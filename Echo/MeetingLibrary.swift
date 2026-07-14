//
//  MeetingLibrary.swift
//  Echo
//
//  Main-actor, observable façade over `MeetingStore` for the dashboard sidebar
//  (SPEC-03). SPEC-03 §4.3 offers two shapes for the library state — inline on
//  `RecordingController`, or a small separate `@Observable`. This is the latter,
//  chosen so `RecordingController` stays focused on capture and the split-view
//  UI reads one clearly-scoped object: the list of meetings, the current
//  selection, and which meeting (if any) is currently backed by the live
//  session's in-memory state.
//

import Foundation
import Observation
import os

/// What the sidebar has selected. `.live` is the pinned "recording in progress"
/// row (only present while recording); `.meeting` is a saved meeting.
enum MeetingSelection: Hashable, Sendable {
    case live
    case meeting(UUID)
}

@Observable
@MainActor
final class MeetingLibrary {

    private static let log = Logger(subsystem: "com.sancrisoft.Echo", category: "MeetingLibrary")

    private let store: MeetingStore

    /// Headers for every saved meeting, newest first. Refreshed after each write.
    private(set) var metas: [MeetingMeta] = []

    /// The sidebar's current selection (bound by the List).
    var selection: MeetingSelection?

    /// The meeting whose transcript/summary is currently the *live* in-memory
    /// state on `RecordingState` (the just-stopped session, until the next
    /// recording wipes that state). While it equals the selected meeting, the
    /// detail view keeps showing the live state — so a summary can stream into
    /// the just-saved meeting's detail with no jump — instead of reloading the
    /// still-summary-less record from disk.
    private(set) var activeMeetingID: UUID?

    init(store: MeetingStore = MeetingStore()) {
        self.store = store
        Task { await refresh() }
    }

    /// Loads (or reloads) the meeting headers from disk.
    func refresh() async {
        metas = await store.listMetas()
    }

    /// Marks the start of a new recording: the previous session's live state is
    /// about to be wiped, and the "Live" row becomes the selection.
    func beginLiveSession() {
        activeMeetingID = nil
        selection = .live
    }

    /// Persists a freshly stopped recording (SPEC-03 criterion 1: saved BEFORE
    /// summary generation, so an LLM crash never loses the transcript). Selects
    /// the new meeting and marks it active so its detail shows the live state
    /// while the summary streams in. Returns the new id, or `nil` if the write
    /// failed (logged; the session is not interrupted).
    func persist(segments: [TranscriptSegment], startedAt: Date, endedAt: Date) async -> UUID? {
        let meta = MeetingMeta(
            id: UUID(),
            title: MeetingMeta.autoTitle(startedAt: startedAt),
            startedAt: startedAt,
            endedAt: endedAt,
            segmentCount: segments.count,
            hasSummary: false
        )
        do {
            try await store.save(MeetingRecord(meta: meta, segments: segments, summary: nil))
            await refresh()
            activeMeetingID = meta.id
            selection = .meeting(meta.id)
            return meta.id
        } catch {
            Self.log.error("Saving meeting failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Attaches a finished summary to an already-saved meeting (SPEC-03
    /// criterion 2). A failure leaves the meeting saved without a summary.
    func attachSummary(_ summary: MeetingSummary, to id: UUID) async {
        do {
            try await store.attachSummary(summary, to: id)
            await refresh()
        } catch {
            Self.log.error("Attaching summary failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Loads a full meeting for the detail view. Returns `nil` (logged) if the
    /// folder is missing or corrupt, so the UI can show an "unavailable" state
    /// instead of crashing.
    func loadRecord(_ id: UUID) async -> MeetingRecord? {
        do {
            return try await store.loadRecord(id)
        } catch {
            Self.log.error("Loading meeting failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Deletes a meeting's folder and refreshes the list, clearing the selection
    /// if it pointed at the deleted meeting.
    func delete(_ id: UUID) async {
        do {
            try await store.delete(id)
            if activeMeetingID == id { activeMeetingID = nil }
            if selection == .meeting(id) { selection = nil }
            await refresh()
        } catch {
            Self.log.error("Deleting meeting failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
