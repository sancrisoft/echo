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

/// What produced the meeting's *current* persisted transcript (SP-007,
/// ADR-022): a display/diagnostics record of a completed outcome, written in
/// the same step as the transcript it describes — never a state marker driving
/// the work queue (the ADR-016 reconciliation). The raw strings are an on-disk
/// contract: the ADR-024 launch scan reads `source` back to disambiguate
/// pending meetings from terminal drafts, so they must never change.
nonisolated struct TranscriptProvenance: Codable, Hashable, Sendable {
    /// What state the meeting's transcript converged to.
    nonisolated enum Source: String, Codable, Hashable, Sendable {
        /// The pass succeeded — `transcript.json` holds its output.
        case finalPass
        /// The pass exhausted its retries: the meeting has NO transcript, its
        /// audio is kept, and only a manual Retry opens a new cycle.
        case terminalFailure
        /// Legacy, pre-Parakeet: the live transcript stood as a draft after a
        /// terminal pass failure. Still a legal on-disk value — those meetings
        /// have real text and keep their draft face — but nothing writes it
        /// any more (there is no live transcript to floor on).
        case liveFloor
    }

    var source: Source
    /// The real speech-checkpoint name that produced the transcript (SP-005
    /// naming-honesty register), e.g. "parakeet-tdt-0.6b-v3" today, or the
    /// Whisper variant ids on pre-migration meetings.
    var modelName: String
    /// Which model class served the transcript. "universal" since the Parakeet
    /// migration — there is one class now; pre-migration metas carry the old
    /// RAM-tier raw values ("fullLargeV3" / "reuseLive"). A plain string
    /// precisely so historical values keep decoding.
    var tier: String
    /// Legacy: true when a full-tier machine's Whisper pass was served by the
    /// live model instead. Always false since the migration (one model, no
    /// fallback), kept so old metas decode.
    var servedByFallback: Bool

    nonisolated init(source: Source, modelName: String, tier: String, servedByFallback: Bool) {
        self.source = source
        self.modelName = modelName
        self.tier = tier
        self.servedByFallback = servedByFallback
    }
}

/// The session's *effective* capture scope, persisted on the meeting's meta
/// (SP-008, ADR-027): what the system tap actually covered — which, under the
/// start-time fallback, may be wider than what the user requested. Inherits
/// ADR-022's register discipline wholesale: written with the artifacts it
/// describes, display and diagnostics only, never scheduling. Absent on
/// pre-SP-008 meetings.
nonisolated struct CaptureScopeRecord: Codable, Hashable, Sendable {

    /// The canonical kind strings — an on-disk contract, so they never change.
    nonisolated static let everythingKind = "everything"
    nonisolated static let appKind = "app"

    /// "everything" or "app" — a plain string (not an enum) so a meta written
    /// by a future build with a new scope kind still decodes here instead of
    /// tumbling the whole meeting out of the list.
    var kind: String
    /// The scoped app's display name (island copy, e.g. "Zoom"); `nil` for an
    /// everything session.
    var appName: String?

    nonisolated init(kind: String, appName: String? = nil) {
        self.kind = kind
        self.appName = appName
    }

    /// The mapping from a session's effective `CaptureScope` to its persisted
    /// record — the only place the two shapes meet.
    nonisolated init(scope: CaptureScope) {
        switch scope {
        case .everything:
            self.init(kind: Self.everythingKind)
        case .app(let app):
            self.init(kind: Self.appKind, appName: app.displayName)
        }
    }

    /// The dashboard's scope caption for a *past* meeting: "Zoom only" for a
    /// scoped record; `nil` for everything — and for any unknown future kind,
    /// which must render as nothing rather than guess (ADR-027: absent or not
    /// understood is never an error). An absent record reads as `nil` via
    /// optional chaining, completing the everything/absent/unknown triple.
    var scopedDisplayLabel: String? {
        guard kind == Self.appKind, let appName else { return nil }
        return "\(appName) only"
    }
}

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

    /// Provenance of the persisted transcript (SP-007, ADR-022). Optional and
    /// encoded only when present, like `wordCount`: pre-SP-007 metas decode to
    /// `nil` (the UI renders "unknown"), and an untouched old `meta.json`
    /// keeps its exact bytes. Written only in the same step as the transcript
    /// it describes (`replaceTranscript` / `recordLiveFloorProvenance`).
    var transcriptProvenance: TranscriptProvenance?

    /// The real name of the summary model that wrote `summary.json` (SP-007,
    /// ADR-022), recorded by `attachSummary` in its existing meta write. Same
    /// additive-optional discipline as `transcriptProvenance`.
    var summaryModelName: String?

    /// The session's effective capture scope (SP-008, ADR-027). Same
    /// additive-optional discipline as `transcriptProvenance`: pre-SP-008
    /// metas decode to `nil` (rendered as nothing), an untouched old
    /// `meta.json` keeps its exact bytes. Written once, at persist time — the
    /// scope is fixed by the end of session start and never changes after.
    var captureScope: CaptureScopeRecord?

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
        transcriptProvenance: TranscriptProvenance? = nil,
        summaryModelName: String? = nil,
        captureScope: CaptureScopeRecord? = nil,
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
        self.transcriptProvenance = transcriptProvenance
        self.summaryModelName = summaryModelName
        self.captureScope = captureScope
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
