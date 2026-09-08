//
//  LegacyMeetingSummaryTests.swift
//  MeetingsTests
//
//  The on-disk contract for the legacy `summary.json` as the summary grew its
//  adaptive `markdown` document (ADR-023 pattern: schemas evolve additively
//  with tolerant decoding). Every summary written before the markdown era must
//  keep decoding — the field simply comes back empty — and a markdown-bearing
//  summary must round-trip losslessly. Nothing writes this shape any more; it
//  is kept forever so every folder v1 ever wrote still loads and folds.
//

import Foundation
import Meetings
import Testing

@Suite("LegacyMeetingSummary coding")
struct LegacyMeetingSummaryCodingTests {

    @Test("a legacy summary.json without a markdown key decodes with markdown empty")
    func legacyPayloadDecodes() throws {
        // Exactly the shape MeetingStore wrote before this field existed.
        let legacy = """
            {
              "shortSummary": "Short",
              "detailedSummary": "Detailed",
              "decisions": [{"title": "Ship it", "details": "Approved", "evidenceSegmentIDs": []}],
              "actionItems": [],
              "openQuestions": [],
              "risks": []
            }
            """
        let summary = try JSONDecoder().decode(LegacyMeetingSummary.self, from: Data(legacy.utf8))
        #expect(summary.markdown == "")
        #expect(summary.shortSummary == "Short")
        #expect(summary.detailedSummary == "Detailed")
        #expect(summary.decisions.first?.title == "Ship it")
    }

    @Test("a non-empty markdown document survives an encode/decode round trip")
    func markdownRoundTrips() throws {
        let original = LegacyMeetingSummary(
            markdown: "### Action Items\n- [ ] Cut the release branch\n\n### Release Plan\nShip Friday.",
            shortSummary: "",
            detailedSummary: "",
            decisions: [],
            actionItems: [],
            openQuestions: [],
            risks: []
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(LegacyMeetingSummary.self, from: data)
        #expect(decoded == original)
        #expect(decoded.markdown == original.markdown)
    }
}

//  `resolvedMarkdown` is the one string the summary UI renders for both eras:
//  a markdown-bearing summary resolves to its document verbatim, and a legacy
//  fixed-schema summary resolves to a faithful markdown serialization of the
//  fields the fixed UI used to show. These tests pin both shapes — the
//  Markdown store (`summary.md`) and the launch fold write exactly this.

@Suite("LegacyMeetingSummary resolvedMarkdown")
struct LegacyMeetingSummaryResolvedMarkdownTests {

    // MARK: - Markdown passthrough

    @Test("a markdown-bearing summary resolves to its document verbatim — untrimmed")
    func markdownPassthrough() {
        // Deliberately ragged: emptiness is judged on the trimmed text, but
        // the resolved string is the document exactly as the model wrote it —
        // the renderer, not this shim, owns whitespace presentation.
        let document = "\n### Action Items\n- [ ] Cut the release branch\n\n### Release Plan\nShip Friday.\n"
        let summary = LegacyMeetingSummary(
            markdown: document,
            shortSummary: "Ignored", detailedSummary: "Ignored too",
            decisions: [LegacyMeetingSummary.Decision(title: "Ignored", details: "", evidenceSegmentIDs: [])],
            actionItems: [], openQuestions: [], risks: [])

        #expect(summary.resolvedMarkdown == document)
    }

    // MARK: - Legacy serialization

    @Test("a legacy summary serializes every populated field the fixed UI showed")
    func legacyFullSerialization() {
        let summary = LegacyMeetingSummary(
            shortSummary: "We agreed to ship on Friday.",
            detailedSummary: "The team walked the release checklist end to end.",
            decisions: [
                LegacyMeetingSummary.Decision(
                    title: "Ship Friday", details: "Once QA signs off", evidenceSegmentIDs: [])
            ],
            actionItems: [
                LegacyMeetingSummary.ActionItem(
                    task: "Cut the release branch", owner: "Ana", dueDate: "Thursday", evidenceSegmentIDs: [])
            ],
            openQuestions: [
                LegacyMeetingSummary.OpenQuestion(
                    question: "Who runs the demo?", context: "The invite has no host yet", evidenceSegmentIDs: [])
            ],
            risks: [
                LegacyMeetingSummary.Risk(
                    risk: "QA is short-staffed", details: "Two people out", evidenceSegmentIDs: [])
            ]
        )

        let expected = """
            We agreed to ship on Friday.

            The team walked the release checklist end to end.

            ### Decisions

            - **Ship Friday** — Once QA signs off

            ### Action Items

            - Cut the release branch · Owner: Ana · Due: Thursday

            ### Open Questions

            - Who runs the demo? — The invite has no host yet

            ### Risks or Blockers

            - QA is short-staffed — Two people out
            """
        #expect(summary.resolvedMarkdown == expected)
    }

    @Test("empty legacy sections are omitted rather than left as bare headings")
    func legacyEmptySectionsAreOmitted() {
        let sparse = LegacyMeetingSummary(
            shortSummary: "Quick standup.",
            detailedSummary: "",
            decisions: [],
            actionItems: [
                LegacyMeetingSummary.ActionItem(
                    task: "Post the notes", owner: nil, dueDate: nil, evidenceSegmentIDs: [])
            ],
            openQuestions: [],
            risks: []
        )

        let expected = """
            Quick standup.

            ### Action Items

            - Post the notes
            """
        #expect(sparse.resolvedMarkdown == expected)
    }

    @Test("action items carry only the parts that exist — never an invented owner or date")
    func legacyActionItemPartials() {
        func line(owner: String?, due: String?) -> String {
            let summary = LegacyMeetingSummary(
                shortSummary: "", detailedSummary: "",
                decisions: [],
                actionItems: [
                    LegacyMeetingSummary.ActionItem(
                        task: "Follow up", owner: owner, dueDate: due, evidenceSegmentIDs: [])
                ],
                openQuestions: [], risks: [])
            return summary.resolvedMarkdown
        }

        #expect(line(owner: "Ana", due: nil) == "### Action Items\n\n- Follow up · Owner: Ana")
        #expect(line(owner: nil, due: "Thursday") == "### Action Items\n\n- Follow up · Due: Thursday")
        #expect(line(owner: nil, due: nil) == "### Action Items\n\n- Follow up")
    }

    @Test("an entirely empty summary resolves to an empty string")
    func entirelyEmptySummaryResolvesEmpty() {
        let empty = LegacyMeetingSummary(
            shortSummary: "", detailedSummary: "",
            decisions: [], actionItems: [], openQuestions: [], risks: [])

        #expect(empty.resolvedMarkdown == "")
    }
}
