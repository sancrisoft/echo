//
//  RecordingReadinessTests.swift
//  RecordingTests
//
//  A recording waits for the transcription model — the product owner's
//  decision of 2026-10-02, reversing v1's "recording never waits for a model"
//  (discovery §7). The one door is `start`, which refuses with the reason; the
//  surfaces read `readiness`, which repeats what the model announces. The
//  summary model never gates.
//

import Audio
import Foundation
import Synchronization
import Testing
import Transcription

@testable import Recording

@Suite("RecordingSession — waiting for the transcription model")
@MainActor
struct RecordingReadinessTests {

    struct Unreachable: Error {}

    /// Whether the fake model's files are on disk.
    final class Disk: Sendable {
        let holdsModel = Mutex(false)
    }

    /// A model with nothing on disk, whose fetch the test controls.
    private func absentModel(fetch: @escaping @Sendable () throws -> Void = {}) -> ParakeetModel {
        let disk = Disk()
        return ParakeetModel(
            modelsRoot: FileManager.default.temporaryDirectory.appending(path: "never-written-\(UUID().uuidString)"),
            modelsPresent: { disk.holdsModel.withLock { $0 } },
            downloader: { _ in
                try fetch()
                disk.holdsModel.withLock { $0 = true }
            })
    }

    @Test func withTheModelMissingStartRecordsNothingAndSaysWhy() async throws {
        let model = absentModel()
        try await withSession(transcriptionModel: model) { harness in
            let refusal = await harness.session.start()
            #expect(refusal == .transcriptionModelNotReady(.waitingToDownload))
            #expect(harness.session.phase == .idle)
            // Nothing was built, armed or asked: not even the permission
            // dialogs, which a recording that cannot start has no business
            // raising.
            #expect(harness.rig.microphones.isEmpty)
            #expect(harness.rig.systemCaptures.isEmpty)
            #expect(harness.rig.permissionPrimeCount == 0)
            #expect(harness.meetingFolders().isEmpty)
        }
    }

    @Test func withTheModelOnDiskStartRecordsAndRefusesNothing() async throws {
        try await withSession { harness in
            let refusal = await harness.session.start()
            #expect(refusal == nil)
            #expect(harness.session.phase.isRecording)
            await harness.session.stop()
        }
    }

    @Test func theGateIsTheDiskNotTheReading() async throws {
        // `readiness` reads as waiting until the launch has started following
        // the model; the door asks the model itself, so a reading that lags
        // never holds a start back.
        try await withSession { harness in
            #expect(harness.session.readiness == .waitingToDownload)
            #expect(await harness.session.start() == nil)
            await harness.session.stop()
        }
    }

    @Test func readinessFollowsTheModelOnceTheLaunchFetchesIt() async throws {
        let model = absentModel()
        try await withSession(transcriptionModel: model) { harness in
            await harness.session.prepareModels()
            await waitUntil("the model to read as ready") { harness.session.readiness == .ready }
            #expect(await harness.session.start() == nil)
            await harness.session.stop()
        }
    }

    @Test func aFailedFetchIsTheReasonAndRetryRunsItAgain() async throws {
        let attempts = Mutex(0)
        let model = absentModel(fetch: {
            let attempt = attempts.withLock { count -> Int in
                count += 1
                return count
            }
            if attempt == 1 { throw Unreachable() }
        })
        try await withSession(transcriptionModel: model) { harness in
            await harness.session.prepareModels()
            await waitUntil("the failure to reach readiness") {
                if case .downloadFailed = harness.session.readiness { return true }
                return false
            }
            guard case .transcriptionModelNotReady(.downloadFailed) = await harness.session.start() else {
                Issue.record("a failed fetch did not refuse with its reason")
                return
            }

            harness.session.retryTranscriptionModel()
            await waitUntil("the retry to make the model ready") { harness.session.readiness == .ready }
            #expect(attempts.withLock { $0 } == 2)
        }
    }

    @Test(
        "the model's states read as the artboard's",
        arguments: [
            (ParakeetModelState.absent, RecordingReadiness.waitingToDownload),
            (.downloading(0.41), .downloading(0.41)),
            (.failed("no network"), .downloadFailed("no network")),
            (.ready, .ready),
        ])
    func statesMap(state: ParakeetModelState, expected: RecordingReadiness) {
        #expect(RecordingReadiness(state) == expected)
        #expect(RecordingReadiness(state).isReady == (state == .ready))
    }
}
