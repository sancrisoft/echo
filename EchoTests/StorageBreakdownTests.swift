//
//  StorageBreakdownTests.swift
//  EchoTests
//
//  The Settings page's storage breakdown (§3.9): meeting data vs saved
//  recordings split by the preserved names, trash counted whole, models
//  counted whole — aggregated over a synthetic temp tree, and agreeing with
//  `preservedAudioTotals` on the recordings row.
//

import Foundation
import Testing
@testable import Echo

@Suite("Storage breakdown")
struct StorageBreakdownTests {

    private func withTempStore<T>(_ body: (MeetingStore, URL) async throws -> T) async rethrows -> T {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "StorageBreakdownTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
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
            TranscriptSegment(channel: .microphone, speaker: .me, text: "words", start: 0, end: 1)
        ]
        try await store.save(MeetingRecord(meta: meta, segments: segments, summary: nil))
        return meta.id
    }

    private func plantPreservedAudio(for id: UUID, in store: MeetingStore, bytes: Int) throws {
        for channel in [AudioChannel.microphone, .system] {
            let url = store.directory(for: id)
                .appending(path: MeetingStore.preservedAudioFileName(for: channel))
            try Data(repeating: 0xA, count: bytes).write(to: url)
        }
    }

    @Test func breakdownSplitsMeetingsRecordingsTrashAndModels() async throws {
        try await withTempStore { store, root in
            let withRecording = try await saveMeeting(in: store, age: 0)
            let plain = try await saveMeeting(in: store, age: 100)
            let trashed = try await saveMeeting(in: store, age: 200, trashed: true)
            try plantPreservedAudio(for: withRecording, in: store, bytes: 50_000)

            // A synthetic models tree with a known payload.
            let models = root.appending(path: "Models", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: models, withIntermediateDirectories: true)
            try Data(repeating: 0xB, count: 10_000).write(to: models.appending(path: "weights.bin"))

            let breakdown = MeetingLibrary.measureBreakdown(
                meetingsRoot: root,
                nonTrashedIDs: [withRecording, plain],
                trashedIDs: [trashed],
                modelsDirectory: models
            )

            // Recordings: two 50 kB files (allocated size ≥ payload).
            #expect(breakdown.recordingsCount == 1)
            #expect(breakdown.recordingsBytes >= 100_000)
            // Meetings: both live folders' meta+transcript bytes, audio
            // excluded — nonzero and far below the audio payload.
            #expect(breakdown.meetingsBytes > 0)
            #expect(breakdown.meetingsBytes < 100_000)
            // Trash: the whole trashed folder.
            #expect(breakdown.trashBytes > 0)
            // Models: at least the synthetic weights file.
            #expect(breakdown.modelsBytes >= 10_000)
        }
    }

    /// The Settings label ("Delete All Saved Recordings (n — size)…") and the
    /// breakdown's recordings row come from two paths — they must agree.
    @Test func breakdownRecordingsRowAgreesWithPreservedAudioTotals() async throws {
        try await withTempStore { store, root in
            let a = try await saveMeeting(in: store, age: 0)
            let b = try await saveMeeting(in: store, age: 100)
            _ = try await saveMeeting(in: store, age: 200)
            try plantPreservedAudio(for: a, in: store, bytes: 4_096)
            try plantPreservedAudio(for: b, in: store, bytes: 8_192)

            let ids = await store.listMetas().map(\.id)
            let breakdown = MeetingLibrary.measureBreakdown(
                meetingsRoot: root,
                nonTrashedIDs: ids,
                trashedIDs: [],
                modelsDirectory: root.appending(path: "no-models", directoryHint: .isDirectory)
            )
            let totals = await store.preservedAudioTotals()

            #expect(breakdown.recordingsCount == totals.meetings)
            #expect(breakdown.recordingsBytes == totals.bytes)
            #expect(totals.meetings == 2)
        }
    }

    @Test func deleteAllPreservedAudioClearsEveryNonTrashedRecording() async throws {
        try await withTempStore { store, _ in
            let a = try await saveMeeting(in: store, age: 0)
            let trashed = try await saveMeeting(in: store, age: 100, trashed: true)
            try plantPreservedAudio(for: a, in: store, bytes: 1_000)
            try plantPreservedAudio(for: trashed, in: store, bytes: 1_000)

            await store.deleteAllPreservedAudio()

            #expect(await store.preservedAudioFiles(for: a).isEmpty)
            // The trashed meeting's recording rides with its folder until the
            // purge — the global action never reaches into Trash.
            #expect(await store.preservedAudioFiles(for: trashed).count == 2)
            let totals = await store.preservedAudioTotals()
            #expect(totals.meetings == 0)
        }
    }
}
