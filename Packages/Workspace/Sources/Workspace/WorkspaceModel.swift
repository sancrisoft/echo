//
//  WorkspaceModel.swift
//  Workspace
//
//  The window's one navigation truth: which section is showing, which meeting
//  is selected, which document tab is open, and how the list is filtered and
//  sorted. Lists render from it and write to it; none of them owns a selection
//  of its own (ADR-003). Every rule that decides where a selection goes is a
//  method here, so it is testable without a window.
//

import EchoCore
import Foundation
import Meetings
import Observation

@Observable
public final class WorkspaceModel {

    public enum Section: Hashable, Sendable {
        case meetings
        case trash
        case settings
    }

    public enum DocumentTab: Hashable, Sendable, CaseIterable {
        case summary
        case transcript

        public var title: String {
            switch self {
            case .summary: return "Summary"
            case .transcript: return "Transcript"
            }
        }
    }

    /// What the window shows to the right of the sidebar.
    public var section: Section = .meetings

    /// The meeting the document shows; survives a switch to Trash or Settings
    /// and back.
    public var selectedMeetingID: UUID?

    /// The meeting selected in Trash, independent of the library selection.
    public var selectedTrashedID: UUID?

    /// Summary first: it is what the user opens a meeting for.
    public var documentTab: DocumentTab = .summary

    /// The sidebar's filter text.
    public var searchText = ""

    public var sortOrder: MeetingSortOrder = .recent

    public init() {}

    // MARK: - Derived lists

    /// The meetings the sidebar shows, filtered by `searchText` and ordered by
    /// `sortOrder`.
    public func visibleMeetings(in metas: [MeetingMeta]) -> [MeetingMeta] {
        MeetingFilter.apply(to: metas, search: searchText, sort: sortOrder)
    }

    /// Whether the sidebar shows no rows because the search matched nothing
    /// (as opposed to an empty library).
    public func searchHidesEverything(in metas: [MeetingMeta]) -> Bool {
        !metas.isEmpty && visibleMeetings(in: metas).isEmpty && !searchText.isEmpty
    }

    // MARK: - Selection rules

    /// Drops a library selection the library no longer contains — a trashed,
    /// deleted or purged meeting — so the document never shows a meeting that
    /// is gone. A selection the *search* merely hides survives: the document
    /// stays while the user types.
    public func reconcileSelection(with metas: [MeetingMeta]) {
        selectedMeetingID = MeetingListSelection.reconcile(selectedMeetingID, with: metas.map(\.id))
    }

    /// Moves the library selection with the keyboard. Returns `false` when
    /// there was nowhere to go, so the key can fall through.
    @discardableResult
    public func moveSelection(_ move: MeetingListSelection.Move, in metas: [MeetingMeta]) -> Bool {
        let ids = visibleMeetings(in: metas).map(\.id)
        guard let destination = MeetingListSelection.destination(from: selectedMeetingID, move: move, in: ids)
        else { return false }
        selectedMeetingID = destination
        return true
    }

    /// Where the selection goes once `id` leaves the visible list (it was
    /// trashed): the row that slides up, so a run of deletes keeps working from
    /// the keyboard. Call before the mutation, with the list as it was.
    public func selectionAfterRemoving(_ id: UUID, in metas: [MeetingMeta]) {
        guard selectedMeetingID == id else { return }
        selectedMeetingID = MeetingListSelection.selectionAfterRemoving(id, from: visibleMeetings(in: metas).map(\.id))
    }

    /// Selects a meeting and shows the library, opening on the given tab.
    public func open(_ id: UUID, tab: DocumentTab? = nil) {
        section = .meetings
        selectedMeetingID = id
        if let tab { documentTab = tab }
    }

    /// Drops the trash selection when its row is gone.
    public func reconcileTrashSelection(with trashed: [MeetingMeta]) {
        selectedTrashedID = MeetingListSelection.reconcile(selectedTrashedID, with: trashed.map(\.id))
    }
}
