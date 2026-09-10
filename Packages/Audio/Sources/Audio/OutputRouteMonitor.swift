//
//  OutputRouteMonitor.swift
//  Audio
//
//  Resolves and watches the default audio output device and classifies it
//  into an `OutputRouteClass` for the echo-handling mode machine.
//
//  Isolation (ADR-002). v1 registered its listeners on the main queue and
//  hopped through `MainActor.assumeIsolated`, both artefacts of the
//  main-actor default isolation this package does not use. The listener now
//  runs on the monitor's own serial queue, which is also where the mutable
//  state lives, so the confinement is real; the callbacks are immutable and
//  handed over at construction.
//

import CoreAudio
import EchoCore
import Synchronization
import os

/// Maps a device's (transport type, data-source selector) to an
/// `OutputRouteClass`. Pure and deterministic — the Core Audio reads live in
/// `OutputRouteMonitor`.
public enum OutputRouteClassifier {

    /// Data-source selector for the built-in loudspeakers ('ispk').
    public static let internalSpeakerDataSource: UInt32 = 0x6973_706B

    /// Data-source selector for headphones on the built-in jack ('hdpn').
    public static let headphoneDataSource: UInt32 = 0x6864_706E

    /// Ambiguity maps to `.unsupported`: misclassifying headphones as
    /// unsupported is harmless (there is no echo to cancel), misclassifying a
    /// loudspeaker as headphones is not.
    public static func classify(transportType: UInt32, dataSource: UInt32?) -> OutputRouteClass {
        guard transportType == kAudioDeviceTransportTypeBuiltIn else { return .unsupported }
        switch dataSource {
        case internalSpeakerDataSource:
            return .builtInSpeakers
        case headphoneDataSource:
            return .headphones
        default:
            return .unsupported
        }
    }
}

/// Watches the default output device (and its data-source selector, which is
/// how the built-in device distinguishes loudspeakers from jack headphones)
/// and reports the classified route on every change.
public final class OutputRouteMonitor: Sendable {

    private static let log = Logger(subsystem: AppIdentity.logSubsystem, category: "OutputRouteMonitor")

    /// Reports the classified route on every change.
    private let onRouteChange: (@Sendable (OutputRouteClass) -> Void)?

    /// Fires when the default output DEVICE ITSELF changes — AirPods
    /// connecting mid-meeting, a monitor waking up — as opposed to the
    /// classified route above, which collapses every non-built-in device into
    /// `.unsupported` and so cannot tell one pair of headphones from another.
    ///
    /// The system-audio tap needs this because its aggregate device is built
    /// around whichever device was default at start and keeps that anchor —
    /// and that device's sample rate — after the sound moves elsewhere. Echo
    /// handling reads the classified route; capture reads this.
    private let onDefaultOutputDeviceChange: (@Sendable (AudioObjectID) -> Void)?

    /// Where the listeners fire and where every mutation below happens.
    /// Serial, so a burst of notifications cannot overlap.
    private let queue = DispatchQueue(label: "com.sancrisoft.Echo.outputRoute")

    /// `@unchecked Sendable` because it holds a listener block, which is not
    /// `Sendable`. Only `queue` and the start/stop calls touch it, always
    /// under this lock.
    private struct State: @unchecked Sendable {
        var listenerBlock: AudioObjectPropertyListenerBlock?
        var dataSourceDeviceID: AudioObjectID?
        /// Deduplicates: the listeners fire on data-source changes and on
        /// spurious notifications too, and a rebuild is only owed to a real
        /// device swap.
        var lastDefaultOutputDeviceID: AudioObjectID?
    }

    private let state = Mutex(State())

    private static let defaultOutputAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    private static let dataSourceAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyDataSource,
        mScope: kAudioObjectPropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain
    )

    private static let transportTypeAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyTransportType,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    public init(
        onRouteChange: (@Sendable (OutputRouteClass) -> Void)? = nil,
        onDefaultOutputDeviceChange: (@Sendable (AudioObjectID) -> Void)? = nil
    ) {
        self.onRouteChange = onRouteChange
        self.onDefaultOutputDeviceChange = onDefaultOutputDeviceChange
    }

    // MARK: - Lifecycle

    /// Classifies the default output device right now.
    public func currentRoute() -> OutputRouteClass {
        guard let deviceID = DefaultAudioDevices.outputDeviceID() else { return .unsupported }
        let transport = Self.readUInt32(deviceID, Self.transportTypeAddress) ?? kAudioDeviceTransportTypeUnknown
        let dataSource = Self.readUInt32(deviceID, Self.dataSourceAddress)
        return OutputRouteClassifier.classify(transportType: transport, dataSource: dataSource)
    }

    public func start() {
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.handleChange()
        }
        let armed = state.withLock { state -> Bool in
            guard state.listenerBlock == nil else { return false }
            state.listenerBlock = block
            // Seeded so the first real swap reads as a change and a session
            // that never changes device never reports one.
            state.lastDefaultOutputDeviceID = DefaultAudioDevices.outputDeviceID()
            return true
        }
        guard armed else { return }

        var address = Self.defaultOutputAddress
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, block)
        attachDataSourceListener()
    }

    public func stop() {
        detachDataSourceListener()
        let block = state.withLock { state -> AudioObjectPropertyListenerBlock? in
            let previous = state.listenerBlock
            state.listenerBlock = nil
            state.lastDefaultOutputDeviceID = nil
            return previous
        }
        guard let block else { return }
        var address = Self.defaultOutputAddress
        AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, block)
    }

    // MARK: - Listeners

    private func handleChange() {
        // The default device may have changed; follow it with the data-source
        // listener before reporting (headphones in and out on the built-in
        // device only fires the data-source property, not the default-device
        // one).
        detachDataSourceListener()
        attachDataSourceListener()

        let route = currentRoute()
        Self.log.info("Output route changed: \(String(describing: route), privacy: .public)")
        onRouteChange?(route)

        // Reported AFTER the route, so echo handling has already switched
        // mode by the time capture rebuilds on the new device.
        guard let deviceID = DefaultAudioDevices.outputDeviceID() else { return }
        let isNewDevice = state.withLock { state -> Bool in
            guard deviceID != state.lastDefaultOutputDeviceID else { return false }
            state.lastDefaultOutputDeviceID = deviceID
            return true
        }
        guard isNewDevice else { return }
        Self.log.info("Default output device changed: \(deviceID, privacy: .public)")
        onDefaultOutputDeviceChange?(deviceID)
    }

    private func attachDataSourceListener() {
        guard let block = state.withLock({ $0.listenerBlock }),
            let deviceID = DefaultAudioDevices.outputDeviceID()
        else { return }
        var address = Self.dataSourceAddress
        guard AudioObjectHasProperty(deviceID, &address) else { return }
        // The id is remembered only once the attach actually succeeded. v1
        // stored it either way, so a failed attach left `detach` removing a
        // listener that was never added — harmless, but it made the pair
        // asymmetric and the state a lie about what is attached.
        guard AudioObjectAddPropertyListenerBlock(deviceID, &address, queue, block) == noErr else { return }
        state.withLock { $0.dataSourceDeviceID = deviceID }
    }

    private func detachDataSourceListener() {
        let attached = state.withLock { state -> (AudioObjectPropertyListenerBlock, AudioObjectID)? in
            guard let block = state.listenerBlock, let deviceID = state.dataSourceDeviceID else { return nil }
            state.dataSourceDeviceID = nil
            return (block, deviceID)
        }
        guard let (block, deviceID) = attached else { return }
        var address = Self.dataSourceAddress
        AudioObjectRemovePropertyListenerBlock(deviceID, &address, queue, block)
    }

    // MARK: - Core Audio helpers

    private static func readUInt32(
        _ objectID: AudioObjectID,
        _ address: AudioObjectPropertyAddress
    ) -> UInt32? {
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var address = address
        guard AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }
}
