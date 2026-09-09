//
//  RecordingSessionTests.swift
//  RecordingTests
//
//  The session façade: the phase every surface reads, the capture topology a
//  scope establishes, what a degraded microphone does to a session, the live
//  meter's arithmetic, and what a Stop leaves on disk.
//
//  Everything runs against fakes for the two capture seams and a real
//  `MeetingStore` under a `TemporaryDirectory` — no microphone, no process
//  tap, no network. Where the session hops off a capture callback the tests
//  yield until the work lands (`waitUntil`); nothing here sleeps or asserts
//  on elapsed time, because a session's ordering is what is under test and a
//  clock would only add flakiness to it.
//

import Audio
import EchoCore
import EchoCoreTestSupport
import Foundation
import Meetings
import Testing

@testable import Recording

/// The app a scoped session narrows to, for every test that needs one.
let zoomSelector = ProcessSelector(displayName: "Zoom", bundlePrefix: "us.zoom.xos")

// MARK: - Phase and lifecycle

@Suite("RecordingSession — phase and lifecycle")
@MainActor
struct RecordingSessionLifecycleTests {

    @Test func aFreshSessionIsIdleAndHasTouchedNothing() async throws {
        try await withSession { harness in
            #expect(harness.session.phase == .idle)
            #expect(harness.session.levels == .silent)
            #expect(harness.session.notices.isEmpty)
            #expect(harness.session.currentMeetingID == nil)
            // An initializer performs no side effect: no capture was built,
            // no watcher armed, no folder created.
            #expect(harness.rig.systemCaptures.isEmpty)
            #expect(harness.rig.microphones.isEmpty)
            #expect(harness.meetingFolders().isEmpty)
        }
    }

    @Test func startBeginsARecordingPhaseCarryingItsStartAndScope() async throws {
        try await withSession { harness in
            await harness.session.start()

            guard case .recording(let startedAt, let scope) = harness.session.phase else {
                Issue.record("Expected .recording, got \(harness.session.phase)")
                return
            }
            #expect(scope == .everything)
            // Both are payloads of the phase, so a surface can never read a
            // start time for a session that is not running.
            #expect(harness.session.phase.startedAt == startedAt)
            #expect(harness.session.phase.captureScope == .everything)
            #expect(harness.session.phase.isRecording)
            #expect(harness.session.currentMeetingID == nil)

            await harness.session.stop()
        }
    }

    @Test func startingTwiceIsOneSession() async throws {
        try await withSession { harness in
            await harness.session.start()
            let established = harness.session.phase

            await harness.session.start()

            // Same phase value — same start time — and no second topology:
            // a second gesture is a no-op, not a second session.
            #expect(harness.session.phase == established)
            #expect(harness.rig.systemCaptures.count == 1)
            #expect(harness.rig.microphones.count == 1)

            await harness.session.stop()
        }
    }

    @Test func stoppingWhileIdleDoesNothing() async throws {
        try await withSession { harness in
            await harness.session.stop()

            #expect(harness.session.phase == .idle)
            #expect(harness.rig.systemCaptures.isEmpty)
            #expect(harness.meetingFolders().isEmpty)
        }
    }
}

// MARK: - Scope

@Suite("RecordingSession — capture scope")
@MainActor
struct RecordingSessionScopeTests {

    @Test func aScopedSessionRunsTheReferenceTapFirstAndTheScopedTapSecond() async throws {
        try await withSession { harness in
            await harness.session.start(scope: .app(zoomSelector))

            #expect(harness.session.phase.captureScope == .app(zoomSelector))
            #expect(harness.rig.systemCaptures.count == 2)
            // The reference comes up FIRST and globally, so a scoped tap never
            // runs without the far end that keeps cancellation honest.
            #expect(harness.rig.systemCaptures[0].startedScope == .everything)
            #expect(harness.rig.systemCaptures[1].startedScope == .app(zoomSelector))

            await harness.session.stop()
        }
    }

    @Test func onlyTheScopedTapIsMetered() async throws {
        try await withSession { harness in
            await harness.session.start(scope: .app(zoomSelector))

            // Nothing from the reference tap is metered, shown, persisted or
            // transcribed, which is why it is built with no level callback at
            // all — the absence is the guarantee.
            #expect(harness.rig.systemCaptures[0].isMetered == false)
            #expect(harness.rig.systemCaptures[1].isMetered == true)

            await harness.session.stop()
        }
    }

    @Test func aFailedScopedTapCollapsesToAGlobalSessionVisibly() async throws {
        let rig = CaptureRig(systemStartOutcome: { index in
            // The scoped tap is the second one built; the reference and the
            // fallback both come up.
            if index == 2 { throw ScriptedCaptureFailure(reason: "no audio processes") }
        })
        try await withSession(rig: rig) { harness in
            await harness.session.start(scope: .app(zoomSelector))

            // Recording more than intended is acceptable only while it says
            // so: the phase carries the EFFECTIVE coverage, not the request.
            #expect(harness.session.phase.captureScope == .everything)
            #expect(rig.systemCaptures.count == 3)
            #expect(rig.systemCaptures[2].startedScope == .everything)

            await harness.session.stop()
        }
    }

    @Test func onlyTheReferenceTapFeedsTheEchoCancellerInAScopedSession() async throws {
        try await withSession { harness in
            await harness.session.start(scope: .app(zoomSelector))
            let reference = harness.rig.systemCaptures[0]
            let scoped = harness.rig.systemCaptures[1]

            reference.emit(samples: audibleBatch(frames: 320))
            #expect(harness.rig.echoStage.farEndFrames == 320)

            scoped.emit(samples: audibleBatch(frames: 320))
            // The scoped tap is the Others channel, never the AEC reference:
            // it hears one app, and cancelling the mic against one app's
            // audio would leave the rest of the speaker bleed in place.
            #expect(harness.rig.echoStage.farEndFrames == 320)

            await harness.session.stop()
        }
    }

    @Test func theSingleTapOfAGlobalSessionDoesFeedTheEchoCanceller() async throws {
        try await withSession { harness in
            await harness.session.start()

            harness.rig.systemCaptures[0].emit(samples: audibleBatch(frames: 320))

            // One tap, two jobs: the Others channel and the far-end reference.
            #expect(harness.rig.echoStage.farEndFrames == 320)
            #expect(harness.rig.systemCaptures.count == 1)

            await harness.session.stop()
        }
    }
}

// MARK: - Start failure

@Suite("RecordingSession — start failure")
@MainActor
struct RecordingSessionStartFailureTests {

    @Test func aSystemCaptureThatNeverStartsLeavesTheSessionIdle() async throws {
        let rig = CaptureRig(systemStartOutcome: { _ in
            throw ScriptedCaptureFailure(reason: "the tap could not be built")
        })
        try await withSession(rig: rig) { harness in
            await harness.session.start()

            #expect(harness.session.phase == .idle)
            #expect(harness.session.notices.map(\.kind) == [.captureFailed])
            #expect(harness.session.currentMeetingID == nil)
            // A session that never began is not a meeting.
            #expect(harness.meetingFolders().isEmpty)

            // And there is nothing left for a Stop to tear down: the notice
            // survives it untouched, because teardown already happened.
            await harness.session.stop()
            #expect(harness.session.phase == .idle)
            #expect(harness.session.notices.map(\.kind) == [.captureFailed])
        }
    }

    @Test func aFailedStartStopsTheTapItCouldNotBringUp() async throws {
        let rig = CaptureRig(systemStartOutcome: { _ in
            throw ScriptedCaptureFailure(reason: "the tap could not be built")
        })
        try await withSession(rig: rig) { harness in
            await harness.session.start()

            #expect(rig.systemCaptures.count == 1)
            // Twice: the unwind inside the start path, then the teardown. The
            // unwind is what is under test — the global start path leaves a
            // process tap and a private aggregate device behind otherwise,
            // for the next attempt to trip over, and `stop()` is idempotent.
            #expect(rig.systemCaptures[0].stops == 2)
        }
    }
}

// MARK: - Microphone degradation

@Suite("RecordingSession — microphone degradation")
@MainActor
struct RecordingSessionMicrophoneTests {

    @Test func aMacWithNoInputDeviceRecordsMeetingAudioOnly() async throws {
        let rig = CaptureRig(inputDevice: nil)
        try await withSession(rig: rig) { harness in
            await harness.session.start()

            // The microphone is optional; the meeting audio is not.
            #expect(harness.session.phase.isRecording)
            #expect(harness.session.notices.map(\.kind) == [.microphoneUnavailable])
            #expect(harness.session.notices.first?.message == InputDeviceNotice.micUnavailableMessage)
            // No mic engine is even built: the session never expected one.
            #expect(rig.microphones.isEmpty)
            #expect(rig.systemCaptures.count == 1)

            await harness.session.stop()
        }
    }

    @Test func aMicrophoneThatCannotFindItsDeviceDegradesTheSession() async throws {
        let rig = CaptureRig(micStartOutcome: { _ in
            throw MicrophoneCapture.CaptureError.noInputDevice
        })
        try await withSession(rig: rig) { harness in
            await harness.session.start()

            #expect(harness.session.phase.isRecording)
            #expect(harness.session.notices.map(\.kind) == [.microphoneUnavailable])
            // The system side is untouched by a mic failure — it came up, on
            // the requested coverage, and was never stopped.
            #expect(rig.systemCaptures.count == 1)
            #expect(rig.systemCaptures[0].startedScope == .everything)
            #expect(rig.systemCaptures[0].stops == 0)

            await harness.session.stop()
        }
    }

    @Test func aDeniedMicrophoneAbortsTheSession() async throws {
        let rig = CaptureRig(micStartOutcome: { _ in
            throw MicrophoneCapture.CaptureError.permissionDenied
        })
        try await withSession(rig: rig) { harness in
            await harness.session.start()

            // Degradation is for a MISSING device only; a denial is a real
            // failure and propagates.
            #expect(harness.session.phase == .idle)
            #expect(harness.session.notices.map(\.kind) == [.captureFailed])
            // It aborted before the system side was ever reached.
            #expect(rig.systemCaptures.isEmpty)
            #expect(harness.meetingFolders().isEmpty)
        }
    }
}

// MARK: - Levels

@Suite("RecordingSession — live levels")
@MainActor
struct RecordingSessionLevelTests {

    @Test func aMicLevelReachesTheYouChannelOnly() async throws {
        try await withSession { harness in
            await harness.session.start()
            let mic = try #require(harness.rig.microphones.first)

            mic.emit(level: 0.5)
            await waitUntil("the mic level to reach the meter") { harness.session.levels.you > 0 }

            // Speaker attribution is the channel all the way to the meter.
            #expect(harness.session.levels.others == 0)

            await harness.session.stop()
        }
    }

    @Test func levelsRestAfterStop() async throws {
        try await withSession { harness in
            await harness.session.start()
            let mic = try #require(harness.rig.microphones.first)
            mic.emit(level: 0.8)
            await waitUntil("the mic level to reach the meter") { harness.session.levels.you > 0 }

            await harness.session.stop()

            // Reset at teardown rather than aged out, so an idle meter rests
            // immediately instead of waiting out `levelStaleAfter`.
            #expect(harness.session.levels == .silent)
        }
    }

    @Test func aLevelEmittedWhileIdleChangesNothing() async throws {
        try await withSession { harness in
            await harness.session.start()
            let mic = try #require(harness.rig.microphones.first)
            await harness.session.stop()

            mic.emit(level: 0.9)

            // A straggler from a torn-down tap must not move the meter: a
            // meter that moves when nothing is captured makes a broken
            // microphone look fine.
            for _ in 0..<50 { await Task.yield() }
            #expect(harness.session.levels == .silent)
        }
    }
}

// MARK: - The level window itself

@Suite("LevelWindow")
struct LevelWindowTests {

    @Test func pruningIsByAgeNotByCount() {
        var window = LevelWindow()
        let t0 = ContinuousClock.Instant.now
        for _ in 0..<50 { window.append(0.1, at: t0) }
        window.append(0.5, at: t0 + .seconds(0.1))

        // Fifty readings at one instant do not outvote one 0.1 s later: the
        // window spans 0.06 s of AUDIO, so only the newest is inside it. A
        // window counted in callbacks would render the mic's ~800 ms average.
        #expect(abs(window.amplitude(at: t0 + .seconds(0.1)) - 0.7) < 0.000_001)
    }

    @Test func aChannelSilentLongerThanTheStaleBoundRests() {
        var window = LevelWindow()
        let t0 = ContinuousClock.Instant.now
        window.append(0.5, at: t0)

        // A channel that genuinely stopped — the device disappeared — falls to
        // the resting line rather than freezing at what it last measured.
        #expect(window.amplitude(at: t0 + .seconds(LevelWindow.levelStaleAfter + 0.01)) == 0)
    }

    @Test func aTapSlowerThanTheWindowKeepsRenderingItsNewestReading() {
        var window = LevelWindow()
        let t0 = ContinuousClock.Instant.now
        window.append(0.5, at: t0)

        // 0.3 s: past the 0.06 s window, well inside the 0.5 s stale bound —
        // a mic tap on a 16 kHz device. It renders, it does not flatline.
        #expect(abs(window.amplitude(at: t0 + .seconds(0.3)) - 0.7) < 0.000_001)
    }

    @Test func theGainAppliesToTheMean() {
        var window = LevelWindow()
        let t0 = ContinuousClock.Instant.now
        window.append(0.5, at: t0)
        window.append(0.1, at: t0)

        // Mean 0.3, then the display gain — never applied to a stored sample,
        // so the recorded levels stay the measurement.
        #expect(abs(window.amplitude(at: t0) - 0.42) < 0.000_001)
    }

    @Test func theGainedMeanIsClampedAtOne() {
        var window = LevelWindow()
        let t0 = ContinuousClock.Instant.now
        window.append(1, at: t0)
        #expect(window.amplitude(at: t0) == 1)

        // And a reading above the rail is clamped on the way in, so it can
        // never drag a later mean above what was measured.
        var overdriven = LevelWindow()
        overdriven.append(5, at: t0)
        overdriven.append(0, at: t0)
        #expect(abs(overdriven.amplitude(at: t0) - 0.7) < 0.000_001)
    }

    @Test func resetDropsEverything() {
        var window = LevelWindow()
        let t0 = ContinuousClock.Instant.now
        window.append(0.9, at: t0)

        window.reset()

        #expect(window.amplitude(at: t0) == 0)
    }
}

// MARK: - Stop and the store

@Suite("RecordingSession — stop and the store")
@MainActor
struct RecordingSessionStopTests {

    @Test func stoppingWithRetainedAudioPersistsOneMeetingAndAdoptsItsAudio() async throws {
        try await withSession { harness in
            await harness.session.start()
            try await harness.captureAudibleAudio()

            await harness.session.stop()

            let folders = harness.meetingFolders()
            #expect(folders.count == 1)
            let meetingID = try #require(harness.session.currentMeetingID)
            // The retained audio IS the pending marker; the phase only says so,
            // and it carries the pass's own fraction from zero (ADR-007).
            #expect(harness.session.phase == .finalizing(meetingID: meetingID, progress: 0))

            let meta = try #require(await harness.store.listMetas().first)
            #expect(meta.id == meetingID)
            // Persisted from its audio, not from a transcript: nothing
            // transcribes during a recording, so there are no words yet and
            // an empty `transcript.json` would claim one that does not exist.
            #expect(meta.segmentCount == 0)
            #expect(meta.captureScope == .everything)
            #expect(!harness.fileNames(in: folders[0]).contains("transcript.json"))

            // Adopted INTO the meeting folder — a rename, not a copy — so
            // nothing is left in staging for a launch sweep to delete.
            #expect(
                harness.fileNames(in: folders[0])
                    .isSuperset(of: ["retained-mic.m4a", "retained-system.m4a"]))
            #expect(await harness.store.hasRetainedAudio(for: meetingID))
            // Encoded bytes, not empty containers: a truncated retention file
            // would replace a fuller transcript with less.
            for url in await harness.store.retainedAudioFiles(for: meetingID).values {
                #expect(try Data(contentsOf: url).count > 0)
            }
            #expect(harness.stagedSessionFolders().isEmpty)

            // The library re-read after the stop, so the row is already there.
            #expect(harness.library.metas.map(\.id) == [meetingID])
        }
    }

    @Test func aSessionThatCapturedNothingPersistsNoMeeting() async throws {
        try await withSession { harness in
            await harness.session.start()
            await harness.session.stop()

            // A folder claiming a recording that produced no audio would be a
            // row that can never become words.
            #expect(harness.meetingFolders().isEmpty)
            #expect(harness.session.phase == .idle)
            #expect(harness.session.currentMeetingID == nil)
            #expect(harness.library.metas.isEmpty)
        }
    }

    @Test func aScopedSessionRecordsTheAppItCaptured() async throws {
        try await withSession { harness in
            await harness.session.start(scope: .app(zoomSelector))
            try await harness.captureAudibleAudio()

            await harness.session.stop()

            let meta = try #require(await harness.store.listMetas().first)
            #expect(meta.captureScope?.kind == CaptureScopeRecord.appKind)
            // The display name is what the row must still say a year from now.
            #expect(meta.captureScope?.appName == "Zoom")
            #expect(meta.captureScope?.scopedDisplayLabel == "Zoom only")
        }
    }
}

// MARK: - Notices

@Suite("RecordingSession — notices")
@MainActor
struct RecordingSessionNoticeTests {

    @Test func noticeKindsOrderThemselvesByDeclaration() {
        // Declaration order is render order, so a health notice can never
        // displace an active device-lost one. The guarantee lives in the
        // value — `notices` only sorts by kind — never in a view.
        #expect(RecordingNotice.Kind.allCases.sorted() == RecordingNotice.Kind.allCases)
        #expect(RecordingNotice.Kind.captureFailed < RecordingNotice.Kind.retentionLost)
        #expect(RecordingNotice.Kind.retentionLost < RecordingNotice.Kind.microphoneUnavailable)
        #expect(RecordingNotice.Kind.microphoneUnavailable < RecordingNotice.Kind.echoCancellation)
        #expect(RecordingNotice.Kind.echoCancellation < RecordingNotice.Kind.microphoneHealth)
        #expect(RecordingNotice.Kind.microphoneHealth < RecordingNotice.Kind.meetingAudioHealth)
    }

    @Test func aNoticeIsIdentifiedByItsKindSoAShowReplaces() {
        let first = RecordingNotice(kind: .microphoneUnavailable, message: "first")
        let second = RecordingNotice(kind: .microphoneUnavailable, message: "second")

        // Keying by kind is what makes "at most one per episode" free: a show
        // replaces rather than accumulates, so nothing has to be counted.
        #expect(first.id == second.id)
        #expect(first != second)
    }

    @Test func stoppingClearsEveryNotice() async throws {
        let rig = CaptureRig(inputDevice: nil)
        try await withSession(rig: rig) { harness in
            await harness.session.start()
            #expect(harness.session.notices.map(\.kind) == [.microphoneUnavailable])

            await harness.session.stop()

            #expect(harness.session.notices.isEmpty)
        }
    }

    @Test func anEngineThatNeverCameUpRaisesTheDegradationNoticeAtStart() async throws {
        // On loudspeakers the mode machine starts in `.cancelling`, so an
        // engine that failed before anyone was listening has to be folded in
        // at start: it reports transitions only, and this one already
        // happened.
        let rig = CaptureRig(route: .builtInSpeakers, engineHealthy: false)
        try await withSession(rig: rig) { harness in
            await harness.session.start()

            #expect(harness.session.phase.isRecording)
            #expect(
                harness.session.notices
                    == [
                        RecordingNotice(
                            kind: .echoCancellation, message: EchoDegradationNotice.message)
                    ])

            await harness.session.stop()
        }
    }

    @Test func anEngineFailureMidSessionRaisesTheNoticeOnceAndLeavingSpeakersClearsIt() async throws {
        let rig = CaptureRig(route: .builtInSpeakers)
        try await withSession(rig: rig) { harness in
            await harness.session.start()
            #expect(harness.session.notices.isEmpty)

            rig.echoStage.reportEngineHealth(false)
            await Task.yield()
            #expect(harness.session.notices.map(\.kind) == [.echoCancellation])

            // At most one notice per degradation episode — never one per
            // frame. A second failure inside the same episode adds nothing.
            rig.echoStage.reportEngineHealth(false)
            await Task.yield()
            #expect(harness.session.notices.count == 1)

            // Leaving the loudspeaker route ends the episode: there is no
            // echo path to degrade any more.
            rig.outputWatcher?.reportRouteChange(.headphones)
            await Task.yield()
            #expect(harness.session.notices.isEmpty)

            await harness.session.stop()
        }
    }

    @Test func twoLiveNoticesRenderInDeclarationOrder() async throws {
        // The only pair a session can hold at once: no input device at all,
        // plus an echo engine that never came up. Raised device-first here,
        // and they must still render device-first — but the point is that the
        // order comes from the kind, not from the raising.
        let rig = CaptureRig(inputDevice: nil, route: .builtInSpeakers, engineHealthy: false)
        try await withSession(rig: rig) { harness in
            await harness.session.start()

            #expect(
                harness.session.notices.map(\.kind) == [.microphoneUnavailable, .echoCancellation])

            await harness.session.stop()
        }
    }

    @Test func permissionsAreRaisedOnceOnTheFirstRecordGesture() async throws {
        let rig = CaptureRig()
        try await withSession(rig: rig) { harness in
            // Never at launch: building a session touches nothing.
            #expect(rig.permissionPrimeCount == 0)

            await harness.session.start()
            #expect(rig.permissionPrimeCount == 1)
            await harness.session.stop()

            // Once per app run, not once per session: the dialogs are a
            // gesture effect, and the OS has already answered.
            await harness.session.start()
            #expect(rig.permissionPrimeCount == 1)
            await harness.session.stop()
        }
    }

    @Test func aSecondStartClearsTheFailedOnesNotice() async throws {
        let rig = CaptureRig(systemStartOutcome: { index in
            // Only the first session's tap fails; the second start builds a
            // fresh one, which comes up.
            if index == 1 { throw ScriptedCaptureFailure(reason: "the tap was busy") }
        })
        try await withSession(rig: rig) { harness in
            await harness.session.start()
            #expect(harness.session.notices.map(\.kind) == [.captureFailed])

            await harness.session.start()

            // A new session begins clean: the previous one's failure is not
            // its state.
            #expect(harness.session.phase.isRecording)
            #expect(harness.session.notices.isEmpty)

            await harness.session.stop()
        }
    }
}
