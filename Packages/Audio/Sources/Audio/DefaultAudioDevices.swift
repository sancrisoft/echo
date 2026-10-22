//
//  DefaultAudioDevices.swift
//  Audio
//
//  Which device Core Audio currently considers the default, for the four
//  places in this package that need to ask: the system tap anchors its
//  aggregate to the output device, the route monitor classifies it, the input
//  monitor watches the input device, and the DEBUG fixture recorder records
//  which one a take was captured on. One reader rather than four copies of
//  the same property dance.
//

import CoreAudio

enum DefaultAudioDevices {

    /// The device where app audio actually plays (e.g. the external
    /// monitor), NOT `DefaultSystemOutputDevice` — that one is the alerts
    /// device and can differ.
    static func outputDeviceID() -> AudioObjectID? {
        deviceID(for: kAudioHardwarePropertyDefaultOutputDevice)
    }

    /// The device the microphone channel records from.
    static func inputDeviceID() -> AudioObjectID? {
        deviceID(for: kAudioHardwarePropertyDefaultInputDevice)
    }

    private static func deviceID(for selector: AudioObjectPropertySelector) -> AudioObjectID? {
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID
            ) == noErr,
            deviceID != kAudioObjectUnknown
        else { return nil }
        return deviceID
    }
}
