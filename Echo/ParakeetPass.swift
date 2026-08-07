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

// MARK: - Energy

/// One channel's loudness over time, frame-quantized: the whole sample buffer
/// reduced to a mean square per 100 ms.
///
/// It exists so the two channels' levels can be compared on the SAME window —
/// the measured bleed discriminator — even though the pass decodes one channel
/// at a time and lets each one's samples go before reading the next. Keeping
/// both buffers instead would double the pass's peak memory (~46 MB per hour,
/// per channel); an envelope costs ~144 KB an hour and answers the only
/// question the dedup asks of the audio.
nonisolated struct EnergyEnvelope: Sendable {

    /// Resolution. Well under the shortest segment the pass emits, so a span's
    /// level is never dominated by frame rounding.
    static let frameSeconds: TimeInterval = 0.1

    private let meanSquares: [Float]

    init(samples: [Float]) {
        let frame = max(1, Int(AudioConstants.sampleRate * Self.frameSeconds))
        var squares: [Float] = []
        squares.reserveCapacity(samples.count / frame + 1)
        var start = 0
        while start < samples.count {
            let count = min(frame, samples.count - start)
            var sum: Float = 0
            for i in start..<(start + count) { sum += samples[i] * samples[i] }
            squares.append(sum / Float(count))
            start += count
        }
        meanSquares = squares
    }

    /// RMS over `[from, to)` seconds, or nil when that window covers no frame
    /// of this channel — an unmeasurable span must read as absent evidence,
    /// never as silence.
    func rms(from: TimeInterval, to: TimeInterval) -> Float? {
        let first = max(0, Int((from / Self.frameSeconds).rounded(.down)))
        let last = min(meanSquares.count, Int((to / Self.frameSeconds).rounded(.up)))
        guard first < last else { return nil }
        var sum: Float = 0
        for i in first..<last { sum += meanSquares[i] }
        return (sum / Float(last - first)).squareRoot()
    }

    /// Below this rms a frame holds nothing at all — not speech, not echo,
    /// not room tone worth a word. Measured on the fixtures: true silence sits
    /// at 0.0004–0.0008, the quietest transcribed bleed at 0.003, speech above
    /// 0.02. An absolute floor is safe HERE, where it only places a boundary
    /// between segments, in a way it never was for deciding what to transcribe
    /// (BRN-005): misplacing a boundary costs nothing, dropping audio erases
    /// words.
    static let silenceFloor: Float = 0.002

    /// Start time of every stretch of silence lasting at least `minimum`.
    ///
    /// These are the only instants in a channel guaranteed not to fall inside
    /// a word, which makes them the safe places to end a segment — and unlike
    /// the gaps between token timings, they come from the audio itself rather
    /// than from the model's estimate of when it heard something.
    ///
    /// The START of each stretch is what is reported, not its middle: a model
    /// that stretches a token's timing forward over the silence would put the
    /// echo's first word before a midpoint, but never before the instant the
    /// speaker actually fell quiet.
    func silenceStarts(minimum: TimeInterval) -> [TimeInterval] {
        let floor = Self.silenceFloor * Self.silenceFloor
        var starts: [TimeInterval] = []
        var runStart: Int?
        // One index past the end closes a run that reaches the last frame.
        for i in 0...meanSquares.count {
            if i < meanSquares.count, meanSquares[i] < floor {
                if runStart == nil { runStart = i }
            } else if let start = runStart {
                if Double(i - start) * Self.frameSeconds >= minimum {
                    starts.append(Double(start) * Self.frameSeconds)
                }
                runStart = nil
            }
        }
        return starts
    }

    /// How many frames either side of a frame are averaged in before comparing
    /// the two channels. Raw 100 ms frames cross over constantly during
    /// ordinary speech — a syllable's decay dips under the other channel and
    /// back — so a run measured on them is chopped into meaningless slivers.
    /// Smoothing over 300 ms makes "dominant" mean sustained, not momentary.
    private static let dominanceSmoothing = 1

    /// The longest uninterrupted stretch of `[from, to)` where this channel
    /// carries more energy than `other`.
    ///
    /// This is the one thing an echo can never fake. A bleed segment is the
    /// other channel arriving quieter through a speaker and a room, so it is
    /// under that channel for its whole length; a second of the reverse means
    /// the near speaker actually said something here. Frames only one channel
    /// has are not dominance — they are the absence of a comparison.
    func longestDominantRun(
        over other: EnergyEnvelope,
        from: TimeInterval,
        to: TimeInterval
    ) -> TimeInterval {
        let first = max(0, Int((from / Self.frameSeconds).rounded(.down)))
        let last = min(
            min(meanSquares.count, other.meanSquares.count),
            Int((to / Self.frameSeconds).rounded(.up))
        )
        guard first < last else { return 0 }

        var longest = 0
        var current = 0
        for i in first..<last {
            let window = max(first, i - Self.dominanceSmoothing)
                ..< min(last, i + Self.dominanceSmoothing + 1)
            var mine: Float = 0
            var theirs: Float = 0
            for j in window {
                mine += meanSquares[j]
                theirs += other.meanSquares[j]
            }
            current = mine > theirs ? current + 1 : 0
            longest = max(longest, current)
        }
        return Double(longest) * Self.frameSeconds
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
    ///
    /// It is also the finest grain the dedup can work at, which is what set
    /// this value. A segment is the unit of suppression, so any silence this
    /// misses welds real speech to the bleed that follows it into one
    /// indivisible row — kept whole with the echo inside, or deleted whole
    /// with the speech. Measured on a field recording: a 0.7 s pause between
    /// the user finishing and the teammate's echo starting, which 1.0 s
    /// stepped straight over. Splitting there costs nothing the reader sees
    /// (`TranscriptUtterance.derive` re-merges same-speaker runs) and lets
    /// each side be judged on its own evidence.
    static let segmentGapSeconds: TimeInterval = 0.6

    /// A silent stretch in the channel's OWN audio at least this long also
    /// ends a segment, whatever the token timings say.
    ///
    /// `segmentGapSeconds` trusts the model's estimate of when it heard each
    /// token, and that estimate is what fails on the case this exists for: a
    /// measured 0.7 s pause between the user finishing and an echo starting,
    /// which the model papered over by stretching its token times across it —
    /// no gap to split on, so real speech and bleed stayed welded into one
    /// row. The audio always knew. Shorter than `segmentGapSeconds` because
    /// this is positive evidence of silence rather than the mere absence of a
    /// token, and because the token boundaries either side eat into it.
    static let silenceSplitSeconds: TimeInterval = 0.3

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

        // Both channels up front, because the echo pre-pass needs the pair in
        // hand at once — it subtracts one from the other. Costs ~46 MB per
        // hour more at peak than reading them one at a time, transiently, on
        // a machine that has already unloaded the summary model for the pass.
        var samplesByChannel: [AudioChannel: [Float]] = [:]
        for entry in channels {
            if shouldYield() { throw PassError.preempted }
            samplesByChannel[entry.channel] = try readSamples(at: entry.url)
        }
        try cancelEchoIfPresent(in: &samplesByChannel, shouldYield: shouldYield, diagnostics: diagnostics)

        var segments: [TranscriptSegment] = []
        // ADR-003 v2's optional evidence. Built from the samples that are
        // actually decoded — evidence has to describe the audio the words
        // came from, so after the pre-pass, not before it. Never persisted —
        // the on-disk schema is untouched.
        var envelopes: [AudioChannel: EnergyEnvelope] = [:]
        for (index, entry) in channels.enumerated() {
            if shouldYield() { throw PassError.preempted }

            let samples = samplesByChannel[entry.channel] ?? []
            let envelope = EnergyEnvelope(samples: samples)
            envelopes[entry.channel] = envelope
            let produced = try await transcribeChannel(
                samples: samples,
                channel: entry.channel,
                envelope: envelope,
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
        let kept = EchoDedupPolicy().dedupe(
            final: ordered,
            spanLevels: spanLevels(of: ordered, envelopes: envelopes),
            onSuppression: diagnostics.map { sink in
                { candidate, verdict in sink(Self.suppressionReport(candidate, verdict)) }
            }
        )
        // Numbers only — the reason each one went is the harness sink's job.
        log.notice("Dedup: \(ordered.count - kept.count, privacy: .public) of \(ordered.count, privacy: .public) segments suppressed as bleed")
        return kept
    }

    // MARK: Echo pre-pass

    /// Replaces the mic samples with a copy the teammate's voice has been
    /// subtracted out of, when the audio itself shows an echo path.
    ///
    /// Subordinate to the pass in the strongest sense: it needs both channels
    /// to do anything, it decides from the audio rather than from stored
    /// state (so Retry cleans meetings recorded before any of this existed),
    /// and it cannot fail. `EchoCancellationPrePass` returns the mic it was
    /// given whenever it cannot do better, and the only error it raises is
    /// the pass's own preemption.
    ///
    /// Dedup, the own-voice guard and the silence cutter all still run
    /// afterwards, on whatever survives subtraction — defence in depth, not a
    /// replacement.
    private static func cancelEchoIfPresent(
        in samples: inout [AudioChannel: [Float]],
        shouldYield: @escaping @Sendable () -> Bool,
        diagnostics: DiagnosticSink?
    ) throws {
        guard let mic = samples[.microphone], let system = samples[.system] else { return }

        let outcome = try EchoCancellationPrePass.run(
            mic: mic,
            system: system,
            stage: WebRTCAECStage(),
            shouldYield: shouldYield
        )
        samples[.microphone] = outcome.mic

        // Numbers only, so this one line can go to the log as well as the
        // harness — nothing here describes what anybody said.
        log.notice("\(outcome.summary, privacy: .public)")
        diagnostics?(outcome.summary)
    }

    // MARK: Dedup evidence

    /// Both channels' rms over each segment's own window. Segment times are
    /// file-relative and the retained files begin at recording t=0, so a
    /// segment's span indexes both envelopes directly.
    ///
    /// A segment only carries evidence when BOTH channels can answer for its
    /// window — a half-measured span has no ratio, and the policy reads a
    /// missing entry as "no evidence, keep".
    static func spanLevels(
        of segments: [TranscriptSegment],
        envelopes: [AudioChannel: EnergyEnvelope]
    ) -> [UUID: EchoDedupPolicy.SpanLevels] {
        var levels: [UUID: EchoDedupPolicy.SpanLevels] = [:]
        for segment in segments {
            let opposite: AudioChannel = segment.channel == .microphone ? .system : .microphone
            guard
                let ownEnvelope = envelopes[segment.channel],
                let otherEnvelope = envelopes[opposite],
                let own = ownEnvelope.rms(from: segment.start, to: segment.end),
                let other = otherEnvelope.rms(from: segment.start, to: segment.end)
            else { continue }
            levels[segment.id] = EchoDedupPolicy.SpanLevels(
                own: own,
                other: other,
                ownVoiceSeconds: ownEnvelope.longestDominantRun(
                    over: otherEnvelope, from: segment.start, to: segment.end
                )
            )
        }
        return levels
    }

    /// One harness line per suppressed segment: which tier fired and on what
    /// evidence, so a replay shows *why* a row went. Carries transcript text,
    /// which is why only the harness sink ever sees it.
    private static func suppressionReport(
        _ candidate: TranscriptSegment,
        _ verdict: EchoDedupPolicy.SuppressionVerdict
    ) -> String {
        String(
            format: "suppressed %@ %.2f–%.2fs tier=%@ containment=%.2f ratio=%@ ownvoice=%.1fs team=%.2f–%.2fs text=%@",
            candidate.channel.rawValue,
            candidate.start, candidate.end,
            verdict.tier.rawValue,
            verdict.containment,
            verdict.rmsRatio.map { String(format: "%.2f", $0) } ?? "n/a",
            verdict.ownVoiceSeconds,
            verdict.match.start, verdict.match.end,
            candidate.text
        )
    }

    // MARK: Per-channel decode

    private static func transcribeChannel(
        samples: [Float],
        channel: AudioChannel,
        envelope: EnergyEnvelope,
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
            channel: channel,
            silenceStarts: envelope.silenceStarts(minimum: silenceSplitSeconds)
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
    /// Splits at every inter-token gap over `segmentGapSeconds`, at every
    /// `silenceStarts` instant a token crosses, and at the next word start once
    /// a running segment would pass `maxSegmentSeconds`. Empty-text segments
    /// are dropped; nothing else is filtered — Whisper's pathologies (noise
    /// transcriptions, boilerplate hallucinations, silence inventions) don't
    /// apply, and ADR-003 dedup still runs afterwards.
    ///
    /// `silenceStarts` are the instants this channel's audio actually fell
    /// quiet (`EnergyEnvelope.silenceStarts`), in ascending order. They are
    /// what makes the cutter independent of the model's timing estimates,
    /// which measurably paper over real pauses; passing none leaves the pure
    /// token-timing behaviour, which is what the tables exercise.
    static func segments(
        from timings: [TokenTiming],
        text: String,
        duration: TimeInterval,
        channel: AudioChannel,
        silenceStarts: [TimeInterval] = []
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
            // A row with no letter and no digit in it says nothing — and
            // dropping one can't cost a word, because it has none. Silence
            // draws a lone "." out of the model, and cancelled bleed leaves
            // long stretches of exactly that: a measured 25 s of "You: ."
            // where the teammate's voice used to be. Same rule as the empty
            // check this replaces, one character wider.
            guard text.contains(where: { $0.isLetter || $0.isNumber }) else { return }
            produced.append(TranscriptSegment(
                channel: channel,
                speaker: speaker,
                text: text,
                start: first.startTime,
                end: last.endTime
            ))
        }

        var nextSilence = 0
        for timing in timings {
            if let previous = current.last, let first = current.first {
                // Silences the emitted tokens already span can't split
                // anything: a model that stretched a token across a pause
                // leaves nowhere inside it to cut.
                while nextSilence < silenceStarts.count,
                      silenceStarts[nextSilence] <= previous.endTime {
                    nextSilence += 1
                }
                let crossesSilence = nextSilence < silenceStarts.count
                    && silenceStarts[nextSilence] <= timing.startTime

                if crossesSilence || timing.startTime - previous.endTime > segmentGapSeconds {
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
