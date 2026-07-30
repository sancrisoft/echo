//
//  FinalPassProgressTests.swift
//  EchoTests
//
//  SP-005 S6: the finalizing UI's single progress source (ADR-007) as pure
//  tables — decoded audio time over the total retained duration across both
//  channels, one accumulator, never a second counter. The load-bearing rows:
//  monotonic (a fraction may never move backward), skipped silent regions
//  count as instantly decoded (windows can be far fewer than duration/30 s),
//  channels weight by their retained duration, and a completed pass reads
//  exactly 1.0 — including the no-audio and fully-silent-channel edges.
//

import Foundation
import Testing
@testable import Echo

@Suite("FinalPassProgress")
struct FinalPassProgressTests {

    @Test("no retained audio reads complete immediately")
    func emptyInputIsComplete() {
        #expect(FinalPassProgress(channelTotalSamples: []).fraction == 1.0)
        #expect(FinalPassProgress(channelTotalSamples: [0, 0]).fraction == 1.0)
    }

    @Test("the fraction starts at zero and advances with decoded windows")
    func advancesWithWindows() {
        var progress = FinalPassProgress(channelTotalSamples: [1_000])
        #expect(progress.fraction == 0)
        #expect(progress.advance(channel: 0, decodedThrough: 300) == 0.3)
        #expect(progress.advance(channel: 0, decodedThrough: 700) == 0.7)
    }

    @Test("the fraction is monotonic — stale or backward positions never rewind it")
    func monotonicity() {
        var progress = FinalPassProgress(channelTotalSamples: [1_000])
        #expect(progress.advance(channel: 0, decodedThrough: 600) == 0.6)
        // A backward report (out-of-order delivery) is ignored.
        #expect(progress.advance(channel: 0, decodedThrough: 200) == 0.6)
        #expect(progress.fraction == 0.6)
        // And progress resumes forward from the high-water mark.
        #expect(progress.advance(channel: 0, decodedThrough: 800) == 0.8)
    }

    @Test("skipped silent regions count as instantly decoded")
    func skippedRegionsJump() {
        // Speech regions at [0, 100) and [800, 900) of a 1 000-sample
        // channel: the first window past the silence gap lands at 900, so
        // the fraction jumps the gap instead of stalling under it.
        var progress = FinalPassProgress(channelTotalSamples: [1_000])
        #expect(progress.advance(channel: 0, decodedThrough: 100) == 0.1)
        #expect(progress.advance(channel: 0, decodedThrough: 900) == 0.9)
        // Trailing silence after the last region: finishing the channel
        // accounts for it, so the pass still ends at exactly 1.0.
        #expect(progress.finishChannel(0) == 1.0)
    }

    @Test("channels weight by their retained duration")
    func bothChannelsWeighting() {
        // Mic holds 1/4 of the retained audio, system 3/4 — a finished mic
        // channel is 25% of the pass, not half of it.
        var progress = FinalPassProgress(channelTotalSamples: [1_000, 3_000])
        #expect(progress.finishChannel(0) == 0.25)
        #expect(progress.advance(channel: 1, decodedThrough: 1_500) == 0.625)
        #expect(progress.finishChannel(1) == 1.0)
    }

    @Test("a fully silent channel completes on finish alone")
    func silentChannelCompletes() {
        // No speech evidence → no windows → only the finish call arrives.
        var progress = FinalPassProgress(channelTotalSamples: [500, 500])
        #expect(progress.finishChannel(0) == 0.5)
        #expect(progress.finishChannel(1) == 1.0)
    }

    @Test("positions clamp to the channel total and the fraction to 1")
    func clampsOverrun() {
        var progress = FinalPassProgress(channelTotalSamples: [100])
        // A window's upper bound can never exceed the channel, but a broken
        // report past the end must still cap at exactly 1.0.
        #expect(progress.advance(channel: 0, decodedThrough: 150) == 1.0)
        #expect(progress.finishChannel(0) == 1.0)
    }

    @Test("out-of-range channel indexes are ignored")
    func outOfRangeIgnored() {
        var progress = FinalPassProgress(channelTotalSamples: [100])
        #expect(progress.advance(channel: 5, decodedThrough: 50) == 0)
        #expect(progress.finishChannel(-1) == 0)
        #expect(progress.fraction == 0)
    }
}
