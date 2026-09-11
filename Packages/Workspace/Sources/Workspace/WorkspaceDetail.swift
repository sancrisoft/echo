//
//  WorkspaceDetail.swift
//  Workspace
//
//  What the window shows to the right of the sidebar, as a value. The choice
//  is small but it is a rule, not a rendering detail: a selection the library
//  no longer holds must never reach the document, and an empty library is a
//  different screen from a library with nothing selected. As a value it is
//  decided in one place and exercised without a window.
//
//  It is resolved inside `body`, so it asks the library questions instead of
//  taking a copy of it: whether it holds anything, and which meeting one id
//  names. A `.meeting` therefore carries the meeting itself — the document can
//  always be drawn from it, and "selected but missing" is not a state the
//  window can find itself in.
//

import Foundation
import Meetings

enum WorkspaceDetail: Equatable, Sendable {
    /// One meeting's document.
    case meeting(MeetingMeta)
    /// Nothing has been recorded yet.
    case noMeetings
    /// There are meetings and none is selected.
    case noSelection
    case trash
    case settings

    /// The pane for the window's current navigation.
    ///
    /// Trash and Settings take the document's place whatever is selected, so
    /// the selection survives a trip through them. Inside the library, a
    /// selection `meta` cannot name — trashed, deleted or purged between a
    /// click and the refresh that notices it — reads as no selection rather
    /// than as a document that cannot be loaded.
    static func resolve(
        section: WorkspaceModel.Section,
        selection: UUID?,
        hasMeetings: Bool,
        meta: (UUID) -> MeetingMeta?
    ) -> WorkspaceDetail {
        switch section {
        case .trash:
            return .trash
        case .settings:
            return .settings
        case .meetings:
            guard hasMeetings else { return .noMeetings }
            guard let selection, let meta = meta(selection) else { return .noSelection }
            return .meeting(meta)
        }
    }
}
