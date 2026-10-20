//
//  SystemAudioOffNoticeTests.swift
//  RecordingTests
//
//  A tap macOS refuses comes up as cleanly as a granted one and delivers
//  silence, so every session checks, once its own tap is up, whether it can
//  hear the Mac's audio at all — and says so when it cannot, with the
//  recording going on from the microphone (product owner, 2026-10-19).
//
//  Driven with the rig's probe: no tone, no process tap.
//

import Audio
import Foundation
import Testing

@testable import Recording

@Suite("RecordingSession — system audio off during a recording")
@MainActor
struct SystemAudioOffNoticeTests {

    private func notice(in session: RecordingSession) -> RecordingNotice? {
        session.notices.first { $0.kind == .systemAudioOff }
    }

    @Test func refusedTheSessionSaysSoAndGoesOnWithTheMicrophone() async throws {
        let rig = CaptureRig(systemAudio: [.denied])
        try await withSession(rig: rig) { harness in
            #expect(await harness.session.start() == nil)
            await waitUntil("the check to land") { notice(in: harness.session) != nil }
            #expect(notice(in: harness.session)?.message == "System audio is off · only you are recorded")
            #expect(harness.session.phase.isRecording)
            #expect(harness.session.systemAudioAccess == .denied)
            #expect(rig.systemAudioProbeCount == 1)
            await harness.session.stop()
        }
    }

    @Test func grantedOrUntoldItSaysNothing() async throws {
        for verdict in [SystemAudioAccess.granted, .unknown] {
            let rig = CaptureRig(systemAudio: [verdict])
            try await withSession(rig: rig) { harness in
                #expect(await harness.session.start() == nil)
                await waitUntil("the check to run") { rig.systemAudioProbeCount == 1 }
                // Let the verdict land, whatever it raises.
                for _ in 0..<1_000 { await Task.yield() }
                #expect(notice(in: harness.session) == nil)
                await harness.session.stop()
            }
        }
    }

    @Test func aVerdictThatLandsAfterTheStopRaisesNothing() async throws {
        let probe = PassGate()
        let rig = CaptureRig(systemAudio: [.denied], systemAudioGate: probe)
        try await withSession(rig: rig) { harness in
            #expect(await harness.session.start() == nil)
            await waitUntil("the check to be in flight") { probe.entered == 1 }
            await harness.session.stop()
            probe.releaseAll()
            await waitUntil("the check to finish") { rig.systemAudioProbeCount == 1 }
            for _ in 0..<1_000 { await Task.yield() }
            #expect(notice(in: harness.session) == nil)
        }
    }

    @Test func everySessionChecksAgainAndStartsClean() async throws {
        // Refused, then allowed in System Settings between two meetings: the
        // second session neither inherits the first's notice nor misses the
        // change.
        let rig = CaptureRig(systemAudio: [.denied, .granted])
        try await withSession(rig: rig) { harness in
            #expect(await harness.session.start() == nil)
            await waitUntil("the first check to land") { notice(in: harness.session) != nil }
            await harness.session.stop()

            #expect(await harness.session.start() == nil)
            await waitUntil("the second check to run") { rig.systemAudioProbeCount == 2 }
            for _ in 0..<1_000 { await Task.yield() }
            #expect(notice(in: harness.session) == nil)
            #expect(harness.session.systemAudioAccess == .granted)
            await harness.session.stop()
        }
    }

    @Test func itRanksWithTheLostMicrophoneAboveHowAChannelSounds() {
        #expect(RecordingNotice.Kind.microphoneUnavailable < .systemAudioOff)
        #expect(RecordingNotice.Kind.systemAudioOff < .echoCancellation)
        #expect(RecordingNotice.Kind.systemAudioOff < .meetingAudioHealth)
    }
}
