//
//  FinalizationMachine.swift
//  Recording
//
//  When a transcription pass may run, and when a summary may. Ported as-is
//  from the PoC, where it was already a pure, table-tested machine — events
//  in, actions out, no clock, no I/O — which is exactly the kind of thing
//  ADR-006 says to carry across rather than re-derive. Only the isolation
//  changed: the PoC needed `nonisolated` against a main-actor default this
//  package does not have.
//
//  The two invariants it exists to hold: a pass never decodes while a
//  recording runs or while a summary streams, and a meeting's retries are
//  bounded within a run and reopened only by the user.
//
//  Nothing here is persisted. The retained audio on disk is the checkpoint,
//  so a relaunch counts attempts fresh and the in-memory terminal set dies
//  with the process — deliberately, because a persisted counter would make a
//  meeting permanently unfinalizable after two bad launches.
//

import Foundation
import Synchronization

public struct FinalizationMachine: Sendable {

    /// Pass attempts per meeting per app run (bounded retries). A resume at
    /// the next launch counts fresh — the retained audio, not a persisted
    /// counter, is the checkpoint.
    public static let maxAttemptsPerRun = 2

    public enum Conclusion: Equatable, Sendable {
        case success
        case failure
        /// `shouldYield` stopped the pass between decode windows (a recording
        /// started). A deferral — consumes no attempt.
        case preempted
    }

    public enum Event: Equatable, Sendable {
        /// A pending meeting wants a pass (launch resume). Appends to the
        /// back, so callers requesting newest-first keep the queue
        /// newest-first.
        case passRequested(UUID)
        /// The just-stopped meeting's own pass: front of the queue, and the
        /// only pass admitted while its post-stop pipeline holds the gate.
        case stopPassRequested(UUID)
        /// The running pass ended.
        case passConcluded(Conclusion)
        case recordingStarted
        /// Recording ended and its post-stop pipeline (pass → summary) began.
        /// Deferred passes stay held until `pipelineFinished` — they resume
        /// behind the new meeting's own post-stop work.
        case recordingStopped
        /// The post-stop pipeline finished (summary done or abandoned).
        case pipelineFinished
        /// Summary work wants to run. Granted only while no pass decodes;
        /// while requested or granted, no new pass starts.
        case summaryRequested
        case summaryEnded
        /// The user pressed Retry on a failed meeting: clear the meeting's
        /// terminal exclusion and failed-attempt history (a fresh bounded
        /// cycle) and admit it at the FRONT of the queue — the user-request
        /// discipline. Normal admission still gates the start (recording,
        /// summary work, open pipelines). Also valid for a meeting terminal
        /// only on disk (a relaunch: this set is in-memory) — there is simply
        /// nothing to clear.
        case manualRetryRequested(UUID)
    }

    public enum Action: Equatable, Sendable {
        case startPass(meetingID: UUID, attempt: Int)
        /// Retries exhausted this run (terminal convergence): record the
        /// terminal provenance on the meeting's meta — one atomic write, the
        /// retained audio stays KEPT for the manual Retry.
        case converge(meetingID: UUID)
        /// Resume `count` waiting summary-work requests.
        case grantSummary(count: Int)
    }

    public private(set) var isRecording = false
    /// Open post-stop pipelines. A count, not a flag: a new recording can
    /// start (and stop) while an older pipeline is still winding down.
    public private(set) var pipelineCount = 0
    /// The meeting whose post-stop pipeline opened most recently — the one
    /// pass admitted while any pipeline is open.
    public private(set) var pipelineMeetingID: UUID?
    /// Pending passes, front = next. Newest-first by construction: launch
    /// resume requests newest-first (appends), preempted/retrying meetings
    /// re-enter at the front they came from, and the just-stopped meeting
    /// inserts at the very front.
    public private(set) var queue: [UUID] = []
    public private(set) var runningMeetingID: UUID?
    public private(set) var runningAttempt = 0
    /// Failed attempts consumed per meeting this run (preemptions excluded).
    private var failedAttempts: [UUID: Int] = [:]
    public private(set) var summaryWaiting = 0
    public private(set) var summaryActive = 0
    /// Meetings whose finalization converged terminally this run — never
    /// re-admitted within the run (in-memory only; nothing is persisted).
    public private(set) var terminalMeetingIDs: Set<UUID> = []

    /// A pass is running or pending — the driver's "not idle" signal (defers
    /// the optional model download; surfaces the finalizing UI).
    public var isBusy: Bool { runningMeetingID != nil || !queue.isEmpty }

    public init() {}

    @discardableResult
    public mutating func handle(_ event: Event) -> [Action] {
        switch event {
        case .passRequested(let id):
            guard runningMeetingID != id, !queue.contains(id),
                !terminalMeetingIDs.contains(id)
            else { return [] }
            queue.append(id)
            return maybeStartPass()

        case .stopPassRequested(let id):
            pipelineMeetingID = id
            guard runningMeetingID != id, !queue.contains(id),
                !terminalMeetingIDs.contains(id)
            else { return maybeStartPass() }
            queue.insert(id, at: 0)
            return maybeStartPass()

        case .passConcluded(let conclusion):
            guard let id = runningMeetingID else { return [] }
            runningMeetingID = nil
            var actions: [Action] = []
            switch conclusion {
            case .success:
                failedAttempts[id] = nil
            case .failure:
                failedAttempts[id] = runningAttempt
                if runningAttempt >= Self.maxAttemptsPerRun {
                    terminalMeetingIDs.insert(id)
                    actions.append(.converge(meetingID: id))
                } else {
                    queue.insert(id, at: 0)
                }
            case .preempted:
                // A deferral, not an attempt: back to the front it came from,
                // so newest-first order is preserved and the retained audio
                // stays the untouched pending marker.
                queue.insert(id, at: 0)
            }
            runningAttempt = 0
            // Waiting summary work wins over the next queued pass: the pass
            // that just ended is what it was waiting for.
            return actions + (grantSummaryIfPossible() ?? maybeStartPass())

        case .recordingStarted:
            // The driver's preemption signal makes the running pass yield
            // within one decode window; the machine only closes the admission
            // gate here.
            isRecording = true
            return []

        case .recordingStopped:
            isRecording = false
            pipelineCount += 1
            return maybeStartPass()

        case .pipelineFinished:
            pipelineCount = max(0, pipelineCount - 1)
            if pipelineCount == 0 { pipelineMeetingID = nil }
            return maybeStartPass()

        case .summaryRequested:
            summaryWaiting += 1
            return grantSummaryIfPossible() ?? []

        case .summaryEnded:
            summaryActive = max(0, summaryActive - 1)
            return maybeStartPass()

        case .manualRetryRequested(let id):
            // Fresh cycle: forget the terminal exclusion and the exhausted
            // attempt budget — only the user re-opens a converged meeting, so
            // this can never become an automatic loop.
            terminalMeetingIDs.remove(id)
            failedAttempts[id] = nil
            // Already decoding: the running attempt IS the retry.
            guard runningMeetingID != id else { return [] }
            queue.removeAll { $0 == id }
            queue.insert(id, at: 0)
            return maybeStartPass()
        }
    }

    /// Grants every waiting summary request the moment no pass is decoding.
    /// Summary-vs-summary serialization is not this machine's job (the summary
    /// model's own work count owns that); this gate only keeps summary work
    /// and pass decodes from ever overlapping.
    private mutating func grantSummaryIfPossible() -> [Action]? {
        guard summaryWaiting > 0, runningMeetingID == nil else { return nil }
        let count = summaryWaiting
        summaryActive += count
        summaryWaiting = 0
        return [.grantSummary(count: count)]
    }

    private mutating func maybeStartPass() -> [Action] {
        guard runningMeetingID == nil, !isRecording,
            summaryWaiting == 0, summaryActive == 0,
            let next = queue.first
        else { return [] }
        // While a post-stop pipeline is open, only its own meeting's pass may
        // run — deferred work resumes behind the new meeting's pass AND its
        // summary.
        if pipelineCount > 0 && next != pipelineMeetingID { return [] }
        queue.removeFirst()
        runningMeetingID = next
        runningAttempt = failedAttempts[next, default: 0] + 1
        return [.startPass(meetingID: next, attempt: runningAttempt)]
    }
}

/// The recording-start flag a running pass's `shouldYield` closure reads
/// before every decode window.
///
/// Lock-guarded because the decode loop reads it off the main actor while the
/// driver raises and lowers it on the main actor (the diagnostics-sink
/// pattern); the per-window cost is one uncontended acquisition. A `Mutex`
/// rather than the PoC's `NSLock` for the reason `Audio` gave the same
/// change: same semantics, and `Sendable` without an unchecked escape hatch.
final class FinalizationPreemptionSignal: Sendable {

    private let raised = Mutex(false)

    var isRaised: Bool { raised.withLock { $0 } }

    func raise() { raised.withLock { $0 = true } }

    func lower() { raised.withLock { $0 = false } }
}
