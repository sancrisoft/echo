//
//  DownloadRetryTests.swift
//  ModelDeliveryTests
//
//  Stall detection and retry for the model downloads: a download that stops
//  reporting progress is cancelled and retried; real errors propagate
//  immediately; exhausted attempts surface as `.downloadStalled`.
//
//  Split by determinism rather than by type. The watchdog's arithmetic — which
//  beat resets the idle clock, and what "idle" then measures — is pinned by
//  pure `ProgressTracker` tests that inject both the beat's instant and the
//  reading's, so the invariant the PoC could only observe by sleeping through
//  half a second of real progress is asserted exactly. Which failures a stall
//  may retry is likewise a pure question (`isOurCancellation`). What stays
//  async is the orchestration alone — an attempt is cancelled and retried,
//  attempts run out, a real error is never retried — and there every operation
//  body waits on its own cancellation rather than on a clock, so only the
//  production watchdog watches time, at an injected polling rate.
//

import Foundation
import Synchronization
import Testing

@testable import ModelDelivery

@Suite("Download retry")
struct DownloadRetryTests {

    // MARK: - The watchdog's heartbeat

    @Test("only forward progress resets the idle clock")
    func onlyForwardProgressResetsTheIdleClock() {
        let tracker = ProgressTracker()
        let start = ContinuousClock.now

        tracker.note(fraction: 0.2, at: start)
        #expect(tracker.idleSeconds(now: start) == 0)
        #expect(tracker.idleSeconds(now: start.advanced(by: .seconds(5))) == 5)

        // The same fraction again is exactly the stall being detected: a
        // connection that keeps repeating itself has not made progress.
        tracker.note(fraction: 0.2, at: start.advanced(by: .seconds(5)))
        #expect(tracker.idleSeconds(now: start.advanced(by: .seconds(10))) == 10)

        // Neither does a fraction that went backwards (a re-opened transfer
        // re-reporting the offset it resumed from).
        tracker.note(fraction: 0.1, at: start.advanced(by: .seconds(10)))
        #expect(tracker.idleSeconds(now: start.advanced(by: .seconds(10))) == 10)

        // Forward progress does.
        tracker.note(fraction: 0.3, at: start.advanced(by: .seconds(10)))
        #expect(tracker.idleSeconds(now: start.advanced(by: .seconds(10))) == 0)
    }

    /// A transfer's first callback is usually 0; it is still a heartbeat, and a
    /// download must not be declared stalled for reporting it.
    @Test("the first beat counts even at zero")
    func theFirstBeatCountsEvenAtZero() {
        let tracker = ProgressTracker()
        let start = ContinuousClock.now

        tracker.note(fraction: 0, at: start.advanced(by: .seconds(3)))
        #expect(tracker.idleSeconds(now: start.advanced(by: .seconds(3))) == 0)
    }

    /// The invariant behind the PoC's `progressBeatsKeepTheWatchdogQuiet`: a
    /// download that beats steadily is never idle for the stall timeout, no
    /// matter how much longer than the timeout it runs in total. Asserted as
    /// arithmetic instead of by sleeping through five real beats.
    @Test("steady beats never let the idle window reach the stall timeout")
    func steadyBeatsNeverReachTheStallTimeout() {
        let stallTimeout: TimeInterval = 0.3
        let beat = Duration.milliseconds(100)
        let tracker = ProgressTracker()
        var now = ContinuousClock.now

        // Five beats: half a second of download against a 0.3 s timeout.
        for step in 1...5 {
            tracker.note(fraction: Double(step) / 5, at: now)
            #expect(tracker.idleSeconds(now: now) == 0)
            now = now.advanced(by: beat)
            #expect(tracker.idleSeconds(now: now) < stallTimeout)
        }
    }

    /// The complement: repeating a fraction for as long as you like accrues
    /// idle time, which is what lets the watchdog fire on a dead connection
    /// that is still calling back.
    @Test("a repeated fraction accrues idle time for as long as it repeats")
    func aRepeatedFractionAccruesIdleTime() {
        let tracker = ProgressTracker()
        let start = ContinuousClock.now

        tracker.note(fraction: 0.5, at: start)
        for second in 1...5 {
            tracker.note(fraction: 0.5, at: start.advanced(by: .seconds(second)))
        }

        #expect(tracker.idleSeconds(now: start.advanced(by: .seconds(5))) == 5)
    }

    @Test("the stall verdict is absent until the watchdog records it")
    func theStallVerdictIsAbsentUntilRecorded() {
        let tracker = ProgressTracker()

        #expect(!tracker.wasStalled)
        tracker.markStalled()
        #expect(tracker.wasStalled)
    }

    // MARK: - Which failures a stall may retry

    /// Half of the AND-condition guarding the retry: the download reacting to
    /// the watchdog's own `cancel()`, whichever of its two shapes it arrives in.
    @Test("structured cancellation and a cancelled request are both ours")
    func cancellationsAreOurs() {
        #expect(DownloadRetry.isOurCancellation(CancellationError()))
        #expect(DownloadRetry.isOurCancellation(URLError(.cancelled)))
    }

    /// A real failure is never mistaken for our cancellation — retrying it
    /// would re-run a download that is broken for a reason retrying can't fix.
    @Test("a real transport or domain error is not our cancellation")
    func realErrorsAreNotOurCancellation() {
        #expect(!DownloadRetry.isOurCancellation(URLError(.timedOut)))
        #expect(!DownloadRetry.isOurCancellation(URLError(.notConnectedToInternet)))
        #expect(!DownloadRetry.isOurCancellation(DownloadBroke()))
    }

    // MARK: - The orchestration

    @Test("a stalled attempt is cancelled and retried")
    func stalledAttemptIsCancelledAndRetried() async throws {
        let attempts = AttemptCounter()
        let retries = RetryLog()

        let value = try await DownloadRetry.withStallRetry(
            attempts: 3,
            stallTimeout: 0.5,
            watchdogInterval: 0.02,
            onRetry: { attempt in retries.record(attempt) },
            operation: { noteProgress in
                if attempts.next() == 1 {
                    // First attempt: one beat, then a wait nothing but cancellation
                    // ends. The watchdog's whole job is to be that cancellation.
                    noteProgress(0.1)
                    try await waitUntilCancelled()
                }
                // The retry has no suspension point at all, so nothing can come
                // between its beat and its result.
                noteProgress(1.0)
                return "done"
            }
        )

        #expect(value == "done")
        #expect(attempts.count == 2)
        #expect(retries.attemptNumbers == [2])
    }

    @Test("exhausted attempts surface as a stalled download")
    func exhaustedAttemptsThrowStalledError() async {
        let attempts = AttemptCounter()

        await #expect(throws: ModelDeliveryError.downloadStalled) {
            try await DownloadRetry.withStallRetry(
                attempts: 2,
                stallTimeout: 0.05,
                watchdogInterval: 0.01
            ) { _ -> String in
                _ = attempts.next()
                try await waitUntilCancelled()
                return "unreachable"
            }
        }

        #expect(attempts.count == 2)
    }

    @Test("a real error propagates without a retry")
    func realErrorsPropagateWithoutRetry() async {
        let attempts = AttemptCounter()

        await #expect(throws: DownloadBroke.self) {
            try await DownloadRetry.withStallRetry(
                attempts: 3,
                stallTimeout: 0.5,
                watchdogInterval: 0.02
            ) { noteProgress -> String in
                _ = attempts.next()
                noteProgress(0.5)
                throw DownloadBroke()
            }
        }

        #expect(attempts.count == 1)
    }

    /// The load-dependent version of the case above: the operation throws a real
    /// error, but not before the watchdog has already decided it stalled (a
    /// starved machine can delay the throw past the timeout). A stall retry must
    /// not swallow it. Deterministic here because the operation waits FOR the
    /// cancellation rather than for a duration long enough to provoke it.
    @Test("a real error thrown while the watchdog fires still propagates")
    func realErrorThrownWhileTheWatchdogFiresStillPropagates() async {
        let attempts = AttemptCounter()

        await #expect(throws: DownloadBroke.self) {
            try await DownloadRetry.withStallRetry(
                attempts: 3,
                stallTimeout: 0.05,
                watchdogInterval: 0.01
            ) { noteProgress -> String in
                _ = attempts.next()
                noteProgress(0.5)
                // Idle until the watchdog marks a stall and cancels — then fail
                // for a reason of our own.
                try? await waitUntilCancelled()
                throw DownloadBroke()
            }
        }

        #expect(attempts.count == 1)
    }

    /// A healthy operation, end to end, at the production polling rate: it beats
    /// and finishes, and no retry is ever considered.
    @Test("an operation that beats and finishes is never retried")
    func progressingOperationIsNeverRetried() async throws {
        let attempts = AttemptCounter()
        let retries = RetryLog()

        let value = try await DownloadRetry.withStallRetry(
            onRetry: { attempt in retries.record(attempt) },
            operation: { noteProgress in
                for step in 1...5 {
                    noteProgress(Double(step) / 5)
                }
                _ = attempts.next()
                return "done"
            }
        )

        #expect(value == "done")
        #expect(attempts.count == 1)
        #expect(retries.attemptNumbers.isEmpty)
    }
}

// MARK: - Helpers

/// A failure that is emphatically not a stall.
private struct DownloadBroke: Error {}

/// Serializes attempt counting across the `@Sendable` operation closures.
private final class AttemptCounter: Sendable {

    private let value = Mutex(0)

    /// Increments and returns the attempt number this call represents.
    func next() -> Int {
        value.withLock {
            $0 += 1
            return $0
        }
    }

    var count: Int { value.withLock { $0 } }
}

/// The attempt numbers `onRetry` announced, in order.
private final class RetryLog: Sendable {

    private let attempts = Mutex<[Int]>([])

    func record(_ attempt: Int) {
        attempts.withLock { $0.append(attempt) }
    }

    var attemptNumbers: [Int] { attempts.withLock { $0 } }
}

/// Suspends until the surrounding task is cancelled, then throws
/// `CancellationError`.
///
/// The stand-in for the PoC's `Task.sleep(for: .seconds(60))`, which meant
/// "this operation never finishes on its own" and made the test's runtime a
/// bet on the watchdog winning a race against a clock. Here the continuation is
/// stored and never resumed by anything but cancellation, so the operation
/// reaches its next step the instant the watchdog acts and not a moment of wall
/// clock sooner or later.
private func waitUntilCancelled() async throws {
    let box = CancellationBox()
    try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            box.store(continuation)
        }
    } onCancel: {
        box.resumeWithCancellation()
    }
}

/// Holds the parked continuation. `Mutex` rather than a lock-and-flag pair
/// because the cancellation can land before the continuation is stored, and the
/// continuation must be resumed exactly once either way.
private final class CancellationBox: Sendable {

    private struct State {
        var continuation: CheckedContinuation<Void, any Error>?
        var isCancelled = false
        var isResumed = false
    }

    private let state = Mutex(State())

    func store(_ continuation: CheckedContinuation<Void, any Error>) {
        let alreadyCancelled: Bool = state.withLock {
            guard $0.isCancelled, !$0.isResumed else {
                $0.continuation = continuation
                return false
            }
            $0.isResumed = true
            return true
        }
        if alreadyCancelled { continuation.resume(throwing: CancellationError()) }
    }

    func resumeWithCancellation() {
        let parked: CheckedContinuation<Void, any Error>? = state.withLock {
            $0.isCancelled = true
            guard !$0.isResumed, let parked = $0.continuation else { return nil }
            $0.continuation = nil
            $0.isResumed = true
            return parked
        }
        parked?.resume(throwing: CancellationError())
    }
}
