//
//  ParakeetSegmentShapingTests.swift
//  EchoTests
//
//  Turning one channel's token timings into segments. A segment is the unit
//  the dedup suppresses, so where the cutter puts a boundary decides what can
//  ever be separated from what — which is why the cutter takes its pauses from
//  the audio and not only from the model's estimate of when it heard a token.
//
//  Synthetic timings throughout; no meeting text.
//

import FluidAudio
import Foundation
import Testing
@testable import Echo

@Suite("ParakeetPass segment shaping")
struct ParakeetSegmentShapingTests {

    /// One word, `▁`-prefixed so it reads as a word start.
    private func token(_ word: String, _ start: Double, _ end: Double) -> TokenTiming {
        TokenTiming(
            token: ParakeetPass.wordBoundary + word,
            tokenId: 0,
            startTime: start,
            endTime: end,
            confidence: 1
        )
    }

    private func cut(
        _ timings: [TokenTiming], silenceStarts: [TimeInterval] = []
    ) -> [TranscriptSegment] {
        ParakeetPass.segments(
            from: timings,
            text: "",
            duration: timings.last?.endTime ?? 0,
            channel: .microphone,
            silenceStarts: silenceStarts
        )
    }

    // MARK: - Token timings alone

    @Test("a gap longer than segmentGapSeconds splits")
    func longTokenGapSplits() {
        let result = cut([
            token("one", 0.0, 0.4), token("two", 0.5, 0.9),
            token("three", 2.0, 2.4),
        ])

        #expect(result.map(\.text) == ["one two", "three"])
    }

    @Test("a gap shorter than segmentGapSeconds does not")
    func shortTokenGapDoesNotSplit() {
        let result = cut([
            token("one", 0.0, 0.4), token("two", 0.9, 1.3),
        ])

        #expect(result.map(\.text) == ["one two"])
    }

    // MARK: - Silence from the audio

    /// The case this exists for. The user stops at 1.0 s, the room is quiet
    /// until 1.7 s, then an echo starts — but the model reports its first echo
    /// token starting at 1.4 s, so the token gap is only 0.4 s and the
    /// timing-based rule sees nothing to split. The audio did.
    @Test("a silence the token timings papered over still splits")
    func audioSilenceSplitsWhereTokenGapDoesNot() {
        let timings = [
            token("mine", 0.4, 1.0),
            token("echo", 1.4, 2.0), token("tail", 2.1, 2.6),
        ]

        #expect(cut(timings).map(\.text) == ["mine echo tail"])
        #expect(cut(timings, silenceStarts: [1.1]).map(\.text) == ["mine", "echo tail"])
    }

    /// The boundary is the instant the channel fell quiet, not the middle of
    /// the pause: a token whose reported start was dragged back into the
    /// silence still lands on the far side of it.
    @Test("a token whose timing was dragged back into the pause still splits off")
    func boundaryIsTheStartOfTheSilence() {
        let timings = [
            token("mine", 0.4, 1.0),
            token("echo", 1.2, 2.0),   // before the pause's midpoint of 1.4
        ]

        #expect(cut(timings, silenceStarts: [1.1]).map(\.text) == ["mine", "echo"])
    }

    /// A pause a single token spans cannot be cut — there is no boundary
    /// inside a word — and it must not fire on the following token either.
    @Test("a silence swallowed by one token splits nothing")
    func silenceInsideATokenIsIgnored() {
        let timings = [
            token("stretched", 0.4, 2.0), token("next", 2.1, 2.5),
        ]

        #expect(cut(timings, silenceStarts: [1.0]).map(\.text) == ["stretched next"])
    }

    @Test("each silence fires at most once")
    func silencesAreConsumed() {
        let timings = [
            token("a", 0.0, 0.4), token("b", 1.0, 1.4),
            token("c", 1.5, 1.9), token("d", 2.0, 2.4),
        ]

        #expect(cut(timings, silenceStarts: [0.5]).map(\.text) == ["a", "b c d"])
    }

    @Test("several silences make several segments")
    func multipleSilences() {
        let timings = [
            token("a", 0.0, 0.4), token("b", 1.0, 1.4), token("c", 2.0, 2.4),
        ]

        #expect(cut(timings, silenceStarts: [0.5, 1.5]).map(\.text) == ["a", "b", "c"])
    }

    /// Silence before the first token or after the last has nothing to split.
    @Test("silences outside the spoken range are harmless")
    func silencesOutsideTheRange() {
        let timings = [token("a", 5.0, 5.4), token("b", 5.5, 5.9)]

        #expect(cut(timings, silenceStarts: [0.0, 1.0, 9.0]).map(\.text) == ["a b"])
    }
}

@Suite("EnergyEnvelope silence")
struct EnergyEnvelopeSilenceTests {

    private let rate = AudioConstants.sampleRate

    private func buffer(_ spans: [(level: Float, seconds: Double)]) -> [Float] {
        spans.flatMap { Array(repeating: $0.level, count: Int(rate * $0.seconds)) }
    }

    @Test("a quiet stretch is reported at the instant it starts")
    func reportsTheStart() {
        // 1 s of speech, 0.5 s of silence, 1 s of speech.
        let envelope = EnergyEnvelope(samples: buffer([
            (0.05, 1.0), (0.0, 0.5), (0.05, 1.0),
        ]))

        let starts = envelope.silenceStarts(minimum: 0.3)

        #expect(starts.count == 1)
        #expect(abs((starts.first ?? 0) - 1.0) < 0.15)
    }

    @Test("stretches shorter than the minimum are not boundaries")
    func shortGapsAreIgnored() {
        let envelope = EnergyEnvelope(samples: buffer([
            (0.05, 1.0), (0.0, 0.2), (0.05, 1.0),
        ]))

        #expect(envelope.silenceStarts(minimum: 0.3).isEmpty)
    }

    /// Quiet bleed is not silence: it carries words, and cutting inside it is
    /// fine but calling it a pause would be wrong. The floor sits between the
    /// measured true silence (0.0004–0.0008) and the quietest bleed (0.003).
    @Test("audio at bleed level is not silence")
    func bleedLevelIsNotSilence() {
        let envelope = EnergyEnvelope(samples: buffer([
            (0.05, 1.0), (0.004, 0.8), (0.05, 1.0),
        ]))

        #expect(envelope.silenceStarts(minimum: 0.3).isEmpty)
    }

    @Test("a run reaching the end of the channel still closes")
    func trailingSilenceCloses() {
        let envelope = EnergyEnvelope(samples: buffer([(0.05, 1.0), (0.0, 1.0)]))

        #expect(envelope.silenceStarts(minimum: 0.3).count == 1)
    }

    @Test("every stretch is reported, in order")
    func allStretchesInOrder() {
        let envelope = EnergyEnvelope(samples: buffer([
            (0.05, 0.5), (0.0, 0.5), (0.05, 0.5), (0.0, 0.5), (0.05, 0.5),
        ]))

        let starts = envelope.silenceStarts(minimum: 0.3)

        #expect(starts.count == 2)
        #expect(starts == starts.sorted())
    }

    @Test("a wholly silent channel is one boundary at zero")
    func fullySilentChannel() {
        let envelope = EnergyEnvelope(samples: buffer([(0.0, 2.0)]))

        #expect(envelope.silenceStarts(minimum: 0.3) == [0.0])
    }

    @Test("a channel with no silence has no boundaries")
    func noSilence() {
        let envelope = EnergyEnvelope(samples: buffer([(0.05, 2.0)]))

        #expect(envelope.silenceStarts(minimum: 0.3).isEmpty)
    }
}
