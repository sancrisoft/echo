//
//  MeetingExportTests.swift
//  MeetingsTests
//
//  The share format behind the detail's "Copy summary" button: a standalone
//  Markdown document (title, meta line, the summary document verbatim). One
//  builder renders it and the export's nested "## Summary" block, so these
//  tests pin both the copy's own shape and the fact that the export's heading
//  depth did not shift under it. Summaries are plain Markdown strings now; a
//  legacy fixed-section summary reaches the export as its `resolvedMarkdown`.
//

import EchoCore
import Foundation
import Meetings
import Testing

@Suite("Summary Markdown (copy + export)")
struct MeetingExportTests {

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

    /// A legacy fixed-section summary — the shape the pre-Markdown UI showed.
    /// Its `resolvedMarkdown` is the document the store holds for it.
    private func makeLegacySummary() -> LegacyMeetingSummary {
        LegacyMeetingSummary(
            shortSummary: "We agreed to ship on Friday.",
            detailedSummary: "The team walked the release checklist end to end.",
            decisions: [
                LegacyMeetingSummary.Decision(
                    title: "Ship Friday", details: "Once QA signs off", evidenceSegmentIDs: [])
            ],
            actionItems: [
                LegacyMeetingSummary.ActionItem(
                    task: "Cut the release branch", owner: "Ana", dueDate: "Thursday", evidenceSegmentIDs: []),
                // Unknown owner/date stay empty rather than invented (AGENTS.md).
                LegacyMeetingSummary.ActionItem(
                    task: "Update the changelog", owner: nil, dueDate: nil, evidenceSegmentIDs: []),
            ],
            openQuestions: [
                LegacyMeetingSummary.OpenQuestion(question: "Who runs the demo?", context: nil, evidenceSegmentIDs: [])
            ],
            risks: [
                LegacyMeetingSummary.Risk(
                    risk: "QA is short-staffed", details: "Two people out", evidenceSegmentIDs: [])
            ]
        )
    }

    private func makeSummary() -> String {
        makeLegacySummary().resolvedMarkdown
    }

    private func makeRecord(summaryMarkdown: String?) -> MeetingRecord {
        MeetingRecord(
            meta: makeMeta(),
            segments: [
                TranscriptSegment(channel: .microphone, speaker: .me, text: "Morning.", start: 12, end: 15)
            ],
            summaryMarkdown: summaryMarkdown
        )
    }

    @Test func copiedMarkdownIsAStandaloneDocument() {
        let markdown = MeetingExport.summaryMarkdown(makeSummary(), meta: makeMeta())
        let lines = markdown.components(separatedBy: "\n")

        #expect(lines.first == "# Weekly sync")
        // The meta line carries date · duration · words, italicized.
        #expect(lines[2].hasPrefix("_") && lines[2].hasSuffix("_"))
        #expect(lines[2].contains("30 min"))
        #expect(lines[2].contains("420 words"))

        // The document is carried verbatim: its sections keep the depth the
        // serialization gave them, one rung under the title's H1 — the copy
        // never re-levels or re-assembles them.
        #expect(markdown.hasSuffix(makeSummary()))
        #expect(markdown.contains("\n### Decisions\n"))
        #expect(markdown.contains("\n### Action Items\n"))
        #expect(markdown.contains("\n### Open Questions\n"))
        #expect(markdown.contains("\n### Risks or Blockers\n"))
        #expect(!markdown.contains("## Summary"))

        #expect(markdown.contains("- **Ship Friday** — Once QA signs off"))
        #expect(markdown.contains("- Cut the release branch · Owner: Ana · Due: Thursday"))
        // No owner and no due date means neither is fabricated in the paste.
        #expect(markdown.contains("- Update the changelog\n"))
        // Nothing trailing: pasted into a chat box it needs no cleanup.
        #expect(!markdown.hasSuffix("\n"))
    }

    @Test func aSessionWithoutAMetaCopiesTheSummaryAlone() {
        let markdown = MeetingExport.summaryMarkdown(makeSummary(), meta: nil)
        #expect(!markdown.contains("# Weekly sync"))
        #expect(markdown.hasPrefix("We agreed to ship on Friday."))
        #expect(markdown.contains("\n### Decisions\n"))
    }

    @Test func emptySectionsAreOmittedRatherThanLeftAsBareHeadings() {
        let sparse = LegacyMeetingSummary(
            shortSummary: "Quick standup.",
            detailedSummary: "",
            decisions: [],
            actionItems: [],
            openQuestions: [],
            risks: []
        )
        let markdown = MeetingExport.summaryMarkdown(sparse.resolvedMarkdown, meta: nil)
        #expect(markdown == "Quick standup.")
    }

    // MARK: - Adaptive markdown summaries

    private var adaptiveDocument: String {
        "### Action Items\n- [ ] Cut the release branch\n\n### Release Plan\nShip Friday once QA signs off."
    }

    /// A markdown-bearing summary IS the share body: the model already wrote
    /// the document, so the copy carries it verbatim after the title/meta
    /// header instead of reassembling fixed sections.
    @Test func copiedMarkdownSummaryIsTheDocumentItself() {
        let markdown = MeetingExport.summaryMarkdown(adaptiveDocument, meta: makeMeta())
        let lines = markdown.components(separatedBy: "\n")

        #expect(lines.first == "# Weekly sync")
        #expect(lines[2].hasPrefix("_") && lines[2].hasSuffix("_"))
        #expect(markdown.hasSuffix(adaptiveDocument))
        // None of the legacy fixed sections are reassembled around it.
        #expect(!markdown.contains("Decisions"))
        #expect(!markdown.contains("Open Questions"))
    }

    @Test func copiedMarkdownSummaryWithoutMetaIsTheBareDocument() {
        let markdown = MeetingExport.summaryMarkdown(adaptiveDocument, meta: nil)
        #expect(markdown == adaptiveDocument)
    }

    @Test func exportEmbedsTheMarkdownDocumentUnderSummary() {
        let markdown = MeetingExport.markdown(for: makeRecord(summaryMarkdown: adaptiveDocument))

        #expect(markdown.contains("\n## Summary\n"))
        #expect(markdown.contains(adaptiveDocument))
        #expect(markdown.contains("\n## Transcript\n"))
        // The legacy fixed sections never appear alongside the document.
        #expect(!markdown.contains("### Decisions"))
    }

    @Test func plainTextExportCarriesTheRawMarkdown() {
        let text = MeetingExport.plainText(for: makeRecord(summaryMarkdown: adaptiveDocument))

        #expect(text.contains("SUMMARY"))
        #expect(text.contains(adaptiveDocument))
        #expect(text.contains("TRANSCRIPT"))
    }

    /// The copy button reuses the export's builder; the export's own nesting
    /// ("### " under "## Summary") must not have moved with it: a document
    /// with `###` sections nests under "## Summary" in the export and stays
    /// top-level in the copy.
    @Test func exportKeepsItsNestedHeadingDepth() {
        let markdown = MeetingExport.markdown(for: makeRecord(summaryMarkdown: makeSummary()))

        #expect(markdown.contains("\n## Summary\n"))
        #expect(markdown.contains("\n### Decisions\n"))
        #expect(markdown.contains("\n### Risks or Blockers\n"))
        #expect(markdown.contains("\n## Transcript\n"))
        #expect(!markdown.contains("\n## Decisions\n"))
        // The summary block precedes the transcript, and the sections sit
        // between the two — nested under Summary, not floating after it.
        let summaryIndex = try? #require(markdown.range(of: "## Summary")?.lowerBound)
        let decisionsIndex = try? #require(markdown.range(of: "### Decisions")?.lowerBound)
        let transcriptIndex = try? #require(markdown.range(of: "## Transcript")?.lowerBound)
        if let summaryIndex, let decisionsIndex, let transcriptIndex {
            #expect(summaryIndex < decisionsIndex)
            #expect(decisionsIndex < transcriptIndex)
        }

        // The standalone copy keeps the same document at top level: no
        // "## Summary" wrapper, sections still at `###`.
        let copy = MeetingExport.summaryMarkdown(makeSummary(), meta: makeMeta())
        #expect(!copy.contains("## Summary"))
        #expect(copy.contains("\n### Decisions\n"))
    }

    // MARK: - Records without a summary

    @Test func aRecordWithoutASummaryExportsNoSummarySection() {
        let markdown = MeetingExport.markdown(for: makeRecord(summaryMarkdown: nil))
        #expect(!markdown.contains("## Summary"))
        #expect(markdown.contains("\n## Transcript\n"))

        // A whitespace-only document is no summary either — never a bare
        // "## Summary" heading with nothing under it.
        let blank = MeetingExport.markdown(for: makeRecord(summaryMarkdown: "  \n\n"))
        #expect(!blank.contains("## Summary"))
        #expect(MeetingExport.summaryMarkdown("  \n", meta: nil) == "")
    }
}
