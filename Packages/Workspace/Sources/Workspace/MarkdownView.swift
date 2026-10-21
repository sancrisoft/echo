//
//  MarkdownView.swift
//  Workspace
//
//  The summary's native renderer, on the design's type scale: sections as
//  section titles, prose in the body face, bullets as small dots, tasks as
//  real checkboxes, bold in the primary ink, code on a raised rounded fill;
//  plus nested and ordered lists, tables, rules and code blocks, which the
//  design does not draw and which keep a plain look in the same tokens.
//
//  Streaming shapes it: the summary tab shows the document while the model is
//  still writing it, so `body` re-parses the Markdown on every tick —
//  deliberate, because `MarkdownDocument.parse` is microseconds for a
//  summary-sized document and stateless re-parsing has no incremental
//  machinery to get out of sync.
//
//  The design states its spacing as CSS margins between line boxes, and a
//  line box carries half its leading above and below the letters where a
//  SwiftUI `Text` carries none outside its first and last lines. The gaps
//  here add that half leading back, so blocks sit where the artboard puts
//  them. The rules live in `MarkdownRendering` as pure functions so tests
//  exercise them without a render pass.
//

import AppKit
import DesignSystem
import SwiftUI

// MARK: - Pure formatting helpers

/// The testable half of the renderer: everything that turns parsed Markdown
/// values into drawable primitives without touching a view.
public nonisolated enum MarkdownRendering {

    /// Leading indent added per list nesting level.
    public static let listIndent: CGFloat = 18

    /// The summary's sections are `###`, and the design sets them as section
    /// titles. A heading above that is a section too — the design draws no
    /// larger heading inside a document that already has its title — and one
    /// below is a strong label in the body's size.
    public static func headingFont(level: Int) -> Font {
        level <= 3 ? EchoFont.sectionTitle : EchoFont.bodyBold
    }

    public static func headingTracking(level: Int) -> CGFloat {
        level <= 3 ? EchoFont.sectionTitleTracking : 0
    }

    /// Ordered-list marker for a zero-based position: "1.", "2.", … The parser
    /// doesn't preserve source numbers (the model's numbering drifts
    /// mid-stream); position is the honest count.
    public static func orderedMarker(position: Int) -> String {
        "\(position + 1)."
    }

    /// Leading indent for a nesting level. Clamped at zero so no input can
    /// push content off the leading edge.
    public static func indent(level: Int) -> CGFloat {
        CGFloat(max(0, level)) * listIndent
    }

    /// Half of the leading a body line carries: what a CSS line box puts
    /// above its first line and below its last.
    public static let halfLeading: CGFloat = EchoFont.bodyLineSpacing / 2

    /// The air above a block, given the block before it. A heading sits a
    /// section's distance below whatever precedes it and a short step above
    /// what follows; any other two blocks are a short step apart. Leading is
    /// added wherever a body line meets the gap, and nothing above the first
    /// heading, whose distance from the tabs is the summary's own top gap.
    public static func gap(above block: MarkdownBlock, after previous: MarkdownBlock?) -> CGFloat {
        let isHeading = block.isHeading
        guard let previous else { return isHeading ? 0 : halfLeading }
        switch (previous.isHeading, isHeading) {
        case (_, true): return EchoLayout.summaryHeadingTop + (previous.isHeading ? 0 : halfLeading)
        case (true, false): return EchoLayout.summaryHeadingBottom + halfLeading
        case (false, false): return EchoLayout.summaryBlockGap + 2 * halfLeading
        }
    }

    /// Between two items of one list, and between an item and the list
    /// nested under it: the same short step, with both lines' leading.
    public static let itemGap: CGFloat = EchoLayout.summaryBlockGap + 2 * halfLeading

    /// One flat span run as an attributed string. Bold takes the given bold
    /// face and the primary ink, so it stands out of the quieter prose; code
    /// takes the monospaced face and its own ink; italic slants whatever it
    /// is on. An empty run converts to an empty string.
    public static func attributedString(
        for spans: [MarkdownSpan], baseFont: Font, boldFont: Font? = nil
    ) -> AttributedString {
        var result = AttributedString()
        for span in spans {
            var piece = AttributedString(span.text)
            if span.style.contains(.code) {
                piece.font = span.style.contains(.italic) ? EchoFont.inlineCode.italic() : EchoFont.inlineCode
                piece.foregroundColor = EchoColor.textValue
            } else {
                var font = baseFont
                if span.style.contains(.bold) {
                    font = boldFont ?? baseFont.bold()
                    piece.foregroundColor = EchoColor.textPrimary
                }
                if span.style.contains(.italic) { font = font.italic() }
                piece.font = font
            }
            result += piece
        }
        return result
    }

    /// The run as a `Text`, with code on its rounded fill. The fill reaches
    /// past the letters as the design pads them; the room it takes in the
    /// line comes from kerning the letter before the code and the code's own
    /// last letter, so the prose around it moves aside as a padded box would.
    /// `text` with the writing cursor after its last words when `cursor` is
    /// set: a thin bar in the accent, a hair's space after the last letter.
    static func withCursor(_ text: Text, _ cursor: Bool) -> Text {
        guard cursor else { return text }
        return Text("\(text)\(Text(verbatim: "\u{200A}\u{258F}").foregroundStyle(EchoColor.accent))")
    }

    static func text(for spans: [MarkdownSpan], baseFont: Font, boldFont: Font? = nil) -> Text {
        var pieces = spans.map { attributedString(for: [$0], baseFont: baseFont, boldFont: boldFont) }
        let pad = EchoControl.inlineCodeInset.width
        for (index, span) in spans.enumerated() where span.style.contains(.code) {
            kernLastCharacter(of: &pieces[index], by: pad)
            if index > 0 { kernLastCharacter(of: &pieces[index - 1], by: pad) }
        }
        return zip(spans, pieces).reduce(Text(verbatim: "")) { text, element in
            let (span, piece) = element
            var segment = Text(piece)
            if span.style.contains(.code) {
                segment = segment.customAttribute(
                    InlineHighlight(
                        fill: EchoColor.surfaceRaised, radius: EchoRadius.inlineCode, leading: pad, trailing: 0,
                        vertical: EchoControl.inlineCodeInset.height))
            }
            return Text("\(text)\(segment)")
        }
    }

    private static func kernLastCharacter(of piece: inout AttributedString, by amount: CGFloat) {
        guard let last = piece.characters.indices.last else { return }
        piece[last..<piece.endIndex].kern = amount
    }
}

nonisolated extension MarkdownBlock {
    fileprivate var isHeading: Bool {
        if case .heading = self { return true }
        return false
    }
}

// MARK: - Document view

/// Renders a Markdown document. Stateless: parse lives in `body`, so a growing
/// streaming string simply re-renders with more blocks.
public struct MarkdownView: View {
    private let markdown: String
    private let showsCursor: Bool

    /// - Parameter showsCursor: the summary is still being written: its last
    ///   words end in the accent's cursor, as `Processing.dc.html` draws the
    ///   notes streaming in.
    public init(markdown: String, showsCursor: Bool = false) {
        self.markdown = markdown
        self.showsCursor = showsCursor
    }

    public var body: some View {
        let blocks = MarkdownDocument.parse(markdown)
        VStack(alignment: .leading, spacing: 0) {
            // Identity by position: a streaming parse is prefix-stable (the
            // parser's design goal), so block N stays block N as the document
            // grows and only the tail re-renders meaningfully.
            ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
                MarkdownBlockView(block: block, cursor: showsCursor && index == blocks.count - 1)
                    .padding(.top, MarkdownRendering.gap(above: block, after: index > 0 ? blocks[index - 1] : nil))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Blocks

private struct MarkdownBlockView: View {
    let block: MarkdownBlock
    /// The writing cursor goes after this block's last words. A rule, a
    /// table or a code block has no words to end on, and draws none.
    var cursor = false

    var body: some View {
        switch block {
        case .heading(let level, let spans):
            MarkdownRendering.withCursor(
                MarkdownRendering.text(for: spans, baseFont: MarkdownRendering.headingFont(level: level)), cursor
            )
            .tracking(MarkdownRendering.headingTracking(level: level))
            .foregroundStyle(EchoColor.textPrimary)
            .textRenderer(InlineHighlightRenderer())
            .textSelection(.enabled)

        case .paragraph(let spans):
            ProseText(spans: spans, ink: EchoColor.textProse, cursor: cursor)

        case .list(let items, let ordered):
            MarkdownListView(items: items, ordered: ordered, cursor: cursor)

        case .horizontalRule:
            EchoColor.divider
                .frame(height: EchoLayout.hairline)

        case .table(let table):
            MarkdownTableView(table: table)

        case .codeBlock(_, let code):
            MarkdownCodeBlockView(code: code)
        }
    }
}

/// A run of prose in the body face and its leading, in the given ink.
private struct ProseText: View {
    let spans: [MarkdownSpan]
    let ink: Color
    var cursor = false

    var body: some View {
        MarkdownRendering.withCursor(
            MarkdownRendering.text(for: spans, baseFont: EchoFont.body, boldFont: EchoFont.bodyBold), cursor
        )
        .lineSpacing(EchoFont.bodyLineSpacing)
        .foregroundStyle(ink)
        .textRenderer(InlineHighlightRenderer())
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Lists

private struct MarkdownListView: View {
    let items: [MarkdownListItem]
    let ordered: Bool
    /// The cursor goes on the list's last item, deepest child first.
    var cursor = false

    var body: some View {
        VStack(alignment: .leading, spacing: MarkdownRendering.itemGap) {
            ForEach(Array(items.enumerated()), id: \.offset) { position, item in
                MarkdownListItemView(
                    item: item, ordered: ordered, position: position, cursor: cursor && position == items.count - 1)
            }
        }
    }
}

private struct MarkdownListItemView: View {
    let item: MarkdownListItem
    let ordered: Bool
    let position: Int
    var cursor = false

    var body: some View {
        VStack(alignment: .leading, spacing: MarkdownRendering.itemGap) {
            HStack(alignment: .firstTextBaseline, spacing: EchoLayout.listMarkerGap) {
                marker
                // A done task recedes: same words, the tertiary ink.
                ProseText(
                    spans: item.spans, ink: item.checkbox == .checked ? EchoColor.textTertiary : EchoColor.textProse,
                    cursor: cursor && item.children.isEmpty)
            }
            if !item.children.isEmpty {
                // One indent step per structural level — recursion accumulates
                // the rest, so the constant is relative, not absolute depth.
                MarkdownListView(items: item.children, ordered: item.childrenOrdered, cursor: cursor)
                    .padding(.leading, MarkdownRendering.indent(level: 1))
            }
        }
    }

    @ViewBuilder
    private var marker: some View {
        if let checkbox = item.checkbox {
            TaskCheckbox(isChecked: checkbox == .checked)
                .frame(width: EchoControl.checkboxSize, height: EchoControl.checkboxSize)
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + BodyLine.middle }
                .accessibilityLabel(checkbox == .checked ? "Done" : "To do")
        } else if ordered {
            Text(MarkdownRendering.orderedMarker(position: position))
                .font(EchoFont.body.monospacedDigit())
                .foregroundStyle(EchoColor.textTertiary)
        } else {
            Circle()
                .fill(EchoColor.textTertiary)
                .frame(width: EchoControl.bulletSize, height: EchoControl.bulletSize)
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + BodyLine.middle }
                .accessibilityHidden(true)
        }
    }
}

/// Where the middle of a body line sits, above its baseline: halfway between
/// the face's ascender and descender, which is where the artboard centres a
/// marker on the first line of its item.
private nonisolated enum BodyLine {
    static let middle: CGFloat = {
        let font = EchoFont.nsInterface(14.5, weight: 400)
        return (font.ascender + font.descender) / 2
    }()
}

/// A task's checkbox, on the artboard's 16 × 16 grid: a rounded square, open
/// in the quaternary ink or filled with the accent and a check cut out of it
/// in the window's own background.
private struct TaskCheckbox: View {
    let isChecked: Bool

    var body: some View {
        if isChecked {
            ZStack {
                CheckboxSquare().fill(EchoColor.accent)
                CheckboxTick()
                    .stroke(EchoColor.windowBackground, style: CheckboxTick.style(in: EchoControl.checkboxSize))
            }
        } else {
            CheckboxSquare()
                .stroke(EchoColor.textQuaternary, lineWidth: CheckboxSquare.lineWidth(in: EchoControl.checkboxSize))
        }
    }
}

private nonisolated struct CheckboxSquare: Shape {
    static func lineWidth(in size: CGFloat) -> CGFloat { 1.5 * size / 16 }

    func path(in rect: CGRect) -> Path {
        let grid = GlyphGrid(rect: rect)
        let origin = grid.point(2.4, 2.4)
        return Path(
            roundedRect: CGRect(x: origin.x, y: origin.y, width: grid.length(11.2), height: grid.length(11.2)),
            cornerRadius: grid.length(3.4), style: .continuous)
    }
}

private nonisolated struct CheckboxTick: Shape {
    static func style(in size: CGFloat) -> StrokeStyle {
        StrokeStyle(lineWidth: 1.8 * size / 16, lineCap: .round, lineJoin: .round)
    }

    func path(in rect: CGRect) -> Path {
        let grid = GlyphGrid(rect: rect)
        var path = Path()
        path.move(to: grid.point(4.9, 8.3))
        path.addLine(to: grid.point(6.9, 10.3))
        path.addLine(to: grid.point(11.2, 6))
        return path
    }
}

// MARK: - Tables

private struct MarkdownTableView: View {
    let table: MarkdownTable

    var body: some View {
        // A wide table scrolls in place rather than squeezing its columns into
        // ellipses — the page itself never scrolls horizontally.
        ScrollView(.horizontal) {
            Grid(alignment: .leading, horizontalSpacing: EchoSpacing.l, verticalSpacing: EchoSpacing.s) {
                GridRow {
                    // Rows are pre-padded to the header's width (parser
                    // contract), so the grid is rigid by construction.
                    ForEach(Array(table.header.enumerated()), id: \.offset) { _, cell in
                        Text(MarkdownRendering.attributedString(for: cell, baseFont: EchoFont.bodyBold))
                            .foregroundStyle(EchoColor.textPrimary)
                            .textSelection(.enabled)
                    }
                }
                EchoColor.divider
                    .frame(height: EchoLayout.hairline)
                ForEach(Array(table.rows.enumerated()), id: \.offset) { _, row in
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                            Text(
                                MarkdownRendering.attributedString(
                                    for: cell, baseFont: EchoFont.body, boldFont: EchoFont.bodyBold)
                            )
                            .foregroundStyle(EchoColor.textProse)
                            .textSelection(.enabled)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Code blocks

private struct MarkdownCodeBlockView: View {
    let code: String

    var body: some View {
        Text(code)
            .font(EchoFont.inlineCode)
            .foregroundStyle(EchoColor.textValue)
            .textSelection(.enabled)
            .padding(EchoSpacing.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(EchoColor.surface, in: .rect(cornerRadius: EchoRadius.control))
    }
}
