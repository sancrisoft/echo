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
//    - session-informed language with hysteresis (`FinalPassLanguageTracker`;
//      audio is never discarded for language reasons)
//    - evidence-based speech-region selection (`SpeechRegionSelector`) — the
//      live path's anti-hallucination speech gates never see a full-timeline
//      decode, and the pinned WhisperKit's noSpeechProb is dead code
//      (hardcoded 0), so silence discipline must come from energy evidence
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

/// Session-informed per-window language with hysteresis (SP-005 S3), one
/// tracker per channel. Replaces the live path's per-chunk detect-and-discard:
/// the final pass never skips audio for language reasons — every window
/// decodes, in the best language the session's evidence supports.
nonisolated struct FinalPassLanguageTracker: Sendable {

    /// A differing in-whitelist detection must repeat on this many consecutive
    /// windows to switch the session language — mixed es/en meetings switch on
    /// real transitions while single-window flickers (Whisper mis-detecting
    /// one noisy window) don't whipsaw the decode.
    static let switchStreak = 2

    /// Decode language while no confident in-whitelist detection has arrived.
    static let defaultLanguage = "en"

    private(set) var sessionLanguage: String?
    private var pendingLanguage: String?
    private var pendingCount = 0

    /// The language this window decodes with, given the window's detection
    /// (nil when detection failed). Out-of-whitelist detections keep the
    /// current session language (or the default while undecided) and break
    /// any pending switch streak — they are noise, not evidence.
    mutating func decodeLanguage(forDetection detection: String?) -> String {
        guard let detection,
              TranscriptionPipeline.allowedTranscriptionLanguages.contains(detection) else {
            pendingLanguage = nil
            pendingCount = 0
            return sessionLanguage ?? Self.defaultLanguage
        }
        guard let current = sessionLanguage else {
            // First confident detection sets the session language.
            sessionLanguage = detection
            return detection
        }
        guard detection != current else {
            pendingLanguage = nil
            pendingCount = 0
            return current
        }
        if pendingLanguage == detection {
            pendingCount += 1
        } else {
            pendingLanguage = detection
            pendingCount = 1
        }
        guard pendingCount >= Self.switchStreak else { return current }
        sessionLanguage = detection
        pendingLanguage = nil
        pendingCount = 0
        return detection
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
    /// the retained audio (ADR-016).
    static func run(
        retainedFiles: [AudioChannel: URL],
        model: some FinalPassModelProviding,
        shouldYield: @Sendable () -> Bool = { false }
    ) async throws -> [TranscriptSegment] {
        var segments: [TranscriptSegment] = []
        // Deterministic channel order; the sort below owns the timeline.
        for channel in [AudioChannel.microphone, .system] {
            guard let url = retainedFiles[channel] else { continue }
            segments += try await transcribeChannel(
                url: url,
                channel: channel,
                model: model,
                shouldYield: shouldYield
            )
        }
        let ordered = segments.sorted { $0.start < $1.start }
        // ADR-003 re-applied over the complete final set (SP-005): the batch
        // holds every Team segment, so echoes whose counterpart transcribed
        // too late to match live are caught here — batch dedup is only ever
        // stronger than live, and keep-on-doubt still rules the close calls.
        return EchoDedupPolicy().dedupe(final: ordered)
    }

    // MARK: - Per-channel window loop

    private static func transcribeChannel(
        url: URL,
        channel: AudioChannel,
        model: some FinalPassModelProviding,
        shouldYield: @Sendable () -> Bool
    ) async throws -> [TranscriptSegment] {
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

        for window in windows {
            if shouldYield() { throw PassError.preempted }

            let samples = try read(file, window: window)
            let clip = FinalPassWindowPlan.paddedClip(samples[...])
            let offset = Double(window.lowerBound) / AudioConstants.sampleRate
            let carriedTracker = languageTracker
            let promptTokens = chain.promptTokens

            let (produced, windowTokens, advancedTracker) = try await model.withModel {
                whisper -> ([TranscriptSegment], [Int], FinalPassLanguageTracker) in
                // Session-informed language with hysteresis (SP-005): the
                // window always decodes — out-of-whitelist or failed
                // detections fall back to the session language, never skip.
                var tracker = carriedTracker
                let detection = try? await whisper.detectLangauge(audioArray: clip)
                let language = tracker.decodeLanguage(forDetection: detection?.language)

                var options = finalDecodeOptions
                options.language = language
                options.promptTokens = promptTokens
                let results = try await whisper.transcribe(audioArray: clip, decodeOptions: options)

                // Same segment assembly + noise/boilerplate filters as the
                // live path (the post-filter second line of defense), with
                // recording-relative timestamps (window offset + within-window
                // segment offsets). Stats come from the unpadded samples so
                // the filters judge the real audio.
                let stats = AudioStats.compute(from: samples)
                let produced = TranscriptionPipeline.transcriptSegments(
                    from: results,
                    channel: channel,
                    offset: offset,
                    stats: stats
                )

                // Chain only text that survived the post-filters — a dropped
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
                return (produced, tokens, tracker)
            }

            languageTracker = advancedTracker
            chain.advance(windowTokens: windowTokens)

            // A segment may bleed into the silence pad; the clip's real audio
            // ends at the window boundary, so clamp there.
            let windowEnd = Double(window.upperBound) / AudioConstants.sampleRate
            segments += produced.map { segment in
                var clamped = segment
                clamped.end = min(segment.end, windowEnd)
                return clamped
            }
        }
        return segments
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
