//
//  FinalizationMachineTests.swift
//  RecordingTests
//
//  The finalization admission machine and its retry / terminal-convergence
//  rules, as pure event tables — events in, actions out, no clock and no I/O.
//
//  Ported from the PoC's `FinalizationLifecycleTests` unchanged in substance
//  (ADR-006: the machine was already table-tested there, so the tests come
//  across with it). Only the import moved and the PoC's `nonisolated` noise
//  went away: this package has no main-actor default for the machine to
//  escape from.
//
//  The preemption signal gets a suite of its own, which the PoC had none of:
//  it is the one piece of shared mutable state a decode loop reads off the
//  main actor while the driver writes it on the main actor.
//

import Foundation
import Testing

@testable import Recording

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
        #expect(
            machine.handle(.passConcluded(.failure))
                == [.startPass(meetingID: meeting, attempt: 2)])

        #expect(machine.handle(.passConcluded(.success)) == [])
        #expect(machine.terminalMeetingIDs.isEmpty)
    }

    @Test func retriesExhaustedConvergeTerminally() {
        var machine = machineWithRunningStopPass()
        _ = machine.handle(.passConcluded(.failure))  // attempt 1 → retry (attempt 2)

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
        _ = machine.handle(.passConcluded(.failure))  // attempt 1 consumed, attempt 2 running

        // A recording preempts attempt 2 — a deferral, not a failure.
        _ = machine.handle(.recordingStarted)
        #expect(machine.handle(.passConcluded(.preempted)) == [])
        #expect(machine.queue == [meeting])
        // The preempted stop pipeline resolves as deferred and closes.
        _ = machine.handle(.pipelineFinished)

        // After the (empty) new session's pipeline closes, the pass resumes
        // still on attempt 2 — the preemption cost nothing.
        _ = machine.handle(.recordingStopped)
        #expect(
            machine.handle(.pipelineFinished)
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
        #expect(
            machine.handle(.pipelineFinished)
                == [.startPass(meetingID: meeting, attempt: 1)])
    }

    @Test func stopPassFrontRunsTheDeferredQueue() {
        var machine = FinalizationMachine()
        _ = machine.handle(.recordingStarted)
        _ = machine.handle(.passRequested(older))  // deferred while recording
        _ = machine.handle(.recordingStopped)

        // The just-stopped meeting's own pass is admitted first, even though
        // the older meeting was queued before it.
        #expect(
            machine.handle(.stopPassRequested(meeting))
                == [.startPass(meetingID: meeting, attempt: 1)])
        _ = machine.handle(.passConcluded(.success))

        // The deferred meeting waits for the whole pipeline (pass → summary).
        #expect(
            machine.handle(.pipelineFinished)
                == [.startPass(meetingID: older, attempt: 1)])
    }

    @Test func recordingMidPassDefersAndResumesNewestFirst() {
        var machine = machineWithRunningStopPass()
        _ = machine.handle(.pipelineFinished)  // stop pipeline closed early (deferred)

        // Recording starts mid-pass; the pass yields and is re-queued front.
        _ = machine.handle(.recordingStarted)
        #expect(machine.handle(.passConcluded(.preempted)) == [])
        #expect(machine.queue == [meeting])

        // The new meeting stops: its own pass first, then the deferred one.
        _ = machine.handle(.recordingStopped)
        let newMeeting = UUID()
        #expect(
            machine.handle(.stopPassRequested(newMeeting))
                == [.startPass(meetingID: newMeeting, attempt: 1)])
        #expect(machine.queue == [meeting])
        _ = machine.handle(.passConcluded(.success))
        #expect(
            machine.handle(.pipelineFinished)
                == [.startPass(meetingID: meeting, attempt: 1)])
    }

    @Test func queueProcessesRequestsInOrderOneAtATime() {
        var machine = FinalizationMachine()
        let newest = UUID()
        // The launch scan requests newest-first; request order is queue order.
        #expect(
            machine.handle(.passRequested(newest))
                == [.startPass(meetingID: newest, attempt: 1)])
        #expect(machine.handle(.passRequested(older)) == [])
        #expect(machine.queue == [older])

        #expect(
            machine.handle(.passConcluded(.success))
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
        #expect(
            machine.handle(.summaryEnded)
                == [.startPass(meetingID: older, attempt: 1)])
    }

    @Test func passNeverStartsWhileSummaryWorkIsActive() {
        var machine = FinalizationMachine()
        #expect(machine.handle(.summaryRequested) == [.grantSummary(count: 1)])

        #expect(machine.handle(.passRequested(meeting)) == [])
        #expect(
            machine.handle(.summaryEnded)
                == [.startPass(meetingID: meeting, attempt: 1)])
    }

    @Test func manualRetryReadmitsTerminalMeetingFrontOfQueueWithFreshBudget() {
        var machine = machineWithRunningStopPass()
        _ = machine.handle(.passConcluded(.failure))  // attempt 1 → retry
        _ = machine.handle(.passConcluded(.failure))  // attempt 2 → terminal
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
        #expect(
            machine.handle(.pipelineFinished)
                == [.startPass(meetingID: meeting, attempt: 1)])
    }

    @Test func manualRetryCycleThatConvergesAgainReturnsToTerminal() {
        var machine = machineWithRunningStopPass()
        _ = machine.handle(.passConcluded(.failure))
        _ = machine.handle(.passConcluded(.failure))  // terminal
        _ = machine.handle(.pipelineFinished)

        // The Retry re-admits immediately (nothing else gates it).
        #expect(
            machine.handle(.manualRetryRequested(meeting))
                == [.startPass(meetingID: meeting, attempt: 1)])

        // The fresh cycle keeps ADR-016's bounded retries…
        #expect(
            machine.handle(.passConcluded(.failure))
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
        #expect(
            machine.handle(.manualRetryRequested(meeting))
                == [.startPass(meetingID: meeting, attempt: 1)])

        // Retrying the meeting whose pass is already running is a no-op —
        // the running attempt IS the retry the user asked for.
        #expect(machine.handle(.manualRetryRequested(meeting)) == [])
        #expect(machine.queue.isEmpty)
        #expect(machine.runningMeetingID == meeting)
    }

    /// Re-transcribe (settings page §3.5) rides `manualRetryRequested` for a
    /// meeting that already SUCCEEDED — nothing terminal to clear, admission
    /// unbent: idle starts the pass immediately on a fresh attempt 1; while
    /// recording it only queues (front) and starts after the stop pipeline
    /// closes.
    @Test func retranscribeOfASuccessfulMeetingStartsWhenIdleAndQueuesWhileRecording() {
        var machine = machineWithRunningStopPass()
        _ = machine.handle(.passConcluded(.success))
        _ = machine.handle(.pipelineFinished)

        // Idle: the re-transcribe starts right away, attempt 1.
        #expect(
            machine.handle(.manualRetryRequested(meeting))
                == [.startPass(meetingID: meeting, attempt: 1)])
        _ = machine.handle(.passConcluded(.success))

        // While recording: queued at the front, no start until the recording
        // stops AND its post-stop pipeline closes.
        _ = machine.handle(.recordingStarted)
        #expect(machine.handle(.manualRetryRequested(meeting)) == [])
        #expect(machine.queue == [meeting])
        #expect(machine.handle(.recordingStopped) == [])
        #expect(
            machine.handle(.pipelineFinished)
                == [.startPass(meetingID: meeting, attempt: 1)])
    }

    @Test func attemptBudgetIsPerMeeting() {
        var machine = FinalizationMachine()
        // `meeting` exhausts its budget…
        _ = machine.handle(.passRequested(meeting))
        _ = machine.handle(.passConcluded(.failure))
        #expect(machine.handle(.passConcluded(.failure)) == [.converge(meetingID: meeting)])

        // …which costs `older` nothing: it starts on a fresh attempt 1.
        #expect(
            machine.handle(.passRequested(older))
                == [.startPass(meetingID: older, attempt: 1)])
    }
}

// MARK: - The preemption signal

@Suite("Finalization preemption signal")
struct FinalizationPreemptionSignalTests {

    @Test func aFreshSignalIsLowered() {
        // Nothing is preempted until a recording says so: a signal that came
        // up raised would make the very first launch-resumed pass yield.
        #expect(!FinalizationPreemptionSignal().isRaised)
    }

    @Test func raisingAndLoweringAreObservable() {
        let signal = FinalizationPreemptionSignal()

        signal.raise()
        #expect(signal.isRaised)
        // Idempotent on purpose: `noteRecordingStarted` may run twice across
        // a rejected second start gesture.
        signal.raise()
        #expect(signal.isRaised)

        signal.lower()
        #expect(!signal.isRaised)
    }

    /// The signal's whole reason for existing: the decode loop reads it off
    /// the main actor, once per decode window, while the driver raises it on
    /// the main actor. The reader here is a task group child — a different
    /// isolation domain — and it must see the raise without the writer ever
    /// waiting on it.
    @Test @MainActor func aReaderOffTheMainActorSeesARaiseFromIt() async {
        let signal = FinalizationPreemptionSignal()

        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                // Yielding rather than sleeping: the writer below runs on the
                // main actor, and this turn ends until it has.
                while !signal.isRaised { await Task.yield() }
                return true
            }
            // The writer is the main actor, exactly as the driver is.
            signal.raise()
            let sawIt = await group.next()
            #expect(sawIt == true)
        }

        #expect(signal.isRaised)
    }
}
