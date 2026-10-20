//
//  CaptureAccessTests.swift
//  RecordingTests
//
//  The welcome screen's two permission rows read the session. The
//  microphone's permission is read from macOS without asking; the Mac's
//  audio is read by the probe, which is also the request, so it runs only
//  once Echo has asked — a look never raises a dialog on its own.
//
//  Driven with the rig's fakes: no TCC prompt, no tone, no process tap.
//

import Audio
import Foundation
import Testing

@testable import Recording

@Suite("RecordingSession — capture permissions")
@MainActor
struct CaptureAccessTests {

    @Test(
        "macOS's answers read as the rows draw them",
        arguments: [
            (MicrophoneAuthorization.notDetermined, CaptureAccess.undecided),
            (.denied, .denied),
            (.granted, .granted),
        ])
    func microphoneMap(authorization: MicrophoneAuthorization, expected: CaptureAccess) {
        #expect(CaptureAccess(authorization) == expected)
    }

    @Test(
        "the probe's verdicts read as the rows draw them",
        arguments: [
            (SystemAudioAccess.granted, CaptureAccess.granted),
            (.denied, .denied),
            (.unknown, .undecided),
        ])
    func systemAudioMap(verdict: SystemAudioAccess, expected: CaptureAccess) {
        #expect(CaptureAccess(verdict) == expected)
    }

    @Test func aLookBeforeEchoHasAskedRaisesNothing() async throws {
        let rig = CaptureRig(microphone: .notDetermined, systemAudio: [.granted])
        try await withSession(rig: rig) { harness in
            await harness.session.refreshCaptureAccess()
            #expect(harness.session.microphoneAccess == .undecided)
            #expect(harness.session.systemAudioAccess == .undecided)
            // Neither dialog: the microphone was read, not asked, and the
            // probe that would have asked never ran.
            #expect(rig.microphoneRequestCount == 0)
            #expect(rig.systemAudioProbeCount == 0)
        }
    }

    @Test func allowOnTheMicrophoneAsksAndReadsTheAnswer() async throws {
        let rig = CaptureRig(microphone: .notDetermined, microphoneAnswer: false)
        try await withSession(rig: rig) { harness in
            await harness.session.requestMicrophoneAccess()
            #expect(rig.microphoneRequestCount == 1)
            #expect(harness.session.microphoneAccess == .denied)
        }
    }

    @Test func allowOnTheMacsAudioAsksOnceAndRemembersThatItAsked() async throws {
        let rig = CaptureRig(systemAudio: [.denied])
        try await withSession(rig: rig) { harness in
            #expect(!harness.settings.hasRequestedSystemAudio)
            await harness.session.requestSystemAudioAccess()
            #expect(rig.systemAudioProbeCount == 1)
            #expect(harness.session.systemAudioAccess == .denied)
            #expect(harness.settings.hasRequestedSystemAudio)
        }
    }

    @Test func onceAskedALookChecksAgain() async throws {
        // Denied, then allowed in System Settings: the next look says so,
        // with no relaunch.
        let rig = CaptureRig(systemAudio: [.denied, .granted])
        try await withSession(rig: rig) { harness in
            await harness.session.requestSystemAudioAccess()
            #expect(harness.session.systemAudioAccess == .denied)
            await harness.session.refreshCaptureAccess()
            #expect(harness.session.systemAudioAccess == .granted)
            #expect(rig.systemAudioProbeCount == 2)
        }
    }

    @Test func aCheckThatCannotTellLeavesTheLastAnswerStanding() async throws {
        let rig = CaptureRig(systemAudio: [.granted, .unknown])
        try await withSession(rig: rig) { harness in
            await harness.session.requestSystemAudioAccess()
            await harness.session.refreshCaptureAccess()
            #expect(harness.session.systemAudioAccess == .granted)
        }
    }

    @Test func aLookWhileAllowWaitsOnTheDialogJoinsIt() async throws {
        let dialog = PassGate()
        let rig = CaptureRig(systemAudio: [.granted], systemAudioGate: dialog)
        try await withSession(rig: rig) { harness in
            let allow = Task { await harness.session.requestSystemAudioAccess() }
            await waitUntil("the probe to wait on the dialog") { dialog.entered == 1 }
            let look = Task { await harness.session.refreshCaptureAccess() }
            // The look joins the check in flight rather than raising a second
            // tap; give it every chance to start one of its own.
            for _ in 0..<1_000 { await Task.yield() }
            #expect(dialog.entered == 1)
            dialog.releaseAll()
            await allow.value
            await look.value
            #expect(rig.systemAudioProbeCount == 1)
            #expect(harness.session.systemAudioAccess == .granted)
        }
    }

    @Test func theFirstRecordGestureCountsAsAsking() async throws {
        // The record gesture's primer raises the same dialog, so after it a
        // check is no longer the first ask.
        try await withSession { harness in
            #expect(await harness.session.start() == nil)
            #expect(harness.settings.hasRequestedSystemAudio)
            await harness.session.stop()
        }
    }
}
