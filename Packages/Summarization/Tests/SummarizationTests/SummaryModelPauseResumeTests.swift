//
//  SummaryModelPauseResumeTests.swift
//  SummarizationTests
//
//  User-controllable pause and resume of the multi-GB background download,
//  asserted through the actor's public API with counting fakes and an
//  in-memory pause store — no real MLX, network, disk or clock.
//
//  What is observed: `isDownloadPaused` (the persisted intent), the
//  downloader's call count (whether a transfer started), the snapshot flag
//  (whether one completed) and `state` (which of a pause and a failure the UI
//  is told about). The discipline under test: a pause records the intent and
//  cancels the in-flight transfer WITHOUT it reading as a failure; the eager
//  background download respects the persisted intent, on this launch and
//  across a restart; resume clears the intent and re-runs the single shared
//  transfer, skipping whatever is already complete on disk.
//
//  Only the lifecycle half of the PoC's suite lives here. The transport's own
//  guarantees — resumable byte ranges, the manifest, the tally, etag/sha256
//  verification — belong to `ModelDelivery` and are covered by its suites; a
//  second copy here would only pin them twice.
//
//  The fakes are shared with `SummaryModelLifecycleTests` (same module, one
//  definition): `FakeTextEngine`, `SnapshotFlag`, `CountingEngineLoader` and
//  `InMemoryPauseStore` are declared there.
//

import EchoCore
import EchoCoreTestSupport
import Foundation
import ModelDelivery
import Synchronization
import Testing

@testable import Summarization

// MARK: - Fakes

/// A transfer that parks until it is cancelled and then throws
/// `CancellationError` — a long, interruptible fetch.
///
/// The park is a continuation resumed by the cancellation handler itself, not
/// a `Task.sleep`: nothing here waits for a duration, so a pause is observed
/// by construction rather than by hoping a clock cooperates. The snapshot flag
/// flips only past the park, so a paused transfer provably never completes.
private final class PausableDownloader: Sendable {

    private struct State {
        var count = 0
        var isInFlight = false
        var isCancelled = false
        var gate: CheckedContinuation<Void, Never>?
        var inFlightWaiters: [CheckedContinuation<Void, Never>] = []
    }

    private let state = Mutex(State())
    private let snapshot: SnapshotFlag?

    init(snapshot: SnapshotFlag? = nil) {
        self.snapshot = snapshot
    }

    var download: SummaryModelDownloader {
        { [self] progress in
            let waiters = state.withLock { state -> [CheckedContinuation<Void, Never>] in
                state.count += 1
                state.isInFlight = true
                let pending = state.inFlightWaiters
                state.inFlightWaiters = []
                return pending
            }
            for waiter in waiters { waiter.resume() }

            progress(.downloading, 0)
            await withTaskCancellationHandler {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    let alreadyCancelled: Bool = state.withLock { state in
                        guard !state.isCancelled else { return true }
                        state.gate = continuation
                        return false
                    }
                    if alreadyCancelled { continuation.resume() }
                }
            } onCancel: {
                let gate = state.withLock { state -> CheckedContinuation<Void, Never>? in
                    state.isCancelled = true
                    let gate = state.gate
                    state.gate = nil
                    return gate
                }
                gate?.resume()
            }
            try Task.checkCancellation()

            // Only a clean completion gets this far, which a paused transfer
            // never does: its shards stay partial on disk.
            snapshot?.setExists(true)
            progress(.downloading, 1)
        }
    }

    /// Resumes once a transfer has entered the downloader.
    func waitUntilInFlight() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let alreadyInFlight: Bool = state.withLock { state in
                guard !state.isInFlight else { return true }
                state.inFlightWaiters.append(continuation)
                return false
            }
            if alreadyInFlight { continuation.resume() }
        }
    }

    var downloadCount: Int { state.withLock { $0.count } }
}

/// A transfer that completes at once and flips its snapshot flag true — a
/// download that finishes, or resumes to completion.
private final class ImmediateDownloader: Sendable {

    private let count = Mutex(0)
    private let snapshot: SnapshotFlag?

    init(snapshot: SnapshotFlag? = nil) {
        self.snapshot = snapshot
    }

    var download: SummaryModelDownloader {
        { [self] progress in
            count.withLock { $0 += 1 }
            progress(.downloading, 0)
            snapshot?.setExists(true)
            progress(.downloading, 1)
        }
    }

    var downloadCount: Int { count.withLock { $0 } }
}

/// A real transport failure — a dropped connection, a server error — and NOT a
/// cancellation. `LocalizedError` so the message the model puts in `.failed`
/// is a value a test can name exactly.
private struct DownloadBlewUp: LocalizedError {
    var errorDescription: String? { "The connection dropped." }
}

/// A transfer that fails for a real reason, to prove a genuine failure stays
/// distinguishable from a pause.
private final class FailingDownloader: Sendable {

    var download: SummaryModelDownloader {
        { progress in
            progress(.downloading, 0)
            throw DownloadBlewUp()
        }
    }
}

/// A no-op idle-release scheduler: the release lifecycle is not what these
/// tests are about (it is `SummaryModelLifecycleTests`').
private struct NoopIdleReleaseScheduler: IdleReleaseScheduling {
    func arm(after timeout: Duration, _ fire: @escaping @Sendable () async -> Void) {}
    func cancel() {}
}

// MARK: - The suite

@Suite("Summary download pause and resume")
struct SummaryModelPauseResumeTests {

    private let fakeLoader: SummaryEngineLoader = { _ in FakeTextEngine() }

    /// `modelsRoot` and `pauseStateFile` are required by design, so every test
    /// gets its own scratch folder and the real data folder is unreachable.
    /// The pause store is in-memory, so the intent is the test's to seed and
    /// to read; the partial probe answers nil, which keeps the suite off the
    /// file system entirely.
    private func makeModel(
        in temporary: TemporaryDirectory,
        downloader: @escaping SummaryModelDownloader,
        snapshot: SnapshotFlag,
        pauseStore: InMemoryPauseStore
    ) -> SummaryModel {
        SummaryModel(
            modelsRoot: temporary.path("Models"),
            pauseStateFile: temporary.path("summary-model-download-state.json"),
            loader: fakeLoader,
            downloader: downloader,
            snapshotExists: { snapshot.exists },
            partialBytes: { nil },
            scheduler: NoopIdleReleaseScheduler(),
            pauseStore: pauseStore
        )
    }

    // MARK: - Behavior 1: a pause records the intent, then cancels the transfer

    /// The ordering IS the behavior: the intent is written down before the
    /// cancel, so by the time a joined awaiter sees the `CancellationError`,
    /// `isDownloadPaused` already answers truthfully — and the state the UI
    /// reads is `.paused`, never `.failed`.
    @Test("pausing an in-flight download records the intent and cancels the transfer, not as a failure")
    func pauseRecordsIntentAndCancelsInFlight() async throws {
        let temporary = try TemporaryDirectory(prefix: "SummaryModelPauseResumeTests")
        defer { temporary.remove() }
        let snapshot = SnapshotFlag(onDisk: false)
        let downloader = PausableDownloader(snapshot: snapshot)
        let store = InMemoryPauseStore()
        let model = makeModel(
            in: temporary, downloader: downloader.download, snapshot: snapshot, pauseStore: store)

        #expect(await model.isDownloadPaused == false)

        async let download: Void = model.ensureDownloaded()
        await downloader.waitUntilInFlight()

        await model.pauseDownload()
        #expect(await model.isDownloadPaused == true)

        var didCancel = false
        do {
            try await download
        } catch is CancellationError {
            didCancel = true
        } catch {
            // Any non-cancellation error would mean the pause read as a failure.
            Issue.record("a pause must arrive as a cancellation, not \(error)")
        }
        #expect(didCancel)  // the transfer was cancelled…
        #expect(snapshot.exists == false)  // …and never completed (shards stay partial)
        #expect(store.isPaused == true)  // the intent went through the store

        // The state consequence, which v1's manager did not own: a paused
        // download reports `.paused`, so the UI offers Resume rather than a
        // failure notice or a from-scratch Download.
        #expect(await model.state == .paused)
    }

    // MARK: - Behavior 2: the persisted intent suppresses the background download

    @Test("while paused, ensureDownloaded starts no transfer at all")
    func pausedEnsureDownloadedIsNoOp() async throws {
        let temporary = try TemporaryDirectory(prefix: "SummaryModelPauseResumeTests")
        defer { temporary.remove() }
        let snapshot = SnapshotFlag(onDisk: false)
        let downloader = ImmediateDownloader(snapshot: snapshot)
        let store = InMemoryPauseStore()
        let model = makeModel(
            in: temporary, downloader: downloader.download, snapshot: snapshot, pauseStore: store)

        await model.pauseDownload()  // the user paused with no transfer running
        #expect(await model.isDownloadPaused == true)
        #expect(await model.state == .paused)

        try await model.ensureDownloaded()

        #expect(downloader.downloadCount == 0)  // the eager fetch stayed its hand
        #expect(snapshot.exists == false)
        #expect(await model.state == .paused)  // and said so, rather than reporting a failure
    }

    // MARK: - Behavior 3: resume clears the intent and re-runs one transfer

    @Test("resume clears the intent and the next ensureDownloaded runs exactly one completing transfer")
    func resumeClearsIntentAndDownloadsOnce() async throws {
        let temporary = try TemporaryDirectory(prefix: "SummaryModelPauseResumeTests")
        defer { temporary.remove() }
        let snapshot = SnapshotFlag(onDisk: false)
        let downloader = ImmediateDownloader(snapshot: snapshot)
        let store = InMemoryPauseStore(paused: true)  // start paused
        let model = makeModel(
            in: temporary, downloader: downloader.download, snapshot: snapshot, pauseStore: store)

        // Paused: the background fetch is a no-op.
        try await model.ensureDownloaded()
        #expect(downloader.downloadCount == 0)

        // Resume clears the intent, and the at-rest state stops saying paused.
        await model.resumeDownload()
        #expect(await model.isDownloadPaused == false)
        #expect(await model.state == .notDownloaded)

        // …and the next fetch runs exactly one transfer that completes. The
        // snapshot flag standing in for "complete on disk" models a real resume
        // skipping the shards already downloaded — nothing complete is
        // re-fetched.
        try await model.ensureDownloaded()
        #expect(downloader.downloadCount == 1)
        #expect(snapshot.exists == true)
        #expect(await model.state == .ready)

        // A follow-up call now no-ops on the on-disk snapshot — still one
        // transfer.
        try await model.ensureDownloaded()
        #expect(downloader.downloadCount == 1)
    }

    // MARK: - Behavior 4: the paused intent survives a restart

    /// The whole reason the intent is a file rather than a field: a brand-new
    /// model over a store that already reports paused (as the file a previous
    /// run wrote does) must not auto-resume. This is the launch path after a
    /// "quit while paused".
    @Test("a pause persisted before a restart is respected by a brand-new model")
    func persistedPauseSurvivesRestart() async throws {
        let temporary = try TemporaryDirectory(prefix: "SummaryModelPauseResumeTests")
        defer { temporary.remove() }
        let snapshot = SnapshotFlag(onDisk: false)
        let downloader = ImmediateDownloader(snapshot: snapshot)
        let store = InMemoryPauseStore(paused: true)
        let model = makeModel(
            in: temporary, downloader: downloader.download, snapshot: snapshot, pauseStore: store)

        #expect(await model.isDownloadPaused == true)
        try await model.ensureDownloaded()  // the eager launch download

        #expect(downloader.downloadCount == 0)  // no auto-resume across the restart
        #expect(snapshot.exists == false)

        // And the launch-time read of disk agrees: a pause outranks the partial
        // files it left behind, so the UI offers Resume.
        await model.refreshState()
        #expect(await model.state == .paused)
    }

    // MARK: - Behavior 5: a real failure is not a pause

    @Test("a real download failure while not paused stays a failure, and is never reported as a pause")
    func realFailureIsNotMistakenForPause() async throws {
        let temporary = try TemporaryDirectory(prefix: "SummaryModelPauseResumeTests")
        defer { temporary.remove() }
        let snapshot = SnapshotFlag(onDisk: false)
        let store = InMemoryPauseStore()
        let model = makeModel(
            in: temporary, downloader: FailingDownloader().download, snapshot: snapshot,
            pauseStore: store)

        var caught: Error?
        do { try await model.ensureDownloaded() } catch { caught = error }

        #expect(caught != nil)  // the transfer threw…
        #expect(caught is DownloadBlewUp)  // …the real error, unwrapped, to its caller
        #expect(await model.isDownloadPaused == false)  // …and not because of a pause

        // The state keys off the recorded intent, not off the error, which is
        // why a genuine failure can never be swallowed as a pause.
        let expected = SummaryModelError.downloadFailed(DownloadBlewUp().localizedDescription)
        #expect(await model.state == .failed(expected.localizedDescription))
        #expect(await model.state != .paused)
    }
}
