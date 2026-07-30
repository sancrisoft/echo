//
//  TieredFinalPassProviderTests.swift
//  EchoTests
//
//  SP-005 S5 (ADR-015): the tiered provider's choice matrix, with tier and
//  completeness injected as values and the pass-scoped load behind a factory
//  seam — no real model is ever loaded (Testing Decisions, layer 4). Marker
//  errors prove which path executed: the fake fallback and the fake loader
//  each throw a distinct sentinel, so every assertion is on observable
//  routing, never on internals.
//

import Foundation
import Testing
import WhisperKit
@testable import Echo

@Suite("TieredFinalPassModelProvider (ADR-015)")
struct TieredFinalPassProviderTests {

    // MARK: - Fakes

    private struct Marker: Error, Equatable {
        let id: String
        static let fallbackReached = Marker(id: "fallback")
        static let loaderInvoked = Marker(id: "loader")
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0

        func bump() {
            lock.lock()
            defer { lock.unlock() }
            count += 1
        }

        var value: Int {
            lock.lock()
            defer { lock.unlock() }
            return count
        }
    }

    /// Delegation target that records the call and throws its sentinel —
    /// `withModel` can't return without a real WhisperKit, so the sentinel IS
    /// the proof the live path was chosen.
    private struct MarkerFallback: FinalPassModelProviding {
        let calls: Counter

        func withModel<T: Sendable>(
            _ body: @Sendable (WhisperKit) async throws -> T
        ) async throws -> T {
            calls.bump()
            throw Marker.fallbackReached
        }
    }

    private func makeProvider(
        tier: FinalPassTier,
        folderReady: Bool,
        loaderCalls: Counter = Counter(),
        fallbackCalls: Counter = Counter(),
        onServed: (@Sendable (FinalPassModelChoice) -> Void)? = nil
    ) -> TieredFinalPassModelProvider {
        TieredFinalPassModelProvider(
            tierProvider: { tier },
            readyFolder: { folderReady ? URL(fileURLWithPath: "/synthetic/openai_whisper-large-v3_947MB") : nil },
            loadModel: { _ in
                loaderCalls.bump()
                throw Marker.loaderInvoked
            },
            fallback: MarkerFallback(calls: fallbackCalls),
            onServed: onServed
        )
    }

    private func expectMarker(
        _ expected: Marker,
        from provider: TieredFinalPassModelProvider
    ) async {
        do {
            _ = try await provider.withModel { _ in () }
            Issue.record("withModel returned without reaching a fake seam")
        } catch let marker as Marker {
            #expect(marker == expected)
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    // MARK: - The pure decision table

    @Test("the choice matrix routes every doubt to the live model")
    func choiceMatrix() {
        typealias Row = (FinalPassTier, Bool, Bool, FinalPassModelChoice)
        let rows: [Row] = [
            // (tier, snapshotComplete, loadFailedThisSession, expected)
            (.reuseLive, false, false, .liveModel),
            (.reuseLive, true, false, .liveModel),   // floor tier never loads, even with the snapshot on disk
            (.reuseLive, true, true, .liveModel),
            (.fullLargeV3, false, false, .liveModel), // absent / incomplete / still downloading
            (.fullLargeV3, true, true, .liveModel),   // a load already failed this session
            (.fullLargeV3, false, true, .liveModel),
            (.fullLargeV3, true, false, .fullLargeV3),
        ]
        for (tier, complete, failed, expected) in rows {
            #expect(
                TieredFinalPassModelProvider.decide(
                    tier: tier, snapshotComplete: complete, loadFailedThisSession: failed
                ) == expected,
                "tier=\(tier) complete=\(complete) failed=\(failed)"
            )
        }
    }

    // MARK: - Routing

    @Test("the floor tier delegates to the live model without touching the loader")
    func floorTierDelegatesToLive() async {
        let loaderCalls = Counter()
        let fallbackCalls = Counter()
        let provider = makeProvider(
            tier: .reuseLive, folderReady: true,
            loaderCalls: loaderCalls, fallbackCalls: fallbackCalls
        )

        await expectMarker(.fallbackReached, from: provider)
        #expect(loaderCalls.value == 0)
        #expect(fallbackCalls.value == 1)
        #expect(await provider.lastServed == .liveModel)
    }

    @Test("an incomplete snapshot delegates to the live model without touching the loader")
    func incompleteSnapshotDelegatesToLive() async {
        let loaderCalls = Counter()
        let fallbackCalls = Counter()
        let provider = makeProvider(
            tier: .fullLargeV3, folderReady: false,
            loaderCalls: loaderCalls, fallbackCalls: fallbackCalls
        )

        await expectMarker(.fallbackReached, from: provider)
        #expect(loaderCalls.value == 0)
        #expect(fallbackCalls.value == 1)
        #expect(await provider.lastServed == .liveModel)
    }

    @Test("full tier with a complete snapshot reaches the pass-scoped loader")
    func fullTierReachesTheLoader() async {
        let loaderCalls = Counter()
        let provider = makeProvider(tier: .fullLargeV3, folderReady: true, loaderCalls: loaderCalls)

        // The throwing loader triggers the graceful floor, so the observable
        // outcome is: loader touched once, then the live model served.
        await expectMarker(.fallbackReached, from: provider)
        #expect(loaderCalls.value == 1)
    }

    @Test("a load failure falls back to the live model and is remembered for the session")
    func loadFailureFallsBackAndSticks() async {
        let loaderCalls = Counter()
        let fallbackCalls = Counter()
        let provider = makeProvider(
            tier: .fullLargeV3, folderReady: true,
            loaderCalls: loaderCalls, fallbackCalls: fallbackCalls
        )

        // First pass: load fails → live model serves (never an errored pass).
        await expectMarker(.fallbackReached, from: provider)
        #expect(loaderCalls.value == 1)
        #expect(await provider.lastServed == .liveModel)

        // Second pass this session: no retry loop — straight to the live
        // model, the loader untouched.
        await expectMarker(.fallbackReached, from: provider)
        #expect(loaderCalls.value == 1)
        #expect(fallbackCalls.value == 2)
    }

    @Test("onServed reports the model that actually served the pass")
    func onServedReportsTheChoice() async {
        let served = LockedChoices()
        let provider = makeProvider(
            tier: .fullLargeV3, folderReady: true,
            onServed: { served.append($0) }
        )

        await expectMarker(.fallbackReached, from: provider)
        // The load failed, so the pass was honestly served by the live model.
        #expect(served.values == [.liveModel])
    }

    private final class LockedChoices: @unchecked Sendable {
        private let lock = NSLock()
        private var choices: [FinalPassModelChoice] = []

        func append(_ choice: FinalPassModelChoice) {
            lock.lock()
            defer { lock.unlock() }
            choices.append(choice)
        }

        var values: [FinalPassModelChoice] {
            lock.lock()
            defer { lock.unlock() }
            return choices
        }
    }
}
