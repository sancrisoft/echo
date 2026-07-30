//
//  FinalizationResumeScanTests.swift
//  EchoTests
//
//  SP-005 S4: the launch-time crash-resume scan (ADR-016 — pending state is a
//  directory scan over retained-audio presence) and the retention-staging
//  sweep, against a real-FS temp meetings root (the MeetingStoreTests /
//  FinalizationReplaceTests pattern). The pending-ID query under test here is
//  also the summary backfill's eligibility exclusion — one primitive, both
//  consumers.
//

import Foundation
import Testing
@testable import Echo

@Suite("Finalization resume scan & staging sweep")
struct FinalizationResumeScanTests {

    // MARK: - Helpers

    private func withTempStore<T>(_ body: (MeetingStore, URL) async throws -> T) async rethrows -> T {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "FinalizationResumeScanTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        return try await body(MeetingStore(rootDirectory: root), root)
    }

    /// Saves a meeting started `age` seconds before a fixed reference date —
    /// larger age = older meeting — and returns its id.
    private func saveMeeting(
        in store: MeetingStore,
        age: TimeInterval,
        trashed: Bool = false
    ) async throws -> UUID {
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000 - age)
        let meta = MeetingMeta(
            id: UUID(),
            title: "Meeting",
            startedAt: startedAt,
            endedAt: startedAt.addingTimeInterval(60),
            segmentCount: 1,
            hasSummary: false,
            trashedAt: trashed ? startedAt.addingTimeInterval(120) : nil
        )
        let segments = [
            TranscriptSegment(channel: .microphone, speaker: .me, text: "live", start: 0, end: 1)
        ]
        try await store.save(MeetingRecord(meta: meta, segments: segments, summary: nil))
        return meta.id
    }

    /// Arms the ADR-016 pending marker: retained audio in the meeting folder.
    private func plantRetainedAudio(for id: UUID, in store: MeetingStore) throws {
        let url = store.directory(for: id)
            .appending(path: MeetingStore.retainedAudioFileName(for: .microphone))
        try Data("retained".utf8).write(to: url)
    }

    /// Plants an orphaned staging session folder (a quit mid-recording).
    private func plantStaging(in store: MeetingStore) throws -> URL {
        let session = store.retentionStagingDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        try Data("staged".utf8).write(to: session.appending(path: "retained-mic.m4a"))
        return session
    }

    // MARK: - Pending scan (the launch-resume work queue)

    @Test("meetings with retained audio scan as pending, newest first; others are excluded")
    func scanFindsPendingMeetingsNewestFirst() async throws {
        try await withTempStore { store, _ in
            let oldest = try await saveMeeting(in: store, age: 3_000)
            let middle = try await saveMeeting(in: store, age: 2_000)
            let newest = try await saveMeeting(in: store, age: 1_000)
            try plantRetainedAudio(for: oldest, in: store)
            try plantRetainedAudio(for: newest, in: store)

            let pending = await store.pendingFinalizationMeetingIDs()

            #expect(pending == [newest, oldest])
            _ = middle   // no retained audio → final, never enqueued
        }
    }

    @Test("an empty library (or one with no pending work) scans clean")
    func scanWithNothingPendingIsEmpty() async throws {
        try await withTempStore { store, _ in
            #expect(await store.pendingFinalizationMeetingIDs() == [])

            _ = try await saveMeeting(in: store, age: 1_000)
            #expect(await store.pendingFinalizationMeetingIDs() == [])
        }
    }

    @Test("a trashed meeting with retained audio is not resumed")
    func trashedPendingMeetingIsExcluded() async throws {
        try await withTempStore { store, _ in
            let trashed = try await saveMeeting(in: store, age: 2_000, trashed: true)
            let live = try await saveMeeting(in: store, age: 1_000)
            try plantRetainedAudio(for: trashed, in: store)
            try plantRetainedAudio(for: live, in: store)

            #expect(await store.pendingFinalizationMeetingIDs() == [live])
        }
    }

    // MARK: - Staging sweep (disposable by design)

    @Test("the sweep removes the whole staging tree and nothing else")
    func sweepRemovesStagingOnly() async throws {
        try await withTempStore { store, root in
            let session = try plantStaging(in: store)
            let pending = try await saveMeeting(in: store, age: 1_000)
            try plantRetainedAudio(for: pending, in: store)

            await store.sweepRetentionStaging()

            #expect(!FileManager.default.fileExists(atPath: session.path))
            #expect(!FileManager.default.fileExists(atPath: store.retentionStagingDirectory.path))
            // Adopted retention — the pending marker — is untouched: staging
            // is the only sweep target, never the meeting folders.
            #expect(await store.isPendingFinalization(pending))
            #expect(await store.pendingFinalizationMeetingIDs() == [pending])
            _ = root
        }
    }

    @Test("sweeping with no staging directory is a no-op")
    func sweepWithoutStagingIsNoOp() async throws {
        try await withTempStore { store, _ in
            let id = try await saveMeeting(in: store, age: 1_000)

            await store.sweepRetentionStaging()   // must not throw or remove anything

            #expect(FileManager.default.fileExists(
                atPath: store.directory(for: id).appending(path: "transcript.json").path
            ))
        }
    }

    // MARK: - Backfill eligibility (the same primitive)

    @Test("the pending set excludes exactly the meetings a backfill must skip")
    func pendingSetMatchesBackfillExclusion() async throws {
        try await withTempStore { store, _ in
            let pending = try await saveMeeting(in: store, age: 2_000)
            let eligible = try await saveMeeting(in: store, age: 1_000)
            try plantRetainedAudio(for: pending, in: store)

            let excluded = Set(await store.pendingFinalizationMeetingIDs())

            // The backfill filters its summary-less candidates through this
            // set (SP-005 NFR: pending meetings are not summary-eligible).
            #expect(excluded.contains(pending))
            #expect(!excluded.contains(eligible))

            // A concluded pass (success or terminal) deletes the audio; the
            // meeting becomes eligible with no other state change (ADR-016).
            await store.deleteRetainedAudio(for: pending)
            #expect(await store.pendingFinalizationMeetingIDs() == [])
        }
    }
}
