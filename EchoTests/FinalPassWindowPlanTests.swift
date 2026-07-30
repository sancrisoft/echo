//
//  FinalPassWindowPlanTests.swift
//  EchoTests
//
//  SP-005 S1: the final pass's window plan, asserted as pure tables (the
//  real decode needs a model). The tail-trap guard is the load-bearing row:
//  the pinned WhisperKit never decodes the last ≤1.0 s of a clip
//  (windowClipTime), so every decode clip must carry ≥1.5 s of trailing
//  silence — and the last window must reach the clip's true end, or the
//  meeting's closing words (user story 4) stay structurally lost.
//

import Foundation
import Testing
@testable import Echo

@Suite("FinalPassWindowPlan")
struct FinalPassWindowPlanTests {

    private let rate = Int(AudioConstants.sampleRate)

    @Test("windows of ≤30 s cover the whole duration contiguously")
    func windowsCoverTheWholeDuration() {
        let total = 75 * rate   // 75 s → 30 + 30 + 15
        let windows = FinalPassWindowPlan.windows(totalSamples: total)

        #expect(windows.count == 3)
        #expect(windows.first?.lowerBound == 0)
        #expect(windows.last?.upperBound == total)
        for window in windows {
            #expect(window.count <= 30 * rate)
        }
        for (previous, next) in zip(windows, windows.dropFirst()) {
            #expect(previous.upperBound == next.lowerBound)
        }
    }

    @Test("the last window covers the final second (the tail-trap guard)")
    func lastWindowCoversTheFinalSecond() {
        // Exact multiple, remainder, and a sub-second tail after a full
        // window — the stop-flush shape that live provably loses.
        for totalSeconds in [60.0, 61.5, 30.4, 0.4] {
            let total = Int(totalSeconds * AudioConstants.sampleRate)
            let windows = FinalPassWindowPlan.windows(totalSamples: total)
            #expect(windows.last?.upperBound == total, "duration \(totalSeconds)s")
        }
    }

    @Test("no audio plans no windows")
    func emptyClipPlansNothing() {
        #expect(FinalPassWindowPlan.windows(totalSamples: 0).isEmpty)
    }

    @Test("every decode clip carries at least 1.5 s of trailing silence")
    func decodeClipCarriesTheTailPad() {
        #expect(FinalPassWindowPlan.tailPadSamples >= Int(AudioConstants.sampleRate * 1.5))

        let window: [Float] = Array(repeating: 0.5, count: 2 * rate)
        let clip = FinalPassWindowPlan.paddedClip(window[...])

        #expect(clip.count == window.count + FinalPassWindowPlan.tailPadSamples)
        #expect(Array(clip.prefix(window.count)) == window)
        #expect(clip.suffix(FinalPassWindowPlan.tailPadSamples).allSatisfy { $0 == 0 })
    }
}
