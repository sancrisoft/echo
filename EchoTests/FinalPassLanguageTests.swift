//
//  FinalPassLanguageTests.swift
//  EchoTests
//
//  SP-005 S3: session-informed per-window language with hysteresis. The
//  binding requirement is "audio never discarded for language reasons" —
//  every table row returns a decode language; no input ever means "skip the
//  window". Hysteresis (N=2 consecutive windows to switch) lets genuinely
//  mixed es/en meetings switch while single-window flickers don't.
//

import Testing
@testable import Echo

@Suite("FinalPassLanguageTracker")
struct FinalPassLanguageTests {

    /// Runs a detection sequence through one tracker, collecting the decode
    /// language chosen for each window.
    private func decodeLanguages(for detections: [String?]) -> [String] {
        var tracker = FinalPassLanguageTracker()
        return detections.map { tracker.decodeLanguage(forDetection: $0) }
    }

    @Test("undecided sessions decode in the default language, never skip")
    func undecidedFallsBackToDefault() {
        // Failed detection and out-of-whitelist detection, before any
        // confident evidence: the window still decodes, in English.
        #expect(decodeLanguages(for: [nil]) == ["en"])
        #expect(decodeLanguages(for: ["de"]) == ["en"])
        #expect(decodeLanguages(for: ["de", "fr", nil]) == ["en", "en", "en"])
    }

    @Test("the first confident in-whitelist detection sets the session language")
    func firstConfidentDetectionSetsSession() {
        #expect(decodeLanguages(for: ["es"]) == ["es"])
        // Out-of-whitelist noise before it doesn't lock the session to "en".
        #expect(decodeLanguages(for: ["de", "es"]) == ["en", "es"])
    }

    @Test("failed and out-of-whitelist detections keep the session language")
    func noisyDetectionsKeepSession() {
        #expect(decodeLanguages(for: ["es", nil, "de", nil]) == ["es", "es", "es", "es"])
    }

    @Test("a single-window flicker does not switch the session")
    func singleWindowFlickerDoesNotSwitch() {
        #expect(decodeLanguages(for: ["es", "en", "es", "es"]) == ["es", "es", "es", "es"])
    }

    @Test("two consecutive differing detections switch the session (mixed meetings)")
    func consecutiveDetectionsSwitch() {
        #expect(decodeLanguages(for: ["es", "en", "en", "en"]) == ["es", "es", "en", "en"])
    }

    @Test("switching works in both directions across a meeting")
    func mixedMeetingSwitchesBothWays() {
        let sequence: [String?] = ["en", "en", "es", "es", "es", "en", "en"]
        #expect(decodeLanguages(for: sequence) == ["en", "en", "en", "es", "es", "es", "en"])
    }

    @Test("an interruption breaks the switch streak — consecutive means consecutive")
    func interruptionBreaksTheStreak() {
        // "de" between the two "en" windows resets the pending switch; only
        // the later back-to-back pair flips the session.
        let sequence: [String?] = ["es", "en", "de", "en", "en"]
        #expect(decodeLanguages(for: sequence) == ["es", "es", "es", "es", "en"])
    }

    @Test("a matching detection also resets a pending switch")
    func matchingDetectionResetsPendingSwitch() {
        // es, en(pending), es(reset), en(pending again), en(switch)
        let sequence: [String?] = ["es", "en", "es", "en", "en"]
        #expect(decodeLanguages(for: sequence) == ["es", "es", "es", "es", "en"])
    }

    @Test("a flicker after a switch does not whipsaw back")
    func flickerAfterSwitchDoesNotRevert() {
        let sequence: [String?] = ["es", "en", "en", "es", "en"]
        #expect(decodeLanguages(for: sequence) == ["es", "es", "en", "en", "en"])
    }

    @Test("the switch streak is two consecutive windows")
    func switchStreakIsTwo() {
        #expect(FinalPassLanguageTracker.switchStreak == 2)
    }
}
