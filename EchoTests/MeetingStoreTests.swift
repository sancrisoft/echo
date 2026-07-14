//
//  MeetingStoreTests.swift
//  EchoTests
//
//  Exercises the persistent meeting library (SPEC-03) against a temp root per
//  test: round-trip fidelity, summary attachment, ordering + corruption
//  tolerance, deletion, the sidecar directory contract, and the stable on-disk
//  encoding SPEC-06/08 depend on. Constructed text segments (no audio) —
//  allowed for store tests per the project's test policy.
//

import Foundation
import Testing
@testable import Echo

@Suite("MeetingStore")
struct MeetingStoreTests {

    // MARK: - Helpers

    /// Runs `body` against a store rooted at a fresh temp directory, then
    /// removes it. Root does not exist up front — the store must create it.
    private func withTempStore<T>(_ body: (MeetingStore, URL) async throws -> T) async rethrows -> T {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "MeetingStoreTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        return try await body(MeetingStore(rootDirectory: root), root)
    }

    private func makeMeta(
        id: UUID = UUID(),
        title: String = "Test Meeting",
        startedAt: Date = Date(timeIntervalSince1970: 1_700_000_000),
        durationSeconds: TimeInterval = 90,
        segmentCount: Int = 0,
        hasSummary: Bool = false
    ) -> MeetingMeta {
        MeetingMeta(
            id: id,
            title: title,
            startedAt: startedAt,
            endedAt: startedAt.addingTimeInterval(durationSeconds),
            segmentCount: segmentCount,
            hasSummary: hasSummary
        )
    }

    private func makeSegments(_ count: Int = 2) -> [TranscriptSegment] {
        (0..<count).map { index in
            TranscriptSegment(
                channel: index.isMultiple(of: 2) ? .microphone : .system,
                speaker: index.isMultiple(of: 2) ? .me : .teammates,
                text: "Line \(index)",
                start: TimeInterval(index),
                end: TimeInterval(index) + 0.5
            )
        }
    }

    private func makeSummary() -> MeetingSummary {
        MeetingSummary(
            shortSummary: "Short",
            detailedSummary: "Detailed",
            decisions: [SummaryDecision(title: "Ship it", details: "Approved", evidenceSegmentIDs: [])],
            actionItems: [SummaryActionItem(task: "Follow up", owner: nil, dueDate: nil, evidenceSegmentIDs: [])],
            openQuestions: [],
            risks: []
        )
    }

    // MARK: - Round trip

    @Test("save then loadRecord returns identical transcript and normalized meta")
    func roundTrip() async throws {
        try await withTempStore { store, _ in
            let segments = makeSegments(3)
            let meta = makeMeta(segmentCount: 99)   // wrong on purpose: save normalizes it
            try await store.save(MeetingRecord(meta: meta, segments: segments, summary: nil))

            let loaded = try await store.loadRecord(meta.id)
            #expect(loaded.segments == segments)
            #expect(loaded.summary == nil)
            #expect(loaded.meta.id == meta.id)
            #expect(loaded.meta.title == meta.title)
            #expect(loaded.meta.segmentCount == 3)     // reflects what was saved
            #expect(loaded.meta.hasSummary == false)
            #expect(loaded.meta.schemaVersion == 1)
        }
    }

    @Test("save with a summary sets hasSummary and round-trips it")
    func saveWithSummary() async throws {
        try await withTempStore { store, _ in
            let meta = makeMeta()
            try await store.save(MeetingRecord(meta: meta, segments: makeSegments(), summary: makeSummary()))

            let loaded = try await store.loadRecord(meta.id)
            #expect(loaded.summary == makeSummary())
            #expect(loaded.meta.hasSummary == true)
            #expect(await store.listMetas().first?.hasSummary == true)
        }
    }

    // MARK: - attachSummary

    @Test("attachSummary writes the summary and flips meta.hasSummary")
    func attachSummary() async throws {
        try await withTempStore { store, _ in
            let meta = makeMeta()
            try await store.save(MeetingRecord(meta: meta, segments: makeSegments(), summary: nil))
            #expect(try await store.loadRecord(meta.id).summary == nil)

            try await store.attachSummary(makeSummary(), to: meta.id)

            let loaded = try await store.loadRecord(meta.id)
            #expect(loaded.summary == makeSummary())
            #expect(loaded.meta.hasSummary == true)
            #expect(await store.listMetas().first?.hasSummary == true)
        }
    }

    // MARK: - listMetas

    @Test("listMetas is empty when no meeting has ever been saved")
    func listMetasEmpty() async {
        await withTempStore { store, _ in
            #expect(await store.listMetas().isEmpty)
        }
    }

    @Test("listMetas orders newest-first by startedAt")
    func listMetasOrder() async throws {
        try await withTempStore { store, _ in
            let base = Date(timeIntervalSince1970: 1_700_000_000)
            let oldest = makeMeta(id: UUID(), title: "Oldest", startedAt: base)
            let middle = makeMeta(id: UUID(), title: "Middle", startedAt: base.addingTimeInterval(3600))
            let newest = makeMeta(id: UUID(), title: "Newest", startedAt: base.addingTimeInterval(7200))
            // Save out of order to prove sorting, not insertion order.
            for meta in [middle, oldest, newest] {
                try await store.save(MeetingRecord(meta: meta, segments: makeSegments(), summary: nil))
            }

            let titles = await store.listMetas().map(\.title)
            #expect(titles == ["Newest", "Middle", "Oldest"])
        }
    }

    @Test("listMetas skips folders with corrupt or missing meta.json")
    func listMetasTolerance() async throws {
        try await withTempStore { store, root in
            let good = makeMeta(id: UUID(), title: "Good")
            try await store.save(MeetingRecord(meta: good, segments: makeSegments(), summary: nil))

            let fileManager = FileManager.default
            // A folder whose meta.json is garbage.
            let corrupt = root.appending(path: UUID().uuidString, directoryHint: .isDirectory)
            try fileManager.createDirectory(at: corrupt, withIntermediateDirectories: true)
            try Data("not json".utf8).write(to: corrupt.appending(path: "meta.json"))
            // A folder with no meta.json at all.
            let empty = root.appending(path: UUID().uuidString, directoryHint: .isDirectory)
            try fileManager.createDirectory(at: empty, withIntermediateDirectories: true)

            let metas = await store.listMetas()
            #expect(metas.count == 1)
            #expect(metas.first?.title == "Good")
        }
    }

    // MARK: - delete

    @Test("delete removes the whole meeting folder")
    func delete() async throws {
        try await withTempStore { store, root in
            let meta = makeMeta()
            try await store.save(MeetingRecord(meta: meta, segments: makeSegments(), summary: makeSummary()))
            #expect(FileManager.default.fileExists(atPath: store.directory(for: meta.id).path))

            try await store.delete(meta.id)

            #expect(!FileManager.default.fileExists(atPath: store.directory(for: meta.id).path))
            #expect(await store.listMetas().isEmpty)
        }
    }

    @Test("delete of an unknown meeting is a no-op")
    func deleteMissing() async throws {
        try await withTempStore { store, _ in
            try await store.delete(UUID())   // must not throw
        }
    }

    // MARK: - directory contract (SPEC-06/08)

    @Test("directory(for:) is stable and rooted at the store root")
    func directoryContract() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "MeetingStoreTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        let store = MeetingStore(rootDirectory: root)
        let id = UUID()
        let first = store.directory(for: id)
        #expect(first == store.directory(for: id))
        #expect(first == root.appending(path: id.uuidString, directoryHint: .isDirectory))
    }

    // MARK: - Encoder golden

    @Test("meta.json encodes with sorted keys and iso8601 dates")
    func metaGolden() async throws {
        try await withTempStore { store, _ in
            let id = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
            let meta = makeMeta(
                id: id,
                title: "Test Meeting",
                startedAt: Date(timeIntervalSince1970: 1_700_000_000),
                durationSeconds: 90
            )
            try await store.save(MeetingRecord(meta: meta, segments: makeSegments(2), summary: nil))

            let data = try Data(contentsOf: store.directory(for: id).appending(path: "meta.json"))
            let json = String(decoding: data, as: UTF8.self)

            let expected = """
            {
              "endedAt" : "2023-11-14T22:14:50Z",
              "hasSummary" : false,
              "id" : "00000000-0000-0000-0000-000000000001",
              "schemaVersion" : 1,
              "segmentCount" : 2,
              "startedAt" : "2023-11-14T22:13:20Z",
              "title" : "Test Meeting"
            }
            """
            #expect(json == expected)
        }
    }
}
