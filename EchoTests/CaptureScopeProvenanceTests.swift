//
//  CaptureScopeProvenanceTests.swift
//  EchoTests
//
//  SP-008 S2 (ADR-027): the effective capture scope persisted on a meeting's
//  meta — round-trip fidelity, tolerant decoding of old metas and future
//  kinds, survival through the meta-mutating writes, the CaptureScope →
//  record mapping, and the display accessor. Same temp-root-per-test pattern
//  as MeetingStoreTests; constructed text segments (no audio), allowed for
//  store tests per the project's test policy.
//

import Foundation
import Testing
@testable import Echo

@Suite("CaptureScopeProvenance")
struct CaptureScopeProvenanceTests {

    // MARK: - Helpers

    /// Runs `body` against a store rooted at a fresh temp directory, then
    /// removes it (the MeetingStoreTests pattern).
    private func withTempStore<T>(_ body: (MeetingStore, URL) async throws -> T) async rethrows -> T {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "CaptureScopeProvenanceTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        return try await body(MeetingStore(rootDirectory: root), root)
    }

    private func makeMeta(
        id: UUID = UUID(),
        captureScope: CaptureScopeRecord? = nil
    ) -> MeetingMeta {
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
        return MeetingMeta(
            id: id,
            title: "Scoped Meeting",
            startedAt: startedAt,
            endedAt: startedAt.addingTimeInterval(90),
            segmentCount: 0,
            hasSummary: false,
            captureScope: captureScope
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

    // MARK: - Round trip

    @Test("a meta persisted with a scoped record round-trips kind and app name")
    func scopedRecordRoundTrips() async throws {
        try await withTempStore { store, _ in
            let meta = makeMeta(captureScope: CaptureScopeRecord(kind: "app", appName: "Zoom"))
            try await store.save(MeetingRecord(meta: meta, segments: makeSegments(), summary: nil))

            let loaded = try await store.loadRecord(meta.id)
            #expect(loaded.meta.captureScope == CaptureScopeRecord(kind: "app", appName: "Zoom"))
            #expect(loaded.meta.captureScope?.kind == "app")
            #expect(loaded.meta.captureScope?.appName == "Zoom")
        }
    }

    @Test("a meta persisted with an everything record round-trips with no app name")
    func everythingRecordRoundTrips() async throws {
        try await withTempStore { store, _ in
            let meta = makeMeta(captureScope: CaptureScopeRecord(kind: "everything"))
            try await store.save(MeetingRecord(meta: meta, segments: makeSegments(), summary: nil))

            let loaded = try await store.loadRecord(meta.id)
            #expect(loaded.meta.captureScope == CaptureScopeRecord(kind: "everything"))
            #expect(loaded.meta.captureScope?.appName == nil)
        }
    }

    // MARK: - Tolerant decoding (ADR-022 discipline)

    @Test("an old meta.json without the field decodes with captureScope == nil")
    func oldMetaDecodesNilScope() async throws {
        try await withTempStore { store, root in
            // A pre-SP-008 meta.json, verbatim: no captureScope key at all.
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
            #expect(metas.first?.captureScope == nil)
            #expect(metas.first?.captureScope?.scopedDisplayLabel == nil)   // absent renders as nothing
        }
    }

    @Test("an unknown future scope kind decodes without error and displays as nothing")
    func unknownFutureKindTolerated() async throws {
        try await withTempStore { store, root in
            // A meta a future build wrote with a scope kind this build has
            // never heard of: it must decode (plain string, not an enum) and
            // render as nothing — never tumble the meeting out of the list.
            let id = UUID()
            let directory = root.appending(path: id.uuidString, directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let future = """
            {
              "captureScope" : {
                "appName" : "Some Display",
                "kind" : "displaySurface"
              },
              "endedAt" : "2023-11-14T22:14:50Z",
              "hasSummary" : false,
              "id" : "\(id.uuidString)",
              "schemaVersion" : 1,
              "segmentCount" : 2,
              "startedAt" : "2023-11-14T22:13:20Z",
              "title" : "Future Meeting"
            }
            """
            try Data(future.utf8).write(to: directory.appending(path: "meta.json"))

            let metas = await store.listMetas()
            #expect(metas.count == 1)
            #expect(metas.first?.captureScope?.kind == "displaySurface")
            #expect(metas.first?.captureScope?.scopedDisplayLabel == nil)
        }
    }

    @Test("a meta saved without a scope record does not encode the key")
    func metaWithoutScopeOmitsKey() async throws {
        try await withTempStore { store, _ in
            let meta = makeMeta(captureScope: nil)
            try await store.save(MeetingRecord(meta: meta, segments: makeSegments(), summary: nil))

            let json = try String(
                decoding: Data(contentsOf: store.directory(for: meta.id).appending(path: "meta.json")),
                as: UTF8.self
            )
            #expect(!json.contains("captureScope"))
        }
    }

    // MARK: - Survival through meta-mutating writes

    @Test("replaceTranscript preserves a previously persisted scope record")
    func replaceTranscriptPreservesScope() async throws {
        try await withTempStore { store, _ in
            let record = CaptureScopeRecord(kind: "app", appName: "Zoom")
            let meta = makeMeta(captureScope: record)
            try await store.save(MeetingRecord(meta: meta, segments: makeSegments(), summary: nil))

            try await store.replaceTranscript(
                makeSegments(4),
                provenance: TranscriptProvenance(
                    source: .finalPass,
                    modelName: "large-v3_947MB",
                    tier: "fullLargeV3",
                    servedByFallback: false
                ),
                for: meta.id
            )

            #expect(try await store.loadRecord(meta.id).meta.captureScope == record)
        }
    }

    @Test("recordLiveFloorProvenance preserves a previously persisted scope record")
    func recordLiveFloorProvenancePreservesScope() async throws {
        try await withTempStore { store, _ in
            let record = CaptureScopeRecord(kind: "app", appName: "FaceTime")
            let meta = makeMeta(captureScope: record)
            try await store.save(MeetingRecord(meta: meta, segments: makeSegments(), summary: nil))

            try await store.recordLiveFloorProvenance(
                for: meta.id,
                provenance: TranscriptProvenance(
                    source: .liveFloor,
                    modelName: "large-v3-v20240930_626MB",
                    tier: "reuseLive",
                    servedByFallback: false
                )
            )

            #expect(try await store.loadRecord(meta.id).meta.captureScope == record)
        }
    }

    // MARK: - Library persist carries the record

    @Test("MeetingLibrary.persist writes the session's scope record onto the new meta")
    @MainActor
    func libraryPersistCarriesScope() async throws {
        try await withTempStore { store, _ in
            let library = MeetingLibrary(store: store)
            let record = CaptureScopeRecord(kind: "app", appName: "Zoom")

            let id = await library.persist(
                segments: makeSegments(),
                startedAt: Date(timeIntervalSince1970: 1_700_000_000),
                endedAt: Date(timeIntervalSince1970: 1_700_000_090),
                captureScope: record
            )

            let meetingID = try #require(id)
            #expect(try await store.loadRecord(meetingID).meta.captureScope == record)
        }
    }

    // MARK: - CaptureScope → record mapping

    @Test("mapping a scoped session carries the app's display name and the app kind")
    func mappingScopedSession() {
        let record = CaptureScopeRecord(scope: .app(CallApp(displayName: "Zoom", bundlePrefix: "us.zoom.xos")))
        #expect(record.kind == "app")
        #expect(record.kind == CaptureScopeRecord.appKind)
        #expect(record.appName == "Zoom")
    }

    @Test("mapping an everything session records the everything kind with no app name")
    func mappingEverythingSession() {
        let record = CaptureScopeRecord(scope: .everything)
        #expect(record.kind == "everything")
        #expect(record.kind == CaptureScopeRecord.everythingKind)
        #expect(record.appName == nil)
    }

    // MARK: - Display accessor

    @Test("display accessor: scoped reads '{app} only', everything reads as nothing")
    func displayAccessor() {
        #expect(CaptureScopeRecord(kind: "app", appName: "Zoom").scopedDisplayLabel == "Zoom only")
        #expect(CaptureScopeRecord(kind: "everything").scopedDisplayLabel == nil)
        // A malformed scoped record (no app name) also renders as nothing
        // rather than a dangling " only".
        #expect(CaptureScopeRecord(kind: "app", appName: nil).scopedDisplayLabel == nil)
    }
}
