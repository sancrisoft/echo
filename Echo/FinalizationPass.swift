//
//  FinalizationPass.swift
//  Echo
//
//  SP-005 S1+S3: the final re-transcription pass. After a meeting stops (and
//  its live transcript is persisted — the floor, ADR-016), the pass re-decodes
//  the retained per-channel audio (ADR-013) in sequential ≤30 s windows on the
//  model a `FinalPassModelProviding` lends it — v0 lends the live pipeline's
//  already-loaded instance (ADR-015's floor tier: no second model in memory).
//
//  S3 gives the decode Whisper's native advantages the live path can't afford:
//    - prior-text chaining (`FinalPassPromptChain` → DecodingOptions.promptTokens;
//      the pinned WhisperKit prepends them behind startOfPreviousToken in
//      `prefillDecoderInputs`, so they genuinely condition decoding)
//    - temperature-fallback retries on flagged windows (`finalDecodeOptions`)
//    - per-window language on voiced evidence with the session language as
//      fallback and an alternate-language re-decode on flagged windows
//      (SP-007, ADR-020; audio is never discarded for language reasons)
//    - evidence-based speech-region selection (`SpeechRegionSelector`) — the
//      live path's anti-hallucination speech gates never see a full-timeline
//      decode, and the pinned WhisperKit's noSpeechProb is dead code
//      (hardcoded 0), so silence discipline must come from energy evidence
//    - the SP-007 decode discipline (`FinalPassDiscipline`, ADR-019):
//      tail-pad hygiene, rejection after exhausted fallback, per-segment
//      energy evidence, per-channel run collapse, and the empty-output guard
//    - ADR-003 dedup re-applied to the complete final segment set
//
//  The loop is deliberately window-driven: `shouldYield` is checked before
//  every decode window so slice S4 can wire recording preemption (ADR-014
//  "yields within one decode window") without touching this loop. v0 callers
//  always pass false.
//
//  Tail trap (SP-005 Further Notes): the pinned WhisperKit never decodes the
//  last ≤1.0 s of a clip (windowClipTime), so every window is padded with
//  ≥1.5 s of trailing silence before decoding — otherwise each window's tail,
//  and with it the meeting's closing words, would be structurally lost.
//

import AVFoundation
import Foundation
import WhisperKit
import os

/// Provides the Whisper model a final pass decodes with. v0's only
/// implementation lends the live pipeline's instance; slice S5 adds the
/// RAM-tiered provider (ADR-015) behind this same seam, so the window loop
/// never learns which checkpoint it is running on.
nonisolated protocol FinalPassModelProviding: Sendable {
    func withModel<T: Sendable>(_ body: @Sendable (WhisperKit) async throws -> T) async throws -> T
}

/// Lends the live pipeline's already-loaded WhisperKit instance — zero
/// additional model memory, the 8 GB tier and the universal fallback floor.
nonisolated struct LivePipelineModelProvider: FinalPassModelProviding {
    let pipeline: TranscriptionPipeline

    func withModel<T: Sendable>(_ body: @Sendable (WhisperKit) async throws -> T) async throws -> T {
        try await pipeline.withModelForFinalPass(body)
    }
}

/// Pure windowing arithmetic, separated so the plan is table-testable
/// without a model (SP-005 Testing Decisions, layer 1).
nonisolated enum FinalPassWindowPlan {

    /// Whisper's native operating point — the full context the live path's
    /// 1–12 s chunks structurally can't give it.
    static let windowSamples = Int(AudioConstants.sampleRate * 30)

    /// Trailing silence appended to every decode clip; must exceed the
    /// pinned WhisperKit's 1.0 s windowClipTime so the audible tail decodes.
    static let tailPadSamples = Int(AudioConstants.sampleRate * 1.5)

    /// Sequential, contiguous windows covering every retained sample — the
    /// last window always reaches `totalSamples` (the tail-trap guard).
    static func windows(totalSamples: Int) -> [Range<Int>] {
        guard totalSamples > 0 else { return [] }
        return stride(from: 0, to: totalSamples, by: windowSamples).map {
            $0..<min($0 + windowSamples, totalSamples)
        }
    }

    /// A window's decode clip: its samples plus the trailing silence pad.
    static func paddedClip(_ samples: ArraySlice<Float>) -> [Float] {
        var clip = Array(samples)
        clip.append(contentsOf: [Float](repeating: 0, count: tailPadSamples))
        return clip
    }

    /// ≤30 s windows covering exactly the selected speech regions, in absolute
    /// (recording-relative) sample positions — the last window of every region
    /// reaches the region's end, so the tail-trap guard holds per region.
    static func windows(covering regions: [Range<Int>]) -> [Range<Int>] {
        regions.flatMap { region in
            windows(totalSamples: region.count).map {
                (region.lowerBound + $0.lowerBound)..<(region.lowerBound + $0.upperBound)
            }
        }
    }
}

/// The finalizing UI's single progress source (SP-005 S6, ADR-007): decoded
/// audio time over the total retained duration across both channels — never a
/// second independently-maintained number. Positions are absolute sample
/// offsets on each channel's retained timeline, so silent regions the speech
/// selector skipped count as instantly decoded the moment a window lands past
/// them; `finishChannel` accounts for trailing silence after the last speech
/// region. The fraction is monotonic, in [0, 1], and reaches exactly 1.0 when
/// every channel is fully accounted for. Pure value — table-tested without
/// audio (SP-005 Testing Decisions, layer 1).
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

    /// A decode window on `channel` finished, covering the channel's timeline
    /// through `samplePosition` (the window's absolute upper bound).
    /// Everything before it — including skipped silent regions — counts as
    /// decoded. Backward positions and out-of-range channels are ignored, so
    /// the fraction can never regress.
    @discardableResult
    mutating func advance(channel: Int, decodedThrough samplePosition: Int) -> Double {
        guard positions.indices.contains(channel) else { return reported }
        positions[channel] = min(max(positions[channel], Double(samplePosition)), totals[channel])
        return recompute()
    }

    /// `channel`'s window loop completed: any trailing silence after its last
    /// speech region counts as decoded, so the channel contributes its full
    /// share and the overall fraction ends at exactly 1.0.
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

/// Prior-text chaining state for one channel (SP-005 S3): the rolling token
/// tail of what decoded so far, handed to the next window as
/// `DecodingOptions.promptTokens`. Pure value — table-tested without a model.
///
/// Reset rules: a fresh chain per channel (channel boundaries never share
/// context), and an empty window clears the chain — silence broke the
/// utterance, so stale context would mislead the next decode more than help it.
nonisolated struct FinalPassPromptChain: Sendable {

    /// Half of Whisper's 224-token sample length — the conditioning budget the
    /// model was trained with. The pinned WhisperKit trims prompts to
    /// (224/2)−1 itself; capping here keeps the chain's memory bounded and the
    /// tail (the most recent speech) the part that survives.
    static let maxTokens = 112

    private(set) var tokens: [Int] = []

    /// What the next window decodes with — nil (not `[]`) when there is
    /// nothing to carry, so DecodingOptions skips the prompt path entirely.
    var promptTokens: [Int]? { tokens.isEmpty ? nil : tokens }

    /// Feeds one decoded window into the chain: text tokens accumulate and
    /// only the most recent `maxTokens` survive; an empty window resets.
    mutating func advance(windowTokens: [Int]) {
        guard !windowTokens.isEmpty else {
            tokens = []
            return
        }
        tokens = Array((tokens + windowTokens).suffix(Self.maxTokens))
    }
}

/// Evidence-based speech-region selection (SP-005 S3) — the live path's
/// anti-hallucination defense, moved: speech gates never see a full-timeline
/// decode and the pinned WhisperKit's noSpeechProb is dead code, so the final
/// pass decodes ONLY sample ranges with energy evidence of speech. Pure
/// arithmetic over 30 ms probe series; table-tested without audio.
nonisolated enum SpeechRegionSelector {

    /// One 30 ms energy probe — the same window the gates and VAD use.
    struct Probe: Sendable {
        let rms: Float
        let peak: Float
    }

    static let probeSamples = AudioStats.probeSamples

    /// Generous padding around detected speech: soft onsets/decays and probe
    /// quantization must never clip a word's edges.
    static let paddingSamples = Int(AudioConstants.sampleRate * 0.5)

    /// Regions closer than this merge — decoding across a short pause keeps
    /// sentence context together and avoids sub-second slivers.
    static let mergeGapSamples = Int(AudioConstants.sampleRate * 2.0)

    /// Whether one probe clears the gates' hard silence floor — evaluated
    /// through `GateTerm` itself so the thresholds can never drift from the
    /// live gate's (SP-002's single home of the numbers).
    static func hasSpeechEvidence(_ probe: Probe) -> Bool {
        let stats = AudioStats(
            rms: probe.rms,
            peak: probe.peak,
            activeRatio: 0,
            speechWindowRatio: 0,
            strongWindowRatio: 0,
            noiseFloorRMS: 0,
            dynamicRangeDB: 0,
            crestFactor: 0
        )
        return GateTerm.hardFloor.allSatisfy { $0.passes(stats) }
    }

    /// The sample ranges worth decoding: every probe with speech evidence,
    /// padded by `paddingSamples` on both sides, nearby ranges merged, all
    /// clamped to `[0, totalSamples)`. Probe `i` covers samples
    /// `[i*probeSamples, (i+1)*probeSamples)` (the last probe may be partial),
    /// so ranges stay in recording-relative sample positions. A fully silent
    /// series selects nothing — those spans are never decoded.
    static func regions(probes: [Probe], totalSamples: Int) -> [Range<Int>] {
        guard totalSamples > 0 else { return [] }
        var merged: [Range<Int>] = []
        for (index, probe) in probes.enumerated() where hasSpeechEvidence(probe) {
            let start = max(0, index * probeSamples - paddingSamples)
            let end = min(totalSamples, (index + 1) * probeSamples + paddingSamples)
            guard start < end else { continue }
            if let last = merged.last, start - last.upperBound < mergeGapSamples {
                merged[merged.count - 1] = last.lowerBound..<max(last.upperBound, end)
            } else {
                merged.append(start..<end)
            }
        }
        return merged
    }
}

nonisolated enum FinalizationPass {

    static let log = Logger(subsystem: "com.sancrisoft.Echo", category: "FinalizationPass")

    enum PassError: Error {
        /// The lender has no loaded model — the pass cannot run now.
        case modelUnavailable
        /// `shouldYield` asked the pass to stop between decode windows
        /// (ADR-014 recording preemption; S4 wires the caller side).
        case preempted
        /// The retained file couldn't be opened or read as 16 kHz Float PCM.
        case unreadableAudio(String)
        /// Speech regions existed but the decode discipline dropped every
        /// segment (ADR-019's empty-output guard): a filter bug must never
        /// silently erase a good transcript, so the pass fails and the
        /// caller's live floor stands.
        case emptyDisciplinedOutput
    }

    /// The final pass's decode options: the live path's tightened thresholds,
    /// plus the retries live latency forbids — `temperatureFallbackCount = 3`
    /// re-decodes a flagged window at increasing temperature (SP-005 Further
    /// Notes reality 3; post-meeting time is affordable). `usePrefillPrompt`
    /// stays true (the DecodingOptions default): it is what routes
    /// `promptTokens` through the pinned WhisperKit's prefill path, so the
    /// chained prior text actually conditions decoding. Language and
    /// promptTokens are set per window.
    static let finalDecodeOptions: DecodingOptions = {
        var options = TranscriptionPipeline.liveDecodeOptions
        options.temperatureFallbackCount = 3
        return options
    }()

    /// Re-transcribes every retained channel and returns the complete final
    /// segment set, timeline-ordered, ready for the atomic replace. Throws on
    /// any failure — the caller leaves the live transcript standing and keeps
    /// the retained audio (ADR-016). `onProgress` receives the single ADR-007
    /// fraction (monotonic, ends at 1.0 on a completed decode) after every
    /// decode window; a pass that fails or defers simply stops reporting.
    static func run(
        retainedFiles: [AudioChannel: URL],
        model: some FinalPassModelProviding,
        shouldYield: @Sendable () -> Bool = { false },
        onProgress: @Sendable (Double) -> Void = { _ in }
    ) async throws -> [TranscriptSegment] {
        // Deterministic channel order; the sort below owns the timeline.
        let channels = [AudioChannel.microphone, .system].compactMap { channel in
            retainedFiles[channel].map { (channel: channel, url: $0) }
        }
        // One accumulator over both channels' retained durations drives every
        // fraction the UI sees (ADR-007 — no second counter). Totals come
        // from the files' own lengths; a file this header read can't open
        // reads 0 here and throws honestly in `transcribeChannel` below.
        var progress = FinalPassProgress(channelTotalSamples: channels.map {
            (try? AVAudioFile(forReading: $0.url)).map { Int($0.length) } ?? 0
        })
        onProgress(progress.fraction)

        var segments: [TranscriptSegment] = []
        var anySpeechRegions = false
        for (index, entry) in channels.enumerated() {
            let channelResult = try await transcribeChannel(
                url: entry.url,
                channel: entry.channel,
                model: model,
                shouldYield: shouldYield,
                onWindowDecoded: { decodedThrough in
                    onProgress(progress.advance(channel: index, decodedThrough: decodedThrough))
                }
            )
            segments += channelResult.segments
            anySpeechRegions = anySpeechRegions || channelResult.hadSpeechRegions
            // Trailing silence after the channel's last speech region counts
            // as instantly decoded — the channel contributes its full share.
            onProgress(progress.finishChannel(index))
        }
        let ordered = segments.sorted { $0.start < $1.start }
        // ADR-003 re-applied over the complete final set (SP-005): the batch
        // holds every Team segment, so echoes whose counterpart transcribed
        // too late to match live are caught here — batch dedup is only ever
        // stronger than live, and keep-on-doubt still rules the close calls.
        let deduped = EchoDedupPolicy().dedupe(final: ordered)
        // ADR-019's empty-output guard: empty output is a legitimate success
        // only where the energy evidence itself says nobody spoke.
        if FinalPassDiscipline.emptyOutputIsFailure(
            regionsSelected: anySpeechRegions,
            outputEmpty: deduped.isEmpty
        ) {
            ErrorTrace.record(
                "Final pass dropped every segment despite speech regions — floor stands",
                category: "FinalizationPass"
            )
            throw PassError.emptyDisciplinedOutput
        }
        return deduped
    }

    // MARK: - Per-channel window loop

    /// One decoded window's disciplined outcome, computed inside the model
    /// lend and applied to the loop state outside it.
    private struct WindowOutcome: Sendable {
        let segments: [TranscriptSegment]
        let windowTokens: [Int]
        let tracker: FinalPassLanguageTracker
        /// The language the kept decode actually ran in (the A/B backstop may
        /// have switched it) — what the next window's chain-reset compares.
        let language: String
    }

    /// The per-window diagnostic's confidence field: a decode that produced
    /// no segments has no mean logprob to report.
    private static func logprobDescription(_ mean: Float?) -> String {
        mean.map { String(format: "%.3f", $0) } ?? "empty"
    }

    private static func transcribeChannel(
        url: URL,
        channel: AudioChannel,
        model: some FinalPassModelProviding,
        shouldYield: @Sendable () -> Bool,
        onWindowDecoded: (Int) -> Void = { _ in }
    ) async throws -> (segments: [TranscriptSegment], hadSpeechRegions: Bool) {
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
        // Silence discipline (SP-005): decode only where the energy evidence
        // says someone spoke. Windows fully below the gates' hard floor are
        // never decoded, so Whisper never sees the long silent stretches it
        // is known to invent text over. Region positions are absolute sample
        // offsets, so the recording-relative timestamp mapping is intact.
        let probes = try probeSeries(file, totalSamples: totalSamples)
        let regions = SpeechRegionSelector.regions(probes: probes, totalSamples: totalSamples)
        let windows = FinalPassWindowPlan.windows(covering: regions)
        Self.log.info("""
        Final pass: \(channel.rawValue, privacy: .public) — \
        \(String(format: "%.1f", Double(totalSamples) / AudioConstants.sampleRate), privacy: .public)s retained, \
        \(regions.count, privacy: .public) speech regions, \
        \(windows.count, privacy: .public) windows
        """)

        var segments: [TranscriptSegment] = []
        var languageTracker = FinalPassLanguageTracker()
        var chain = FinalPassPromptChain()
        var previousLanguage: String?

        for window in windows {
            if shouldYield() { throw PassError.preempted }

            let samples = try read(file, window: window)
            let clip = FinalPassWindowPlan.paddedClip(samples[...])
            let offset = Double(window.lowerBound) / AudioConstants.sampleRate
            let carriedTracker = languageTracker
            let carriedPrevious = previousLanguage
            let carriedPrompt = chain.promptTokens

            let outcome = try await model.withModel { whisper -> WindowOutcome in
                // Per-window language on voiced evidence (ADR-020): detection
                // runs on the UNPADDED window samples — the window covers a
                // selected speech region, so this is what was actually voiced,
                // never the silence pad. The window always decodes: a decisive
                // detection decides it alone; anything below the decisive
                // floor makes it language-uncertain, with the session prior
                // (else argmax, else default) as the prompt-carrying primary.
                var tracker = carriedTracker
                let detection = try? await whisper.detectLangauge(audioArray: samples)
                let decision = tracker.decodeLanguage(
                    detection: detection?.language,
                    probabilities: detection?.langProbs ?? [:]
                )
                let language = decision.language

                // A language change orphans the previous window's prior-text
                // conditioning (ADR-020 rule 4) — text in another language
                // would drag this decode toward it.
                let promptTokens = FinalPassDiscipline.shouldResetChain(
                    previousLanguage: carriedPrevious,
                    windowLanguage: language
                ) ? nil : carriedPrompt

                var options = finalDecodeOptions
                options.language = language
                options.promptTokens = promptTokens
                let results = try await whisper.transcribe(audioArray: clip, decodeOptions: options)

                // Tail-pad hygiene before anything judges the raw segments:
                // the clip's real audio ends at the window boundary, and the
                // decoder extrapolates into the pad (ADR-019 rule 4).
                let windowDuration = Double(samples.count) / AudioConstants.sampleRate
                var raw = FinalPassDiscipline.tailPadHygiene(
                    results.flatMap(\.segments),
                    windowDuration: windowDuration
                )
                var chosenLanguage = language
                var abLine = "none"

                // A/B backstop (ADR-020 rule 3 + 2026-08-05 field report):
                // quality-flagged windows as before, PLUS language-uncertain
                // ones — a fluent covert translation has healthy logprobs and
                // never quality-flags, but transcribing Spanish as Spanish
                // beats translating it on token logprob, so the decode
                // comparison catches what fluency hides from the thresholds.
                // The better mean logprob is kept — and remains subject to
                // the discipline below (both may lose). No prompt: the chain
                // is in the primary language.
                if FinalPassDiscipline.needsAlternateDecode(
                    isDecisive: decision.isDecisive,
                    qualityFlagged: FinalPassDiscipline.isQualityFlagged(raw)
                ), let alternate = FinalPassDiscipline.alternateWhitelistLanguage(to: language) {
                    var alternateOptions = finalDecodeOptions
                    alternateOptions.language = alternate
                    alternateOptions.promptTokens = nil
                    if let alternateResults = try? await whisper.transcribe(
                        audioArray: clip, decodeOptions: alternateOptions
                    ) {
                        let alternateRaw = FinalPassDiscipline.tailPadHygiene(
                            alternateResults.flatMap(\.segments),
                            windowDuration: windowDuration
                        )
                        let primaryMean = FinalPassDiscipline.meanAvgLogprob(raw)
                        let alternateMean = FinalPassDiscipline.meanAvgLogprob(alternateRaw)
                        let choice = FinalPassDiscipline.abChoice(primary: raw, alternate: alternateRaw)
                        if choice == .alternate {
                            raw = alternateRaw
                            chosenLanguage = alternate
                        }
                        // The kept dual-decode language is real evidence of
                        // what the meeting sounds like — feed the session
                        // prior so consistent meetings converge, without
                        // re-creating the lock (decisive windows still
                        // decide alone).
                        tracker.noteABWinner(chosenLanguage)
                        abLine = String(
                            format: "%@ %@=%@ %@=%@",
                            choice == .alternate ? "alternate" : "primary",
                            language, Self.logprobDescription(primaryMean),
                            alternate, Self.logprobDescription(alternateMean)
                        )
                    } else {
                        abLine = "failed"
                    }
                }

                // Per-window language diagnosability (2026-08-05 field
                // report: covert translation had to be inferred because
                // nothing logged the language path). Numbers and language
                // codes only — NEVER transcript text.
                let detectedLine = detection.map {
                    String(format: "%@@%.2f", $0.language, $0.langProbs[$0.language] ?? 0)
                } ?? "none"
                let windowLine = String(
                    format: "Final pass window %@ %.2f–%.2fs: detected=%@ decisive=%@ decode=%@ kept=%@ ab=%@",
                    channel.rawValue,
                    offset, offset + windowDuration,
                    detectedLine,
                    decision.isDecisive ? "yes" : "no",
                    language, chosenLanguage,
                    abLine
                )
                Self.log.info("\(windowLine, privacy: .public)")

                // ADR-019 rules 1+2: exhausted-fallback rejection, then
                // per-segment energy evidence through the live filters —
                // every kept segment is judged against stats sliced from its
                // OWN span of the unpadded samples, with recording-relative
                // timestamps applied.
                let produced = FinalPassDiscipline.disciplinedWindowSegments(
                    raw: raw,
                    channel: channel,
                    offset: offset,
                    windowSamples: samples
                )

                // Chain only text that survived the discipline — a dropped
                // hallucination must not condition the next window. The
                // leading space matters to Whisper's byte-BPE (mid-stream
                // words tokenize with the space attached); WhisperKit's
                // prefill drops special tokens, but filtering here keeps the
                // chain's 112-token budget spent on real text only.
                let keptText = produced.map(\.text).joined(separator: " ")
                var tokens: [Int] = []
                if !keptText.isEmpty, let tokenizer = whisper.tokenizer {
                    tokens = tokenizer.encode(text: " " + keptText)
                        .filter { $0 < tokenizer.specialTokens.specialTokenBegin }
                }
                return WindowOutcome(
                    segments: produced,
                    windowTokens: tokens,
                    tracker: tracker,
                    language: chosenLanguage
                )
            }

            languageTracker = outcome.tracker
            // The chain resets when the kept decode's language changed from
            // the previous window's (ADR-020 rule 4) — including an A/B
            // switch, whose kept text is in the alternate language.
            if FinalPassDiscipline.shouldResetChain(
                previousLanguage: previousLanguage,
                windowLanguage: outcome.language
            ) {
                chain = FinalPassPromptChain()
            }
            chain.advance(windowTokens: outcome.windowTokens)
            previousLanguage = outcome.language

            segments += outcome.segments

            // The channel's timeline is decoded through this window's end —
            // silence skipped before it included (SP-005 S6, ADR-007).
            onWindowDecoded(window.upperBound)
        }
        // ADR-019 rule 3, per channel across windows: no run of 3+
        // near-identical segments survives; the first member remains as the
        // ADR-003 dedup timing anchor.
        return (FinalPassDiscipline.collapseRuns(segments), !regions.isEmpty)
    }

    /// Streams the retained file once, computing the 30 ms RMS/peak probe
    /// series the region selector consumes. Reads in probe-aligned blocks so
    /// no probe spans a read boundary; only the file's final probe may be
    /// partial. Memory stays bounded (~33 probes per second of audio).
    private static func probeSeries(
        _ file: AVAudioFile,
        totalSamples: Int
    ) throws -> [SpeechRegionSelector.Probe] {
        let blockSamples = SpeechRegionSelector.probeSamples * 1000
        var probes: [SpeechRegionSelector.Probe] = []
        probes.reserveCapacity(totalSamples / SpeechRegionSelector.probeSamples + 1)

        var position = 0
        while position < totalSamples {
            let count = min(blockSamples, totalSamples - position)
            let samples = try read(file, window: position..<(position + count))
            var start = 0
            while start < samples.count {
                let length = min(SpeechRegionSelector.probeSamples, samples.count - start)
                var sumSquares: Float = 0
                var peak: Float = 0
                for i in start..<(start + length) {
                    sumSquares += samples[i] * samples[i]
                    peak = max(peak, abs(samples[i]))
                }
                probes.append(.init(
                    rms: (sumSquares / Float(length)).squareRoot(),
                    peak: peak
                ))
                start += length
            }
            position += count
        }
        return probes
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
