//
//  AECAcceptanceTests.swift
//  EchoTests
//
//  S5 acceptance suite (SP-001 test layer 4): the Success Criteria scenarios
//  end-to-end — fixture audio → SwitchingAECStage → TranscriptionPipeline →
//  RecordingState (transcript dedup included) — asserting on the emitted
//  transcript segments per channel. This suite is the executable definition
//  of done for SP-001.
//
//  Slow: it loads WhisperKit large-v3, so it is gated on ECHO_ACCEPTANCE=1
//  in addition to the recorded fixtures. See EchoTests/Fixtures/README.md
//  for the exact invocation.
//

import Foundation
import Testing
@testable import Echo

nonisolated enum Acceptance {

    static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["ECHO_ACCEPTANCE"] == "1"
    }

    static let gate: Comment = """
    Slow WhisperKit suite — run on demand with \
    TEST_RUNNER_ECHO_ACCEPTANCE=1 xcodebuild test -project Echo.xcodeproj \
    -scheme Echo -destination 'platform=macOS' (see EchoTests/Fixtures/README.md)
    """

    /// One pipeline for the whole suite so the (heavy) model loads once.
    static let pipeline = TranscriptionPipeline()
}

@Suite(.serialized, .enabled(if: Acceptance.isEnabled, Acceptance.gate))
struct AECAcceptanceTests {

    /// SP-001: convergence grace at the start of playback.
    private static let convergenceGrace: TimeInterval = 10

    // MARK: - Harness

    /// Replays a fixture pair through the production audio path at full
    /// speed: read-only far-end copy + Team ingest, mic through the stage,
    /// interleaved at the 10 ms capture cadence.
    private func transcribe(
        mic: [Float],
        system: [Float],
        mode: EchoHandlingMode
    ) async throws -> [TranscriptSegment] {
        let state = RecordingState()
        let stage = SwitchingAECStage(engineStage: WebRTCAECStage(), mode: mode)
        await Acceptance.pipeline.start(appendingTo: state)

        let chunk = AECFixtureRunner.chunkSize
        var offset = 0
        let total = max(mic.count, system.count)
        while offset < total {
            if offset < system.count {
                let far = Array(system[offset ..< min(offset + chunk, system.count)])
                stage.feedFarEnd(far)
                await Acceptance.pipeline.ingest(far, from: .system)
            }
            if offset < mic.count {
                let near = stage.processMicSamples(Array(mic[offset ..< min(offset + chunk, mic.count)]))
                await Acceptance.pipeline.ingest(near, from: .microphone)
            }
            offset += chunk
        }
        await Acceptance.pipeline.stop()
        return state.segments
    }

    private nonisolated static func words(_ text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    /// Fraction of `needle`'s words present in `haystack` (multiset
    /// containment) — the fuzzy-containment measure that absorbs normal
    /// Whisper wording variance between two runs.
    private nonisolated static func containment(of needle: [String], in haystack: [String]) -> Double {
        guard !needle.isEmpty else { return 1 }
        var pool: [String: Int] = [:]
        for word in haystack { pool[word, default: 0] += 1 }
        var found = 0
        for word in needle where (pool[word] ?? 0) > 0 {
            pool[word]! -= 1
            found += 1
        }
        return Double(found) / Double(needle.count)
    }

    // MARK: - Speaker-bleed scenario

    @Test(.enabled(if: Fixtures.available("bleed-only"), Fixtures.instructions))
    func bleedOnlyYieldsNoMicSegmentsAfterGrace() async throws {
        let pair = try Fixtures.load("bleed-only")
        let segments = try await transcribe(mic: pair.mic, system: pair.system, mode: .cancelling)

        // Sanity: the Team channel actually transcribed the playback —
        // otherwise a broken fixture (or failed model load) passes vacuously.
        try #require(
            segments.contains { $0.channel == .system },
            "no Team segments: fixture playback or model load is broken"
        )

        // SP-001 tolerance: at most one stray of at most 3 words per 5 min;
        // fixtures are ≤ 60 s, so at most one stray total after the grace.
        let strays = segments.filter { $0.channel == .microphone && $0.start >= Self.convergenceGrace }
        #expect(strays.count <= 1, "You-channel segments from speaker bleed: \(strays.map(\.text))")
        if let stray = strays.first {
            #expect(Self.words(stray.text).count <= 3, "stray segment exceeds 3 words: \"\(stray.text)\"")
        }
    }

    // MARK: - Double-talk scenario (baseline-relative, per SP-001)

    @Test(.enabled(
        if: Fixtures.available("double-talk") && Fixtures.available("double-talk-baseline"),
        Fixtures.instructions
    ))
    func doubleTalkKeepsEveryBaselineUserUtterance() async throws {
        // Headphones baseline (echo processing bypassed) defines what
        // Whisper can hear at all — its miss rate is not charged to AEC.
        let baselinePair = try Fixtures.load("double-talk-baseline")
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

        let pair = try Fixtures.load("double-talk")
        let cancelled = try await transcribe(mic: pair.mic, system: pair.system, mode: .cancelling)
        let youPool = Self.words(
            cancelled.filter { $0.channel == .microphone }.map(\.text).joined(separator: " ")
        )

        for utterance in baselineUtterances {
            let ratio = Self.containment(of: Self.words(utterance.text), in: youPool)
            // Tunable fuzzy floor: full word-for-word equality would charge
            // Whisper's own variance to the feature.
            #expect(
                ratio >= 0.7,
                "utterance suppressed under cancellation: \"\(utterance.text)\" (containment \(ratio))"
            )
        }
    }

    // MARK: - No collateral damage (Team channel unchanged)

    @Test(.enabled(if: Fixtures.available("double-talk"), Fixtures.instructions))
    func teamChannelIsEquivalentWithAndWithoutCancellation() async throws {
        let pair = try Fixtures.load("double-talk")

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
        // text overlap (tunable margin for residual Whisper nondeterminism).
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
