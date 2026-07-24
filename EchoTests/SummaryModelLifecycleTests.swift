//
//  SummaryModelLifecycleTests.swift
//  EchoTests
//
//  The summary model's memory lifecycle (ADR-008), asserted through the
//  manager's public API with counting fakes and a manual release scheduler —
//  no real MLX, network, disk, or clock (SP-003 Testing Decisions, layer 3).
//
//  What's observed: the loader's call count (an engine exists iff it ran), the
//  downloader's call count (one joined transfer), and — via a fake scheduler
//  the test fires on demand — whether the idle release lands. The discipline
//  under test: download/idle paths never load; active work loads once and is
//  released only after the idle timeout with no work in flight; a burst keeps
//  the model warm and cancels the pending release; a release can never land
//  while work is in flight or queued.
//

import Foundation
import Testing
@testable import Echo

@Suite("Summary model memory lifecycle (ADR-008)")
struct SummaryModelLifecycleTests {

    // MARK: - Fakes

    /// A no-op engine — these tests never run a generation, they only assert
    /// that (and when) one would be loaded.
    private struct FakeEngine: TextGenerating {
        func stream(system: String, user: String, params: GenerationParams)
            -> AsyncThrowingStream<String, Error>
        {
            AsyncThrowingStream { $0.finish() }
        }
    }

    /// Counts how many times the manager asked to LOAD weights into RAM.
    private final class CountingLoader: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0

        var load: EngineLoader {
            { [self] _ in
                lock.lock(); count += 1; lock.unlock()
                return FakeEngine()
            }
        }

        var loadCount: Int { lock.lock(); defer { lock.unlock() }; return count }
    }

    /// A mutable "is the snapshot on disk" flag shared between the injected
    /// existence check and the downloader (which flips it true on completion,
    /// exactly as a real finished download would).
    private final class SnapshotFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Bool
        init(onDisk: Bool) { value = onDisk }
        var exists: Bool { lock.lock(); defer { lock.unlock() }; return value }
        func setExists(_ newValue: Bool) { lock.lock(); value = newValue; lock.unlock() }
    }

    /// Counts snapshot transfers and never touches the network. Optionally
    /// blocks inside the transfer until `release()` so concurrent callers are
    /// provably in flight at the same time; flips its `SnapshotFlag` true on
    /// completion.
    private final class CountingDownloader: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        private let snapshot: SnapshotFlag?
        private let blocks: Bool
        private var gate: CheckedContinuation<Void, Never>?
        private var inFlightSignal: CheckedContinuation<Void, Never>?
        private var isInFlight = false

        init(snapshot: SnapshotFlag? = nil, blocks: Bool = false) {
            self.snapshot = snapshot
            self.blocks = blocks
        }

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
                if blocks {
                    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                        lock.lock(); gate = continuation; lock.unlock()
                    }
                }
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

        /// Let a blocked transfer finish.
        func release() {
            lock.lock(); let gate = self.gate; self.gate = nil; lock.unlock()
            gate?.resume()
        }

        var downloadCount: Int { lock.lock(); defer { lock.unlock() }; return count }
    }

    /// A release scheduler the test drives by hand: `arm`/`cancel` record what
    /// the manager asked for, and `fire()` simulates the idle timeout elapsing.
    /// No real sleeping, so the release discipline is fully deterministic.
    private final class ManualIdleReleaseScheduler: IdleReleaseScheduling, @unchecked Sendable {
        private let lock = NSLock()
        private var pending: (@Sendable () async -> Void)?
        private var lastArmed: (@Sendable () async -> Void)?
        private var armed = 0
        private var cancelled = 0

        func arm(after timeout: Duration, _ fire: @escaping @Sendable () async -> Void) {
            lock.lock()
            armed += 1
            pending = fire
            lastArmed = fire
            lock.unlock()
        }

        func cancel() {
            lock.lock()
            cancelled += 1
            pending = nil
            lock.unlock()
        }

        /// The idle timeout elapses for the currently-armed release.
        func fire() async {
            lock.lock(); let fire = pending; pending = nil; lock.unlock()
            await fire?()
        }

        /// Fire the most-recently-armed release even after `cancel()` cleared
        /// it — models the production race where the timer's sleep already
        /// elapsed before the cancellation landed, so it fires anyway and the
        /// manager must re-check work-in-flight before releasing.
        func fireLastArmedIgnoringCancel() async {
            lock.lock(); let fire = lastArmed; lock.unlock()
            await fire?()
        }

        var hasPending: Bool { lock.lock(); defer { lock.unlock() }; return pending != nil }
        var armCount: Int { lock.lock(); defer { lock.unlock() }; return armed }
        var cancelCount: Int { lock.lock(); defer { lock.unlock() }; return cancelled }
    }

    private let noProgress: @Sendable (String, Double) -> Void = { _, _ in }

    private func makeManager(
        loader: CountingLoader,
        downloader: CountingDownloader,
        snapshot: SnapshotFlag,
        scheduler: ManualIdleReleaseScheduler
    ) -> SummaryModelManager {
        SummaryModelManager(
            loader: loader.load,
            downloader: downloader.download,
            snapshotExists: { snapshot.exists },
            scheduler: scheduler
        )
    }

    // MARK: - Behavior 1: idle/download paths never load

    @Test("ensureDownloaded downloads but never loads the weights")
    func ensureDownloadedNeverLoads() async throws {
        let loader = CountingLoader()
        let snapshot = SnapshotFlag(onDisk: false)
        let downloader = CountingDownloader(snapshot: snapshot)
        let manager = makeManager(
            loader: loader, downloader: downloader, snapshot: snapshot,
            scheduler: ManualIdleReleaseScheduler()
        )

        try await manager.ensureDownloaded(progress: noProgress)

        #expect(downloader.downloadCount == 1)   // fetched the snapshot…
        #expect(loader.loadCount == 0)            // …but never brought it into RAM
    }

    @Test("a snapshot already on disk neither re-downloads nor loads")
    func snapshotPresentStaysUnloaded() async throws {
        let loader = CountingLoader()
        let snapshot = SnapshotFlag(onDisk: true)
        let downloader = CountingDownloader(snapshot: snapshot)
        let manager = makeManager(
            loader: loader, downloader: downloader, snapshot: snapshot,
            scheduler: ManualIdleReleaseScheduler()
        )

        try await manager.ensureDownloaded(progress: noProgress)

        #expect(downloader.downloadCount == 0)   // already complete on disk
        #expect(loader.loadCount == 0)            // still no engine in memory
    }

    // MARK: - Behavior 2: load for active work, release after idle timeout

    @Test("work loads the engine; after the idle timeout it releases and the next work reloads once")
    func idleTimeoutReleasesThenReloadsExactlyOnce() async throws {
        let loader = CountingLoader()
        let snapshot = SnapshotFlag(onDisk: true)   // downloaded; work only loads
        let scheduler = ManualIdleReleaseScheduler()
        let manager = makeManager(
            loader: loader, downloader: CountingDownloader(snapshot: snapshot),
            snapshot: snapshot, scheduler: scheduler
        )

        // One unit of work loads the weights and, once done, arms the release.
        try await manager.withEngine(progress: noProgress) { _ in }
        #expect(loader.loadCount == 1)
        #expect(scheduler.hasPending)

        // Idle timeout elapses with no further work → the engine is released.
        await scheduler.fire()

        // The next unit of work pays exactly one cold reload.
        try await manager.withEngine(progress: noProgress) { _ in }
        #expect(loader.loadCount == 2)
    }

    // MARK: - Behavior 2: burst keeps the model warm, cancels the pending release

    @Test("a second unit of work before the timeout reuses the warm engine and cancels the pending release")
    func backToBackBurstStaysWarmAndCancelsRelease() async throws {
        let loader = CountingLoader()
        let snapshot = SnapshotFlag(onDisk: true)
        let scheduler = ManualIdleReleaseScheduler()
        let manager = makeManager(
            loader: loader, downloader: CountingDownloader(snapshot: snapshot),
            snapshot: snapshot, scheduler: scheduler
        )

        // First unit of work: loads, then arms the release on completion.
        try await manager.withEngine(progress: noProgress) { _ in }
        #expect(loader.loadCount == 1)
        #expect(scheduler.hasPending)

        // Second unit arrives before the timeout fires. While it's in flight the
        // pending release must be cancelled (not just superseded on completion).
        try await manager.withEngine(progress: noProgress) { _ in
            #expect(scheduler.hasPending == false)
        }

        #expect(loader.loadCount == 1)          // stayed resident — no reload
        #expect(scheduler.cancelCount >= 2)     // the burst cancelled the pending release
        #expect(scheduler.hasPending)           // and re-armed once the burst went idle
    }

    // MARK: - Behavior 2: a release can never land while work is in flight

    @Test("advancing the clock while work is in flight does not release the engine")
    func releaseNeverLandsWhileWorkInFlight() async throws {
        let loader = CountingLoader()
        let snapshot = SnapshotFlag(onDisk: true)
        let scheduler = ManualIdleReleaseScheduler()
        let manager = makeManager(
            loader: loader, downloader: CountingDownloader(snapshot: snapshot),
            snapshot: snapshot, scheduler: scheduler
        )

        try await manager.withEngine(progress: noProgress) { _ in
            // Work is in flight: the release is only ever armed when work drops
            // to zero, so nothing is pending and advancing the clock is a no-op —
            // the engine cannot be pulled out from under an active generation.
            #expect(scheduler.hasPending == false)
            await scheduler.fire()
        }

        // Never released mid-work, so a follow-up unit still sees exactly one load.
        try await manager.withEngine(progress: noProgress) { _ in }
        #expect(loader.loadCount == 1)
    }

    @Test("a pending release that fires after new work began re-checks and does not unload")
    func pendingReleaseFiringAfterNewWorkDoesNotUnload() async throws {
        let loader = CountingLoader()
        let snapshot = SnapshotFlag(onDisk: true)
        let scheduler = ManualIdleReleaseScheduler()
        let manager = makeManager(
            loader: loader, downloader: CountingDownloader(snapshot: snapshot),
            snapshot: snapshot, scheduler: scheduler
        )

        // First unit of work loads and arms a release.
        try await manager.withEngine(progress: noProgress) { _ in }
        #expect(scheduler.hasPending)

        // A second unit begins (and cancels the pending release). Simulate the
        // production race where the first release's timer already elapsed and
        // fires anyway: the manager re-checks work-in-flight on the actor and
        // must NOT unload while this generation holds the engine.
        try await manager.withEngine(progress: noProgress) { _ in
            await scheduler.fireLastArmedIgnoringCancel()
        }

        // Never unloaded mid-work → the follow-up work stays on the one load.
        try await manager.withEngine(progress: noProgress) { _ in }
        #expect(loader.loadCount == 1)
    }

    // MARK: - Behavior 3 support: concurrent downloads join one transfer

    @Test("eager download + prefetch + post-stop ensureReady join a single transfer")
    func concurrentDownloadCallersJoinOneTransfer() async throws {
        let loader = CountingLoader()
        let snapshot = SnapshotFlag(onDisk: false)
        let downloader = CountingDownloader(snapshot: snapshot, blocks: true)
        let manager = makeManager(
            loader: loader, downloader: downloader, snapshot: snapshot,
            scheduler: ManualIdleReleaseScheduler()
        )
        let progress = noProgress

        // Three callers race — the eager first-launch download, the record-start
        // prefetch, and a post-stop summary's load — while the transfer is held
        // in flight, so they must all join the one downloadTask.
        async let first: Void = manager.ensureDownloaded(progress: progress)
        await downloader.waitUntilInFlight()
        async let second: Void = manager.ensureDownloaded(progress: progress)
        async let third: Void = manager.withEngine(progress: progress) { _ in }
        downloader.release()
        _ = try await (first, second, third)

        #expect(downloader.downloadCount == 1)   // one joined transfer, never three
        #expect(loader.loadCount == 1)            // only the ensureReady caller loaded
    }
}
