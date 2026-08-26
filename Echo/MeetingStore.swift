//
//  MeetingStore.swift
//  Echo
//
//  The persistent meeting library: one folder per meeting under
//  ~/Library/Application Support/Echo/Meetings (SPEC-03) — JSON for the meta
//  and transcript, plain markdown (`summary.md`) as the summary store (S11).
//  An actor so the JSON encode/decode (a 3 h transcript is a few MB) runs off
//  the main thread and concurrent saves/loads/deletes serialize.
//
//  Why plain JSON and not SwiftData/SQLite: volume is tiny (tens of meetings),
//  reads are trivial, zero dependencies, human-inspectable, and the folder gives
//  a natural home to the per-meeting sidecars later features add (SPEC-06
//  rag_index.json, SPEC-08 pages). If it ever hurts, migrating behind this actor
//  is cheap.
//

import Foundation
import os

actor MeetingStore {

    private static let log = Logger(subsystem: "com.sancrisoft.Echo", category: "MeetingStore")

    /// Root under which every meeting folder lives. `let` + `Sendable` so
    /// `directory(for:)` can read it from a `nonisolated` context (the sidecar
    /// contract for SPEC-06/08).
    private let root: URL

    /// `.sortedKeys` + `.iso8601` make the on-disk bytes deterministic, so diffs
    /// are readable and the encoder is testable with a golden. `.prettyPrinted`
    /// keeps the files inspectable by hand.
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

    init(rootDirectory: URL = EchoPaths.meetingsDirectory) {
        self.root = rootDirectory
    }

    // MARK: - Sidecar contract (SPEC-06/08)

    /// The root under which every meeting folder lives. `nonisolated` (it is a
    /// `let`) so callers like the storage-footer measurement can read it
    /// without awaiting the actor.
    nonisolated var rootDirectory: URL { root }

    /// The folder for a meeting. `nonisolated` and side-effect-free so other
    /// features can locate a meeting's sidecars without awaiting the actor and
    /// without accidentally creating anything.
    nonisolated func directory(for id: UUID) -> URL {
        root.appending(path: id.uuidString, directoryHint: .isDirectory)
    }

    // MARK: - Write

    /// Creates the meeting folder and writes `meta.json` (+ `transcript.json`
    /// when the record carries segments, + `summary.md` when it carries a
    /// summary). `meta` is normalized to the record it is saved with —
    /// `segmentCount` and `hasSummary` always reflect what actually landed on
    /// disk (so a summary that resolves to no markdown claims nothing).
    ///
    /// A segment-less save is the normal stop path now: a just-stopped meeting
    /// has retained audio and no words yet, and writing an empty
    /// `transcript.json` beside it would claim a transcript that doesn't
    /// exist. `ParakeetPass` writes the real one through `replaceTranscript`.
    func save(_ record: MeetingRecord) async throws {
        let directory = directory(for: record.meta.id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        var meta = record.meta
        meta.segmentCount = record.segments.count

        if !record.segments.isEmpty {
            try writeJSON(record.segments, to: directory.appending(path: Filename.transcript))
        }
        if let summary = record.summary {
            meta.hasSummary = try writeSummaryMarkdown(summary, in: directory)
        } else {
            meta.hasSummary = false
        }
        // meta.json last: a reader that finds a meta also finds its transcript.
        try writeJSON(meta, to: directory.appending(path: Filename.meta))
    }

    /// Writes `summary.md` and flips `meta.hasSummary` to `true`. Called when
    /// a summary lands after the meeting was already saved (SPEC-03 criterion
    /// 2). Throws if the meeting folder / meta is missing.
    ///
    /// A summary that resolves to no markdown at all is a total no-op past
    /// that existence check: nothing lands on disk, so no meta bit —
    /// `hasSummary`, the caption, the model name — may describe it. They all
    /// describe the artifact, and the artifact doesn't exist.
    ///
    /// `description`, when provided, is stored on the meta as the row's
    /// one-line caption in the same write (it is generated alongside the
    /// summary). Passing `nil` leaves any existing caption untouched.
    ///
    /// `modelName`, when provided, records which summary model wrote the notes
    /// (SP-007, ADR-022 — provenance lands in the same step as the artifact it
    /// describes). Passing `nil` leaves any existing record untouched.
    func attachSummary(
        _ summary: MeetingSummary,
        description: String? = nil,
        modelName: String? = nil,
        to id: UUID
    ) async throws {
        let directory = directory(for: id)
        let metaURL = directory.appending(path: Filename.meta)
        var meta = try decode(MeetingMeta.self, from: metaURL)
        guard try writeSummaryMarkdown(summary, in: directory) else { return }
        meta.hasSummary = true
        if let description { meta.oneLineDescription = description }
        if let modelName { meta.summaryModelName = modelName }
        try writeJSON(meta, to: metaURL)
    }

    /// Rewrites only `meta.json` for an existing meeting (rename, trash/restore,
    /// word-count backfill). The caller owns the full, up-to-date `MeetingMeta`;
    /// this persists it verbatim. Throws if the folder is missing (the atomic
    /// write into a nonexistent directory fails), so a caller can't resurrect a
    /// deleted meeting by updating it.
    func updateMeta(_ meta: MeetingMeta) throws {
        try writeJSON(meta, to: directory(for: meta.id).appending(path: Filename.meta))
    }

    // MARK: - Read

    /// Every saved meeting's header, newest first. Loads only `meta.json` (small)
    /// so app launch never deserializes full transcripts. A folder whose meta is
    /// missing or corrupt is skipped with a log — one bad meeting never tumbles
    /// the whole list.
    func listMetas() -> [MeetingMeta] {
        let fileManager = FileManager.default
        guard let entries = try? fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            // Root doesn't exist yet (no meeting ever saved) — an empty library,
            // not an error.
            return []
        }

        var metas: [MeetingMeta] = []
        for entry in entries {
            guard (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
            do {
                metas.append(try decode(MeetingMeta.self, from: entry.appending(path: Filename.meta)))
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

    /// The full meeting (header + transcript + summary if present). Throws if
    /// the folder / meta is missing or corrupt, or if a transcript that exists
    /// can't be read.
    ///
    /// A meeting with NO `transcript.json` loads with no segments rather than
    /// throwing: that is the honest state of a meeting whose pass hasn't
    /// produced words yet (pending) or never will (terminal failure). Only an
    /// absent file reads that way — an unreadable one still throws, so real
    /// corruption is never silently rendered as "no transcript".
    func loadRecord(_ id: UUID) async throws -> MeetingRecord {
        let directory = directory(for: id)
        let meta = try decode(MeetingMeta.self, from: directory.appending(path: Filename.meta))
        // The transcript is the big payload (MBs for a 3 h meeting); it decodes
        // here in the actor, off the main thread, via its nonisolated conformance.
        let transcriptURL = directory.appending(path: Filename.transcript)
        let segments = FileManager.default.fileExists(atPath: transcriptURL.path)
            ? try decode([TranscriptSegment].self, from: transcriptURL)
            : []
        let summary = try await loadSummary(in: directory)
        return MeetingRecord(meta: meta, segments: segments, summary: summary)
    }

    /// The stored summary, md-first (S11): `summary.md` IS the store — its
    /// contents load verbatim as the summary's document, legacy fields empty.
    /// A folder that only has the legacy `summary.json` (the launch migration
    /// hasn't reached it, or its conversion failed) still loads through the
    /// decode fallback, exactly as it always did. When BOTH files exist — a
    /// crash between the migration's md-write and its json-delete — the
    /// markdown wins: it was derived from that very json, and it is the only
    /// file the app writes now.
    private func loadSummary(in directory: URL) async throws -> MeetingSummary? {
        let markdownURL = directory.appending(path: Filename.summaryMarkdown)
        if FileManager.default.fileExists(atPath: markdownURL.path) {
            let contents = try String(decoding: Data(contentsOf: markdownURL), as: UTF8.self)
            return MeetingSummary(
                markdown: contents,
                shortSummary: "",
                detailedSummary: "",
                decisions: [],
                actionItems: [],
                openQuestions: [],
                risks: []
            )
        }
        let jsonURL = directory.appending(path: Filename.summary)
        guard FileManager.default.fileExists(atPath: jsonURL.path) else { return nil }
        return try await readSummary(from: jsonURL)
    }

    // MARK: - Delete

    /// Removes the whole meeting folder, including any sidecars other features
    /// dropped in it (SPEC-03 criterion 5). A no-op if it is already gone.
    func delete(_ id: UUID) throws {
        let directory = directory(for: id)
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        try FileManager.default.removeItem(at: directory)
    }

    // MARK: - Final-pass transcript replacement (SP-005, ADR-016)

    /// Atomically replaces a meeting's transcript with the complete final
    /// segment set and re-derives the meta fields that describe it (segment
    /// and word counts, plus the transcript's provenance — ADR-022: written in
    /// the same step as the artifact it describes). Transcript first, meta
    /// after — mirroring `save`'s meta-last discipline, so the stale-meta
    /// window is display-only. Every write is the store's
    /// temp-file-plus-rename (`writeJSON`), so any failure leaves the live
    /// transcript byte-identical (the floor stands).
    func replaceTranscript(
        _ segments: [TranscriptSegment],
        provenance: TranscriptProvenance,
        for id: UUID
    ) throws {
        let directory = directory(for: id)
        let metaURL = directory.appending(path: Filename.meta)
        // Load the meta up front: a missing/corrupt meeting fails here,
        // before the transcript is touched.
        var meta = try decode(MeetingMeta.self, from: metaURL)

        try writeJSON(segments, to: directory.appending(path: Filename.transcript))

        meta.segmentCount = segments.count
        meta.wordCount = MeetingMeta.wordCount(of: segments)
        meta.transcriptProvenance = provenance
        try writeJSON(meta, to: metaURL)
    }

    /// Records the meeting's terminal transcript provenance — a single atomic
    /// `meta.json` write, no other file touched (ADR-022/ADR-024: the terminal
    /// transition is safe as a state bit precisely because nothing else is
    /// written beside it). Called when a pass cycle terminally converged: the
    /// retained audio stays for the manual Retry, and this bit is what ends
    /// the meeting's pending classification. Throws if the meeting folder /
    /// meta is missing.
    func recordTerminalProvenance(for id: UUID, provenance: TranscriptProvenance) throws {
        let metaURL = directory(for: id).appending(path: Filename.meta)
        var meta = try decode(MeetingMeta.self, from: metaURL)
        meta.transcriptProvenance = provenance
        try writeJSON(meta, to: metaURL)
    }

    // MARK: - Retained audio (SP-005, ADR-013/ADR-016)

    /// Canonical name of a channel's retained-audio file inside its meeting
    /// folder. One source of truth for the retention writer, the pending
    /// query, and the cleanup targets.
    nonisolated static func retainedAudioFileName(for channel: AudioChannel) -> String {
        switch channel {
        case .microphone: return "retained-mic.m4a"
        case .system: return "retained-system.m4a"
        }
    }

    /// The retained-audio files currently present in a meeting's folder.
    func retainedAudioFiles(for id: UUID) -> [AudioChannel: URL] {
        let directory = directory(for: id)
        var files: [AudioChannel: URL] = [:]
        for channel in [AudioChannel.microphone, .system] {
            let url = directory.appending(
                path: Self.retainedAudioFileName(for: channel),
                directoryHint: .notDirectory
            )
            if FileManager.default.fileExists(atPath: url.path) {
                files[channel] = url
            }
        }
        return files
    }

    /// Whether the meeting's folder still holds retained audio — the exact
    /// lifetime of the draft state's Retry affordance (SP-007: "Retry exists
    /// exactly while the retained audio does"). A thin, named veneer over
    /// `retainedAudioFiles` for the UI's yes/no question.
    func hasRetainedAudio(for id: UUID) -> Bool {
        !retainedAudioFiles(for: id).isEmpty
    }

    /// What a meeting's retained audio means (ADR-024). ADR-016's
    /// presence-means-pending rule gains one disambiguation: terminal
    /// convergence now KEEPS the audio, so presence alone no longer implies
    /// pending — the recorded transcript-provenance source (ADR-022's one
    /// sanctioned scheduling bit) breaks the tie.
    nonisolated enum RetainedAudioDisposition: Equatable, Sendable {
        /// No retained audio: the meeting is final, its draft was kept, or
        /// retention never armed.
        case none
        /// Audio with no transcript provenance: an unfinished cycle — the
        /// launch scan auto-resumes it (ADR-016, unchanged).
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

    /// The pure classification rule — one source of truth for the
    /// disposition query, the launch scan, and the orphan sweep.
    nonisolated static func classifyRetainedAudio(
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

    /// Classifies one meeting's retained audio from disk: file presence +
    /// the meta's recorded provenance, nothing else (ADR-024 — no new files,
    /// no new state markers). An unreadable meta classifies like a missing
    /// provenance; the scan never reaches it anyway (`listMetas` skips it).
    func retainedAudioDisposition(for id: UUID) -> RetainedAudioDisposition {
        let meta = try? decode(MeetingMeta.self, from: directory(for: id).appending(path: Filename.meta))
        return Self.classifyRetainedAudio(
            present: hasRetainedAudio(for: id),
            transcriptSource: meta?.transcriptProvenance?.source
        )
    }

    /// ADR-016 amended by ADR-024: retained audio marks a meeting pending
    /// only while no transcript provenance is recorded — the terminal
    /// transition's single atomic meta write is what ends the pending
    /// classification while the audio stays for the manual Retry.
    func isPendingFinalization(_ id: UUID) -> Bool {
        retainedAudioDisposition(for: id) == .pending
    }

    /// Meetings still pending finalization, newest first — the launch-resume
    /// work queue (ADR-016: crash-resume is a directory scan) and the
    /// summary backfill's exclusion set. Only the true pending class
    /// qualifies (ADR-024): terminal failures and legacy drafts rest until
    /// the user retries, finalPass orphans are sweep targets. Trashed meetings are excluded: the user set them aside, and
    /// their retention is deleted with the folder (a restore surfaces them
    /// to the next launch's scan).
    func pendingFinalizationMeetingIDs() -> [UUID] {
        listMetas()
            .filter { !$0.isTrashed && disposition(of: $0) == .pending }
            .map(\.id)
    }

    /// Deletes the retained audio of meetings whose provenance says
    /// `finalPass` (ADR-024): orphans of a success whose cleanup crashed
    /// after the transcript replace. Their transcript is already final, so
    /// the audio is swept — never re-run. Runs at launch, before the resume
    /// enqueue. Trashed meetings stay outside the scan (existing rule).
    func sweepFinalPassAudioOrphans() {
        for meta in listMetas() where !meta.isTrashed && disposition(of: meta) == .finalPassOrphan {
            deleteRetainedAudio(for: meta.id)
        }
    }

    /// Classification with the meta already in hand (the scan and sweep walk
    /// `listMetas` — no second decode per meeting).
    private func disposition(of meta: MeetingMeta) -> RetainedAudioDisposition {
        Self.classifyRetainedAudio(
            present: hasRetainedAudio(for: meta.id),
            transcriptSource: meta.transcriptProvenance?.source
        )
    }

    /// Hidden sibling of the meeting folders where a live session stages its
    /// retention before the meeting persists (SP-005). One source of truth
    /// for the writer's destination and the launch sweep.
    nonisolated static let retentionStagingDirectoryName = ".retention-staging"

    nonisolated var retentionStagingDirectory: URL {
        root.appending(path: Self.retentionStagingDirectoryName, directoryHint: .isDirectory)
    }

    /// Deletes the whole retention-staging tree — session folders a quit or
    /// crash orphaned. Staged audio is disposable by design: it was never
    /// adopted, so no meeting points at it and no pending marker involves it
    /// (ADR-016). Meeting folders are never touched (the staging root is a
    /// named target, not a sweep of the meetings tree). A failure is
    /// non-fatal — logged, retried next launch.
    func sweepRetentionStaging() {
        let staging = retentionStagingDirectory
        guard FileManager.default.fileExists(atPath: staging.path) else { return }
        do {
            try FileManager.default.removeItem(at: staging)
        } catch {
            ErrorTrace.record(
                "Retention-staging sweep failed",
                error: error,
                category: "MeetingStore"
            )
        }
    }

    /// Moves staged retention files into the meeting's folder, arming the
    /// pending marker. Runs only after the live transcript persisted (the
    /// floor exists first), so a folder with retained audio always also has
    /// a transcript to fall back on. All-or-nothing: a failure undoes any
    /// file already moved in — a partial channel set must never read as
    /// pending, or a resumed pass would finalize half a meeting.
    func adoptRetainedAudio(_ staged: [AudioChannel: URL], for id: UUID) throws -> [AudioChannel: URL] {
        let directory = directory(for: id)
        var adopted: [AudioChannel: URL] = [:]
        do {
            for (channel, source) in staged {
                let destination = directory.appending(
                    path: Self.retainedAudioFileName(for: channel),
                    directoryHint: .notDirectory
                )
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
    /// never a directory sweep (SP-005 NFR Reliability): sibling files and
    /// sidecars are untouched. A per-file failure is non-fatal (logged; a
    /// later pass or launch retries the cleanup).
    func deleteRetainedAudio(for id: UUID) {
        for url in retainedAudioFiles(for: id).values {
            do {
                try FileManager.default.removeItem(at: url)
            } catch {
                ErrorTrace.record(
                    "Retained-audio cleanup failed",
                    error: error,
                    category: "MeetingStore",
                    metadata: [
                        "meetingID": id.uuidString,
                        "file": url.lastPathComponent,
                    ]
                )
            }
        }
    }

    // MARK: - Preserved recordings (settings-page retention)

    /// Canonical name of a channel's *preserved* audio file — the product
    /// "keep recordings" feature's sibling of the retained and DEBUG-kept
    /// names. Deliberately NOT `retained-*`: `retainedAudioFiles` never looks
    /// for these, so a preserved meeting classifies `.none` under ADR-024 —
    /// never auto-resumed, never swept. The files stay inside the meeting's
    /// own folder, so trashing or deleting the meeting takes them along.
    nonisolated static func preservedAudioFileName(for channel: AudioChannel) -> String {
        switch channel {
        case .microphone: return "audio-mic.m4a"
        case .system: return "audio-system.m4a"
        }
    }

    /// The preserved-audio files currently present in a meeting's folder.
    func preservedAudioFiles(for id: UUID) -> [AudioChannel: URL] {
        let directory = directory(for: id)
        var files: [AudioChannel: URL] = [:]
        for channel in [AudioChannel.microphone, .system] {
            let url = directory.appending(
                path: Self.preservedAudioFileName(for: channel),
                directoryHint: .notDirectory
            )
            if FileManager.default.fileExists(atPath: url.path) {
                files[channel] = url
            }
        }
        return files
    }

    /// Whether the meeting's folder holds a preserved recording — the exact
    /// lifetime of the detail's player/re-transcribe affordances.
    func hasPreservedAudio(for id: UUID) -> Bool {
        !preservedAudioFiles(for: id).isEmpty
    }

    /// Preserves the meeting's retained audio as its saved recording: each
    /// retained file currently present is RENAMED to its preserved name in
    /// the same folder (a move — cheap and atomic on the same volume, bytes
    /// untouched), mirroring `preserveRetainedAudioAsDebugFixture`. The
    /// success path's normal `deleteRetainedAudio` then finds nothing,
    /// harmlessly. An existing preserved file is replaced first — the
    /// overwrite case is a re-transcribe writing the same bytes back.
    /// Returns whether anything was preserved. A per-file failure is
    /// non-fatal: the file stays under its retained name and the normal
    /// deletion cleans it up.
    @discardableResult
    func preserveRetainedAudio(for id: UUID) -> Bool {
        var preserved = false
        for (channel, url) in retainedAudioFiles(for: id) {
            let destination = directory(for: id).appending(
                path: Self.preservedAudioFileName(for: channel),
                directoryHint: .notDirectory
            )
            do {
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.moveItem(at: url, to: destination)
                preserved = true
            } catch {
                ErrorTrace.record(
                    "Preserving retained audio failed",
                    error: error,
                    category: "MeetingStore",
                    metadata: [
                        "meetingID": id.uuidString,
                        "file": url.lastPathComponent,
                    ]
                )
            }
        }
        return preserved
    }

    /// Deletes exactly this meeting's preserved-audio files — named targets,
    /// never a directory sweep, like `deleteRetainedAudio`. A per-file
    /// failure is non-fatal (logged).
    func deletePreservedAudio(for id: UUID) {
        for url in preservedAudioFiles(for: id).values {
            do {
                try FileManager.default.removeItem(at: url)
            } catch {
                ErrorTrace.record(
                    "Preserved-audio deletion failed",
                    error: error,
                    category: "MeetingStore",
                    metadata: [
                        "meetingID": id.uuidString,
                        "file": url.lastPathComponent,
                    ]
                )
            }
        }
    }

    /// Clones the meeting's preserved audio back to its retained names —
    /// re-transcribe's arming step (§3.5). COPY, never rename: the preserved
    /// copy is the archive, so it survives crashes, terminal failures and a
    /// mid-flight retention-setting change. On APFS the copy is a clone (no
    /// real disk cost). Crash-safety needs no new state: a quit between this
    /// clone and the pass concluding leaves `retained-*` + `finalPass`
    /// provenance — ADR-024's orphan class, swept at the next launch while
    /// `audio-*` survives and the previous transcript stands. All-or-nothing
    /// like `adoptRetainedAudio`: a partial channel set must never feed a
    /// pass, or it would replace a fuller transcript with less.
    func cloneAudioForRetranscription(for id: UUID) -> Bool {
        let preserved = preservedAudioFiles(for: id)
        guard !preserved.isEmpty else { return false }
        var cloned: [URL] = []
        do {
            for (channel, source) in preserved {
                let destination = directory(for: id).appending(
                    path: Self.retainedAudioFileName(for: channel),
                    directoryHint: .notDirectory
                )
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

    /// Deletes the meeting's derived summary artifacts — `summary.md`, any
    /// legacy `summary.json`, and any stale `rag_index.json` sidecar — and clears
    /// the meta bits that describe them (named targets only, mirroring the
    /// store's delete discipline). Re-transcribe calls this before arming its
    /// pass: the new transcript invalidates all of them, and the cleared
    /// `hasSummary` is what makes the post-pass backfill regenerate the
    /// summary. Throws if the meeting folder / meta is missing.
    func removeSummaryArtifacts(for id: UUID) throws {
        let directory = directory(for: id)
        let metaURL = directory.appending(path: Filename.meta)
        var meta = try decode(MeetingMeta.self, from: metaURL)
        try? FileManager.default.removeItem(at: directory.appending(path: Filename.summary))
        try? FileManager.default.removeItem(at: directory.appending(path: Filename.summaryMarkdown))
        try? FileManager.default.removeItem(at: directory.appending(path: "rag_index.json"))
        meta.hasSummary = false
        meta.oneLineDescription = nil
        meta.summaryModelName = nil
        try writeJSON(meta, to: metaURL)
    }

    // MARK: - Legacy summary store migration (S11)

    /// Folds every legacy `summary.json` into the markdown store: decode the
    /// json, write its `resolvedMarkdown` as `summary.md` (atomic), and ONLY
    /// once the markdown is safely on disk delete the json — a crash between
    /// the two steps leaves both files, which the read path (md wins) and
    /// this run's next launch both absorb, so no summary is ever lost.
    ///
    /// RetiredModelCleanup's discipline (ADR-011), applied to data files:
    /// runs at every launch with no persisted trigger state (an
    /// already-migrated library is a silent no-op), each meeting's failure is
    /// non-fatal — logged, json kept, scan continues — and deletions are
    /// named targets, never a sweep. An actor method so it serializes with
    /// every concurrent save/load instead of racing them.
    func migrateLegacySummaries() async {
        let fileManager = FileManager.default
        guard let entries = try? fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            // Root doesn't exist yet (no meeting ever saved) — nothing to do.
            return
        }

        for entry in entries {
            guard (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
            let jsonURL = entry.appending(path: Filename.summary)
            guard fileManager.fileExists(atPath: jsonURL.path) else { continue }
            let markdownURL = entry.appending(path: Filename.summaryMarkdown)

            if !fileManager.fileExists(atPath: markdownURL.path) {
                do {
                    let summary = try await readSummary(from: jsonURL)
                    let markdown = summary.resolvedMarkdown
                    // An entirely empty legacy summary has no markdown to
                    // carry over: an empty summary.md would claim notes that
                    // don't exist, and deleting the json would erase the
                    // meeting's only summary artifact. Leave both; the
                    // fallback read serves it, honestly empty.
                    guard !markdown.isEmpty else { continue }
                    try Data(markdown.utf8).write(to: markdownURL, options: .atomic)
                } catch {
                    // Non-fatal by design: the json stays (the fallback read
                    // keeps the meeting loading exactly as before), the rest
                    // of the library still migrates, and the next launch is
                    // the retry.
                    ErrorTrace.record(
                        "Legacy summary migration failed",
                        error: error,
                        category: "MeetingStore",
                        metadata: ["folder": entry.lastPathComponent]
                    )
                    continue
                }
            }

            // The markdown exists — just written, or left by a run that
            // crashed before this delete. Either way the json is now a
            // shadow of the real store and goes.
            do {
                try fileManager.removeItem(at: jsonURL)
                Self.log.info("Migrated legacy summary.json for meeting \(entry.lastPathComponent, privacy: .public)")
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

    /// Deletes every non-trashed meeting's preserved recording — the
    /// Settings page's "Delete All Saved Recordings…" action. Per-meeting
    /// named targets (`deletePreservedAudio`), never a directory sweep.
    func deleteAllPreservedAudio() {
        for meta in listMetas() where !meta.isTrashed {
            deletePreservedAudio(for: meta.id)
        }
    }

    /// How many non-trashed meetings hold a preserved recording, and the
    /// recordings' total bytes — the Settings page's "Delete All Saved
    /// Recordings (3 — 214 MB)…" label and the storage breakdown's
    /// saved-recordings row. Trashed meetings are excluded (their recordings
    /// leave with the trash purge, and the breakdown counts them under Trash).
    func preservedAudioTotals() -> (meetings: Int, bytes: Int64) {
        var meetings = 0
        var bytes: Int64 = 0
        for meta in listMetas() where !meta.isTrashed {
            let files = preservedAudioFiles(for: meta.id)
            guard !files.isEmpty else { continue }
            meetings += 1
            for url in files.values {
                let values = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey])
                bytes += Int64(values?.totalFileAllocatedSize ?? values?.fileAllocatedSize ?? 0)
            }
        }
        return (meetings, bytes)
    }

    // MARK: - DEBUG kept fixtures (SP-007 keep flag)

    #if DEBUG
    /// The name a successful pass's kept audio takes inside the meeting
    /// folder when the DEBUG keep flag is on. Deliberately NOT the canonical
    /// `retained-*` names: the ADR-024 launch scan classifies retained audio
    /// + `finalPass` provenance as a crashed-success orphan and would sweep
    /// it, so kept fixtures must be invisible to `retainedAudioFiles` and
    /// the disposition scan (different names — nothing above ever looks for
    /// these). They stay inside the meeting's own folder, so deleting the
    /// meeting always deletes them: retention can never outlive its meeting
    /// (SP-007 Further Notes — a scoped exception to ADR-013, not an
    /// amendment).
    nonisolated static func debugKeptAudioFileName(for channel: AudioChannel) -> String {
        switch channel {
        case .microphone: return "debug-kept-mic.m4a"
        case .system: return "debug-kept-system.m4a"
        }
    }

    /// Preserves the meeting's retained audio as development fixtures: each
    /// retained file currently present is RENAMED to its kept name in the
    /// same folder (a move — cheap and atomic on the same volume, bytes
    /// untouched). Afterwards the meeting reads as holding no retained audio
    /// — not pending, invisible to the three-way scan — and the success
    /// path's normal `deleteRetainedAudio` finds nothing, harmlessly.
    /// Returns whether anything was preserved. A per-file failure is
    /// non-fatal: the file stays under its retained name and the normal
    /// deletion cleans it up.
    @discardableResult
    func preserveRetainedAudioAsDebugFixture(for id: UUID) -> Bool {
        var preserved = false
        for (channel, url) in retainedAudioFiles(for: id) {
            let destination = directory(for: id).appending(
                path: Self.debugKeptAudioFileName(for: channel),
                directoryHint: .notDirectory
            )
            do {
                // A re-kept meeting (manual Retry driven to success again)
                // replaces the previous kept take.
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.moveItem(at: url, to: destination)
                preserved = true
            } catch {
                ErrorTrace.record(
                    "Preserving retained audio as a debug fixture failed",
                    error: error,
                    category: "MeetingStore",
                    metadata: [
                        "meetingID": id.uuidString,
                        "file": url.lastPathComponent,
                    ]
                )
            }
        }
        return preserved
    }
    #endif

    // MARK: - JSON helpers

    /// Atomic write (temp file in the same folder + rename): a crash or a
    /// concurrent reader never sees a half-written file — it sees either the old
    /// bytes or the new ones. `Data.write(options: .atomic)` performs exactly the
    /// temp-then-rename dance in the destination directory.
    ///
    /// Used for `MeetingMeta` and `[TranscriptSegment]`, whose `Codable`
    /// conformances are `nonisolated` and therefore usable here in the actor.
    private func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
        let data = try Self.encoder.encode(value)
        try data.write(to: url, options: .atomic)
    }

    private func decode<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
        let data = try Data(contentsOf: url)
        return try Self.decoder.decode(type, from: data)
    }

    /// Writes `summary.md` — the summary store itself (S11), not a mirror:
    /// exactly `resolvedMarkdown`, which is the verbatim adaptive document,
    /// or the faithful `###` serialization of a facts-only summary (the long
    /// route's degraded reduce), so both eras persist as one readable file.
    /// A summary that resolves to NO markdown writes nothing and returns
    /// `false` — a file (or a `hasSummary` bit; the callers key on the
    /// return) claiming a summary with no content would promise notes that
    /// don't exist.
    @discardableResult
    private func writeSummaryMarkdown(_ summary: MeetingSummary, in directory: URL) throws -> Bool {
        let markdown = summary.resolvedMarkdown
        guard !markdown.isEmpty else { return false }
        try Data(markdown.utf8).write(
            to: directory.appending(path: Filename.summaryMarkdown),
            options: .atomic
        )
        return true
    }

    // `MeetingSummary`'s `Codable` conformance is main-actor-isolated: its nested
    // value types (`SummaryDecision` etc.) are not declared `nonisolated`, so
    // the conformance is bound to the main actor. Only the legacy DECODE
    // survives S11 (the fallback read and the launch migration both need it —
    // nothing encodes a summary to JSON any more); it is tiny, so the hop
    // costs microseconds and the large transcript never touches the main
    // thread.

    private func readSummary(from url: URL) async throws -> MeetingSummary {
        let data = try Data(contentsOf: url)
        return try await Self.decodeSummary(data)
    }

    @MainActor
    private static func decodeSummary(_ data: Data) throws -> MeetingSummary {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(MeetingSummary.self, from: data)
    }

    enum Filename {
        static let meta = "meta.json"
        static let transcript = "transcript.json"
        /// The LEGACY summary store (pre-S11). Never written any more — kept
        /// only as the read fallback for folders the launch migration hasn't
        /// converted yet, and deleted by that migration once `summary.md`
        /// safely exists.
        static let summary = "summary.json"
        /// THE summary store (S11): the adaptive markdown document itself —
        /// plain, readable, syncable (open it in any editor). The markdown
        /// files ARE the database; `summary.json` is only their migrated past.
        static let summaryMarkdown = "summary.md"
    }
}
