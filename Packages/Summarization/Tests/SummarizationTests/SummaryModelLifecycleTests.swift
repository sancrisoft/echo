//
//  SummaryModelLifecycleTests.swift
//  SummarizationTests
//
//  The summary model's memory lifecycle, asserted through the actor's public
//  API with counting fakes and a manual release scheduler — no real MLX, no
//  network, no disk, no clock.
//
//  What is observed: the loader's call count (an engine exists iff it ran),
//  the downloader's call count (one joined transfer), and — through a
//  scheduler the test fires by hand — whether the idle release lands. The
//  discipline under test: the download and idle paths never load; active work
//  loads once and is released only after the idle window with nothing in
//  flight; a burst keeps the model warm and cancels the pending release; a
//  release can never land while work is in flight.
//
//  Nothing here sleeps. The interesting case is a timer that has ALREADY
//  elapsed racing a re-acquire, which a real clock cannot be asked to
//  reproduce on command — `fireLastArmedIgnoringCancel()` is that case, and it
//  is why `releaseIfIdle` double-checks the work count on the actor.
//

import EchoCore
import EchoCoreTestSupport
import Foundation
import ModelDelivery
import Synchronization
import Testing

@testable import Summarization

// MARK: - Shared fakes

// These four are module-scope rather than private because the pause/resume
// suite builds the same hermetic model over them (same module, one definition).

/// A no-op engine — these suites never run a generation, they only assert that
/// (and when) one would be loaded.
struct FakeTextEngine: TextGenerating {
    func stream(system: String, user: String, params: GenerationParams) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

/// Counts how many times the model asked to LOAD weights into RAM.
final class CountingEngineLoader: Sendable {

    private let count = Mutex(0)

    var load: SummaryEngineLoader {
        { [self] _ in
            count.withLock { $0 += 1 }
            return FakeTextEngine()
        }
    }

    var loadCount: Int { count.withLock { $0 } }
}

/// A mutable "is the snapshot on disk" flag, shared between the injected
/// existence check and a downloader that flips it true on completion — exactly
/// as a real finished download would.
final class SnapshotFlag: Sendable {

    private let value: Mutex<Bool>

    init(onDisk: Bool) {
        value = Mutex(onDisk)
    }

    var exists: Bool { value.withLock { $0 } }

    func setExists(_ newValue: Bool) {
        value.withLock { $0 = newValue }
    }
}

/// In-memory `DownloadPauseStore`: no disk, so a pause left over from manual
/// app use cannot perturb a suite, and a seeded `paused: true` stands in for
/// the file a previous run wrote.
final class InMemoryPauseStore: DownloadPauseStore {

    private let paused: Mutex<Bool>

    init(paused: Bool = false) {
        self.paused = Mutex(paused)
    }

    var isPaused: Bool { paused.withLock { $0 } }

    func setPaused(_ newValue: Bool) {
        paused.withLock { $0 = newValue }
    }
}

/// A release scheduler the test drives by hand: `arm`/`cancel` record what the
/// model asked for and `fire()` stands in for the idle window elapsing. No real
/// sleeping, so the release discipline is fully deterministic.
final class ManualIdleReleaseScheduler: IdleReleaseScheduling {

    private struct State {
        var pending: (@Sendable () async -> Void)?
        var lastArmed: (@Sendable () async -> Void)?
        var armedTimeouts: [Duration] = []
        var cancelCount = 0
    }

    private let state = Mutex(State())

    func arm(after timeout: Duration, _ fire: @escaping @Sendable () async -> Void) {
        state.withLock {
            $0.armedTimeouts.append(timeout)
            $0.pending = fire
            $0.lastArmed = fire
        }
    }

    func cancel() {
        state.withLock {
            $0.cancelCount += 1
            $0.pending = nil
        }
    }

    /// The idle window elapses for the currently-armed release.
    func fire() async {
        let fire = state.withLock { state -> (@Sendable () async -> Void)? in
            let pending = state.pending
            state.pending = nil
            return pending
        }
        await fire?()
    }

    /// Fire the most-recently-armed release even after `cancel()` cleared it —
    /// the production race where the timer's sleep already elapsed before the
    /// cancellation landed, so it fires anyway and the model must re-check work
    /// in flight before releasing. The only way to reach that branch at all.
    func fireLastArmedIgnoringCancel() async {
        let fire = state.withLock { $0.lastArmed }
        await fire?()
    }

    var hasPending: Bool { state.withLock { $0.pending != nil } }

    var armCount: Int { state.withLock { $0.armedTimeouts.count } }

    var cancelCount: Int { state.withLock { $0.cancelCount } }

    /// Every duration the model armed with, so the 60 s window is asserted as
    /// the value the model actually asks for and not only as a constant.
    var armedTimeouts: [Duration] { state.withLock { $0.armedTimeouts } }
}

// MARK: - The downloader fake

/// Counts snapshot transfers and never touches the network. Optionally blocks
/// inside the transfer until `release()`, so concurrent callers are provably in
/// flight at the same time; flips its `SnapshotFlag` true on completion.
private final class CountingDownloader: Sendable {

    private struct State {
        var count = 0
        var isInFlight = false
        var gate: CheckedContinuation<Void, Never>?
        var inFlightWaiters: [CheckedContinuation<Void, Never>] = []
    }

    private let state = Mutex(State())
    private let snapshot: SnapshotFlag?
    private let blocks: Bool

    init(snapshot: SnapshotFlag? = nil, blocks: Bool = false) {
        self.snapshot = snapshot
        self.blocks = blocks
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
            if blocks {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    state.withLock { $0.gate = continuation }
                }
            }
            snapshot?.setExists(true)
            progress(.downloading, 1)
        }
    }

    /// Resumes once a transfer has entered the downloader — the event resumes
    /// the waiter, so nothing depends on a clock.
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

    /// Let a blocked transfer finish.
    func release() {
        let gate = state.withLock { state -> CheckedContinuation<Void, Never>? in
            let gate = state.gate
            state.gate = nil
            return gate
        }
        gate?.resume()
    }

    var downloadCount: Int { state.withLock { $0.count } }
}

// MARK: - The suite

@Suite("Summary model memory lifecycle")
struct SummaryModelLifecycleTests {

    /// `modelsRoot` and `pauseStateFile` are required by design, so every test
    /// gets its own scratch folder and no suite can read — let alone delete —
    /// the real data folder. With the existence check, the partial probe and
    /// the pause store all injected, nothing here touches the file system at
    /// all; the temporary directory is the belt to that braces.
    private func makeModel(
        in temporary: TemporaryDirectory,
        loader: CountingEngineLoader,
        downloader: CountingDownloader,
        snapshot: SnapshotFlag,
        scheduler: any IdleReleaseScheduling
    ) -> SummaryModel {
        SummaryModel(
            modelsRoot: temporary.path("Models"),
            pauseStateFile: temporary.path("summary-model-download-state.json"),
            loader: loader.load,
            downloader: downloader.download,
            snapshotExists: { snapshot.exists },
            partialBytes: { nil },
            scheduler: scheduler,
            pauseStore: InMemoryPauseStore()
        )
    }

    // MARK: - The idle window is a measured constant

    /// 60 s: long enough to span a regenerate or a quick follow-up summary,
    /// short enough that the app returns to its light baseline soon after the
    /// user is done. Pinned as a value so a retune is a failing test rather
    /// than a silent change in resident memory behavior.
    @Test("the idle release window is 60 seconds")
    func idleTimeoutIsSixtySeconds() {
        #expect(SummaryModel.idleTimeout == .seconds(60))
    }

    @Test("the release is armed with the model's own idle window, never some other duration")
    func releaseIsArmedWithTheIdleTimeout() async throws {
        let temporary = try TemporaryDirectory(prefix: "SummaryModelLifecycleTests")
        defer { temporary.remove() }
        let loader = CountingEngineLoader()
        let snapshot = SnapshotFlag(onDisk: true)
        let scheduler = ManualIdleReleaseScheduler()
        let model = makeModel(
            in: temporary, loader: loader, downloader: CountingDownloader(snapshot: snapshot),
            snapshot: snapshot, scheduler: scheduler
        )

        try await model.withEngine { _ in }

        #expect(scheduler.armCount == 1)
        #expect(scheduler.armedTimeouts.allSatisfy { $0 == SummaryModel.idleTimeout })
    }

    // MARK: - Behavior 1: the idle and download paths never load

    @Test("ensureDownloaded downloads but never loads the weights")
    func ensureDownloadedNeverLoads() async throws {
        let temporary = try TemporaryDirectory(prefix: "SummaryModelLifecycleTests")
        defer { temporary.remove() }
        let loader = CountingEngineLoader()
        let snapshot = SnapshotFlag(onDisk: false)
        let downloader = CountingDownloader(snapshot: snapshot)
        let model = makeModel(
            in: temporary, loader: loader, downloader: downloader,
            snapshot: snapshot, scheduler: ManualIdleReleaseScheduler()
        )

        try await model.ensureDownloaded()

        #expect(downloader.downloadCount == 1)  // fetched the snapshot…
        #expect(loader.loadCount == 0)  // …but never brought it into RAM
    }

    @Test("a snapshot already on disk neither re-downloads nor loads")
    func snapshotPresentStaysUnloaded() async throws {
        let temporary = try TemporaryDirectory(prefix: "SummaryModelLifecycleTests")
        defer { temporary.remove() }
        let loader = CountingEngineLoader()
        let snapshot = SnapshotFlag(onDisk: true)
        let downloader = CountingDownloader(snapshot: snapshot)
        let model = makeModel(
            in: temporary, loader: loader, downloader: downloader,
            snapshot: snapshot, scheduler: ManualIdleReleaseScheduler()
        )

        try await model.ensureDownloaded()

        #expect(downloader.downloadCount == 0)  // already complete on disk
        #expect(loader.loadCount == 0)  // still no engine in memory
    }

    // MARK: - Behavior 2: load for active work, release after the idle window

    @Test("work loads the engine; after the idle window it releases and the next work reloads once")
    func idleTimeoutReleasesThenReloadsExactlyOnce() async throws {
        let temporary = try TemporaryDirectory(prefix: "SummaryModelLifecycleTests")
        defer { temporary.remove() }
        let loader = CountingEngineLoader()
        let snapshot = SnapshotFlag(onDisk: true)  // downloaded; work only loads
        let scheduler = ManualIdleReleaseScheduler()
        let model = makeModel(
            in: temporary, loader: loader, downloader: CountingDownloader(snapshot: snapshot),
            snapshot: snapshot, scheduler: scheduler
        )

        // One unit of work loads the weights and, once done, arms the release.
        try await model.withEngine { _ in }
        #expect(loader.loadCount == 1)
        #expect(scheduler.hasPending)

        // The idle window elapses with no further work → the engine is released.
        await scheduler.fire()

        // The next unit of work pays exactly one cold reload.
        try await model.withEngine { _ in }
        #expect(loader.loadCount == 2)
    }

    // MARK: - Behavior 2: a burst keeps the model warm and cancels the pending release

    @Test("a second unit of work before the window elapses reuses the warm engine and cancels the release")
    func backToBackBurstStaysWarmAndCancelsRelease() async throws {
        let temporary = try TemporaryDirectory(prefix: "SummaryModelLifecycleTests")
        defer { temporary.remove() }
        let loader = CountingEngineLoader()
        let snapshot = SnapshotFlag(onDisk: true)
        let scheduler = ManualIdleReleaseScheduler()
        let model = makeModel(
            in: temporary, loader: loader, downloader: CountingDownloader(snapshot: snapshot),
            snapshot: snapshot, scheduler: scheduler
        )

        // First unit of work: loads, then arms the release on completion.
        try await model.withEngine { _ in }
        #expect(loader.loadCount == 1)
        #expect(scheduler.hasPending)

        // The second unit arrives before the window elapses. While it is in
        // flight the pending release must be CANCELLED, not merely superseded
        // when the burst finishes.
        try await model.withEngine { _ in
            #expect(scheduler.hasPending == false)
        }

        #expect(loader.loadCount == 1)  // stayed resident — no reload
        #expect(scheduler.cancelCount >= 2)  // the burst cancelled the pending release
        #expect(scheduler.hasPending)  // and re-armed once the burst went idle
    }

    // MARK: - Behavior 2: a release can never land while work is in flight

    @Test("the window elapsing while work is in flight does not release the engine")
    func releaseNeverLandsWhileWorkInFlight() async throws {
        let temporary = try TemporaryDirectory(prefix: "SummaryModelLifecycleTests")
        defer { temporary.remove() }
        let loader = CountingEngineLoader()
        let snapshot = SnapshotFlag(onDisk: true)
        let scheduler = ManualIdleReleaseScheduler()
        let model = makeModel(
            in: temporary, loader: loader, downloader: CountingDownloader(snapshot: snapshot),
            snapshot: snapshot, scheduler: scheduler
        )

        try await model.withEngine { _ in
            // Work is in flight: the release is only ever armed when the count
            // drops to zero, so nothing is pending and firing the scheduler is
            // a no-op — the engine cannot be pulled out from under an active
            // generation.
            #expect(scheduler.hasPending == false)
            await scheduler.fire()
        }

        // Never released mid-work, so a follow-up unit still sees one load.
        try await model.withEngine { _ in }
        #expect(loader.loadCount == 1)
    }

    @Test("a pending release that fires after new work began re-checks and does not unload")
    func pendingReleaseFiringAfterNewWorkDoesNotUnload() async throws {
        let temporary = try TemporaryDirectory(prefix: "SummaryModelLifecycleTests")
        defer { temporary.remove() }
        let loader = CountingEngineLoader()
        let snapshot = SnapshotFlag(onDisk: true)
        let scheduler = ManualIdleReleaseScheduler()
        let model = makeModel(
            in: temporary, loader: loader, downloader: CountingDownloader(snapshot: snapshot),
            snapshot: snapshot, scheduler: scheduler
        )

        // First unit of work loads and arms a release.
        try await model.withEngine { _ in }
        #expect(scheduler.hasPending)

        // A second unit begins, cancelling that release. Now reproduce the
        // production race: the first release's timer had already elapsed and
        // fires anyway. The model re-checks work in flight on the actor and
        // must NOT unload while this generation holds the engine.
        try await model.withEngine { _ in
            await scheduler.fireLastArmedIgnoringCancel()
        }

        // Never unloaded mid-work → the follow-up work stays on the one load.
        try await model.withEngine { _ in }
        #expect(loader.loadCount == 1)
    }

    // MARK: - Behavior 3: concurrent callers join one transfer

    @Test("eager download, prefetch and a post-stop ensureReady join a single transfer")
    func concurrentDownloadCallersJoinOneTransfer() async throws {
        let temporary = try TemporaryDirectory(prefix: "SummaryModelLifecycleTests")
        defer { temporary.remove() }
        let loader = CountingEngineLoader()
        let snapshot = SnapshotFlag(onDisk: false)
        let downloader = CountingDownloader(snapshot: snapshot, blocks: true)
        let model = makeModel(
            in: temporary, loader: loader, downloader: downloader,
            snapshot: snapshot, scheduler: ManualIdleReleaseScheduler()
        )

        // Three callers race — the eager first-launch download, the
        // record-start prefetch and a post-stop summary's load — while the
        // transfer is held in flight, so they must all join the one download
        // task.
        async let first: Void = model.ensureDownloaded()
        await downloader.waitUntilInFlight()
        async let second: Void = model.ensureDownloaded()
        async let third: Void = model.withEngine { _ in }
        downloader.release()
        _ = try await (first, second, third)

        #expect(downloader.downloadCount == 1)  // one joined transfer, never three
        #expect(loader.loadCount == 1)  // only the ensureReady caller loaded
    }
}
