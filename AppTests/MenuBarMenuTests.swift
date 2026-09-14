//
//  MenuBarMenuTests.swift
//  AppTests
//
//  What the menu is made of in each phase, and the rule that only shows up in
//  three of them: the post-stop phases contribute no item of their own, so the
//  divider that follows has nothing above it. SwiftUI's `Menu` elided a leading
//  divider and `NSMenu` draws it, which is a defect the port could only inherit
//  silently.
//
//  Hosted because the type belongs to the app target and there is no other way
//  to reach it; the menu it builds asks nothing of the host.
//

import AppKit
import Audio
import Foundation
import Recording
import Testing

@testable import Echo

@Suite("The menu bar item's menu")
@MainActor
struct MenuBarMenuTests {

    /// Every phase, including the three that offer nothing.
    private nonisolated static let phases: [RecordingPhase] = [
        .idle,
        .recording(startedAt: Date(), scope: .everything),
        .stopping,
        .finalizing(meetingID: UUID(), progress: 0.5),
        .summarizing(meetingID: UUID()),
    ]

    private func menu(in phase: RecordingPhase) -> NSMenu {
        MenuBarMenu(
            phase: { phase },
            requests: MenuBarMenu.Requests(
                startRecording: {},
                stopRecording: {},
                openEcho: {},
                openSettings: {}
            )
        )
        .build()
    }

    @Test("no phase opens the menu on a separator", arguments: phases)
    func neverStartsWithASeparator(phase: RecordingPhase) throws {
        let first = try #require(menu(in: phase).items.first)
        #expect(!first.isSeparatorItem)
    }

    @Test("idle offers Record at the top")
    func idleOffersRecord() throws {
        #expect(try #require(menu(in: .idle).items.first).title == "Record")
    }

    @Test("a live recording offers Stop at the top")
    func recordingOffersStop() throws {
        let menu = menu(in: .recording(startedAt: Date(), scope: .everything))
        #expect(try #require(menu.items.first).title == "Stop Recording")
    }

    /// Work the user cannot answer: the phase contributes nothing, so the menu
    /// starts at the way back into the app.
    @Test(
        "the post-stop phases start at Open Echo",
        arguments: [
            RecordingPhase.stopping,
            .finalizing(meetingID: UUID(), progress: 0.5),
            .summarizing(meetingID: UUID()),
        ]
    )
    func postStopStartsAtOpenEcho(phase: RecordingPhase) throws {
        #expect(try #require(menu(in: phase).items.first).title == "Open Echo")
    }

    /// The rest of the menu is the same in every phase, and the two dividers
    /// inside it always have something above them.
    @Test("the way back, the version and Quit are always there", arguments: phases)
    func theRestOfTheMenuIsConstant(phase: RecordingPhase) {
        let titles = menu(in: phase).items.filter { !$0.isSeparatorItem }.map(\.title)
        #expect(titles.contains("Open Echo"))
        #expect(titles.contains("Settings…"))
        #expect(titles.last == "Quit Echo")
    }
}
