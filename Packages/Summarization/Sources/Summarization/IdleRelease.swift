//
//  IdleRelease.swift
//  Summarization
//
//  When to give the weights back.
//
//  Behind a protocol so the release discipline is deterministic under test: a
//  fake fires the timer on demand, and no suite ever sleeps for a minute to
//  find out whether a minute works. That matters more than it looks — the
//  interesting case is a timer that has ALREADY elapsed racing a re-acquire,
//  which a real clock cannot be asked to reproduce on command.
//

import Foundation
import Synchronization

/// Schedules, and cancels, the summary model's idle release.
public protocol IdleReleaseScheduling: Sendable {

    /// (Re)arm the release: run `fire` after `timeout` unless `cancel()`, or a
    /// superseding `arm`, intervenes first. `fire` re-enters the model and
    /// re-checks work in flight, so losing the cancellation race is still safe.
    func arm(after timeout: Duration, _ fire: @escaping @Sendable () async -> Void)

    /// Cancel a pending release: new work arrived, or the model was unloaded.
    func cancel()
}

/// Production scheduler: one cancellable task that sleeps, then fires.
///
/// A `Mutex` rather than a lock plus `@unchecked Sendable`: the only shared
/// state is the pending task, and it is replaced from whichever isolation
/// called `arm`.
public final class TaskIdleReleaseScheduler: IdleReleaseScheduling {

    private let pending = Mutex<Task<Void, Never>?>(nil)

    public init() {}

    public func arm(after timeout: Duration, _ fire: @escaping @Sendable () async -> Void) {
        pending.withLock { task in
            task?.cancel()
            task = Task {
                // A cancelled sleep — superseded, or work resumed — throws, and
                // must not fire. When it does fire, the model re-checks work in
                // flight anyway.
                do { try await Task.sleep(for: timeout) } catch { return }
                await fire()
            }
        }
    }

    public func cancel() {
        pending.withLock { task in
            task?.cancel()
            task = nil
        }
    }
}
