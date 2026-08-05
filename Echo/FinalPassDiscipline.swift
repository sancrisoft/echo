//
//  FinalPassDiscipline.swift
//  Echo
//
//  SP-007 S2: the final pass's decode discipline (ADR-019) and the pure parts
//  of its per-window language policy (ADR-020). Everything here is a
//  nonisolated value or pure function so every rule is a table test without a
//  model — the FinalizationPass window loop stays a thin wiring layer.
//
//  ADR-019 — the final pass errs toward omission. Unlike the live path it has
//  no obligation to show something, so every doubtful decision drops text and
//  leaves an honest gap:
//    1. rejection over acceptance — a segment whose final temperature-fallback
//       attempt still fails the model's own quality thresholds contributes no
//       text; a window where every segment fails contributes nothing
//    2. per-segment energy evidence — every kept segment must show speech
//       evidence over ITS OWN time span (the slicing lives in
//       `TranscriptionPipeline.evidenceJudgedSegments`, reusing the live
//       filters at per-segment granularity)
//    3. run collapse — no run of 3+ consecutive near-identical segments
//       survives; the FIRST member is the surviving timing representative
//    4. tail-pad hygiene — segments born in the trailing silence pad drop,
//       pad-bleed ends clamp to the window's real-audio end, and no
//       `end < start` or zero-duration segment can be produced
//  plus the empty-output guard: if speech regions existed but every segment
//  was dropped, the pass must fail so the live floor stands — a filter bug
//  can never silently erase a good transcript.
//

import Foundation
import WhisperKit

nonisolated enum FinalPassDiscipline {

    // MARK: - Rejection over acceptance (ADR-019 rule 1)

    /// The model's own calibrated quality thresholds — read from the live
    /// decode options so the numbers keep exactly one home (the literals here
    /// only guard against those options ever being edited to nil).
    static let compressionRatioThreshold: Float =
        TranscriptionPipeline.liveDecodeOptions.compressionRatioThreshold ?? 2.2
    static let logProbThreshold: Float =
        TranscriptionPipeline.liveDecodeOptions.logProbThreshold ?? -0.75

    /// Whether one raw segment's final-attempt decode metrics clear the
    /// thresholds. Boundaries pass: WhisperKit itself flags strictly beyond
    /// them (`avgLogprob < threshold`, `compressionRatio > threshold`).
    /// `noSpeechProb` is deliberately not consulted — it is dead code in the
    /// pinned WhisperKit (hardcoded 0, documented in SP-005).
    static func passesQualityThresholds(_ segment: TranscriptionSegment) -> Bool {
        segment.avgLogprob >= logProbThreshold
            && segment.compressionRatio <= compressionRatioThreshold
    }

    /// Exhausted retries produce a gap, never the least-bad attempt: only
    /// segments whose final attempt passes survive. An all-failing window
    /// contributes no text.
    static func rejectFailingSegments(_ segments: [TranscriptionSegment]) -> [TranscriptionSegment] {
        segments.filter(passesQualityThresholds)
    }

    /// Whether a window's decode still fails the quality thresholds after
    /// temperature fallback — the trigger for ADR-020's alternate-language
    /// re-decode. An empty decode has nothing to re-decode for.
    static func isQualityFlagged(_ segments: [TranscriptionSegment]) -> Bool {
        segments.contains { !passesQualityThresholds($0) }
    }

    // MARK: - Tail-pad hygiene (ADR-019 rule 4)

    /// Times are window-relative seconds; `windowDuration` is where the
    /// window's REAL audio ends (the trailing silence pad begins there).
    /// Segments born at or beyond it are decoder extrapolation over the pad
    /// and drop outright; segments bleeding into it keep their end clamped;
    /// anything left without positive duration drops. No `end < start` and
    /// no zero-duration segment can survive — the 2026-08-04 clamp artifact
    /// is structurally impossible.
    static func tailPadHygiene(
        _ segments: [TranscriptionSegment],
        windowDuration: Double
    ) -> [TranscriptionSegment] {
        segments.compactMap { segment in
            guard Double(segment.start) < windowDuration else { return nil }
            var clean = segment
            clean.end = min(segment.end, Float(windowDuration))
            guard clean.end > clean.start else { return nil }
            return clean
        }
    }

    // MARK: - Run collapse (ADR-019 rule 3)

    /// Runs of this many (or more) consecutive near-identical segments on a
    /// channel collapse to one. Starting point, tuned against the retained
    /// real-meeting fixtures later — the criterion ("no 3+ run survives") is
    /// the requirement (ADR-019 follow-up).
    static let runCollapseLength = 3

    /// Collapses each qualifying run to its FIRST member — the earliest
    /// timestamps survive as the ADR-003 dedup timing anchor. Near-identical
    /// means equal after normalization (lowercase, punctuation and whitespace
    /// stripped — the live filters' `normalizedWords`). Call per channel on
    /// its time-ordered segments, after the window loop, before batch dedup.
    static func collapseRuns(_ segments: [TranscriptSegment]) -> [TranscriptSegment] {
        var collapsed: [TranscriptSegment] = []
        var index = 0
        while index < segments.count {
            let key = normalizedKey(segments[index].text)
            var runEnd = index + 1
            while runEnd < segments.count, normalizedKey(segments[runEnd].text) == key {
                runEnd += 1
            }
            if runEnd - index >= runCollapseLength {
                collapsed.append(segments[index])
            } else {
                collapsed.append(contentsOf: segments[index..<runEnd])
            }
            index = runEnd
        }
        return collapsed
    }

    private static func normalizedKey(_ text: String) -> String {
        TranscriptionPipeline.normalizedWords(text).joined(separator: " ")
    }

    // MARK: - The composed per-window pipeline

    /// One decode's raw segments through rules 4 → 1 → 2 in the fixed order:
    /// tail-pad hygiene first (so evidence slices judge real spans), then
    /// exhausted-fallback rejection, then per-segment energy evidence through
    /// the live filters. Run collapse (rule 3) runs later, per channel across
    /// windows. `windowSamples` are the window's UNPADDED samples.
    static func disciplinedWindowSegments(
        raw: [TranscriptionSegment],
        channel: AudioChannel,
        offset: TimeInterval,
        windowSamples: [Float]
    ) -> [TranscriptSegment] {
        let windowDuration = Double(windowSamples.count) / AudioConstants.sampleRate
        let hygienic = tailPadHygiene(raw, windowDuration: windowDuration)
        let passing = rejectFailingSegments(hygienic)
        return TranscriptionPipeline.evidenceJudgedSegments(
            from: passing,
            channel: channel,
            offset: offset,
            windowSamples: windowSamples
        )
    }

    // MARK: - Empty-output guard (ADR-019)

    /// Empty output counts as success only where the energy evidence itself
    /// says nobody spoke (no speech regions selected on any channel). Regions
    /// with nothing left after the discipline mean the filters ate a meeting
    /// that had speech — the pass fails and the floor stands.
    static func emptyOutputIsFailure(regionsSelected: Bool, outputEmpty: Bool) -> Bool {
        regionsSelected && outputEmpty
    }

    // MARK: - ADR-020 pure parts

    /// A decode-language change orphans the previous window's conditioning:
    /// prior text in one language must never drag the next window's decode
    /// toward it (ADR-020 rule 4). A channel's first window has no chain yet.
    static func shouldResetChain(previousLanguage: String?, windowLanguage: String) -> Bool {
        previousLanguage != nil && previousLanguage != windowLanguage
    }

    /// The other whitelist language — the A/B backstop's re-decode target.
    /// Designed for the 2-language whitelist (ADR-020 accepted trade-off);
    /// a wider whitelist must revisit the ADR before this grows.
    static func alternateWhitelistLanguage(to language: String) -> String? {
        TranscriptionPipeline.allowedTranscriptionLanguages.first { $0 != language }
    }

    /// Whether a window must dual-decode both whitelist languages
    /// (2026-08-05 field report, extending ADR-020 rule 3): quality-flagged
    /// windows as before, PLUS every language-uncertain window. A covert
    /// translation is FLUENT — healthy logprobs, never quality-flagged — so
    /// the quality trigger alone cannot see it; but transcribing Spanish as
    /// Spanish beats translating it on token logprob, so the decode
    /// comparison catches what fluency hides from the thresholds.
    static func needsAlternateDecode(isDecisive: Bool, qualityFlagged: Bool) -> Bool {
        !isDecisive || qualityFlagged
    }

    enum ABChoice: Equatable {
        case primary
        case alternate
    }

    /// ADR-020 rule 3's verdict: the decode with the better model-reported
    /// confidence (mean per-segment avgLogprob) is kept. A decode with no
    /// segments reports no confidence and loses to one with any; ties and
    /// empty-vs-empty keep the primary (the detection-decided language).
    static func abChoice(
        primary: [TranscriptionSegment],
        alternate: [TranscriptionSegment]
    ) -> ABChoice {
        guard let alternateConfidence = meanAvgLogprob(alternate) else { return .primary }
        guard let primaryConfidence = meanAvgLogprob(primary) else { return .alternate }
        return alternateConfidence > primaryConfidence ? .alternate : .primary
    }

    /// Internal (not private): the window loop logs both decodes' confidence
    /// on the per-window diagnostic line (2026-08-05 field report — this
    /// defect class must never need inferring again).
    static func meanAvgLogprob(_ segments: [TranscriptionSegment]) -> Float? {
        guard !segments.isEmpty else { return nil }
        return segments.reduce(0) { $0 + $1.avgLogprob } / Float(segments.count)
    }
}

/// ADR-020: per-window language on voiced evidence — no session lock. A
/// DECISIVE in-whitelist detection decides its own window, full stop, and
/// becomes the session fallback. Everything below the decisive floor is
/// language-UNCERTAIN: the window dual-decodes both whitelist languages and
/// keeps the better mean logprob (`FinalPassDiscipline.abChoice`); the
/// uncertain PRIMARY (the decode that carries the prompt chain) follows the
/// session prior when one exists, else the detection argmax, else the
/// default. The dual decode's winner feeds the session evidence, so a
/// consistently-Spanish meeting converges to an es prior — without ever
/// locking out a decisive opposite detection (mixed meetings stay
/// per-window; alternating languages per window IS the correct output).
///
/// History: the SP-005 hysteresis tracker let backchannel lock a session to
/// English (2026-08-04 covert translation); its pure per-window replacement
/// then trusted any detection above 0.5 — and a 2026-08-05 field meeting
/// showed Whisper reporting en@~0.5–0.8 on Spanish audio, producing FLUENT
/// per-window translations whose healthy logprobs never quality-flagged.
/// The decisive/uncertain split is what closes that band.
nonisolated struct FinalPassLanguageTracker: Sendable {

    /// Decode language while no evidence has ever arrived.
    static let defaultLanguage = "en"

    /// Detection probability at which a window decides itself ALONE — no
    /// dual decode. High on purpose: below it the detection is a hint, not a
    /// verdict, and the field evidence shows Whisper reporting the wrong
    /// language in the 0.5–0.8 band on real meeting audio. Tuned against the
    /// mixed-language fixtures (ADR-020 follow-up).
    static let decisiveConfidence: Float = 0.8

    /// Minimum probability for a detection to count as language *evidence*
    /// at all — below it the argmax is noise and may not even pick the
    /// uncertain primary (majority of the model's probability mass: the
    /// detected language beats every other language combined).
    static let confidenceFloor: Float = 0.5

    /// The most recent decisive detection or dual-decode winner — a prior
    /// for uncertain windows, never an override of a decisive one.
    private(set) var sessionLanguage: String?

    /// One window's language decision.
    struct Decision: Equatable, Sendable {
        /// The prompt-carrying primary decode's language.
        let language: String
        /// False = language-uncertain: the window must dual-decode both
        /// whitelist languages and keep the better mean logprob, whatever
        /// the quality flags say.
        let isDecisive: Bool
    }

    /// The decision for this window. Pure over (state, detection,
    /// probabilities) — the FinalPassLanguageTests tables drive exactly this.
    mutating func decodeLanguage(
        detection: String?,
        probabilities: [String: Float]
    ) -> Decision {
        let whitelisted = detection.flatMap { candidate in
            TranscriptionPipeline.allowedTranscriptionLanguages.contains(candidate) ? candidate : nil
        }
        let probability = whitelisted.map { probabilities[$0, default: 0] } ?? 0

        if let whitelisted, probability >= Self.decisiveConfidence {
            sessionLanguage = whitelisted
            return Decision(language: whitelisted, isDecisive: true)
        }
        // Uncertain: the session prior picks the primary; the A/B winner —
        // not this hint — is what may move the session evidence.
        if let sessionLanguage {
            return Decision(language: sessionLanguage, isDecisive: false)
        }
        if let whitelisted, probability >= Self.confidenceFloor {
            return Decision(language: whitelisted, isDecisive: false)
        }
        return Decision(language: Self.defaultLanguage, isDecisive: false)
    }

    /// The dual decode's kept language is real evidence of what the meeting
    /// sounds like — feeding it back converges the prior without re-creating
    /// the session lock (decisive windows still decide alone). Whitelist
    /// languages only, defensively: the wiring can never hand anything else.
    mutating func noteABWinner(_ language: String) {
        guard TranscriptionPipeline.allowedTranscriptionLanguages.contains(language) else { return }
        sessionLanguage = language
    }
}
