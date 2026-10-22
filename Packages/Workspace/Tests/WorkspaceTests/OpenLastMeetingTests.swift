//
//  OpenLastMeetingTests.swift
//  WorkspaceTests
//
//  The window never shows nothing selected while there are meetings: it opens
//  on the meeting last open, and when that one is gone, on the most recent
//  (product owner, 2026-10-02). A rule over values, checked without a window.
//

import Foundation
import Meetings
import Testing

@testable import Workspace

@Suite("Where the library opens")
struct OpenLastMeetingTests {

    /// Newest first, an hour apart.
    private func metas(_ count: Int) -> [MeetingMeta] {
        (0..<count).map { index in
            let start = Date(timeIntervalSince1970: 1_756_900_000 - Double(index) * 3600)
            return MeetingMeta(
                id: UUID(), title: "Meeting \(index)", startedAt: start, endedAt: start.addingTimeInterval(600),
                segmentCount: 1, hasSummary: true)
        }
    }

    @Test("with nothing selected it opens on the meeting last open")
    func opensOnTheLastOpen() {
        let model = WorkspaceModel()
        let list = metas(3)
        model.settleSelection(in: list, lastOpen: list[2].id)
        #expect(model.selectedMeetingID == list[2].id)
    }

    @Test("when the meeting last open is gone, it opens on the most recent")
    func fallsBackToTheMostRecent() {
        let model = WorkspaceModel()
        let list = metas(3)
        model.settleSelection(in: list, lastOpen: UUID())
        #expect(model.selectedMeetingID == list[0].id)

        let fresh = WorkspaceModel()
        fresh.settleSelection(in: list.reversed(), lastOpen: nil)
        #expect(fresh.selectedMeetingID == list[0].id, "most recent by start, not by position in the list")
    }

    @Test("a selection the library still holds is never moved")
    func aLiveSelectionStays() {
        let model = WorkspaceModel()
        let list = metas(3)
        model.open(list[1].id)
        model.settleSelection(in: list, lastOpen: list[2].id)
        #expect(model.selectedMeetingID == list[1].id)
    }

    @Test("a selection that is gone gives way, as if nothing were selected")
    func aGoneSelectionGivesWay() {
        let model = WorkspaceModel()
        let list = metas(3)
        model.open(UUID())
        model.settleSelection(in: list, lastOpen: list[1].id)
        #expect(model.selectedMeetingID == list[1].id)
    }

    @Test("an empty library has nothing to open")
    func emptyStaysEmpty() {
        let model = WorkspaceModel()
        model.settleSelection(in: [], lastOpen: UUID())
        #expect(model.selectedMeetingID == nil)
    }
}
