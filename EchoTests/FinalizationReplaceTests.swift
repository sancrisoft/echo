//
//  FinalizationReplaceTests.swift
//  EchoTests
//
//  SP-005 S1 (ADR-016): atomic transcript replacement and the retained-audio
//  pending marker, against a real-FS temp meetings root (the MeetingStoreTests
//  pattern). The invariants under test: a successful pass replaces
//  transcript.json with the complete final set and re-derives meta in the same
//  step; any failure leaves the live transcript byte-identical; pending
//  finalization is defined solely by retained-audio presence; and cleanup
//  deletes named targets, never a sweep.
//

import Foundation
import Testing
@testable import Echo

@Suite("Finalization replace & retention mechanics")
struct FinalizationReplaceTests {

    // MARK: - Helpers

    private func withTempStore<T>(_ body: (MeetingStore, URL) async throws -> T) async rethrows -> T {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "FinalizationReplaceTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        return try await body(MeetingStore(rootDirectory: root), root)
    }

    private func makeMeta(id: UUID = UUID()) -> MeetingMeta {
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
        return MeetingMeta(
            id: id,
            title: "Test Meeting",
            startedAt: startedAt,
            endedAt: startedAt.addingTimeInterval(90),
            segmentCount: 0,
            hasSummary: false,
            wordCount: 0
        )
    }

    private func liveSegments() -> [TranscriptSegment] {
        [
            TranscriptSegment(channel: .microphone, speaker: .me, text: "live one", start: 0, end: 1),
            TranscriptSegment(channel: .system, speaker: .teammates, text: "live two", start: 1, end: 2),
        ]
    }

    private func finalSegments() -> [TranscriptSegment] {
        [
            TranscriptSegment(channel: .microphone, speaker: .me, text: "final one improved", start: 0, end: 1.2),
            TranscriptSegment(channel: .system, speaker: .teammates, text: "final two improved", start: 1.1, end: 2.4),
            TranscriptSegment(channel: .microphone, speaker: .me, text: "recovered closing words", start: 2.5, end: 3.0),
        ]
    }

    /// Saves a live meeting and returns its id.
    private func saveLiveMeeting(in store: MeetingStore) async throws -> UUID {
        let meta = makeMeta()
        try await store.save(MeetingRecord(meta: meta, segments: liveSegments(), summary: nil))
        return meta.id
    }

    /// Drops synthetic retained-audio files into the meeting folder. Content
    /// is irrelevant to the marker/cleanup mechanics — presence is the state.
    private func plantRetainedAudio(for id: UUID, in store: MeetingStore, channels: [AudioChannel] = [.microphone, .system]) throws {
        let directory = store.directory(for: id)
        for channel in channels {
            let url = directory.appending(path: MeetingStore.retainedAudioFileName(for: channel))
            try Data("retained".utf8).write(to: url)
        }
    }

    // MARK: - Atomic replace (ADR-016)

    @Test("replaceTranscript swaps in exactly the final set and re-derives meta counts")
    func replaceSwapsTranscriptAndRederivesMeta() async throws {
        try await withTempStore { store, _ in
            let id = try await saveLiveMeeting(in: store)
            let final = finalSegments()

            try await store.replaceTranscript(final, for: id)

            let record = try await store.loadRecord(id)
            #expect(record.segments == final)
            #expect(record.meta.segmentCount == final.count)
            #expect(record.meta.wordCount == MeetingMeta.wordCount(of: final))
        }
    }

    @Test("replaceTranscript preserves meta fields it does not own")
    func replaceLeavesUnrelatedMetaAlone() async throws {
        try await withTempStore { store, _ in
            let id = try await saveLiveMeeting(in: store)
            let before = try await store.loadRecord(id).meta

            try await store.replaceTranscript(finalSegments(), for: id)

            let after = try await store.loadRecord(id).meta
            #expect(after.title == before.title)
            #expect(after.startedAt == before.startedAt)
            #expect(after.endedAt == before.endedAt)
            #expect(after.hasSummary == before.hasSummary)
        }
    }

    @Test("a failed replace leaves the live transcript byte-identical")
    func failedReplaceLeavesLiveTranscriptUntouched() async throws {
        try await withTempStore { store, _ in
            let id = try await saveLiveMeeting(in: store)
            let directory = store.directory(for: id)
            let transcriptURL = directory.appending(path: "transcript.json")
            let liveBytes = try Data(contentsOf: transcriptURL)

            // Injected failure: a read-only meeting folder fails the atomic
            // temp-file-plus-rename write before it can replace anything.
            try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: directory.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path) }

            await #expect(throws: (any Error).self) {
                try await store.replaceTranscript(finalSegments(), for: id)
            }

            #expect(try Data(contentsOf: transcriptURL) == liveBytes)
        }
    }

    @Test("replaceTranscript on a missing meeting throws and creates nothing")
    func replaceMissingMeetingThrows() async throws {
        try await withTempStore { store, root in
            let ghost = UUID()
            await #expect(throws: (any Error).self) {
                try await store.replaceTranscript(finalSegments(), for: ghost)
            }
            #expect(!FileManager.default.fileExists(atPath: store.directory(for: ghost).path))
        }
    }

    // MARK: - Pending marker (retained-audio presence, ADR-016)

    @Test("retained audio present reads as pending; absent reads as final")
    func pendingIsDefinedByRetainedAudioPresence() async throws {
        try await withTempStore { store, _ in
            let id = try await saveLiveMeeting(in: store)
            #expect(await !store.isPendingFinalization(id))

            try plantRetainedAudio(for: id, in: store, channels: [.microphone])
            #expect(await store.isPendingFinalization(id))

            let files = await store.retainedAudioFiles(for: id)
            #expect(files.count == 1)
            #expect(files[.microphone]?.lastPathComponent == "retained-mic.m4a")
        }
    }

    @Test("adoptRetainedAudio moves staged files into the meeting folder")
    func adoptMovesStagedFilesIn() async throws {
        try await withTempStore { store, _ in
            let id = try await saveLiveMeeting(in: store)
            let staging = FileManager.default.temporaryDirectory
                .appending(path: "FinalizationReplaceTests-staging-\(UUID().uuidString)", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: staging) }
            let stagedMic = staging.appending(path: "retained-mic.m4a")
            try Data("mic".utf8).write(to: stagedMic)

            let adopted = try await store.adoptRetainedAudio([.microphone: stagedMic], for: id)

            #expect(adopted[.microphone] == store.directory(for: id).appending(path: "retained-mic.m4a", directoryHint: .notDirectory))
            #expect(!FileManager.default.fileExists(atPath: stagedMic.path))
            #expect(await store.isPendingFinalization(id))
        }
    }

    @Test("a failed adopt undoes itself — a partial channel set never arms the pending marker")
    func failedAdoptLeavesNoPartialMarker() async throws {
        try await withTempStore { store, _ in
            let id = try await saveLiveMeeting(in: store)
            let staging = FileManager.default.temporaryDirectory
                .appending(path: "FinalizationReplaceTests-staging-\(UUID().uuidString)", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: staging) }
            let stagedMic = staging.appending(path: "retained-mic.m4a")
            try Data("mic".utf8).write(to: stagedMic)
            // The system entry points at a file that doesn't exist, so its
            // move throws after the mic file already moved in.
            let ghostSystem = staging.appending(path: "retained-system.m4a")

            await #expect(throws: (any Error).self) {
                try await store.adoptRetainedAudio([.microphone: stagedMic, .system: ghostSystem], for: id)
            }

            // A pass over one channel's audio would replace the transcript
            // with half a meeting — the marker must read "not pending".
            #expect(await !store.isPendingFinalization(id))
        }
    }

    // MARK: - Cleanup (named targets, never a sweep)

    @Test("success cleanup removes ONLY the retained files — siblings untouched")
    func cleanupIsNotASweep() async throws {
        try await withTempStore { store, _ in
            let id = try await saveLiveMeeting(in: store)
            try plantRetainedAudio(for: id, in: store)
            let directory = store.directory(for: id)
            // Sibling artifacts other features own: a summary, a RAG sidecar,
            // and an unrelated stray file must all survive the cleanup.
            let siblings = ["summary.json", "rag_index.json", "notes.txt"]
            for name in siblings {
                try Data("sibling".utf8).write(to: directory.appending(path: name))
            }

            await store.deleteRetainedAudio(for: id)

            #expect(await !store.isPendingFinalization(id))
            let remaining = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
            #expect(remaining == (siblings + ["meta.json", "transcript.json"]).sorted())
        }
    }

    @Test("cleanup with no retained files is a no-op")
    func cleanupWithoutRetentionIsNoOp() async throws {
        try await withTempStore { store, _ in
            let id = try await saveLiveMeeting(in: store)
            await store.deleteRetainedAudio(for: id)   // must not throw or remove anything
            #expect(FileManager.default.fileExists(atPath: store.directory(for: id).appending(path: "transcript.json").path))
        }
    }

    @Test("deleting the meeting removes its retained audio with the folder")
    func meetingDeletionRemovesRetention() async throws {
        try await withTempStore { store, _ in
            let id = try await saveLiveMeeting(in: store)
            try plantRetainedAudio(for: id, in: store)

            try await store.delete(id)

            #expect(!FileManager.default.fileExists(atPath: store.directory(for: id).path))
        }
    }
}
