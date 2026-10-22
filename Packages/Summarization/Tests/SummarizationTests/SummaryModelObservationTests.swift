//
//  SummaryModelObservationTests.swift
//  SummarizationTests
//
//  The summary model announces its state, so the one observable façade above
//  it can repeat it without keeping a copy (ADR-003): an observer hears the
//  state now, then each change.
//
//  Driven through the actor's public API with the fakes the lifecycle suite
//  declares (`SnapshotFlag`, `InMemoryPauseStore`) — no network, disk, MLX or
//  clock. A missing announcement fails by the suite's time limit rather than
//  by a sleep: the next value simply never comes.
//

import EchoCore
import EchoCoreTestSupport
import Foundation
import Synchronization
import Testing

@testable import Summarization

@Suite("SummaryModel — observing its state", .timeLimit(.minutes(1)))
struct SummaryModelObservationTests {

    private func makeModel(
        snapshot: SnapshotFlag = SnapshotFlag(onDisk: false),
        partialBytes: Int64? = nil,
        pauseStore: InMemoryPauseStore = InMemoryPauseStore()
    ) -> SummaryModel {
        SummaryModel(
            modelsRoot: FileManager.default.temporaryDirectory.appending(path: "never-written-\(UUID().uuidString)"),
            pauseStateFile: FileManager.default.temporaryDirectory.appending(path: "never-written.json"),
            loader: { _ in throw SummaryModelError.loadFailed("no engine in this suite") },
            downloader: { _ in snapshot.setExists(true) },
            snapshotExists: { snapshot.exists },
            partialBytes: { partialBytes },
            pauseStore: pauseStore
        )
    }

    @Test("an observer hears the state now, then each change")
    func announcesEachChange() async throws {
        let model = makeModel(partialBytes: 1_024)
        var states = await model.stateChanges().makeAsyncIterator()
        #expect(await states.next() == .notDownloaded)

        await model.refreshState()
        #expect(await states.next() == .partiallyDownloaded)

        await model.pauseDownload()
        #expect(await states.next() == .paused)

        await model.resumeDownload()
        #expect(await states.next() == .partiallyDownloaded)

        try await model.ensureDownloaded()
        // The transfer passes through `downloading` on its way; newest wins,
        // so what is certain is that the observer is told where it ended.
        var last = await states.next()
        while case .downloading = last { last = await states.next() }
        #expect(last == .ready)
    }

    @Test("an observer that arrives late hears where the model is, not where it was")
    func lateObserverHearsTheCurrentState() async throws {
        let model = makeModel(partialBytes: 1_024)
        await model.refreshState()
        await model.pauseDownload()
        var states = await model.stateChanges().makeAsyncIterator()
        #expect(await states.next() == .paused)
    }

    @Test("every observer hears it, and one that stops listening is let go")
    func severalObservers() async throws {
        let model = makeModel()
        var first = await model.stateChanges().makeAsyncIterator()
        var second = await model.stateChanges().makeAsyncIterator()
        #expect(await first.next() == .notDownloaded)
        #expect(await second.next() == .notDownloaded)

        await model.pauseDownload()
        #expect(await first.next() == .paused)
        #expect(await second.next() == .paused)

        // A third stream that ends at once must not keep the model from
        // announcing to the others.
        do {
            let gone = await model.stateChanges()
            _ = gone
        }
        await model.resumeDownload()
        #expect(await first.next() == .notDownloaded)
        #expect(await second.next() == .notDownloaded)
    }
}
