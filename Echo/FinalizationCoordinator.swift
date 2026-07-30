//
//  FinalizationCoordinator.swift
//  Echo
//
//  SP-005 S4: finalization lifecycle & admission (ADR-014 + ADR-016).
//
//  `FinalizationMachine` is the pure, table-testable admission rule: at most
//  ONE final pass at a time; no pass decode while a recording is active or a
//  post-stop pipeline (pass → summary) is still running; summary work and
//  passes never overlap (beyond the always-resident live speech model, at
//  most one heavyweight is ever in memory — ADR-014). Pending meetings
//  process newest-first, with the just-stopped meeting's own pass
//  front-running the deferred queue.
//
//  Retry design (ADR-016): max 2 attempts per meeting per app run; a
//  preemption is a deferral, never an attempt. ADR-016 rejects persisted
//  state files, so no attempt counter survives the process — instead
//  "attempts exhausted in this run" is TERMINAL: the retained audio is
//  deleted, the live floor stands with an honest notice, and the summary
//  generates from the floor. Per-run bounding + terminal-on-exhaustion keeps
//  failure convergent across launches (a run either converges or is quit
//  mid-pass — and a mid-pass quit leaves the audio, so the next launch
//  resumes with a fresh budget; the audio is the checkpoint).
//
//  `FinalizationCoordinator` is the thin main-actor driver: it feeds events
//  into the machine, executes the emitted actions through injected closures
//  (the real pass, summary-model release, terminal cleanup), and resolves the
//  stop path's awaited outcome.
//

import Foundation
import Observation
import os

// MARK: - Pure admission machine (SP-005 Testing Decisions, layer 1)

nonisolated struct FinalizationMachine: Sendable {

    /// Pass attempts per meeting per app run (ADR-016 bounded retries). A
    /// resume at the next launch counts fresh — the retained audio, not a
    /// persisted counter, is the checkpoint.
    static let maxAttemptsPerRun = 2

    enum Conclusion: Equatable, Sendable {
        case success
        case failure
        /// `shouldYield` stopped the pass between decode windows (a recording
        /// started). A deferral — consumes no attempt.
        case preempted
    }

    enum Event: Equatable, Sendable {
        /// A pending meeting wants a pass (launch resume). Appends to the
        /// back, so callers requesting newest-first keep the queue newest-first.
        case passRequested(UUID)
        /// The just-stopped meeting's own pass: front of the queue, and the
        /// only pass admitted while its post-stop pipeline holds the gate.
        case stopPassRequested(UUID)
        /// The running pass ended.
        case passConcluded(Conclusion)
        case recordingStarted
        /// Recording ended and its post-stop pipeline (pass → summary) began.
        /// Deferred passes stay held until `pipelineFinished` — they resume
        /// behind the new meeting's own post-stop work (ADR-014).
        case recordingStopped
        /// The post-stop pipeline finished (summary done or abandoned).
        case pipelineFinished
        /// Summary work wants to run. Granted only while no pass decodes;
        /// while requested or granted, no new pass starts.
        case summaryRequested
        case summaryEnded
    }

    enum Action: Equatable, Sendable {
        case startPass(meetingID: UUID, attempt: Int)
        /// Retries exhausted this run (ADR-016 terminal convergence): delete
        /// the retained audio, log honestly; the summary generates from the
        /// live floor.
        case converge(meetingID: UUID)
        /// Resume `count` waiting summary-work requests.
        case grantSummary(count: Int)
    }

    private(set) var isRecording = false
    /// Open post-stop pipelines. A count, not a flag: a new recording can
    /// start (and stop) while an older pipeline is still winding down.
    private(set) var pipelineCount = 0
    /// The meeting whose post-stop pipeline opened most recently — the one
    /// pass admitted while any pipeline is open.
    private(set) var pipelineMeetingID: UUID?
    /// Pending passes, front = next. Newest-first by construction: launch
    /// resume requests newest-first (appends), preempted/retrying meetings
    /// re-enter at the front they came from, and the just-stopped meeting
    /// inserts at the very front.
    private(set) var queue: [UUID] = []
    private(set) var runningMeetingID: UUID?
    private(set) var runningAttempt = 0
    /// Failed attempts consumed per meeting this run (preemptions excluded).
    private var failedAttempts: [UUID: Int] = [:]
    private(set) var summaryWaiting = 0
    private(set) var summaryActive = 0
    /// Meetings whose finalization converged terminally this run — never
    /// re-admitted within the run (in-memory only; ADR-016 persists nothing).
    private(set) var terminalMeetingIDs: Set<UUID> = []

    /// A pass is running or pending — the coordinator's "not idle" signal
    /// (defers the optional model download; surfaces the finalizing UI).
    var isBusy: Bool { runningMeetingID != nil || !queue.isEmpty }

    mutating func handle(_ event: Event) -> [Action] {
        switch event {
        case .passRequested(let id):
            guard runningMeetingID != id, !queue.contains(id),
                  !terminalMeetingIDs.contains(id) else { return [] }
            queue.append(id)
            return maybeStartPass()

        case .stopPassRequested(let id):
            pipelineMeetingID = id
            guard runningMeetingID != id, !queue.contains(id),
                  !terminalMeetingIDs.contains(id) else { return maybeStartPass() }
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
                // A deferral, not an attempt (ADR-014): back to the front it
                // came from, so newest-first order is preserved and the
                // retained audio stays the untouched pending marker.
                queue.insert(id, at: 0)
            }
            runningAttempt = 0
            // Waiting summary work wins over the next queued pass: the pass
            // that just ended is what it was waiting for.
            return actions + (grantSummaryIfPossible() ?? maybeStartPass())

        case .recordingStarted:
            // The coordinator's preemption signal makes the running pass
            // yield within one decode window; the machine only closes the
            // admission gate here.
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
        }
    }

    /// Grants every waiting summary request the moment no pass is decoding.
    /// Summary-vs-summary serialization is not this machine's job (the model
    /// manager's work count owns that); this gate only keeps summary work and
    /// pass decodes from ever overlapping (ADR-014).
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
              let next = queue.first else { return [] }
        // While a post-stop pipeline is open, only its own meeting's pass may
        // run — deferred work resumes behind the new meeting's pass AND its
        // summary (ADR-014 "behind the new meeting's own post-stop pipeline").
        if pipelineCount > 0 && next != pipelineMeetingID { return [] }
        queue.removeFirst()
        runningMeetingID = next
        runningAttempt = failedAttempts[next, default: 0] + 1
        return [.startPass(meetingID: next, attempt: runningAttempt)]
    }
}

// MARK: - Preemption signal

/// The recording-start flag a running pass's `shouldYield` closure reads
/// before every decode window (ADR-014 "yields within one decode window").
/// Lock-guarded because the decode loop reads it off the main actor while the
/// coordinator raises/lowers it on the main actor (the diagnostics-sink
/// pattern); the per-window cost is one uncontended lock acquisition.
nonisolated final class FinalizationPreemptionSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var raised = false

    var isRaised: Bool {
        lock.lock()
        defer { lock.unlock() }
        return raised
    }

    func raise() {
        lock.lock()
        defer { lock.unlock() }
        raised = true
    }

    func lower() {
        lock.lock()
        defer { lock.unlock() }
        raised = false
    }
}

// MARK: - Coordinator

@Observable
@MainActor
final class FinalizationCoordinator {

    static let log = Logger(subsystem: "com.sancrisoft.Echo", category: "FinalizationCoordinator")

    /// Outcome of the just-stopped meeting's own pass, awaited by the stop
    /// path so the summary grounds in the best transcript the meeting has.
    enum StopOutcome: Equatable {
        /// The pass succeeded and the transcript was replaced — summarize these.
        case replaced([TranscriptSegment])
        /// Retries exhausted (terminal, ADR-016): summarize the live floor.
        case floorStands
        /// A new recording preempted the pass (or blocked its retry): the
        /// meeting stays pending, its pass resumes after stop, and the
        /// summary follows THAT pass — the stop path does nothing more.
        case deferred
    }

    /// What one pass attempt produced, reported by the injected runner. The
    /// runner owns the mechanics (decode, atomic replace, success cleanup);
    /// the coordinator owns admission and retries.
    enum PassResult {
        case replaced([TranscriptSegment])
        case failed
        case preempted
    }

    typealias PassRunner =
        @MainActor (UUID, _ shouldYield: @escaping @Sendable () -> Bool) async -> PassResult

    // Injected work, assigned once by RecordingController at init (tests
    // assign fakes). Defaults are inert so an unwired coordinator fails
    // passes honestly instead of crashing.
    var runPass: PassRunner = { _, _ in .failed }
    /// Runs before every pass starts: release any idle-warm summary model so
    /// it is never resident while a pass decodes (ADR-014 admission).
    var prepareForPass: @MainActor () async -> Void = {}
    /// Terminal convergence (ADR-016): delete exactly this meeting's retained
    /// audio — the pending marker — so the meeting reads final.
    var convergeTerminally: @MainActor (UUID) async -> Void = { _ in }
    /// A pass concluded outside a stop path's await (launch-resumed or
    /// deferred work): the meeting is summary-eligible now — kick the backfill.
    var onPassConcluded: @MainActor (UUID) -> Void = { _ in }

    private var machine = FinalizationMachine()
    private let preemption = FinalizationPreemptionSignal()
    private var stopAwaiters: [UUID: CheckedContinuation<StopOutcome, Never>] = [:]
    private var summaryWaiters: [CheckedContinuation<Void, Never>] = []

    // Observable surface for the finalizing UI (S6): what is running, what is
    // queued, and which meetings converged terminally this run (the honest,
    // non-blocking failure notice — in-memory by design, ADR-016).
    private(set) var currentMeetingID: UUID?
    private(set) var queuedMeetingIDs: [UUID] = []
    private(set) var terminalFailureIDs: Set<UUID> = []

    var isBusy: Bool { machine.isBusy }

    // MARK: Recording lifecycle signals

    func noteRecordingStarted() {
        preemption.raise()
        apply(machine.handle(.recordingStarted))
    }

    /// Recording ended; its post-stop pipeline begins. EVERY stop path must
    /// balance this with exactly one `notePostStopWorkFinished()`.
    func noteRecordingStopped() {
        preemption.lower()
        apply(machine.handle(.recordingStopped))
    }

    /// The post-stop pipeline (pass → summary, or its early exit) is done —
    /// deferred passes may resume.
    func notePostStopWorkFinished() {
        apply(machine.handle(.pipelineFinished))
    }

    // MARK: Pass entry points

    /// Launch-time resume: enqueue pending meetings, newest first (the
    /// caller's order is preserved). Fire-and-forget — passes run one at a
    /// time under the admission rule.
    func requestResume(of meetingIDs: [UUID]) {
        for id in meetingIDs {
            apply(machine.handle(.passRequested(id)))
        }
    }

    /// The just-stopped meeting's own pass: front-runs the deferred queue and
    /// resolves when the meeting genuinely concludes this pipeline — success,
    /// terminal failure, or deferral to a later resume.
    func finalizeStopped(_ meetingID: UUID) async -> StopOutcome {
        await withCheckedContinuation { continuation in
            stopAwaiters[meetingID] = continuation
            apply(machine.handle(.stopPassRequested(meetingID)))
        }
    }

    // MARK: Summary admission (ADR-014)

    /// Waits until no pass is decoding, then holds pass admission until the
    /// matching `endSummaryWork()`. Every summary-engine acquisition must be
    /// wrapped in this pair — it is what keeps the summary model and a final
    /// pass from ever being resident together.
    func beginSummaryWork() async {
        await withCheckedContinuation { continuation in
            summaryWaiters.append(continuation)
            apply(machine.handle(.summaryRequested))
        }
    }

    func endSummaryWork() {
        apply(machine.handle(.summaryEnded))
    }

    // MARK: Machine driving

    private func apply(_ actions: [FinalizationMachine.Action]) {
        for action in actions {
            switch action {
            case .startPass(let meetingID, let attempt):
                startPass(meetingID, attempt: attempt)
            case .converge(let meetingID):
                converge(meetingID)
            case .grantSummary(let count):
                let granted = summaryWaiters.prefix(count)
                summaryWaiters.removeFirst(min(count, summaryWaiters.count))
                for waiter in granted { waiter.resume() }
            }
        }
        publishMachineState()
    }

    private func startPass(_ meetingID: UUID, attempt: Int) {
        Self.log.info("""
        Final pass starting for meeting \(meetingID.uuidString, privacy: .public) \
        (attempt \(attempt, privacy: .public))
        """)
        let signal = preemption
        Task { [weak self] in
            guard let self else { return }
            await self.prepareForPass()
            let result = await self.runPass(meetingID) { signal.isRaised }
            self.concludePass(meetingID, result: result)
        }
    }

    private func concludePass(_ meetingID: UUID, result: PassResult) {
        let conclusion: FinalizationMachine.Conclusion
        switch result {
        case .replaced: conclusion = .success
        case .failed: conclusion = .failure
        case .preempted: conclusion = .preempted
        }
        let actions = machine.handle(.passConcluded(conclusion))
        let converged = actions.contains(.converge(meetingID: meetingID))
        apply(actions)   // may start the retry, grant summary work, or start the next pass

        if stopAwaiters[meetingID] != nil {
            resolveStopAwaiter(meetingID, result: result, converged: converged)
        } else if case .replaced = result {
            // Launch-resumed / deferred pass succeeded: the meeting is no
            // longer pending, so the backfill may summarize it now. (Terminal
            // conclusions kick from `converge`, after the audio deletion that
            // clears the pending marker.)
            onPassConcluded(meetingID)
        }
    }

    private func resolveStopAwaiter(_ meetingID: UUID, result: PassResult, converged: Bool) {
        let outcome: StopOutcome
        switch result {
        case .replaced(let segments):
            outcome = .replaced(segments)
        case .failed where converged:
            outcome = .floorStands
        case .failed:
            // A retry is owed. If it started right away, keep waiting for its
            // conclusion; if admission blocked it (a new recording), resolve
            // as deferred so the stop pipeline can close — the meeting stays
            // queued and pending, and `onPassConcluded` follows its eventual
            // pass instead.
            guard machine.runningMeetingID != meetingID else { return }
            outcome = .deferred
        case .preempted:
            outcome = .deferred
        }
        stopAwaiters.removeValue(forKey: meetingID)?.resume(returning: outcome)
    }

    private func converge(_ meetingID: UUID) {
        Self.log.error("""
        Finalization retries exhausted for meeting \(meetingID.uuidString, privacy: .public) — \
        live transcript stands, retained audio deleted (terminal, ADR-016)
        """)
        // Captured now: `converge` runs before the stop awaiter (if any) is
        // resolved, and an awaited meeting's summary comes from its own stop
        // pipeline — only unawaited (launch-resumed) conclusions kick the
        // backfill, and only after the deletion clears the pending marker.
        let awaited = stopAwaiters[meetingID] != nil
        Task { [weak self] in
            guard let self else { return }
            await self.convergeTerminally(meetingID)
            if !awaited {
                self.onPassConcluded(meetingID)
            }
        }
    }

    private func publishMachineState() {
        currentMeetingID = machine.runningMeetingID
        queuedMeetingIDs = machine.queue
        terminalFailureIDs = machine.terminalMeetingIDs
    }
}
