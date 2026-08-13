//
//  CaptureCallbackCostTests.swift
//  EchoTests
//
//  BRN-007: what one system-tap IO cycle costs, and a guard that it stays
//  cheap. Field accounting showed Core Audio dropping ~8% of the tap's cycles
//  (606 of 7389 on a real meeting) against a 10.67 ms budget — so the first
//  question was whether the block simply does too much. Measured here at
//  ~0.1% of budget: it does not, and the loss is in *reaching* the block.
//
//  It stays as a regression guard. Anything added to the capture callback
//  that pushes it toward its deadline fails this before it reaches a meeting.
//

import AVFoundation
import Foundation
import Testing
@testable import Echo

struct CaptureCallbackCostTests {

    /// One system-tap cycle: 512 frames of 48 kHz mono float.
    private static let cycleFrames = 512
    private static let tapRate: Double = 48_000
    private static let budgetMs = Double(cycleFrames) / tapRate * 1_000

    private static func tapFormat() -> AVAudioFormat {
        AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: tapRate, channels: 1, interleaved: false)!
    }

    private static func measure(_ iterations: Int, _ body: () -> Void) -> Double {
        let start = ContinuousClock.now
        for _ in 0..<iterations { body() }
        let parts = start.duration(to: .now).components
        let ms = (Double(parts.seconds) * 1_000) + Double(parts.attoseconds) / 1e15
        return ms / Double(iterations)
    }

    @Test func oneCycleCostBreakdown() async {
        let format = Self.tapFormat()
        let iterations = 2_000
        let raw = [Float](repeating: 0.1, count: Self.cycleFrames)
        let resampler = BufferResampler(from: format)!

        // a) what `handle` does before resampling: allocate + copy
        let alloc = Self.measure(iterations) {
            let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(Self.cycleFrames))!
            pcm.frameLength = AVAudioFrameCount(Self.cycleFrames)
            raw.withUnsafeBufferPointer { source in
                pcm.floatChannelData![0].update(from: source.baseAddress!, count: Self.cycleFrames)
            }
        }

        // b) the 48 kHz → 16 kHz conversion, the same call the tap makes
        let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(Self.cycleFrames))!
        pcm.frameLength = AVAudioFrameCount(Self.cycleFrames)
        raw.withUnsafeBufferPointer { source in
            pcm.floatChannelData![0].update(from: source.baseAddress!, count: Self.cycleFrames)
        }
        let resample = Self.measure(iterations) { _ = resampler.resample(pcm) }

        let frames = resampler.resample(pcm) ?? []
        // c) the waveform's level
        let level = Self.measure(iterations) { _ = AudioLevelMeter.level(from: frames) }

        // d) the echo canceller's far-end feed, run synchronously on the callback
        let stage = WebRTCAECStage()
        let farEnd = Self.measure(iterations) { stage.feedFarEnd(frames) }

        // e) the two unstructured tasks the callback spawns per cycle
        let spawn = Self.measure(iterations) {
            Task { @MainActor in _ = frames.count }
            Task { _ = frames.count }
        }

        let total = alloc + resample + level + farEnd + spawn
        print("""

        ── one IO cycle (\(Self.cycleFrames) frames @ \(Int(Self.tapRate)) Hz), budget \(String(format: "%.2f", Self.budgetMs)) ms
           alloc+copy   \(String(format: "%7.3f", alloc)) ms
           resample     \(String(format: "%7.3f", resample)) ms
           level meter  \(String(format: "%7.3f", level)) ms
           AEC far-end  \(String(format: "%7.3f", farEnd)) ms
           2 Task spawn \(String(format: "%7.3f", spawn)) ms
           ── total     \(String(format: "%7.3f", total)) ms  (\(String(format: "%.0f", total / Self.budgetMs * 100))% of budget)

        """)
        // Measured at ~0.1% of budget, so a quarter is a loose ceiling that
        // only a real regression (synchronous encoding, a blocking call, an
        // unbounded loop over the buffer) can cross — never machine load.
        #expect(total < Self.budgetMs * 0.25)
    }
}
