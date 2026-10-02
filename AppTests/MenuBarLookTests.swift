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
}
