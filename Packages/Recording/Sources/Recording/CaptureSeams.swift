//
//  CaptureSeams.swift
//  Recording
//
//  The two capture seams, and they live here rather than in `Audio` on
//  purpose. `Audio` dropped the PoC's `AudioCaptureSource` protocol because
//  nothing consumed it polymorphically: its only effect was to force two
//  genuinely different sources to share a surface. Recording IS the
//  polymorphic consumer — a session has to be drivable from a fake that emits
//  samples, levels and gaps on demand, because no test may open a real
//  microphone or a real process tap — so the protocols belong to the
//  consumer, and `Audio` keeps its concrete classes.
//
//  Two protocols, not one, for the reason the merged one failed: the starts
//  really differ. `MicrophoneCapture.start()` awaits a permission check;
//  `SystemAudioCapture.start(scope:)` is synchronous and takes coverage. The
//  PoC's `async` on the system side existed only to satisfy the protocol.
//
//  The callbacks are not in the protocols either. Both sources take them as
//  `init` parameters (they are `Sendable` and their callbacks run on the
//  render thread and the IO queue, so what those threads read must be
//  immutable), which means a session cannot set them after the fact and must
//  build the source around them. That is what the factories express.
//

import Audio
import CoreAudio
import EchoCore
import Foundation

/// The microphone side of a session.
protocol MicCapturing: Sendable {
    /// Prompts for permission if needed, then brings the engine up.
    func start() async throws
    func stop()
}

/// The system-audio side of a session.
protocol SystemCapturing: Sendable {
    /// `.everything` is the global tap; `.app` taps one app's process set and
    /// follows it live.
    func start(scope: CaptureScope) throws
    func stop()
    /// What the tap actually delivered, or nil when it never activated.
    ///
    /// In the seam because the stop path reads it, and because a fake that
    /// cannot report delivery cannot exercise the retention accounting that
    /// exists to explain the Others channel's measured shortfall. Defaulted,
    /// so a fake that has nothing to report says so rather than inventing
    /// figures.
    func deliveryStats() -> SystemAudioCapture.DeliveryStats?
}

extension SystemCapturing {
    func deliveryStats() -> SystemAudioCapture.DeliveryStats? { nil }
}

/// The echo-cancellation engine, as a session needs it: the stage itself plus
/// the health it reports.
///
/// A protocol rather than a downcast to `WebRTCAECStage`, because the health
/// wiring is the part a test has to drive — an engine that never came up, and
/// an engine that fails mid-session, are the two cases that produce the
/// degradation notice, and neither can be reached through a real engine in a
/// package test.
protocol EchoCancelling: AECStage {

    /// Whether the engine came up and is processing frames.
    var isEngineHealthy: Bool { get }

    /// Receives health TRANSITIONS — and only transitions, which is why a
    /// session also reads `isEngineHealthy` once at start: an engine that
    /// failed before anyone was listening never reports it.
    func setEngineEventHandler(_ handler: (@Sendable (Bool) -> Void)?)
}

extension WebRTCAECStage: EchoCancelling {
    var isEngineHealthy: Bool { isHealthy }
    func setEngineEventHandler(_ handler: (@Sendable (Bool) -> Void)?) {
        onEngineEvent = handler
    }
}

/// The default-input-device watcher. Same seam story as the capture sources:
/// the callback is an `init` parameter, so a session builds the watcher rather
/// than configuring one, and a test injects an inert one and drives the events
/// through the session directly.
protocol InputDeviceWatching: Sendable {
    /// The current default input, or nil when the Mac has none at all.
    func currentDefaultInputDevice() -> InputDeviceLifecycleMachine.DeviceID?
    func start()
    func stop()
}

/// The output-route watcher, which reports the classified route and the raw
/// device change separately — the route first, so echo handling has already
/// switched mode by the time a tap rebuild is requested.
protocol OutputRouteWatching: Sendable {
    func currentRoute() -> OutputRouteClass
    func start()
    func stop()
}

// The real sources conform as they are: the protocols were shaped around
// them, so there is nothing to forward and no adapter type earns its keep.
extension MicrophoneCapture: MicCapturing {}
extension SystemAudioCapture: SystemCapturing {}
extension InputDeviceMonitor: InputDeviceWatching {}
extension OutputRouteMonitor: OutputRouteWatching {}

/// Decodes one meeting's retained audio into its final transcript.
///
/// A seam for the same reason the capture sources are: the real pass loads a
/// 480 MB Core ML model and decodes minutes of audio, and what Recording owns
/// is not the decode but what surrounds it — the admission gate, the retry
/// budget, the atomic replace and the audio's disposal. Those are what the
/// tests are about.
typealias TranscriptionPassRunning =
    @Sendable (
        _ retainedFiles: [AudioChannel: URL],
        _ shouldYield: @escaping @Sendable () -> Bool,
        _ onProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> [TranscriptSegment]

/// Builds the two sources and the echo-cancellation engine a session needs.
///
/// A struct of closures rather than a protocol: there is exactly one
/// production implementation and one test implementation per closure, and a
/// test usually replaces one of the three.
struct CaptureFactories: Sendable {

    /// `onSamples` receives 16 kHz mono Float32 on the AVAudioEngine render
    /// thread; `onLevel` receives one un-averaged reading per callback.
    var makeMicrophone:
        @Sendable (
            _ onSamples: @escaping @Sendable ([Float]) -> Void,
            _ onLevel: @escaping @Sendable (Double) -> Void
        ) -> any MicCapturing

    /// `onLevel` is optional because the reference tap a scoped session runs
    /// must not have one: nothing from it is ever metered, shown, persisted
    /// or transcribed.
    var makeSystem:
        @Sendable (
            _ onSamples: @escaping @Sendable ([Float]) -> Void,
            _ onLevel: (@Sendable (Double) -> Void)?
        ) -> any SystemCapturing

    /// A fresh engine stage per session, so no adaptation state leaks across
    /// recordings and an init failure only degrades the session that hit it.
    var makeEchoCanceller: @Sendable () -> any EchoCancelling

    /// Raises both OS permission dialogs, in order, on the first record
    /// gesture.
    ///
    /// A seam because a package test runs with no host and may not raise a
    /// real TCC prompt or start a real process tap: on a machine whose
    /// microphone status is still undetermined, the live implementation
    /// blocks on a dialog nobody is there to answer.
    var primePermissions: @Sendable () async -> Void

    var makeInputDeviceWatcher:
        @Sendable (
            _ onDefaultInputChange:
                @escaping @Sendable (InputDeviceLifecycleMachine.DeviceID?) ->
                Void
        ) -> any InputDeviceWatching

    var makeOutputRouteWatcher:
        @Sendable (
            _ onRouteChange: @escaping @Sendable (OutputRouteClass) -> Void,
            _ onDefaultOutputDeviceChange: @escaping @Sendable (AudioObjectID) -> Void
        ) -> any OutputRouteWatching

    static let live = CaptureFactories(
        makeMicrophone: { onSamples, onLevel in
            MicrophoneCapture(onSamples: onSamples, onLevel: onLevel)
        },
        makeSystem: { onSamples, onLevel in
            SystemAudioCapture(onSamples: onSamples, onLevel: onLevel)
        },
        makeEchoCanceller: { WebRTCAECStage() },
        primePermissions: {
            // Sequential and in this order: the microphone prompt is the one
            // the user expects from a record gesture, and the system-audio
            // probe is a real throwaway tap, because that prompt only fires
            // when a process tap actually runs.
            _ = await MicrophoneCapture.requestPermission()
            await SystemAudioCapture.primePermission()
        },
        makeInputDeviceWatcher: { onChange in
            InputDeviceMonitor(onDefaultInputChange: onChange)
        },
        makeOutputRouteWatcher: { onRoute, onDevice in
            OutputRouteMonitor(onRouteChange: onRoute, onDefaultOutputDeviceChange: onDevice)
        }
    )
}
