//
//  ParakeetModelLifecycleTests.swift
//  TranscriptionTests
//
//  The model's download lifecycle, through the seams: what it reports while it
//  fetches, that what it reports can be followed from outside the actor, and
//  that a failed fetch can be run again — recording waits on this model since
//  the product owner's decision of 2026-10-02, so a failure that held until a
//  relaunch would hold recording with it. No network, no 480 MB.
//

import EchoCoreTestSupport
import Foundation
import Synchronization
import Testing
import Transcription

@Suite("Parakeet model lifecycle")
struct ParakeetModelLifecycleTests {

    struct Unreachable: Error {}

    /// Collects what a stream says up to and including `.ready` or a failure.
    /// The stream keeps only the newest state for a slow listener — a façade
    /// wants where things stand, not the history — so a listener may miss
    /// steps but never sees them out of order and never misses the end.
    private func untilSettled(_ stream: AsyncStream<ParakeetModelState>) async -> [ParakeetModelState] {
        var seen: [ParakeetModelState] = []
        for await state in stream {
            seen.append(state)
            if state == .ready { break }
            if case .failed = state { break }
        }
        return seen
    }

    @Test("files already on disk are ready without a transfer")
    func presentIsReady() async throws {
        let temporary = try TemporaryDirectory()
        defer { temporary.remove() }
        let model = ParakeetModel(
            modelsRoot: temporary.url, modelsPresent: { true },
            downloader: { _ in Issue.record("a model on disk was fetched again") })
        await model.initialize()
        #expect(await model.state == .ready)
    }

    @Test("a fetch reports its progress in order and ends ready, as a follower hears it")
    func aFetchIsFollowed() async throws {
        let temporary = try TemporaryDirectory()
        defer { temporary.remove() }
        let onDisk = Mutex(false)
        let model = ParakeetModel(
            modelsRoot: temporary.url,
            modelsPresent: { onDisk.withLock { $0 } },
            downloader: { progress in
                await progress(0.41)
                onDisk.withLock { $0 = true }
            })
        let changes = await model.stateChanges()
        let listener = Task { await untilSettled(changes) }
        await model.initialize()
        let seen = await listener.value

        let order: [ParakeetModelState] = [.absent, .downloading(0), .downloading(0.41), .ready]
        #expect(seen.last == .ready)
        let positions = seen.compactMap { order.firstIndex(of: $0) }
        #expect(positions.count == seen.count, "a state the fetch never reports: \(seen)")
        #expect(positions == positions.sorted(), "heard out of order: \(seen)")
    }

    @Test("a follower that arrives late hears where things stand first")
    func aLateFollowerHearsTheStateNow() async throws {
        let temporary = try TemporaryDirectory()
        defer { temporary.remove() }
        let model = ParakeetModel(modelsRoot: temporary.url, modelsPresent: { true })
        await model.initialize()
        #expect(await untilSettled(await model.stateChanges()) == [.ready])
    }

    @Test("a failed fetch can be run again, and nothing runs it again on its own")
    func aFailureCanBeRetried() async throws {
        let temporary = try TemporaryDirectory()
        defer { temporary.remove() }
        let onDisk = Mutex(false)
        let attempts = Mutex(0)
        let model = ParakeetModel(
            modelsRoot: temporary.url,
            modelsPresent: { onDisk.withLock { $0 } },
            downloader: { _ in
                let attempt = attempts.withLock { count -> Int in
                    count += 1
                    return count
                }
                if attempt == 1 { throw Unreachable() }
                onDisk.withLock { $0 = true }
            })

        await model.initialize()
        guard case .failed = await model.state else {
            Issue.record("the first attempt did not fail")
            return
        }
        #expect(attempts.withLock { $0 } == 1)

        // The user's Retry.
        await model.initialize()
        #expect(await model.state == .ready)
        #expect(attempts.withLock { $0 } == 2)

        // Ready is final for this launch: a third call fetches nothing.
        await model.initialize()
        #expect(attempts.withLock { $0 } == 2)
    }
}
