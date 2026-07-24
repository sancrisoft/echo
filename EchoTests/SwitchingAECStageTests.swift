//
//  SwitchingAECStageTests.swift
//  EchoTests
//
//  Switching-logic tests for S4: mode-driven delegation between the AEC
//  engine and pass-through. Uses a sentinel engine double, not the real
//  engine — these are pure routing tests.
//

import Foundation
import Testing
@testable import Echo

/// Engine stand-in that visibly alters mic samples and records every call,
/// proving which inner stage `SwitchingAECStage` delegated to. A real
/// pass-through could not distinguish "delegated to engine" from
/// "delegated to pass-through".
private final class SentinelEngineStage: AECStage, @unchecked Sendable {

    /// Added to every mic sample so engine delegation is visible in output.
    static let offset: Float = 100

    private let lock = NSLock()
    private var mic: [Float] = []
    private var farEnd: [Float] = []
    private var resets = 0

    var micReceived: [Float] {
        lock.lock()
        defer { lock.unlock() }
        return mic
    }

    var farEndReceived: [Float] {
        lock.lock()
        defer { lock.unlock() }
        return farEnd
    }

    var resetCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return resets
    }

    func processMicSamples(_ samples: [Float]) -> [Float] {
        lock.lock()
        mic.append(contentsOf: samples)
        lock.unlock()
        return samples.map { $0 + Self.offset }
    }

    func feedFarEnd(_ samples: [Float]) {
        lock.lock()
        farEnd.append(contentsOf: samples)
        lock.unlock()
    }

    func reset() {
        lock.lock()
        resets += 1
        lock.unlock()
    }
}

struct SwitchingAECStageTests {

    private let mic: [Float] = [0, 0.25, -0.5, 1, -1, 0.125, -0.0625]
    private let farEnd: [Float] = [0.75, -0.75, 0.5]

    // MARK: - Pass-through modes (SP-001 NFR: bit-identical mic path)

    @Test(arguments: [EchoHandlingMode.bypassed, EchoHandlingMode.dedupOnly])
    func passthroughModesReturnMicSamplesBitIdentical(mode: EchoHandlingMode) {
        let engine = SentinelEngineStage()
        let stage = SwitchingAECStage(engineStage: engine, mode: mode)

        #expect(stage.processMicSamples(mic) == mic)
        #expect(stage.processMicSamples([]) == [])
        #expect(engine.micReceived.isEmpty)
    }

    @Test(arguments: [EchoHandlingMode.bypassed, EchoHandlingMode.dedupOnly])
    func passthroughModesNeverFeedTheEngineFarEnd(mode: EchoHandlingMode) {
        let engine = SentinelEngineStage()
        let stage = SwitchingAECStage(engineStage: engine, mode: mode)

        stage.feedFarEnd(farEnd)
        #expect(engine.farEndReceived.isEmpty)
    }

    // MARK: - Engine-fed modes

    @Test func cancellingDelegatesMicSamplesToTheEngine() {
        let engine = SentinelEngineStage()
        let stage = SwitchingAECStage(engineStage: engine, mode: .cancelling)

        let expected = mic.map { $0 + SentinelEngineStage.offset }
        #expect(stage.processMicSamples(mic) == expected)
        #expect(engine.micReceived == mic)
    }

    @Test func cancellingFeedsFarEndToTheEngine() {
        let engine = SentinelEngineStage()
        let stage = SwitchingAECStage(engineStage: engine, mode: .cancelling)

        stage.feedFarEnd(farEnd)
        #expect(engine.farEndReceived == farEnd)
    }

    @Test func degradedKeepsTheEngineFedSoRecoveryStaysDetectable() {
        // While degraded the engine passes raw audio through internally, but
        // it must keep seeing both streams: it only detects recovery on frame
        // processing, so starving it would make Degraded → Cancelling
        // unreachable.
        let engine = SentinelEngineStage()
        let stage = SwitchingAECStage(engineStage: engine, mode: .degraded)

        _ = stage.processMicSamples(mic)
        stage.feedFarEnd(farEnd)
        #expect(engine.micReceived == mic)
        #expect(engine.farEndReceived == farEnd)
    }

    // MARK: - Mode transitions mid-stream

    @Test func modeFlipsMidStreamDropNoSamples() {
        let engine = SentinelEngineStage()
        let stage = SwitchingAECStage(engineStage: engine, mode: .cancelling)

        var output: [Float] = []
        output += stage.processMicSamples(mic)
        stage.setMode(.bypassed)
        output += stage.processMicSamples(mic)
        stage.setMode(.cancelling)
        output += stage.processMicSamples(mic)

        let altered = mic.map { $0 + SentinelEngineStage.offset }
        #expect(output.count == mic.count * 3)
        #expect(output == altered + mic + altered)
    }

    @Test func reEngagingTheEngineResetsItFirst() {
        // While the engine is not fed, its buffered far-end reference goes
        // stale relative to the live mic; adapting against it on re-engage
        // would corrupt convergence, so re-engage starts from a clean state.
        let engine = SentinelEngineStage()
        let stage = SwitchingAECStage(engineStage: engine, mode: .bypassed)

        stage.setMode(.cancelling)
        #expect(engine.resetCount == 1)
    }

    @Test func disengagingAndRecoveryTransitionsDoNotReset() {
        let engine = SentinelEngineStage()
        let stage = SwitchingAECStage(engineStage: engine, mode: .cancelling)

        // Disengaging defers the reset to the eventual re-engage.
        stage.setMode(.bypassed)
        #expect(engine.resetCount == 0)

        stage.setMode(.cancelling)
        #expect(engine.resetCount == 1)

        // Cancelling ↔ Degraded keeps the engine fed throughout: recovery
        // means the engine is already converged again, so no reset.
        stage.setMode(.degraded)
        stage.setMode(.cancelling)
        #expect(engine.resetCount == 1)
    }

    @Test func sameModeSetIsANoOp() {
        let engine = SentinelEngineStage()
        let stage = SwitchingAECStage(engineStage: engine, mode: .cancelling)

        stage.setMode(.cancelling)
        #expect(engine.resetCount == 0)
    }

    @Test func resetForwardsToTheEngine() {
        let engine = SentinelEngineStage()
        let stage = SwitchingAECStage(engineStage: engine, mode: .bypassed)

        stage.reset()
        #expect(engine.resetCount == 1)
    }

    @Test func currentModeTracksSetMode() {
        let stage = SwitchingAECStage(engineStage: SentinelEngineStage(), mode: .dedupOnly)
        #expect(stage.currentMode == .dedupOnly)

        stage.setMode(.cancelling)
        #expect(stage.currentMode == .cancelling)
    }
}

// MARK: - Degradation notice glue (SP-001 US-7)

struct EchoDegradationNoticeTests {

    @Test func showEffectProducesTheEnglishNotice() {
        let notice = EchoDegradationNotice.notice(after: .showDegradationNotice)
        #expect(notice == "Echo cancellation reduced — headphones recommended")
    }

    @Test func clearEffectRemovesTheNotice() {
        #expect(EchoDegradationNotice.notice(after: .clearDegradationNotice) == nil)
    }
}

@MainActor
struct RecordingStateEchoNoticeTests {

    @Test func effectsSetAndClearTheNotice() {
        let state = RecordingState()
        #expect(state.echoNotice == nil)

        state.applyEchoHandlingEffect(.showDegradationNotice)
        #expect(state.echoNotice == EchoDegradationNotice.message)

        state.applyEchoHandlingEffect(.clearDegradationNotice)
        #expect(state.echoNotice == nil)
    }

    @Test func stoppingARecordingClearsTheNotice() {
        let state = RecordingState()
        state.markStarted()
        state.applyEchoHandlingEffect(.showDegradationNotice)

        state.markStopped()
        #expect(state.echoNotice == nil)
    }
}
