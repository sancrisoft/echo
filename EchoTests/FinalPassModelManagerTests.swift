//
//  FinalPassModelManagerTests.swift
//  EchoTests
//
//  SP-005 S5 (ADR-015): the acquisition manager's lifecycle with every seam
//  faked (tier, completeness, downloader — SummaryModelManager's injection
//  pattern): no network, no disk, no real model. Asserts observable state
//  transitions and routing only — floor machines never download, complete
//  snapshots never re-download, an active recording defers the transfer, and
//  a transfer that can't verify never claims ready.
//

import Foundation
import Testing
@testable import Echo

@Suite("FinalPassModelManager (ADR-015)")
struct FinalPassModelManagerTests {

    // MARK: - Fakes

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0

        /// Increments and returns the new value.
        @discardableResult
        func next() -> Int {
            lock.lock()
            defer { lock.unlock() }
            count += 1
            return count
        }

        var value: Int {
            lock.lock()
            defer { lock.unlock() }
            return count
        }
    }

    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var raised: Bool

        init(_ raised: Bool = false) { self.raised = raised }

        func raise() {
            lock.lock()
            defer { lock.unlock() }
            raised = true
        }

        var value: Bool {
            lock.lock()
            defer { lock.unlock() }
            return raised
        }
    }

    private final class LockedStates: @unchecked Sendable {
        private let lock = NSLock()
        private var states: [FinalPassModelState] = []

        func append(_ state: FinalPassModelState) {
            lock.lock()
            defer { lock.unlock() }
            states.append(state)
        }

        var values: [FinalPassModelState] {
            lock.lock()
            defer { lock.unlock() }
            return states
        }
    }

    // MARK: - Tier routing

    @Test("floor-tier machines never download — the model is not needed")
    func floorTierNeverDownloads() async {
        let downloads = Counter()
        let manager = FinalPassModelManager(
            tier: .reuseLive,
            snapshotComplete: { false },
            downloader: { _ in downloads.next() }
        )

        await manager.initialize()

        #expect(await manager.currentState == .notNeeded(.reuseLive))
        #expect(downloads.value == 0)
        #expect(await manager.passModelFolderIfReady() == nil)
    }

    @Test("a complete snapshot reads ready with no download")
    func completeSnapshotIsReadyWithoutDownload() async {
        let downloads = Counter()
        let manager = FinalPassModelManager(
            tier: .fullLargeV3,
            snapshotComplete: { true },
            downloader: { _ in downloads.next() }
        )

        await manager.initialize()

        #expect(await manager.currentState == .ready)
        #expect(downloads.value == 0)
        let folder = await manager.passModelFolderIfReady()
        #expect(folder?.lastPathComponent == FinalPassModelManager.variantFolderName)
    }

    /// The floor tier lends no folder even when the snapshot happens to be on
    /// disk (say, RAM was swapped down) — the tier decides, per pass.
    @Test("the floor tier lends no pass-model folder even with a complete snapshot")
    func floorTierLendsNoFolder() async {
        let manager = FinalPassModelManager(
            tier: .reuseLive,
            snapshotComplete: { true },
            downloader: { _ in }
        )

        #expect(await manager.passModelFolderIfReady() == nil)
    }

    // MARK: - Acquisition

    @Test("an absent snapshot downloads with honest progress, then reads ready")
    func absentSnapshotDownloadsToReady() async {
        let complete = Flag(false)
        let observed = LockedStates()
        let manager = FinalPassModelManager(
            tier: .fullLargeV3,
            snapshotComplete: { complete.value },
            downloader: { progress in
                await progress(0.5)
                await progress(1.0)
                complete.raise()
            }
        )
        await manager.setStateHandler { observed.append($0) }

        await manager.initialize()

        #expect(await manager.currentState == .ready)
        // The single fraction source drove the observable states, in order.
        #expect(observed.values.contains(.downloading(0.5)))
        #expect(observed.values.last == .ready)
        #expect(await manager.passModelFolderIfReady() != nil)
    }

    @Test("a failed download reads failed, never ready")
    func failedDownloadReadsFailed() async {
        struct Boom: LocalizedError {
            var errorDescription: String? { "network gone" }
        }
        let manager = FinalPassModelManager(
            tier: .fullLargeV3,
            snapshotComplete: { false },
            downloader: { _ in throw Boom() }
        )

        await manager.initialize()

        #expect(await manager.currentState == .failed("network gone"))
        #expect(await manager.passModelFolderIfReady() == nil)
    }

    /// The ADR-012 fail-safe direction at the manager level: a transfer that
    /// returned but whose snapshot still reads incomplete must not claim
    /// ready.
    @Test("a download that cannot verify reads failed, not ready")
    func unverifiedDownloadReadsFailed() async {
        let manager = FinalPassModelManager(
            tier: .fullLargeV3,
            snapshotComplete: { false },   // stays incomplete after the transfer
            downloader: { _ in }
        )

        await manager.initialize()

        guard case .failed = await manager.currentState else {
            Issue.record("expected .failed, got \(await manager.currentState)")
            return
        }
        #expect(await manager.passModelFolderIfReady() == nil)
    }

    // MARK: - Sequencing guard

    @Test("the download defers while the guard holds and starts once it clears")
    func downloadDefersWhileGuarded() async {
        let deferChecks = Counter()
        let downloads = Counter()
        let complete = Flag(false)
        let manager = FinalPassModelManager(
            tier: .fullLargeV3,
            snapshotComplete: { complete.value },
            downloader: { _ in
                downloads.next()
                complete.raise()
            },
            deferPollInterval: .milliseconds(1)
        )

        // Guard holds for the first two polls (a recording in flight), then
        // clears — the transfer must start only after that.
        await manager.initialize(deferWhile: { deferChecks.next() < 3 })

        #expect(deferChecks.value == 3)
        #expect(downloads.value == 1)
        #expect(await manager.currentState == .ready)
    }

    // MARK: - Idempotency

    @Test("initialize is once per launch — a second call never re-downloads")
    func initializeIsIdempotent() async {
        let downloads = Counter()
        let complete = Flag(false)
        let manager = FinalPassModelManager(
            tier: .fullLargeV3,
            snapshotComplete: { complete.value },
            downloader: { _ in
                downloads.next()
                complete.raise()
            }
        )

        await manager.initialize()
        await manager.initialize()

        #expect(downloads.value == 1)
        #expect(await manager.currentState == .ready)
    }

    // MARK: - Late subscription

    @Test("a late state handler is told the current state immediately")
    func lateHandlerSeesCurrentState() async {
        let observed = LockedStates()
        let manager = FinalPassModelManager(
            tier: .fullLargeV3,
            snapshotComplete: { true },
            downloader: { _ in }
        )
        await manager.initialize()

        await manager.setStateHandler { observed.append($0) }

        #expect(observed.values == [.ready])
    }
}
