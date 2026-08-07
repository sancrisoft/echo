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

    @Test("a segment with no word in it is dropped")
    func wordlessSegmentsAreDropped() {
        // What the model returns for a stretch that holds no speech: a lone
        // punctuation token. Cancelled bleed leaves long stretches of exactly
        // that, and a row reading "You: ." for 25 s is worse than no row.
        let result = cut([
            token("one", 0.0, 0.4),
            TokenTiming(token: ".", tokenId: 0, startTime: 2.0, endTime: 27.3, confidence: 1),
            token("two", 30.0, 30.4),
        ])

        #expect(result.map(\.text) == ["one", "two"])
    }

    @Test("punctuation attached to a word is kept")
    func punctuationRidingOnAWordSurvives() {
        // The rule is about rows with nothing in them, not about stripping
        // punctuation out of real speech.
        let result = cut([
            token("hola", 0.0, 0.4),
            TokenTiming(token: ".", tokenId: 0, startTime: 0.4, endTime: 0.5, confidence: 1),
        ])

        #expect(result.map(\.text) == ["hola."])
    }

    @Test("a digit counts as a word")
    func numbersAreNotPunctuation() {
        let result = cut([token("2026", 0.0, 0.4)])

        #expect(result.map(\.text) == ["2026"])
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

    // MARK: - Cuts land on word boundaries

    /// A sub-word piece: what the model actually emits inside a word, and
    /// what a boundary must never be placed in front of.
    private func piece(_ text: String, _ start: Double, _ end: Double) -> TokenTiming {
        TokenTiming(token: text, tokenId: 0, startTime: start, endTime: end, confidence: 1)
    }

    /// The field regression this exists for. The model emits "break" as
    /// "▁bre" + "ak", so a boundary taken at the straddling token shears the
    /// word in half — a real transcript came back reading "on the bre" / "ak".
    /// The audio still decides THAT the row ends; the tokenization decides
    /// WHERE, and the cut waits for the next word.
    @Test("a silence inside a word cuts at the next word start")
    func silenceNeverSplitsAWord() {
        let timings = [
            token("the", 0.0, 0.4),
            token("bre", 0.5, 1.3), piece("ak", 1.5, 1.8),
            token("now", 1.9, 2.3),
        ]

        #expect(cut(timings, silenceStarts: [1.4]).map(\.text) == ["the break", "now"])
    }

    /// Same for the timing-gap rule: the model reporting a two-second hole in
    /// the middle of a word is a timing artefact, not a pause to cut at.
    @Test("a long token gap inside a word does not split it either")
    func longGapInsideAWordDoesNotSplit() {
        let timings = [token("wor", 0.0, 0.4), piece("d", 2.0, 2.4)]

        #expect(cut(timings).map(\.text) == ["word"])
    }

    /// The cut is deferred, not dropped — a boundary the audio asked for
    /// still lands, at the first place it legally can.
    @Test("a deferred cut still fires at the next word")
    func deferredCutIsNotLost() {
        let timings = [
            token("a", 0.0, 0.4),
            token("b", 0.5, 0.9), piece("c", 1.0, 1.4),
            token("d", 1.5, 1.9), token("e", 2.0, 2.4),
        ]

        #expect(cut(timings, silenceStarts: [0.95]).map(\.text) == ["a bc", "d e"])
    }

    /// Punctuation may open a row: the detokenizer welds it to whatever came
    /// before, so a boundary in front of it strands no word fragment. This is
    /// what keeps the lone "." of a long pause off the end of the last real
    /// word, where it would stretch that row's span across the whole silence.
    @Test("a pause before punctuation still ends the row")
    func punctuationMayStartASegment() {
        let timings = [
            token("hola", 0.0, 0.4),
            piece(".", 2.0, 2.2),
            token("adios", 2.3, 2.7),
        ]

        #expect(cut(timings, silenceStarts: []).map(\.text) == ["hola", ". adios"])
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
