import DesignSystem
import SwiftUI
import Testing

@testable import Workspace

@Suite("The summary on the type scale")
struct MarkdownRenderingTests {

    private let heading = MarkdownBlock.heading(level: 3, spans: [MarkdownSpan(text: "Action Items")])
    private let list = MarkdownBlock.list(items: [MarkdownListItem(spans: [MarkdownSpan(text: "One")])], ordered: false)
    private let paragraph = MarkdownBlock.paragraph(spans: [MarkdownSpan(text: "Prose.")])

    @Test("a heading sits a section away from what precedes it and a short step above what follows")
    func headingGaps() {
        let half = MarkdownRendering.halfLeading
        #expect(MarkdownRendering.gap(above: heading, after: list) == EchoLayout.summaryHeadingTop + half)
        #expect(MarkdownRendering.gap(above: heading, after: heading) == EchoLayout.summaryHeadingTop)
        #expect(MarkdownRendering.gap(above: list, after: heading) == EchoLayout.summaryHeadingBottom + half)
    }

    @Test("two blocks of prose are a short step apart, with both lines' leading")
    func bodyGaps() {
        #expect(MarkdownRendering.gap(above: paragraph, after: list) == MarkdownRendering.itemGap)
        #expect(MarkdownRendering.itemGap == EchoLayout.summaryBlockGap + EchoFont.bodyLineSpacing)
    }

    @Test("the first block takes no section gap: the summary's own top gap is above it")
    func firstBlock() {
        #expect(MarkdownRendering.gap(above: heading, after: nil) == 0)
        #expect(MarkdownRendering.gap(above: paragraph, after: nil) == MarkdownRendering.halfLeading)
    }

    @Test("every heading a summary can hold is a section title or, deeper, a strong label")
    func headingFaces() {
        for level in 1...3 {
            #expect(MarkdownRendering.headingFont(level: level) == EchoFont.sectionTitle)
        }
        #expect(MarkdownRendering.headingFont(level: 4) == EchoFont.bodyBold)
    }

    @Test("bold takes the bold face and the primary ink; code its own face and ink; plain prose neither")
    func inlineStyles() throws {
        let spans = [
            MarkdownSpan(text: "Trade rejections:", style: .bold),
            MarkdownSpan(text: " showing a "),
            MarkdownSpan(text: "destination", style: .code),
        ]
        let string = MarkdownRendering.attributedString(
            for: spans, baseFont: EchoFont.body, boldFont: EchoFont.bodyBold)
        let runs = Array(string.runs)
        try #require(runs.count == 3)
        #expect(runs[0].font == EchoFont.bodyBold)
        #expect(runs[0].foregroundColor == EchoColor.textPrimary)
        #expect(runs[1].font == EchoFont.body)
        #expect(runs[1].foregroundColor == nil)
        #expect(runs[2].font == EchoFont.inlineCode)
        #expect(runs[2].foregroundColor == EchoColor.textValue)
    }
}
