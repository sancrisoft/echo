//
//  GlobalShortcutTests.swift
//  AppTests
//
//  What one press of Control + Option + E does in each phase, and that the
//  menu shows the combination beside the command it runs. Hosted only because
//  the type belongs to the app target; the registration itself is a launch
//  side effect and never runs under a test host.
//

import AppKit
import Audio
import Foundation
import Island
import Recording
import Testing

@testable import Echo

@Suite("The global shortcut")
@MainActor
struct GlobalShortcutTests {

    @Test("it is written the way menus write it, for the keyboard shortcuts panel")
    func display() {
        #expect(GlobalShortcut.display == "⌃⌥E")
    }

    @Test("at rest a press records, and while recording it stops")
    func pressesToggle() {
        #expect(GlobalShortcut.Press.of(.idle) == .start)
        #expect(GlobalShortcut.Press.of(.recording(startedAt: Date(), scope: .everything)) == .stop)
    }

    @Test("a teardown under way is not stopped twice")
    func stoppingIgnoresAPress() {
        #expect(GlobalShortcut.Press.of(.stopping) == .nothing)
    }

    @Test(
        "the work after a stop never blocks a new recording",
        arguments: [RecordingPhase.finalizing(meetingID: UUID(), progress: 0.3), .summarizing(meetingID: UUID())])
    func postStopWorkRecords(phase: RecordingPhase) {
        #expect(GlobalShortcut.Press.of(phase) == .start)
    }

    @Test("the menu shows the combination beside the command it runs, and nowhere else")
    func theMenuShowsTheShortcut() throws {
        let menu = MenuBarMenu(
            island: { _ in
                [
                    IslandMenuEntry(title: "Record", kind: .action({}), takesShortcut: true),
                    IslandMenuEntry(title: "Dismiss", kind: .action({})),
                ]
            },
            requests: MenuBarMenu.Requests(openEcho: {}, openSettings: {}, checkForUpdates: {}, update: {})
        ).build()
        let record = try #require(menu.items.first { $0.title == "Record" })
        #expect(record.keyEquivalent == "e")
        #expect(record.keyEquivalentModifierMask == [.control, .option])
        let dismiss = try #require(menu.items.first { $0.title == "Dismiss" })
        #expect(dismiss.keyEquivalent.isEmpty)
    }
}
