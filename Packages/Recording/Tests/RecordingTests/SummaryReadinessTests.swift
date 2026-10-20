//
//  SummaryReadinessTests.swift
//  RecordingTests
//
//  The summary model's state reaches the surfaces through the session the way
//  the transcription model's does: the model announces it, `summaryReadiness`
//  repeats it, and nothing keeps a copy (ADR-003). The panel's Pause, Resume
//  and Retry are the session's verbs over the model's own.
//
//  Driven with a real `SummaryModel` whose transfer the test holds and lets
//  go — no network, no weights, no clock.
//

import EchoCoreTestSupport
import Foundation
import Summarization
import Synchronization
import Testing
import Transcription

@testable import Recording

@Suite("RecordingSession — the summary model's state")
@MainActor
struct SummaryReadinessTests {

    struct Unreachable: Error {}

    @Test(
        "the model's states read as the models artboard's",
        arguments: [
            (SummaryModelState.notDownloaded, SummaryReadiness.waitingToDownload),
            (.partiallyDownloaded, .incomplete),
            (.paused, .paused),
            (.downloading(0.41), .downloading(0.41)),
            (.loading, .loading),
            (.ready, .ready),
            (.failed("Not enough space"), .failed("Not enough space")),
        ])
    func statesMap(state: SummaryModelState, expected: SummaryReadiness) {
        #expect(SummaryReadiness(state) == expected)
        #expect(SummaryReadiness(state).isReady == (state == .ready))
    }

    @Test(
        "a download's percent is whole and rounded down, and there is none at rest",
        arguments: [
            (0.414, 41), (0.999, 99), (1.0, 100), (1.2, 100), (-0.1, 0),
        ] as [(Double, Int)])
    func downloadPercent(fraction: Double, percent: Int) {
        #expect(SummaryReadiness.downloading(fraction).downloadPercent == percent)
        #expect(RecordingReadiness.downloading(fraction).downloadPercent == percent)
    }

    @Test func atRestThereIsNoPercent() {
        for readiness in [SummaryReadiness.waitingToDownload, .paused, .incomplete, .loading, .ready, .failed("x")] {
            #expect(readiness.downloadPercent == nil)
        }
        for readiness in [RecordingReadiness.waitingToDownload, .ready, .downloadFailed("x")] {
            #expect(readiness.downloadPercent == nil)
        }
    }

    @Test func itFollowsTheModelOnceTheLaunchPreparesTheModels() async throws {
        try await withSession { harness in
            #expect(harness.session.summaryReadiness == .waitingToDownload)
            await harness.session.prepareModels()
            await waitUntil("the summary model to read as ready") {
                harness.session.summaryReadiness == .ready
            }
        }
    }

    @Test func aModelOnDiskReadsAsReadyWhileTheTranscriptionModelIsStillComing() async throws {
        // The transcription model's fetch can take minutes; a summary model
        // already on disk must not be drawn as waiting to download meanwhile.
        let fetch = PassGate()
        let transcription = ParakeetModel(
            modelsRoot: FileManager.default.temporaryDirectory.appending(path: "never-written-\(UUID().uuidString)"),
            modelsPresent: { false },
            downloader: { _ in
                await fetch.enter()
                throw Unreachable()
            })
        try await withSession(transcriptionModel: transcription) { harness in
            let launch = Task { await harness.session.prepareModels() }
            await waitUntil("the transcription model's fetch to begin") { fetch.entered == 1 }
            await waitUntil("the summary model to read as ready") {
                harness.session.summaryReadiness == .ready
            }
            fetch.releaseAll()
            await launch.value
        }
    }

    @Test func pauseStopsTheDownloadAndResumeCarriesItOn() async throws {
        let download = HeldDownload()
        try await withSession(summaryModel: download.model(in:)) { harness in
            let launch = Task { await harness.session.prepareModels() }
            await waitUntil("the launch to fetch the summary model") {
                harness.session.summaryReadiness == .downloading(0) && download.isHeld
            }

            harness.session.pauseSummaryModelDownload()
            await waitUntil("the pause to reach the panel") { harness.session.summaryReadiness == .paused }
            // The launch fetch ends with the pause rather than waiting on it.
            await launch.value
            #expect(await harness.summaryModel.isDownloadPaused)

            harness.session.resumeSummaryModelDownload()
            await waitUntil("the resume to fetch again") {
                harness.session.summaryReadiness == .downloading(0) && download.isHeld
            }
            #expect(await !harness.summaryModel.isDownloadPaused)
            download.release(.success(()))
            await waitUntil("the model to read as ready") { harness.session.summaryReadiness == .ready }
            #expect(download.attempts == 2)
        }
    }

    @Test func retryAfterAFailedFetchRunsItAgain() async throws {
        let download = HeldDownload()
        try await withSession(summaryModel: download.model(in:)) { harness in
            let launch = Task { await harness.session.prepareModels() }
            await waitUntil("the launch to fetch the summary model") { download.isHeld }
            download.release(.failure(Unreachable()))
            await launch.value
            await waitUntil("the failure to reach the panel") {
                if case .failed = harness.session.summaryReadiness { return true }
                return false
            }

            harness.session.resumeSummaryModelDownload()
            await waitUntil("the retry to fetch again") { download.isHeld }
            download.release(.success(()))
            await waitUntil("the model to read as ready") { harness.session.summaryReadiness == .ready }
            #expect(download.attempts == 2)
        }
    }

    @Test func bothModelsOnDiskIsAskedOfTheModels() async throws {
        try await withSession { harness in
            // Nothing followed yet, and still the answer: the disk, not the
            // readings.
            #expect(harness.session.summaryReadiness == .waitingToDownload)
            #expect(await harness.session.modelsOnDisk())
        }
        try await withSession(summaryModelOnDisk: false) { harness in
            #expect(await !harness.session.modelsOnDisk())
        }
        let missing = ParakeetModel(
            modelsRoot: FileManager.default.temporaryDirectory.appending(path: "never-written-\(UUID().uuidString)"),
            modelsPresent: { false },
            downloader: { _ in throw Unreachable() })
        try await withSession(transcriptionModel: missing) { harness in
            #expect(await !harness.session.modelsOnDisk())
        }
    }

    @Test func theModelsAreNamedByTheirOwners() {
        #expect(OnDeviceModel.transcription.name == ParakeetModel.modelDisplayName)
        #expect(OnDeviceModel.transcription.size == ParakeetModel.modelDisplaySize)
        #expect(OnDeviceModel.transcription.attribution == ParakeetModel.attribution)
        #expect(OnDeviceModel.summary.name == SummaryModel.modelDisplayName)
        #expect(OnDeviceModel.summary.size == SummaryModel.modelDisplaySize)
        #expect(OnDeviceModel.summary.attribution == nil)
    }
}

/// A summary-model transfer the test holds until it says how it ends — and
/// that ends at once with `CancellationError` when the model cancels it, as
/// a pause does. An outcome given before the transfer arrives is kept for it,
/// so the test never races the hop onto the model's task.
private final class HeldDownload: Sendable {

    private struct State {
        var attempts = 0
        var held: CheckedContinuation<Result<Void, any Error>, Never>?
        var pending: Result<Void, any Error>?
        var cancelled = false
    }

    private let state = Mutex(State())
    private let onDisk = Mutex(false)

    var attempts: Int { state.withLock { $0.attempts } }
    var isHeld: Bool { state.withLock { $0.held != nil } }

    func model(in temp: TemporaryDirectory) -> SummaryModel {
        SummaryModel(
            modelsRoot: temp.path("Models"),
            pauseStateFile: temp.path("summary-download.json"),
            loader: { _ in throw SummaryModelError.loadFailed("no engine in a unit test") },
            downloader: { [self] _ in try await self.transfer() },
            snapshotExists: { [self] in self.onDisk.withLock { $0 } },
            partialBytes: { nil }
        )
    }

    func release(_ outcome: Result<Void, any Error>) {
        let held = state.withLock { state -> CheckedContinuation<Result<Void, any Error>, Never>? in
            guard let held = state.held else {
                state.pending = outcome
                return nil
            }
            state.held = nil
            return held
        }
        held?.resume(returning: outcome)
    }

    private func transfer() async throws {
        state.withLock { state in
            state.attempts += 1
            state.cancelled = false
        }
        let outcome = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Result<Void, any Error>, Never>) in
                let ready = state.withLock { state -> Result<Void, any Error>? in
                    if state.cancelled { return .failure(CancellationError()) }
                    if let pending = state.pending {
                        state.pending = nil
                        return pending
                    }
                    state.held = continuation
                    return nil
                }
                if let ready { continuation.resume(returning: ready) }
            }
        } onCancel: {
            let held = state.withLock { state -> CheckedContinuation<Result<Void, any Error>, Never>? in
                state.cancelled = true
                defer { state.held = nil }
                return state.held
            }
            held?.resume(returning: .failure(CancellationError()))
        }
        try outcome.get()
        onDisk.withLock { $0 = true }
    }
}
