//
//  MeetingLibraryTests.swift
//  MeetingsTests
//
//  The main-actor façade over the store: `refresh()` is a pure read that
//  splits live from trashed, the destructive housekeeping (purging expired
//  trash) is explicit and only ever touches what has expired, and the row
//  mutations (rename, trash, restore, delete, empty trash, word-count
//  backfill) land on disk and re-read from it. Fixtures are saved through the
//  store into a temp root — never the real data root.
//

import EchoCore
import EchoCoreTestSupport
import Foundation
import Meetings
import Testing

@Suite("MeetingLibrary")
@MainActor
struct MeetingLibraryTests {

    // MARK: - Helpers

    /// Runs `body` against a library over a store rooted at a fresh temp
    /// directory, then removes it.
    private func withTempLibrary<T>(_ body: (MeetingLibrary, MeetingStore) async throws -> T) async throws -> T {
        let temp = try TemporaryDirectory(prefix: "MeetingLibraryTests")
        defer { temp.remove() }
        let store = MeetingStore(rootDirectory: temp.path("Meetings"))
        return try await body(MeetingLibrary(store: store, modelsDirectory: nil), store)
    }

    private let base = Date(timeIntervalSince1970: 1_700_000_000)

    /// Saves a meeting `age` seconds before `base`, trashed at `trashedAt`
    /// when given. `wordCount` stays `nil` unless passed — the shape a
    /// pre-denormalization folder has.
    @discardableResult
    private func saveMeeting(
        in store: MeetingStore,
        title: String = "Meeting",
        age: TimeInterval = 0,
        trashedAt: Date? = nil,
        wordCount: Int? = nil,
        segments: [TranscriptSegment]? = nil
    ) async throws -> UUID {
        let startedAt = base.addingTimeInterval(-age)
        let meta = MeetingMeta(
            id: UUID(),
            title: title,
            startedAt: startedAt,
            endedAt: startedAt.addingTimeInterval(60),
            segmentCount: 0,
            hasSummary: false,
            wordCount: wordCount,
            trashedAt: trashedAt
        )
        let segments =
            segments ?? [TranscriptSegment(channel: .microphone, text: "one two three", start: 0, end: 1)]
        try await store.save(MeetingRecord(meta: meta, segments: segments, summaryMarkdown: nil))
        return meta.id
    }

    private func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    private let day: TimeInterval = 24 * 60 * 60

    // MARK: - refresh

    @Test("refresh splits live from trashed, newest first, and deletes nothing")
    func refreshSplitsLiveAndTrashed() async throws {
        try await withTempLibrary { library, store in
            let oldest = try await saveMeeting(in: store, title: "Oldest", age: 7200)
            let newest = try await saveMeeting(in: store, title: "Newest", age: 0)
            let middle = try await saveMeeting(in: store, title: "Middle", age: 3600)
            // Trashed at different times — including one long past the
            // retention window, which a READ must never purge.
            let now = Date()
            let trashedRecently = try await saveMeeting(
                in: store, title: "Trashed recently", age: 10_000, trashedAt: now.addingTimeInterval(-day))
            let trashedLongAgo = try await saveMeeting(
                in: store, title: "Trashed long ago", age: 20_000, trashedAt: now.addingTimeInterval(-90 * day))

            await library.refresh()

            #expect(library.metas.map(\.id) == [newest, middle, oldest])
            #expect(library.metas.allSatisfy { !$0.isTrashed })
            // Most recently trashed first.
            #expect(library.trashedMetas.map(\.id) == [trashedRecently, trashedLongAgo])
            // Reading never writes: every folder is still there, expired or not.
            for id in [oldest, middle, newest, trashedRecently, trashedLongAgo] {
                #expect(exists(store.directory(for: id)))
            }
            #expect(await store.listMetas().count == 5)
        }
    }

    @Test("meta(for:) finds a row in either list")
    func metaForFindsEitherList() async throws {
        try await withTempLibrary { library, store in
            let live = try await saveMeeting(in: store, title: "Live")
            let trashed = try await saveMeeting(in: store, title: "Trashed", age: 100, trashedAt: Date())
            await library.refresh()

            #expect(library.meta(for: live)?.title == "Live")
            #expect(library.meta(for: trashed)?.title == "Trashed")
            #expect(library.meta(for: UUID()) == nil)
        }
    }

    // MARK: - purgeExpiredTrash

    @Test("purgeExpiredTrash deletes only folders trashed past 30 days")
    func purgeDeletesOnlyExpiredTrash() async throws {
        try await withTempLibrary { library, store in
            let now = Date(timeIntervalSince1970: 1_800_000_000)
            let live = try await saveMeeting(in: store, title: "Live")
            let fresh = try await saveMeeting(
                in: store, title: "Fresh trash", age: 100, trashedAt: now.addingTimeInterval(-29 * day))
            let expired = try await saveMeeting(
                in: store, title: "Expired trash", age: 200, trashedAt: now.addingTimeInterval(-31 * day))

            await library.purgeExpiredTrash(now: now)

            #expect(!exists(store.directory(for: expired)))
            #expect(exists(store.directory(for: fresh)))
            #expect(exists(store.directory(for: live)))
            // The lists reflect the purge without a separate refresh.
            #expect(library.metas.map(\.id) == [live])
            #expect(library.trashedMetas.map(\.id) == [fresh])
        }
    }

    @Test("purgeExpiredTrash with nothing expired changes nothing")
    func purgeWithNothingExpiredIsANoOp() async throws {
        try await withTempLibrary { library, store in
            let now = Date(timeIntervalSince1970: 1_800_000_000)
            let live = try await saveMeeting(in: store, title: "Live")
            let fresh = try await saveMeeting(in: store, title: "Fresh trash", age: 100, trashedAt: now)
            let metaBytes = try Data(
                contentsOf: store.directory(for: fresh).appending(path: MeetingStore.Filename.meta))

            await library.purgeExpiredTrash(now: now)

            #expect(exists(store.directory(for: live)))
            #expect(exists(store.directory(for: fresh)))
            #expect(
                try Data(contentsOf: store.directory(for: fresh).appending(path: MeetingStore.Filename.meta))
                    == metaBytes)
        }
    }

    // MARK: - trash / restore / delete

    @Test("trash soft-deletes: the row moves to Trash, its files stay")
    func trashMovesTheRow() async throws {
        try await withTempLibrary { library, store in
            let id = try await saveMeeting(in: store)
            await library.refresh()

            await library.trash(id)

            #expect(library.metas.isEmpty)
            #expect(library.trashedMetas.map(\.id) == [id])
            #expect(library.trashedMetas.first?.trashedAt != nil)
            #expect(exists(store.directory(for: id)))
            #expect(try await store.loadMeta(id).isTrashed)
            // Trashing twice does not move the timestamp.
            let firstTrashedAt = library.trashedMetas.first?.trashedAt
            await library.trash(id)
            #expect(library.trashedMetas.first?.trashedAt == firstTrashedAt)
        }
    }

    @Test("restore brings a trashed row back into the library")
    func restoreBringsTheRowBack() async throws {
        try await withTempLibrary { library, store in
            let id = try await saveMeeting(in: store)
            await library.refresh()
            await library.trash(id)

            await library.restore(id)

            #expect(library.trashedMetas.isEmpty)
            #expect(library.metas.map(\.id) == [id])
            #expect(library.metas.first?.trashedAt == nil)
            #expect(try await store.loadMeta(id).trashedAt == nil)
            // Restoring a live (non-trashed) row is a no-op.
            await library.restore(id)
            #expect(library.metas.map(\.id) == [id])
        }
    }

    @Test("deletePermanently removes the folder and refreshes")
    func deletePermanentlyRemovesTheFolder() async throws {
        try await withTempLibrary { library, store in
            let keep = try await saveMeeting(in: store, title: "Keep")
            let gone = try await saveMeeting(in: store, title: "Gone", age: 100)
            await library.refresh()

            await library.deletePermanently(gone)

            #expect(!exists(store.directory(for: gone)))
            #expect(exists(store.directory(for: keep)))
            #expect(library.metas.map(\.id) == [keep])
        }
    }

    @Test("emptyTrash deletes every trashed meeting and only those")
    func emptyTrashDeletesOnlyTrashed() async throws {
        try await withTempLibrary { library, store in
            let live = try await saveMeeting(in: store, title: "Live")
            let trashedA = try await saveMeeting(in: store, title: "A", age: 100, trashedAt: Date())
            let trashedB = try await saveMeeting(in: store, title: "B", age: 200, trashedAt: Date())
            await library.refresh()

            await library.emptyTrash()

            #expect(!exists(store.directory(for: trashedA)))
            #expect(!exists(store.directory(for: trashedB)))
            #expect(exists(store.directory(for: live)))
            #expect(library.trashedMetas.isEmpty)
            #expect(library.metas.map(\.id) == [live])
        }
    }

    // MARK: - rename

    @Test("rename trims whitespace and persists; an empty result is ignored")
    func renameTrimsAndIgnoresEmpty() async throws {
        try await withTempLibrary { library, store in
            let id = try await saveMeeting(in: store, title: "Original")
            await library.refresh()

            await library.rename(id, to: "  Planning sync  ")
            #expect(library.meta(for: id)?.title == "Planning sync")
            #expect(try await store.loadMeta(id).title == "Planning sync")

            // Whitespace-only is no title: a meeting always keeps one.
            await library.rename(id, to: "   \n")
            #expect(library.meta(for: id)?.title == "Planning sync")
            #expect(try await store.loadMeta(id).title == "Planning sync")
            await library.rename(id, to: "")
            #expect(try await store.loadMeta(id).title == "Planning sync")
        }
    }

    @Test("rename also reaches a trashed row")
    func renameReachesTrashedRows() async throws {
        try await withTempLibrary { library, store in
            let id = try await saveMeeting(in: store, title: "Original", trashedAt: Date())
            await library.refresh()

            await library.rename(id, to: "Renamed in Trash")

            #expect(library.trashedMetas.first?.title == "Renamed in Trash")
            #expect(try await store.loadMeta(id).isTrashed)
        }
    }

    // MARK: - backfillWordCounts

    @Test("backfillWordCounts fills a nil wordCount from the transcript and leaves the rest alone")
    func backfillFillsMissingWordCounts() async throws {
        try await withTempLibrary { library, store in
            let segments = [
                TranscriptSegment(channel: .microphone, text: "one two three", start: 0, end: 1),
                TranscriptSegment(channel: .system, text: "four  five", start: 1, end: 2),
            ]
            let missing = try await saveMeeting(in: store, title: "Missing", segments: segments)
            // A row that already carries a count — deliberately "wrong" to
            // prove the backfill never recomputes what exists.
            let counted = try await saveMeeting(in: store, title: "Counted", age: 100, wordCount: 42)
            let countedMetaURL = store.directory(for: counted).appending(path: MeetingStore.Filename.meta)
            let countedBytes = try Data(contentsOf: countedMetaURL)
            await library.refresh()
            #expect(library.meta(for: missing)?.wordCount == nil)

            await library.backfillWordCounts()

            let expected = TranscriptSegment.wordCount(of: segments)
            #expect(expected == 5)
            #expect(library.meta(for: missing)?.wordCount == expected)
            #expect(try await store.loadMeta(missing).wordCount == expected)
            #expect(library.meta(for: counted)?.wordCount == 42)
            #expect(try Data(contentsOf: countedMetaURL) == countedBytes)
        }
    }

    @Test("backfillWordCounts with nothing missing writes nothing")
    func backfillWithNothingMissingIsANoOp() async throws {
        try await withTempLibrary { library, store in
            let id = try await saveMeeting(in: store, wordCount: 3)
            let metaURL = store.directory(for: id).appending(path: MeetingStore.Filename.meta)
            let before = try Data(contentsOf: metaURL)
            await library.refresh()

            await library.backfillWordCounts()

            #expect(try Data(contentsOf: metaURL) == before)
        }
    }
}
