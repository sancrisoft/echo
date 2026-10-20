//
//  LiveSessionNavigationTests.swift
//  WorkspaceTests
//
//  Where the window goes when a live session begins and ends. The rules live
//  in `WorkspaceModel`, so they are checked without a window or a session.
//

import Foundation
import Testing

@testable import Workspace

@Suite("The window and the live session")
struct LiveSessionNavigationTests {

    @Test("showing the live session keeps the meeting selected underneath")
    func theSelectionSurvives() {
        let model = WorkspaceModel()
        let meeting = UUID()
        model.open(meeting)
        model.showLiveSession()
        #expect(model.section == .recording)
        #expect(model.selectedMeetingID == meeting)
    }

    @Test("when capture ends on the live session, the window opens the meeting the stop saved")
    func followsTheMeeting() {
        let model = WorkspaceModel()
        model.open(UUID())
        model.showLiveSession()
        let saved = UUID()
        model.liveSessionEnded(savedMeeting: saved)
        #expect(model.section == .meetings)
        #expect(model.selectedMeetingID == saved)
    }

    @Test("with no saved meeting, the library comes back as it was")
    func fallsBackToTheLibrary() {
        let model = WorkspaceModel()
        let reading = UUID()
        model.open(reading)
        model.showLiveSession()
        model.liveSessionEnded(savedMeeting: nil)
        #expect(model.section == .meetings)
        #expect(model.selectedMeetingID == reading)
    }

    @Test("a stop made elsewhere does not pull the window away from what it shows")
    func elsewhereNothingMoves() {
        let model = WorkspaceModel()
        let reading = UUID()
        model.open(reading)
        model.liveSessionEnded(savedMeeting: UUID())
        #expect(model.section == .meetings)
        #expect(model.selectedMeetingID == reading)

        model.section = .settings
        model.liveSessionEnded(savedMeeting: UUID())
        #expect(model.section == .settings)
    }
}
