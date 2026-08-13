//
//  GlidingLevelTests.swift
//  EchoTests
//
//  The waves are drawn by one function, in one Canvas, in one frame — so when
//  the indigo one moved visibly worse than the gray one, the difference could
//  only be in how often each height changed: ~83 readings a second from the
//  system tap against 10 from the mic, painted on a 60–120 Hz display. These
//  pin the glide that carries a height between readings, and specifically that
//  it measures each channel's rate instead of assuming one.
//

import Foundation
import Testing
@testable import Echo

@Suite("Gliding level (between readings)")
struct GlidingLevelTests {

    private let start = Date(timeIntervalSince1970: 1_770_000_000)

    @Test func aNewHeightIsReachedGraduallyNotAtOnce() {
        var glide = GlidingLevel()
        // Two readings 100 ms apart — the mic's measured cadence.
        glide.retarget(0, now: start)
        glide.retarget(1, now: start.addingTimeInterval(0.1))

        // Frame-by-frame across the next 100 ms: every frame draws a
        // different height, none of them the old one, none overshooting.
        let mid = glide.value(at: start.addingTimeInterval(0.15))
        #expect(mid > 0.4 && mid < 0.6)
        #expect(glide.value(at: start.addingTimeInterval(0.12)) < mid)
        #expect(glide.value(at: start.addingTimeInterval(0.18)) > mid)
    }

    @Test func theTargetIsReachedByTheTimeTheNextReadingIsDue() {
        var glide = GlidingLevel()
        glide.retarget(0, now: start)
        glide.retarget(0.8, now: start.addingTimeInterval(0.1))

        #expect(abs(glide.value(at: start.addingTimeInterval(0.2)) - 0.8) < 0.0001)
        // And it holds there rather than drifting past.
        #expect(abs(glide.value(at: start.addingTimeInterval(0.6)) - 0.8) < 0.0001)
    }

    @Test func theSlideMatchesEachChannelsOwnRate() {
        // The fast tap: readings ~12 ms apart must not be smeared over the
        // mic's 100 ms, which would leave the gray wave chasing its own data.
        var fast = GlidingLevel()
        fast.retarget(0, now: start)
        fast.retarget(1, now: start.addingTimeInterval(0.012))

        // Half a fast interval in, it is already halfway there.
        let halfway = fast.value(at: start.addingTimeInterval(0.018))
        #expect(halfway > 0.4 && halfway < 0.6)
        // A full interval in, it has arrived.
        #expect(abs(fast.value(at: start.addingTimeInterval(0.024)) - 1) < 0.0001)
    }

    @Test func aReadingLandingMidSlideStartsFromWhereTheWaveIsDrawn() {
        var glide = GlidingLevel()
        glide.retarget(0, now: start)
        glide.retarget(1, now: start.addingTimeInterval(0.1))

        // Interrupt halfway up with a new target.
        let interrupt = start.addingTimeInterval(0.15)
        let heightAtInterrupt = glide.value(at: interrupt)
        glide.retarget(0.2, now: interrupt)

        // Continuous: it carries on from the drawn height, not from 1.0.
        #expect(abs(glide.value(at: interrupt) - heightAtInterrupt) < 0.0001)
        #expect(glide.value(at: interrupt.addingTimeInterval(0.01)) < heightAtInterrupt)
    }

    @Test func aStalledChannelStopsCrawlingTowardAStaleTarget() {
        var glide = GlidingLevel()
        glide.retarget(0.5, now: start)
        // Nothing for two seconds, then a reading: the slide is capped, so
        // the wave doesn't spend two seconds inching to the new height.
        glide.retarget(0, now: start.addingTimeInterval(2))

        #expect(glide.value(at: start.addingTimeInterval(2.12)) == 0)
    }
}
