//
//  FinalizationLifecycleTests.swift
//  EchoTests
//
//  SP-005 S4: the finalization admission machine (ADR-014) and its retry /
//  terminal-convergence rules (ADR-016), as pure event tables (the
//  EchoHandlingModeTests style), plus the coordinator's awaited stop outcome
//  and seams driven through scripted closures.
//

import Foundation
import Testing
@testable import Echo

// MARK: - Pure machine tables

@Suite("Finalization admission machine")
struct FinalizationMachineTests {

    private let meeting = UUID()
    private let older = UUID()

    /// A machine mid-way through a stop pipeline with `meeting`'s pass running.
    private func machineWithRunningStopPass() -> FinalizationMachine {
        var machine = FinalizationMachine()
        _ = machine.handle(.recordingStarted)
        _ = machine.handle(.recordingStopped)
        let actions = machine.handle(.stopPassRequested(meeting))
        #expect(actions == [.startPass(meetingID: meeting, attempt: 1)])
        return machine
    }

    @Test func happyPathStopPassStartsAndConcludes() {
        var machine = machineWithRunningStopPass()
        #expect(machine.isBusy)

        #expect(machine.handle(.passConcluded(.success)) == [])
        #expect(!machine.isBusy)
        #expect(machine.handle(.pipelineFinished) == [])
    }

    @Test func failureRetriesImmediatelyThenSucceeds() {
        var machine = machineWithRunningStopPass()

        // First failure consumes attempt 1; the retry starts right away.
        #expect(machine.handle(.passConcluded(.failure))
            == [.startPass(meetingID: meeting, attempt: 2)])

        #expect(machine.handle(.passConcluded(.success)) == [])
        #expect(machine.terminalMeetingIDs.isEmpty)
    }

    @Test func retriesExhaustedConvergeTerminally() {
        var machine = machineWithRunningStopPass()
        _ = machine.handle(.passConcluded(.failure))   // attempt 1 → retry (attempt 2)

        // Attempt 2 fails: retries exhausted this run — terminal (ADR-016).
        #expect(machine.handle(.passConcluded(.failure)) == [.converge(meetingID: meeting)])
        #expect(!machine.isBusy)
        #expect(machine.terminalMeetingIDs == [meeting])

        // Terminal means terminal: the meeting is never re-admitted this run.
        _ = machine.handle(.pipelineFinished)
        #expect(machine.handle(.passRequested(meeting)) == [])
        #expect(!machine.isBusy)
    }

    @Test func preemptionConsumesNoAttempt() {
        var machine = machineWithRunningStopPass()
        _ = machine.handle(.passConcluded(.failure))   // attempt 1 consumed, attempt 2 running

        // A recording preempts attempt 2 — a deferral, not a failure.
        _ = machine.handle(.recordingStarted)
        #expect(machine.handle(.passConcluded(.preempted)) == [])
        #expect(machine.queue == [meeting])
        // The preempted stop pipeline resolves as deferred and closes.
        _ = machine.handle(.pipelineFinished)

        // After the (empty) new session's pipeline closes, the pass resumes
        // still on attempt 2 — the preemption cost nothing.
        _ = machine.handle(.recordingStopped)
        #expect(machine.handle(.pipelineFinished)
            == [.startPass(meetingID: meeting, attempt: 2)])
    }

    @Test func passNeverStartsWhileRecording() {
        var machine = FinalizationMachine()
        _ = machine.handle(.recordingStarted)

        // A launch-resumed request during a recording only queues.
        #expect(machine.handle(.passRequested(meeting)) == [])
        #expect(machine.queue == [meeting])

        // Stop opens the post-stop pipeline: deferred work still waits
        // (ADR-014 — behind the new meeting's own post-stop pipeline).
        #expect(machine.handle(.recordingStopped) == [])
        #expect(machine.handle(.pipelineFinished)
            == [.startPass(meetingID: meeting, attempt: 1)])
    }

    @Test func stopPassFrontRunsTheDeferredQueue() {
        var machine = FinalizationMachine()
        _ = machine.handle(.recordingStarted)
        _ = machine.handle(.passRequested(older))      // deferred while recording
        _ = machine.handle(.recordingStopped)

        // The just-stopped meeting's own pass is admitted first, even though
        // the older meeting was queued before it.
        #expect(machine.handle(.stopPassRequested(meeting))
            == [.startPass(meetingID: meeting, attempt: 1)])
        _ = machine.handle(.passConcluded(.success))

        // The deferred meeting waits for the whole pipeline (pass → summary).
        #expect(machine.handle(.pipelineFinished)
            == [.startPass(meetingID: older, attempt: 1)])
    }

    @Test func recordingMidPassDefersAndResumesNewestFirst() {
        var machine = machineWithRunningStopPass()
        _ = machine.handle(.pipelineFinished)          // stop pipeline closed early (deferred)

        // Recording starts mid-pass; the pass yields and is re-queued front.
        _ = machine.handle(.recordingStarted)
        #expect(machine.handle(.passConcluded(.preempted)) == [])
        #expect(machine.queue == [meeting])

        // The new meeting stops: its own pass first, then the deferred one.
        _ = machine.handle(.recordingStopped)
        let newMeeting = UUID()
        #expect(machine.handle(.stopPassRequested(newMeeting))
            == [.startPass(meetingID: newMeeting, attempt: 1)])
        #expect(machine.queue == [meeting])
        _ = machine.handle(.passConcluded(.success))
        #expect(machine.handle(.pipelineFinished)
            == [.startPass(meetingID: meeting, attempt: 1)])
    }

    @Test func queueProcessesRequestsInOrderOneAtATime() {
        var machine = FinalizationMachine()
        let newest = UUID()
        // The launch scan requests newest-first; request order is queue order.
        #expect(machine.handle(.passRequested(newest))
            == [.startPass(meetingID: newest, attempt: 1)])
        #expect(machine.handle(.passRequested(older)) == [])
        #expect(machine.queue == [older])

        #expect(machine.handle(.passConcluded(.success))
            == [.startPass(meetingID: older, attempt: 1)])
    }

    @Test func duplicateRequestsAreIgnored() {
        var machine = FinalizationMachine()
        _ = machine.handle(.recordingStarted)
        _ = machine.handle(.passRequested(meeting))
        #expect(machine.handle(.passRequested(meeting)) == [])
        #expect(machine.queue == [meeting])
    }

    @Test func summaryWorkWaitsForTheRunningPass() {
        var machine = machineWithRunningStopPass()

        // Requested while a pass decodes: not granted yet (ADR-014).
        #expect(machine.handle(.summaryRequested) == [])
        #expect(machine.summaryWaiting == 1)

        // The pass concluding grants the summary INSTEAD of starting the next
        // queued pass.
        _ = machine.handle(.passRequested(older))
        #expect(machine.handle(.passConcluded(.success)) == [.grantSummary(count: 1)])
        #expect(machine.queue == [older])

        // Only the summary ending lets the queue move again.
        _ = machine.handle(.pipelineFinished)
        #expect(machine.handle(.summaryEnded)
            == [.startPass(meetingID: older, attempt: 1)])
    }

    @Test func passNeverStartsWhileSummaryWorkIsActive() {
        var machine = FinalizationMachine()
        #expect(machine.handle(.summaryRequested) == [.grantSummary(count: 1)])

        #expect(machine.handle(.passRequested(meeting)) == [])
        #expect(machine.handle(.summaryEnded)
            == [.startPass(meetingID: meeting, attempt: 1)])
    }

    @Test func manualRetryReadmitsTerminalMeetingFrontOfQueueWithFreshBudget() {
        var machine = machineWithRunningStopPass()
        _ = machine.handle(.passConcluded(.failure))   // attempt 1 → retry
        _ = machine.handle(.passConcluded(.failure))   // attempt 2 → terminal
        _ = machine.handle(.pipelineFinished)
        #expect(machine.terminalMeetingIDs == [meeting])

        // While a recording runs, the user's Retry only queues — at the
        // FRONT, ahead of a meeting queued before it (the user-request
        // discipline, ADR-024) — and clears the terminal exclusion.
        _ = machine.handle(.recordingStarted)
        _ = machine.handle(.passRequested(older))
        #expect(machine.handle(.manualRetryRequested(meeting)) == [])
        #expect(machine.queue == [meeting, older])
        #expect(machine.terminalMeetingIDs.isEmpty)

        // The retry bypasses no admission gate: it starts only after the
        // recording stops AND its post-stop pipeline closes — on a FRESH
        // attempt 1, the exhausted budget forgotten.
        #expect(machine.handle(.recordingStopped) == [])
        #expect(machine.handle(.pipelineFinished)
            == [.startPass(meetingID: meeting, attempt: 1)])
    }

    @Test func manualRetryCycleThatConvergesAgainReturnsToTerminal() {
        var machine = machineWithRunningStopPass()
        _ = machine.handle(.passConcluded(.failure))
        _ = machine.handle(.passConcluded(.failure))   // terminal
        _ = machine.handle(.pipelineFinished)

        // The Retry re-admits immediately (nothing else gates it).
        #expect(machine.handle(.manualRetryRequested(meeting))
            == [.startPass(meetingID: meeting, attempt: 1)])

        // The fresh cycle keeps ADR-016's bounded retries…
        #expect(machine.handle(.passConcluded(.failure))
            == [.startPass(meetingID: meeting, attempt: 2)])
        // …and a second convergence is terminal again — nothing loops
        // automatically; only the user starts another cycle.
        #expect(machine.handle(.passConcluded(.failure)) == [.converge(meetingID: meeting)])
        #expect(machine.terminalMeetingIDs == [meeting])
        #expect(machine.handle(.passRequested(meeting)) == [])
    }

    @Test func manualRetryOfNonTerminalMeetingEnqueuesNormally() {
        // A meeting terminal only ON DISK (a relaunch: the in-memory terminal
        // set died with the process) has no exclusion to clear — the Retry is
        // a normal front-of-queue admission on attempt 1.
        var machine = FinalizationMachine()
        #expect(machine.handle(.manualRetryRequested(meeting))
            == [.startPass(meetingID: meeting, attempt: 1)])

        // Retrying the meeting whose pass is already running is a no-op —
        // the running attempt IS the retry the user asked for.
        #expect(machine.handle(.manualRetryRequested(meeting)) == [])
        #expect(machine.queue.isEmpty)
        #expect(machine.runningMeetingID == meeting)
    }

    @Test func attemptBudgetIsPerMeeting() {
        var machine = FinalizationMachine()
        // `meeting` exhausts its budget…
        _ = machine.handle(.passRequested(meeting))
        _ = machine.handle(.passConcluded(.failure))
        #expect(machine.handle(.passConcluded(.failure)) == [.converge(meetingID: meeting)])

        // …which costs `older` nothing: it starts on a fresh attempt 1.
        #expect(machine.handle(.passRequested(older))
            == [.startPass(meetingID: older, attempt: 1)])
    }
}

// MARK: - Coordinator (scripted seams)

@Suite("Finalization coordinator")
@MainActor
struct FinalizationCoordinatorTests {

    /// Scripted pass results, consumed in order; records every call.
    @MainActor
    private final class ScriptedRunner {
        var results: [FinalizationCoordinator.PassResult]
        private(set) var calledMeetingIDs: [UUID] = []

        init(_ results: [FinalizationCoordinator.PassResult]) {
            self.results = results
        }

        func run(_ id: UUID, shouldYield: @escaping @Sendable () -> Bool) -> FinalizationCoordinator.PassResult {
            calledMeetingIDs.append(id)
            return results.isEmpty ? .failed : results.removeFirst()
        }
    }

    /// Holds entered passes until the test releases them.
    @MainActor
    private final class PassGate {
        private var waiters: [CheckedContinuation<Void, Never>] = []
        private(set) var entered = 0

        func enter() async {
            entered += 1
            await withCheckedContinuation { waiters.append($0) }
        }

        func releaseAll() {
            let released = waiters
            waiters = []
            for waiter in released { waiter.resume() }
        }
    }

    private func segments() -> [TranscriptSegment] {
        [TranscriptSegment(channel: .microphone, speaker: .me, text: "final", start: 0, end: 1)]
    }

    /// Enters a stop pipeline (recording started and stopped) so
    /// `finalizeStopped` runs under the same gates as production.
    private func enterStopPipeline(_ coordinator: FinalizationCoordinator) {
        coordinator.noteRecordingStarted()
        coordinator.noteRecordingStopped()
    }

    @Test func happyPathReplacesAndReleasesSummaryModelFirst() async {
        let coordinator = FinalizationCoordinator()
        let meeting = UUID()
        let final = segments()
        let order = OrderLog()
        coordinator.prepareForPass = { order.append("prepare") }
        coordinator.runPass = { _, _ in
            order.append("pass")
            return .replaced(final)
        }
        enterStopPipeline(coordinator)

        let outcome = await coordinator.finalizeStopped(meeting)

        #expect(outcome == .replaced(final))
        // ADR-014: the summary model is released before the first decode.
        #expect(order.entries == ["prepare", "pass"])
        #expect(!coordinator.isBusy)
        coordinator.notePostStopWorkFinished()
    }

    @Test func failureRetriesOnceThenSucceeds() async {
        let coordinator = FinalizationCoordinator()
        let meeting = UUID()
        let final = segments()
        let runner = ScriptedRunner([.failed, .replaced(final)])
        coordinator.runPass = { id, yield in runner.run(id, shouldYield: yield) }
        enterStopPipeline(coordinator)

        let outcome = await coordinator.finalizeStopped(meeting)

        #expect(outcome == .replaced(final))
        #expect(runner.calledMeetingIDs == [meeting, meeting])
        #expect(coordinator.terminalFailureIDs.isEmpty)
        coordinator.notePostStopWorkFinished()
    }

    @Test func exhaustedRetriesConvergeTerminally() async {
        let coordinator = FinalizationCoordinator()
        let meeting = UUID()
        let runner = ScriptedRunner([.failed, .failed])
        let converged = OrderLog()
        coordinator.runPass = { id, yield in runner.run(id, shouldYield: yield) }
        coordinator.convergeTerminally = { id in converged.append(id.uuidString) }
        enterStopPipeline(coordinator)

        let outcome = await coordinator.finalizeStopped(meeting)

        #expect(outcome == .failed)
        #expect(runner.calledMeetingIDs.count == 2)
        // The honest in-memory notice, and the retained-audio deletion seam.
        #expect(coordinator.terminalFailureIDs == [meeting])
        while converged.entries.isEmpty { await Task.yield() }
        #expect(converged.entries == [meeting.uuidString])
        #expect(!coordinator.isBusy)
        coordinator.notePostStopWorkFinished()
    }

    @Test func manualRetryRunsAFreshCycleAfterTerminalConvergence() async {
        let coordinator = FinalizationCoordinator()
        let meeting = UUID()
        let final = segments()
        let runner = ScriptedRunner([.failed, .failed, .replaced(final)])
        let concluded = OrderLog()
        coordinator.runPass = { id, yield in runner.run(id, shouldYield: yield) }
        coordinator.onPassConcluded = { id in concluded.append(id.uuidString) }
        enterStopPipeline(coordinator)

        let outcome = await coordinator.finalizeStopped(meeting)
        #expect(outcome == .failed)
        #expect(coordinator.terminalFailureIDs == [meeting])
        coordinator.notePostStopWorkFinished()

        // The user's Retry (ADR-024): a fresh bounded cycle for the same
        // meeting, clearing the in-memory terminal notice.
        coordinator.requestManualRetry(meeting)
        #expect(coordinator.terminalFailureIDs.isEmpty)

        // No stop awaiter this time — the retry's success kicks the
        // backfill, exactly like a launch-resumed pass.
        while concluded.entries.isEmpty { await Task.yield() }
        #expect(concluded.entries == [meeting.uuidString])
        #expect(runner.calledMeetingIDs == [meeting, meeting, meeting])
        #expect(!coordinator.isBusy)
    }

    @Test func recordingMidStopPassDefersAndResumesAfterStop() async {
        let coordinator = FinalizationCoordinator()
        let meeting = UUID()
        let final = segments()
        let gate = PassGate()
        let concluded = OrderLog()
        coordinator.runPass = { _, shouldYield in
            await gate.enter()
            // The pass loop checks the signal before every decode window.
            return shouldYield() ? .preempted : .replaced(final)
        }
        coordinator.onPassConcluded = { id in concluded.append(id.uuidString) }
        enterStopPipeline(coordinator)

        async let outcome = coordinator.finalizeStopped(meeting)
        while gate.entered < 1 { await Task.yield() }
        // A new recording starts mid-pass: the yield signal preempts it.
        coordinator.noteRecordingStarted()
        gate.releaseAll()

        #expect(await outcome == .deferred)
        // Deferred, not failed: still queued (front) with its audio untouched.
        #expect(coordinator.queuedMeetingIDs == [meeting])
        coordinator.notePostStopWorkFinished()   // the old pipeline closes

        // After the new session stops and its (empty) pipeline finishes, the
        // deferred pass resumes and — with no stop awaiter — kicks the
        // backfill for its summary.
        coordinator.noteRecordingStopped()
        coordinator.notePostStopWorkFinished()
        while gate.entered < 2 { await Task.yield() }
        gate.releaseAll()
        while concluded.entries.isEmpty { await Task.yield() }
        #expect(concluded.entries == [meeting.uuidString])
        #expect(!coordinator.isBusy)
    }

    @Test func summaryWorkIsGatedWhileAPassRuns() async {
        let coordinator = FinalizationCoordinator()
        let meeting = UUID()
        let gate = PassGate()
        let order = OrderLog()
        coordinator.runPass = { _, _ in
            await gate.enter()
            order.append("pass-finished")
            return .replaced(self.segments())
        }
        coordinator.requestResume(of: [meeting])
        while gate.entered < 1 { await Task.yield() }

        let summaryTask = Task { @MainActor in
            await coordinator.beginSummaryWork()
            order.append("summary-granted")
        }
        // The request must not be granted while the pass is decoding.
        for _ in 0..<20 { await Task.yield() }
        #expect(order.entries.isEmpty)

        gate.releaseAll()
        await summaryTask.value
        #expect(order.entries == ["pass-finished", "summary-granted"])
        coordinator.endSummaryWork()
    }

    @Test func launchResumeRunsOneMeetingAtATimeInRequestOrder() async {
        let coordinator = FinalizationCoordinator()
        let newest = UUID()
        let older = UUID()
        let runner = ScriptedRunner([.replaced(segments()), .replaced(segments())])
        coordinator.runPass = { id, yield in runner.run(id, shouldYield: yield) }

        coordinator.requestResume(of: [newest, older])
        while coordinator.isBusy { await Task.yield() }

        #expect(runner.calledMeetingIDs == [newest, older])
    }
}

/// Main-actor ordering log for the coordinator tests (avoids captured-var
/// warnings in escaping closures).
@MainActor
private final class OrderLog {
    private(set) var entries: [String] = []
    func append(_ entry: String) { entries.append(entry) }
}
