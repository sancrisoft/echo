//
//  AECEngineTests.swift
//  EchoTests
//
//  Structural/smoke tests for the WebRTC AEC engine stage (S2).
//  Energy-reduction quality tests belong to the fixture-based suite.
//

import Foundation
import Testing
@testable import Echo

/// Thread-safe recorder for engine-health events (the hook may fire on a
/// capture thread).
private final class HealthEventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [Bool] = []

    func record(_ healthy: Bool) {
        lock.lock()
        recorded.append(healthy)
        lock.unlock()
    }

    var events: [Bool] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }
}

struct AECEngineTests {

    @Test func engineStageInitializesHealthy() {
        let stage = WebRTCAECStage()
        #expect(stage.isHealthy)
    }

    @Test func cumulativeSampleCountIsPreservedAcrossUnevenCallSizes() {
        let stage = WebRTCAECStage()
        // 100 + 60 + 250 + 70 = 480 = 3 whole 160-sample frames.
        let callSizes = [100, 60, 250, 70]
        let expectedOutSizes = [0, 160, 160, 160]

        var totalIn = 0
        var totalOut = 0
        for (size, expected) in zip(callSizes, expectedOutSizes) {
            let out = stage.processMicSamples([Float](repeating: 0, count: size))
            totalIn += size
            totalOut += out.count
            #expect(out.count == expected)
            // The pending remainder never reaches a whole frame.
            #expect(totalIn - totalOut >= 0 && totalIn - totalOut < 160)
        }
        #expect(totalOut == totalIn)
    }

    @Test func silentInputOnBothPathsYieldsSilentOutput() {
        let stage = WebRTCAECStage()
        let silence = [Float](repeating: 0, count: 480)

        // Uneven far-end feeds exercise the far-end framing carry too.
        stage.feedFarEnd([Float](repeating: 0, count: 173))
        stage.feedFarEnd([Float](repeating: 0, count: 307))
        let out = stage.processMicSamples(silence)

        #expect(out.count == 480)
        #expect(out.allSatisfy { abs($0) <= 1e-6 })
    }

    @Test func resetMidStreamClearsCarryAndKeepsIntegrity() {
        let stage = WebRTCAECStage()

        // 200 samples: one frame out, 40 carried.
        let before = stage.processMicSamples([Float](repeating: 0, count: 200))
        #expect(before.count == 160)

        stage.reset()

        // The 40-sample carry is dropped with the adaptation state; framing
        // restarts from zero. 120 post-reset samples must NOT combine with
        // the stale 40 to complete a frame.
        let after = stage.processMicSamples([Float](repeating: 0, count: 120))
        #expect(after.count == 0)
        let final = stage.processMicSamples([Float](repeating: 0, count: 40))
        #expect(final.count == 160)
        #expect(stage.isHealthy)
    }

    @Test func farEndFeedConcurrentWithMicProcessingKeepsCumulativeCounts() async {
        let stage = WebRTCAECStage()
        let iterations = 500

        let farTask = Task.detached {
            for _ in 0 ..< iterations {
                // Non-frame-aligned on purpose: hammers the far-end carry.
                stage.feedFarEnd([Float](repeating: 0.05, count: 173))
            }
        }
        let micTask = Task.detached {
            var total = 0
            for _ in 0 ..< iterations {
                total += stage.processMicSamples([Float](repeating: 0.01, count: 160)).count
            }
            return total
        }

        await farTask.value
        let totalOut = await micTask.value
        #expect(totalOut == iterations * 160)
        #expect(stage.isHealthy)
    }

    @Test func healthyEngineEmitsNoHealthEvents() {
        let stage = WebRTCAECStage()
        let recorder = HealthEventRecorder()
        stage.onEngineEvent = { recorder.record($0) }

        stage.feedFarEnd([Float](repeating: 0.1, count: 320))
        _ = stage.processMicSamples([Float](repeating: 0.1, count: 320))

        // Baseline is healthy; the hook only fires on transitions.
        #expect(recorder.events.isEmpty)
        #expect(stage.isHealthy)
    }

    @Test func failedEngineReportsUnhealthyOnceAndPassesAudioThrough() {
        // Engine-init failure is not inducible through the real bridge, so
        // the test seam constructs the stage in the same state init failure
        // would leave it in.
        let stage = WebRTCAECStage(failedEngine: ())
        let recorder = HealthEventRecorder()
        stage.onEngineEvent = { recorder.record($0) }

        let samples = [Float](repeating: 0.5, count: 200)
        // Degradation contract: raw mic audio keeps flowing, unframed.
        #expect(stage.processMicSamples(samples) == samples)
        #expect(stage.isHealthy == false)
        #expect(recorder.events == [false])

        // One event per degradation episode, not one per call.
        _ = stage.processMicSamples(samples)
        stage.feedFarEnd(samples)
        #expect(recorder.events == [false])
    }
}
