//
//  MeetingSearchHit.swift
//  Meetings
//
//  What search answers with: a meeting, where in its title the words fell,
//  and the one line that says why it matched — its description, as the
//  sidebar would show it, or the line of the summary or the turn of the
//  transcript the words were found in, cut to start near them.
//

import EchoCore
import Foundation

/// Some text and where in it the query's words fell.
public struct MeetingSearchSnippet: Hashable, Sendable {
    public let text: String
    /// In `text`, in reading order, never overlapping.
    public let highlights: [Range<String.Index>]

    public init(text: String, highlights: [Range<String.Index>]) {
        self.text = text
        self.highlights = highlights
    }

    /// How far into a line its first match may sit before the line is cut
    /// to start near it, and how much is kept before the match when it is.
    /// A result has one line, roughly eighty characters at the palette's
    /// width (an estimate from its layout, not a measurement), so a match
    /// past the fortieth risks falling off its end.
    static let leadAllowance = 40
    static let leadKept = 28

    /// `text` with its matches, starting at a word a little before the first
    /// of them, after an ellipsis, when the first match sits far in.
    static func around(_ highlights: [Range<String.Index>], in text: String) -> MeetingSearchSnippet {
        guard let first = highlights.first,
            text.distance(from: text.startIndex, to: first.lowerBound) > leadAllowance,
            var start = text.index(first.lowerBound, offsetBy: -leadKept, limitedBy: text.startIndex)
        else { return MeetingSearchSnippet(text: text, highlights: highlights) }
        // Forward to the start of the next word, so no word is cut in two.
        if let space = text[start..<first.lowerBound].firstIndex(where: \.isWhitespace) {
            start = text.index(after: space)
        }
        let cut = "…" + text[start...]
        let rebased = highlights.compactMap { range -> Range<String.Index>? in
            guard range.lowerBound >= start else { return nil }
            let offset = 1 + text.distance(from: start, to: range.lowerBound)
            let length = text.distance(from: range.lowerBound, to: range.upperBound)
            let lower = cut.index(cut.startIndex, offsetBy: offset)
            return lower..<cut.index(lower, offsetBy: length)
        }
        return MeetingSearchSnippet(text: cut, highlights: rebased)
    }
}

/// One meeting a query found.
public struct MeetingSearchHit: Identifiable, Hashable, Sendable {

    /// The line under the title.
    public enum Line: Hashable, Sendable {
        /// The one-line description: the words were in the meeting's header.
        case caption(MeetingSearchSnippet)
        case summary(MeetingSearchSnippet)
        /// A turn: who said it, when, and which turn, for find to land on.
        case transcript(MeetingSearchSnippet, turn: UUID, speaker: Speaker, start: TimeInterval)
    }

    public var id: UUID { meta.id }
    public let meta: MeetingMeta
    /// Where in `meta.title` the words fell.
    public let titleHighlights: [Range<String.Index>]
    /// `nil` when the words were in the header and the meeting has no
    /// description to show.
    public let line: Line?

    public init(meta: MeetingMeta, titleHighlights: [Range<String.Index>], line: Line?) {
        self.meta = meta
        self.titleHighlights = titleHighlights
        self.line = line
    }

    /// Whether the line shown is the transcript's: the result opens where
    /// its line is.
    public var foundInTranscript: Bool {
        if case .transcript = line { return true }
        return false
    }

    /// The turn the line is, for find to land on.
    public var turn: UUID? {
        if case .transcript(_, let turn, _, _) = line { return turn }
        return nil
    }
}
