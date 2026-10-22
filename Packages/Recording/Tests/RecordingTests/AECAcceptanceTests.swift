//
//  AECAcceptanceTests.swift
//  RecordingTests
//
//  The echo-cancellation Success Criteria scenarios end-to-end — fixture
//  audio → `SwitchingAECStage` → the Parakeet pass — asserting on the
//  transcribed segments per channel. This suite is the executable definition
//  of done for echo cancellation, and the transcript-level layer above
//  `AudioTests`' signal-level one: strip the transcription and no assertion
//  is left, which is exactly why it lives in Recording (it needs Audio and
//  Transcription at once, and no package below sees both).
//
//  Slow: it loads the Parakeet model (which must already be on disk — the
//  suite never downloads), so it carries `.acceptance` in addition to a
//  per-test gate on the recorded fixtures. See Fixtures/README.md for the
//  exact invocation.
//

import Audio
import EchoCore
import EchoCoreTestSupport
import Foundation
import Testing
import Transcription

@testable import Recording

@Suite(.serialized, .acceptance)
struct AECAcceptanceTests {

    /// Convergence grace at the start of playback.
    private static let convergenceGrace: TimeInterval = 10

    // MARK: - Harness

    /// Replays a fixture pair through the production audio path at full
    /// speed: read-only far-end copy + Team retention, mic through the stage,
    /// interleaved at the 10 ms capture cadence. The processed samples are
    /// exactly what retention would have written, so transcribing them is
    /// what the real meeting's pass would see.
    private func transcribe(
        mic: [Float],
        system: [Float],
        mode: EchoHandlingMode
    ) async throws -> [TranscriptSegment] {
        let stage = SwitchingAECStage(engineStage: WebRTCAECStage(), mode: mode)
        var retainedMic: [Float] = []
        var retainedSystem: [Float] = []

        let chunk = AECFixtureRunner.chunkSize
        var offset = 0
        let total = max(mic.count, system.count)
        while offset < total {
            if offset < system.count {
                let far = Array(system[offset..<min(offset + chunk, system.count)])
                stage.feedFarEnd(far)
                retainedSystem += far
            }
            if offset < mic.count {
                retainedMic += stage.processMicSamples(
                    Array(mic[offset..<min(offset + chunk, mic.count)])
                )
            }
            offset += chunk
        }
        return try await RecordingAcceptanceSupport.transcribe(
            [.microphone: retainedMic, .system: retainedSystem]
        )
    }

    private static func words(_ text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    /// Fraction of `needle`'s words present in `haystack` (multiset
    /// containment) — the fuzzy-containment measure that absorbs normal
    /// decoder wording variance between two runs.
    private static func containment(of needle: [String], in haystack: [String]) -> Double {
        guard !needle.isEmpty else { return 1 }
        var pool: [String: Int] = [:]
        for word in haystack { pool[word, default: 0] += 1 }
        var found = 0
        for word in needle where (pool[word] ?? 0) > 0 {
            pool[word, default: 0] -= 1
            found += 1
        }
        return Double(found) / Double(needle.count)
    }

    // MARK: - Speaker-bleed scenario

    @Test(.enabled(if: Fixtures.available("bleed-only"), Comment(rawValue: Fixtures.instructions)))
    func bleedOnlyYieldsNoMicSegmentsAfterGrace() async throws {
        let pair = try RecordingAcceptanceSupport.loadPair("bleed-only")
        let segments = try await transcribe(mic: pair.mic, system: pair.system, mode: .cancelling)

        // Sanity: the Team channel actually transcribed the playback —
        // otherwise a broken fixture (or failed model load) passes vacuously.
        try #require(
            segments.contains { $0.channel == .system },
            "no Team segments: fixture playback or model load is broken"
        )

        // Tolerance: at most one stray of at most 3 words per 5 min; fixtures
        // are ≤ 60 s, so at most one stray total after the grace.
        let strays = segments.filter { $0.channel == .microphone && $0.start >= Self.convergenceGrace }
        #expect(strays.count <= 1, "You-channel segments from speaker bleed: \(strays.map(\.text))")
        if let stray = strays.first {
            #expect(Self.words(stray.text).count <= 3, "stray segment exceeds 3 words: \"\(stray.text)\"")
        }
    }

    // MARK: - Double-talk scenario (baseline-relative)

    @Test(
        .enabled(
            if: Fixtures.available("double-talk") && Fixtures.available("double-talk-baseline"),
            Comment(rawValue: Fixtures.instructions)
        )
    )
    func doubleTalkKeepsEveryBaselineUserUtterance() async throws {
        // Headphones baseline (echo processing bypassed) defines what the
        // model can hear at all — its miss rate is not charged to AEC.
        let baselinePair = try RecordingAcceptanceSupport.loadPair("double-talk-baseline")
        let baseline = try await transcribe(
            mic: baselinePair.mic,
            system: baselinePair.system,
            mode: .bypassed
        )
        let baselineUtterances = baseline.filter { $0.channel == .microphone }
        try #require(
            !baselineUtterances.isEmpty,
            "headphones baseline produced no You segments: fixture or model load is broken"
        )

        let pair = try RecordingAcceptanceSupport.loadPair("double-talk")
        let cancelled = try await transcribe(mic: pair.mic, system: pair.system, mode: .cancelling)
        let youPool = Self.words(
            cancelled.filter { $0.channel == .microphone }.map(\.text).joined(separator: " ")
        )

        for utterance in baselineUtterances {
            let ratio = Self.containment(of: Self.words(utterance.text), in: youPool)
            // Tunable fuzzy floor: full word-for-word equality would charge
            // the decoder's own variance to the feature.
            #expect(
                ratio >= 0.7,
                "utterance suppressed under cancellation: \"\(utterance.text)\" (containment \(ratio))"
            )
        }
    }

    // MARK: - No collateral damage (Team channel unchanged)

    @Test(.enabled(if: Fixtures.available("double-talk"), Comment(rawValue: Fixtures.instructions)))
    func teamChannelIsEquivalentWithAndWithoutCancellation() async throws {
        let pair = try RecordingAcceptanceSupport.loadPair("double-talk")

        let withAEC = try await transcribe(mic: pair.mic, system: pair.system, mode: .cancelling)
            .filter { $0.channel == .system }
        let withoutAEC = try await transcribe(mic: pair.mic, system: pair.system, mode: .bypassed)
            .filter { $0.channel == .system }

        try #require(
            !withoutAEC.isEmpty,
            "baseline run produced no Team segments: fixture or model load is broken"
        )

        // The far-end reference is a read-only copy, so the Team ingest path
        // is byte-identical in both runs; require near-total bidirectional
        // text overlap (tunable margin for residual decoder nondeterminism).
        let onWords = Self.words(withAEC.map(\.text).joined(separator: " "))
        let offWords = Self.words(withoutAEC.map(\.text).joined(separator: " "))
        #expect(
            Self.containment(of: offWords, in: onWords) >= 0.9,
            "Team content lost with AEC active: \(withoutAEC.map(\.text)) vs \(withAEC.map(\.text))"
        )
        #expect(
            Self.containment(of: onWords, in: offWords) >= 0.9,
            "Team content hallucinated with AEC active: \(withAEC.map(\.text)) vs \(withoutAEC.map(\.text))"
        )
    }
}
