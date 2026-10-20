//
//  TranscriptFind.swift
//  Workspace
//
//  Find in the open transcript: where a query occurs in the turns, which of
//  those places the user is on, and how that is written in the field. Local
//  to the document that is open — the palette's search across the library is
//  a different feature, which only hands find its words when it opens a
//  result here.
//
//  As values, so the rules — what counts as a match, how ⌘G wraps — are
//  tested without a window.
//

import EchoCore
import Foundation

/// One place a query was found: the turn, and where in its words.
struct TranscriptMatch: Equatable, Sendable {
    let turn: UUID
    let range: Range<String.Index>
}

enum TranscriptFind {

    /// Every place `query` occurs in the turns' words, in reading order. Case
    /// and accents are ignored, as macOS's own find does, so "deja" finds
    /// "déjà". Matches do not overlap, and a query of nothing but spaces
    /// finds nothing rather than every space.
    static func matches(of query: String, in turns: [TranscriptUtterance]) -> [TranscriptMatch] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return [] }
        var found: [TranscriptMatch] = []
        for turn in turns {
            var searchRange = turn.text.startIndex..<turn.text.endIndex
            while let range = turn.text.range(
                of: needle, options: [.caseInsensitive, .diacriticInsensitive], range: searchRange)
            {
                found.append(TranscriptMatch(turn: turn.id, range: range))
                searchRange = range.upperBound..<turn.text.endIndex
            }
        }
        return found
    }

    /// The match `offset` places on from `current`, wrapping at either end,
    /// as ⌘G and ⇧⌘G do. With nothing current yet, forward lands on the first
    /// match and back on the last. `nil` when there is nothing to land on.
    static func step(from current: Int?, by offset: Int, count: Int) -> Int? {
        guard count > 0 else { return nil }
        guard let current else { return offset >= 0 ? 0 : count - 1 }
        return ((current + offset) % count + count) % count
    }

    /// What the field says after the query: "3 of 12", or "0 of 0" when the
    /// query is nowhere in the transcript.
    static func counter(current: Int?, count: Int) -> String {
        guard count > 0, let current else { return "0 of 0" }
        return "\(current + 1) of \(count)"
    }
}
