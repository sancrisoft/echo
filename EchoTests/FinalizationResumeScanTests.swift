//
//  FinalizationResumeScanTests.swift
//  EchoTests
//
//  SP-005 S4: the launch-time crash-resume scan (ADR-016 — pending state is a
//  directory scan over retained audio) and the retention-staging sweep,
//  against a real-FS temp meetings root (the MeetingStoreTests /
//  FinalizationReplaceTests pattern). SP-007 (ADR-024) makes the scan
//  three-way: terminal convergence now KEEPS the audio, so presence alone no
//  longer means pending — the recorded transcript provenance disambiguates
//  (none → pending; liveFloor → terminal draft, never auto-resumed;
//  finalPass → orphan of a crashed success cleanup, swept). The pending-ID
//  query under test here is also the summary backfill's eligibility
//  exclusion — one primitive, both consumers.
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

    /// Marks the meeting a terminal draft: liveFloor provenance recorded by
    /// the same store call the converge path uses (ADR-024's atomic write).
    private func markTerminalDraft(_ id: UUID, in store: MeetingStore) async throws {
        try await store.recordLiveFloorProvenance(
            for: id,
            provenance: TranscriptProvenance(
                source: .liveFloor,
                modelName: "large-v3-v20240930_626MB",
                tier: "reuseLive",
                servedByFallback: false
            )
        )
    }

    /// Makes the meeting a finalPass orphan: a successful replace (which
    /// records finalPass provenance) whose audio deletion then "crashed" —
    /// the caller plants/keeps retained audio around this.
    private func markFinalized(_ id: UUID, in store: MeetingStore) async throws {
        try await store.replaceTranscript(
            [TranscriptSegment(channel: .microphone, speaker: .me, text: "final", start: 0, end: 1)],
            provenance: TranscriptProvenance(
                source: .finalPass,
                modelName: "large-v3_947MB",
                tier: "fullLargeV3",
                servedByFallback: false
            ),
            for: id
        )
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

    // MARK: - Three-way classification (ADR-024)

    @Test("with retained audio, provenance disambiguates: none resumes, liveFloor is a draft, finalPass is an orphan")
    func scanClassifiesRetainedAudioByProvenance() async throws {
        try await withTempStore { store, _ in
            let pending = try await saveMeeting(in: store, age: 3_000)
            let draft = try await saveMeeting(in: store, age: 2_000)
            let orphan = try await saveMeeting(in: store, age: 1_000)
            for id in [pending, draft, orphan] {
                try plantRetainedAudio(for: id, in: store)
            }
            try await markTerminalDraft(draft, in: store)
            try await markFinalized(orphan, in: store)

            // Only the true pending meeting auto-resumes: the draft waits
            // for the user's Retry; the orphan's transcript is already final.
            #expect(await store.pendingFinalizationMeetingIDs() == [pending])
            #expect(await store.retainedAudioDisposition(for: pending) == .pending)
            #expect(await store.retainedAudioDisposition(for: draft) == .terminalDraft)
            #expect(await store.retainedAudioDisposition(for: orphan) == .finalPassOrphan)
        }
    }

    @Test("the orphan sweep deletes exactly the finalPass orphan's audio — drafts and pending untouched")
    func orphanSweepDeletesOnlyOrphanAudio() async throws {
        try await withTempStore { store, _ in
            let pending = try await saveMeeting(in: store, age: 4_000)
            let draft = try await saveMeeting(in: store, age: 3_000)
            let orphan = try await saveMeeting(in: store, age: 2_000)
            let trashedOrphan = try await saveMeeting(in: store, age: 1_000, trashed: true)
            for id in [pending, draft, orphan, trashedOrphan] {
                try plantRetainedAudio(for: id, in: store)
            }
            try await markTerminalDraft(draft, in: store)
            try await markFinalized(orphan, in: store)
            try await markFinalized(trashedOrphan, in: store)
            let orphanTranscript = try Data(contentsOf: store.directory(for: orphan).appending(path: "transcript.json"))

            await store.sweepFinalPassAudioOrphans()

            // The orphan's audio is gone; its final transcript is untouched.
            #expect(await !store.hasRetainedAudio(for: orphan))
            #expect(try Data(contentsOf: store.directory(for: orphan).appending(path: "transcript.json")) == orphanTranscript)
            // The draft's kept audio (the Retry's fuel) and the pending
            // meeting's checkpoint both survive the sweep.
            #expect(await store.hasRetainedAudio(for: draft))
            #expect(await store.hasRetainedAudio(for: pending))
            // Trashed meetings stay outside the scan (existing rule): their
            // files go with the folder, or a restore re-surfaces them.
            #expect(await store.hasRetainedAudio(for: trashedOrphan))
        }
    }

    @Test("a terminal draft is never enqueued — across relaunches, only the user re-opens it")
    func terminalDraftIsNeverAutoResumed() async throws {
        try await withTempStore { store, _ in
            let draft = try await saveMeeting(in: store, age: 1_000)
            try plantRetainedAudio(for: draft, in: store)
            try await markTerminalDraft(draft, in: store)

            // However often the scan runs (every launch), the draft rests.
            #expect(await store.pendingFinalizationMeetingIDs() == [])
            await store.sweepFinalPassAudioOrphans()
            #expect(await store.pendingFinalizationMeetingIDs() == [])
            // Its audio — the Retry affordance's exact lifetime — remains.
            #expect(await store.hasRetainedAudio(for: draft))
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

            // Terminal convergence records liveFloor provenance with the
            // audio KEPT (ADR-024): the draft is no longer pending, so its
            // floor summary may generate — the same rule, new bit.
            try await markTerminalDraft(pending, in: store)
            #expect(await store.pendingFinalizationMeetingIDs() == [])
            #expect(await store.hasRetainedAudio(for: pending))
        }
    }

    @Test("a successful pass still ends pending the old way: the audio deletion")
    func successCleanupEndsPending() async throws {
        try await withTempStore { store, _ in
            let pending = try await saveMeeting(in: store, age: 1_000)
            try plantRetainedAudio(for: pending, in: store)
            #expect(await store.pendingFinalizationMeetingIDs() == [pending])

            // Success: replace (recording finalPass provenance) + delete —
            // and a crash between the two is exactly the orphan class above.
            try await markFinalized(pending, in: store)
            await store.deleteRetainedAudio(for: pending)
            #expect(await store.pendingFinalizationMeetingIDs() == [])
            #expect(await store.retainedAudioDisposition(for: pending) == .none)
        }
    }
}
