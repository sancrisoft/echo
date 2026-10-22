//
//  CaptureAccessTests.swift
//  RecordingTests
//
//  The welcome screen's two permission rows read the session. Neither read
//  asks: the microphone's permission is read from macOS every time, the Mac's
//  audio from TCC's record once a run. Allow on the Mac's audio raises the
//  dialog and leaves the answer to be read once Echo reopens.
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

    @Test func aLookReadsBothAndAsksForNeither() async throws {
        let rig = CaptureRig(microphone: .notDetermined, systemAudioRecord: [.granted])
        try await withSession(rig: rig) { harness in
            await harness.session.refreshCaptureAccess()
            #expect(harness.session.microphoneAccess == .undecided)
            #expect(harness.session.systemAudioAccess == .granted)
            // Neither dialog, and no tone: both were read, not asked.
            #expect(rig.microphoneRequestCount == 0)
            #expect(rig.systemAudioRequestCount == 0)
            #expect(rig.systemAudioProbeCount == 0)
        }
    }

    @Test func theMacsAudioIsReadFromTheRecordOnceARun() async throws {
        // The record read is right only the first time in a process; a
        // change after it shows when Echo reopens.
        let rig = CaptureRig(systemAudioRecord: [.denied, .granted])
        try await withSession(rig: rig) { harness in
            await harness.session.refreshCaptureAccess()
            await harness.session.refreshCaptureAccess()
            #expect(harness.session.systemAudioAccess == .denied)
            #expect(rig.systemAudioRecordReadCount == 1)
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

    @Test func allowOnTheMacsAudioAsksAndAwaitsARelaunch() async throws {
        let rig = CaptureRig(systemAudioRecord: [.unknown])
        try await withSession(rig: rig) { harness in
            await harness.session.refreshCaptureAccess()
            #expect(!harness.settings.hasRequestedSystemAudio)
            await harness.session.requestSystemAudioAccess()
            #expect(rig.systemAudioRequestCount == 1)
            #expect(harness.settings.hasRequestedSystemAudio)
            #expect(harness.session.systemAudioAwaitsRelaunch)
            // The answer is not guessed: it is read after Echo reopens.
            #expect(harness.session.systemAudioAccess == .undecided)
            #expect(rig.systemAudioProbeCount == 0)
        }
    }

    @Test func aSecondAllowWhileTheDialogIsUpAsksNothing() async throws {
        let dialog = PassGate()
        let rig = CaptureRig(systemAudioRequestGate: dialog)
        try await withSession(rig: rig) { harness in
            let first = Task { await harness.session.requestSystemAudioAccess() }
            await waitUntil("the request to wait on the dialog") { dialog.entered == 1 }
            await harness.session.requestSystemAudioAccess()
            dialog.releaseAll()
            await first.value
            await harness.session.requestSystemAudioAccess()
            #expect(dialog.entered == 1)
            #expect(rig.systemAudioRequestCount == 1)
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
