//
//  MeetingLibrary.swift
//  Meetings
//
//  The main-actor, observable façade over `MeetingStore` that the UI reads:
//  the live meetings, the trashed ones, and what the library occupies on disk.
//  Disk is the source of truth; this is a cache that re-reads after its own
//  mutations.
//
//  Reading never writes. `refresh()` lists and measures; the launch-time
//  housekeeping that deletes or rewrites files — purging expired trash, folding
//  legacy summaries, backfilling word counts — is explicit, called by the
//  composition root, never a side effect of loading the list (ADR-003).
//

import EchoCore
import Foundation
import Observation

@Observable
@MainActor
public final class MeetingLibrary {

    /// A meeting sits in Trash for this long before it is permanently removed.
    public static let trashRetention: TimeInterval = 30 * 24 * 60 * 60

    /// The store this library fronts. The pipeline writes through it directly
    /// and asks the library to `refresh()`.
    public let store: MeetingStore

    /// Counted into the storage breakdown; `nil` skips the models row.
    private let modelsDirectory: URL?

    /// Live meetings (not trashed), newest first.
    public private(set) var metas: [MeetingMeta] = []

    /// Trashed meetings, most recently trashed first.
    public private(set) var trashedMetas: [MeetingMeta] = []

    /// What the library occupies on disk. `nil` until the first measurement.
    public private(set) var storage: StorageBreakdown?

    private var isBackfilling = false

    /// Builds the library. Performs no I/O: call `refresh()` to load.
    public init(store: MeetingStore, modelsDirectory: URL? = nil) {
        self.store = store
        self.modelsDirectory = modelsDirectory
    }

    /// The library at a data root.
    public convenience init(dataRoot: DataRoot) {
        self.init(store: MeetingStore(dataRoot: dataRoot), modelsDirectory: dataRoot.models)
    }

    // MARK: - Locations

    /// The on-disk folder for a meeting, for Reveal in Finder and export.
    /// Side-effect free.
    public nonisolated func directory(for id: UUID) -> URL {
        store.directory(for: id)
    }

    // MARK: - Loading

    /// Reloads the meeting headers from disk and re-measures storage. Reads
    /// only.
    public func refresh() async {
        let all = await store.listMetas()
        metas = all.filter { !$0.isTrashed }
        trashedMetas =
            all.filter(\.isTrashed)
            .sorted { ($0.trashedAt ?? .distantPast) > ($1.trashedAt ?? .distantPast) }
        measureStorage()
    }

    /// Permanently deletes meetings that have sat in Trash past the retention
    /// window, then refreshes. Launch housekeeping, called by the composition
    /// root.
    public func purgeExpiredTrash(now: Date = Date()) async {
        let cutoff = now.addingTimeInterval(-Self.trashRetention)
        var purged = false
        for meta in await store.listMetas() {
            guard let trashedAt = meta.trashedAt, trashedAt < cutoff else { continue }
            do {
                try await store.delete(meta.id)
                purged = true
            } catch {
                ErrorTrace.record(
                    "Purging expired trash failed",
                    error: error,
                    category: "MeetingLibrary",
                    metadata: ["meetingID": meta.id.uuidString]
                )
            }
        }
        if purged { await refresh() }
    }

    /// Fills in `wordCount` for meetings saved before it was denormalized (a
    /// one-time, self-healing migration). New meetings already carry it, so
    /// this is usually a no-op. Patches rows in place as it goes.
    public func backfillWordCounts() async {
        guard !isBackfilling else { return }
        let missing = metas.filter { $0.wordCount == nil }.map(\.id)
        guard !missing.isEmpty else { return }
        isBackfilling = true
        defer { isBackfilling = false }
        for id in missing {
            guard let record = await loadRecord(id) else { continue }
            var meta = record.meta
            meta.wordCount = TranscriptSegment.wordCount(of: record.segments)
            do {
                try await store.updateMeta(meta)
            } catch {
                ErrorTrace.record(
                    "Word-count backfill failed",
                    error: error,
                    category: "MeetingLibrary",
                    metadata: ["meetingID": id.uuidString]
                )
                continue
            }
            if let index = metas.firstIndex(where: { $0.id == id }) {
                metas[index].wordCount = meta.wordCount
            }
        }
    }

    /// Loads a full meeting for the document view. Returns `nil` (traced) if
    /// the folder is missing or corrupt, so the UI can show an unavailable
    /// state instead of crashing.
    public func loadRecord(_ id: UUID) async -> MeetingRecord? {
        do {
            return try await store.loadRecord(id)
        } catch {
            ErrorTrace.record(
                "Loading meeting failed",
                error: error,
                category: "MeetingLibrary",
                metadata: ["meetingID": id.uuidString]
            )
            return nil
        }
    }

    /// The current meta for an id from whichever list holds it.
    public func meta(for id: UUID) -> MeetingMeta? {
        metas.first { $0.id == id } ?? trashedMetas.first { $0.id == id }
    }

    // MARK: - Mutations

    /// Renames a meeting. Trims whitespace and ignores an empty result — a
    /// meeting always keeps a title.
    public func rename(_ id: UUID, to newTitle: String) async {
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, var meta = meta(for: id), meta.title != trimmed else { return }
        meta.title = trimmed
        await update(meta)
    }

    /// Moves a meeting to Trash (soft-delete). It keeps all its files and is
    /// permanently removed once it has sat in Trash past `trashRetention`.
    public func trash(_ id: UUID) async {
        guard var meta = meta(for: id), !meta.isTrashed else { return }
        meta.trashedAt = Date()
        await update(meta)
    }

    /// Restores a trashed meeting back into the library.
    public func restore(_ id: UUID) async {
        guard var meta = trashedMetas.first(where: { $0.id == id }) else { return }
        meta.trashedAt = nil
        await update(meta)
    }

    /// Permanently deletes a meeting's folder and refreshes.
    public func deletePermanently(_ id: UUID) async {
        do {
            try await store.delete(id)
            await refresh()
        } catch {
            ErrorTrace.record(
                "Deleting meeting failed",
                error: error,
                category: "MeetingLibrary",
                metadata: ["meetingID": id.uuidString]
            )
        }
    }

    /// Empties the Trash: permanently deletes every trashed meeting.
    public func emptyTrash() async {
        for meta in trashedMetas {
            do {
                try await store.delete(meta.id)
            } catch {
                ErrorTrace.record(
                    "Emptying trash failed",
                    error: error,
                    category: "MeetingLibrary",
                    metadata: ["meetingID": meta.id.uuidString]
                )
            }
        }
        await refresh()
    }

    // MARK: - Preserved recordings

    /// The preserved-audio files in the meeting's folder.
    public func preservedAudioFiles(for id: UUID) async -> [AudioChannel: URL] {
        await store.preservedAudioFiles(for: id)
    }

    /// Deletes exactly the meeting's preserved recording and re-measures.
    public func deletePreservedAudio(for id: UUID) async {
        await store.deletePreservedAudio(for: id)
        measureStorage()
    }

    /// Deletes every saved recording (the settings page's global action) and
    /// re-measures so the numbers move with the bytes.
    public func deleteAllPreservedAudio() async {
        await store.deleteAllPreservedAudio()
        measureStorage()
    }

    // MARK: - Storage

    /// Measures the breakdown off the main actor (detached, utility priority)
    /// and publishes it. Called by `refresh()` and after deletions.
    public func measureStorage() {
        let root = store.rootDirectory
        let live = metas.map(\.id)
        let trashed = trashedMetas.map(\.id)
        let models = modelsDirectory
        Task.detached(priority: .utility) { [weak self] in
            let breakdown = StorageBreakdown.measure(
                meetingsRoot: root,
                nonTrashedIDs: live,
                trashedIDs: trashed,
                modelsDirectory: models
            )
            await MainActor.run { self?.storage = breakdown }
        }
    }

    // MARK: - Helpers

    private func update(_ meta: MeetingMeta) async {
        do {
            try await store.updateMeta(meta)
            await refresh()
        } catch {
            ErrorTrace.record(
                "Updating meeting failed",
                error: error,
                category: "MeetingLibrary",
                metadata: ["meetingID": meta.id.uuidString]
            )
        }
    }
}
