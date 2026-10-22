//
//  InputDeviceMonitor.swift
//  Audio
//
//  Follows the macOS default input device: capture follows the new device on
//  every change, losing the last device degrades the session to Others-only,
//  and a returning device brings the mic back automatically.
//
//  Structure mirrors `OutputRouteMonitor.swift`: the decisions live in
//  `InputDeviceLifecycleMachine`, which is pure and fully table-tested; the
//  Core Audio reads live in the thin `InputDeviceMonitor` shim below.
//
//  Isolation (ADR-002). As with the route monitor, v1's main-queue listener
//  and `MainActor.assumeIsolated` hop were artefacts of its main-actor
//  default isolation. The listener runs on this monitor's own serial queue,
//  the callback is immutable, and the listener handle sits behind a lock.
//

import CoreAudio
import EchoCore
import Synchronization
import os

/// Deterministic machine mapping default-input-device events to mic-side
/// capture actions during a recording session.
///
/// Its `Action` type models mic capture control and the mic-unavailable
/// notice only — a stop-recording outcome, or anything touching the system
/// capture path, is unrepresentable: device churn is never a crash and never
/// a stopped recording, and the Others channel is inviolable. Device
/// disappearance needs no case of its own — when macOS falls back to another
/// device the listener simply reports the new identity, and only "no input
/// device remains" degrades the session.
///
/// The event surface is UI-free on purpose: the input-health classifier
/// consumes the same device events, and where a notice is SHOWN is decided
/// by whichever surface renders it, not here.
public struct InputDeviceLifecycleMachine: Sendable {

    /// Core Audio device identity (`AudioDeviceID`), kept as a plain UInt32
    /// so the machine stays importable without Core Audio.
    public typealias DeviceID = UInt32

    public enum Event: Equatable, Sendable {
        /// A session began; `device` is the default input at that moment
        /// (`nil` on a Mac with no input device at all).
        case recordingStarted(device: DeviceID?)
        case recordingStopped
        /// The default input device changed; `nil` means no input device
        /// remains — disappearance WITH a fallback arrives as the fallback
        /// device's identity, not as a loss.
        case defaultInputChanged(DeviceID?)
        /// The mic engine failed to (re)start on the current device — e.g.
        /// it vanished between the listener event and the engine rebuild.
        case micCaptureFailed
    }

    /// Requested side effects, applied by Recording. A mic restart is always
    /// accompanied by `resetEchoProcessing`: echo processing has to reset and
    /// re-converge on every input-device change.
    public enum Action: Equatable, Sendable {
        case restartMicCapture
        case resetEchoProcessing
        case stopMicCapture
        case showMicUnavailableNotice
        case clearMicUnavailableNotice
    }

    public private(set) var isRecording = false

    /// The device mic capture is (believed to be) running on; `nil` while
    /// degraded or idle.
    public private(set) var captureDevice: DeviceID?

    /// True while the session runs Others-only because no input device is
    /// usable — one degradation episode, one notice.
    public private(set) var isMicDegraded = false

    /// Whether the session should have mic capture running right now.
    public var expectsMicCapture: Bool { isRecording && !isMicDegraded }

    /// Explicit because every stored property above has a default, which
    /// would otherwise leave the memberwise initializer internal and make
    /// this machine unconstructable from Recording, its actual driver.
    public init() {}

    @discardableResult
    public mutating func handle(_ event: Event) -> [Action] {
        switch event {
        case .recordingStarted(let device):
            guard !isRecording else { return [] }
            isRecording = true
            captureDevice = device
            guard device == nil else { return [] }
            // No input device at session start (e.g. a desktop Mac without a
            // microphone): begin Others-only instead of failing.
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
                // No input device remains: mic side stops, system capture is
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

/// User-facing wording for the mic-unavailable degradation. A value, not a
/// view: where it is shown is the rendering surface's decision.
public enum InputDeviceNotice {
    public static let micUnavailableMessage =
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
public final class InputDeviceMonitor: Sendable {

    private static let log = Logger(subsystem: AppIdentity.logSubsystem, category: "InputDeviceMonitor")

    /// Reports the new default input device; `nil` means none exists.
    private let onDefaultInputChange: (@Sendable (InputDeviceLifecycleMachine.DeviceID?) -> Void)?

    /// Where the listener fires. Serial, so a burst cannot overlap.
    private let queue = DispatchQueue(label: "com.sancrisoft.Echo.inputDevice")

    /// `@unchecked Sendable` because a listener block is not `Sendable`; the
    /// lock is the only way in, and only start/stop touch it.
    private struct State: @unchecked Sendable {
        var listenerBlock: AudioObjectPropertyListenerBlock?
    }

    private let state = Mutex(State())

    public init(
        onDefaultInputChange: (@Sendable (InputDeviceLifecycleMachine.DeviceID?) -> Void)? = nil
    ) {
        self.onDefaultInputChange = onDefaultInputChange
    }

    private static let defaultInputAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultInputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    /// The current default input device, `nil` when no input device exists
    /// (Core Audio reports `kAudioObjectUnknown` in that case).
    public func currentDefaultInputDevice() -> InputDeviceLifecycleMachine.DeviceID? {
        DefaultAudioDevices.inputDeviceID()
    }

    public func start() {
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.handleChange()
        }
        let armed = state.withLock { state -> Bool in
            guard state.listenerBlock == nil else { return false }
            state.listenerBlock = block
            return true
        }
        guard armed else { return }

        var address = Self.defaultInputAddress
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, block)
    }

    public func stop() {
        let block = state.withLock { state -> AudioObjectPropertyListenerBlock? in
            let previous = state.listenerBlock
            state.listenerBlock = nil
            return previous
        }
        guard let block else { return }
        var address = Self.defaultInputAddress
        AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, block)
    }

    private func handleChange() {
        let device = currentDefaultInputDevice()
        Self.log.info(
            """
            Default input device changed: \(device.map(String.init) ?? "none", privacy: .public)
            """)
        onDefaultInputChange?(device)
    }
}
