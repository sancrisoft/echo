//
//  AECStageTests.swift
//  EchoTests
//

import Testing
@testable import Echo

struct AECStageTests {

    @Test func passthroughReturnsMicSamplesUnchanged() {
        let stage = PassthroughAECStage()
        let samples: [Float] = [0, 0.25, -0.5, 1, -1, 0.125, -0.0625]

        #expect(stage.processMicSamples(samples) == samples)
        #expect(stage.processMicSamples([]) == [])
    }

    @Test func farEndFeedAndResetDoNotAlterMicOutput() {
        let stage = PassthroughAECStage()
        let mic: [Float] = [0.5, -0.25, 0.75]

        stage.feedFarEnd([1, -1, 0.5, -0.5])
        #expect(stage.processMicSamples(mic) == mic)

        stage.reset()
        #expect(stage.processMicSamples(mic) == mic)
    }
}
