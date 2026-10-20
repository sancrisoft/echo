//
//  MeetingSearchIndex.swift
//  Meetings
//
//  The words of every meeting, held so a query is answered without opening a
//  file: for each meeting, the passages its words were read from — the title,
//  the description, the date, each line of the summary, each turn of the
//  transcript — and which words occur in which passage; across meetings,
//  which meetings hold each word, and every word in order, so the words a
//  prefix begins are a range and not a scan.
//
//  A value, rebuilt from disk and never written to it: the index is a reading
//  of the meetings, not a second copy of them (ADR-003). Only memory holds
//  it, and only for as long as the app runs.
//

import EchoCore
import Foundation

/// One place a meeting's words were read from.
struct SearchPassage: Sendable {
    enum Kind: Sendable, Equatable {
        case title
        case caption
        case date
        case summary
        case transcript(turn: UUID, speaker: Speaker, start: TimeInterval)

        /// What a term found here is worth: a meeting named for the words
        /// outranks one that only mentions them.
        var weight: Int {
            switch self {
            case .title: return 8
            case .caption, .date: return 4
            case .summary: return 2
            case .transcript: return 1
            }
        }

        var isHeader: Bool {
            switch self {
            case .title, .caption, .date: return true
            case .summary, .transcript: return false
            }
        }
    }

    let kind: Kind
    let text: String
}

/// A meeting as search holds it.
struct SearchDocument: Sendable {
    let meta: MeetingMeta
    let passages: [SearchPassage]
    /// Each folded word, and the passages it occurs in, ascending.
    let postings: [String: [Int32]]

    /// The turns are the transcript as the document draws it, so a turn
    /// found here is a turn the document's find can land on.
    init(meta: MeetingMeta, segments: [TranscriptSegment], summaryMarkdown: String?) {
        var passages = [SearchPassage(kind: .title, text: meta.title)]
        if let caption = meta.oneLineDescription, !caption.isEmpty {
            passages.append(SearchPassage(kind: .caption, text: caption))
        }
        // The date as the sidebar's filter wrote it, so "Oct 14" still finds
        // the meetings of that day.
        passages.append(SearchPassage(kind: .date, text: meta.startedAt.formatted(date: .abbreviated, time: .omitted)))
        for line in summaryMarkdown.map(SearchText.summaryLines) ?? [] {
            passages.append(SearchPassage(kind: .summary, text: line))
        }
        for turn in TranscriptUtterance.derive(from: segments) {
            passages.append(
                SearchPassage(
                    kind: .transcript(turn: turn.id, speaker: turn.speaker, start: turn.start), text: turn.text))
        }
        var postings: [String: [Int32]] = [:]
        for (index, passage) in passages.enumerated() {
            for word in Set(SearchText.words(in: passage.text).map(\.token)) {
                postings[word, default: []].append(Int32(index))
            }
        }
        self.meta = meta
        self.passages = passages
        self.postings = postings
    }
}

struct MeetingSearchIndex: Sendable {

    private(set) var documents: [UUID: SearchDocument] = [:]
    /// Each folded word, and the meetings that hold it.
    private var holders: [String: Set<UUID>] = [:]
    /// Every word held, in order.
    private var vocabulary: [String] = []

    /// Takes in meetings, replacing any already held under the same id.
    mutating func insert(_ new: [SearchDocument]) {
        for document in new {
            let id = document.meta.id
            forgetWords(of: id)
            documents[id] = document
            for word in document.postings.keys {
                holders[word, default: []].insert(id)
            }
        }
        vocabulary = holders.keys.sorted()
    }

    mutating func remove(_ ids: some Sequence<UUID>) {
        for id in ids {
            forgetWords(of: id)
            documents[id] = nil
        }
        vocabulary = holders.keys.sorted()
    }

    private mutating func forgetWords(of id: UUID) {
        guard let old = documents[id] else { return }
        for word in old.postings.keys {
            holders[word]?.remove(id)
            if holders[word]?.isEmpty == true { holders[word] = nil }
        }
    }

    // MARK: - Answering

    /// The meetings that hold every term inside the query's scope and pass
    /// its filters, best first: a meeting named for the words before one
    /// that mentions them, more recent before older on a tie. All of them:
    /// how many to draw is the surface's call, and the count it shows has to
    /// be the true one.
    func search(_ query: MeetingSearchQuery) -> [MeetingSearchHit] {
        guard !query.isEmpty else { return [] }
        let terms = query.terms.map(resolve)
        // Only meetings holding every term somewhere are worth opening.
        var pool: Set<UUID>?
        for term in terms {
            var holding: Set<UUID>?
            for part in term.parts {
                var inPart = Set<UUID>()
                for word in part { inPart.formUnion(holders[word] ?? []) }
                holding = holding.map { $0.intersection(inPart) } ?? inPart
            }
            let meetings = holding ?? []
            pool = pool.map { $0.intersection(meetings) } ?? meetings
            if pool?.isEmpty == true { return [] }
        }
        var scored: [(hit: MeetingSearchHit, score: Int)] = []
        for id in pool ?? Set(documents.keys) {
            guard let document = documents[id], admits(document.meta, query),
                let match = match(document, terms, query)
            else { continue }
            scored.append(match)
        }
        scored.sort { lhs, rhs in
            lhs.score != rhs.score ? lhs.score > rhs.score : lhs.hit.meta.startedAt > rhs.hit.meta.startedAt
        }
        return scored.map(\.hit)
    }

    /// A term as the held words that satisfy it, found once for every
    /// meeting: a word's every completion; a phrase's, part by part.
    private struct ResolvedTerm {
        let term: MeetingSearchQuery.Term
        let parts: [[String]]
    }

    private func resolve(_ term: MeetingSearchQuery.Term) -> ResolvedTerm {
        switch term {
        case .word(let word):
            return ResolvedTerm(term: term, parts: [words(beginningWith: word, wholeOnly: word.count < 2)])
        case .phrase(let words):
            let parts = words.enumerated().map { index, word in
                self.words(beginningWith: word, wholeOnly: index < words.count - 1 || word.count < 2)
            }
            return ResolvedTerm(term: term, parts: parts)
        }
    }

    private func words(beginningWith word: String, wholeOnly: Bool) -> [String] {
        guard !wholeOnly else { return holders[word] == nil ? [] : [word] }
        var low = 0
        var high = vocabulary.count
        while low < high {
            let middle = (low + high) / 2
            if vocabulary[middle] < word { low = middle + 1 } else { high = middle }
        }
        var found: [String] = []
        while low < vocabulary.count, vocabulary[low].hasPrefix(word) {
            found.append(vocabulary[low])
            low += 1
        }
        return found
    }

    private func admits(_ meta: MeetingMeta, _ query: MeetingSearchQuery) -> Bool {
        (!meta.isTrashed || query.includesTrash) && (query.dates?.contains(meta.startedAt) ?? true)
    }

    /// Whether a passage is one the query reads: its scope, and its speaker.
    private func reads(_ kind: SearchPassage.Kind, _ query: MeetingSearchQuery) -> Bool {
        if let speaker = query.speaker {
            guard case .transcript(_, let said, _) = kind, said == speaker else { return false }
            return query.scope == .all || query.scope == .transcripts
        }
        switch (query.scope, kind) {
        case (.all, _): return true
        case (.titles, .title), (.titles, .caption), (.titles, .date): return true
        case (.summaries, .summary): return true
        case (.transcripts, .transcript): return true
        default: return false
        }
    }

    private func match(
        _ document: SearchDocument, _ terms: [ResolvedTerm], _ query: MeetingSearchQuery
    ) -> (hit: MeetingSearchHit, score: Int)? {
        let passages = document.passages
        // Where each term occurs, among the passages the query reads.
        var found: [[Int]] = []
        for term in terms {
            var indices = Set<Int>()
            for (position, part) in term.parts.enumerated() {
                var inPart = Set<Int>()
                for word in part { inPart.formUnion((document.postings[word] ?? []).map(Int.init)) }
                indices = position == 0 ? inPart : indices.intersection(inPart)
            }
            var places = indices.filter { reads(passages[$0].kind, query) }.sorted()
            if case .phrase(let words) = term.term {
                places = places.filter { !Self.highlights(of: [.phrase(words)], in: passages[$0].text).isEmpty }
            }
            guard !places.isEmpty else { return nil }
            found.append(places)
        }
        // Filters alone: a meeting answers if it holds anything the query
        // reads — `you:` asks for meetings where the user said something.
        if terms.isEmpty, query.speaker != nil, !passages.contains(where: { reads($0.kind, query) }) {
            return nil
        }

        let titleHighlights = reads(.title, query) ? Self.highlights(of: query.terms, in: document.meta.title) : []
        var score = found.reduce(0) { total, places in
            total + (places.map { passages[$0].kind.weight }.max() ?? 0)
        }
        if !terms.isEmpty, found.allSatisfy({ $0.contains(0) }) { score += SearchPassage.Kind.title.weight }

        // The header carries every term: the line is the description, as the
        // sidebar shows it. Otherwise it is the body's line holding the most
        // terms — the summary's before the transcript's on a tie, then the
        // earliest.
        let headerOnly = found.allSatisfy { places in places.contains { passages[$0].kind.isHeader } }
        let line: MeetingSearchHit.Line?
        if headerOnly {
            line = document.meta.oneLineDescription.flatMap { caption in
                caption.isEmpty
                    ? nil
                    : .caption(
                        MeetingSearchSnippet(text: caption, highlights: Self.highlights(of: query.terms, in: caption)))
            }
        } else {
            var counts: [Int: Int] = [:]
            for places in found {
                for index in places where !passages[index].kind.isHeader { counts[index, default: 0] += 1 }
            }
            let best = counts.max { lhs, rhs in
                if lhs.value != rhs.value { return lhs.value < rhs.value }
                return lhs.key > rhs.key
            }
            line = best.map { index, _ in
                let passage = passages[index]
                let snippet = MeetingSearchSnippet.around(
                    Self.highlights(of: query.terms, in: passage.text), in: passage.text)
                if case .transcript(let turn, let speaker, let start) = passage.kind {
                    return .transcript(snippet, turn: turn, speaker: speaker, start: start)
                }
                return .summary(snippet)
            }
            score += min(counts.count, 5)
        }
        return (MeetingSearchHit(meta: document.meta, titleHighlights: titleHighlights, line: line), score)
    }

    // MARK: - Where the words fall

    /// Every place in `text` a term matches, in reading order, overlaps
    /// merged: a word wherever a word in `text` begins with it, a phrase
    /// wherever its words follow one another.
    static func highlights(of terms: [MeetingSearchQuery.Term], in text: String) -> [Range<String.Index>] {
        guard !terms.isEmpty else { return [] }
        let words = SearchText.words(in: text)
        var ranges: [Range<String.Index>] = []
        for (index, word) in words.enumerated() {
            for term in terms {
                switch term {
                case .word(let typed):
                    if begins(word.token, with: typed, whole: false) { ranges.append(word.range) }
                case .phrase(let typed):
                    guard index + typed.count <= words.count else { continue }
                    let run = words[index..<(index + typed.count)]
                    let matches = zip(run, typed).enumerated().allSatisfy { position, pair in
                        begins(pair.0.token, with: pair.1, whole: position < typed.count - 1)
                    }
                    if matches, let last = run.last { ranges.append(word.range.lowerBound..<last.range.upperBound) }
                }
            }
        }
        ranges.sort { $0.lowerBound < $1.lowerBound }
        var merged: [Range<String.Index>] = []
        for range in ranges {
            if let last = merged.last, range.lowerBound <= last.upperBound {
                merged[merged.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound)
            } else {
                merged.append(range)
            }
        }
        return merged
    }

    private static func begins(_ token: String, with typed: String, whole: Bool) -> Bool {
        whole || typed.count < 2 ? token == typed : token.hasPrefix(typed)
    }
}
