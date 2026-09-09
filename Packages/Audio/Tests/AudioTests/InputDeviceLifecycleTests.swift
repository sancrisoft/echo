//
//  InputDeviceLifecycleTests.swift
//  AudioTests
//
//  The input-device lifecycle machine's full table: default input-device
//  changes mid-recording are handled automatically — capture follows the new
//  device, echo processing resets and re-converges, and losing the last input
//  device degrades the session to Others-only with a once-per-episode notice,
//  never a stopped recording.
//
//  Pure event→action tests. The Core Audio listener shim
//  (`InputDeviceMonitor`) attaches real system listeners, so it is never
//  started here; live hot-plug behavior stays manual.
//
//  `@testable` only because `InputDeviceLifecycleMachine`'s default
//  initializer is not `public`, so the machine cannot be constructed from
//  outside the package at all — see the port note in the report.
//

import Testing

@testable import Audio

struct InputDeviceLifecycleTests {

    /// A machine mid-session, capturing from `device`.
    private func recordingMachine(device: UInt32? = 1) -> InputDeviceLifecycleMachine {
        var machine = InputDeviceLifecycleMachine()
        machine.handle(.recordingStarted(device: device))
        return machine
    }

    // MARK: - Default-input change mid-recording

    @Test func defaultInputChangeMidRecordingRestartsMicAndResetsEchoProcessing() {
        var machine = recordingMachine(device: 1)

        let actions = machine.handle(.defaultInputChanged(2))

        #expect(actions == [.restartMicCapture, .resetEchoProcessing])
        #expect(machine.captureDevice == 2)
        #expect(machine.expectsMicCapture)
    }

    @Test func repeatedEventForTheSameDeviceIsSpurious() {
        // Core Audio listeners can fire without an identity change; a restart
        // costs a capture gap, so same-device events must be no-ops.
        var machine = recordingMachine(device: 1)
        #expect(machine.handle(.defaultInputChanged(1)).isEmpty)
        #expect(machine.captureDevice == 1)
    }

    @Test func deviceDisappearanceWithFallbackIsJustADeviceChange() {
        // Unplugging the default input makes macOS promote another device; the
        // listener only ever observes the new identity, so disappearance with
        // fallback is indistinguishable from a plain switch — and must behave
        // identically: a device change like any other.
        var machine = recordingMachine(device: 7)

        let actions = machine.handle(.defaultInputChanged(3))

        #expect(actions == [.restartMicCapture, .resetEchoProcessing])
        #expect(machine.captureDevice == 3)
        #expect(machine.expectsMicCapture)
    }

    // MARK: - No input device remains (Others-only degradation)

    @Test func losingTheLastInputDeviceDegradesToOthersOnlyWithOneNotice() {
        var machine = recordingMachine(device: 1)

        let actions = machine.handle(.defaultInputChanged(nil))

        // Mic side only: `Action` has no case that could touch the system
        // capture path, so Others-only continuation is structural.
        #expect(actions == [.stopMicCapture, .showMicUnavailableNotice])
        #expect(!machine.expectsMicCapture)

        // Repeated no-device events belong to the same episode: no re-notice.
        #expect(machine.handle(.defaultInputChanged(nil)).isEmpty)
    }

    @Test func deviceReturnRestartsMicResetsEchoProcessingAndClearsTheNotice() {
        var machine = recordingMachine(device: 1)
        machine.handle(.defaultInputChanged(nil))

        let actions = machine.handle(.defaultInputChanged(5))

        #expect(actions == [.restartMicCapture, .resetEchoProcessing, .clearMicUnavailableNotice])
        #expect(machine.expectsMicCapture)
        #expect(machine.captureDevice == 5)
    }

    @Test func recoveryToTheSameDeviceIdentityStillRestarts() {
        // A replugged device can come back with its old ID; mic capture was
        // stopped during the episode, so recovery must restart regardless.
        var machine = recordingMachine(device: 1)
        machine.handle(.defaultInputChanged(nil))

        let actions = machine.handle(.defaultInputChanged(1))

        #expect(actions == [.restartMicCapture, .resetEchoProcessing, .clearMicUnavailableNotice])
    }

    @Test func startingWithNoInputDeviceBeginsOthersOnlyWithANotice() {
        // Desktop Macs without a microphone: the session starts Others-only
        // instead of failing, and the first device to appear brings the mic up
        // with a fresh canceller.
        var machine = InputDeviceLifecycleMachine()

        let actions = machine.handle(.recordingStarted(device: nil))
        #expect(actions == [.showMicUnavailableNotice])
        #expect(!machine.expectsMicCapture)

        let recovery = machine.handle(.defaultInputChanged(4))
        #expect(recovery == [.restartMicCapture, .resetEchoProcessing, .clearMicUnavailableNotice])
        #expect(machine.expectsMicCapture)
    }

    @Test func micCaptureFailureDegradesInsteadOfEndingTheSession() {
        // The engine can fail to start on a device that vanished between the
        // listener event and the rebuild (or reports an unusable format):
        // that is a degradation, not a session failure.
        var machine = recordingMachine(device: 1)

        let actions = machine.handle(.micCaptureFailed)

        #expect(actions == [.stopMicCapture, .showMicUnavailableNotice])
        #expect(!machine.expectsMicCapture)

        // A failure while already degraded stays within the same episode.
        #expect(machine.handle(.micCaptureFailed).isEmpty)
    }

    // MARK: - Notice discipline under flapping: once per episode

    @Test func flappingYieldsOneNoticePerEpisodeAndResetsEchoProcessingOnEveryRecovery() {
        var machine = recordingMachine(device: 1)

        let flapping: [InputDeviceLifecycleMachine.Event] = [
            .defaultInputChanged(nil),  // episode 1 begins
            .defaultInputChanged(2),  // recovery
            .defaultInputChanged(nil),  // episode 2 begins
            .defaultInputChanged(nil),  // repeated loss inside episode 2
            .defaultInputChanged(3),  // recovery
        ]

        var shows = 0
        var clears = 0
        var resets = 0
        for event in flapping {
            for action in machine.handle(event) {
                switch action {
                case .showMicUnavailableNotice: shows += 1
                case .clearMicUnavailableNotice: clears += 1
                case .resetEchoProcessing: resets += 1
                default: break
                }
            }
        }

        #expect(shows == 2)  // exactly one notice per degradation episode
        #expect(clears == 2)  // clearing automatically on each recovery
        #expect(resets == 2)  // every recovery re-converges the canceller
        #expect(machine.expectsMicCapture)
        #expect(machine.captureDevice == 3)
    }

    @Test func stoppingWhileDegradedClosesTheEpisodeAndClearsTheNotice() {
        var machine = recordingMachine(device: 1)
        machine.handle(.defaultInputChanged(nil))

        #expect(machine.handle(.recordingStopped) == [.clearMicUnavailableNotice])
        #expect(!machine.expectsMicCapture)
    }

    // MARK: - Inert outside a session

    @Test func deviceEventsWhileNotRecordingAreInert() {
        var machine = InputDeviceLifecycleMachine()

        #expect(machine.handle(.defaultInputChanged(2)).isEmpty)
        #expect(machine.handle(.defaultInputChanged(nil)).isEmpty)
        #expect(machine.handle(.micCaptureFailed).isEmpty)
        #expect(!machine.expectsMicCapture)

        // Same once a session has ended.
        machine.handle(.recordingStarted(device: 1))
        machine.handle(.recordingStopped)
        #expect(machine.handle(.defaultInputChanged(3)).isEmpty)
        #expect(machine.handle(.micCaptureFailed).isEmpty)
    }

    @Test func redundantLifecycleEventsAreIgnored() {
        var machine = InputDeviceLifecycleMachine()
        #expect(machine.handle(.recordingStopped).isEmpty)

        machine.handle(.recordingStarted(device: 1))
        #expect(machine.handle(.recordingStarted(device: 9)).isEmpty)
        #expect(machine.captureDevice == 1)
    }

    // MARK: - Global safety sweep

    /// No input-device event sequence may ever stop, fail, or lose a
    /// recording. `Action` models mic-side capture control and the
    /// mic-unavailable notice only, so a stop-recording (or any
    /// system-channel) outcome is unrepresentable — mirroring
    /// `EchoModeMachine.Effect`. This sweep additionally verifies that the
    /// notice never spams (a show is always followed by a clear before the
    /// next show), that every mic restart carries an echo-processing reset
    /// (reset and re-converge on every input-device change), and that the
    /// machine never expects mic capture without a known device.
    @Test func noEventSequenceStopsARecordingOrSpamsNotices() {
        let events: [InputDeviceLifecycleMachine.Event] = [
            .recordingStarted(device: 1),
            .recordingStopped,
            .defaultInputChanged(1),
            .defaultInputChanged(2),
            .defaultInputChanged(nil),
            .micCaptureFailed,
        ]

        var sequences: [[InputDeviceLifecycleMachine.Event]] = [[]]
        for _ in 0..<4 {
            sequences = sequences.flatMap { prefix in events.map { prefix + [$0] } }
        }

        for sequence in sequences {
            var machine = InputDeviceLifecycleMachine()
            var noticeShowing = false
            for event in sequence {
                let actions = machine.handle(event)

                if actions.contains(.restartMicCapture) {
                    #expect(
                        actions.contains(.resetEchoProcessing),
                        "mic restart without an echo reset: \(sequence)"
                    )
                }

                for action in actions {
                    switch action {
                    case .showMicUnavailableNotice:
                        #expect(!noticeShowing, "notice re-fired within an episode: \(sequence)")
                        noticeShowing = true
                    case .clearMicUnavailableNotice:
                        #expect(noticeShowing, "clear without a preceding show: \(sequence)")
                        noticeShowing = false
                    default:
                        break
                    }
                }

                if machine.expectsMicCapture {
                    #expect(machine.captureDevice != nil, "capturing without a device: \(sequence)")
                }
                if !machine.isRecording {
                    #expect(
                        actions.isEmpty || actions == [.clearMicUnavailableNotice],
                        "actions outside a session: \(sequence)"
                    )
                }
            }
        }
    }
}
