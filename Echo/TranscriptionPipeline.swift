//
//  TranscriptionPipeline.swift
//  Echo
//
//  Turns the two 16 kHz mono Float streams into transcript segments:
//    - microphone → WhisperKit → labeled as the user (`.me`)
//    - system     → WhisperKit + SpeakerKit → labeled per diarized teammate
//
//  Audio is buffered per channel and processed in fixed-length chunks so
//  transcription runs incrementally during the meeting.
//

import Foundation
import WhisperKit
import SpeakerKit
import os

actor TranscriptionPipeline {

    static let log = Logger(subsystem: "com.sancrisoft.Echo", category: "TranscriptionPipeline")

    // MARK: - Tuning

    /// Process audio in ~5 s windows so transcript text appears quickly. (Whisper
    /// handles up to 30 s per window; shorter windows trade a little context for
    /// much lower latency.)
    private let chunkSamples = Int(AudioConstants.sampleRate) * 5
    /// Don't bother transcribing slivers shorter than this.
    private let minSamples = Int(AudioConstants.sampleRate) * 1

    // MARK: - Models

    private var whisper: WhisperKit?
    private var speaker: SpeakerKit?
    private var loaded = false
    private var loadTask: Task<Void, Never>?

    private let decodeOptions: DecodingOptions = {
        var options = DecodingOptions()
        options.verbose = false
        options.task = .transcribe
        options.detectLanguage = true   // meetings may not be in English
        options.wordTimestamps = false
        options.skipSpecialTokens = true   // keep <|...|> tokens out of the text
        return options
    }()

    // MARK: - State

    private weak var state: RecordingState?

    private var micBuffer: [Float] = []
    private var systemBuffer: [Float] = []
    private var micChunkStart: TimeInterval = 0
    private var systemChunkStart: TimeInterval = 0

    // MARK: - Lifecycle

    /// Loads the models (downloading on first run). Idempotent and safe to call
    /// from app launch so the heavy work is done before the user hits record.
    /// Concurrent callers share (and await) a single in-flight load.
    func preload(updating state: RecordingState) async {
        self.state = state
        if loaded { return }
        if let loadTask {
            await loadTask.value
            return
        }
        let task = Task { await self.performLoad() }
        loadTask = task
        await task.value
        if !loaded { loadTask = nil }   // allow a retry after a failed load
    }

    private func performLoad() async {
        await state?.updateStatus("Cargando modelos…")
        let clock = ContinuousClock()
        let started = clock.now
        do {
            whisper = try await WhisperKit(
                model: "large-v3-v20240930_626MB",
                verbose: false,
                logLevel: .error,
                prewarm: false,
                load: true,
                download: true
            )
            speaker = try await SpeakerKit(
                PyannoteConfig(
                    modelRepo: "argmaxinc/speakerkit-coreml",
                    download: true,
                    load: true,
                    verbose: false,
                    logLevel: .error
                )
            )
            loaded = true
            Self.log.info("Models loaded in \(started.duration(to: clock.now).description, privacy: .public)")
            await state?.updateStatus("")
        } catch {
            Self.log.error("Model load failed: \(error.localizedDescription, privacy: .public)")
            await state?.updateStatus("No se pudieron cargar los modelos: \(error.localizedDescription)")
        }
    }

    /// Resets per-session state and ensures the models are loaded.
    func start(appendingTo state: RecordingState) async {
        self.state = state
        micBuffer.removeAll(keepingCapacity: true)
        systemBuffer.removeAll(keepingCapacity: true)
        micChunkStart = 0
        systemChunkStart = 0

        if !loaded { await preload(updating: state) }
    }

    /// Flush whatever is left in both buffers at the end of the session.
    func stop() async {
        await flushMic(force: true)
        await flushSystem(force: true)
    }

    // MARK: - Ingestion

    func ingest(_ frames: [Float], from channel: AudioChannel) async {
        guard loaded else { return }   // drop audio until the models are ready
        switch channel {
        case .microphone:
            micBuffer.append(contentsOf: frames)
            if micBuffer.count >= chunkSamples { await flushMic(force: false) }
        case .system:
            systemBuffer.append(contentsOf: frames)
            if systemBuffer.count >= chunkSamples { await flushSystem(force: false) }
        }
    }

    // MARK: - Microphone (user)

    private func flushMic(force: Bool) async {
        guard micBuffer.count >= (force ? 1 : chunkSamples), micBuffer.count >= minSamples else {
            if force { micBuffer.removeAll(keepingCapacity: true) }
            return
        }
        let chunk = micBuffer
        micBuffer.removeAll(keepingCapacity: true)
        let offset = micChunkStart
        micChunkStart += Double(chunk.count) / AudioConstants.sampleRate

        guard !isSilent(chunk) else { return }
        guard let whisper else { return }
        let results: [TranscriptionResult]
        do {
            results = try await whisper.transcribe(audioArray: chunk, decodeOptions: decodeOptions)
        } catch {
            Self.log.error("Mic transcribe failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        for result in results {
            for segment in result.segments {
                guard let segmentText = cleaned(segment.text) else { continue }
                await state?.append(TranscriptSegment(
                    channel: .microphone,
                    speaker: .me,
                    text: segmentText,
                    start: offset + Double(segment.start),
                    end: offset + Double(segment.end)
                ))
            }
        }
    }

    // MARK: - System (teammates)

    private func flushSystem(force: Bool) async {
        guard systemBuffer.count >= (force ? 1 : chunkSamples), systemBuffer.count >= minSamples else {
            if force { systemBuffer.removeAll(keepingCapacity: true) }
            return
        }
        let chunk = systemBuffer
        systemBuffer.removeAll(keepingCapacity: true)
        let offset = systemChunkStart
        systemChunkStart += Double(chunk.count) / AudioConstants.sampleRate

        guard !isSilent(chunk) else { return }
        guard let whisper else { return }
        let results: [TranscriptionResult]
        do {
            results = try await whisper.transcribe(audioArray: chunk, decodeOptions: decodeOptions)
        } catch {
            Self.log.error("System transcribe failed: \(error.localizedDescription, privacy: .public)")
            return
        }

        // Diarize the same chunk to attribute teammates.
        // NOTE: speaker indices are per-chunk; cross-chunk identity is a known
        // limitation to revisit (e.g. via centroid embeddings) — see TODO.
        let diarization = try? await speaker?.diarize(audioArray: chunk)

        for result in results {
            for segment in result.segments {
                guard let segmentText = cleaned(segment.text) else { continue }
                let speakerLabel = speaker(for: segment, in: diarization)
                await state?.append(TranscriptSegment(
                    channel: .system,
                    speaker: speakerLabel,
                    text: segmentText,
                    start: offset + Double(segment.start),
                    end: offset + Double(segment.end)
                ))
            }
        }
    }

    /// Pick the diarized speaker whose interval contains the midpoint of the
    /// transcription segment; falls back to the first teammate.
    private func speaker(for segment: TranscriptionSegment, in diarization: DiarizationResult?) -> Speaker {
        guard let diarization else { return .teammate(0) }
        let midpoint = Float((segment.start + segment.end) / 2)
        let match = diarization.segments.first { midpoint >= $0.startTime && midpoint <= $0.endTime }
        if let id = match?.speaker.speakerId {
            return .teammate(id)
        }
        if let id = match?.speaker.speakerIds.first {
            return .teammate(id)
        }
        return .teammate(0)
    }

    private func cleaned(_ text: String) -> String? {
        // Strip any leftover Whisper special tokens (e.g. <|0.00|>, <|en|>).
        var value = text.replacingOccurrences(
            of: "<\\|[^|]*\\|>",
            with: "",
            options: .regularExpression
        )
        value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }

        // Whisper emits these markers on silence/non-speech — drop them.
        let nonSpeech: Set<String> = [
            "[blank_audio]", "[silence]", "[ silence ]", "(silence)",
            "[no speech]", "[music]", "(music)", "[inaudible]", "[ pause ]",
        ]
        return nonSpeech.contains(value.lowercased()) ? nil : value
    }

    /// True when a chunk is essentially silence (≈ below −50 dBFS RMS), so we
    /// skip transcribing it and avoid hallucinated text on muted audio.
    private func isSilent(_ samples: [Float]) -> Bool {
        guard !samples.isEmpty else { return true }
        var sumSquares: Float = 0
        for sample in samples { sumSquares += sample * sample }
        let rms = (sumSquares / Float(samples.count)).squareRoot()
        return rms < 0.003
    }
}
