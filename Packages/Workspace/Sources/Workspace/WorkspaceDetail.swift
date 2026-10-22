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
//  window can find itself in. The live session is read the same way, from the
//  session's phase, so the window never shows a recording that has stopped.
//

import Foundation
import Meetings
import Recording

enum WorkspaceDetail: Equatable, Sendable {
    /// One meeting's document.
    case meeting(MeetingMeta)
    /// The session being recorded, before it is a meeting.
    case liveSession(LiveSession)
    /// The session is being torn down and saved. Nothing to show for the
    /// moment that takes: the session has no clock left and the meeting is
    /// not on disk yet.
    case savingSession
    /// Nothing has been recorded yet.
    case noMeetings
    /// There are meetings and none is selected.
    case noSelection
    case trash
    /// A trashed meeting's document, looked at from Trash.
    case trashedMeeting(MeetingMeta)
    case settings

    /// The pane for the window's current navigation.
    ///
    /// Trash and Settings take the document's place whatever is selected, so
    /// the selection survives a trip through them. Inside the library, a
    /// selection `meta` cannot name — trashed, deleted or purged between a
    /// click and the refresh that notices it — reads as no selection rather
    /// than as a document that cannot be loaded. The live session shows only
    /// while there is one: otherwise its section reads as the library.
    static func resolve(
        section: WorkspaceModel.Section,
        selection: UUID?,
        hasMeetings: Bool,
        meta: (UUID) -> MeetingMeta?,
        phase: RecordingPhase,
        openedTrashedID: UUID? = nil,
        trashedMeta: (UUID) -> MeetingMeta? = { _ in nil }
    ) -> WorkspaceDetail {
        switch section {
        case .trash:
            // A trashed meeting opened from the list shows while Trash still
            // holds it; restored or deleted, the list takes its place.
            if let openedTrashedID, let opened = trashedMeta(openedTrashedID) {
                return .trashedMeeting(opened)
            }
            return .trash
        case .settings:
            return .settings
        case .recording:
            switch phase {
            case .recording(let startedAt, let scope):
                return .liveSession(
                    LiveSession(startedAt: startedAt, capture: LiveSession.capture(scope.scopedApp?.displayName)))
            case .stopping:
                return .savingSession
            case .idle, .finalizing, .summarizing:
                return library(selection: selection, hasMeetings: hasMeetings, meta: meta)
            }
        case .meetings:
            return library(selection: selection, hasMeetings: hasMeetings, meta: meta)
        }
    }

    private static func library(
        selection: UUID?, hasMeetings: Bool, meta: (UUID) -> MeetingMeta?
    ) -> WorkspaceDetail {
        guard hasMeetings else { return .noMeetings }
        guard let selection, let meta = meta(selection) else { return .noSelection }
        return .meeting(meta)
    }
}

/// The session being recorded, as the window shows it: when it began and
/// what it captures. Nothing transcribed, nothing counted — there is none of
/// either until the stop.
struct LiveSession: Equatable, Sendable {
    let startedAt: Date
    /// "Zoom only", or "Everything": the session's effective coverage.
    let capture: String

    /// The capture in the island's words. Written again here rather than
    /// shared, because the island owns its own and Workspace cannot import
    /// it; the session's effective scope is the input to both.
    static func capture(_ scopedApp: String?) -> String {
        scopedApp.map { "\($0) only" } ?? "Everything"
    }
}
