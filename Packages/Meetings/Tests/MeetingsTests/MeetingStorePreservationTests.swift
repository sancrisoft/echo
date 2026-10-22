//
//  MeetingStorePreservationTests.swift
//  MeetingsTests
//
//  Settings-page retention (§3.3): preservation renames `retained-*` →
//  `audio-*` inside the meeting folder, which by construction leaves the
//  ADR-024 disposition model untouched — a preserved meeting classifies
//  `.none`, is never auto-resumed and never swept. All against temp roots
//  with synthetic bytes (never real meeting audio).
//

import EchoCore
import EchoCoreTestSupport
import Foundation
import Meetings
import Testing

@Suite("MeetingStore — preserved recordings")
struct MeetingStorePreservationTests {

    // MARK: - Helpers (the FinalizationResumeScanTests pattern)

    private func withTempStore<T>(_ body: (MeetingStore, URL) async throws -> T) async throws -> T {
        let temp = try TemporaryDirectory(prefix: "MeetingStorePreservationTests")
        defer { temp.remove() }
        let root = temp.path("Meetings")
        return try await body(MeetingStore(rootDirectory: root), root)
    }

    private func saveMeeting(
        in store: MeetingStore,
        age: TimeInterval = 0,
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
        try await store.save(MeetingRecord(meta: meta, segments: segments, summaryMarkdown: nil))
        return meta.id
    }

    private func plantRetainedAudio(
        for id: UUID,
        in store: MeetingStore,
        channels: [AudioChannel] = [.microphone, .system],
        bytes: String = "retained"
    ) throws {
        for channel in channels {
            let url = store.directory(for: id)
                .appending(path: MeetingStore.retainedAudioFileName(for: channel))
            try Data(bytes.utf8).write(to: url)
        }
    }

    private func markFinalPass(_ id: UUID, in store: MeetingStore) async throws {
        try await store.recordTerminalProvenance(
            for: id,
            provenance: TranscriptProvenance(
                source: .finalPass,
                modelName: "parakeet-tdt-0.6b-v3",
                tier: "universal",
                servedByFallback: false
            )
        )
    }

    private func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    // MARK: - Rename

    @Test func preservingRenamesRetainedToAudioNames() async throws {
        try await withTempStore { store, _ in
            let id = try await saveMeeting(in: store)
            try plantRetainedAudio(for: id, in: store, bytes: "same bytes")

            #expect(await store.preserveRetainedAudio(for: id))

            let preserved = await store.preservedAudioFiles(for: id)
            #expect(Set(preserved.keys) == [.microphone, .system])
            for url in preserved.values {
                #expect(try Data(contentsOf: url) == Data("same bytes".utf8))
            }
            // The rename left nothing behind under the retained names.
            #expect(await store.retainedAudioFiles(for: id).isEmpty)
            #expect(await store.hasPreservedAudio(for: id))
        }
    }

    @Test func preservingNothingReturnsFalse() async throws {
        try await withTempStore { store, _ in
            let id = try await saveMeeting(in: store)
            #expect(await !store.preserveRetainedAudio(for: id))
            #expect(await !store.hasPreservedAudio(for: id))
        }
    }

    /// The overwrite case is a re-transcribe writing the same audio back:
    /// existing preserved files are replaced, never left stale.
    @Test func preservingReplacesAnExistingRecording() async throws {
        try await withTempStore { store, _ in
            let id = try await saveMeeting(in: store)
            try plantRetainedAudio(for: id, in: store, bytes: "old take")
            #expect(await store.preserveRetainedAudio(for: id))

            try plantRetainedAudio(for: id, in: store, bytes: "new take")
            #expect(await store.preserveRetainedAudio(for: id))

            let preserved = await store.preservedAudioFiles(for: id)
            #expect(preserved.count == 2)
            for url in preserved.values {
                #expect(try Data(contentsOf: url) == Data("new take".utf8))
            }
        }
    }

    // MARK: - ADR-024 invariants

    /// The crown jewel stays untouched: a preserved meeting reads as holding
    /// NO retained audio, so it classifies `.none` — never pending, never a
    /// sweep target.
    @Test func aPreservedMeetingClassifiesAsNone() async throws {
        try await withTempStore { store, _ in
            let id = try await saveMeeting(in: store)
            try plantRetainedAudio(for: id, in: store)
            try await markFinalPass(id, in: store)
            #expect(await store.preserveRetainedAudio(for: id))

            #expect(await store.retainedAudioDisposition(for: id) == .none)
            #expect(await store.pendingFinalizationMeetingIDs().isEmpty)
        }
    }

    @Test func theOrphanSweepNeverTouchesPreservedAudio() async throws {
        try await withTempStore { store, _ in
            // A finalPass meeting holding BOTH a preserved recording and
            // leftover retained clones (the re-transcribe crash shape): the
            // sweep removes exactly the retained files.
            let id = try await saveMeeting(in: store)
            try plantRetainedAudio(for: id, in: store, bytes: "preserved")
            try await markFinalPass(id, in: store)
            #expect(await store.preserveRetainedAudio(for: id))
            try plantRetainedAudio(for: id, in: store, bytes: "clone")

            await store.sweepFinalPassAudioOrphans()

            #expect(await store.retainedAudioFiles(for: id).isEmpty)
            let preserved = await store.preservedAudioFiles(for: id)
            #expect(preserved.count == 2)
            for url in preserved.values {
                #expect(try Data(contentsOf: url) == Data("preserved".utf8))
            }
        }
    }

    /// Decision §2.8: with both mechanisms armed the debug-keep rename runs
    /// first and wins — audio lands under debug-kept-*, and product
    /// preservation finds nothing.
    @Test func debugKeepFlagTakesPrecedenceOverPreservation() async throws {
        try await withTempStore { store, _ in
            let id = try await saveMeeting(in: store)
            try plantRetainedAudio(for: id, in: store)

            #expect(await store.preserveRetainedAudioAsDebugFixture(for: id))
            #expect(await !store.preserveRetainedAudio(for: id))

            #expect(await store.preservedAudioFiles(for: id).isEmpty)
            let kept = store.directory(for: id)
                .appending(path: MeetingStore.debugKeptAudioFileName(for: .microphone))
            #expect(exists(kept))
        }
    }

    // MARK: - Deletion

    @Test func deletePreservedAudioRemovesOnlyItsNamedTargets() async throws {
        try await withTempStore { store, _ in
            let id = try await saveMeeting(in: store)
            try plantRetainedAudio(for: id, in: store)
            #expect(await store.preserveRetainedAudio(for: id))
            // Siblings that must survive: the meeting's own files and a
            // leftover retained file from an unfinished cycle.
            try plantRetainedAudio(for: id, in: store, channels: [.microphone], bytes: "pending")

            await store.deletePreservedAudio(for: id)

            #expect(await store.preservedAudioFiles(for: id).isEmpty)
            let directory = store.directory(for: id)
            #expect(exists(directory.appending(path: MeetingStore.Filename.meta)))
            #expect(exists(directory.appending(path: MeetingStore.Filename.transcript)))
            #expect(await store.retainedAudioFiles(for: id).count == 1)
        }
    }

    // MARK: - Re-transcribe arming (§3.5)

    /// The clone is a copy, never a rename: the preserved archive survives.
    @Test func cloningForRetranscriptionLeavesTheOriginals() async throws {
        try await withTempStore { store, _ in
            let id = try await saveMeeting(in: store)
            try plantRetainedAudio(for: id, in: store, bytes: "the take")
            #expect(await store.preserveRetainedAudio(for: id))

            #expect(await store.cloneAudioForRetranscription(for: id))

            let preserved = await store.preservedAudioFiles(for: id)
            let retained = await store.retainedAudioFiles(for: id)
            #expect(preserved.count == 2)
            #expect(retained.count == 2)
            for url in preserved.values {
                #expect(try Data(contentsOf: url) == Data("the take".utf8))
            }
            for url in retained.values {
                #expect(try Data(contentsOf: url) == Data("the take".utf8))
            }
        }
    }

    @Test func cloningWithNoPreservedAudioReturnsFalse() async throws {
        try await withTempStore { store, _ in
            let id = try await saveMeeting(in: store)
            #expect(await !store.cloneAudioForRetranscription(for: id))
            #expect(await store.retainedAudioFiles(for: id).isEmpty)
        }
    }

    /// A leftover retained file from a previous failed cycle is replaced by
    /// the fresh clone, never mixed with it.
    @Test func cloningReplacesLeftoverRetainedFiles() async throws {
        try await withTempStore { store, _ in
            let id = try await saveMeeting(in: store)
            try plantRetainedAudio(for: id, in: store, bytes: "archive")
            #expect(await store.preserveRetainedAudio(for: id))
            try plantRetainedAudio(for: id, in: store, channels: [.microphone], bytes: "stale clone")

            #expect(await store.cloneAudioForRetranscription(for: id))

            let retained = await store.retainedAudioFiles(for: id)
            #expect(retained.count == 2)
            for url in retained.values {
                #expect(try Data(contentsOf: url) == Data("archive".utf8))
            }
        }
    }

    /// The §3.5 crash-safety story end to end: a quit between the clone and
    /// the pass concluding leaves retained-* + finalPass provenance — the
    /// launch sweep removes exactly the clones, the archive and the previous
    /// transcript stand, and nothing re-enters pending.
    @Test func aCrashedRetranscribeSelfHealsAtTheNextLaunchScan() async throws {
        try await withTempStore { store, _ in
            let id = try await saveMeeting(in: store)
            try plantRetainedAudio(for: id, in: store, bytes: "archive")
            try await markFinalPass(id, in: store)
            #expect(await store.preserveRetainedAudio(for: id))
            #expect(await store.cloneAudioForRetranscription(for: id))

            // The mid-flight shape is the orphan class — swept, not pending.
            #expect(await store.retainedAudioDisposition(for: id) == .finalPassOrphan)
            #expect(await store.pendingFinalizationMeetingIDs().isEmpty)

            await store.sweepFinalPassAudioOrphans()

            #expect(await store.retainedAudioFiles(for: id).isEmpty)
            #expect(await store.preservedAudioFiles(for: id).count == 2)
            let transcript = store.directory(for: id).appending(path: MeetingStore.Filename.transcript)
            #expect(exists(transcript))
        }
    }

    // MARK: - Summary artifacts (§3.5 step 3)

    @Test func removingSummaryArtifactsClearsFilesAndMetaBits() async throws {
        try await withTempStore { store, _ in
            let id = try await saveMeeting(in: store)
            let summary = LegacyMeetingSummary(shortSummary: "s", detailedSummary: "d")
            try await store.attachSummary(
                markdown: summary.resolvedMarkdown, caption: "caption", modelName: "model", to: id
            )
            // A stale RAG sidecar from a build that wrote one.
            let sidecar = store.directory(for: id).appending(path: "rag_index.json")
            try Data("{}".utf8).write(to: sidecar)

            try await store.removeSummaryArtifacts(for: id)

            let directory = store.directory(for: id)
            #expect(!exists(directory.appending(path: MeetingStore.Filename.summaryMarkdown)))
            #expect(!exists(directory.appending(path: MeetingStore.Filename.legacySummary)))
            #expect(!exists(sidecar))
            let meta = try #require(await store.listMetas().first { $0.id == id })
            #expect(!meta.hasSummary)
            #expect(meta.oneLineDescription == nil)
            #expect(meta.summaryModelName == nil)
            // The transcript is untouched — only derived artifacts go.
            #expect(exists(directory.appending(path: MeetingStore.Filename.transcript)))
        }
    }

    // MARK: - Totals

    /// The settings page's "n recordings — size" comes from the one storage
    /// measurement, over the non-trashed folders only.
    @Test func totalsCountNonTrashedRecordingsOnly() async throws {
        try await withTempStore { store, root in
            // Two live meetings with recordings, one live without, one
            // trashed with — the trashed one must not count.
            let withAudioA = try await saveMeeting(in: store, age: 100)
            let withAudioB = try await saveMeeting(in: store, age: 200)
            _ = try await saveMeeting(in: store, age: 300)
            let trashed = try await saveMeeting(in: store, age: 400, trashed: true)

            for id in [withAudioA, withAudioB, trashed] {
                try plantRetainedAudio(for: id, in: store, bytes: "0123456789")
                #expect(await store.preserveRetainedAudio(for: id))
            }

            let live = await store.listMetas().filter { !$0.isTrashed }.map(\.id)
            #expect(live.count == 3)
            let totals = StorageBreakdown.measure(
                meetingsRoot: root, nonTrashedIDs: live, trashedIDs: [trashed], modelsDirectory: nil
            )
            #expect(totals.recordingsCount == 2)
            // Allocated size is at least the payload (4 files × 10 bytes,
            // rounded up to allocation blocks) and clearly nonzero.
            #expect(totals.recordingsBytes > 0)

            // Deleting both clears the totals.
            await store.deletePreservedAudio(for: withAudioA)
            await store.deletePreservedAudio(for: withAudioB)
            let after = StorageBreakdown.measure(
                meetingsRoot: root, nonTrashedIDs: live, trashedIDs: [trashed], modelsDirectory: nil
            )
            #expect(after.recordingsCount == 0)
            #expect(after.recordingsBytes == 0)
            // The trashed recording rides with its folder, counted as trash.
            #expect(after.trashBytes > 0)
        }
    }
}
