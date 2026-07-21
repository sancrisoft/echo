//
//  ModelDownloadRetry.swift
//  Echo
//
//  Stall detection + retry for the multi-GB model downloads (the Whisper
//  variant and the summary LLM snapshot). A download whose connection goes
//  idle otherwise hangs forever with the UI stuck at its last percentage and
//  every trigger button disabled — the only way out was relaunching the app.
//
//  A watchdog watches the progress callbacks; when no forward progress is
//  reported for `stallTimeout`, the in-flight download is cancelled and the
//  operation is retried (both Hub snapshots and WhisperKit downloads skip
//  already-completed files, so a retry resumes rather than starting over).
//  Only genuine stalls are retried — real errors (no network, no disk) still
//  propagate immediately.
//

import Foundation

nonisolated enum ModelDownload {

    /// All retry attempts stalled — surfaced to the user with a retry hint.
    struct StalledError: LocalizedError {
        var errorDescription: String? {
            "The download stalled and made no progress. Check your connection and retry."
        }
    }

    static let defaultAttempts = 3
    static let defaultStallTimeout: TimeInterval = 60

    /// Runs `operation` with stall detection, retrying up to `attempts` times.
    ///
    /// `operation` receives a `noteProgress` sink and must call it with the
    /// running completion fraction from its own progress callback — that
    /// heartbeat is what the watchdog measures. `onRetry` fires (with the
    /// attempt number about to start) before each retry, so callers can
    /// surface "Retrying…" in their progress UI.
    static func withStallRetry<T: Sendable>(
        attempts: Int = defaultAttempts,
        stallTimeout: TimeInterval = defaultStallTimeout,
        watchdogInterval: TimeInterval = 5,
        onRetry: @Sendable @escaping (Int) -> Void = { _ in },
        operation: @Sendable @escaping (_ noteProgress: @Sendable @escaping (Double) -> Void) async throws -> T
    ) async throws -> T {
        var attempt = 1
        while true {
            let tracker = ProgressTracker()
            // Unstructured on purpose: the watchdog must be able to cancel
            // the download without the failure tearing down the caller.
            let download = Task {
                try await operation { tracker.note(fraction: $0) }
            }
            let watchdog = Task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(watchdogInterval))
                    if tracker.idleSeconds() >= stallTimeout {
                        tracker.markStalled()
                        download.cancel()
                        return
                    }
                }
            }

            do {
                let value = try await download.value
                watchdog.cancel()
                return value
            } catch {
                watchdog.cancel()
                // A real failure (offline, disk full, server error) is not a
                // stall — the caller's own error handling owns it.
                guard tracker.wasStalled else { throw error }
                guard attempt < attempts else { throw StalledError() }
                attempt += 1
                onRetry(attempt)
            }
        }
    }

    /// Lock-guarded because the progress callbacks arrive on URLSession
    /// worker threads while the watchdog polls from its own task.
    private final class ProgressTracker: @unchecked Sendable {
        private let lock = NSLock()
        private var lastProgressAt = ContinuousClock.now
        private var lastFraction: Double = -1
        private var stalled = false

        func note(fraction: Double) {
            lock.lock()
            defer { lock.unlock() }
            // Only forward progress resets the clock: a connection that keeps
            // reporting the same fraction is exactly the stall being detected.
            guard fraction > lastFraction else { return }
            lastFraction = fraction
            lastProgressAt = .now
        }

        func idleSeconds(now: ContinuousClock.Instant = .now) -> TimeInterval {
            lock.lock()
            defer { lock.unlock() }
            let parts = lastProgressAt.duration(to: now).components
            return TimeInterval(parts.seconds) + TimeInterval(parts.attoseconds) / 1e18
        }

        func markStalled() {
            lock.lock()
            defer { lock.unlock() }
            stalled = true
        }

        var wasStalled: Bool {
            lock.lock()
            defer { lock.unlock() }
            return stalled
        }
    }
}
