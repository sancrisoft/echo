//
//  CaptureCallbackCostTests.swift
//  AudioTests
//
//  What one system-tap IO cycle costs, and a guard that it stays cheap. Field
//  accounting showed Core Audio dropping ~8 % of the tap's cycles (606 of
//  7389 on a real meeting) against a 10.67 ms budget — so the first question
//  was whether the block simply does too much. Measured at a fraction of a
//  percent of budget: it does not, and the loss is in *reaching* the block.
//
//  It stays as a regression guard. Anything added to the capture callback
//  that pushes it toward its deadline fails this before it reaches a meeting.
//
//  Two of v1's five terms are gone because the code they timed is not in this
//  package: the echo canceller's far-end feed (the AEC stage arrives with the
//  next layer) and the two unstructured tasks the v1 callback spawned per
//  cycle (that shape belongs to Recording). Both return with the AEC layer,
//  and the ceiling below is calibrated for the three terms that remain — not
//  inherited from the five-term measurement.
//
//  `.acceptance`, because the assertion is a wall-clock throughput budget:
//  it measures elapsed time on the machine it runs on, which is not a fact a
//  normal `swift test` may depend on.
//

import AVFoundation
import Audio
import EchoCoreTestSupport
import Foundation
import Testing

@Suite(.acceptance)
struct CaptureCallbackCostTests {

    /// One system-tap cycle: 512 frames of 48 kHz mono float.
    private static let cycleFrames = 512
    private static let tapRate: Double = 48_000
    private static let budgetMs = Double(cycleFrames) / tapRate * 1_000

    private static func measure(_ iterations: Int, _ body: () -> Void) -> Double {
        let start = ContinuousClock.now
        for _ in 0..<iterations { body() }
        let parts = start.duration(to: .now).components
        let milliseconds = (Double(parts.seconds) * 1_000) + Double(parts.attoseconds) / 1e15
        return milliseconds / Double(iterations)
    }

    @Test func oneCycleCostBreakdown() throws {
        let format = try #require(
            AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Self.tapRate, channels: 1, interleaved: false)
        )
        let iterations = 2_000
        let raw = [Float](repeating: 0.1, count: Self.cycleFrames)
        let resampler = try #require(BufferResampler(from: format))

        // a) what the IO block does before resampling: allocate + copy
        let alloc = Self.measure(iterations) {
            guard
                let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(Self.cycleFrames)),
                let destination = pcm.floatChannelData?[0]
            else { return }
            pcm.frameLength = AVAudioFrameCount(Self.cycleFrames)
            raw.withUnsafeBufferPointer { source in
                guard let base = source.baseAddress else { return }
                destination.update(from: base, count: Self.cycleFrames)
            }
        }

        // b) the 48 kHz → 16 kHz conversion, the same call the tap makes
        let pcm = try #require(
            AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(Self.cycleFrames))
        )
        let destination = try #require(pcm.floatChannelData?[0])
        pcm.frameLength = AVAudioFrameCount(Self.cycleFrames)
        raw.withUnsafeBufferPointer { source in
            guard let base = source.baseAddress else { return }
            destination.update(from: base, count: Self.cycleFrames)
        }
        let resample = Self.measure(iterations) { _ = resampler.resample(pcm) }

        let frames = resampler.resample(pcm) ?? []
        // c) the meter's level
        let level = Self.measure(iterations) { _ = AudioLevelMeter.level(from: frames) }

        let total = alloc + resample + level
        let breakdown = Comment(
            rawValue: """
                one IO cycle (\(Self.cycleFrames) frames @ \(Int(Self.tapRate)) Hz), \
                budget \(String(format: "%.2f", Self.budgetMs)) ms — \
                alloc+copy \(String(format: "%.3f", alloc)) ms, \
                resample \(String(format: "%.3f", resample)) ms, \
                level meter \(String(format: "%.3f", level)) ms, \
                total \(String(format: "%.3f", total)) ms \
                (\(String(format: "%.1f", total / Self.budgetMs * 100)) % of budget)
                """
        )

        // Measured 2026-09-09 on this Mac (three runs, stable to the
        // microsecond): alloc+copy 0.003 ms, resample 0.001 ms, level meter
        // 0.008–0.009 ms — 0.13 % of the 10.67 ms budget for the three terms
        // this package holds. 10 % is therefore a ceiling with ~80× headroom,
        // which only a real regression (synchronous encoding, a blocking
        // call, an unbounded loop over the buffer) can cross — never machine
        // load. The breakdown rides along as the failure comment, so a
        // regression says which term grew.
        #expect(total < Self.budgetMs * 0.10, breakdown)
    }
}
