//
//  OutputRouteClassifierTests.swift
//  EchoTests
//

import CoreAudio
import Testing
@testable import Echo

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

    @Test(arguments: [
        (kAudioDeviceTransportTypeBluetooth, OutputRouteClassifier.headphoneDataSource),
        (kAudioDeviceTransportTypeBluetoothLE, nil),
        (kAudioDeviceTransportTypeAggregate, nil),
        (kAudioDeviceTransportTypeVirtual, nil),
        (kAudioDeviceTransportTypeUnknown, nil),
        (kAudioDeviceTransportTypeHDMI, nil),
        (kAudioDeviceTransportTypeUSB, nil),
        (kAudioDeviceTransportTypeBuiltIn, nil),                    // no data-source selector
        (kAudioDeviceTransportTypeBuiltIn, UInt32(0x6C69_6E65)),    // unrecognized selector ('line')
    ] as [(UInt32, UInt32?)])
    func ambiguousRoutesAreUnsupported(transportType: UInt32, dataSource: UInt32?) {
        let route = OutputRouteClassifier.classify(transportType: transportType, dataSource: dataSource)
        #expect(route == .unsupported)
    }
}
