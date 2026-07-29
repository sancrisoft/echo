//
//  MeetingStore.swift
//  Echo
//
//  The persistent meeting library: JSON files, one folder per meeting, under
//  ~/Library/Application Support/Echo/Meetings (SPEC-03). An actor so the JSON
//  encode/decode (a 3 h transcript is a few MB) runs off the main thread and
//  concurrent saves/loads/deletes serialize.
//
//  Why plain JSON and not SwiftData/SQLite: volume is tiny (tens of meetings),
//  reads are trivial, zero dependencies, human-inspectable, and the folder gives
//  a natural home to the per-meeting sidecars later features add (SPEC-06
//  rag_index.json, SPEC-08 pages). If it ever hurts, migrating behind this actor
//  is cheap.
//

import Foundation

actor MeetingStore {

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

    /// Creates the meeting folder and writes `meta.json` + `transcript.json`
    /// (+ `summary.json` when the record already carries one). `meta` is
    /// normalized to the record it is saved with — `segmentCount` and
    /// `hasSummary` always reflect what actually landed on disk.
    func save(_ record: MeetingRecord) async throws {
        let directory = directory(for: record.meta.id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        var meta = record.meta
        meta.segmentCount = record.segments.count
        meta.hasSummary = record.summary != nil

        try writeJSON(record.segments, to: directory.appending(path: Filename.transcript))
        if let summary = record.summary {
            try await writeSummary(summary, to: directory.appending(path: Filename.summary))
        }
        // meta.json last: a reader that finds a meta also finds its transcript.
        try writeJSON(meta, to: directory.appending(path: Filename.meta))
    }

    /// Writes `summary.json` and flips `meta.hasSummary` to `true`. Called when
    /// a summary lands after the meeting was already saved (SPEC-03 criterion
    /// 2). Throws if the meeting folder / meta is missing.
    ///
    /// `description`, when provided, is stored on the meta as the row's
    /// one-line caption in the same write (it is generated alongside the
    /// summary). Passing `nil` leaves any existing caption untouched.
    func attachSummary(_ summary: MeetingSummary, description: String? = nil, to id: UUID) async throws {
        let directory = directory(for: id)
        let metaURL = directory.appending(path: Filename.meta)
        var meta = try decode(MeetingMeta.self, from: metaURL)
        try await writeSummary(summary, to: directory.appending(path: Filename.summary))
        meta.hasSummary = true
        if let description { meta.oneLineDescription = description }
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

    /// The full meeting (header + transcript + summary if present). Throws if the
    /// folder / meta / transcript is missing or corrupt.
    func loadRecord(_ id: UUID) async throws -> MeetingRecord {
        let directory = directory(for: id)
        let meta = try decode(MeetingMeta.self, from: directory.appending(path: Filename.meta))
        // The transcript is the big payload (MBs for a 3 h meeting); it decodes
        // here in the actor, off the main thread, via its nonisolated conformance.
        let segments = try decode([TranscriptSegment].self, from: directory.appending(path: Filename.transcript))
        let summaryURL = directory.appending(path: Filename.summary)
        let summary = FileManager.default.fileExists(atPath: summaryURL.path)
            ? try await readSummary(from: summaryURL)
            : nil
        return MeetingRecord(meta: meta, segments: segments, summary: summary)
    }

    // MARK: - Delete

    /// Removes the whole meeting folder, including any sidecars other features
    /// dropped in it (SPEC-03 criterion 5). A no-op if it is already gone.
    func delete(_ id: UUID) throws {
        let directory = directory(for: id)
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        try FileManager.default.removeItem(at: directory)
    }

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

    // `MeetingSummary`'s `Codable` conformance is main-actor-isolated: its nested
    // value types (`SummaryDecision` etc.) live in a file this spec must not
    // modify and are not declared `nonisolated`, so the synthesized conformance
    // is bound to the main actor. The summary is tiny (a few short strings and
    // small arrays), so serializing it on the main actor costs microseconds —
    // the byte-level file write still happens back here in the actor, and the
    // large transcript never touches the main thread.

    private func writeSummary(_ summary: MeetingSummary, to url: URL) async throws {
        let data = try await Self.encodeSummary(summary)
        try data.write(to: url, options: .atomic)
    }

    private func readSummary(from url: URL) async throws -> MeetingSummary {
        let data = try Data(contentsOf: url)
        return try await Self.decodeSummary(data)
    }

    @MainActor
    private static func encodeSummary(_ summary: MeetingSummary) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(summary)
    }

    @MainActor
    private static func decodeSummary(_ data: Data) throws -> MeetingSummary {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(MeetingSummary.self, from: data)
    }

    private enum Filename {
        static let meta = "meta.json"
        static let transcript = "transcript.json"
        static let summary = "summary.json"
    }
}
