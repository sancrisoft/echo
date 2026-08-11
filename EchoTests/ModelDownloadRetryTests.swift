//
//  ModelDownloadRetryTests.swift
//  EchoTests
//
//  Stall detection + retry for the model downloads: a download that stops
//  reporting progress is cancelled and retried; real errors propagate
//  immediately; exhausted attempts surface as StalledError.
//

import Foundation
import Testing
@testable import Echo

struct ModelDownloadRetryTests {

    /// Serializes attempt counting across the @Sendable operation closures.
    private final class AttemptCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0

        /// Increments and returns the attempt number this call represents.
        func next() -> Int {
            lock.lock()
            defer { lock.unlock() }
            value += 1
            return value
        }

        var count: Int {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
    }

    @Test func stalledAttemptIsCancelledAndRetried() async throws {
        let attempts = AttemptCounter()
        let retries = AttemptCounter()

        let value = try await ModelDownload.withStallRetry(
            attempts: 3,
            stallTimeout: 0.2,
            watchdogInterval: 0.05,
            onRetry: { _ in _ = retries.next() }
        ) { noteProgress in
            if attempts.next() == 1 {
                // First attempt: report progress once, then go idle until the
                // watchdog cancels this task.
                noteProgress(0.1)
                try await Task.sleep(for: .seconds(60))
            }
            noteProgress(1.0)
            return "done"
        }

        #expect(value == "done")
        #expect(attempts.count == 2)
        #expect(retries.count == 1)
    }

    @Test func exhaustedAttemptsThrowStalledError() async {
        let attempts = AttemptCounter()

        await #expect(throws: ModelDownload.StalledError.self) {
            try await ModelDownload.withStallRetry(
                attempts: 2,
                stallTimeout: 0.2,
                watchdogInterval: 0.05
            ) { noteProgress -> String in
                _ = attempts.next()
                try await Task.sleep(for: .seconds(60))
                return "unreachable"
            }
        }

        #expect(attempts.count == 2)
    }

    @Test func realErrorsPropagateWithoutRetry() async {
        struct DownloadBroke: Error {}
        let attempts = AttemptCounter()

        await #expect(throws: DownloadBroke.self) {
            try await ModelDownload.withStallRetry(
                attempts: 3,
                stallTimeout: 0.2,
                watchdogInterval: 0.05
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
    /// not swallow it — retrying would re-run a download that is broken for a
    /// reason retrying can't fix.
    @Test func realErrorThrownWhileTheWatchdogFiresStillPropagates() async {
        struct DownloadBroke: Error {}
        let attempts = AttemptCounter()

        await #expect(throws: DownloadBroke.self) {
            try await ModelDownload.withStallRetry(
                attempts: 3,
                stallTimeout: 0.1,
                watchdogInterval: 0.02
            ) { noteProgress -> String in
                _ = attempts.next()
                noteProgress(0.5)
                // Idle past the stall timeout, so the watchdog marks a stall and
                // cancels — then fail for a reason of our own.
                try? await Task.sleep(for: .seconds(0.4))
                throw DownloadBroke()
            }
        }

        #expect(attempts.count == 1)
    }

    @Test func progressBeatsKeepTheWatchdogQuiet() async throws {
        let retries = AttemptCounter()

        let value = try await ModelDownload.withStallRetry(
            attempts: 3,
            stallTimeout: 0.3,
            watchdogInterval: 0.05,
            onRetry: { _ in _ = retries.next() }
        ) { noteProgress in
            // Steady progress for ~0.5 s — longer than the stall timeout, but
            // never idle for longer than it.
            for step in 1...5 {
                noteProgress(Double(step) / 5)
                try await Task.sleep(for: .milliseconds(100))
            }
            return "done"
        }

        #expect(value == "done")
        #expect(retries.count == 0)
    }
}
