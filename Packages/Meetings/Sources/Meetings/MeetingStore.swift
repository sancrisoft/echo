//
//  MeetingStore.swift
//  Meetings
//
//  The persistent meeting library: one folder per meeting under the data root's
//  `Meetings/`, JSON for the meta and transcript, plain Markdown (`summary.md`)
//  as the summary. An actor so the JSON encode/decode (a 3 h transcript is a
//  few MB) runs off the main thread and concurrent saves, loads and deletes
//  serialize. This is the only type that touches the meetings tree.
//
//  Why plain files and not SwiftData/SQLite: volume is tiny (tens of meetings),
//  reads are trivial, zero dependencies, human-inspectable, and the folder
//  gives a natural home to per-meeting sidecars. If it ever hurts, migrating
//  behind this actor is cheap.
//
//  Disciplines every method keeps (ADR-005):
//  - Writes are atomic (temp file + rename) and ordered: transcript, summary,
//    `meta.json` last, so a reader that finds a meta also finds its files.
//  - Deletions are named targets, never a directory sweep, so sidecars other
//    features drop in a folder are never collateral.
//  - The audio file *name family* is the state: `retained-*` means a pending
//    transcription, `audio-*` a preserved recording, `debug-kept-*` a fixture.
//

import EchoCore
import Foundation
import os

public enum MeetingStoreError: Error, LocalizedError, Equatable {
    /// No folder or no `meta.json` for this id.
    case meetingNotFound(UUID)
    /// The folder was written by a build that understands a newer schema.
    case unsupportedSchemaVersion(UUID, Int)

    public var errorDescription: String? {
        switch self {
        case .meetingNotFound(let id):
            return "Meeting \(id.uuidString) does not exist."
        case .unsupportedSchemaVersion(let id, let version):
            return "Meeting \(id.uuidString) uses schema version \(version), newer than this build understands."
        }
    }
}

public actor MeetingStore {

    private static let log = Logger(subsystem: AppIdentity.logSubsystem, category: "MeetingStore")

    /// Root under which every meeting folder lives.
    private let root: URL

    /// `.sortedKeys` + `.iso8601` make the on-disk bytes deterministic, so
    /// diffs are readable and the encoder is testable with a golden.
    /// `.prettyPrinted` keeps the files inspectable by hand.
    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    public init(rootDirectory: URL) {
        self.root = rootDirectory
    }

    /// The store at the data root's `Meetings/`.
    public init(dataRoot: DataRoot) {
        self.init(rootDirectory: dataRoot.meetings)
    }

    // MARK: - Locations

    /// The root under which every meeting folder lives. `nonisolated` so the
    /// storage measurement can read it without awaiting the actor.
    public nonisolated var rootDirectory: URL { root }

    /// The folder for a meeting. `nonisolated` and side-effect free so callers
    /// (Reveal in Finder, export) can locate it without awaiting the actor and
    /// without creating anything.
    public nonisolated func directory(for id: UUID) -> URL {
        root.appending(path: id.uuidString, directoryHint: .isDirectory)
    }

    // MARK: - Write

    /// Creates the meeting folder and writes `meta.json` (+ `transcript.json`
    /// when the record carries segments, + `summary.md` when it carries a
    /// summary). The meta is normalized to what actually landed on disk:
    /// `segmentCount` and `hasSummary` describe the files, so a summary that
    /// resolves to no Markdown claims nothing.
    ///
    /// A segment-less save is the normal stop path: a just-stopped meeting has
    /// retained audio and no words yet, and writing an empty `transcript.json`
    /// beside it would claim a transcript that doesn't exist.
    public func save(_ record: MeetingRecord) throws {
        let directory = directory(for: record.meta.id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        var meta = record.meta
        meta.segmentCount = record.segments.count

        if !record.segments.isEmpty {
            try writeJSON(record.segments, to: directory.appending(path: Filename.transcript))
        }
        if let markdown = record.summaryMarkdown {
            meta.hasSummary = try writeSummaryMarkdown(markdown, in: directory)
        } else {
            meta.hasSummary = false
        }
        // meta.json last: a reader that finds a meta also finds its transcript.
        try writeJSON(meta, to: directory.appending(path: Filename.meta))
    }

    /// Writes `summary.md` and flips `meta.hasSummary`. Called when a summary
    /// lands after the meeting was already saved. Throws if the meeting is
    /// missing.
    ///
    /// A summary that resolves to no Markdown is a total no-op past that
    /// existence check and returns `false`: nothing lands on disk, so no meta
    /// bit — `hasSummary`, the caption, the model name — may describe it.
    ///
    /// `caption`, when provided, is stored as the row's one-line description
    /// in the same write; `modelName` records which summary model wrote the
    /// notes. Passing `nil` for either leaves the existing value untouched.
    @discardableResult
    public func attachSummary(
        markdown: String, caption: String? = nil, modelName: String? = nil, to id: UUID
    ) throws
        -> Bool
    {
        let directory = directory(for: id)
        var meta = try loadMeta(id)
        guard try writeSummaryMarkdown(markdown, in: directory) else { return false }
        meta.hasSummary = true
        if let caption { meta.oneLineDescription = caption }
        if let modelName { meta.summaryModelName = modelName }
        try writeJSON(meta, to: directory.appending(path: Filename.meta))
        return true
    }

    /// Rewrites only `meta.json` for an existing meeting (rename, trash and
    /// restore, word-count backfill). The caller owns the full, up-to-date
    /// meta; this persists it verbatim. Throws if the folder is missing, so a
    /// caller cannot resurrect a deleted meeting by updating it.
    public func updateMeta(_ meta: MeetingMeta) throws {
        let directory = directory(for: meta.id)
        guard FileManager.default.fileExists(atPath: directory.path) else {
            throw MeetingStoreError.meetingNotFound(meta.id)
        }
        try writeJSON(meta, to: directory.appending(path: Filename.meta))
    }

    // MARK: - Read

    /// Every saved meeting's header, newest first. Loads only `meta.json`
    /// (small) so app launch never deserializes full transcripts. A folder
    /// whose meta is missing, corrupt or too new is skipped with a trace — one
    /// bad meeting never tumbles the whole list.
    public func listMetas() -> [MeetingMeta] {
        let fileManager = FileManager.default
        guard
            let entries = try? fileManager.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
        else {
            // Root doesn't exist yet (no meeting ever saved) — an empty
            // library, not an error.
            return []
        }

        var metas: [MeetingMeta] = []
        for entry in entries {
            guard (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
            do {
                metas.append(try decodeMeta(at: entry.appending(path: Filename.meta), folder: entry.lastPathComponent))
            } catch {
                ErrorTrace.record(
                    "Skipping unreadable meeting folder",
                    error: error,
                    category: "MeetingStore",
                    metadata: ["folder": entry.lastPathComponent]
                )
            }
        }
        return metas.sorted { $0.startedAt > $1.startedAt }
    }

    /// One meeting's header. Throws `meetingNotFound` when the folder or its
    /// meta is missing, `unsupportedSchemaVersion` when it is too new, or the
    /// decoding error when it is corrupt.
    public func loadMeta(_ id: UUID) throws -> MeetingMeta {
        let url = directory(for: id).appending(path: Filename.meta)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw MeetingStoreError.meetingNotFound(id)
        }
        return try decodeMeta(at: url, folder: id.uuidString)
    }

    /// The full meeting (header + transcript + summary if present). Throws if
    /// the folder or meta is missing or corrupt, or if a transcript that exists
    /// cannot be read.
    ///
    /// A meeting with NO `transcript.json` loads with no segments rather than
    /// throwing: that is the honest state of a meeting whose pass hasn't
    /// produced words yet (pending) or never will (terminal failure). Only an
    /// absent file reads that way — an unreadable one still throws, so real
    /// corruption is never silently rendered as "no transcript".
    public func loadRecord(_ id: UUID) throws -> MeetingRecord {
        let directory = directory(for: id)
        let meta = try loadMeta(id)
        let transcriptURL = directory.appending(path: Filename.transcript)
        let segments =
            FileManager.default.fileExists(atPath: transcriptURL.path)
            ? try decode([TranscriptSegment].self, from: transcriptURL)
            : []
        let summary = try loadSummaryMarkdown(in: directory)
        return MeetingRecord(meta: meta, segments: segments, summaryMarkdown: summary)
    }

    /// The stored summary, Markdown first: `summary.md` IS the store and loads
    /// verbatim. A folder that only has the legacy `summary.json` (the launch
    /// fold hasn't reached it, or its conversion failed) still loads through
    /// the legacy decoder. When BOTH files exist — a crash between the fold's
    /// md-write and its json-delete — the Markdown wins: it was derived from
    /// that very json, and it is the only file the app writes now.
    private func loadSummaryMarkdown(in directory: URL) throws -> String? {
        let markdownURL = directory.appending(path: Filename.summaryMarkdown)
        if FileManager.default.fileExists(atPath: markdownURL.path) {
            return try String(decoding: Data(contentsOf: markdownURL), as: UTF8.self)
        }
        let jsonURL = directory.appending(path: Filename.legacySummary)
        guard FileManager.default.fileExists(atPath: jsonURL.path) else { return nil }
        let legacy = try decode(LegacyMeetingSummary.self, from: jsonURL)
        return legacy.resolvedMarkdown
    }

    // MARK: - Delete

    /// Removes the whole meeting folder, including any sidecars other features
    /// dropped in it. A no-op if it is already gone.
    public func delete(_ id: UUID) throws {
        let directory = directory(for: id)
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        try FileManager.default.removeItem(at: directory)
    }

    // MARK: - Transcript replacement

    /// Atomically replaces a meeting's transcript with the complete final
    /// segment set and re-derives the meta fields that describe it (segment
    /// and word counts, plus the transcript's provenance — written in the same
    /// step as the artifact it describes). Transcript first, meta after,
    /// mirroring `save`'s meta-last discipline. Every write is atomic, so any
    /// failure leaves the previous transcript byte-identical.
    public func replaceTranscript(
        _ segments: [TranscriptSegment], provenance: TranscriptProvenance, for id: UUID
    )
        throws
    {
        let directory = directory(for: id)
        // Load the meta up front: a missing or corrupt meeting fails here,
        // before the transcript is touched.
        var meta = try loadMeta(id)

        try writeJSON(segments, to: directory.appending(path: Filename.transcript))

        meta.segmentCount = segments.count
        meta.wordCount = TranscriptSegment.wordCount(of: segments)
        meta.transcriptProvenance = provenance
        try writeJSON(meta, to: directory.appending(path: Filename.meta))
    }

    /// Records the meeting's terminal transcript provenance — a single atomic
    /// `meta.json` write, no other file touched: the terminal transition is
    /// safe as a state bit precisely because nothing else is written beside
    /// it. The retained audio stays for a manual Retry, and this bit is what
    /// ends the meeting's pending classification.
    public func recordTerminalProvenance(for id: UUID, provenance: TranscriptProvenance) throws {
        var meta = try loadMeta(id)
        meta.transcriptProvenance = provenance
        try writeJSON(meta, to: directory(for: id).appending(path: Filename.meta))
    }

    // MARK: - Retained audio (pending transcription)

    /// Canonical name of a channel's retained-audio file inside its meeting
    /// folder. One source of truth for the retention writer, the pending
    /// query and the cleanup targets.
    public nonisolated static func retainedAudioFileName(for channel: AudioChannel) -> String {
        switch channel {
        case .microphone: return "retained-mic.m4a"
        case .system: return "retained-system.m4a"
        }
    }

    /// The retained-audio files currently present in a meeting's folder.
    public func retainedAudioFiles(for id: UUID) -> [AudioChannel: URL] {
        files(named: Self.retainedAudioFileName, in: id)
    }

    /// Whether the folder still holds retained audio — the exact lifetime of
    /// the failed state's Retry affordance.
    public func hasRetainedAudio(for id: UUID) -> Bool {
        !retainedAudioFiles(for: id).isEmpty
    }

    /// What a meeting's retained audio means. Presence alone does not imply
    /// pending — terminal convergence keeps the audio — so the recorded
    /// transcript-provenance source breaks the tie.
    public enum RetainedAudioDisposition: Equatable, Sendable {
        /// No retained audio: the meeting is final, or retention never armed.
        case none
        /// Audio with no transcript provenance: an unfinished cycle — the
        /// launch scan auto-resumes it.
        case pending
        /// Audio with `terminalFailure` provenance: the pass exhausted its
        /// retries and the meeting has no transcript — never auto-resumed;
        /// only the user's Retry opens a new cycle.
        case terminalFailure
        /// Audio with legacy `liveFloor` provenance: a pre-migration draft
        /// whose live transcript stands — never auto-resumed either.
        case terminalDraft
        /// Audio with `finalPass` provenance: the orphan of a success whose
        /// cleanup crashed between the transcript replace and the audio
        /// deletion — swept, never re-run (the transcript is already final).
        case finalPassOrphan
    }

    /// The pure classification rule — one source of truth for the disposition
    /// query, the launch scan and the orphan sweep.
    public nonisolated static func classifyRetainedAudio(
        present: Bool,
        transcriptSource: TranscriptProvenance.Source?
    ) -> RetainedAudioDisposition {
        guard present else { return .none }
        switch transcriptSource {
        case nil: return .pending
        case .terminalFailure: return .terminalFailure
        case .liveFloor: return .terminalDraft
        case .finalPass: return .finalPassOrphan
        }
    }

    /// Classifies one meeting's retained audio from disk: file presence plus
    /// the meta's recorded provenance, nothing else. An unreadable meta
    /// classifies like a missing provenance; the scan never reaches it anyway
    /// (`listMetas` skips it).
    public func retainedAudioDisposition(for id: UUID) -> RetainedAudioDisposition {
        let meta = try? loadMeta(id)
        return Self.classifyRetainedAudio(
            present: hasRetainedAudio(for: id),
            transcriptSource: meta?.transcriptProvenance?.source
        )
    }

    /// Retained audio marks a meeting pending only while no transcript
    /// provenance is recorded.
    public func isPendingFinalization(_ id: UUID) -> Bool {
        retainedAudioDisposition(for: id) == .pending
    }

    /// Meetings still pending transcription, newest first — the launch-resume
    /// work queue (crash-resume is a directory scan) and the summary
    /// scheduler's exclusion set. Terminal failures and legacy drafts rest
    /// until the user retries; orphans are sweep targets. Trashed meetings are
    /// excluded: the user set them aside, and their retention leaves with the
    /// folder (a restore surfaces them to the next launch's scan).
    public func pendingFinalizationMeetingIDs() -> [UUID] {
        listMetas()
            .filter { !$0.isTrashed && disposition(of: $0) == .pending }
            .map(\.id)
    }

    /// Deletes the retained audio of meetings whose provenance says
    /// `finalPass`: orphans of a success whose cleanup crashed after the
    /// transcript replace. Their transcript is already final, so the audio is
    /// swept — never re-run. Runs at launch, before the resume enqueue.
    public func sweepFinalPassAudioOrphans() {
        for meta in listMetas() where !meta.isTrashed && disposition(of: meta) == .finalPassOrphan {
            deleteRetainedAudio(for: meta.id)
        }
    }

    private func disposition(of meta: MeetingMeta) -> RetainedAudioDisposition {
        Self.classifyRetainedAudio(
            present: hasRetainedAudio(for: meta.id),
            transcriptSource: meta.transcriptProvenance?.source
        )
    }

    /// Hidden sibling of the meeting folders where a live session stages its
    /// retention before the meeting persists. One source of truth for the
    /// writer's destination and the launch sweep.
    public nonisolated static let retentionStagingDirectoryName = ".retention-staging"

    public nonisolated var retentionStagingDirectory: URL {
        root.appending(path: Self.retentionStagingDirectoryName, directoryHint: .isDirectory)
    }

    /// Deletes the whole retention-staging tree — session folders a quit or
    /// crash orphaned. Staged audio is disposable by design: it was never
    /// adopted, so no meeting points at it and no pending marker involves it.
    /// Meeting folders are never touched (the staging root is a named target,
    /// not a sweep of the meetings tree). A failure is non-fatal — traced,
    /// retried next launch.
    public func sweepRetentionStaging() {
        let staging = retentionStagingDirectory
        guard FileManager.default.fileExists(atPath: staging.path) else { return }
        do {
            try FileManager.default.removeItem(at: staging)
        } catch {
            ErrorTrace.record("Retention-staging sweep failed", error: error, category: "MeetingStore")
        }
    }

    /// Moves staged retention files into the meeting's folder, arming the
    /// pending marker. All-or-nothing: a failure undoes any file already moved
    /// in — a partial channel set must never read as pending, or a resumed
    /// pass would finalize half a meeting.
    public func adoptRetainedAudio(_ staged: [AudioChannel: URL], for id: UUID) throws -> [AudioChannel: URL] {
        let directory = directory(for: id)
        var adopted: [AudioChannel: URL] = [:]
        do {
            for (channel, source) in staged {
                let destination = directory.appending(
                    path: Self.retainedAudioFileName(for: channel), directoryHint: .notDirectory)
                try FileManager.default.moveItem(at: source, to: destination)
                adopted[channel] = destination
            }
        } catch {
            for url in adopted.values {
                try? FileManager.default.removeItem(at: url)
            }
            throw error
        }
        return adopted
    }

    /// Deletes exactly this meeting's retained-audio files — named targets,
    /// never a directory sweep: sibling files and sidecars are untouched. A
    /// per-file failure is non-fatal (traced; a later pass or launch retries).
    public func deleteRetainedAudio(for id: UUID) {
        delete(files: retainedAudioFiles(for: id), of: id, what: "Retained-audio cleanup failed")
    }

    // MARK: - Preserved recordings ("keep recordings")

    /// Canonical name of a channel's *preserved* audio file. Deliberately NOT
    /// `retained-*`: `retainedAudioFiles` never looks for these, so a preserved
    /// meeting classifies `.none` — never auto-resumed, never swept. The files
    /// stay inside the meeting's own folder, so trashing or deleting the
    /// meeting takes them along.
    public nonisolated static func preservedAudioFileName(for channel: AudioChannel) -> String {
        switch channel {
        case .microphone: return "audio-mic.m4a"
        case .system: return "audio-system.m4a"
        }
    }

    /// The preserved-audio files currently present in a meeting's folder.
    public func preservedAudioFiles(for id: UUID) -> [AudioChannel: URL] {
        files(named: Self.preservedAudioFileName, in: id)
    }

    /// Whether the folder holds a preserved recording — the exact lifetime of
    /// the player, Delete Recording and Re-transcribe affordances.
    public func hasPreservedAudio(for id: UUID) -> Bool {
        !preservedAudioFiles(for: id).isEmpty
    }

    /// Preserves the meeting's retained audio as its saved recording: each
    /// retained file present is RENAMED to its preserved name in the same
    /// folder (a move — cheap and atomic on one volume, bytes untouched). The
    /// success path's normal `deleteRetainedAudio` then finds nothing,
    /// harmlessly. An existing preserved file is replaced first — the
    /// overwrite case is a re-transcribe writing the same bytes back. Returns
    /// whether anything was preserved. A per-file failure is non-fatal: the
    /// file stays under its retained name and the normal deletion cleans it.
    @discardableResult
    public func preserveRetainedAudio(for id: UUID) -> Bool {
        rename(
            retainedAudioFiles(for: id), of: id, to: Self.preservedAudioFileName,
            what: "Preserving retained audio failed")
    }

    /// Deletes exactly this meeting's preserved-audio files — named targets,
    /// never a directory sweep. A per-file failure is non-fatal (traced).
    public func deletePreservedAudio(for id: UUID) {
        delete(files: preservedAudioFiles(for: id), of: id, what: "Preserved-audio deletion failed")
    }

    /// Clones the meeting's preserved audio back to its retained names —
    /// re-transcribe's arming step. COPY, never rename: the preserved copy is
    /// the archive, so it survives crashes, terminal failures and a mid-flight
    /// retention-setting change. On APFS the copy is a clone (no real disk
    /// cost). Crash-safety needs no new state: a quit between this clone and
    /// the pass concluding leaves `retained-*` + `finalPass` provenance — the
    /// orphan class, swept at the next launch while `audio-*` survives and the
    /// previous transcript stands. All-or-nothing like `adoptRetainedAudio`: a
    /// partial channel set must never feed a pass.
    public func cloneAudioForRetranscription(for id: UUID) -> Bool {
        let preserved = preservedAudioFiles(for: id)
        guard !preserved.isEmpty else { return false }
        var cloned: [URL] = []
        do {
            for (channel, source) in preserved {
                let destination = directory(for: id).appending(
                    path: Self.retainedAudioFileName(for: channel), directoryHint: .notDirectory)
                // A leftover retained file (a previous cycle's terminal
                // failure, or a re-tap) is replaced by the fresh clone.
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.copyItem(at: source, to: destination)
                cloned.append(destination)
            }
            return true
        } catch {
            for url in cloned {
                try? FileManager.default.removeItem(at: url)
            }
            ErrorTrace.record(
                "Cloning preserved audio for re-transcription failed",
                error: error,
                category: "MeetingStore",
                metadata: ["meetingID": id.uuidString]
            )
            return false
        }
    }

    /// Deletes every non-trashed meeting's preserved recording — the settings
    /// page's "Delete All Saved Recordings" action. Per-meeting named targets,
    /// never a directory sweep.
    public func deleteAllPreservedAudio() {
        for meta in listMetas() where !meta.isTrashed {
            deletePreservedAudio(for: meta.id)
        }
    }

    // MARK: - Debug-kept fixtures

    /// The name a successful pass's kept audio takes when the keep flag is on
    /// (`LaunchEnvironment.keepsRetainedAudio`). Deliberately NOT the
    /// `retained-*` names: the launch scan would classify retained audio +
    /// `finalPass` provenance as a crashed-success orphan and sweep it, so kept
    /// fixtures must be invisible to `retainedAudioFiles`. They stay inside the
    /// meeting's own folder, so deleting the meeting always deletes them.
    public nonisolated static func debugKeptAudioFileName(for channel: AudioChannel) -> String {
        switch channel {
        case .microphone: return "debug-kept-mic.m4a"
        case .system: return "debug-kept-system.m4a"
        }
    }

    /// Preserves the meeting's retained audio as development fixtures: each
    /// retained file present is RENAMED to its kept name in the same folder.
    /// Afterwards the meeting reads as holding no retained audio — not
    /// pending, invisible to the scan — and the success path's normal
    /// `deleteRetainedAudio` finds nothing. Returns whether anything was kept.
    @discardableResult
    public func preserveRetainedAudioAsDebugFixture(for id: UUID) -> Bool {
        rename(
            retainedAudioFiles(for: id), of: id, to: Self.debugKeptAudioFileName,
            what: "Preserving retained audio as a debug fixture failed")
    }

    // MARK: - Summary artifacts

    /// Deletes the meeting's derived summary artifacts — `summary.md`, any
    /// legacy `summary.json`, and any stale `rag_index.json` sidecar — and
    /// clears the meta bits that describe them (named targets only).
    /// Re-transcribe calls this before arming its pass: the new transcript
    /// invalidates all of them, and the cleared `hasSummary` is what makes the
    /// post-pass scheduler regenerate the summary. Throws if the meeting is
    /// missing.
    public func removeSummaryArtifacts(for id: UUID) throws {
        let directory = directory(for: id)
        var meta = try loadMeta(id)
        for name in [Filename.legacySummary, Filename.summaryMarkdown, "rag_index.json"] {
            let url = directory.appending(path: name)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            try FileManager.default.removeItem(at: url)
        }
        meta.hasSummary = false
        meta.oneLineDescription = nil
        meta.summaryModelName = nil
        try writeJSON(meta, to: directory.appending(path: Filename.meta))
    }

    // MARK: - Legacy summary fold

    /// Folds every legacy `summary.json` into the Markdown store: decode the
    /// json, write its `resolvedMarkdown` as `summary.md` (atomic), and ONLY
    /// once the Markdown is safely on disk delete the json — a crash between
    /// the two steps leaves both files, which the read path (Markdown wins)
    /// and this run's next launch both absorb, so no summary is ever lost.
    ///
    /// Runs at every launch with no persisted trigger state (an already-folded
    /// library is a silent no-op); each meeting's failure is non-fatal —
    /// traced, json kept, scan continues; deletions are named targets.
    public func migrateLegacySummaries() {
        let fileManager = FileManager.default
        guard
            let entries = try? fileManager.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
        else { return }

        for entry in entries {
            guard (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
            let jsonURL = entry.appending(path: Filename.legacySummary)
            guard fileManager.fileExists(atPath: jsonURL.path) else { continue }
            let markdownURL = entry.appending(path: Filename.summaryMarkdown)

            if !fileManager.fileExists(atPath: markdownURL.path) {
                do {
                    let legacy = try decode(LegacyMeetingSummary.self, from: jsonURL)
                    let markdown = legacy.resolvedMarkdown
                    // An entirely empty legacy summary has no Markdown to
                    // carry over: an empty summary.md would claim notes that
                    // don't exist, and deleting the json would erase the
                    // meeting's only summary artifact. Leave both; the
                    // fallback read serves it, honestly empty.
                    guard !markdown.isEmpty else { continue }
                    try Data(markdown.utf8).write(to: markdownURL, options: .atomic)
                } catch {
                    // Non-fatal by design: the json stays (the fallback read
                    // keeps the meeting loading exactly as before), the rest of
                    // the library still folds, and the next launch is the retry.
                    ErrorTrace.record(
                        "Legacy summary migration failed",
                        error: error,
                        category: "MeetingStore",
                        metadata: ["folder": entry.lastPathComponent]
                    )
                    continue
                }
            }

            // The Markdown exists — just written, or left by a run that
            // crashed before this delete. Either way the json is now a shadow
            // of the real store and goes.
            do {
                try fileManager.removeItem(at: jsonURL)
                Self.log.info("Folded legacy summary.json for meeting \(entry.lastPathComponent, privacy: .public)")
            } catch {
                ErrorTrace.record(
                    "Legacy summary.json cleanup failed",
                    error: error,
                    category: "MeetingStore",
                    metadata: ["folder": entry.lastPathComponent]
                )
            }
        }
    }

    // MARK: - Helpers

    private func files(named name: (AudioChannel) -> String, in id: UUID) -> [AudioChannel: URL] {
        let directory = directory(for: id)
        var files: [AudioChannel: URL] = [:]
        for channel in AudioChannel.allCases {
            let url = directory.appending(path: name(channel), directoryHint: .notDirectory)
            if FileManager.default.fileExists(atPath: url.path) {
                files[channel] = url
            }
        }
        return files
    }

    private func delete(files: [AudioChannel: URL], of id: UUID, what message: String) {
        for url in files.values {
            do {
                try FileManager.default.removeItem(at: url)
            } catch {
                ErrorTrace.record(
                    message,
                    error: error,
                    category: "MeetingStore",
                    metadata: ["meetingID": id.uuidString, "file": url.lastPathComponent]
                )
            }
        }
    }

    private func rename(
        _ files: [AudioChannel: URL],
        of id: UUID,
        to name: (AudioChannel) -> String,
        what message: String
    ) -> Bool {
        var renamed = false
        for (channel, url) in files {
            let destination = directory(for: id).appending(path: name(channel), directoryHint: .notDirectory)
            do {
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.moveItem(at: url, to: destination)
                renamed = true
            } catch {
                ErrorTrace.record(
                    message,
                    error: error,
                    category: "MeetingStore",
                    metadata: ["meetingID": id.uuidString, "file": url.lastPathComponent]
                )
            }
        }
        return renamed
    }

    /// Atomic write (temp file in the same folder + rename): a crash or a
    /// concurrent reader never sees a half-written file — it sees either the
    /// old bytes or the new ones. `Data.write(options: .atomic)` performs
    /// exactly that dance in the destination directory.
    private func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
        let data = try Self.encoder.encode(value)
        try data.write(to: url, options: .atomic)
    }

    private func decode<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
        let data = try Data(contentsOf: url)
        return try Self.decoder.decode(type, from: data)
    }

    /// Decodes a meta and rejects one written by a newer schema.
    private func decodeMeta(at url: URL, folder: String) throws -> MeetingMeta {
        let meta = try decode(MeetingMeta.self, from: url)
        guard meta.schemaVersion <= MeetingMeta.currentSchemaVersion else {
            throw MeetingStoreError.unsupportedSchemaVersion(meta.id, meta.schemaVersion)
        }
        return meta
    }

    /// Writes `summary.md` — the summary itself, not a mirror. A summary that
    /// resolves to no Markdown writes nothing and returns `false`: a file (or a
    /// `hasSummary` bit) claiming a summary with no content would promise notes
    /// that don't exist.
    @discardableResult
    private func writeSummaryMarkdown(_ markdown: String, in directory: URL) throws -> Bool {
        guard !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        try Data(markdown.utf8).write(to: directory.appending(path: Filename.summaryMarkdown), options: .atomic)
        return true
    }

    public enum Filename {
        public static let meta = "meta.json"
        public static let transcript = "transcript.json"
        /// The LEGACY summary store. Never written any more — kept only as the
        /// read fallback for folders the launch fold hasn't converted yet, and
        /// deleted by that fold once `summary.md` safely exists.
        public static let legacySummary = "summary.json"
        /// THE summary: the adaptive Markdown document itself — plain,
        /// readable, syncable. `summary.json` is only its migrated past.
        public static let summaryMarkdown = "summary.md"
    }
}
