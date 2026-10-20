//
//  SystemAudioAccessTests.swift
//  AudioTests
//
//  The System Audio Recording probe's verdict, as a pure rule over what its
//  tap delivered while Echo's own tone played. The probe itself plays audio
//  and opens a process tap, which no package test may do; it was measured on
//  hardware instead (the #92 spike, 2026-10-19), and these pin the rule those
//  measurements set and the tone they were made with.
//

import Foundation
import Testing

@testable import Audio

@Suite("System Audio Recording — the probe's verdict")
struct SystemAudioAccessTests {

    @Test(
        "any sample of the tone heard is a grant; cycles of exact zeros are a denial; no cycles is no answer",
        arguments: [
            (cycles: 10, nonZero: 4_800, expected: SystemAudioAccess.granted),
            (cycles: 10, nonZero: 1, expected: .granted),
            (cycles: 10, nonZero: 0, expected: .denied),
            (cycles: 0, nonZero: 0, expected: .unknown),
        ] as [(cycles: Int, nonZero: Int, expected: SystemAudioAccess)])
    func verdict(cycles: Int, nonZero: Int, expected: SystemAudioAccess) {
        #expect(SystemAudioAccess.verdict(cycles: cycles, nonZeroSamples: nonZero) == expected)
    }

    @Test("the tone is the measured one: inaudible, and well above what a 16-bit output rounds away")
    func theTone() {
        let decibels = 20 * log10(Double(SystemAudioAccessProbe.toneAmplitude))
        #expect(abs(decibels - -80) < 0.01)
        let sixteenBitStep = 1.0 / 32_768
        #expect(Double(SystemAudioAccessProbe.toneAmplitude) > 3 * sixteenBitStep)
        #expect(SystemAudioAccessProbe.toneFrequency == 1_000)
    }

    @Test("it listens for a moment, and waits for a first cycle only so long")
    func theWindows() {
        #expect(SystemAudioAccessProbe.listenWindow == 0.1)
        #expect(SystemAudioAccessProbe.firstCycleTimeout == 1)
        #expect(SystemAudioAccessProbe.listenWindow < SystemAudioAccessProbe.firstCycleTimeout)
    }
}
