//
//  MeetingModels.swift
//  Echo
//
//  On-disk models for the persistent meeting library (SPEC-03). These types are
//  a binding contract: SPEC-06 (RAG index sidecar) and SPEC-08 (OKF pages) are
//  written against the folder-per-meeting layout and this API, so field names
//  and the `schemaVersion` gate must stay stable (v1 is the first persisted
//  version — no migrations yet).
//

import Foundation

/// The small, always-loaded header for one meeting. `listMetas` reads only
/// these (never the full transcript) so opening the app stays cheap even with a
/// long history — the transcript and summary live in sibling files.
nonisolated struct MeetingMeta: Codable, Hashable, Identifiable, Sendable {
    /// Bumped only by a future migration; readers reject folders they don't
    /// understand rather than guessing. v1 is the first persisted version.
    var schemaVersion: Int
    let id: UUID
    /// Auto-generated at save time, e.g. "Meeting — Jul 13, 2026, 10:30".
    /// Renaming is out of scope (SPEC-03 §9); it is a plain `String` so a later
    /// feature can make it user-editable without a schema change.
    var title: String
    var startedAt: Date
    var endedAt: Date
    var segmentCount: Int
    var hasSummary: Bool

    /// Total transcript word count, denormalized here so the list can show it
    /// without loading the (potentially large) transcript. Optional and encoded
    /// only when present (`encodeIfPresent`): folders written before this field
    /// existed decode to `nil`, and the on-disk bytes of a meeting that never had
    /// one are unchanged — the SPEC-06/08 golden stays byte-stable. The library
    /// populates it (it owns the segments at save time); the store never injects
    /// it, so an untouched `meta.json` keeps its original shape.
    var wordCount: Int?

    /// A single-sentence, AI-generated caption shown under the title in the
    /// list. Deliberately distinct from `MeetingSummary.shortSummary` and never
    /// rendered inside the summary view — it is a headline for the row only.
    /// Written when the summary lands; `nil` until then (or for meetings that
    /// predate the feature).
    var oneLineDescription: String?

    /// When the meeting was moved to Trash, or `nil` if it is live in the
    /// library. A trashed meeting keeps all its files; the library hides it from
    /// "All Meetings", lists it under "Trash", and permanently deletes it once
    /// this timestamp is older than the retention window.
    var trashedAt: Date?

    /// Wall-clock length of the meeting. Computed, so it is never encoded — the
    /// two timestamps are the source of truth.
    var duration: TimeInterval { endedAt.timeIntervalSince(startedAt) }

    /// Whether the meeting is currently in Trash.
    var isTrashed: Bool { trashedAt != nil }

    nonisolated init(
        schemaVersion: Int = 1,
        id: UUID,
        title: String,
        startedAt: Date,
        endedAt: Date,
        segmentCount: Int,
        hasSummary: Bool,
        wordCount: Int? = nil,
        oneLineDescription: String? = nil,
        trashedAt: Date? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.title = title
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.segmentCount = segmentCount
        self.hasSummary = hasSummary
        self.wordCount = wordCount
        self.oneLineDescription = oneLineDescription
        self.trashedAt = trashedAt
    }

    /// The default title for a freshly stopped recording. Fixed en-US format
    /// (via `en_US_POSIX`) so the on-disk title is stable regardless of the
    /// device's locale/clock preferences. The formatter is built per call
    /// (once per saved meeting — negligible) to avoid shared non-Sendable state.
    nonisolated static func autoTitle(startedAt: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMM d, yyyy, HH:mm"
        return "Meeting — " + formatter.string(from: startedAt)
    }

    /// Canonical transcript word count — one source of truth for the list row,
    /// the menu-bar stat, and the value denormalized into `wordCount`. Splits on
    /// whitespace, matching how a reader counts words.
    nonisolated static func wordCount(of segments: [TranscriptSegment]) -> Int {
        segments.reduce(0) { $0 + $1.text.split(whereSeparator: \.isWhitespace).count }
    }
}

/// A whole meeting in memory: the header plus its transcript and (optional)
/// summary. `MeetingStore` splits it across `meta.json` / `transcript.json` /
/// `summary.json` on save and reassembles it on load.
nonisolated struct MeetingRecord: Sendable {
    var meta: MeetingMeta
    var segments: [TranscriptSegment]
    var summary: MeetingSummary?

    nonisolated init(meta: MeetingMeta, segments: [TranscriptSegment], summary: MeetingSummary? = nil) {
        self.meta = meta
        self.segments = segments
        self.summary = summary
    }
}
