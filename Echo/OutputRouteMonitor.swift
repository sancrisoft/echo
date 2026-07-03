//
//  OutputRouteMonitor.swift
//  Echo
//
//  Resolves and watches the default audio output device and classifies it
//  into an `OutputRouteClass` for the echo-handling mode machine.
//

import CoreAudio
import os

/// Maps a device's (transport type, data-source selector) to an
/// `OutputRouteClass`. Pure and deterministic — the Core Audio reads live in
/// `OutputRouteMonitor`.
nonisolated enum OutputRouteClassifier {

    /// Data-source selector for the built-in loudspeakers ('ispk').
    static let internalSpeakerDataSource: UInt32 = 0x6973_706B

    /// Data-source selector for headphones on the built-in jack ('hdpn').
    static let headphoneDataSource: UInt32 = 0x6864_706E

    /// Ambiguity maps to `.unsupported`: misclassifying headphones as
    /// unsupported is harmless (no echo to cancel), misclassifying a
    /// loudspeaker as headphones is not (SP-001 Reliability).
    static func classify(transportType: UInt32, dataSource: UInt32?) -> OutputRouteClass {
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
final class OutputRouteMonitor {

    static let log = Logger(subsystem: "com.sancrisoft.Echo", category: "OutputRouteMonitor")

    var onRouteChange: ((OutputRouteClass) -> Void)?

    private var listenerBlock: AudioObjectPropertyListenerBlock?
    private var dataSourceDeviceID: AudioObjectID?

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

    // MARK: - Lifecycle

    /// Classifies the default output device right now.
    func currentRoute() -> OutputRouteClass {
        guard let deviceID = defaultOutputDeviceID() else { return .unsupported }
        let transport = readUInt32(deviceID, Self.transportTypeAddress) ?? kAudioDeviceTransportTypeUnknown
        let dataSource = readUInt32(deviceID, Self.dataSourceAddress)
        return OutputRouteClassifier.classify(transportType: transport, dataSource: dataSource)
    }

    func start() {
        guard listenerBlock == nil else { return }
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            // Listeners are registered on the main queue, so this hop is safe.
            MainActor.assumeIsolated { self?.handleChange() }
        }
        listenerBlock = block

        var address = Self.defaultOutputAddress
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, block)
        attachDataSourceListener()
    }

    func stop() {
        guard let block = listenerBlock else { return }
        var address = Self.defaultOutputAddress
        AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, block)
        detachDataSourceListener()
        listenerBlock = nil
    }

    // MARK: - Listeners

    private func handleChange() {
        // The default device may have changed; follow it with the data-source
        // listener before reporting (headphones in/out on the built-in device
        // only fires the data-source property, not the default-device one).
        detachDataSourceListener()
        attachDataSourceListener()

        let route = currentRoute()
        Self.log.info("Output route changed: \(String(describing: route), privacy: .public)")
        onRouteChange?(route)
    }

    private func attachDataSourceListener() {
        guard let block = listenerBlock, let deviceID = defaultOutputDeviceID() else { return }
        var address = Self.dataSourceAddress
        guard AudioObjectHasProperty(deviceID, &address) else { return }
        AudioObjectAddPropertyListenerBlock(deviceID, &address, .main, block)
        dataSourceDeviceID = deviceID
    }

    private func detachDataSourceListener() {
        guard let block = listenerBlock, let deviceID = dataSourceDeviceID else { return }
        var address = Self.dataSourceAddress
        AudioObjectRemovePropertyListenerBlock(deviceID, &address, .main, block)
        dataSourceDeviceID = nil
    }

    // MARK: - Core Audio helpers

    private func defaultOutputDeviceID() -> AudioObjectID? {
        guard let deviceID = readUInt32(AudioObjectID(kAudioObjectSystemObject), Self.defaultOutputAddress),
              deviceID != kAudioObjectUnknown
        else { return nil }
        return deviceID
    }

    private func readUInt32(_ objectID: AudioObjectID, _ address: AudioObjectPropertyAddress) -> UInt32? {
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var address = address
        guard AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }
}
