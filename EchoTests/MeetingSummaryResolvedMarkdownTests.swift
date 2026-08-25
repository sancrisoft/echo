//
//  MeetingSummaryResolvedMarkdownTests.swift
//  EchoTests
//
//  `resolvedMarkdown` is the one string the summary UI renders for both eras:
//  a markdown-bearing summary resolves to its document verbatim, and a legacy
//  fixed-schema summary resolves to a faithful markdown serialization of the
//  fields the fixed UI used to show. These tests pin both shapes — the
//  renderer slice builds on exactly this contract.
//

import Foundation
import Testing
@testable import Echo

@Suite("MeetingSummary resolvedMarkdown")
struct MeetingSummaryResolvedMarkdownTests {

    // MARK: - Markdown passthrough

    @Test("a markdown-bearing summary resolves to its document verbatim — untrimmed")
    func markdownPassthrough() {
        // Deliberately ragged: emptiness is judged on the trimmed text, but
        // the resolved string is the document exactly as the model wrote it —
        // the renderer, not this shim, owns whitespace presentation.
        let document = "\n### Action Items\n- [ ] Cut the release branch\n\n### Release Plan\nShip Friday.\n"
        let summary = MeetingSummary(
            markdown: document,
            shortSummary: "Ignored", detailedSummary: "Ignored too",
            decisions: [SummaryDecision(title: "Ignored", details: "", evidenceSegmentIDs: [])],
            actionItems: [], openQuestions: [], risks: [])

        #expect(summary.resolvedMarkdown == document)
    }

    // MARK: - Legacy serialization

    @Test("a legacy summary serializes every populated field the fixed UI showed")
    func legacyFullSerialization() {
        let summary = MeetingSummary(
            shortSummary: "We agreed to ship on Friday.",
            detailedSummary: "The team walked the release checklist end to end.",
            decisions: [
                SummaryDecision(title: "Ship Friday", details: "Once QA signs off", evidenceSegmentIDs: [])
            ],
            actionItems: [
                SummaryActionItem(task: "Cut the release branch", owner: "Ana", dueDate: "Thursday", evidenceSegmentIDs: [])
            ],
            openQuestions: [
                SummaryOpenQuestion(question: "Who runs the demo?", context: "The invite has no host yet", evidenceSegmentIDs: [])
            ],
            risks: [
                SummaryRisk(risk: "QA is short-staffed", details: "Two people out", evidenceSegmentIDs: [])
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
        let sparse = MeetingSummary(
            shortSummary: "Quick standup.",
            detailedSummary: "",
            decisions: [],
            actionItems: [SummaryActionItem(task: "Post the notes", owner: nil, dueDate: nil, evidenceSegmentIDs: [])],
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
            let summary = MeetingSummary(
                shortSummary: "", detailedSummary: "",
                decisions: [],
                actionItems: [SummaryActionItem(task: "Follow up", owner: owner, dueDate: due, evidenceSegmentIDs: [])],
                openQuestions: [], risks: [])
            return summary.resolvedMarkdown
        }

        #expect(line(owner: "Ana", due: nil) == "### Action Items\n\n- Follow up · Owner: Ana")
        #expect(line(owner: nil, due: "Thursday") == "### Action Items\n\n- Follow up · Due: Thursday")
        #expect(line(owner: nil, due: nil) == "### Action Items\n\n- Follow up")
    }

    @Test("an entirely empty summary resolves to an empty string")
    func entirelyEmptySummaryResolvesEmpty() {
        let empty = MeetingSummary(
            shortSummary: "", detailedSummary: "",
            decisions: [], actionItems: [], openQuestions: [], risks: [])

        #expect(empty.resolvedMarkdown == "")
    }
}
