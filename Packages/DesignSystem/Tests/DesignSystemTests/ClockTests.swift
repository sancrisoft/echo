//
//  ClockTests.swift
//  DesignSystemTests
//
//  How a running clock is written. Whole seconds counted down from the start,
//  so a clock never reads a second the meeting has not reached yet.
//

import DesignSystem
import Foundation
import Testing

@Suite("The clock")
struct ClockTests {

    @Test(
        "the short form drops the hours until there are some",
        arguments: [
            (0, "0:00"), (7, "0:07"), (59, "0:59"), (60, "1:00"), (761, "12:41"),
            (3599, "59:59"), (3600, "1:00:00"), (3761, "1:02:41"), (36_000, "10:00:00"),
        ]
    )
    func compact(seconds: Int, expected: String) {
        #expect(EchoClock.compact(seconds) == expected)
    }

    @Test(
        "the full form always shows hours, so its width never changes",
        arguments: [(0, "00:00:00"), (761, "00:12:41"), (3761, "01:02:41"), (36_000, "10:00:00")]
    )
    func full(seconds: Int, expected: String) {
        #expect(EchoClock.full(seconds) == expected)
    }

    @Test("elapsed time counts whole seconds down, never up")
    func elapsedIsFloored() {
        let start = Date(timeIntervalSinceReferenceDate: 1_000)
        #expect(EchoClock.elapsedSeconds(since: start, now: start) == 0)
        #expect(EchoClock.elapsedSeconds(since: start, now: start.addingTimeInterval(0.999)) == 0)
        #expect(EchoClock.elapsedSeconds(since: start, now: start.addingTimeInterval(1)) == 1)
        #expect(EchoClock.elapsedSeconds(since: start, now: start.addingTimeInterval(761.9)) == 761)
    }

    @Test("a start in the future reads zero instead of running backwards")
    func futureStart() {
        let now = Date(timeIntervalSinceReferenceDate: 1_000)
        #expect(EchoClock.elapsedSeconds(since: now.addingTimeInterval(30), now: now) == 0)
        #expect(EchoClock.compact(-5) == "0:00")
    }
}
