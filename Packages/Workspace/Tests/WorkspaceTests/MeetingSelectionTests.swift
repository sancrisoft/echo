//
//  MeetingSelectionTests.swift
//  WorkspaceTests
//
//  What happens to the selection when the list changes underneath it, and
//  what a click does before a menu opens. These are the cases that produce
//  bugs — the selected meeting is deleted, a new one arrives, the selected one
//  is moved to Trash — and they are rules, not rendering, so they are settled
//  here rather than inside a view.
//

import AppKit
import Foundation
import Meetings
import Testing

@testable import Workspace

@Suite("Selection under a changing list")
struct MeetingSelectionTests {

    private func metas(_ count: Int) -> [MeetingMeta] {
        (0..<count).map { index in
            let start = Date(timeIntervalSince1970: 1_756_900_000 - Double(index) * 3600)
            return MeetingMeta(
                id: UUID(), title: "Meeting \(index)", startedAt: start, endedAt: start.addingTimeInterval(600),
                segmentCount: 1, hasSummary: true)
        }
    }

    @Test("a meeting arriving while something is selected moves nothing")
    func newMeetingKeepsTheSelection() {
        let model = WorkspaceModel()
        let list = metas(3)
        model.open(list[1].id)
        let arrival = MeetingMeta(
            id: UUID(), title: "Just finished", startedAt: .now, endedAt: .now, segmentCount: 0, hasSummary: false)
        model.reconcileSelection(with: [arrival] + list)
        #expect(model.selectedMeetingID == list[1].id)
    }

    @Test("the selected meeting disappearing clears the selection rather than picking another")
    func deletedSelectionIsDropped() {
        let model = WorkspaceModel()
        let list = metas(3)
        model.open(list[0].id)
        model.reconcileSelection(with: Array(list.dropFirst()))
        #expect(model.selectedMeetingID == nil, "a meeting that is gone must not stay highlighted")
    }

    @Test("trashing the selected row keeps the keyboard going: the row that slides up takes it")
    func trashingHandsTheSelectionOn() {
        let model = WorkspaceModel()
        let list = metas(3)
        model.open(list[0].id)
        model.selectionAfterRemoving(list[0].id, in: list)
        #expect(model.selectedMeetingID == list[1].id)
    }

    @Test("trashing the last row falls back, and trashing the only row leaves nothing")
    func trashingAtTheEnds() {
        let model = WorkspaceModel()
        let list = metas(2)
        model.open(list[1].id)
        model.selectionAfterRemoving(list[1].id, in: list)
        #expect(model.selectedMeetingID == list[0].id)

        let single = metas(1)
        model.open(single[0].id)
        model.selectionAfterRemoving(single[0].id, in: single)
        #expect(model.selectedMeetingID == nil)
    }

    @Test("the search decides where an arrow lands, and a hidden selection starts from the end")
    func arrowsFollowTheVisibleList() {
        let model = WorkspaceModel()
        let list = metas(4)
        model.open(list[3].id)
        model.searchText = "Meeting 1"
        #expect(model.moveSelection(.down, in: list))
        #expect(model.selectedMeetingID == list[1].id, "the arrow lands in the filtered list, not the whole one")
        #expect(model.moveSelection(.down, in: list))
        #expect(model.selectedMeetingID == list[1].id, "the only visible row is both ends of the list")
    }

    @Test("the trash's selection is its own and is dropped with its row")
    func trashSelectionIsSeparate() {
        let model = WorkspaceModel()
        let list = metas(2)
        model.open(list[0].id)
        model.selectedTrashedID = list[1].id
        model.reconcileTrashSelection(with: [])
        #expect(model.selectedTrashedID == nil)
        #expect(model.selectedMeetingID == list[0].id, "the library's selection is untouched by the trash's")
    }
}

@Suite("Right-click selects the row it opens on")
struct RowContextClickTests {

    @Test("a right-click is a context click, and so is a control-click")
    func whatCountsAsAContextClick() {
        #expect(RowContextClickWatcher.isContextClick(type: .rightMouseDown, modifiers: []))
        #expect(RowContextClickWatcher.isContextClick(type: .leftMouseDown, modifiers: .control))
        #expect(!RowContextClickWatcher.isContextClick(type: .leftMouseDown, modifiers: []))
        #expect(!RowContextClickWatcher.isContextClick(type: .leftMouseDown, modifiers: .command))
        #expect(!RowContextClickWatcher.isContextClick(type: .mouseMoved, modifiers: []))
    }

    @Test("the click reports the row the pointer is over, and only that one")
    func reportsTheHoveredRow() {
        let watcher = RowContextClickWatcher()
        var selected: [UUID] = []
        watcher.onContextClick = { selected.append($0) }

        watcher.handle(isContextClick: true, isInListWindow: true)
        #expect(selected.isEmpty, "a click with no row under it selects nothing")

        let row = UUID()
        watcher.hoveredID = row
        watcher.handle(isContextClick: false, isInListWindow: true)
        #expect(selected.isEmpty, "an ordinary left click is the row's own business")

        watcher.handle(isContextClick: true, isInListWindow: true)
        #expect(selected == [row])
    }

    @Test("a click in another of the app's windows is not a click on a row")
    func onlyTheListsWindowCounts() {
        let watcher = RowContextClickWatcher()
        var selected: [UUID] = []
        watcher.onContextClick = { selected.append($0) }
        watcher.hoveredID = UUID()

        watcher.handle(isContextClick: true, isInListWindow: false)
        #expect(selected.isEmpty, "the pointer was last over a row in a window this click missed")
    }

    @Test("a hover nothing can vouch for is forgotten, and selects nothing after")
    func aStrandedHoverSelectsNothing() {
        let watcher = RowContextClickWatcher()
        var selected: [UUID] = []
        watcher.onContextClick = { selected.append($0) }
        watcher.hoveredID = UUID()

        // What the rows moving under the pointer, or the window ceasing to be
        // the one in use, does to the hover.
        watcher.forgetHover()
        watcher.handle(isContextClick: true, isInListWindow: true)
        #expect(selected.isEmpty)
    }
}
