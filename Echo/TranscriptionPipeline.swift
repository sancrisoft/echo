//
//  TranscriptionPipeline.swift
//  Echo
//
//  Turns the two 16 kHz mono Float streams into transcript segments:
//    - microphone → WhisperKit → labeled as the user (`.me`)
//    - system     → WhisperKit → labeled as the teammates (`.teammates`)
//
//  Audio is buffered per channel and cut at natural pauses (energy-based VAD
//  endpointing) so chunks land *between* words instead of slicing through one.
//  Per-speaker diarization was dropped for the PoC; the system stream is one
//  generic "Team" speaker.
//

import Foundation
import WhisperKit
import os

actor TranscriptionPipeline {

    static let log = Logger(subsystem: "com.sancrisoft.Echo", category: "TranscriptionPipeline")

    // MARK: - Tuning

    /// Don't cut (or transcribe) anything shorter than this — keeps chunks from
    /// becoming a stream of one-word slivers when there are lots of short pauses.
    private let minSamples = Int(AudioConstants.sampleRate * 1)
    /// Hard cap: if someone talks nonstop, force a cut at the quietest point
    /// within the last few seconds rather than waiting forever. Whisper tops out
    /// around 30 s/window; 12 s keeps latency reasonable while leaving margin.
    private let maxSamples = Int(AudioConstants.sampleRate * 12)

    // VAD endpointing — what counts as "the speaker stopped".

    /// Analysis window for the energy probe (~30 ms).
    private let probeSamples = Int(AudioConstants.sampleRate * 0.03)
    /// A window quieter than this (RMS) is treated as non-speech. Above the
    /// `isSilent` floor so room tone / breaths still register as a pause.
    private let pauseRMS: Float = 0.01
    /// A trailing run of silence this long marks the end of an utterance, so we
    /// cut here. 0.5 s clears normal between-word gaps (<200 ms) but catches
    /// clause/sentence boundaries.
    private let endpointSilence = Int(AudioConstants.sampleRate * 0.5)

    // MARK: - Models

    /// WhisperKit model variant (quantized large-v3 — good accuracy/size balance).
    private let modelVariant = "large-v3-v20240930_626MB"

    private var whisper: WhisperKit?
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

    /// Per-channel pending audio plus the recording-relative time of its first
    /// sample, so emitted segments keep absolute timestamps as we drain it.
    private struct ChannelBuffer {
        var samples: [Float] = []
        var chunkStart: TimeInterval = 0
    }

    private var mic = ChannelBuffer()
    private var system = ChannelBuffer()

    private func speaker(for channel: AudioChannel) -> Speaker {
        channel == .microphone ? .me : .teammates
    }

    private func pendingSamples(_ channel: AudioChannel) -> [Float] {
        switch channel {
        case .microphone: return mic.samples
        case .system: return system.samples
        }
    }

    private func append(_ frames: [Float], to channel: AudioChannel) {
        switch channel {
        case .microphone: mic.samples.append(contentsOf: frames)
        case .system: system.samples.append(contentsOf: frames)
        }
    }

    /// Synchronously pulls the leading `count` samples off a channel buffer and
    /// advances its clock. No `await` runs between the read and the mutation, so
    /// reentrant `ingest` calls can't observe a torn buffer.
    private func detachChunk(_ channel: AudioChannel, count: Int) -> (chunk: [Float], offset: TimeInterval)? {
        switch channel {
        case .microphone: return Self.detach(&mic, count)
        case .system: return Self.detach(&system, count)
        }
    }

    private static func detach(_ buffer: inout ChannelBuffer, _ count: Int) -> (chunk: [Float], offset: TimeInterval)? {
        let n = min(count, buffer.samples.count)
        guard n > 0 else { return nil }
        let chunk = Array(buffer.samples.prefix(n))
        buffer.samples.removeFirst(n)
        let offset = buffer.chunkStart
        buffer.chunkStart += Double(n) / AudioConstants.sampleRate
        return (chunk, offset)
    }

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
        let clock = ContinuousClock()
        let started = clock.now
        let stateRef = state
        do {
            // 1. Download the model with progress (first run only — cached after,
            //    so this returns almost immediately on later launches).
            await state?.updateStatus("Downloading model…")
            let folder = try await WhisperKit.download(
                variant: modelVariant,
                useBackgroundSession: false
            ) { progress in
                Task { @MainActor in
                    stateRef?.updateStatus("Downloading model… \(Int(progress.fractionCompleted * 100))%")
                }
            }

            // 2. Compile + load from the local folder (no model re-download;
            //    download:true only lets the tokenizer resolve if needed).
            await state?.updateStatus("Loading model…")
            whisper = try await WhisperKit(
                modelFolder: folder.path,
                verbose: false,
                logLevel: .error,
                prewarm: false,
                load: true,
                download: true
            )
            loaded = true
            Self.log.info("Model loaded in \(started.duration(to: clock.now).description, privacy: .public)")
            await state?.updateStatus("")
        } catch {
            Self.log.error("Model load failed: \(error.localizedDescription, privacy: .public)")
            await state?.updateStatus("Couldn't load model: \(error.localizedDescription)")
        }
    }

    /// Resets per-session state and ensures the models are loaded.
    func start(appendingTo state: RecordingState) async {
        self.state = state
        mic = ChannelBuffer()
        system = ChannelBuffer()

        if !loaded { await preload(updating: state) }
    }

    /// Flush whatever is left in both buffers at the end of the session.
    func stop() async {
        await emit(.microphone, count: mic.samples.count)
        await emit(.system, count: system.samples.count)
    }

    // MARK: - Ingestion

    func ingest(_ frames: [Float], from channel: AudioChannel) async {
        guard loaded else { return }   // drop audio until the models are ready
        append(frames, to: channel)
        // Emit every chunk whose boundary is currently exposed (a long pause may
        // free several at once after a backlog).
        while let cut = cutPoint(pendingSamples(channel)) {
            await emit(channel, count: cut)
        }
    }

    // MARK: - VAD endpointing

    /// Decides where (if anywhere) the pending buffer should be cut right now.
    /// Returns the number of leading samples to emit, or `nil` to keep buffering.
    private func cutPoint(_ samples: [Float]) -> Int? {
        guard samples.count >= minSamples else { return nil }

        // Natural endpoint: the speaker paused. Cut at the end of the buffer so
        // the whole utterance (plus its trailing silence) goes out together.
        if trailingSilence(samples) >= endpointSilence { return samples.count }

        // Nonstop talking: force a cut at the quietest window we can find near
        // the end, which is the least-bad place to split mid-speech.
        if samples.count >= maxSamples { return quietestCut(samples) }

        return nil
    }

    /// Length, in samples, of the uninterrupted low-energy run at the buffer's end.
    private func trailingSilence(_ samples: [Float]) -> Int {
        var silent = 0
        var end = samples.count
        while end - probeSamples >= 0 {
            if rms(samples, from: end - probeSamples, count: probeSamples) >= pauseRMS { break }
            silent += probeSamples
            end -= probeSamples
        }
        return silent
    }

    /// Index of the quietest probe window in the last few seconds — used as the
    /// fallback cut when there's no real pause. Never cuts below `minSamples`.
    private func quietestCut(_ samples: [Float]) -> Int {
        let searchSpan = Int(AudioConstants.sampleRate * 4)
        let lo = max(minSamples, samples.count - searchSpan)
        let hi = samples.count - probeSamples
        guard hi > lo else { return samples.count }

        var bestRMS = Float.greatestFiniteMagnitude
        var bestCut = samples.count
        var i = lo
        while i <= hi {
            let value = rms(samples, from: i, count: probeSamples)
            if value < bestRMS {
                bestRMS = value
                bestCut = i + probeSamples / 2   // cut through the middle of the gap
            }
            i += probeSamples
        }
        return bestCut
    }

    private func rms(_ samples: [Float], from start: Int, count: Int) -> Float {
        var sumSquares: Float = 0
        for i in start..<(start + count) { sumSquares += samples[i] * samples[i] }
        return (sumSquares / Float(count)).squareRoot()
    }

    // MARK: - Transcription

    /// Pulls the leading `count` samples off the channel buffer, transcribes
    /// them, and appends the resulting segments. Shared by both channels.
    private func emit(_ channel: AudioChannel, count: Int) async {
        guard let (chunk, offset) = detachChunk(channel, count: count) else { return }
        guard !isSilent(chunk) else { return }
        guard let whisper else { return }
        let results: [TranscriptionResult]
        do {
            results = try await whisper.transcribe(audioArray: chunk, decodeOptions: decodeOptions)
        } catch {
            Self.log.error("\(channel.rawValue, privacy: .public) transcribe failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        let who = speaker(for: channel)
        for result in results {
            for segment in result.segments {
                guard let segmentText = cleaned(segment.text) else { continue }
                await state?.append(TranscriptSegment(
                    channel: channel,
                    speaker: who,
                    text: segmentText,
                    start: offset + Double(segment.start),
                    end: offset + Double(segment.end)
                ))
            }
        }
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
