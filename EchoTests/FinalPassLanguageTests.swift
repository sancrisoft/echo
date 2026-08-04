//
//  FinalPassLanguageTests.swift
//  EchoTests
//
//  SP-007 (ADR-020): final-pass language is decided per window on voiced
//  evidence — no session lock. A confident in-whitelist detection decides its
//  own window and becomes the session fallback; everything else (failed,
//  out-of-whitelist, below-floor detections) falls back to the most recent
//  confident language, default "en". The SP-005 hysteresis (two-window switch
//  streak) is deliberately retired: on a backchannel-dominated channel it
//  locked the whole session to English and made Whisper *translate* the
//  user's Spanish (the 2026-08-04 covert-translation failure).
//

import Testing
@testable import Echo

@Suite("FinalPassLanguageTracker (ADR-020 per-window policy)")
struct FinalPassLanguageTests {

    /// Runs a per-window detection sequence (language + its detection
    /// probability) through one tracker, collecting each window's decode
    /// language — the pure function the tables drive.
    private func decodeLanguages(
        for detections: [(language: String?, probability: Float)]
    ) -> [String] {
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

    /// The motivating row: a microphone channel dominated by English
    /// backchannel, then a full Spanish sentence. The old hysteresis locked
    /// "en" and translated it; per-window, the confident es detection decides
    /// its own window — and the next English window flips right back.
    @Test("a confident Spanish window decodes Spanish on an English-dominated channel")
    func confidentSpanishWinsOnEnglishHistory() {
        let sequence: [(String?, Float)] = [
            ("en", 0.9), ("en", 0.85), ("es", 0.95), ("en", 0.9),
        ]
        #expect(decodeLanguages(for: sequence) == ["en", "en", "es", "en"])
    }

    @Test("alternating confident detections alternate the decode — whipsaw IS correct per-window")
    func alternatingDetectionsAlternate() {
        let sequence: [(String?, Float)] = [
            ("es", 0.9), ("en", 0.9), ("es", 0.9), ("en", 0.9),
        ]
        #expect(decodeLanguages(for: sequence) == ["es", "en", "es", "en"])
    }

    @Test("no detection falls back to the session language, default English")
    func noDetectionFallsBack() {
        #expect(decodeLanguages(for: [(nil, 0)]) == ["en"])
        #expect(decodeLanguages(for: [("es", 0.9), (nil, 0), (nil, 0)]) == ["es", "es", "es"])
    }

    @Test("a below-floor detection is not evidence — the window falls back")
    func belowFloorFallsBack() {
        let sequence: [(String?, Float)] = [("es", 0.9), ("en", 0.3)]
        #expect(decodeLanguages(for: sequence) == ["es", "es"])
    }

    @Test("a below-floor detection never updates the session fallback")
    func belowFloorNeverUpdatesSession() {
        let sequence: [(String?, Float)] = [("es", 0.9), ("en", 0.3), (nil, 0)]
        #expect(decodeLanguages(for: sequence) == ["es", "es", "es"])
    }

    @Test("out-of-whitelist detections fall back however confident they are")
    func outOfWhitelistFallsBack() {
        #expect(decodeLanguages(for: [("de", 0.99)]) == ["en"])
        #expect(decodeLanguages(for: [("es", 0.9), ("de", 0.99)]) == ["es", "es"])
    }

    @Test("each confident detection updates the session fallback for later undetectable windows")
    func confidentDetectionUpdatesFallback() {
        let sequence: [(String?, Float)] = [("es", 0.9), ("en", 0.8), (nil, 0)]
        #expect(decodeLanguages(for: sequence) == ["es", "en", "en"])
    }

    @Test("a detection exactly at the floor counts as confident")
    func floorBoundaryIsConfident() {
        let atFloor: [(String?, Float)] = [("es", FinalPassLanguageTracker.confidenceFloor)]
        #expect(decodeLanguages(for: atFloor) == ["es"])
    }

    @Test("the default language is English and the floor is majority probability mass")
    func constants() {
        #expect(FinalPassLanguageTracker.defaultLanguage == "en")
        #expect(FinalPassLanguageTracker.confidenceFloor == 0.5)
    }
}
