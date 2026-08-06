//
//  ParakeetPass.swift
//  Echo
//
//  THE transcription pass. After a meeting stops, the retained per-channel
//  audio (ADR-013) is decoded once, end to end, on `parakeet-tdt-0.6b-v3`
//  through FluidAudio. There is no live transcript to improve on and no
//  "floor" to fall back to — this pass is where a meeting's words come from.
//
//  Deliberately thin, and that is the point. Whisper's pass needed per-window
//  language detection, A/B dual decodes, prompt chaining, rejection
//  thresholds, energy evidence gates, run collapse and tail pads — every one
//  of them a defense against a pathology of that model, and two of them
//  (the A/B verdict, the evidence gate) measured on 2026-08-06 to be
//  translating Spanish into English and erasing real speech. Parakeet v3 has
//  none of those failure modes, so this pass has none of those defenses:
//  read → transcribe → map timings to segments → dedup. Nothing else belongs
//  here; if quality disappoints, the model choice is what changes, never a
//  compensating heuristic bolted on below.
//
//  Long audio is FluidAudio's problem, not ours: `AsrManager.transcribe`
//  chunks internally at ~15 s frame-aligned windows with overlap and merges
//  the result, and streams a progress fraction for anything over ~15 s. The
//  model is loaded ONCE per pass (never per window — the old pass's
//  per-window reload was a measured defect) and released when the pass ends.
//

import AVFoundation
import FluidAudio
import Foundation
import os

// MARK: - Model provisioning

/// Lends the pass a directory holding a complete, ready-to-load model set.
/// Nil means "not now" — the pass throws `modelUnavailable`, the coordinator
/// counts a failed attempt, and the meeting stays pending until a later
/// launch's resume scan finds the model on disk.
nonisolated protocol ParakeetModelProviding: Sendable {
    func readyModelDirectory() async -> URL?
}

/// Production wiring: the answer comes from `ParakeetModelManager`'s offline
/// disk check, re-queried per pass.
nonisolated struct ManagedParakeetModelProvider: ParakeetModelProviding {
    let manager: ParakeetModelManager

    func readyModelDirectory() async -> URL? {
        await manager.modelDirectoryIfReady()
    }
}

// MARK: - Progress

/// The finalizing UI's single progress source (ADR-007): decoded audio time
/// over the total retained duration across both channels — never a second
/// independently-maintained number. The fraction is monotonic, in [0, 1], and
/// reaches exactly 1.0 when every channel is accounted for. Pure value —
/// table-tested without audio.
nonisolated struct FinalPassProgress: Sendable {

    private let totals: [Double]
    private var positions: [Double]
    private var reported: Double

    /// One entry per channel: that channel's total retained samples. No
    /// retained audio at all means nothing to decode — complete immediately,
    /// so the fraction still ends at 1.0.
    init(channelTotalSamples: [Int]) {
        totals = channelTotalSamples.map { Double(max(0, $0)) }
        positions = Array(repeating: 0, count: totals.count)
        reported = totals.reduce(0, +) > 0 ? 0 : 1
    }

    /// The fraction the UI shows — monotonic, never past 1.
    var fraction: Double { reported }

    /// `channel` is decoded through `samplePosition` on its own timeline.
    /// Backward positions and out-of-range channels are ignored, so the
    /// fraction can never regress.
    @discardableResult
    mutating func advance(channel: Int, decodedThrough samplePosition: Int) -> Double {
        guard positions.indices.contains(channel) else { return reported }
        positions[channel] = min(max(positions[channel], Double(samplePosition)), totals[channel])
        return recompute()
    }

    /// `channel` finished: it contributes its full share, so the overall
    /// fraction ends at exactly 1.0 once every channel has finished.
    @discardableResult
    mutating func finishChannel(_ channel: Int) -> Double {
        guard positions.indices.contains(channel) else { return reported }
        positions[channel] = totals[channel]
        return recompute()
    }

    private mutating func recompute() -> Double {
        let total = totals.reduce(0, +)
        guard total > 0 else {
            reported = 1
            return reported
        }
        reported = max(reported, min(1, positions.reduce(0, +) / total))
        return reported
    }
}

/// Lock-guarded holder for the pass's progress accumulator. The fraction is
/// advanced from the engine's progress-stream consumer (its own child task)
/// and from the channel loop, so the value type itself stays pure and
/// table-testable while the sharing is explicit — the diagnostics-sink /
/// preemption-signal pattern this codebase uses everywhere else.
private final class SharedPassProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var progress: FinalPassProgress

    init(channelTotalSamples: [Int]) {
        progress = FinalPassProgress(channelTotalSamples: channelTotalSamples)
    }

    var fraction: Double {
        lock.lock()
        defer { lock.unlock() }
        return progress.fraction
    }

    func advance(channel: Int, decodedThrough samplePosition: Int) -> Double {
        lock.lock()
        defer { lock.unlock() }
        return progress.advance(channel: channel, decodedThrough: samplePosition)
    }

    func finishChannel(_ channel: Int) -> Double {
        lock.lock()
        defer { lock.unlock() }
        return progress.finishChannel(channel)
    }
}

// MARK: - The pass

nonisolated enum ParakeetPass {

    static let log = Logger(subsystem: "com.sancrisoft.Echo", category: "ParakeetPass")

    enum PassError: Error {
        /// No complete model set on disk right now — the pass cannot run.
        case modelUnavailable
        /// Loading the Core ML models failed.
        case modelLoadFailed(String)
        /// `shouldYield` asked the pass to stop (ADR-014 recording preemption).
        case preempted
        /// The retained file couldn't be opened or read as 16 kHz Float PCM.
        case unreadableAudio(String)
    }

    /// Diagnostic sink for the developer replay harness: one human-readable
    /// line per channel and per produced segment, INCLUDING transcript text —
    /// which is why production paths never pass one.
    typealias DiagnosticSink = @Sendable (String) -> Void

    // MARK: Segment shaping

    /// Split the token stream at any inter-token silence longer than this. The
    /// model emits per-token times, not sentences, so this is what turns a
    /// channel's tokens into readable, timeline-anchored segments.
    static let segmentGapSeconds: TimeInterval = 1.0

    /// A running segment longer than this splits at the next word start —
    /// mirroring the 1–12 s granularity the rest of the app (dedup timing
    /// gate, transcript UI, summary chunking) was built against.
    static let maxSegmentSeconds: TimeInterval = 12.0

    /// Polling period of the preemption watcher (ADR-014: the pass yields
    /// promptly once a recording starts).
    static let yieldPollInterval: Duration = .milliseconds(250)

    /// Decodes every retained channel and returns the complete segment set,
    /// timeline-ordered, ready for the atomic write. Throws on any failure —
    /// the caller keeps the retained audio and the coordinator decides retry
    /// vs terminal. `onProgress` receives the single ADR-007 fraction
    /// (monotonic, ends at 1.0 on a completed decode).
    static func run(
        retainedFiles: [AudioChannel: URL],
        models: some ParakeetModelProviding,
        shouldYield: @escaping @Sendable () -> Bool = { false },
        onProgress: @escaping @Sendable (Double) -> Void = { _ in },
        diagnostics: DiagnosticSink? = nil
    ) async throws -> [TranscriptSegment] {
        // Deterministic channel order; the sort below owns the timeline.
        let channels = [AudioChannel.microphone, .system].compactMap { channel in
            retainedFiles[channel].map { (channel: channel, url: $0) }
        }

        guard let modelDirectory = await models.readyModelDirectory() else {
            throw PassError.modelUnavailable
        }
        // A recording that started while we were asking must not pay for a
        // model load it is about to preempt anyway.
        if shouldYield() { throw PassError.preempted }

        let asrModels: AsrModels
        do {
            asrModels = try await AsrModels.load(
                from: modelDirectory,
                version: ParakeetModelManager.version,
                encoderPrecision: ParakeetModelManager.encoderPrecision
            )
        } catch {
            throw PassError.modelLoadFailed(error.localizedDescription)
        }

        // `melChunkContext: false` is FluidAudio's own instruction for v3
        // multilingual long-form batch transcription (issue #594: the 80 ms
        // mel prepend makes the SOS-primed decoder drift back to its
        // English-biased prior — exactly the Spanish-meetings case).
        // Everything else stays at library defaults.
        let manager = AsrManager(config: ASRConfig(melChunkContext: false))
        do {
            try await manager.loadModels(asrModels)
        } catch {
            await manager.cleanup()
            throw PassError.modelLoadFailed(error.localizedDescription)
        }

        do {
            let segments = try await transcribeChannels(
                channels,
                manager: manager,
                shouldYield: shouldYield,
                onProgress: onProgress,
                diagnostics: diagnostics
            )
            await manager.cleanup()
            return segments
        } catch {
            // Pass-scoped release on every exit — Swift forbids `await` in a
            // `defer`, so the release is driven from this do/catch instead.
            await manager.cleanup()
            throw error
        }
    }

    private static func transcribeChannels(
        _ channels: [(channel: AudioChannel, url: URL)],
        manager: AsrManager,
        shouldYield: @escaping @Sendable () -> Bool,
        onProgress: @escaping @Sendable (Double) -> Void,
        diagnostics: DiagnosticSink?
    ) async throws -> [TranscriptSegment] {
        // One accumulator over both channels' retained durations drives every
        // fraction the UI sees (ADR-007 — no second counter). Totals come from
        // the files' own lengths; a file this header can't open reads 0 here
        // and throws honestly when the channel is read below.
        let progress = SharedPassProgress(channelTotalSamples: channels.map {
            (try? AVAudioFile(forReading: $0.url)).map { Int($0.length) } ?? 0
        })
        onProgress(progress.fraction)

        var segments: [TranscriptSegment] = []
        for (index, entry) in channels.enumerated() {
            if shouldYield() { throw PassError.preempted }

            let samples = try readSamples(at: entry.url)
            let produced = try await transcribeChannel(
                samples: samples,
                channel: entry.channel,
                manager: manager,
                shouldYield: shouldYield,
                onChannelFraction: { fraction in
                    onProgress(progress.advance(
                        channel: index,
                        decodedThrough: Int(fraction * Double(samples.count))
                    ))
                },
                diagnostics: diagnostics
            )
            segments += produced
            onProgress(progress.finishChannel(index))
        }

        let ordered = segments.sorted { $0.start < $1.start }
        // ADR-003 over the complete set: the batch holds every Team segment,
        // so cross-channel echoes are caught here.
        return EchoDedupPolicy().dedupe(final: ordered)
    }

    // MARK: Per-channel decode

    private static func transcribeChannel(
        samples: [Float],
        channel: AudioChannel,
        manager: AsrManager,
        shouldYield: @escaping @Sendable () -> Bool,
        onChannelFraction: @escaping @Sendable (Double) -> Void,
        diagnostics: DiagnosticSink?
    ) async throws -> [TranscriptSegment] {
        guard !samples.isEmpty else { return [] }

        let clock = ContinuousClock()
        let started = clock.now
        let result = try await transcribeRespectingPreemption(
            samples: samples,
            manager: manager,
            shouldYield: shouldYield,
            onChannelFraction: onChannelFraction
        )

        let produced = segments(
            from: result.tokenTimings ?? [],
            text: result.text,
            duration: result.duration,
            channel: channel
        )
        let line = String(
            format: "Parakeet %@: %.1fs audio, %d tokens → %d segments in %@",
            channel.rawValue,
            Double(samples.count) / AudioConstants.sampleRate,
            result.tokenTimings?.count ?? 0,
            produced.count,
            started.duration(to: clock.now).description
        )
        // notice, not info: info-level lines never persist in the local log
        // store, so a field report arriving after the fact would find nothing.
        // Numbers only here — NEVER transcript text (that is the harness sink).
        log.notice("\(line, privacy: .public)")
        diagnostics?(line)
        if let diagnostics {
            for segment in produced {
                diagnostics(String(
                    format: "segment %@ %.2f–%.2fs text=%@",
                    channel.rawValue, segment.start, segment.end, segment.text
                ))
            }
        }
        return produced
    }

    /// Runs one channel's decode with ADR-014 preemption: a sibling watcher
    /// polls `shouldYield` and throws the moment a recording starts, which
    /// tears down the task group — FluidAudio checks `Task.isCancelled` inside
    /// its own chunk loop, so the decode stops within a chunk rather than
    /// running the meeting out.
    ///
    /// The decoder state is created inside the child task: it is per-channel
    /// (independent audio streams never share context) and `inout` can't cross
    /// a task boundary.
    private static func transcribeRespectingPreemption(
        samples: [Float],
        manager: AsrManager,
        shouldYield: @escaping @Sendable () -> Bool,
        onChannelFraction: @escaping @Sendable (Double) -> Void
    ) async throws -> ASRResult {
        // FluidAudio only opens a progress session for input over ~15 s
        // (`maxModelSamples`); subscribing below that would leave a session
        // nothing ever finishes. Subscribing BEFORE `transcribe` is the
        // library's documented order — buffered yields make it order-safe.
        let progressStream: AsyncThrowingStream<Double, Error>? =
            samples.count > ASRConstants.maxModelSamples
                ? await manager.transcriptionProgressStream
                : nil

        return try await withThrowingTaskGroup(of: ASRResult?.self) { group in
            group.addTask {
                var state = try TdtDecoderState(
                    decoderLayers: ParakeetModelManager.version.decoderLayers
                )
                // `language: nil` — neutral, the library default. The meeting's
                // language is not a stored fact, and v3 is natively
                // multilingual. `.spanish` is the first knob to try if
                // validation ever shows residual English drift.
                return try await manager.transcribe(samples, decoderState: &state, language: nil)
            }
            if let progressStream {
                group.addTask {
                    for try await fraction in progressStream {
                        onChannelFraction(fraction)
                    }
                    return nil
                }
            }
            group.addTask {
                while true {
                    if shouldYield() { throw PassError.preempted }
                    try await Task.sleep(for: yieldPollInterval)
                }
            }

            // The decode is the only child that ever yields a value; the
            // watcher only throws, and the progress consumer only ends.
            while let next = try await group.next() {
                if let next {
                    group.cancelAll()
                    return next
                }
            }
            throw PassError.preempted
        }
    }

    // MARK: Timings → segments (pure, table-testable)

    /// SentencePiece word-boundary marker: a token carrying it starts a new
    /// word, which is where a long segment is allowed to split.
    static let wordBoundary = "▁"

    /// Turns one channel's token timings into transcript segments. Times are
    /// seconds, file-relative, already window-merged by FluidAudio — and the
    /// retained files begin at recording t=0, so they are absolute recording
    /// seconds with no offset math.
    ///
    /// Splits at every inter-token silence over `segmentGapSeconds`, and at the
    /// next word start once a running segment would pass `maxSegmentSeconds`.
    /// Empty-text segments are dropped; nothing else is filtered — Whisper's
    /// pathologies (noise transcriptions, boilerplate hallucinations, silence
    /// inventions) don't apply, and ADR-003 dedup still runs afterwards.
    static func segments(
        from timings: [TokenTiming],
        text: String,
        duration: TimeInterval,
        channel: AudioChannel
    ) -> [TranscriptSegment] {
        let speaker: Speaker = channel == .microphone ? .me : .teammates

        guard !timings.isEmpty else {
            // Fallback, not the design: v3 batch always returns timings. If it
            // ever doesn't, one channel-spanning segment loses the timeline but
            // never the words.
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return [] }
            ErrorTrace.record(
                "Parakeet returned text with no token timings — emitting one channel-spanning segment",
                category: "ParakeetPass",
                metadata: ["channel": channel.rawValue]
            )
            return [TranscriptSegment(
                channel: channel,
                speaker: speaker,
                text: trimmed,
                start: 0,
                end: max(0, duration)
            )]
        }

        var produced: [TranscriptSegment] = []
        var current: [TokenTiming] = []

        func flush() {
            guard let first = current.first, let last = current.last else { return }
            let text = joinedText(current)
            current = []
            guard !text.isEmpty else { return }
            produced.append(TranscriptSegment(
                channel: channel,
                speaker: speaker,
                text: text,
                start: first.startTime,
                end: last.endTime
            ))
        }

        for timing in timings {
            if let previous = current.last, let first = current.first {
                if timing.startTime - previous.endTime > segmentGapSeconds {
                    flush()
                } else if isWordStart(timing.token),
                          timing.endTime - first.startTime > maxSegmentSeconds {
                    flush()
                }
            }
            current.append(timing)
        }
        flush()
        return produced
    }

    /// SentencePiece detokenization, identical to FluidAudio's own: pieces
    /// concatenate and the boundary marker becomes a space.
    private static func joinedText(_ timings: [TokenTiming]) -> String {
        timings
            .map { $0.token }
            .joined()
            .replacingOccurrences(of: wordBoundary, with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isWordStart(_ token: String) -> Bool {
        token.hasPrefix(wordBoundary) || token.hasPrefix(" ")
    }

    // MARK: Audio reading

    /// The whole retained channel as 16 kHz mono Float32. Read in bounded
    /// blocks so peak memory stays a block, not the file — the samples array
    /// itself is what the engine needs whole (~46 MB for a one-hour channel).
    static func readSamples(at url: URL) throws -> [Float] {
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            throw PassError.unreadableAudio(error.localizedDescription)
        }
        guard file.processingFormat.commonFormat == .pcmFormatFloat32 else {
            throw PassError.unreadableAudio("Unexpected decoded format for \(url.lastPathComponent)")
        }

        let totalSamples = Int(file.length)
        guard totalSamples > 0 else { return [] }
        let blockSamples = Int(AudioConstants.sampleRate * 60)

        var samples: [Float] = []
        samples.reserveCapacity(totalSamples)
        var position = 0
        while position < totalSamples {
            let count = min(blockSamples, totalSamples - position)
            samples += try read(file, window: position..<(position + count))
            position += count
        }
        return samples
    }

    private static func read(_ file: AVAudioFile, window: Range<Int>) throws -> [Float] {
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: file.processingFormat,
            frameCapacity: AVAudioFrameCount(window.count)
        ) else {
            throw PassError.unreadableAudio("Couldn't allocate a \(window.count)-frame read buffer")
        }
        do {
            file.framePosition = AVAudioFramePosition(window.lowerBound)
            try file.read(into: buffer, frameCount: AVAudioFrameCount(window.count))
        } catch {
            throw PassError.unreadableAudio(error.localizedDescription)
        }
        guard let channelData = buffer.floatChannelData else {
            throw PassError.unreadableAudio("Decoded buffer exposes no Float channel data")
        }
        return Array(UnsafeBufferPointer(start: channelData[0], count: Int(buffer.frameLength)))
    }
}
