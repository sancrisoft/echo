//
//  DownloadRetry.swift
//  ModelDelivery
//
//  Stall detection and retry for the large model downloads (the transcription
//  model and the summary snapshot). A download whose connection goes idle
//  otherwise hangs forever with the UI stuck at its last percentage and every
//  trigger disabled — the only way out was relaunching the app.
//
//  A watchdog watches the progress callbacks; when no forward progress is
//  reported for `stallTimeout`, the in-flight download is cancelled and the
//  operation is retried (both the Hub snapshot pass and the transcription
//  model's downloader skip already-completed files, so a retry resumes rather
//  than starting over). Only genuine stalls are retried — real errors (no
//  network, no disk) still propagate immediately.
//

import Foundation
import Synchronization

public enum DownloadRetry {

    /// Attempts before a stall is surfaced to the user. Measured: three
    /// attempts covered every transient stall seen on real connections, and a
    /// fourth only extended the time before an honest failure appeared.
    public static let defaultAttempts = 3

    /// Silence that counts as a stall. Measured: a healthy transfer on a slow
    /// connection still reports bytes well inside a minute, so 60 s
    /// distinguishes a dead connection from a slow one without false positives.
    public static let defaultStallTimeout: TimeInterval = 60

    /// How often the watchdog samples the tracker. Fine enough that a stall is
    /// noticed promptly relative to the 60 s timeout, coarse enough to cost
    /// nothing over a multi-hour download.
    public static let defaultWatchdogInterval: TimeInterval = 5

    /// Runs `operation` with stall detection, retrying up to `attempts` times.
    ///
    /// `operation` receives a `noteProgress` sink and must call it with the
    /// running completion fraction from its own progress callback — that
    /// heartbeat is what the watchdog measures. `onRetry` fires (with the
    /// attempt number about to start) before each retry, so callers can
    /// surface "Retrying…" in their progress UI.
    public static func withStallRetry<T: Sendable>(
        attempts: Int = defaultAttempts,
        stallTimeout: TimeInterval = defaultStallTimeout,
        watchdogInterval: TimeInterval = defaultWatchdogInterval,
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
                // stall — the caller's own error handling owns it. Both
                // conditions are required: `wasStalled` alone would retry an
                // operation that threw a genuine error in the same instant the
                // watchdog happened to fire, and `isOurCancellation` alone
                // would retry a user-initiated pause.
                guard tracker.wasStalled, isOurCancellation(error) else { throw error }
                guard attempt < attempts else { throw ModelDeliveryError.downloadStalled }
                attempt += 1
                onRetry(attempt)
            }
        }
    }

    /// Whether `error` is the download reacting to the watchdog's own
    /// `cancel()` — the only failure a stall may retry. URLSession surfaces a
    /// cancelled transfer as `URLError.cancelled`, structured concurrency as
    /// `CancellationError`, and both mean "we stopped it", never "the transfer
    /// broke".
    static func isOurCancellation(_ error: any Error) -> Bool {
        if error is CancellationError { return true }
        if let urlError = error as? URLError, urlError.code == .cancelled { return true }
        return false
    }
}

/// The watchdog's view of a download's heartbeat.
///
/// Lock-guarded because the progress callbacks arrive on URLSession worker
/// threads while the watchdog polls from its own task. `idleSeconds(now:)`
/// takes the instant as a parameter so the idle arithmetic is testable without
/// waiting for a clock.
final class ProgressTracker: Sendable {

    private struct State {
        var lastProgressAt = ContinuousClock.now
        var lastFraction: Double = -1
        var stalled = false
    }

    private let state = Mutex(State())

    func note(fraction: Double, at now: ContinuousClock.Instant = .now) {
        state.withLock {
            // Only forward progress resets the clock: a connection that keeps
            // reporting the same fraction is exactly the stall being detected.
            guard fraction > $0.lastFraction else { return }
            $0.lastFraction = fraction
            $0.lastProgressAt = now
        }
    }

    func idleSeconds(now: ContinuousClock.Instant = .now) -> TimeInterval {
        state.withLock {
            let parts = $0.lastProgressAt.duration(to: now).components
            return TimeInterval(parts.seconds) + TimeInterval(parts.attoseconds) / 1e18
        }
    }

    func markStalled() {
        state.withLock { $0.stalled = true }
    }

    var wasStalled: Bool {
        state.withLock { $0.stalled }
    }
}
