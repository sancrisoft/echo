//
//  OutputRouteClassifierTests.swift
//  AudioTests
//
//  The output-route classification table. Pure arithmetic over (transport
//  type, data-source selector) pairs — the Core Audio reads that produce
//  those pairs live in the monitor shim and stay manual, so nothing here
//  touches a device.
//
//  The table's shape is the defended behavior: only the built-in transport
//  with a recognized selector classifies, and everything else — including a
//  built-in device whose selector is missing or unknown — falls to
//  `.unsupported`. Calling headphones unsupported costs nothing (there is no
//  echo to cancel); calling a loudspeaker headphones is the harmful
//  direction.
//

import Audio
import CoreAudio
import Testing

struct OutputRouteClassifierTests {

    @Test func builtInTransportWithInternalSpeakerDataSourceIsBuiltInSpeakers() {
        let route = OutputRouteClassifier.classify(
            transportType: kAudioDeviceTransportTypeBuiltIn,
            dataSource: OutputRouteClassifier.internalSpeakerDataSource
        )
        #expect(route == .builtInSpeakers)
    }

    @Test func builtInTransportWithHeadphoneDataSourceIsHeadphones() {
        let route = OutputRouteClassifier.classify(
            transportType: kAudioDeviceTransportTypeBuiltIn,
            dataSource: OutputRouteClassifier.headphoneDataSource
        )
        #expect(route == .headphones)
    }

    @Test(
        arguments: [
            (kAudioDeviceTransportTypeBluetooth, OutputRouteClassifier.headphoneDataSource),
            (kAudioDeviceTransportTypeBluetoothLE, nil),
            (kAudioDeviceTransportTypeAggregate, nil),
            (kAudioDeviceTransportTypeVirtual, nil),
            (kAudioDeviceTransportTypeUnknown, nil),
            (kAudioDeviceTransportTypeHDMI, nil),
            (kAudioDeviceTransportTypeUSB, nil),
            (kAudioDeviceTransportTypeBuiltIn, nil),  // no data-source selector
            (kAudioDeviceTransportTypeBuiltIn, UInt32(0x6C69_6E65)),  // unrecognized selector ('line')
        ] as [(UInt32, UInt32?)])
    func ambiguousRoutesAreUnsupported(transportType: UInt32, dataSource: UInt32?) {
        let route = OutputRouteClassifier.classify(transportType: transportType, dataSource: dataSource)
        #expect(route == .unsupported)
    }
}
