//
//  ParakeetSpanRmsTests.swift
//  EchoTests
//
//  The pass's dedup evidence (ADR-003 v2 Tier B): each produced segment's rms
//  over its own span of its own channel's samples. Pure arithmetic over
//  synthetic buffers — the load-bearing rows are the boundary ones, because a
//  span that runs off the end of the buffer must contribute nothing rather
//  than a wrong number or a crash.
//

import Foundation
import Testing
@testable import Echo

@Suite("ParakeetPass span rms")
struct ParakeetSpanRmsTests {

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

    /// A buffer that is `level` for the first second and silent for the next.
    private func twoSecondBuffer(level: Float) -> [Float] {
        Array(repeating: level, count: Int(rate)) + Array(repeating: 0, count: Int(rate))
    }

    @Test("a segment reads the rms of its own span, not the channel's")
    func spanIsLocalNotGlobal() {
        let samples = twoSecondBuffer(level: 0.5)
        let loud = segment(.microphone, start: 0.0, end: 1.0)
        let quiet = segment(.microphone, start: 1.0, end: 2.0)

        let levels = ParakeetPass.spanRms(of: [loud, quiet], in: samples)

        #expect(levels[loud.id] == 0.5)
        #expect(levels[quiet.id] == 0)
    }

    @Test("levels are keyed by segment id so both channels merge into one map")
    func keyedBySegmentID() {
        let mic = segment(.microphone, start: 0.0, end: 1.0)
        let system = segment(.system, start: 0.0, end: 1.0)

        var levels = ParakeetPass.spanRms(of: [mic], in: twoSecondBuffer(level: 0.25))
        levels.merge(ParakeetPass.spanRms(of: [system], in: twoSecondBuffer(level: 0.5))) { a, _ in a }

        #expect(levels[mic.id] == 0.25)
        #expect(levels[system.id] == 0.5)
    }

    /// The pass hands the map to a policy that treats a missing entry as
    /// "no evidence" and keeps the segment — so an unmeasurable span must be
    /// ABSENT, never zero, which would read as maximally quiet.
    @Test("spans that cannot be measured are absent, not zero")
    func unmeasurableSpansAreOmitted() {
        let samples = twoSecondBuffer(level: 0.5)
        let empty = segment(.microphone, start: 1.0, end: 1.0)
        let inverted = segment(.microphone, start: 1.5, end: 0.5)
        let pastTheEnd = segment(.microphone, start: 3.0, end: 4.0)

        let levels = ParakeetPass.spanRms(of: [empty, inverted, pastTheEnd], in: samples)

        #expect(levels.isEmpty)
    }

    @Test("a span running past the end of the buffer is clamped, not read out of bounds")
    func trailingSpanIsClamped() {
        let samples = twoSecondBuffer(level: 0.5)
        // 0.5 s of signal, then 1.5 s that only partly exists.
        let overhang = segment(.microphone, start: 0.5, end: 2.5)

        let levels = ParakeetPass.spanRms(of: [overhang], in: samples)

        // Half a second at 0.5 and one silent second, over the 1.5 s that
        // exists: sqrt((0.5 * 0.25) / 1.5).
        let expected = (0.5 * 0.25 / 1.5).squareRoot()
        #expect(abs(Double(levels[overhang.id] ?? 0) - expected) < 0.001)
    }

    @Test("a negative start is clamped to the beginning of the buffer")
    func leadingSpanIsClamped() {
        let samples = twoSecondBuffer(level: 0.5)
        let overhang = segment(.microphone, start: -1.0, end: 1.0)

        #expect(ParakeetPass.spanRms(of: [overhang], in: samples)[overhang.id] == 0.5)
    }

    @Test("an empty buffer yields no evidence at all")
    func emptyBufferYieldsNothing() {
        let any = segment(.microphone, start: 0.0, end: 1.0)

        #expect(ParakeetPass.spanRms(of: [any], in: []).isEmpty)
    }
}
