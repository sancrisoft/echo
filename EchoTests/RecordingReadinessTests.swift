//
//  RecordingReadinessTests.swift
//  EchoTests
//
//  The executable form of SP-003's "the record button never lies" criterion
//  (ADR-009, Testing Decisions layer 2): a speech-model sub-state goes in and
//  "recording permitted / blocked with a sub-state-accurate message" comes out.
//  Table-driven over every `SpeechModelState` case, the way the SP-001 mode
//  machine (`EchoHandlingModeTests`) made "no event stops a recording" testable.
//

import Testing
@testable import Echo

struct RecordingReadinessTests {

    // MARK: Tracer — a loaded model records

    @Test func readyModelPermitsRecording() {
        #expect(RecordingGateDecision.decide(.ready) == .record)
    }

    // MARK: Downloading — blocked, message reflects the percent

    @Test func downloadingModelBlocksWithPercentInMessage() {
        let decision = RecordingGateDecision.decide(.downloading(0.42))
        #expect(decision.isBlocked)
        // The percent comes from the same clamped projection the bars use
        // (ADR-007), so 0.42 reads as 42 — never a raw, unbounded number.
        #expect(decision.message?.contains("42") == true)
    }

    // MARK: Loading — blocked with a "preparing" message (the closed hole)

    @Test func loadingModelBlocksWhilePreparing() {
        let decision = RecordingGateDecision.decide(.loading)
        #expect(decision != .record)
        #expect(decision.message?.localizedCaseInsensitiveContains("preparing") == true)
    }

    // MARK: Failed — blocked with an actionable retry message (the other hole)

    @Test func failedModelBlocksWithRetryMessage() {
        let decision = RecordingGateDecision.decide(.failed("disk full"))
        #expect(decision != .record)
        // Not-ready + an explicit retry cue — never a recording state, never a
        // silent hang (SP-003 Reliability).
        let message = decision.message ?? ""
        #expect(message.localizedCaseInsensitiveContains("retry"))
        #expect(message.localizedCaseInsensitiveContains("ready"))
    }

    // MARK: Exhaustive — only .ready records; every other sub-state blocks

    @Test(arguments: [
        SpeechModelState.downloading(0),
        .downloading(0.5),
        .downloading(1),
        .loading,
        .failed(""),
        .failed("network lost"),
    ] as [SpeechModelState])
    func everyNotReadyStateBlocks(state: SpeechModelState) {
        let decision = RecordingGateDecision.decide(state)
        #expect(decision.isBlocked)
        #expect(decision != .record)
        // A blocked decision always carries a non-empty message to show.
        #expect(decision.message?.isEmpty == false)
    }

    @Test func onlyReadyRecords() {
        #expect(RecordingGateDecision.decide(.ready) == .record)
        #expect(!RecordingGateDecision.decide(.ready).isBlocked)
    }
}
