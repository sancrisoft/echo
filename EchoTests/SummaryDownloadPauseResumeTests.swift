//
//  SummaryDownloadPauseResumeTests.swift
//  EchoTests
//
//  User-controllable pause/resume of the large multi-GB background summary-model
//  download (SP-003 US-10), asserted through the manager's public API with
//  counting fakes and an in-memory pause store — no real MLX, network, disk, or
//  clock (SP-003 Testing Decisions, layer 3).
//
//  What's observed: `isDownloadPaused` (the persisted intent), the downloader's
//  call count (whether a transfer started), and the snapshot flag (whether a
//  transfer completed). The discipline under test: a pause records the intent
//  and cancels the in-flight transfer WITHOUT it reading as a failure; the eager
//  background download respects the persisted intent (this run and across a
//  restart); resume clears the intent and re-runs the single shared transfer,
//  skipping whatever is already complete on disk.
//

import Foundation
import Testing
@testable import Echo

@Suite("Summary download pause / resume (SP-003 US-10)")
struct SummaryDownloadPauseResumeTests {

    // MARK: - Fakes

    /// A no-op engine — these tests never load or run a generation; a loader is
    /// required only so the manager can be constructed.
    private struct FakeEngine: TextGenerating {
        func stream(system: String, user: String, params: GenerationParams)
            -> AsyncThrowingStream<String, Error>
        {
            AsyncThrowingStream { $0.finish() }
        }
    }

    /// A mutable "is the snapshot on disk" flag, flipped true by a downloader
    /// that runs to completion — exactly as a real finished download would.
    private final class SnapshotFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Bool
        init(onDisk: Bool) { value = onDisk }
        var exists: Bool { lock.lock(); defer { lock.unlock() }; return value }
        func setExists(_ newValue: Bool) { lock.lock(); value = newValue; lock.unlock() }
    }

    /// A transfer that blocks (cancellation-aware) until it is cancelled by a
    /// pause. The `Task.sleep` throws `CancellationError` the instant the
    /// download task is cancelled and never elapses on its own in a passing test
    /// (a pause always arrives first), so it stands in for a long, interruptible
    /// fetch. Flips the snapshot flag only on clean completion (not exercised
    /// here — the point is that a paused transfer never completes).
    private final class PausableDownloader: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        private let snapshot: SnapshotFlag?
        private var inFlightSignal: CheckedContinuation<Void, Never>?
        private var isInFlight = false

        init(snapshot: SnapshotFlag? = nil) { self.snapshot = snapshot }

        var download: SnapshotDownloader {
            { [self] progress in
                lock.lock()
                count += 1
                isInFlight = true
                let signal = inFlightSignal
                inFlightSignal = nil
                lock.unlock()
                signal?.resume()

                progress("Downloading summary model…", 0)
                try await Task.sleep(for: .seconds(600))
                snapshot?.setExists(true)
                progress("Downloading summary model…", 1)
            }
        }

        /// Resumes once a transfer has entered the downloader.
        func waitUntilInFlight() async {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                lock.lock()
                if isInFlight { lock.unlock(); continuation.resume(); return }
                inFlightSignal = continuation
                lock.unlock()
            }
        }

        var downloadCount: Int { lock.lock(); defer { lock.unlock() }; return count }
    }

    /// A transfer that completes at once and flips its snapshot flag true —
    /// stands in for a download that finishes (or resumes to completion).
    private final class ImmediateDownloader: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        private let snapshot: SnapshotFlag?

        init(snapshot: SnapshotFlag? = nil) { self.snapshot = snapshot }

        var download: SnapshotDownloader {
            { [self] progress in
                lock.lock(); count += 1; lock.unlock()
                progress("Downloading summary model…", 0)
                snapshot?.setExists(true)
                progress("Downloading summary model…", 1)
            }
        }

        var downloadCount: Int { lock.lock(); defer { lock.unlock() }; return count }
    }

    private struct DownloadBlewUp: Error {}

    /// A transfer that fails for a real reason (dropped connection, server
    /// error) — NOT a cancellation. Used to prove a genuine failure is
    /// distinguishable from a pause.
    private final class FailingDownloader: @unchecked Sendable {
        var download: SnapshotDownloader {
            { progress in
                progress("Downloading summary model…", 0)
                throw DownloadBlewUp()
            }
        }
    }

    /// A no-op idle-release scheduler: the release lifecycle is not exercised by
    /// the pause/resume tests.
    private final class NoopScheduler: IdleReleaseScheduling, @unchecked Sendable {
        func arm(after timeout: Duration, _ fire: @escaping @Sendable () async -> Void) {}
        func cancel() {}
    }

    private let noProgress: @Sendable (String, Double) -> Void = { _, _ in }
    private let fakeLoader: EngineLoader = { _ in FakeEngine() }

    private func makeManager(
        downloader: @escaping SnapshotDownloader,
        snapshot: SnapshotFlag,
        pauseStore: InMemoryPauseStore
    ) -> SummaryModelManager {
        SummaryModelManager(
            loader: fakeLoader,
            downloader: downloader,
            snapshotExists: { snapshot.exists },
            scheduler: NoopScheduler(),
            pauseStore: pauseStore
        )
    }

    // MARK: - Behavior 1 (tracer): pause records the intent and cancels the transfer

    @Test("pausing an in-flight download records the intent and cancels the transfer, not as a failure")
    func pauseRecordsIntentAndCancelsInFlight() async throws {
        let snapshot = SnapshotFlag(onDisk: false)
        let downloader = PausableDownloader(snapshot: snapshot)
        let store = InMemoryPauseStore()
        let manager = makeManager(downloader: downloader.download, snapshot: snapshot, pauseStore: store)

        #expect(await manager.isDownloadPaused == false)

        async let download: Void = manager.ensureDownloaded(progress: noProgress)
        await downloader.waitUntilInFlight()

        // The intent is recorded BEFORE the cancel, so it is already true by the
        // time the cancellation propagates to the joined awaiter.
        await manager.pauseDownload()
        #expect(await manager.isDownloadPaused == true)

        var didCancel = false
        do {
            try await download
        } catch is CancellationError {
            didCancel = true
        } catch {
            // Any non-cancellation error would mean the pause read as a failure.
        }
        #expect(didCancel)                 // the transfer was cancelled…
        #expect(snapshot.exists == false)  // …and never completed (shards stay partial)
        #expect(store.isPaused == true)    // the intent is persisted through the store
    }

    // MARK: - Behavior 2: the persisted intent suppresses the background download

    @Test("while paused, ensureDownloaded starts no transfer (the persisted intent is respected)")
    func pausedEnsureDownloadedIsNoOp() async throws {
        let snapshot = SnapshotFlag(onDisk: false)
        let downloader = ImmediateDownloader(snapshot: snapshot)
        let store = InMemoryPauseStore()
        let manager = makeManager(downloader: downloader.download, snapshot: snapshot, pauseStore: store)

        await manager.pauseDownload()   // user paused (no transfer running)
        #expect(await manager.isDownloadPaused == true)

        try await manager.ensureDownloaded(progress: noProgress)

        #expect(downloader.downloadCount == 0)   // the eager/background fetch stayed its hand
        #expect(snapshot.exists == false)
    }

    // MARK: - Behavior 3: resume clears the intent and re-runs one transfer

    @Test("resume clears the intent and a subsequent ensureDownloaded runs exactly one completing transfer")
    func resumeClearsIntentAndDownloadsOnce() async throws {
        let snapshot = SnapshotFlag(onDisk: false)
        let downloader = ImmediateDownloader(snapshot: snapshot)
        let store = InMemoryPauseStore(paused: true)   // start paused
        let manager = makeManager(downloader: downloader.download, snapshot: snapshot, pauseStore: store)

        // Paused: the background fetch is a no-op.
        try await manager.ensureDownloaded(progress: noProgress)
        #expect(downloader.downloadCount == 0)

        // Resume clears the intent…
        await manager.resumeDownload()
        #expect(await manager.isDownloadPaused == false)

        // …and the next fetch runs exactly one transfer that completes. The
        // snapshot flag standing in for "complete on disk" models a real resume
        // skipping the shards already downloaded — nothing complete is re-fetched.
        try await manager.ensureDownloaded(progress: noProgress)
        #expect(downloader.downloadCount == 1)
        #expect(snapshot.exists == true)

        // A follow-up call now no-ops on the on-disk snapshot — still one transfer.
        try await manager.ensureDownloaded(progress: noProgress)
        #expect(downloader.downloadCount == 1)
    }

    // MARK: - Behavior 4: the paused intent survives a restart

    @Test("a pause persisted before a restart is respected by a fresh manager's eager download")
    func persistedPauseSurvivesRestart() async throws {
        // The store reports paused (as a file written in a previous run would),
        // and a brand-new manager is built over it — exactly the launch path
        // after a "quit while paused".
        let snapshot = SnapshotFlag(onDisk: false)
        let downloader = ImmediateDownloader(snapshot: snapshot)
        let store = InMemoryPauseStore(paused: true)
        let manager = makeManager(downloader: downloader.download, snapshot: snapshot, pauseStore: store)

        #expect(await manager.isDownloadPaused == true)
        try await manager.ensureDownloaded(progress: noProgress)   // the eager launch download

        #expect(downloader.downloadCount == 0)   // no auto-resume across the restart
        #expect(snapshot.exists == false)
    }

    // MARK: - Behavior 5: a real failure is not mistaken for a pause (cancel ≠ failure)

    @Test("a real download failure while not paused stays a failure — distinguishable from a pause")
    func realFailureIsNotMistakenForPause() async throws {
        let snapshot = SnapshotFlag(onDisk: false)
        let downloader = FailingDownloader()
        let store = InMemoryPauseStore()
        let manager = makeManager(downloader: downloader.download, snapshot: snapshot, pauseStore: store)

        var caught: Error?
        do { try await manager.ensureDownloaded(progress: noProgress) } catch { caught = error }

        #expect(caught != nil)                              // the transfer threw…
        #expect(await manager.isDownloadPaused == false)    // …but not because of a pause
        // The controller keys `.failed` vs `.paused` on `isDownloadPaused`, so a
        // genuine failure (flag false) can never be swallowed as a pause.
    }
}

/// In-memory `DownloadPauseStore` for the manager tests — no disk, so a pause
/// left over from manual app use can't perturb the suite. Internal (not
/// private) so `SummaryModelLifecycleTests` can build a hermetic manager too.
final class InMemoryPauseStore: DownloadPauseStore, @unchecked Sendable {
    private let lock = NSLock()
    private var paused: Bool
    init(paused: Bool = false) { self.paused = paused }
    var isPaused: Bool { lock.lock(); defer { lock.unlock() }; return paused }
    func setPaused(_ newValue: Bool) { lock.lock(); paused = newValue; lock.unlock() }
}
