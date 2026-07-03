//
//  InputDeviceMonitor.swift
//  Echo
//
//  Follows the macOS default input device for SP-002: capture follows the
//  new device on every change, losing the last device degrades the session
//  to Team-only, and a returning device brings the mic back automatically.
//
//  Structure mirrors `OutputRouteMonitor.swift`: the decisions live in
//  `InputDeviceLifecycleMachine`, which is pure and fully unit-tested; the
//  Core Audio reads live in the thin `InputDeviceMonitor` shim below.
//

import CoreAudio
import os

/// Deterministic machine mapping default-input-device events to mic-side
/// capture actions during a recording session.
///
/// Its `Action` type models mic capture control and the mic-unavailable
/// notice only — a stop-recording outcome, or anything touching the
/// system/Team capture path, is unrepresentable (SP-002 Reliability: device
/// churn is "never a crash or a stopped recording"; the Team channel is
/// inviolable). Device disappearance needs no case of its own: when macOS
/// falls back to another device the listener just reports the new identity,
/// and only "no input device remains" degrades the session.
///
/// The event surface is UI-free on purpose: the input-health classifier
/// (ADR-006) will consume the same device events in a later slice.
nonisolated struct InputDeviceLifecycleMachine {

    /// Core Audio device identity (`AudioDeviceID`), kept as a plain UInt32
    /// so the machine stays importable without Core Audio.
    typealias DeviceID = UInt32

    enum Event: Equatable, Sendable {
        /// A session began; `device` is the default input at that moment
        /// (`nil` on a Mac with no input device at all).
        case recordingStarted(device: DeviceID?)
        case recordingStopped
        /// The default input device changed; `nil` means no input device
        /// remains (SP-002: disappearance with fallback arrives as the
        /// fallback device's identity, not as a loss).
        case defaultInputChanged(DeviceID?)
        /// The mic engine failed to (re)start on the current device — e.g.
        /// it vanished between the listener event and the engine rebuild.
        case micCaptureFailed
    }

    /// Requested side effects, applied by `RecordingController`. A mic
    /// restart is always accompanied by `resetEchoProcessing`: SP-001
    /// requires echo processing to reset and re-converge on every
    /// input-device change.
    enum Action: Equatable, Sendable {
        case restartMicCapture
        case resetEchoProcessing
        case stopMicCapture
        case showMicUnavailableNotice
        case clearMicUnavailableNotice
    }

    private(set) var isRecording = false

    /// The device mic capture is (believed to be) running on; `nil` while
    /// degraded or idle.
    private(set) var captureDevice: DeviceID?

    /// True while the session runs Team-only because no input device is
    /// usable — one degradation episode, one notice (SP-002 Reliability).
    private(set) var isMicDegraded = false

    /// Whether the session should have mic capture running right now.
    var expectsMicCapture: Bool { isRecording && !isMicDegraded }

    @discardableResult
    mutating func handle(_ event: Event) -> [Action] {
        switch event {
        case .recordingStarted(let device):
            guard !isRecording else { return [] }
            isRecording = true
            captureDevice = device
            guard device == nil else { return [] }
            // No input device at session start (e.g. a desktop Mac without a
            // microphone): begin Team-only instead of failing.
            isMicDegraded = true
            return [.showMicUnavailableNotice]

        case .recordingStopped:
            guard isRecording else { return [] }
            isRecording = false
            captureDevice = nil
            guard isMicDegraded else { return [] }
            // Stopping ends the degradation episode; the notice goes with it.
            isMicDegraded = false
            return [.clearMicUnavailableNotice]

        case .defaultInputChanged(let device):
            guard isRecording else { return [] }
            if isMicDegraded {
                // Still no device: same episode, no re-notice (flapping spam
                // guard). A device appearing ends the episode; identity does
                // not matter — mic capture was stopped, so it must restart
                // even if the old device returned with its old ID.
                guard let device else { return [] }
                captureDevice = device
                isMicDegraded = false
                return [.restartMicCapture, .resetEchoProcessing, .clearMicUnavailableNotice]
            }
            // Listeners can fire without an identity change; a restart costs
            // a capture gap, so same-device events are no-ops.
            guard device != captureDevice else { return [] }
            guard let device else {
                // No input device remains: mic side stops, Team capture is
                // untouched, one notice for the episode.
                captureDevice = nil
                isMicDegraded = true
                return [.stopMicCapture, .showMicUnavailableNotice]
            }
            captureDevice = device
            return [.restartMicCapture, .resetEchoProcessing]

        case .micCaptureFailed:
            guard isRecording, !isMicDegraded else { return [] }
            captureDevice = nil
            isMicDegraded = true
            return [.stopMicCapture, .showMicUnavailableNotice]
        }
    }
}

/// User-facing wording for the mic-unavailable degradation (SP-002; English
/// only per project rules). Pure so the mapping stays unit-testable.
nonisolated enum InputDeviceNotice {
    static let micUnavailableMessage =
        "Microphone unavailable — recording continues with meeting audio only."
}

/// Watches the default input device and reports its identity on every change
/// (`nil` when no input device remains at all).
///
/// Thin shim in the `OutputRouteMonitor` mold: raw Core Audio default-input
/// changes are the single restart trigger. `.AVAudioEngineConfigurationChange`
/// was considered and rejected — it carries no device identity (so spurious
/// fires could not be deduplicated, and our own engine rebuilds would risk
/// notification→restart loops) and it cannot express "no input device
/// remains", which this feature must classify.
final class InputDeviceMonitor {

    static let log = Logger(subsystem: "com.sancrisoft.Echo", category: "InputDeviceMonitor")

    /// Reports the new default input device; `nil` means none exists.
    var onDefaultInputChange: ((InputDeviceLifecycleMachine.DeviceID?) -> Void)?

    private var listenerBlock: AudioObjectPropertyListenerBlock?

    private static let defaultInputAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultInputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    /// The current default input device, `nil` when no input device exists
    /// (Core Audio reports `kAudioObjectUnknown` in that case).
    func currentDefaultInputDevice() -> InputDeviceLifecycleMachine.DeviceID? {
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = Self.defaultInputAddress
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID
        )
        guard status == noErr, deviceID != kAudioObjectUnknown else { return nil }
        return deviceID
    }

    func start() {
        guard listenerBlock == nil else { return }
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            // Listeners are registered on the main queue, so this hop is safe.
            MainActor.assumeIsolated { self?.handleChange() }
        }
        listenerBlock = block

        var address = Self.defaultInputAddress
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, block)
    }

    func stop() {
        guard let block = listenerBlock else { return }
        var address = Self.defaultInputAddress
        AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, block)
        listenerBlock = nil
    }

    private func handleChange() {
        let device = currentDefaultInputDevice()
        Self.log.info("""
        Default input device changed: \(device.map(String.init) ?? "none", privacy: .public)
        """)
        onDefaultInputChange?(device)
    }
}
