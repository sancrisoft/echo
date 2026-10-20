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
        /// The session being recorded: the window's view of a meeting that
        /// is not on disk yet.
        case recording
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

    /// Whether the window shows the welcome screen in place of the workspace.
    /// Set at launch by the composition root when `WelcomeGate` says so, and
    /// cleared when the user leaves it; persisting that the user left is the
    /// settings' business, not navigation's.
    public private(set) var showsWelcome = false

    public init() {}

    // MARK: - The welcome screen

    public func presentWelcome() {
        showsWelcome = true
    }

    public func leaveWelcome() {
        showsWelcome = false
    }

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

    /// Where the library opens with nothing selected: never on nothing. The
    /// meeting selected stays while the library holds it; otherwise the
    /// window opens on the meeting last open, and when that one is gone, on
    /// the most recent (product owner, 2026-10-02). An empty library has
    /// nothing to open, and the window says so instead.
    public func settleSelection(in metas: [MeetingMeta], lastOpen: UUID?) {
        guard !metas.isEmpty else { return }
        if let selectedMeetingID, metas.contains(where: { $0.id == selectedMeetingID }) { return }
        if let lastOpen, metas.contains(where: { $0.id == lastOpen }) {
            selectedMeetingID = lastOpen
            return
        }
        selectedMeetingID = metas.max { $0.startedAt < $1.startedAt }?.id
    }

    /// Drops the trash selection when its row is gone.
    public func reconcileTrashSelection(with trashed: [MeetingMeta]) {
        selectedTrashedID = MeetingListSelection.reconcile(selectedTrashedID, with: trashed.map(\.id))
    }

    // MARK: - The live session

    /// Shows the session being recorded in the document's place. The meeting
    /// selection survives underneath, as it does through Trash and Settings.
    public func showLiveSession() {
        section = .recording
    }

    /// Capture ended while the window showed it. The window follows the
    /// meeting into the library: it opens the one the stop saved — the one
    /// the session is now working on — or, with none, the library as it was.
    /// Showing anything else, nothing moves: a stop made from the island does
    /// not pull the window away from what the user is reading.
    public func liveSessionEnded(savedMeeting: UUID?) {
        guard section == .recording else { return }
        if let savedMeeting {
            open(savedMeeting)
        } else {
            section = .meetings
        }
    }
}
