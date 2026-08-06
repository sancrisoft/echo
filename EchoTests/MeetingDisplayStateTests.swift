//
//  MeetingDisplayStateTests.swift
//  EchoTests
//
//  The pending-display resolution as pure tables. Direct rows pin the
//  resolution precedence; the sequence rows drive the REAL
//  `FinalizationMachine` through the spec's event sequences and assert the
//  displayed face after every step — the "always resolves" criterion: a
//  meeting is never stuck showing neither transcript nor state, and the
//  transcript is readable only in `draft` and `final`.
//
//  Two terminal provenances live here now: `terminalFailure` (what a
//  converging cycle writes today — no transcript at all) and the legacy
//  `liveFloor` (pre-migration meetings whose Whisper text stands as a draft).
//  Both rest until the user retries; only their faces differ.
//

import Foundation
import Testing
@testable import Echo

// MARK: - Sequence harness

/// One meeting's world: the real admission machine plus the two persisted
/// bits the machine's actions write (provenance, retained audio). `state`
/// snapshots exactly what the view assembler feeds the pure function.
private struct DisplayHarness {
    let meeting = UUID()
    var machine = FinalizationMachine()
    var source: TranscriptProvenance.Source?
    var hasAudio = false
    var isRecordingThisMeeting = false

    /// A fixed non-zero fraction stands in for the coordinator's ADR-007
    /// progress while this meeting's pass runs; `nil` otherwise — the
    /// harness never invents progress for a non-running pass.
    var fraction: Double? {
        machine.runningMeetingID == meeting ? 0.4 : nil
    }

    var state: MeetingDisplayState {
        MeetingDisplayState.resolve(MeetingDisplaySnapshot(
            isRecordingThisMeeting: isRecordingThisMeeting,
            isRecordingActive: machine.isRecording,
            isPassRunning: machine.runningMeetingID == meeting,
            isQueued: machine.queue.contains(meeting),
            progressFraction: fraction,
            transcriptSource: source,
            hasRetainedAudio: hasAudio
        ))
    }

    /// Feeds the machine and applies the persisted effect of a terminal
    /// convergence: ONE atomic terminalFailure provenance write, audio KEPT
    /// (ADR-024 — the assertion that the audio survives is `hasAudio`
    /// staying true).
    mutating func apply(_ event: FinalizationMachine.Event) {
        for action in machine.handle(event) {
            if case .converge(let id) = action, id == meeting {
                source = .terminalFailure
            }
        }
    }

    /// The running pass succeeded: atomic replace writes finalPass
    /// provenance and deletes exactly this meeting's audio.
    mutating func concludeSuccess() {
        apply(.passConcluded(.success))
        source = .finalPass
        hasAudio = false
    }

    /// Recording → stop (floor persisted, audio adopted) → own stop pass
    /// requested. The state every post-stop sequence starts from.
    static func stoppedWithRunningPass() -> DisplayHarness {
        var h = DisplayHarness()
        h.isRecordingThisMeeting = true
        h.apply(.recordingStarted)
        #expect(h.state == .recording)
        h.isRecordingThisMeeting = false
        h.hasAudio = true
        h.apply(.recordingStopped)
        h.apply(.stopPassRequested(h.meeting))
        #expect(h.state == .transcribing(fraction: 0.4))
        return h
    }

    /// A cycle driven to terminal convergence, stop pipeline closed: the
    /// resting failed-with-Retry state.
    static func convergedFailure() -> DisplayHarness {
        var h = stoppedWithRunningPass()
        h.apply(.passConcluded(.failure))   // attempt 1 → auto-retry
        h.apply(.passConcluded(.failure))   // attempt 2 → terminal
        h.apply(.pipelineFinished)
        #expect(h.state == .failed(retryAvailable: true))
        #expect(h.hasAudio)                 // audio KEPT (ADR-024)
        return h
    }
}

// MARK: - Suites

@Suite("Meeting display state")
struct MeetingDisplayStateTests {

// MARK: Direct resolution rows

@Suite("Resolution table")
struct ResolutionTable {

    @Test func recordingWinsOverEverything() {
        let state = MeetingDisplayState.resolve(MeetingDisplaySnapshot(
            isRecordingThisMeeting: true,
            isRecordingActive: true,
            isPassRunning: true,
            isQueued: true,
            progressFraction: 0.5,
            transcriptSource: .liveFloor,
            hasRetainedAudio: true
        ))
        #expect(state == .recording)
        #expect(!state.isTranscriptReadable)
    }

    @Test func runningPassIsTranscribingWithTheRealFraction() {
        let state = MeetingDisplayState.resolve(MeetingDisplaySnapshot(
            isPassRunning: true, progressFraction: 0.62
        ))
        #expect(state == .transcribing(fraction: 0.62))
        #expect(!state.isTranscriptReadable)
    }

    @Test func runningPassWithNoFractionYetStartsAtZero() {
        let state = MeetingDisplayState.resolve(MeetingDisplaySnapshot(isPassRunning: true))
        #expect(state == .transcribing(fraction: 0))
    }

    /// The FinalizationNotice.isWaiting nuance: a pass yielding to an active
    /// recording must read as waiting, never as a bar pretending to work.
    @Test func yieldingPassReadsAsWaiting() {
        let state = MeetingDisplayState.resolve(MeetingDisplaySnapshot(
            isRecordingActive: true, isPassRunning: true, progressFraction: 0.5
        ))
        #expect(state == .waiting)
    }

    @Test func queuedIsWaiting() {
        let state = MeetingDisplayState.resolve(MeetingDisplaySnapshot(isQueued: true))
        #expect(state == .waiting)
    }

    /// Mid-Retry the terminal provenance is still on disk — the queue
    /// outranks it, so a re-opened cycle never flashes the failed face.
    @Test func queueOutranksTerminalProvenance() {
        for source in [TranscriptProvenance.Source.terminalFailure, .liveFloor] {
            let state = MeetingDisplayState.resolve(MeetingDisplaySnapshot(
                isQueued: true, transcriptSource: source, hasRetainedAudio: true
            ))
            #expect(state == .waiting)
        }
    }

    @Test func terminalFailureIsFailedRetryTracksAudio() {
        let withAudio = MeetingDisplayState.resolve(MeetingDisplaySnapshot(
            transcriptSource: .terminalFailure, hasRetainedAudio: true
        ))
        #expect(withAudio == .failed(retryAvailable: true))
        // No transcript exists — the failed face must never claim one.
        #expect(!withAudio.isTranscriptReadable)
        #expect(MeetingDisplayState.resolve(MeetingDisplaySnapshot(
            transcriptSource: .terminalFailure, hasRetainedAudio: false
        )) == .failed(retryAvailable: false))
    }

    /// Legacy rows: pre-migration meetings keep their draft face and their
    /// readable floor transcript.
    @Test func liveFloorProvenanceIsDraftRetryTracksAudio() {
        #expect(MeetingDisplayState.resolve(MeetingDisplaySnapshot(
            transcriptSource: .liveFloor, hasRetainedAudio: true
        )) == .draft(retryAvailable: true))
        #expect(MeetingDisplayState.resolve(MeetingDisplaySnapshot(
            transcriptSource: .liveFloor, hasRetainedAudio: false
        )) == .draft(retryAvailable: false))
        #expect(MeetingDisplayState.resolve(MeetingDisplaySnapshot(
            transcriptSource: .liveFloor, hasRetainedAudio: true
        )).isTranscriptReadable)
    }

    @Test func finalPassProvenanceIsFinal() {
        let state = MeetingDisplayState.resolve(MeetingDisplaySnapshot(
            transcriptSource: .finalPass
        ))
        #expect(state == .final)
        #expect(state.isTranscriptReadable)
    }

    /// The finalPass orphan (success whose cleanup crashed): its transcript
    /// IS final — the leftover audio never gates it (the sweep deletes it).
    @Test func finalPassOrphanWithLeftoverAudioIsFinal() {
        let state = MeetingDisplayState.resolve(MeetingDisplaySnapshot(
            transcriptSource: .finalPass, hasRetainedAudio: true
        ))
        #expect(state == .final)
    }

    /// Pre-SP-007 meetings and any meeting with neither provenance nor
    /// pending state: the transcript renders — "unknown renders as unknown"
    /// applies to model names, not to gating the transcript.
    @Test func noProvenanceNoAudioIsFinal() {
        let state = MeetingDisplayState.resolve(MeetingDisplaySnapshot())
        #expect(state == .final)
    }

    /// Retained audio with no provenance is a pending meeting awaiting its
    /// launch resume — waiting, never a bare floor transcript.
    @Test func audioWithoutProvenanceIsWaiting() {
        let state = MeetingDisplayState.resolve(MeetingDisplaySnapshot(hasRetainedAudio: true))
        #expect(state == .waiting)
        #expect(!state.isTranscriptReadable)
    }
}

// MARK: Spec event sequences

@Suite("Spec sequences")
struct SpecSequences {

    @Test func stopPassSuccessResolvesToFinal() {
        var h = DisplayHarness.stoppedWithRunningPass()
        h.concludeSuccess()
        #expect(h.state == .final)
        #expect(!h.hasAudio)
        h.apply(.pipelineFinished)
        #expect(h.state == .final)
    }

    /// The stop path's instant between adoption and its own pass request:
    /// audio armed, nothing enqueued yet — honest waiting, never the floor.
    @Test func stoppedBeforePassEnqueuesShowsWaiting() {
        var h = DisplayHarness()
        h.apply(.recordingStarted)
        h.isRecordingThisMeeting = true
        #expect(h.state == .recording)
        h.isRecordingThisMeeting = false
        h.hasAudio = true
        h.apply(.recordingStopped)
        #expect(h.state == .waiting)
    }

    @Test func preemptMidPassReadsAsWaitingUntilResumedBehindTheNewMeeting() {
        var h = DisplayHarness.stoppedWithRunningPass()
        let newer = UUID()

        // A new recording starts: the running pass yields — waiting, not a
        // frozen percentage.
        h.apply(.recordingStarted)
        #expect(h.state == .waiting)

        // The pass concludes preempted; the old stop pipeline resolves as
        // deferred and closes. Still waiting, queued now.
        h.apply(.passConcluded(.preempted))
        h.apply(.pipelineFinished)
        #expect(h.state == .waiting)

        // The new meeting's own post-stop pipeline front-runs: our meeting
        // waits behind it the whole way.
        h.apply(.recordingStopped)
        h.apply(.stopPassRequested(newer))
        #expect(h.state == .waiting)
        h.apply(.passConcluded(.success))
        #expect(h.state == .waiting)
        h.apply(.pipelineFinished)

        // Our pass resumes → transcribing → success → final.
        #expect(h.state == .transcribing(fraction: 0.4))
        h.concludeSuccess()
        #expect(h.state == .final)
    }

    /// A failed attempt inside the cycle auto-retries — the meeting reads as
    /// transcribing (or waiting), NEVER as failed mid-cycle.
    @Test func failedAttemptAutoRetriesWithoutShowingFailure() {
        var h = DisplayHarness.stoppedWithRunningPass()
        h.apply(.passConcluded(.failure))
        #expect(h.machine.runningAttempt == 2)
        #expect(h.state == .transcribing(fraction: 0.4))
        #expect(h.source == nil)   // no provenance mid-cycle
    }

    /// A failed attempt whose retry is blocked by a new recording: waiting.
    @Test func failedAttemptBlockedByRecordingReadsAsWaiting() {
        var h = DisplayHarness.stoppedWithRunningPass()
        h.apply(.recordingStarted)
        h.apply(.passConcluded(.failure))
        #expect(h.state == .waiting)
    }

    @Test func cycleExhaustedConvergesToFailedWithRetry() {
        var h = DisplayHarness.stoppedWithRunningPass()
        h.apply(.passConcluded(.failure))
        h.apply(.passConcluded(.failure))
        #expect(h.state == .failed(retryAvailable: true))
        #expect(h.hasAudio)   // audio KEPT for the manual Retry (ADR-024)
        // There is no transcript to read: a failed meeting has no words.
        #expect(!h.state.isTranscriptReadable)
    }

    @Test func manualRetryRunsAFreshCycleToSuccess() {
        var h = DisplayHarness.convergedFailure()
        h.apply(.manualRetryRequested(h.meeting))
        // Fresh bounded budget: attempt 1, not a continuation of the old cycle.
        #expect(h.machine.runningAttempt == 1)
        #expect(h.state == .transcribing(fraction: 0.4))
        h.concludeSuccess()
        #expect(h.state == .final)
        #expect(!h.hasAudio)
    }

    /// Retry pressed while a recording is active: admission holds it — the
    /// meeting reads as waiting (not failed, not transcribing) until the
    /// recording's pipeline clears, then decodes.
    @Test func manualRetryDuringRecordingWaitsThenTranscribes() {
        var h = DisplayHarness.convergedFailure()
        h.apply(.recordingStarted)
        h.apply(.manualRetryRequested(h.meeting))
        #expect(h.state == .waiting)
        // The session ends without its own pass (abandoned/empty session).
        h.apply(.recordingStopped)
        h.apply(.pipelineFinished)
        #expect(h.state == .transcribing(fraction: 0.4))
    }

    @Test func secondConvergenceReturnsToFailedWithRetryStillAvailable() {
        var h = DisplayHarness.convergedFailure()
        h.apply(.manualRetryRequested(h.meeting))
        h.apply(.passConcluded(.failure))
        #expect(h.state == .transcribing(fraction: 0.4))   // auto-retry within the new cycle
        h.apply(.passConcluded(.failure))
        #expect(h.state == .failed(retryAvailable: true))
        #expect(h.hasAudio)
    }

    /// LEGACY "Keep draft" releases the audio: the draft stays (provenance
    /// is untouched) and the Retry disappears with its audio. Only ever
    /// reachable for a pre-migration `liveFloor` meeting — a terminally
    /// failed one has no text to keep.
    @Test func keepDraftBecomesDraftWithoutRetry() {
        var h = DisplayHarness()
        h.source = .liveFloor
        h.hasAudio = false   // the only effect of keepDraft
        #expect(h.state == .draft(retryAvailable: false))
        #expect(h.source == .liveFloor)
    }

    /// A terminally failed meeting whose audio is gone (deleted out from
    /// under it): failed, and honestly without a Retry — there is nothing
    /// left to decode.
    @Test func terminalFailureWithoutAudioOffersNoRetry() {
        var h = DisplayHarness.convergedFailure()
        h.hasAudio = false
        #expect(h.state == .failed(retryAvailable: false))
    }

    /// Relaunch: fresh machine, persisted bits only. Audio + terminalFailure
    /// is a failed meeting — displayed as failed, never auto-resumed (the
    /// launch scan excludes it; no machine event fires for it).
    @Test func relaunchWithAudioAndTerminalFailureIsFailedNeverAutoResumed() {
        var h = DisplayHarness()
        h.source = .terminalFailure
        h.hasAudio = true
        #expect(h.state == .failed(retryAvailable: true))
        #expect(h.machine.runningMeetingID == nil)
        #expect(h.machine.queue.isEmpty)

        // Only the user's Retry re-opens it — valid even though this
        // machine never saw the meeting converge (the terminal set is
        // in-memory; on a fresh run there is simply nothing to clear).
        h.apply(.manualRetryRequested(h.meeting))
        #expect(h.state == .transcribing(fraction: 0.4))
    }

    /// Relaunch with audio and NO provenance: a pending meeting — waiting
    /// until the launch resume enqueues it, then transcribing.
    @Test func relaunchWithAudioAndNoProvenanceIsWaitingThenResumes() {
        var h = DisplayHarness()
        h.hasAudio = true
        #expect(h.state == .waiting)
        h.apply(.passRequested(h.meeting))   // launch resume
        #expect(h.state == .transcribing(fraction: 0.4))
        h.concludeSuccess()
        #expect(h.state == .final)
    }
}

}
