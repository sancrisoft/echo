//
//  ParakeetSpanLevelsTests.swift
//  EchoTests
//
//  The pass's dedup evidence (ADR-003 v2 Tier B): both channels' rms over each
//  segment's OWN window, carried by a frame-quantized energy envelope so the
//  comparison survives the pass decoding one channel at a time.
//
//  Pure arithmetic over synthetic buffers. The load-bearing rows are the
//  boundary ones, because a span that cannot be measured on both channels must
//  contribute no evidence rather than a wrong number — the policy reads a
//  missing entry as "keep" and a zero as "maximally quiet".
//

import Foundation
import Testing
@testable import Echo

@Suite("EnergyEnvelope")
struct EnergyEnvelopeTests {

    private let rate = AudioConstants.sampleRate

    /// `level` for the first second, silence for the second.
    private func twoSecondBuffer(level: Float) -> [Float] {
        Array(repeating: level, count: Int(rate)) + Array(repeating: 0, count: Int(rate))
    }

    @Test("a window reads the level of its own span, not the channel's")
    func windowIsLocalNotGlobal() {
        let envelope = EnergyEnvelope(samples: twoSecondBuffer(level: 0.5))

        #expect(envelope.rms(from: 0.0, to: 1.0) == 0.5)
        #expect(envelope.rms(from: 1.0, to: 2.0) == 0)
    }

    @Test("a window spanning loud and silent audio averages their energy")
    func windowAveragesEnergy() {
        let envelope = EnergyEnvelope(samples: twoSecondBuffer(level: 0.5))

        // One second at 0.5 and one silent: sqrt(0.25 / 2).
        let expected = (0.25 / 2.0).squareRoot()
        #expect(abs(Double(envelope.rms(from: 0.0, to: 2.0) ?? 0) - expected) < 0.001)
    }

    @Test("windows past either end are clamped, not read out of bounds")
    func windowsAreClamped() {
        let envelope = EnergyEnvelope(samples: twoSecondBuffer(level: 0.5))

        #expect(envelope.rms(from: -1.0, to: 1.0) == 0.5)
        #expect(envelope.rms(from: 0.0, to: 60.0) != nil)
    }

    @Test("a window covering no frame has no answer at all")
    func unmeasurableWindowsAreNil() {
        let envelope = EnergyEnvelope(samples: twoSecondBuffer(level: 0.5))

        #expect(envelope.rms(from: 1.0, to: 1.0) == nil)      // empty
        #expect(envelope.rms(from: 1.5, to: 0.5) == nil)      // inverted
        #expect(envelope.rms(from: 30.0, to: 31.0) == nil)    // past the end
        #expect(EnergyEnvelope(samples: []).rms(from: 0.0, to: 1.0) == nil)
    }

    /// The envelope replaces holding both channels' samples; it must still
    /// report a level a policy threshold can be applied to.
    @Test("the envelope reproduces a known rms within frame quantization")
    func envelopeMatchesDirectRMS() {
        var samples = [Float](repeating: 0, count: Int(rate * 2))
        for i in samples.indices {
            samples[i] = sin(Float(i) * 0.05) * 0.2
        }
        let direct = AudioStats.rms(samples, from: 0, count: samples.count)

        let envelope = EnergyEnvelope(samples: samples).rms(from: 0.0, to: 2.0) ?? 0

        #expect(abs(envelope - direct) < 0.001)
    }
}

@Suite("ParakeetPass span levels")
struct ParakeetSpanLevelsTests {

    private let rate = AudioConstants.sampleRate

    private func segment(_ channel: AudioChannel, start: Double, end: Double) -> TranscriptSegment {
        TranscriptSegment(
            channel: channel,
            speaker: Speaker(defaultFor: channel),
            text: "synthetic",
            start: start,
            end: end
        )
    }

    private func envelope(level: Float, seconds: Double = 2.0) -> EnergyEnvelope {
        EnergyEnvelope(samples: Array(repeating: level, count: Int(rate * seconds)))
    }

    /// `own` is the segment's own channel and `other` the opposite one — over
    /// the same window. Getting these two the wrong way round would invert the
    /// discriminator, so both channels' segments get an explicit row.
    @Test("each segment carries its own channel's level and the opposite one's")
    func ownAndOtherAreOrientedByChannel() {
        let micSegment = segment(.microphone, start: 0.0, end: 1.0)
        let systemSegment = segment(.system, start: 0.0, end: 1.0)
        let envelopes: [AudioChannel: EnergyEnvelope] = [
            .microphone: envelope(level: 0.1),
            .system: envelope(level: 0.4),
        ]

        let levels = ParakeetPass.spanLevels(
            of: [micSegment, systemSegment], envelopes: envelopes
        )

        #expect(abs((levels[micSegment.id]?.own ?? 0) - 0.1) < 0.001)
        #expect(abs((levels[micSegment.id]?.other ?? 0) - 0.4) < 0.001)
        #expect(abs((levels[systemSegment.id]?.own ?? 0) - 0.4) < 0.001)
        #expect(abs((levels[systemSegment.id]?.other ?? 0) - 0.1) < 0.001)
    }

    /// A one-channel meeting has nothing to compare against, so it yields no
    /// evidence — and Tier B simply never fires, which is the right answer:
    /// with no system audio there is no bleed.
    @Test("a segment with only one channel measurable carries no evidence")
    func halfMeasuredSpansAreOmitted() {
        let micSegment = segment(.microphone, start: 0.0, end: 1.0)
        let envelopes: [AudioChannel: EnergyEnvelope] = [.microphone: envelope(level: 0.1)]

        #expect(ParakeetPass.spanLevels(of: [micSegment], envelopes: envelopes).isEmpty)
    }

    /// Channels can differ in length (capture starts and stops are not
    /// simultaneous): a span only the longer one covers has no ratio.
    @Test("a span past the shorter channel's end carries no evidence")
    func spansPastTheShorterChannelAreOmitted() {
        let late = segment(.microphone, start: 3.0, end: 4.0)
        let envelopes: [AudioChannel: EnergyEnvelope] = [
            .microphone: envelope(level: 0.1, seconds: 10.0),
            .system: envelope(level: 0.4, seconds: 2.0),
        ]

        #expect(ParakeetPass.spanLevels(of: [late], envelopes: envelopes).isEmpty)
    }
}
