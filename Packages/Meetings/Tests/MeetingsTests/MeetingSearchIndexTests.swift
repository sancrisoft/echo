//
//  MeetingSearchIndexTests.swift
//  MeetingsTests
//
//  The index as a value: which meetings a query finds, in what order, and the
//  line each result shows — the description when the words are in the
//  header, otherwise the line of the summary or the turn of the transcript
//  they were found in. `@testable` because the index is the library's
//  internals; `MeetingLibrarySearchTests` drives the same rules through the
//  public façade.
//

import EchoCore
import Foundation
import Testing

@testable import Meetings

@Suite("MeetingSearchIndex")
struct MeetingSearchIndexTests {

    private let base = Date(timeIntervalSince1970: 1_700_000_000)

    private func document(
        _ title: String,
        caption: String? = nil,
        age: TimeInterval = 0,
        trashed: Bool = false,
        you: [String] = [],
        others: [String] = [],
        summary: String? = nil
    ) -> SearchDocument {
        let startedAt = base.addingTimeInterval(-age)
        let meta = MeetingMeta(
            id: UUID(), title: title, startedAt: startedAt, endedAt: startedAt.addingTimeInterval(600),
            segmentCount: you.count + others.count, hasSummary: summary != nil, oneLineDescription: caption,
            trashedAt: trashed ? base : nil)
        // A minute apart, so no two turns merge into one paragraph.
        var segments: [TranscriptSegment] = []
        for (index, text) in you.enumerated() {
            segments.append(
                TranscriptSegment(
                    channel: .microphone, text: text, start: Double(index) * 60, end: Double(index) * 60 + 5))
        }
        for (index, text) in others.enumerated() {
            segments.append(
                TranscriptSegment(
                    channel: .system, text: text, start: Double(index) * 60 + 30, end: Double(index) * 60 + 35))
        }
        return SearchDocument(meta: meta, segments: segments, summaryMarkdown: summary)
    }

    private func index(_ documents: SearchDocument...) -> MeetingSearchIndex {
        var index = MeetingSearchIndex()
        index.insert(documents)
        return index
    }

    private func search(
        _ index: MeetingSearchIndex, _ text: String, scope: MeetingSearchScope = .all
    ) -> [MeetingSearchHit] {
        index.search(MeetingSearchQuery.parse(text, scope: scope, now: base))
    }

    private func highlighted(_ snippet: MeetingSearchSnippet) -> [String] {
        snippet.highlights.map { String(snippet.text[$0]) }
    }

    private func snippet(of hit: MeetingSearchHit?) -> MeetingSearchSnippet? {
        switch hit?.line {
        case .caption(let snippet), .summary(let snippet), .transcript(let snippet, _, _, _): return snippet
        case nil: return nil
        }
    }

    // MARK: - Finding

    @Test("a word is found as the start of a word in what was said, and the line is the turn it was said in")
    func findsInTranscript() throws {
        let said = TranscriptSegment(
            channel: .microphone, text: "We should move the budget review to Friday.", start: 0, end: 5)
        let meeting = SearchDocument(
            meta: MeetingMeta(
                id: UUID(), title: "Weekly", startedAt: base, endedAt: base, segmentCount: 1, hasSummary: false),
            segments: [said], summaryMarkdown: nil)
        let hits = search(index(meeting), "budg")
        let hit = try #require(hits.first)
        #expect(hits.count == 1)
        guard case .transcript(let snippet, let turn, let speaker, let start) = hit.line else {
            Issue.record("expected a transcript line, got \(String(describing: hit.line))")
            return
        }
        #expect(highlighted(snippet) == ["budget"])
        #expect(speaker == .me)
        #expect(start == 0)
        // A turn is named by its first segment: the id the document's find
        // lands on.
        #expect(turn == said.id)
        #expect(hit.foundInTranscript)
        #expect(hit.turn == turn)
    }

    @Test("case and accents do not matter, and the highlight covers the word as written")
    func foldsCaseAndAccents() throws {
        let meeting = document("Retro", others: ["C'était un vrai déjà vu."])
        let hit = try #require(search(index(meeting), "DEJA").first)
        #expect(snippet(of: hit).map(highlighted) == ["déjà"])
    }

    @Test("every word must be somewhere in the meeting, in any field")
    func everyWordSomewhere() {
        let meeting = document("GoCoInvest onboarding", you: ["The budget is approved."])
        let all = index(meeting)
        #expect(search(all, "gocoinvest budget").count == 1)
        #expect(search(all, "gocoinvest nothing").isEmpty)
    }

    @Test("a single letter is a whole word, not the start of every word")
    func singleLetterIsWhole() {
        let all = index(document("Apples", you: ["An apple a day."]))
        #expect(search(all, "p").isEmpty)
        #expect(search(all, "a").count == 1)
    }

    @Test("a phrase is its words in order")
    func phrasesKeepOrder() {
        let all = index(document("Planning", you: ["Let us do the budget review now.", "Review the budget later."]))
        let hits = search(all, "\"budget review\"")
        #expect(hits.count == 1)
        #expect(snippet(of: hits.first).map(highlighted) == ["budget review"])
        #expect(search(all, "\"review budget\"").isEmpty)
    }

    // MARK: - The line a result shows

    @Test("words in the header show the description, highlighted where it matches, as the artboard draws")
    func headerShowsCaption() throws {
        let meeting = document(
            "GoCoInvest onboarding", caption: "Technical onboarding on the trading platform",
            you: ["GoCoInvest came up again."])
        let hit = try #require(search(index(meeting), "gocoinvest").first)
        #expect(hit.titleHighlights.map { String(hit.meta.title[$0]) } == ["GoCoInvest"])
        guard case .caption(let caption) = hit.line else {
            Issue.record("expected the caption, got \(String(describing: hit.line))")
            return
        }
        #expect(caption.text == "Technical onboarding on the trading platform")
        #expect(caption.highlights.isEmpty)
        #expect(!hit.foundInTranscript)
    }

    @Test("a summary match shows its line as prose, with the Markdown taken off")
    func summaryLineIsProse() throws {
        let meeting = document(
            "Board", summary: "### Decisions\n- **Budget** approved for Q4\n- [ ] Ana to send the deck")
        let hit = try #require(search(index(meeting), "budget").first)
        guard case .summary(let line) = hit.line else {
            Issue.record("expected a summary line, got \(String(describing: hit.line))")
            return
        }
        #expect(line.text == "Budget approved for Q4")
        #expect(highlighted(line) == ["Budget"])
        #expect(search(index(meeting), "send").first.flatMap(snippet(of:))?.text == "Ana to send the deck")
    }

    @Test("the summary's line is shown before the transcript's when both hold the words")
    func summaryBeforeTranscript() throws {
        let meeting = document("Board", you: ["The budget is fine."], summary: "- Budget approved")
        let hit = try #require(search(index(meeting), "budget").first)
        guard case .summary = hit.line else {
            Issue.record("expected the summary's line, got \(String(describing: hit.line))")
            return
        }
    }

    @Test("a match far into a turn is shown from a word shortly before it, after an ellipsis")
    func longLinesAreCut() throws {
        let opening = String(repeating: "lorem ipsum dolor sit amet ", count: 6)
        let meeting = document("Long", you: [opening + "and then the budget came up."])
        let line = try #require(snippet(of: search(index(meeting), "budget").first))
        #expect(line.text.hasPrefix("…"))
        #expect(!line.text.hasPrefix("… "))
        #expect(highlighted(line) == ["budget"])
        #expect(line.text.count < opening.count)
    }

    // MARK: - Order

    @Test("a meeting named for the words comes before one that mentions them; a tie goes to the newer")
    func ranking() {
        let mentioned = document("Weekly", age: 0, you: ["The budget again."])
        let named = document("Budget review", age: 7200)
        let olderMention = document("Standup", age: 3600, others: ["Budget first."])
        let order = search(index(mentioned, named, olderMention), "budget").map(\.meta.title)
        #expect(order == ["Budget review", "Weekly", "Standup"])
    }

    // MARK: - Scope and filters

    @Test("the scope limits what is read: titles, summaries or transcripts")
    func scopeLimitsFields() {
        let all = index(
            document("Budget review"), document("Weekly", you: ["Budget talk."]),
            document("Board", summary: "- Budget approved"))
        #expect(search(all, "budget", scope: .titles).map(\.meta.title) == ["Budget review"])
        #expect(search(all, "budget", scope: .transcripts).map(\.meta.title) == ["Weekly"])
        #expect(search(all, "budget", scope: .summaries).map(\.meta.title) == ["Board"])
        #expect(search(all, "budget", scope: .all).count == 3)
    }

    @Test("you: reads only what the microphone heard, others: only the call")
    func speakerFilter() {
        let all = index(
            document("Mine", you: ["I will send the budget."]), document("Theirs", others: ["We need the budget."]))
        #expect(search(all, "you: budget").map(\.meta.title) == ["Mine"])
        #expect(search(all, "others: budget").map(\.meta.title) == ["Theirs"])
        // A meeting named for the words does not answer `you:`: the user did
        // not say its title.
        let named = index(document("Budget", others: ["Hello there everyone."]))
        #expect(search(named, "you: budget").isEmpty)
    }

    @Test("a filter alone lists the meetings it admits")
    func filtersAlone() {
        let all = index(document("Mine", you: ["Hello there everyone."]), document("Silent"))
        #expect(search(all, "you:").map(\.meta.title) == ["Mine"])
    }

    @Test("Trash answers only when asked, and a date keeps to its span")
    func trashAndDates() {
        let recent = document("Recent budget", age: 0)
        let old = document("Old budget", age: 40 * 24 * 3600)
        let trashed = document("Trashed budget", age: 0, trashed: true)
        let all = index(recent, old, trashed)
        #expect(Set(search(all, "budget").map(\.meta.title)) == ["Recent budget", "Old budget"])
        #expect(search(all, "budget in:trash").count == 3)
        #expect(Set(search(all, "budget month in:trash").map(\.meta.title)) == ["Recent budget", "Trashed budget"])
    }

    // MARK: - Keeping current

    @Test("a meeting taken in again replaces its old words, and a removed one leaves none behind")
    func replaceAndRemove() {
        let first = document("Kickoff", you: ["Pineapple on the agenda."])
        var all = MeetingSearchIndex()
        all.insert([first])
        let renamed = SearchDocument(
            meta: MeetingMeta(
                id: first.meta.id, title: "Retrospective", startedAt: base, endedAt: base, segmentCount: 0,
                hasSummary: false),
            segments: [], summaryMarkdown: nil)
        all.insert([renamed])
        #expect(search(all, "kickoff").isEmpty)
        #expect(search(all, "pineapple").isEmpty)
        #expect(search(all, "retro").count == 1)

        all.remove([first.meta.id])
        #expect(search(all, "retro").isEmpty)
        #expect(all.documents.isEmpty)
    }
}
