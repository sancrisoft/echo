//
//  WorkspaceModel.swift
//  Workspace
//
//  The window's one navigation truth: which section is showing, which meeting
//  is selected, which document tab is open, how the list is sorted, and the
//  ⌘K palette — whether it is up, what is typed in it, and where a result it
//  opened should land. Lists render from it and write to it; none of them owns
//  a selection of its own (ADR-003). Every rule that decides where a selection
//  goes is a method here, so it is testable without a window.
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

    /// The trashed meeting whose document Trash shows in place of its list,
    /// opened with Return; `nil` shows the list. Looking never takes a
    /// meeting out of Trash (product owner, 2026-10-20).
    public private(set) var openedTrashedID: UUID?

    /// Summary first: it is what the user opens a meeting for.
    public var documentTab: DocumentTab = .summary

    /// Whether the ⌘K palette is over the window.
    public private(set) var isSearchPresented = false

    /// What is typed in the palette, and the scope Tab chose. Both outlive
    /// the palette, so ⌘K reopens on the last search.
    public var searchText = ""
    public var searchScope: MeetingSearchScope = .all

    /// Where the transcript's find should open, once the document of the
    /// meeting a result opened has loaded its turns. Taken once.
    public private(set) var findRequest: TranscriptFindRequest?

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

    /// The meetings the sidebar shows, in `sortOrder`. Every one of them:
    /// search is the palette's, and it never hides a row.
    public func visibleMeetings(in metas: [MeetingMeta]) -> [MeetingMeta] {
        MeetingSort.apply(to: metas, sort: sortOrder)
    }

    // MARK: - Selection rules

    /// Drops a library selection the library no longer contains — a trashed,
    /// deleted or purged meeting — so the document never shows a meeting that
    /// is gone.
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

    /// Drops the trash selection when its row is gone, and closes its
    /// document with it.
    public func reconcileTrashSelection(with trashed: [MeetingMeta]) {
        selectedTrashedID = MeetingListSelection.reconcile(selectedTrashedID, with: trashed.map(\.id))
        openedTrashedID = MeetingListSelection.reconcile(openedTrashedID, with: trashed.map(\.id))
    }

    // MARK: - The ⌘K palette

    public func presentSearch() {
        isSearchPresented = true
    }

    public func dismissSearch() {
        isSearchPresented = false
    }

    public func toggleSearch() {
        isSearchPresented.toggle()
    }

    /// Opens a result where its line is — the transcript, landing find on
    /// the turn shown, when the line is a turn; the summary otherwise — or,
    /// with `otherTab`, on the tab its line is not. A trashed meeting opens
    /// under Trash, as Trash opens it. The palette goes.
    ///
    /// - Parameter findText: what the transcript's find looks for. The
    ///   transcript opens with it whichever way it was reached; the turn is
    ///   only the landing when the line shown is that turn.
    public func open(_ hit: MeetingSearchHit, otherTab: Bool = false, findText: String?) {
        let tab: DocumentTab = hit.foundInTranscript != otherTab ? .transcript : .summary
        findRequest =
            if tab == .transcript, let findText {
                TranscriptFindRequest(meetingID: hit.id, text: findText, turn: otherTab ? nil : hit.turn)
            } else {
                nil
            }
        if hit.meta.isTrashed {
            openTrashed(hit.id)
            documentTab = tab
        } else {
            open(hit.id, tab: tab)
        }
        isSearchPresented = false
    }

    /// The find request waiting for this meeting's document, handed over
    /// once. A request for another meeting stays where it is.
    public func takeFindRequest(for id: UUID) -> TranscriptFindRequest? {
        guard let request = findRequest, request.meetingID == id else { return nil }
        findRequest = nil
        return request
    }

    // MARK: - Trash

    /// Shows Trash's list, whatever was open in it.
    public func showTrash() {
        section = .trash
        openedTrashedID = nil
    }

    /// Shows a trashed meeting's document without taking it out of Trash.
    public func openTrashed(_ id: UUID) {
        section = .trash
        selectedTrashedID = id
        openedTrashedID = id
    }

    /// Back from a trashed meeting's document to the list, on the same row.
    public func closeTrashed() {
        openedTrashedID = nil
    }

    /// Moves the trash selection with the keyboard. Returns `false` when
    /// there was nowhere to go, so the key can fall through.
    @discardableResult
    public func moveTrashSelection(_ move: MeetingListSelection.Move, in trashed: [MeetingMeta]) -> Bool {
        guard
            let destination = MeetingListSelection.destination(
                from: selectedTrashedID, move: move, in: trashed.map(\.id))
        else { return false }
        selectedTrashedID = destination
        return true
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

/// What a transcript's find opens on when a search result brought the user to
/// it: the words, and the turn to land on among their matches — `nil` for the
/// first match.
public struct TranscriptFindRequest: Equatable, Sendable {
    public let meetingID: UUID
    public let text: String
    public let turn: UUID?

    public init(meetingID: UUID, text: String, turn: UUID?) {
        self.meetingID = meetingID
        self.text = text
        self.turn = turn
    }
}
