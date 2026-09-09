//
//  FinalizationDriver.swift
//  Recording
//
//  The thin main-actor driver over `FinalizationMachine`: it feeds events in,
//  executes the actions that come out through injected closures, and resolves
//  the awaited outcome the stop path needs.
//
//  The machine owns WHEN a pass runs. This owns the running of it, and knows
//  nothing about audio, models or `Meetings` — which is what lets every
//  scenario the PoC could only describe in prose be a test here. Its
//  predecessor, `FinalizationCoordinator`, carried the same logic behind
//  settable `var` seams that no test ever set, so the coordination itself was
//  untested; the seams are `init` parameters now for that reason alone.
//
//  Two balances hold the whole thing together and neither is expressible in
//  the type system, so both are tested: one `noteRecordingStopped()` is
//  matched by exactly one `notePostStopWorkFinished()`, and one
//  `beginSummaryWork()` by exactly one `endSummaryWork()`.
//

import EchoCore
import Foundation
import os

@MainActor
final class FinalizationDriver {

    private static let log = Logger(
        subsystem: AppIdentity.logSubsystem, category: "FinalizationDriver")

    /// What one pass produced. An empty segment set is a legitimate success:
    /// the model heard no speech.
    enum PassResult: Equatable, Sendable {
        case replaced([TranscriptSegment])
        case failed
        case preempted
    }

    /// What the stop path learns about the meeting it just persisted.
    ///
    /// `.failed` means terminal: retries are exhausted and the meeting has no
    /// transcript at all. There is no draft to fall back on — the honest
    /// failed state plus a manual Retry is the whole outcome.
    enum StopOutcome: Equatable, Sendable {
        case replaced([TranscriptSegment])
        case failed
        case deferred
    }

    // MARK: - Seams

    private let runPass: @MainActor (UUID, @escaping @Sendable () -> Bool) async -> PassResult
    /// Runs before the first decode of EVERY pass. Wired to the summary
    /// model's unload: two multi-gigabyte models must never be resident at
    /// once, and a warm summary engine is exactly what a pass would collide
    /// with.
    private let prepareForPass: @MainActor () async -> Void
    private let convergeTerminally: @MainActor (UUID) async -> Void
    private let onBackgroundPassConcluded: @MainActor (UUID, PassResult) async -> Void
    /// A pass that no stop path was awaiting concluded — a launch resume, a
    /// Retry, a re-transcribe. Its summary has no pipeline of its own.
    /// Reports everything a surface reads about finalization, as one value.
    /// The driver owns this state and PUBLISHES it; nothing re-derives it.
    private let onStateChanged: @MainActor (Snapshot) -> Void

    init(
        runPass: @escaping @MainActor (UUID, @escaping @Sendable () -> Bool) async -> PassResult,
        prepareForPass: @escaping @MainActor () async -> Void,
        convergeTerminally: @escaping @MainActor (UUID) async -> Void,
        onBackgroundPassConcluded: @escaping @MainActor (UUID, PassResult) async -> Void,
        onStateChanged: @escaping @MainActor (Snapshot) -> Void
    ) {
        self.runPass = runPass
        self.prepareForPass = prepareForPass
        self.convergeTerminally = convergeTerminally
        self.onBackgroundPassConcluded = onBackgroundPassConcluded
        self.onStateChanged = onStateChanged
    }

    /// What the session republishes for the UI: the meeting a pass is running
    /// for and its fraction, plus the work waiting behind it and the meetings
    /// that gave up this run.
    struct Snapshot: Equatable, Sendable {
        var meetingID: UUID?
        var progress: Double?
        var queued: [UUID] = []
        var terminalFailures: Set<UUID> = []

        static let idle = Snapshot(meetingID: nil, progress: nil)
    }

    // MARK: - State

    private var machine = FinalizationMachine()
    private let preemption = FinalizationPreemptionSignal()

    private var stopAwaiters: [UUID: CheckedContinuation<StopOutcome, Never>] = [:]
    /// Outcomes that resolved before anyone awaited them. `requestStopPass`
    /// and `awaitStopOutcome` are deliberately two calls — the request has to
    /// be synchronous so the phase shows `.finalizing` before `stop()`
    /// returns — and a pass that fails instantly can conclude in between.
    private var settledStopOutcomes: [UUID: StopOutcome] = [:]
    private var stopInterest: Set<UUID> = []
    private var summaryWaiters: [CheckedContinuation<Void, Never>] = []

    /// Identifies one pass ATTEMPT, so a same-meeting retry starts its bar
    /// fresh instead of appearing stuck under the forward-only progress
    /// guard.
    private struct PassKey: Equatable {
        let meetingID: UUID
        let attempt: Int
    }
    private var publishedPass: PassKey?

    private(set) var currentMeetingID: UUID?
    private(set) var progress: Double?

    var isBusy: Bool { machine.isBusy }
    var queuedMeetingIDs: [UUID] { machine.queue }
    var terminalFailureIDs: Set<UUID> { machine.terminalMeetingIDs }

    // MARK: - Recording lifecycle

    /// Raises the preemption signal and closes the admission gate.
    ///
    /// Signalled before any capture setup, so a decoding pass begins yielding
    /// immediately rather than one decode window later.
    func noteRecordingStarted() {
        preemption.raise()
        run(machine.handle(.recordingStarted))
    }

    /// Lowers the signal and opens the stopped meeting's post-stop pipeline.
    /// Balanced by exactly one `notePostStopWorkFinished()` on every path.
    func noteRecordingStopped() {
        preemption.lower()
        run(machine.handle(.recordingStopped))
    }

    /// The post-stop pipeline (pass, then summary) is done or abandoned.
    func notePostStopWorkFinished() {
        run(machine.handle(.pipelineFinished))
    }

    // MARK: - Requests

    /// Admits the just-stopped meeting's own pass, ahead of the queue.
    /// Synchronous, so the session's phase reports `.finalizing` before
    /// `stop()` has returned rather than one main-actor hop later.
    func requestStopPass(_ meetingID: UUID) {
        stopInterest.insert(meetingID)
        run(machine.handle(.stopPassRequested(meetingID)))
    }

    /// Waits for what became of that meeting's stop pass.
    func awaitStopOutcome(for meetingID: UUID) async -> StopOutcome {
        if let settled = settledStopOutcomes.removeValue(forKey: meetingID) {
            stopInterest.remove(meetingID)
            return settled
        }
        return await withCheckedContinuation { continuation in
            stopAwaiters[meetingID] = continuation
        }
    }

    /// The launch scan's pending meetings, newest first. Request order is
    /// queue order, and only one runs at a time.
    func requestResume(of meetingIDs: [UUID]) {
        for id in meetingIDs {
            run(machine.handle(.passRequested(id)))
        }
    }

    /// The user's Retry, or a re-transcribe. A fresh bounded cycle at the
    /// front of the queue — but it bypasses no admission gate: bounded within
    /// every cycle, user-paced across cycles, never an automatic loop.
    func requestManualRetry(_ meetingID: UUID) {
        run(machine.handle(.manualRetryRequested(meetingID)))
    }

    // MARK: - Summary gating

    /// Suspends until no pass is decoding, then holds the gate closed against
    /// new passes until `endSummaryWork()`.
    func beginSummaryWork() async {
        let granted = machine.handle(.summaryRequested)
        if grantedCount(in: granted) > 0 {
            run(granted)
            return
        }
        await withCheckedContinuation { continuation in
            summaryWaiters.append(continuation)
            run(granted)
        }
    }

    func endSummaryWork() {
        run(machine.handle(.summaryEnded))
    }

    private func grantedCount(in actions: [FinalizationMachine.Action]) -> Int {
        actions.reduce(0) { total, action in
            if case .grantSummary(let count) = action { return total + count }
            return total
        }
    }

    // MARK: - Progress

    /// One clamped, monotonic fraction from the running pass. Forward-only
    /// and scoped to the meeting that is actually decoding, so a straggler
    /// from a preempted pass cannot move another meeting's bar.
    func noteProgress(_ fraction: Double, for meetingID: UUID) {
        guard meetingID == currentMeetingID, fraction > (progress ?? -1) else { return }
        progress = fraction
        publish()
    }

    // MARK: - Action execution

    private func run(_ actions: [FinalizationMachine.Action]) {
        publishMachineState()
        for action in actions {
            switch action {
            case .startPass(let meetingID, let attempt):
                startPass(meetingID, attempt: attempt)
            case .converge(let meetingID):
                let converge = convergeTerminally
                Task { @MainActor in await converge(meetingID) }
            case .grantSummary(let count):
                let waiting = summaryWaiters.prefix(count)
                summaryWaiters.removeFirst(min(count, summaryWaiters.count))
                for continuation in waiting { continuation.resume() }
            }
        }
    }

    private func startPass(_ meetingID: UUID, attempt: Int) {
        publishMachineState()
        Self.log.info(
            """
            Finalization pass \(attempt, privacy: .public) for \
            \(meetingID.uuidString, privacy: .public)
            """)
        // The signal is read off the main actor, once per decode window; the
        // closure captures it rather than this object so the decode loop
        // never reaches back into the driver.
        let signal = preemption
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.prepareForPass()
            let result = await self.runPass(meetingID, { signal.isRaised })
            self.concludePass(meetingID, result: result)
        }
    }

    private func concludePass(_ meetingID: UUID, result: PassResult) {
        // Read before `resolveStopAwaiter` clears the interest: whether this
        // pass belonged to a stop is what decides who owns its summary.
        let wasStopPass = stopInterest.contains(meetingID)
        let conclusion: FinalizationMachine.Conclusion
        switch result {
        case .replaced: conclusion = .success
        case .failed: conclusion = .failure
        case .preempted: conclusion = .preempted
        }
        let actions = machine.handle(.passConcluded(conclusion))
        // Resolved before the actions run, so a stop awaiter learns its
        // outcome before the next pass is started under it.
        resolveStopAwaiter(meetingID, result: result)
        run(actions)
        // Only for a pass nobody is awaiting. A stop pass's summary is
        // sequenced inside its own post-stop pipeline, and announcing it here
        // too would put two schedulers on the same meeting.
        guard !wasStopPass else { return }
        let concluded = onBackgroundPassConcluded
        Task { @MainActor in await concluded(meetingID, result) }
    }

    /// Resolves the awaited stop outcome, if this meeting's stop is waiting.
    ///
    /// The one non-obvious case: a non-terminal failure whose retry has
    /// ALREADY started leaves the awaiter suspended on purpose. Resuming it
    /// would close the post-stop pipeline while the retry is still decoding,
    /// which is precisely what lets deferred passes in ahead of it.
    private func resolveStopAwaiter(_ meetingID: UUID, result: PassResult) {
        guard stopInterest.contains(meetingID) else { return }
        let outcome: StopOutcome
        switch result {
        case .replaced(let segments):
            outcome = .replaced(segments)
        case .preempted:
            outcome = .deferred
        case .failed:
            if machine.terminalMeetingIDs.contains(meetingID) {
                outcome = .failed
            } else if machine.runningMeetingID == meetingID {
                return
            } else {
                outcome = .deferred
            }
        }
        stopInterest.remove(meetingID)
        if let continuation = stopAwaiters.removeValue(forKey: meetingID) {
            continuation.resume(returning: outcome)
        } else {
            settledStopOutcomes[meetingID] = outcome
        }
    }

    /// Republishes what the UI reads, and resets the bar when the running
    /// ATTEMPT changes — a retry of the same meeting is a new bar, not a
    /// continuation of the one that failed.
    private func publishMachineState() {
        let key = machine.runningMeetingID.map {
            PassKey(meetingID: $0, attempt: machine.runningAttempt)
        }
        let changed = key != publishedPass
        publishedPass = key
        currentMeetingID = machine.runningMeetingID
        if changed {
            progress = machine.runningMeetingID == nil ? nil : 0
        }
        publish()
    }

    private func publish() {
        onStateChanged(
            Snapshot(
                meetingID: currentMeetingID,
                progress: progress,
                queued: machine.queue,
                terminalFailures: machine.terminalMeetingIDs
            ))
    }
}
