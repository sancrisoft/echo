//
//  MeetingListNavigationTests.swift
//  EchoTests
//
//  The meetings list's selection rules as a table. Everything the list does
//  with the keyboard reduces to these three functions, so they carry the
//  behaviour a window can't easily be asked about: where an arrow lands, what
//  survives a search keystroke, and which row inherits the selection when the
//  selected meeting is trashed.
//

import Foundation
import Testing
@testable import Echo

private let ids = (0..<4).map { _ in UUID() }

// MARK: - Arrow keys

@Test("↓ from nothing selects the first row, ↑ from nothing selects the last")
func arrowFromEmptySelectionLandsAtAnEnd() {
    #expect(MeetingListNavigation.destination(from: nil, move: .down, in: ids) == ids[0])
    #expect(MeetingListNavigation.destination(from: nil, move: .up, in: ids) == ids[3])
}

@Test("Arrows step one row at a time in the visible order")
func arrowsStepOneRow() {
    #expect(MeetingListNavigation.destination(from: ids[1], move: .down, in: ids) == ids[2])
    #expect(MeetingListNavigation.destination(from: ids[1], move: .up, in: ids) == ids[0])
}

@Test("The selection holds at both ends instead of wrapping")
func arrowsClampAtTheEnds() {
    #expect(MeetingListNavigation.destination(from: ids[0], move: .up, in: ids) == ids[0])
    #expect(MeetingListNavigation.destination(from: ids[3], move: .down, in: ids) == ids[3])
}

@Test("Home / End jump to the ends from anywhere")
func firstAndLastJumpToTheEnds() {
    #expect(MeetingListNavigation.destination(from: ids[2], move: .first, in: ids) == ids[0])
    #expect(MeetingListNavigation.destination(from: ids[2], move: .last, in: ids) == ids[3])
    #expect(MeetingListNavigation.destination(from: nil, move: .first, in: ids) == ids[0])
}

@Test("A selection the filter has hidden is treated as no selection")
func hiddenSelectionRestartsFromAnEnd() {
    let visible = [ids[2], ids[3]]
    #expect(MeetingListNavigation.destination(from: ids[0], move: .down, in: visible) == ids[2])
    #expect(MeetingListNavigation.destination(from: ids[0], move: .up, in: visible) == ids[3])
}

@Test("An empty list has nowhere to move")
func emptyListHasNoDestination() {
    #expect(MeetingListNavigation.destination(from: nil, move: .down, in: []) == nil)
    #expect(MeetingListNavigation.destination(from: ids[0], move: .up, in: []) == nil)
}

// MARK: - Reconciling with the visible set

@Test("A still-visible selection survives a change to the visible set")
func visibleSelectionSurvives() {
    #expect(MeetingListNavigation.reconcile(ids[1], with: ids) == ids[1])
}

@Test("A selection the search filtered away is dropped")
func filteredSelectionIsDropped() {
    #expect(MeetingListNavigation.reconcile(ids[1], with: [ids[2], ids[3]]) == nil)
    #expect(MeetingListNavigation.reconcile(ids[1], with: []) == nil)
    #expect(MeetingListNavigation.reconcile(nil, with: ids) == nil)
}

// MARK: - Deleting the selected row

@Test("Trashing a row hands the selection to the row that slides up")
func deleteSelectsTheFollowingRow() {
    #expect(MeetingListNavigation.selectionAfterRemoving(ids[1], from: ids) == ids[2])
}

@Test("Trashing the last row falls back to the new last row")
func deletingTheLastRowSelectsItsPredecessor() {
    #expect(MeetingListNavigation.selectionAfterRemoving(ids[3], from: ids) == ids[2])
}

@Test("Trashing the only row clears the selection")
func deletingTheOnlyRowClearsSelection() {
    #expect(MeetingListNavigation.selectionAfterRemoving(ids[0], from: [ids[0]]) == nil)
}

@Test("Removing a row that isn't listed clears the selection")
func deletingAnUnlistedRowClearsSelection() {
    #expect(MeetingListNavigation.selectionAfterRemoving(ids[0], from: [ids[1], ids[2]]) == nil)
}
