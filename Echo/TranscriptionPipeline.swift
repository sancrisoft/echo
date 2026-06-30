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
    private static let allowedTranscriptionLanguages: Set<String> = ["en", "es"]

    private let decodeOptions: DecodingOptions = {
        var options = DecodingOptions()
        options.verbose = false
        options.task = .transcribe
        options.temperatureFallbackCount = 0
        options.compressionRatioThreshold = 2.2
        options.logProbThreshold = -0.75
        options.firstTokenLogProbThreshold = -1.2
        options.noSpeechThreshold = 0.45
        options.detectLanguage = false
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

    private struct AudioStats {
        let rms: Float
        let peak: Float
        let activeRatio: Float
        let speechWindowRatio: Float
        let strongWindowRatio: Float
        let noiseFloorRMS: Float
        let dynamicRangeDB: Float
        let crestFactor: Float

        /// Conservative evidence that the chunk contains actual speech instead
        /// of low-level residue/silence that Whisper may hallucinate over.
        var hasClearSpeech: Bool {
            rms >= 0.010
                && peak >= 0.035
                && speechWindowRatio >= 0.10
                && crestFactor >= 2.0
                && (dynamicRangeDB >= 4.0 || strongWindowRatio >= 0.06)
        }

        var hasTranscribableSpeech: Bool {
            hasClearSpeech
                || (rms >= 0.018 && peak >= 0.055 && speechWindowRatio >= 0.18)
        }

        var isMarginalSpeech: Bool {
            !hasClearSpeech || rms < 0.014 || speechWindowRatio < 0.16
        }
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
        let stats = audioStats(chunk)
        guard shouldTranscribe(stats, from: channel) else { return }
        guard let whisper else { return }
        let results: [TranscriptionResult]
        do {
            guard let language = await restrictedLanguage(for: chunk, from: channel, using: whisper) else { return }
            var options = decodeOptions
            options.language = language
            results = try await whisper.transcribe(audioArray: chunk, decodeOptions: options)
        } catch {
            Self.log.error("\(channel.rawValue, privacy: .public) transcribe failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        let who = speaker(for: channel)
        for result in results {
            for segment in result.segments {
                guard let segmentText = cleaned(segment.text, channel: channel, segment: segment, audio: stats) else { continue }
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

    private func restrictedLanguage(for audio: [Float], from channel: AudioChannel, using whisper: WhisperKit) async -> String? {
        do {
            let detection = try await whisper.detectLangauge(audioArray: audio)
            guard Self.allowedTranscriptionLanguages.contains(detection.language) else {
                Self.log.info("\(channel.rawValue, privacy: .public) skipped unsupported detected language: \(detection.language, privacy: .public)")
                return nil
            }
            return detection.language
        } catch {
            Self.log.error("\(channel.rawValue, privacy: .public) language detection failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private func cleaned(
        _ text: String,
        channel: AudioChannel,
        segment: TranscriptionSegment,
        audio: AudioStats
    ) -> String? {
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
        let lowercased = value.lowercased()
        if nonSpeech.contains(lowercased) { return nil }
        if isLikelyNoiseTranscription(value, channel: channel, segment: segment, audio: audio) { return nil }
        if isLikelyWhisperBoilerplate(value, segment: segment, audio: audio) { return nil }

        return value
    }

    private func isLikelyNoiseTranscription(
        _ text: String,
        channel: AudioChannel,
        segment: TranscriptionSegment,
        audio: AudioStats
    ) -> Bool {
        let words = normalizedWords(text)
        guard !words.isEmpty else { return true }

        let lowConfidence = segment.avgLogprob < -0.70
            || segment.compressionRatio > 2.2
            || segment.noSpeechProb > 0.45
        let short = words.count <= 5 || segment.duration <= 1.4
        let veryShort = words.count <= 2 || segment.duration <= 0.8
        let garbled = unsupportedLetterRatio(in: text) >= 0.12

        if !shouldTranscribe(audio, from: channel) { return true }
        if veryShort && (lowConfidence || audio.isMarginalSpeech) { return true }
        if short && lowConfidence && audio.isMarginalSpeech { return true }
        if garbled && (lowConfidence || audio.isMarginalSpeech || short) { return true }

        return false
    }

    private func isLikelyWhisperBoilerplate(
        _ text: String,
        segment: TranscriptionSegment,
        audio: AudioStats
    ) -> Bool {
        let normalized = normalizedWords(text).joined(separator: " ")
        guard !normalized.isEmpty else { return true }

        let commonHallucinations: Set<String> = [
            "i know", "you know", "thank you", "thank you very much",
            "thanks", "thanks you", "thanks for watching", "thank you for watching",
            "ok", "okay", "yeah", "yes", "right", "all right",
            "bye", "bye bye", "goodbye", "hello", "hi",
            "from below", "but im not", "but i m not", "im not sure", "i m not sure",
            "happy birthday", "gracias",
            "you", "so", "um", "uh", "mhm", "mm hmm", "uh huh",
        ]

        guard commonHallucinations.contains(normalized) else { return false }

        let short = segment.duration <= 1.6 || normalizedWords(text).count <= 4
        let lowConfidence = segment.avgLogprob < -0.55 || segment.compressionRatio > 2.2
        return short && (!audio.hasClearSpeech || lowConfidence)
    }

    private func normalizedWords(_ text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    private func audioStats(_ samples: [Float]) -> AudioStats {
        guard !samples.isEmpty else {
            return AudioStats(
                rms: 0,
                peak: 0,
                activeRatio: 0,
                speechWindowRatio: 0,
                strongWindowRatio: 0,
                noiseFloorRMS: 0,
                dynamicRangeDB: 0,
                crestFactor: 0
            )
        }

        var sumSquares: Float = 0
        var peak: Float = 0
        for sample in samples {
            sumSquares += sample * sample
            peak = max(peak, abs(sample))
        }

        var windowRMS: [Float] = []
        var activeWindows = 0
        var totalWindows = 0
        var start = 0
        while start + probeSamples <= samples.count {
            totalWindows += 1
            let window = rms(samples, from: start, count: probeSamples)
            windowRMS.append(window)
            if window >= pauseRMS {
                activeWindows += 1
            }
            start += probeSamples
        }

        let noiseFloor = percentile(windowRMS, fraction: 0.20)
        let loudFloor = percentile(windowRMS, fraction: 0.90)
        let speechThreshold = max(pauseRMS, noiseFloor * 2.4, 0.012)
        let strongThreshold = max(noiseFloor * 3.2, 0.020)
        let speechWindows = windowRMS.filter { $0 >= speechThreshold }.count
        let strongWindows = windowRMS.filter { $0 >= strongThreshold }.count
        let activeRatio = totalWindows > 0 ? Float(activeWindows) / Float(totalWindows) : 0
        let speechRatio = totalWindows > 0 ? Float(speechWindows) / Float(totalWindows) : 0
        let strongRatio = totalWindows > 0 ? Float(strongWindows) / Float(totalWindows) : 0
        let dynamicRange = 20 * log10(max(loudFloor, 0.000_001) / max(noiseFloor, 0.000_001))
        let totalRMS = (sumSquares / Float(samples.count)).squareRoot()
        return AudioStats(
            rms: totalRMS,
            peak: peak,
            activeRatio: activeRatio,
            speechWindowRatio: speechRatio,
            strongWindowRatio: strongRatio,
            noiseFloorRMS: noiseFloor,
            dynamicRangeDB: dynamicRange,
            crestFactor: peak / max(totalRMS, 0.000_001)
        )
    }

    /// True only when the audio has enough speech-like structure to be worth
    /// sending to Whisper. This is intentionally stricter than a silence check:
    /// high ambient noise can be loud, but it should not become transcript text.
    private func shouldTranscribe(_ stats: AudioStats, from channel: AudioChannel) -> Bool {
        if stats.rms < 0.004 || stats.peak < 0.020 { return false }

        switch channel {
        case .microphone:
            return stats.hasTranscribableSpeech
        case .system:
            return stats.hasTranscribableSpeech
                || (stats.rms >= 0.008 && stats.peak >= 0.030 && stats.speechWindowRatio >= 0.08)
        }
    }

    private func percentile(_ values: [Float], fraction: Double) -> Float {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let clamped = min(max(fraction, 0), 1)
        let index = Int((Double(sorted.count - 1) * clamped).rounded())
        return sorted[index]
    }

    private func unsupportedLetterRatio(in text: String) -> Double {
        let allowedLetters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZáéíóúüñÁÉÍÓÚÜÑ")
        var totalLetters = 0
        var unsupportedLetters = 0

        for scalar in text.unicodeScalars {
            guard CharacterSet.letters.contains(scalar) else { continue }
            totalLetters += 1
            if !allowedLetters.contains(scalar) {
                unsupportedLetters += 1
            }
        }

        guard totalLetters > 0 else { return 0 }
        return Double(unsupportedLetters) / Double(totalLetters)
    }
}
