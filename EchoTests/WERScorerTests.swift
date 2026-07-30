//
//  WERScorerTests.swift
//  EchoTests
//
//  SP-005 S2, Testing Decisions layer 1: pure tables over the WER scorer's
//  arithmetic and normalization (prior art: ModelDownloadProgressTests'
//  table style). The accuracy harness's fixture numbers are only meaningful
//  once every row here is.
//

import Foundation
import Testing
@testable import Echo

struct WERScorerTests {

    // MARK: Alignment counts

    @Test(arguments: [
        // (reference, hypothesis, substitutions, insertions, deletions)
        ("the cat sat", "the cat sat", 0, 0, 0),
        ("the cat sat", "the dog sat", 1, 0, 0),
        ("the cat sat on the mat", "the dog sat on that mat", 2, 0, 0),
        ("the cat", "the big cat", 0, 1, 0),
        ("the cat sat", "well the cat sat now", 0, 2, 0),
        ("the big cat", "the cat", 0, 0, 1),
        ("one two three four", "two three", 0, 0, 2),
        // Mixed: two substitutions plus a trailing insertion.
        ("the quick brown fox", "the slow brown wolf jumps", 2, 1, 0),
    ] as [(String, String, Int, Int, Int)])
    func alignmentCountsMatchHandComputedValues(
        row: (reference: String, hypothesis: String, s: Int, i: Int, d: Int)
    ) {
        let counts = WERScorer.score(reference: row.reference, hypothesis: row.hypothesis)
        #expect(counts.substitutions == row.s)
        #expect(counts.insertions == row.i)
        #expect(counts.deletions == row.d)
    }

    @Test func werIsErrorsOverReferenceLength() {
        #expect(WERScorer.score(reference: "a b c d", hypothesis: "a b x d").wer == 0.25)
        #expect(WERScorer.score(reference: "the cat sat", hypothesis: "the dog sat").wer == 1.0 / 3.0)
        #expect(WERScorer.score(reference: "hola qué tal", hypothesis: "hola qué tal").wer == 0)
    }

    // MARK: Normalization

    @Test func caseAndPunctuationNeverCount() {
        #expect(WERScorer.normalize("Hello, World!") == ["hello", "world"])
        #expect(WERScorer.score(reference: "Hello, World!", hypothesis: "hello world").errors == 0)
    }

    @Test func intraWordApostrophesAndHyphensSurvive() {
        #expect(WERScorer.normalize("Don't over-think it.") == ["don't", "over-think", "it"])
        // The typographic apostrophe equals the straight one…
        #expect(WERScorer.score(reference: "don\u{2019}t stop", hypothesis: "don't stop").errors == 0)
        // …but a missing apostrophe still changes the word.
        #expect(WERScorer.score(reference: "don't stop", hypothesis: "dont stop").substitutions == 1)
    }

    /// SP-005: accents are meaning-bearing — an accent miss is a real error.
    @Test func spanishAccentsAreRealErrors() {
        let counts = WERScorer.score(reference: "cómo estás", hypothesis: "como estas")
        #expect(counts.substitutions == 2)
        #expect(counts.wer == 1.0)
        #expect(WERScorer.score(reference: "cómo estás", hypothesis: "cómo estás").errors == 0)
    }

    @Test func unicodeFormsCompareEqualAfterNFC() {
        // "café" precomposed vs "e" + combining acute accent.
        #expect(WERScorer.score(reference: "café", hypothesis: "cafe\u{0301}").errors == 0)
    }

    @Test func whitespaceRunsCollapse() {
        #expect(WERScorer.score(reference: "hello   world", hypothesis: " hello\nworld ").errors == 0)
    }

    /// The user's normal case: es/en mixed in one utterance — only the
    /// accent miss counts, not the language mixing.
    @Test func mixedSpanishEnglishScoresOnlyTheAccentMiss() {
        let counts = WERScorer.score(
            reference: "vamos a revisar the deployment mañana por la morning",
            hypothesis: "Vamos a revisar the deployment manana por la morning."
        )
        #expect(counts.substitutions == 1)
        #expect(counts.errors == 1)
        #expect(counts.wer == 1.0 / 9.0)
    }

    // MARK: Edges

    @Test func emptyAgainstEmptyIsAPerfectScore() {
        let counts = WERScorer.score(reference: "", hypothesis: "")
        #expect(counts == WERScorer.Counts())
        #expect(counts.wer == 0)
    }

    @Test func textInventedOverAnEmptyReferenceIsAllInsertions() {
        let counts = WERScorer.score(reference: "", hypothesis: "hello there")
        #expect(counts.insertions == 2)
        #expect(counts.substitutions == 0)
        #expect(counts.deletions == 0)
        #expect(counts.wer == .infinity)
    }

    @Test func emptyHypothesisIsAllDeletions() {
        let counts = WERScorer.score(reference: "hello there friend", hypothesis: "")
        #expect(counts.deletions == 3)
        #expect(counts.wer == 1.0)
    }

    @Test func punctuationOnlyHypothesisNormalizesToEmpty() {
        let counts = WERScorer.score(reference: "hello", hypothesis: "... — !!")
        #expect(counts.deletions == 1)
        #expect(counts.insertions == 0)
    }

    // MARK: Segment convenience

    @Test func segmentConvenienceJoinsTextInStartOrder() {
        let segments = [
            TranscriptSegment(channel: .system, speaker: .teammates, text: "second part", start: 10, end: 12),
            TranscriptSegment(channel: .system, speaker: .teammates, text: "First part,", start: 2, end: 4),
        ]
        #expect(WERScorer.joinedText(segments) == "First part, second part")
        #expect(WERScorer.score(reference: "first part second part", segments: segments).errors == 0)
    }
}
