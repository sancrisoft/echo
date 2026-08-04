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

    private func makeProvenance(
        source: TranscriptProvenance.Source = .finalPass,
        modelName: String = "large-v3_947MB",
        tier: String = "fullLargeV3",
        servedByFallback: Bool = false
    ) -> TranscriptProvenance {
        TranscriptProvenance(
            source: source,
            modelName: modelName,
            tier: tier,
            servedByFallback: servedByFallback
        )
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

    @Test("attachSummary records the summary model name alongside hasSummary")
    func attachSummaryRecordsModelName() async throws {
        try await withTempStore { store, _ in
            let meta = makeMeta()
            try await store.save(MeetingRecord(meta: meta, segments: makeSegments(), summary: nil))

            try await store.attachSummary(
                makeSummary(),
                modelName: "mlx-community/Qwen3.5-4B-OptiQ-4bit",
                to: meta.id
            )

            let loaded = try await store.loadRecord(meta.id)
            #expect(loaded.meta.hasSummary == true)
            #expect(loaded.meta.summaryModelName == "mlx-community/Qwen3.5-4B-OptiQ-4bit")
        }
    }

    @Test("attachSummary without a model name leaves the field absent")
    func attachSummaryWithoutModelName() async throws {
        try await withTempStore { store, _ in
            let meta = makeMeta()
            try await store.save(MeetingRecord(meta: meta, segments: makeSegments(), summary: nil))

            try await store.attachSummary(makeSummary(), to: meta.id)

            let loaded = try await store.loadRecord(meta.id)
            #expect(loaded.meta.hasSummary == true)
            #expect(loaded.meta.summaryModelName == nil)
            let json = try String(
                decoding: Data(contentsOf: store.directory(for: meta.id).appending(path: "meta.json")),
                as: UTF8.self
            )
            #expect(!json.contains("summaryModelName"))
        }
    }

    // MARK: - Provenance (SP-007, ADR-022)

    @Test("a meta written without provenance decodes with nil provenance fields")
    func metaWithoutProvenanceDecodesNil() async throws {
        try await withTempStore { store, root in
            // A pre-SP-007 meta.json, verbatim: no provenance fields at all.
            let id = UUID()
            let directory = root.appending(path: id.uuidString, directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let legacy = """
            {
              "endedAt" : "2023-11-14T22:14:50Z",
              "hasSummary" : false,
              "id" : "\(id.uuidString)",
              "schemaVersion" : 1,
              "segmentCount" : 2,
              "startedAt" : "2023-11-14T22:13:20Z",
              "title" : "Legacy Meeting"
            }
            """
            try Data(legacy.utf8).write(to: directory.appending(path: "meta.json"))

            let metas = await store.listMetas()
            #expect(metas.count == 1)
            #expect(metas.first?.transcriptProvenance == nil)
            #expect(metas.first?.summaryModelName == nil)
        }
    }

    @Test("an untouched old meeting's meta.json stays byte-identical after reads")
    func untouchedMetaStaysByteIdentical() async throws {
        try await withTempStore { store, _ in
            let meta = makeMeta()
            try await store.save(MeetingRecord(meta: meta, segments: makeSegments(), summary: nil))
            let metaURL = store.directory(for: meta.id).appending(path: "meta.json")
            let before = try Data(contentsOf: metaURL)

            _ = await store.listMetas()
            _ = try await store.loadRecord(meta.id)

            #expect(try Data(contentsOf: metaURL) == before)
        }
    }

    @Test("recordLiveFloorProvenance writes exactly meta.json — transcript untouched")
    func recordLiveFloorProvenanceWritesOnlyMeta() async throws {
        try await withTempStore { store, _ in
            let meta = makeMeta()
            let segments = makeSegments()
            try await store.save(MeetingRecord(meta: meta, segments: segments, summary: nil))
            let directory = store.directory(for: meta.id)
            let transcriptBytes = try Data(contentsOf: directory.appending(path: "transcript.json"))
            let filesBefore = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()

            let provenance = makeProvenance(
                source: .liveFloor,
                modelName: "large-v3-v20240930_626MB",
                tier: "reuseLive"
            )
            try await store.recordLiveFloorProvenance(for: meta.id, provenance: provenance)

            let loaded = try await store.loadRecord(meta.id)
            #expect(loaded.meta.transcriptProvenance == provenance)
            #expect(loaded.segments == segments)
            #expect(try Data(contentsOf: directory.appending(path: "transcript.json")) == transcriptBytes)
            #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted() == filesBefore)
        }
    }

    @Test("recordLiveFloorProvenance on a missing meeting throws and creates nothing")
    func recordLiveFloorProvenanceMissingMeetingThrows() async throws {
        try await withTempStore { store, _ in
            let ghost = UUID()
            await #expect(throws: (any Error).self) {
                try await store.recordLiveFloorProvenance(for: ghost, provenance: makeProvenance(source: .liveFloor))
            }
            #expect(!FileManager.default.fileExists(atPath: store.directory(for: ghost).path))
        }
    }

    @Test("provenance encodes with the stable raw strings the launch scan will key on")
    func provenanceStableRawStrings() async throws {
        try await withTempStore { store, _ in
            let meta = makeMeta()
            try await store.save(MeetingRecord(meta: meta, segments: makeSegments(), summary: nil))
            let metaURL = store.directory(for: meta.id).appending(path: "meta.json")

            try await store.recordLiveFloorProvenance(
                for: meta.id,
                provenance: makeProvenance(source: .liveFloor, modelName: "large-v3-v20240930_626MB", tier: "reuseLive")
            )
            var json = try String(decoding: Data(contentsOf: metaURL), as: UTF8.self)
            #expect(json.contains("\"source\" : \"liveFloor\""))
            #expect(json.contains("\"tier\" : \"reuseLive\""))
            #expect(json.contains("\"modelName\" : \"large-v3-v20240930_626MB\""))
            #expect(json.contains("\"servedByFallback\" : false"))

            try await store.replaceTranscript(
                makeSegments(),
                provenance: makeProvenance(source: .finalPass, tier: "fullLargeV3"),
                for: meta.id
            )
            json = try String(decoding: Data(contentsOf: metaURL), as: UTF8.self)
            #expect(json.contains("\"source\" : \"finalPass\""))
            #expect(json.contains("\"tier\" : \"fullLargeV3\""))

            // The tier raws come from FinalPassTier itself — one source of truth
            // for what the ADR-024 launch scan will read back.
            #expect(FinalPassTier.reuseLive.rawValue == "reuseLive")
            #expect(FinalPassTier.fullLargeV3.rawValue == "fullLargeV3")
        }
    }

    // MARK: - Retained-audio disposition (SP-007, ADR-024)

    /// Arms retained audio in the meeting folder (the ADR-016 marker).
    private func plantRetainedAudio(for id: UUID, in store: MeetingStore) throws {
        let url = store.directory(for: id)
            .appending(path: MeetingStore.retainedAudioFileName(for: .microphone))
        try Data("retained".utf8).write(to: url)
    }

    @Test("disposition reads audio presence + provenance source: none, pending, terminal draft, orphan")
    func retainedAudioDispositionRows() async throws {
        try await withTempStore { store, _ in
            let meta = makeMeta()
            try await store.save(MeetingRecord(meta: meta, segments: makeSegments(), summary: nil))

            // No audio → nothing retained, whatever the provenance says.
            #expect(await store.retainedAudioDisposition(for: meta.id) == .none)
            #expect(await !store.hasRetainedAudio(for: meta.id))
            #expect(await !store.isPendingFinalization(meta.id))

            // Audio + no provenance → pending (auto-resume, as ever).
            try plantRetainedAudio(for: meta.id, in: store)
            #expect(await store.retainedAudioDisposition(for: meta.id) == .pending)
            #expect(await store.hasRetainedAudio(for: meta.id))
            #expect(await store.isPendingFinalization(meta.id))

            // Audio + liveFloor → terminal draft: kept for the manual Retry,
            // no longer pending (ADR-024's one atomic meta write).
            try await store.recordLiveFloorProvenance(
                for: meta.id,
                provenance: makeProvenance(source: .liveFloor, modelName: "large-v3-v20240930_626MB", tier: "reuseLive")
            )
            #expect(await store.retainedAudioDisposition(for: meta.id) == .terminalDraft)
            #expect(await store.hasRetainedAudio(for: meta.id))
            #expect(await !store.isPendingFinalization(meta.id))

            // Audio + finalPass → the orphan of a success whose cleanup
            // crashed between the transcript replace and the audio deletion.
            try await store.replaceTranscript(makeSegments(), provenance: makeProvenance(), for: meta.id)
            #expect(await store.retainedAudioDisposition(for: meta.id) == .finalPassOrphan)
            #expect(await !store.isPendingFinalization(meta.id))
        }
    }

    @Test("keep-draft deletes exactly the kept audio — meta and transcript byte-identical")
    func keepDraftDeletesOnlyRetainedAudio() async throws {
        try await withTempStore { store, _ in
            let meta = makeMeta()
            let segments = makeSegments()
            try await store.save(MeetingRecord(meta: meta, segments: segments, summary: nil))
            // The terminal-draft state: liveFloor provenance + kept audio.
            try await store.recordLiveFloorProvenance(
                for: meta.id,
                provenance: makeProvenance(source: .liveFloor, modelName: "large-v3-v20240930_626MB", tier: "reuseLive")
            )
            try plantRetainedAudio(for: meta.id, in: store)
            let directory = store.directory(for: meta.id)
            let metaBytes = try Data(contentsOf: directory.appending(path: "meta.json"))
            let transcriptBytes = try Data(contentsOf: directory.appending(path: "transcript.json"))

            // "Keep draft" (ADR-024): the user accepts the draft as final and
            // ends retention — nothing but the audio may change.
            await store.deleteRetainedAudio(for: meta.id)

            #expect(await !store.hasRetainedAudio(for: meta.id))
            #expect(await store.retainedAudioDisposition(for: meta.id) == .none)
            #expect(try Data(contentsOf: directory.appending(path: "meta.json")) == metaBytes)
            #expect(try Data(contentsOf: directory.appending(path: "transcript.json")) == transcriptBytes)
            // The Draft badge survives: provenance still says liveFloor.
            #expect(try await store.loadRecord(meta.id).meta.transcriptProvenance?.source == .liveFloor)
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
