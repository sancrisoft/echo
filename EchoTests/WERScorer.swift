//
//  WERScorer.swift
//  EchoTests
//
//  SP-005 S2 (Testing Decisions layer 1): the word-error-rate arithmetic the
//  accuracy harness scores fixtures with. Pure test-target support code
//  (like FixtureSupport) — no fixture number is trustworthy unless this is.
//
//  Normalization policy, applied identically to reference and hypothesis
//  before alignment:
//    1. Unicode NFC (precomposed), so "café" composed and decomposed
//       compare equal.
//    2. Lowercased — letter case is never a transcription error.
//    3. Typographic apostrophes (U+2019) become straight apostrophes —
//       quote style is never a word difference.
//    4. Tokenized on whitespace; any run of spaces/newlines collapses.
//    5. Per token, punctuation is stripped: letters and digits are kept,
//       and an apostrophe or ASCII hyphen survives only BETWEEN two kept
//       characters ("don't", "well-known") — leading/trailing ones go, and
//       a token left empty (pure punctuation) vanishes. Other joiners
//       (em-dashes, slashes, …) are stripped without splitting the token.
//    6. Diacritics are PRESERVED: Spanish accents are meaning-bearing, so
//       «como» vs «cómo» counts as a real substitution (SP-005).
//

import Foundation
@testable import Echo

nonisolated enum WERScorer {

    /// One scored comparison: the S/I/D decomposition of a word-level
    /// Levenshtein alignment, plus the word counts it was computed over.
    struct Counts: Equatable, Sendable {
        var substitutions = 0
        var insertions = 0
        var deletions = 0
        var referenceWordCount = 0
        var hypothesisWordCount = 0

        var errors: Int { substitutions + insertions + deletions }

        /// WER = (S + I + D) / reference length. An empty reference scores 0
        /// against an empty hypothesis (nothing to get wrong) and infinity
        /// against any text (words invented over nothing — the
        /// silence-hallucination shape).
        var wer: Double {
            guard referenceWordCount > 0 else {
                return hypothesisWordCount == 0 ? 0 : .infinity
            }
            return Double(errors) / Double(referenceWordCount)
        }
    }

    static func score(reference: String, hypothesis: String) -> Counts {
        align(reference: normalize(reference), hypothesis: normalize(hypothesis))
    }

    /// Segment-array convenience: the hypothesis is the segments' text
    /// joined in start order.
    static func score(reference: String, segments: [TranscriptSegment]) -> Counts {
        score(reference: reference, hypothesis: joinedText(segments))
    }

    static func joinedText(_ segments: [TranscriptSegment]) -> String {
        segments.sorted { $0.start < $1.start }.map(\.text).joined(separator: " ")
    }

    // MARK: - Normalization

    static func normalize(_ text: String) -> [String] {
        text.precomposedStringWithCanonicalMapping
            .lowercased()
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .split(whereSeparator: \.isWhitespace)
            .compactMap(cleaned)
    }

    private static func cleaned(_ token: Substring) -> String? {
        let characters = Array(token)
        var kept: [Character] = []
        for (index, character) in characters.enumerated() {
            if character.isLetter || character.isNumber {
                kept.append(character)
            } else if character == "'" || character == "-" {
                let joinsWord = index > 0 && index + 1 < characters.count
                    && (characters[index - 1].isLetter || characters[index - 1].isNumber)
                    && (characters[index + 1].isLetter || characters[index + 1].isNumber)
                if joinsWord { kept.append(character) }
            }
            // Everything else is punctuation — stripped.
        }
        return kept.isEmpty ? nil : String(kept)
    }

    // MARK: - Alignment

    /// Word-level Levenshtein with an S/I/D decomposition (two-row DP, so
    /// hour-long references stay cheap). Among co-optimal alignments the
    /// tie-break is deterministic: match/substitution wins over deletion,
    /// deletion over insertion — the totals are identical either way.
    static func align(reference: [String], hypothesis: [String]) -> Counts {
        var previous = (0 ... hypothesis.count).map { Cell(insertions: $0) }
        var current = previous

        for i in 1 ..< reference.count + 1 {
            current[0] = Cell(deletions: i)
            for j in 1 ..< hypothesis.count + 1 {
                var best = previous[j - 1]
                if reference[i - 1] != hypothesis[j - 1] { best.substitutions += 1 }

                var deletion = previous[j]
                deletion.deletions += 1
                if deletion.total < best.total { best = deletion }

                var insertion = current[j - 1]
                insertion.insertions += 1
                if insertion.total < best.total { best = insertion }

                current[j] = best
            }
            swap(&previous, &current)
        }

        let aligned = previous[hypothesis.count]
        return Counts(
            substitutions: aligned.substitutions,
            insertions: aligned.insertions,
            deletions: aligned.deletions,
            referenceWordCount: reference.count,
            hypothesisWordCount: hypothesis.count
        )
    }

    private struct Cell {
        var substitutions = 0
        var insertions = 0
        var deletions = 0
        var total: Int { substitutions + insertions + deletions }
    }
}
