//
//  MenuBarLookTests.swift
//  AppTests
//
//  What the menu bar item shows for each phase of a session. Hosted only
//  because the type belongs to the app target; the rule is pure. The pixels it
//  leads to — a template that inverts with the bar, a red one that does not —
//  are the half only a person can see.
//

import Audio
import Foundation
import Island
import Recording
import Testing

@testable import Echo

@Suite("What the menu bar item shows")
struct MenuBarLookTests {

    private let start = Date(timeIntervalSinceReferenceDate: 10_000)

    @Test("nothing recording: the mark alone")
    func idle() {
        #expect(MenuBarItem.Look.of(.idle, now: start) == .idle)
    }

    @Test("a live session: the mark in red and the whole seconds since it began")
    func recording() {
        let phase = RecordingPhase.recording(startedAt: start, scope: .everything)
        #expect(MenuBarItem.Look.of(phase, now: start) == .recording(elapsed: 0))
        #expect(MenuBarItem.Look.of(phase, now: start.addingTimeInterval(761.6)) == .recording(elapsed: 761))
    }

    /// The bar shows a capture and nothing after it. Stopping, the pass and
    /// the summary are the island's to report.
    @Test(
        "the work after a stop is not shown in the bar",
        arguments: [
            RecordingPhase.stopping,
            .finalizing(meetingID: UUID(), progress: 0.4),
            .summarizing(meetingID: UUID()),
        ]
    )
    func afterTheStop(phase: RecordingPhase) {
        #expect(MenuBarItem.Look.of(phase, now: start) == .idle)
    }

    // MARK: With the island switched off

    @Test("off, the item says what the ears would: the call's app, the status words")
    func theEarsInWords() {
        #expect(MenuBarItem.Look.of(IslandEars.none, now: start, stoppedAt: 0) == .idle)
        #expect(MenuBarItem.Look.of(.call(app: "Zoom"), now: start, stoppedAt: 0) == .call("Zoom"))
        #expect(MenuBarItem.Look.of(.saved, now: start, stoppedAt: 0) == .status("Saved"))
        #expect(MenuBarItem.Look.of(.afterStop(.summary), now: start, stoppedAt: 0) == .status("Summarizing"))
        #expect(MenuBarItem.Look.of(.afterStop(.transcript), now: start, stoppedAt: 0) == .status("Finalizing"))
    }

    @Test("off, the countdown is written out in full, in red")
    func theCountdown() {
        let look = MenuBarItem.Look.of(.countdown(deadline: start.addingTimeInterval(8)), now: start, stoppedAt: 0)
        #expect(look == .countdown("stopping 8s"))
    }

    @Test("off, a live clock is the same red clock, and a stopped one holds where it stopped")
    func theClock() {
        #expect(
            MenuBarItem.Look.of(.clock(startedAt: start), now: start.addingTimeInterval(761.6), stoppedAt: 0)
                == .recording(elapsed: 761))
        #expect(MenuBarItem.Look.of(.clock(startedAt: nil), now: start, stoppedAt: 761) == .recording(elapsed: 761))
    }

    @Test("a call with no name leaves the mark alone")
    func aNamelessCall() {
        #expect(MenuBarItem.Look.of(.call(app: ""), now: start, stoppedAt: 0) == .idle)
    }
}
