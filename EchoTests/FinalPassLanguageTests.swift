//
//  FinalPassLanguageTests.swift
//  EchoTests
//
//  SP-007 (ADR-020): final-pass language is decided per window on voiced
//  evidence — no session lock. A DECISIVE in-whitelist detection decides its
//  own window alone and becomes the session fallback. Everything below the
//  decisive floor is language-UNCERTAIN: the window dual-decodes both
//  whitelist languages and keeps the better mean logprob (the uncertain
//  primary carries the prompt chain in the session language when one exists,
//  else the detection argmax, else the default).
//
//  The uncertainty band exists because of the 2026-08-05 field report: on
//  Spanish system audio Whisper reported "en" just above the old 0.5
//  confidence floor, the window decoded as English, and the FLUENT covert
//  translation had healthy logprobs — so the quality-flag A/B never fired.
//  Per-window trust without a decisive floor just replaced the session lock
//  with per-window flip-flops.
//

import Testing
@testable import Echo

@Suite("FinalPassLanguageTracker (ADR-020 per-window policy + uncertainty backstop)")
struct FinalPassLanguageTests {

    private typealias Detection = (language: String?, probability: Float)

    /// Runs a per-window detection sequence through one tracker, collecting
    /// each window's decision — the pure function the tables drive.
    private func decisions(
        for detections: [Detection]
    ) -> [FinalPassLanguageTracker.Decision] {
        var tracker = FinalPassLanguageTracker()
        return detections.map { detection in
            var probabilities: [String: Float] = [:]
            if let language = detection.language {
                probabilities[language] = detection.probability
            }
            return tracker.decodeLanguage(
                detection: detection.language,
                probabilities: probabilities
            )
        }
    }

    private func languages(for detections: [Detection]) -> [String] {
        decisions(for: detections).map(\.language)
    }

    /// The field-report row: en@0.55 is not decisive evidence — the window is
    /// language-uncertain and must dual-decode instead of trusting the
    /// detection alone.
    @Test("a detection below the decisive floor is language-uncertain")
    func belowDecisiveIsUncertain() {
        let result = decisions(for: [("en", 0.55)])
        #expect(result == [.init(language: "en", isDecisive: false)])
    }

    @Test("a decisive detection decides its own window alone")
    func decisiveDecidesAlone() {
        #expect(decisions(for: [("en", 0.9)]) == [.init(language: "en", isDecisive: true)])
        #expect(decisions(for: [("es", 0.95)]) == [.init(language: "es", isDecisive: true)])
    }

    @Test("a detection exactly at the decisive floor is decisive")
    func decisiveBoundaryIsDecisive() {
        let atFloor: [Detection] = [("es", FinalPassLanguageTracker.decisiveConfidence)]
        #expect(decisions(for: atFloor) == [.init(language: "es", isDecisive: true)])
    }

    /// The hard requirement: mixed meetings stay per-window — a confident
    /// opposite-language detection wins its own window whatever the session
    /// prior says.
    @Test("a decisive opposite-language detection wins its window against the session prior")
    func decisiveOppositeLanguageBeatsSessionPrior() {
        let sequence: [Detection] = [("es", 0.85), ("es", 0.9), ("en", 0.9)]
        #expect(decisions(for: sequence) == [
            .init(language: "es", isDecisive: true),
            .init(language: "es", isDecisive: true),
            .init(language: "en", isDecisive: true),
        ])
    }

    @Test("alternating decisive windows decode alternately — no A/B, no lock")
    func mixedMeetingAlternatesDecisively() {
        let sequence: [Detection] = [("es", 0.9), ("en", 0.85), ("es", 0.95), ("en", 0.9)]
        let result = decisions(for: sequence)
        #expect(result.map(\.language) == ["es", "en", "es", "en"])
        #expect(result.allSatisfy { $0.isDecisive })
    }

    /// The session prior steers only the UNCERTAIN primary (which decode
    /// carries the prompt chain) — the dual decode still decides the window.
    @Test("an uncertain window with a session prior uses it as the primary")
    func uncertainUsesSessionPrimary() {
        let sequence: [Detection] = [("es", 0.9), ("en", 0.55)]
        #expect(decisions(for: sequence) == [
            .init(language: "es", isDecisive: true),
            .init(language: "es", isDecisive: false),
        ])
    }

    @Test("the session prior outranks the detection argmax for the uncertain primary")
    func sessionOutranksArgmax() {
        // en@0.7 is real evidence, but the primary follows the es session —
        // the alternate decode is where the en hypothesis gets its shot.
        let sequence: [Detection] = [("es", 0.9), ("en", 0.7)]
        #expect(languages(for: sequence) == ["es", "es"])
    }

    @Test("an uncertain window with no session falls back to the detection argmax")
    func uncertainNoSessionUsesArgmax() {
        #expect(decisions(for: [("es", 0.6)]) == [.init(language: "es", isDecisive: false)])
    }

    @Test("a detection below the evidence floor is noise — the default primary stands")
    func belowEvidenceFloorUsesDefault() {
        #expect(decisions(for: [("es", 0.3)]) == [.init(language: "en", isDecisive: false)])
    }

    @Test("no detection is maximally uncertain — session (or default) primary, dual decode")
    func noDetectionIsUncertain() {
        #expect(decisions(for: [(nil, 0)]) == [.init(language: "en", isDecisive: false)])
        #expect(decisions(for: [("es", 0.9), (nil, 0)]) == [
            .init(language: "es", isDecisive: true),
            .init(language: "es", isDecisive: false),
        ])
    }

    @Test("out-of-whitelist detections are uncertain however confident")
    func outOfWhitelistIsUncertain() {
        #expect(decisions(for: [("de", 0.99)]) == [.init(language: "en", isDecisive: false)])
    }

    @Test("a decisive detection updates the session fallback for later windows")
    func decisiveUpdatesSession() {
        let sequence: [Detection] = [("es", 0.9), ("en", 0.55), (nil, 0)]
        #expect(languages(for: sequence) == ["es", "es", "es"])
    }

    @Test("an uncertain detection never updates the session by itself")
    func uncertainDoesNotUpdateSession() {
        // en@0.55 must not shift the prior — only its A/B winner may.
        let sequence: [Detection] = [("es", 0.9), ("en", 0.55), (nil, 0)]
        #expect(languages(for: sequence).last == "es")
    }

    /// A consistently-Spanish meeting converges: the dual decode keeps
    /// winning in es and each winner feeds the prior — without ever locking
    /// out a decisive opposite detection.
    @Test("an A/B winner updates the session evidence")
    func abWinnerUpdatesSession() {
        var tracker = FinalPassLanguageTracker()
        let first = tracker.decodeLanguage(detection: "en", probabilities: ["en": 0.55])
        #expect(first == .init(language: "en", isDecisive: false))

        tracker.noteABWinner("es")

        let next = tracker.decodeLanguage(detection: nil, probabilities: [:])
        #expect(next == .init(language: "es", isDecisive: false))
    }

    @Test("an out-of-whitelist A/B winner is impossible and ignored defensively")
    func abWinnerRejectsOutOfWhitelist() {
        var tracker = FinalPassLanguageTracker()
        tracker.noteABWinner("de")
        #expect(tracker.decodeLanguage(detection: nil, probabilities: [:]).language == "en")
    }

    @Test("the floors and default hold their calibrated values")
    func constants() {
        #expect(FinalPassLanguageTracker.defaultLanguage == "en")
        #expect(FinalPassLanguageTracker.decisiveConfidence == 0.8)
        #expect(FinalPassLanguageTracker.confidenceFloor == 0.5)
        #expect(FinalPassLanguageTracker.decisiveConfidence > FinalPassLanguageTracker.confidenceFloor)
    }

    // MARK: - Log-probability units (2026-08-05 second field report)

    /// The pinned WhisperKit's `detectLangauge` reports LOG probabilities
    /// (TextDecoder.detectLanguage stores the sampler's log-softmax values —
    /// verified in source, and measured on the kept fixture: es@-0.00,
    /// en@-0.14, en@-1.20). Compared raw against the linear floors, every
    /// value is below 0.5 — so nothing was ever decisive and every window
    /// dual-decoded. The conversion is the tracker's, so no caller can make
    /// that unit mistake again.
    @Test("log probabilities convert to linear before the floors compare")
    func logProbabilitiesConvert() {
        let linear = FinalPassLanguageTracker.linearProbabilities(
            fromLogProbabilities: ["es": -0.001, "en": -1.20]
        )
        #expect(abs((linear["es"] ?? 0) - 0.999) < 0.001)
        #expect(abs((linear["en"] ?? 0) - 0.301) < 0.001)
    }

    @Test("a positive log probability clamps to certainty instead of exceeding it")
    func positiveLogProbClamps() {
        let linear = FinalPassLanguageTracker.linearProbabilities(
            fromLogProbabilities: ["es": 0.3]
        )
        #expect(linear["es"] == 1.0)
    }

    /// The fixture's measured detections, end to end: es@log(-0.00) must be
    /// decisive; en@log(-1.20) must not be.
    @Test("the fixture's measured log detections decide correctly after conversion")
    func fixtureDetectionsDecideCorrectly() {
        var tracker = FinalPassLanguageTracker()
        let decisive = tracker.decodeLanguage(
            detection: "es",
            probabilities: FinalPassLanguageTracker.linearProbabilities(
                fromLogProbabilities: ["es": -0.001]
            )
        )
        #expect(decisive == .init(language: "es", isDecisive: true))

        let uncertain = tracker.decodeLanguage(
            detection: "en",
            probabilities: FinalPassLanguageTracker.linearProbabilities(
                fromLogProbabilities: ["en": -1.20]
            )
        )
        #expect(uncertain == .init(language: "es", isDecisive: false))
    }
}
