//
//  FinalizationDriverTests.swift
//  RecordingTests
//
//  The driver over the admission machine: it turns the machine's actions into
//  work, resolves the awaited stop outcome, publishes what the UI reads, and
//  holds the two balances nothing in the type system can hold.
//
//  Rewritten from the PoC's `FinalizationCoordinatorTests` rather than ported.
//  The scenarios are its scenarios — the same names where the behaviour is the
//  same — but its seams were settable `var`s that only a handful of tests ever
//  set, and `finalizeStopped` is now two calls (`requestStopPass` then
//  `awaitStopOutcome`), because the request has to be synchronous so a phase
//  reads `.finalizing` before `stop()` returns. Everything after
//  `launchResumeRunsOneMeetingAtATimeInRequestOrder` is new: progress scoping,
//  the retry's fresh bar, the awaiter a started retry must NOT resume, and the
//  two balances — none of which the PoC's shape could express.
//
//  Nothing here touches disk, a model or a `RecordingSession`: the driver's
//  whole job is coordination, and coordination is all that is under test.
//

import EchoCore
import Foundation
import Testing

@testable import Recording

@Suite("Finalization driver")
@MainActor
struct FinalizationDriverTests {

    private func segments() -> [TranscriptSegment] {
        [TranscriptSegment(channel: .microphone, speaker: .me, text: "final", start: 0, end: 1)]
    }

    /// Enters a stop pipeline (a recording started and stopped) so a stop pass
    /// runs under the same gates production puts it under.
    private func enterStopPipeline(_ driver: FinalizationDriver) {
        driver.noteRecordingStarted()
        driver.noteRecordingStopped()
    }

    // MARK: - The PoC's scenarios

    @Test func happyPathReplacesAndReleasesSummaryModelFirst() async {
        let meeting = UUID()
        let final = segments()
        let order = OrderLog()
        let driver = makeDriver(
            runPass: { _, _ in
                order.append("pass")
                return .replaced(final)
            },
            prepareForPass: { order.append("prepare") }
        )
        enterStopPipeline(driver)

        driver.requestStopPass(meeting)
        let outcome = await driver.awaitStopOutcome(for: meeting)

        #expect(outcome == .replaced(final))
        // The ordering IS the invariant: the summary model is released before
        // the first decode, so two multi-gigabyte models are never resident at
        // once.
        #expect(order.entries == ["prepare", "pass"])
        #expect(!driver.isBusy)
        driver.notePostStopWorkFinished()
    }

    @Test func failureRetriesOnceThenSucceeds() async {
        let meeting = UUID()
        let final = segments()
        let runner = ScriptedRunner([.failed, .replaced(final)])
        let driver = makeDriver(runPass: { id, _ in runner.run(id) })
        enterStopPipeline(driver)

        driver.requestStopPass(meeting)
        let outcome = await driver.awaitStopOutcome(for: meeting)

        #expect(outcome == .replaced(final))
        #expect(runner.calledMeetingIDs == [meeting, meeting])
        #expect(driver.terminalFailureIDs.isEmpty)
        driver.notePostStopWorkFinished()
    }

    @Test func exhaustedRetriesConvergeTerminally() async {
        let meeting = UUID()
        let runner = ScriptedRunner([.failed, .failed])
        let converged = OrderLog()
        let driver = makeDriver(
            runPass: { id, _ in runner.run(id) },
            convergeTerminally: { id in converged.append(id.uuidString) }
        )
        enterStopPipeline(driver)

        driver.requestStopPass(meeting)
        let outcome = await driver.awaitStopOutcome(for: meeting)

        #expect(outcome == .failed)
        #expect(runner.calledMeetingIDs.count == 2)
        // The honest in-memory notice, and the meta write that keeps the
        // retained audio for the manual Retry.
        #expect(driver.terminalFailureIDs == [meeting])
        await waitUntil("the terminal convergence to run") {
            !converged.isEmpty
        }
        #expect(converged.entries == [meeting.uuidString])
        #expect(!driver.isBusy)
        driver.notePostStopWorkFinished()
    }

    @Test func manualRetryRunsAFreshCycleAfterTerminalConvergence() async {
        let meeting = UUID()
        let final = segments()
        let runner = ScriptedRunner([.failed, .failed, .replaced(final)])
        let concluded = OrderLog()
        let driver = makeDriver(
            runPass: { id, _ in runner.run(id) },
            // The driver reports EVERY conclusion here; the session filters
            // to successes, because only a transcript that landed has a
            // summary to kick. Filtered the same way, so the log below means
            // "the retry succeeded" rather than "something ended".
            onBackgroundPassConcluded: { id, result in
                if case .replaced = result { concluded.append(id.uuidString) }
            }
        )
        enterStopPipeline(driver)

        driver.requestStopPass(meeting)
        #expect(await driver.awaitStopOutcome(for: meeting) == .failed)
        #expect(driver.terminalFailureIDs == [meeting])
        driver.notePostStopWorkFinished()

        // The user's Retry: a fresh bounded cycle for the same meeting, which
        // clears the in-memory terminal notice.
        driver.requestManualRetry(meeting)
        #expect(driver.terminalFailureIDs.isEmpty)

        // No stop awaiter this time — the retry's success is reported as a
        // background conclusion, exactly like a launch-resumed pass, and that
        // is what kicks the backfill.
        await waitUntil("the retried pass to conclude in the background") {
            !concluded.isEmpty
        }
        #expect(concluded.entries == [meeting.uuidString])
        #expect(runner.calledMeetingIDs == [meeting, meeting, meeting])
        #expect(!driver.isBusy)
    }

    @Test func recordingMidStopPassDefersAndResumesAfterStop() async {
        let meeting = UUID()
        let final = segments()
        // Two scripted attempts that both READ the yield signal rather than
        // being told the answer: the deferral has to come from the real
        // signal, or the test proves nothing about the preemption path.
        let pass = ScriptedPass([.yieldingIfAsked(final), .yieldingIfAsked(final)])
        let concluded = OrderLog()
        let driver = makeDriver(
            runPass: { _, shouldYield in await passResult(from: pass, shouldYield: shouldYield) },
            // Successes only, as the session filters them: the deferral is
            // also a conclusion, and it is not what this waits for.
            onBackgroundPassConcluded: { id, result in
                if case .replaced = result { concluded.append(id.uuidString) }
            }
        )
        enterStopPipeline(driver)

        driver.requestStopPass(meeting)
        async let outcome = driver.awaitStopOutcome(for: meeting)
        await waitUntil("the pass to reach its gate") { pass.entered == 1 }

        // A new recording starts mid-pass: the signal goes up and the pass
        // yields at its next decode window.
        driver.noteRecordingStarted()
        pass.releaseAll()

        #expect(await outcome == .deferred)
        // Deferred, not failed: still queued (front) with its audio untouched.
        #expect(driver.queuedMeetingIDs == [meeting])
        driver.notePostStopWorkFinished()  // the old pipeline closes

        // After the new session stops and its (empty) pipeline finishes, the
        // deferred pass resumes — and with no stop awaiter left, concludes as
        // a background pass.
        driver.noteRecordingStopped()
        driver.notePostStopWorkFinished()
        await waitUntil("the deferred pass to resume and conclude") { !concluded.isEmpty }
        #expect(concluded.entries == [meeting.uuidString])
        #expect(!driver.isBusy)
    }

    @Test func summaryWorkIsGatedWhileAPassRuns() async {
        let meeting = UUID()
        let pass = ScriptedPass([.segments(segments())])
        let order = OrderLog()
        let driver = makeDriver(
            runPass: { _, shouldYield in
                let result = await passResult(from: pass, shouldYield: shouldYield)
                order.append("pass-finished")
                return result
            })

        driver.requestResume(of: [meeting])
        await waitUntil("the pass to reach its gate") { pass.entered == 1 }

        let summaryTask = Task { @MainActor in
            await driver.beginSummaryWork()
            order.append("summary-granted")
        }
        // The grant must not arrive while the pass decodes.
        await settle()
        #expect(order.isEmpty)

        pass.releaseAll()
        await summaryTask.value
        #expect(order.entries == ["pass-finished", "summary-granted"])
        driver.endSummaryWork()
    }

    @Test func launchResumeRunsOneMeetingAtATimeInRequestOrder() async {
        let newest = UUID()
        let older = UUID()
        let runner = ScriptedRunner([.replaced(segments()), .replaced(segments())])
        let driver = makeDriver(runPass: { id, _ in runner.run(id) })

        driver.requestResume(of: [newest, older])
        await waitUntil("both resumed passes to run") { !driver.isBusy }

        #expect(runner.calledMeetingIDs == [newest, older])
    }

    // MARK: - Progress

    @Test func progressIsForwardOnlyAndScopedToTheRunningMeeting() async {
        let meeting = UUID()
        let other = UUID()
        let pass = ScriptedPass([.segments([])])
        let driver = makeDriver(
            runPass: { _, shouldYield in await passResult(from: pass, shouldYield: shouldYield) })

        driver.requestResume(of: [meeting])
        await waitUntil("the pass to reach its gate") { pass.entered == 1 }
        // A started pass publishes a bar at zero, never a nil one: the meeting
        // IS being worked on, and an absent fraction would read as idle.
        #expect(driver.currentMeetingID == meeting)
        #expect(driver.progress == 0)

        driver.noteProgress(0.5, for: meeting)
        #expect(driver.progress == 0.5)

        // A straggler from a preempted pass must not move another meeting's
        // bar, and a bar never runs backwards.
        driver.noteProgress(0.9, for: other)
        #expect(driver.progress == 0.5)
        driver.noteProgress(0.2, for: meeting)
        #expect(driver.progress == 0.5)

        driver.noteProgress(0.75, for: meeting)
        #expect(driver.progress == 0.75)

        pass.releaseAll()
        await waitUntil("the pass to conclude") { !driver.isBusy }
        // Nothing is decoding, so there is no fraction to show.
        #expect(driver.progress == nil)
        #expect(driver.currentMeetingID == nil)
    }

    @Test func aRetryOfTheSameMeetingStartsItsBarFresh() async {
        let meeting = UUID()
        let gate = PassGate()
        let attempts = AttemptCounter()
        let published = SnapshotLog()
        let driver = makeDriver(
            runPass: { _, _ in
                let attempt = attempts.next()
                await gate.enter()
                return attempt == 1 ? .failed : .replaced([])
            },
            onStateChanged: { snapshot in published.append(snapshot) }
        )

        driver.requestResume(of: [meeting])
        await waitUntil("attempt 1 to reach its gate") { gate.entered == 1 }
        driver.noteProgress(0.9, for: meeting)
        #expect(driver.progress == 0.9)

        gate.releaseAll()  // attempt 1 fails; the retry starts under it
        await waitUntil("attempt 2 to reach its gate") { gate.entered == 2 }

        // The forward-only guard is per ATTEMPT, not per meeting: a retry that
        // inherited attempt 1's high-water mark would look stuck at 90 % for
        // the whole of its decode.
        #expect(driver.currentMeetingID == meeting)
        #expect(driver.progress == 0)
        driver.noteProgress(0.3, for: meeting)
        #expect(driver.progress == 0.3)
        #expect(published.progressValues.contains(0))

        gate.releaseAll()
        await waitUntil("the retry to conclude") { !driver.isBusy }
    }

    // MARK: - The stop awaiter

    @Test func aFailureWhoseRetryAlreadyStartedLeavesTheStopAwaiterSuspended() async {
        let meeting = UUID()
        let final = segments()
        let gate = PassGate()
        let attempts = AttemptCounter()
        let resolved = OrderLog()
        let driver = makeDriver(
            runPass: { _, _ in
                let attempt = attempts.next()
                await gate.enter()
                return attempt == 1 ? .failed : .replaced(final)
            })
        enterStopPipeline(driver)

        driver.requestStopPass(meeting)
        let awaiting = Task { @MainActor in
            let outcome = await driver.awaitStopOutcome(for: meeting)
            resolved.append("resolved")
            return outcome
        }

        await waitUntil("attempt 1 to reach its gate") { gate.entered == 1 }
        gate.releaseAll()  // attempt 1 fails — but it is not terminal
        await waitUntil("attempt 2 to reach its gate") { gate.entered == 2 }

        // Resuming here would close the post-stop pipeline while the retry is
        // still decoding, which is exactly what lets deferred passes in ahead
        // of it. The awaiter stays suspended on purpose.
        await settle()
        #expect(resolved.isEmpty)

        gate.releaseAll()
        #expect(await awaiting.value == .replaced(final))
        driver.notePostStopWorkFinished()
    }

    // MARK: - The two balances

    /// One `noteRecordingStopped()` opens exactly one pipeline and exactly one
    /// `notePostStopWorkFinished()` closes it. Nothing in the type system says
    /// so, and an unbalanced count wedges the gate forever — so the observable
    /// symptom is asserted directly: a deferred pass that never starts.
    @Test func onePostStopFinishClosesExactlyOnePipeline() async {
        let deferred = UUID()
        let ran = OrderLog()
        let driver = makeDriver(
            runPass: { id, _ in
                ran.append(id.uuidString)
                return .replaced([])
            })

        driver.noteRecordingStarted()
        driver.requestResume(of: [deferred])  // queued: nothing runs while recording
        driver.noteRecordingStopped()  // pipeline 1 opens
        driver.noteRecordingStarted()
        driver.noteRecordingStopped()  // pipeline 2 opens

        await settle()
        #expect(ran.isEmpty)

        driver.notePostStopWorkFinished()  // closes one, not both
        await settle()
        #expect(ran.isEmpty)

        driver.notePostStopWorkFinished()
        await waitUntil("the deferred pass to start once both pipelines closed") {
            ran.entries == [deferred.uuidString]
        }
    }

    /// The same balance on the other gate: one `beginSummaryWork()` is matched
    /// by exactly one `endSummaryWork()`, and a pass is admitted only once the
    /// count is back to zero.
    @Test func oneSummaryEndReleasesExactlyOneBeginning() async {
        let meeting = UUID()
        let ran = OrderLog()
        let driver = makeDriver(
            runPass: { id, _ in
                ran.append(id.uuidString)
                return .replaced([])
            })

        // Nothing is decoding, so both grants are immediate.
        await driver.beginSummaryWork()
        await driver.beginSummaryWork()

        driver.requestResume(of: [meeting])
        await settle()
        #expect(ran.isEmpty)

        driver.endSummaryWork()
        await settle()
        #expect(ran.isEmpty)

        driver.endSummaryWork()
        await waitUntil("the pass to start once summary work is balanced out") {
            ran.entries == [meeting.uuidString]
        }
    }
}
