//
//  MeetingMeta.swift
//  Meetings
//
//  The on-disk models of the meeting library. These types are a binding
//  contract with every folder v1 ever wrote (ADR-005): field names and raw
//  strings never change, new fields are optional with defaults and encoded only
//  when present, so an untouched old `meta.json` stays byte-identical after a
//  read-modify-write of something else.
//

import EchoCore
import Foundation

/// What produced the meeting's *current* persisted transcript: a display and
/// diagnostics record of a completed outcome, written in the same step as the
/// transcript it describes — never a state marker driving a work queue. The
/// raw strings are an on-disk contract: the launch scan reads `source` back to
/// tell pending meetings from terminal ones.
public struct TranscriptProvenance: Codable, Hashable, Sendable {

    /// What state the meeting's transcript converged to.
    public enum Source: String, Codable, Hashable, Sendable {
        /// The pass succeeded — `transcript.json` holds its output.
        case finalPass
        /// The pass exhausted its retries: the meeting has NO transcript, its
        /// audio is kept, and only a manual Retry opens a new cycle.
        case terminalFailure
        /// Legacy: a live transcript stood as a draft after a terminal pass
        /// failure. Still a legal on-disk value — those meetings have real text
        /// — but nothing writes it any more.
        case liveFloor
    }

    public var source: Source
    /// The real speech-model checkpoint name that produced the transcript,
    /// e.g. "parakeet-tdt-0.6b-v3", or a Whisper variant id on old meetings.
    public var modelName: String
    /// Which model class served the transcript. "universal" since the Parakeet
    /// migration; a plain string precisely so historical values keep decoding.
    public var tier: String
    /// Legacy: true when a full-tier machine's Whisper pass was served by the
    /// live model instead. Always false now, kept so old metas decode.
    public var servedByFallback: Bool

    public init(source: Source, modelName: String, tier: String = "universal", servedByFallback: Bool = false) {
        self.source = source
        self.modelName = modelName
        self.tier = tier
        self.servedByFallback = servedByFallback
    }
}

/// The session's *effective* capture scope, persisted on the meeting's meta:
/// what the system tap actually covered, which under the start-time fallback
/// may be wider than what the user requested. Display and diagnostics only,
/// never scheduling. Absent on meetings recorded before scoped capture.
public struct CaptureScopeRecord: Codable, Hashable, Sendable {

    /// The canonical kind strings — an on-disk contract, so they never change.
    public static let everythingKind = "everything"
    public static let appKind = "app"

    /// "everything" or "app" — a plain string (not an enum) so a meta written
    /// by a future build with a new scope kind still decodes here instead of
    /// tumbling the whole meeting out of the list.
    public var kind: String
    /// The scoped app's display name (e.g. "Zoom"); `nil` for an everything
    /// session.
    public var appName: String?

    public init(kind: String, appName: String? = nil) {
        self.kind = kind
        self.appName = appName
    }

    /// A session that captured all system audio.
    public static let everything = CaptureScopeRecord(kind: everythingKind)

    /// A session scoped to one app's processes.
    public static func app(named displayName: String) -> CaptureScopeRecord {
        CaptureScopeRecord(kind: appKind, appName: displayName)
    }

    /// The caption for a *past* meeting: "Zoom only" for a scoped record;
    /// `nil` for everything — and for any unknown future kind, which must
    /// render as nothing rather than guess.
    public var scopedDisplayLabel: String? {
        guard kind == Self.appKind, let appName else { return nil }
        return "\(appName) only"
    }
}

/// The small, always-loaded header for one meeting. `listMetas` reads only
/// these (never the transcript) so opening the app stays cheap with a long
/// history — the transcript and summary live in sibling files.
public struct MeetingMeta: Codable, Hashable, Identifiable, Sendable {

    /// The schema this build writes and the highest it understands. A folder
    /// with a higher version is rejected rather than guessed at.
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public let id: UUID
    /// Auto-generated at save time, user-editable afterwards.
    public var title: String
    public var startedAt: Date
    public var endedAt: Date
    public var segmentCount: Int
    public var hasSummary: Bool

    /// Total transcript word count, denormalized so the list never loads a
    /// transcript. Optional: folders written before it existed decode to
    /// `nil`, and their bytes stay untouched.
    public var wordCount: Int?

    /// A single-sentence, model-written caption for the row, distinct from the
    /// summary itself. Written when the summary lands.
    public var oneLineDescription: String?

    /// Provenance of the persisted transcript. `nil` on pre-provenance metas
    /// and on pending meetings whose pass has not concluded.
    public var transcriptProvenance: TranscriptProvenance?

    /// The real name of the summary model that wrote `summary.md`.
    public var summaryModelName: String?

    /// The session's effective capture scope; fixed at session start.
    public var captureScope: CaptureScopeRecord?

    /// When the meeting was moved to Trash, or `nil` if it is live. A trashed
    /// meeting keeps all its files; the library hides it from the main list
    /// and permanently deletes it once this is older than the retention.
    public var trashedAt: Date?

    /// Wall-clock length. Computed, never encoded — the two timestamps are the
    /// source of truth.
    public var duration: TimeInterval { endedAt.timeIntervalSince(startedAt) }

    public var isTrashed: Bool { trashedAt != nil }

    public init(
        schemaVersion: Int = MeetingMeta.currentSchemaVersion,
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
    /// device's locale and clock preferences.
    public static func autoTitle(startedAt: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMM d, yyyy, HH:mm"
        return "Meeting — " + formatter.string(from: startedAt)
    }
}

/// A whole meeting in memory: the header, its transcript, and its summary as
/// the Markdown document `summary.md` holds. `MeetingStore` splits it across
/// `meta.json` / `transcript.json` / `summary.md` on save and reassembles it on
/// load.
public struct MeetingRecord: Sendable, Equatable {
    public var meta: MeetingMeta
    public var segments: [TranscriptSegment]
    /// The summary document, or `nil` when the meeting has none.
    public var summaryMarkdown: String?

    public init(meta: MeetingMeta, segments: [TranscriptSegment], summaryMarkdown: String? = nil) {
        self.meta = meta
        self.segments = segments
        self.summaryMarkdown = summaryMarkdown
    }
}
