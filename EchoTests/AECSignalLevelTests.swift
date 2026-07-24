//
//  AECSignalLevelTests.swift
//  EchoTests
//
//  S5 signal-level tests (SP-001 test layer 1): fixture pairs through the
//  real AEC engine, asserting post-cancellation energy against the
//  pipeline's speech gates. Fast — no WhisperKit. Every test here skips
//  with recording instructions until the fixture set exists; thresholds are
//  the spec's starting points and get calibrated against the real fixtures.
//

import Foundation
import Testing
@testable import Echo

struct AECSignalLevelTests {

    /// SP-001: convergence grace at the start of playback.
    private static let convergenceGraceSeconds = 10.0
    private static let windowSamples = Int(AudioConstants.sampleRate)   // 1 s

    /// Scripted double-talk utterance spans, in seconds from take start.
    /// Must match the script timing in EchoTests/Fixtures/README.md.
    private static let doubleTalkSpans: [(start: Double, end: Double)] = [
        (12, 16), (18, 22), (24, 28),
    ]

    /// Runs a fixture through the production stage arrangement in cancelling
    /// mode. The bypassed baseline is `pair.mic` itself: SwitchingAECStage's
    /// pass-through is bit-identical (proven in SwitchingAECStageTests).
    private func cancelled(_ scenario: String) throws -> (cleaned: [Float], raw: [Float]) {
        let pair = try Fixtures.load(scenario)
        let stage = SwitchingAECStage(engineStage: WebRTCAECStage(), mode: .cancelling)
        let cleaned = AECFixtureRunner.process(mic: pair.mic, system: pair.system, through: stage)
        return (cleaned, pair.mic)
    }

    // MARK: - Bleed-only (SP-001 speaker-bleed criterion, signal level)

    @Test(.enabled(if: Fixtures.available("bleed-only"), Fixtures.instructions))
    func bleedOnlyResidualFallsBelowSpeechGatesAfterConvergence() throws {
        let (cleaned, _) = try cancelled("bleed-only")

        let graceSamples = Int(Self.convergenceGraceSeconds * AudioConstants.sampleRate)
        try #require(
            cleaned.count >= graceSamples + Self.windowSamples,
            "bleed-only fixture must be longer than the 10 s convergence grace"
        )

        // Below the pipeline's speech gates == not transcribable: the ingest
        // path drops any chunk with rms < 0.004 || peak < 0.020.
        var violations: [String] = []
        var start = graceSamples
        while start + Self.windowSamples <= cleaned.count {
            let window = cleaned[start ..< start + Self.windowSamples]
            let rms = SignalMetrics.rms(window)
            let peak = SignalMetrics.peak(window)
            if !(rms < 0.004 || peak < 0.020) {
                violations.append("t=\(start / Int(AudioConstants.sampleRate))s rms=\(rms) peak=\(peak)")
            }
            start += Self.windowSamples
        }
        #expect(violations.isEmpty, "post-AEC windows above the speech gates: \(violations)")
    }

    // MARK: - Double-talk (SP-001: user speech survives cancellation)

    @Test(.enabled(
        if: Fixtures.available("double-talk"),
        Fixtures.instructions
    ))
    func doubleTalkPreservesUserSpeechEnergyDuringScriptedUtterances() throws {
        let (cleaned, raw) = try cancelled("double-talk")

        for span in Self.doubleTalkSpans {
            let lo = Int(span.start * AudioConstants.sampleRate)
            let hi = min(Int(span.end * AudioConstants.sampleRate), cleaned.count, raw.count)
            try #require(lo < hi, "fixture too short for scripted span \(span.start)–\(span.end)s")

            let rawEnergy = SignalMetrics.energy(raw[lo ..< hi])
            let cleanedEnergy = SignalMetrics.energy(cleaned[lo ..< hi])
            // Conservative preservation floor (tunable, per slice spec): the
            // near-field user voice dominates the raw span energy, so losing
            // more than half of it means cancellation ate user speech, not
            // just bleed.
            #expect(
                cleanedEnergy >= 0.5 * rawEnergy,
                "user speech attenuated in span \(span.start)–\(span.end)s: raw=\(rawEnergy) post-AEC=\(cleanedEnergy)"
            )
        }
    }

    // MARK: - Monologue (SP-001 NFR: silent far end → no material attenuation)

    @Test(.enabled(if: Fixtures.available("monologue"), Fixtures.instructions))
    func monologueWithSilentFarEndIsNotMateriallyAttenuated() throws {
        let (cleaned, raw) = try cancelled("monologue")
        let count = min(cleaned.count, raw.count)
        try #require(count >= Self.windowSamples, "monologue fixture too short")

        // Overall level: near-transparent (the engine runs AEC only — HPF,
        // NS, and AGC are all off in APMEchoCanceller).
        #expect(SignalMetrics.rms(cleaned[..<count]) >= 0.9 * SignalMetrics.rms(raw[..<count]))

        // And no speech-bearing second is selectively suppressed.
        var violations: [String] = []
        var start = 0
        while start + Self.windowSamples <= count {
            let rawRMS = SignalMetrics.rms(raw[start ..< start + Self.windowSamples])
            if rawRMS >= 0.01 {   // window with actual speech in the baseline
                let cleanedRMS = SignalMetrics.rms(cleaned[start ..< start + Self.windowSamples])
                if cleanedRMS < 0.7 * rawRMS {
                    violations.append("t=\(start / Int(AudioConstants.sampleRate))s raw=\(rawRMS) post-AEC=\(cleanedRMS)")
                }
            }
            start += Self.windowSamples
        }
        #expect(violations.isEmpty, "speech windows attenuated with a silent far end: \(violations)")
    }
}
