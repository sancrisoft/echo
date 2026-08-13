//
//  MeetingSummaryMarkdownTests.swift
//  EchoTests
//
//  The share format behind the detail's "Copy summary" button: a standalone
//  Markdown document (title, meta line, one section per summary field). One
//  builder renders it and the export's nested "## Summary" block, so these
//  tests pin both the copy's own shape and the fact that the export's heading
//  depth did not shift under it.
//

import Foundation
import Testing
@testable import Echo

@Suite("Summary Markdown (copy + export)")
@MainActor
struct MeetingSummaryMarkdownTests {

    private let start = Date(timeIntervalSince1970: 1_770_000_000)

    private func makeMeta(hasSummary: Bool = true) -> MeetingMeta {
        MeetingMeta(
            id: UUID(),
            title: "Weekly sync",
            startedAt: start,
            endedAt: start.addingTimeInterval(1800),
            segmentCount: 2,
            hasSummary: hasSummary,
            wordCount: 420
        )
    }

    private func makeSummary() -> MeetingSummary {
        MeetingSummary(
            shortSummary: "We agreed to ship on Friday.",
            detailedSummary: "The team walked the release checklist end to end.",
            decisions: [
                SummaryDecision(title: "Ship Friday", details: "Once QA signs off", evidenceSegmentIDs: [])
            ],
            actionItems: [
                SummaryActionItem(task: "Cut the release branch", owner: "Ana", dueDate: "Thursday", evidenceSegmentIDs: []),
                // Unknown owner/date stay empty rather than invented (AGENTS.md).
                SummaryActionItem(task: "Update the changelog", owner: nil, dueDate: nil, evidenceSegmentIDs: [])
            ],
            openQuestions: [
                SummaryOpenQuestion(question: "Who runs the demo?", context: nil, evidenceSegmentIDs: [])
            ],
            risks: [
                SummaryRisk(risk: "QA is short-staffed", details: "Two people out", evidenceSegmentIDs: [])
            ]
        )
    }

    @Test func copiedMarkdownIsAStandaloneDocument() {
        let markdown = MeetingActions.summaryMarkdown(makeSummary(), meta: makeMeta())
        let lines = markdown.components(separatedBy: "\n")

        #expect(lines.first == "# Weekly sync")
        // The meta line carries date · duration · words, italicized.
        #expect(lines[2].hasPrefix("_") && lines[2].hasSuffix("_"))
        #expect(lines[2].contains("30 min"))
        #expect(lines[2].contains("420 words"))

        // Sections sit at H2 — one rung under the title, not the export's H3.
        #expect(markdown.contains("\n## Decisions\n"))
        #expect(markdown.contains("\n## Action Items\n"))
        #expect(markdown.contains("\n## Open Questions\n"))
        #expect(markdown.contains("\n## Risks or Blockers\n"))
        #expect(!markdown.contains("### "))

        #expect(markdown.contains("- Ship Friday — Once QA signs off"))
        #expect(markdown.contains("- Cut the release branch · Owner: Ana · Due: Thursday"))
        // No owner and no due date means neither is fabricated in the paste.
        #expect(markdown.contains("- Update the changelog\n"))
        // Nothing trailing: pasted into a chat box it needs no cleanup.
        #expect(!markdown.hasSuffix("\n"))
    }

    @Test func aSessionWithoutAMetaCopiesTheSummaryAlone() {
        let markdown = MeetingActions.summaryMarkdown(makeSummary(), meta: nil)
        #expect(!markdown.contains("# Weekly sync"))
        #expect(markdown.hasPrefix("We agreed to ship on Friday."))
        #expect(markdown.contains("\n## Decisions\n"))
    }

    @Test func emptySectionsAreOmittedRatherThanLeftAsBareHeadings() {
        let sparse = MeetingSummary(
            shortSummary: "Quick standup.",
            detailedSummary: "",
            decisions: [],
            actionItems: [],
            openQuestions: [],
            risks: []
        )
        let markdown = MeetingActions.summaryMarkdown(sparse, meta: nil)
        #expect(markdown == "Quick standup.")
    }

    /// The copy button reuses the export's builder; the export's own nesting
    /// ("### " under "## Summary") must not have moved with it.
    @Test func exportKeepsItsNestedHeadingDepth() {
        let meta = makeMeta()
        let record = MeetingRecord(
            meta: meta,
            segments: [
                TranscriptSegment(channel: .microphone, speaker: .me, text: "Morning.", start: 12, end: 15)
            ],
            summary: makeSummary()
        )
        let markdown = MeetingActions.markdown(for: record)

        #expect(markdown.contains("\n## Summary\n"))
        #expect(markdown.contains("\n### Decisions\n"))
        #expect(markdown.contains("\n### Risks or Blockers\n"))
        #expect(markdown.contains("\n## Transcript\n"))
        #expect(!markdown.contains("\n## Decisions\n"))
    }
}
