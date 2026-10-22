//
//  SummaryStoreMigrationTests.swift
//  MeetingsTests
//
//  S11: `summary.md` becomes the single summary store, and launch folds every
//  legacy `summary.json` into it — decode the json, write its resolved
//  markdown, and only once the markdown is safely on disk delete the json.
//  RetiredModelCleanup's discipline (ADR-011) applied to data: runs every
//  launch, an already-migrated library is a silent no-op, per-meeting
//  failures never stop the scan, and nothing is deleted before its
//  replacement exists — a crash mid-migration never loses a summary.
//

import EchoCore
import EchoCoreTestSupport
import Foundation
import Meetings
import Testing

@Suite("Legacy summary migration")
struct SummaryStoreMigrationTests {

    // MARK: - Helpers (MeetingStoreTests' temp-dir pattern)

    /// Runs `body` against a store rooted at a fresh temp directory, then
    /// removes it. Root does not exist up front — the store must create it.
    private func withTempStore<T>(_ body: (MeetingStore, URL) async throws -> T) async throws -> T {
        let temp = try TemporaryDirectory(prefix: "SummaryStoreMigrationTests")
        defer { temp.remove() }
        let root = temp.path("Meetings")
        return try await body(MeetingStore(rootDirectory: root), root)
    }

    private func makeMeta(id: UUID = UUID(), title: String = "Legacy Meeting") -> MeetingMeta {
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
        return MeetingMeta(
            id: id,
            title: title,
            startedAt: startedAt,
            endedAt: startedAt.addingTimeInterval(90),
            segmentCount: 0,
            hasSummary: true
        )
    }

    /// Saves a summary-less meeting and plants `contents` verbatim as its
    /// `summary.json` — the bytes a pre-S11 build left on disk.
    private func plantLegacyMeeting(json contents: String, in store: MeetingStore) async throws -> UUID {
        let meta = makeMeta()
        try await store.save(MeetingRecord(meta: meta, segments: [], summaryMarkdown: nil))
        try Data(contents.utf8).write(to: jsonURL(for: meta.id, in: store))
        return meta.id
    }

    /// Saves a summary-less meeting and plants `summary`, encoded, as its
    /// `summary.json` — the fixed schema a pre-S11 build wrote.
    private func plantLegacyMeeting(_ summary: LegacyMeetingSummary, in store: MeetingStore) async throws -> UUID {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        let data = try encoder.encode(summary)
        return try await plantLegacyMeeting(json: String(decoding: data, as: UTF8.self), in: store)
    }

    /// The canonical pre-S11 `summary.json` bytes — the fixed schema, no
    /// `markdown` key. Decodes to `legacySummary`.
    private var legacyJSON: String {
        """
        {
          "actionItems" : [
            {
              "evidenceSegmentIDs" : [],
              "task" : "Follow up"
            }
          ],
          "decisions" : [
            {
              "details" : "Approved",
              "evidenceSegmentIDs" : [],
              "title" : "Ship it"
            }
          ],
          "detailedSummary" : "Detailed",
          "openQuestions" : [],
          "risks" : [],
          "shortSummary" : "Short"
        }
        """
    }

    /// The summary `legacyJSON` decodes to — its `resolvedMarkdown` is the
    /// exact document the migration must write.
    private var legacySummary: LegacyMeetingSummary {
        LegacyMeetingSummary(
            shortSummary: "Short",
            detailedSummary: "Detailed",
            decisions: [LegacyMeetingSummary.Decision(title: "Ship it", details: "Approved", evidenceSegmentIDs: [])],
            actionItems: [
                LegacyMeetingSummary.ActionItem(task: "Follow up", owner: nil, dueDate: nil, evidenceSegmentIDs: [])
            ],
            openQuestions: [],
            risks: []
        )
    }

    private func markdownURL(for id: UUID, in store: MeetingStore) -> URL {
        store.directory(for: id).appending(path: MeetingStore.Filename.summaryMarkdown)
    }

    private func jsonURL(for id: UUID, in store: MeetingStore) -> URL {
        store.directory(for: id).appending(path: MeetingStore.Filename.legacySummary)
    }

    private func contents(of url: URL) throws -> String {
        try String(decoding: Data(contentsOf: url), as: UTF8.self)
    }

    private func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    private func listing(of id: UUID, in store: MeetingStore) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: store.directory(for: id).path).sorted()
    }

    // MARK: - Conversion

    @Test("a legacy folder migrates: summary.md holds the resolved markdown, the json is gone")
    func legacyFolderMigrates() async throws {
        try await withTempStore { store, _ in
            let id = try await plantLegacyMeeting(json: legacyJSON, in: store)

            await store.migrateLegacySummaries()

            #expect(try contents(of: markdownURL(for: id, in: store)) == legacySummary.resolvedMarkdown)
            #expect(!exists(jsonURL(for: id, in: store)))
            // ...and the meeting loads as a markdown-era summary afterward.
            let summary = try #require(await store.loadRecord(id).summaryMarkdown)
            #expect(summary == legacySummary.resolvedMarkdown)
        }
    }

    @Test("an encoded legacy summary (with its empty markdown key) folds the same way")
    func encodedLegacySummaryMigrates() async throws {
        try await withTempStore { store, _ in
            // The last pre-S11 builds wrote `markdown` too — empty when the
            // summary came off the facts-only route. Same fold, same result.
            let id = try await plantLegacyMeeting(legacySummary, in: store)

            await store.migrateLegacySummaries()

            #expect(try contents(of: markdownURL(for: id, in: store)) == legacySummary.resolvedMarkdown)
            #expect(!exists(jsonURL(for: id, in: store)))
        }
    }

    @Test("migration is idempotent — a second run changes nothing")
    func migrationIsIdempotent() async throws {
        try await withTempStore { store, _ in
            let id = try await plantLegacyMeeting(legacySummary, in: store)

            await store.migrateLegacySummaries()
            let bytesAfterFirst = try Data(contentsOf: markdownURL(for: id, in: store))
            let listingAfterFirst = try listing(of: id, in: store)

            // The launch hook runs this EVERY launch, unconditionally — the
            // steady state must be a byte-identical no-op.
            await store.migrateLegacySummaries()

            #expect(try Data(contentsOf: markdownURL(for: id, in: store)) == bytesAfterFirst)
            #expect(try listing(of: id, in: store) == listingAfterFirst)
        }
    }

    @Test("a crash between md-write and json-delete heals: the md is kept verbatim, the json deleted")
    func interruptedMigrationHeals() async throws {
        try await withTempStore { store, _ in
            let id = try await plantLegacyMeeting(legacySummary, in: store)
            // The md already there — from the crashed run, or hand-edited
            // since. Its content deliberately differs from the json's
            // serialization to prove it is never rewritten.
            let existing = "### Notes\nEdited by hand since."
            try Data(existing.utf8).write(to: markdownURL(for: id, in: store))

            await store.migrateLegacySummaries()

            #expect(try contents(of: markdownURL(for: id, in: store)) == existing)
            #expect(!exists(jsonURL(for: id, in: store)))
        }
    }

    // MARK: - Non-fatal failure isolation

    @Test("a corrupt summary.json is kept — and the rest of the library still migrates")
    func corruptJSONIsKeptAndIsolated() async throws {
        try await withTempStore { store, _ in
            let corrupt = try await plantLegacyMeeting(json: "not json at all", in: store)
            let healthy = try await plantLegacyMeeting(json: legacyJSON, in: store)

            await store.migrateLegacySummaries()

            // The corrupt json survives untouched (never delete before a
            // replacement is safely on disk) and no md claims to be it...
            #expect(exists(jsonURL(for: corrupt, in: store)))
            #expect(!exists(markdownURL(for: corrupt, in: store)))
            // ...while the healthy meeting converted normally.
            #expect(!exists(jsonURL(for: healthy, in: store)))
            #expect(try contents(of: markdownURL(for: healthy, in: store)) == legacySummary.resolvedMarkdown)
        }
    }

    @Test("an entirely empty legacy summary keeps its json — nothing is deleted without a replacement")
    func emptyLegacySummaryKeepsItsJSON() async throws {
        try await withTempStore { store, _ in
            let empty = LegacyMeetingSummary()
            #expect(empty.resolvedMarkdown == "")
            let id = try await plantLegacyMeeting(empty, in: store)

            await store.migrateLegacySummaries()

            // No markdown to carry over: an empty summary.md would claim
            // notes that don't exist, and deleting the json would erase the
            // meeting's only summary artifact. Both stay as they were.
            #expect(exists(jsonURL(for: id, in: store)))
            #expect(!exists(markdownURL(for: id, in: store)))
        }
    }

    // MARK: - No-ops

    @Test("a folder with no summary files is untouched")
    func summaryLessFolderUntouched() async throws {
        try await withTempStore { store, _ in
            let meta = makeMeta(title: "No summary yet")
            try await store.save(MeetingRecord(meta: meta, segments: [], summaryMarkdown: nil))
            let directory = store.directory(for: meta.id)
            let listingBefore = try listing(of: meta.id, in: store)
            let metaBytes = try Data(contentsOf: directory.appending(path: MeetingStore.Filename.meta))

            await store.migrateLegacySummaries()

            #expect(try listing(of: meta.id, in: store) == listingBefore)
            #expect(try Data(contentsOf: directory.appending(path: MeetingStore.Filename.meta)) == metaBytes)
        }
    }

    @Test("an empty (or never-created) library is a silent no-op")
    func emptyLibraryIsANoOp() async throws {
        try await withTempStore { store, root in
            // The root doesn't even exist yet — no meeting was ever saved.
            await store.migrateLegacySummaries()
            #expect(!exists(root))
        }
    }
}
