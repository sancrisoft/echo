//
//  MarkdownView.swift
//  Workspace
//
//  The summary's native renderer: headings on the type scale, nested bullets
//  and checkboxes, inline bold/italic/code, tables, rules and code blocks.
//
//  Two constraints shape it. Streaming: the summary tab shows the document
//  while the model is still writing it, so `body` re-parses the Markdown on
//  every tick — deliberate, because `MarkdownDocument.parse` is microseconds
//  for a summary-sized document and stateless re-parsing has no incremental
//  machinery to get out of sync. Theming: window backgrounds are
//  wallpaper-tinted materials on macOS 26, so nothing here paints a flat color
//  behind text — only semantic styles and faint `Color.primary` opacities that
//  read correctly over any material.
//
//  The span→AttributedString conversion and the list marker/indent math live
//  in `MarkdownRendering` as pure functions so tests exercise them without a
//  render pass.
//

import DesignSystem
import SwiftUI

// MARK: - Pure formatting helpers

/// The testable half of the renderer: everything that turns parsed Markdown
/// values into drawable primitives without touching a view.
public nonisolated enum MarkdownRendering {

    /// Leading indent added per list nesting level.
    public static let listIndent: CGFloat = 18

    /// The document's type scale, mapped onto the app's. h3 is the workhorse
    /// heading a Notion-style summary leans on, so it gets the section title;
    /// h4–h6 share the smallest tier: by then the hierarchy is spent and
    /// anything deeper is just a strong label.
    public static func headingFont(level: Int) -> Font {
        switch level {
        case 1: return EchoFont.documentTitle
        case 2: return Font.system(size: 22, weight: .semibold)
        case 3: return EchoFont.sectionTitle
        default: return EchoFont.body.weight(.semibold)
        }
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

    /// Converts one flat span run into a single AttributedString. Styles map
    /// onto the base font's traits — bold/italic compose, code swaps to the
    /// monospaced design and picks up a faint primary-tinted highlight (an
    /// opacity, never a flat theme color). An empty run converts to an empty
    /// string.
    public static func attributedString(for spans: [MarkdownSpan], baseFont: Font) -> AttributedString {
        var result = AttributedString()
        for span in spans {
            var piece = AttributedString(span.text)
            var font = baseFont
            if span.style.contains(.code) { font = font.monospaced() }
            if span.style.contains(.bold) { font = font.bold() }
            if span.style.contains(.italic) { font = font.italic() }
            piece.font = font
            if span.style.contains(.code) {
                piece.backgroundColor = Color.primary.opacity(0.07)
            }
            result += piece
        }
        return result
    }
}

// MARK: - Document view

/// Renders a Markdown document. Stateless: parse lives in `body`, so a growing
/// streaming string simply re-renders with more blocks.
public struct MarkdownView: View {
    private let markdown: String

    public init(markdown: String) {
        self.markdown = markdown
    }

    public var body: some View {
        let blocks = MarkdownDocument.parse(markdown)
        VStack(alignment: .leading, spacing: EchoSpacing.l) {
            // Identity by position: a streaming parse is prefix-stable (the
            // parser's design goal), so block N stays block N as the document
            // grows and only the tail re-renders meaningfully.
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                MarkdownBlockView(block: block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Blocks

private struct MarkdownBlockView: View {
    let block: MarkdownBlock

    var body: some View {
        switch block {
        case .heading(let level, let spans):
            Text(MarkdownRendering.attributedString(for: spans, baseFont: MarkdownRendering.headingFont(level: level)))
                .foregroundStyle(EchoColor.textPrimary)
                .padding(.top, level <= 2 ? EchoSpacing.s : EchoSpacing.xs)
                .textSelection(.enabled)

        case .paragraph(let spans):
            Text(MarkdownRendering.attributedString(for: spans, baseFont: EchoFont.body))
                .lineSpacing(EchoFont.bodyLineSpacing)
                .foregroundStyle(EchoColor.textPrimary)
                .textSelection(.enabled)

        case .list(let items, let ordered):
            MarkdownListView(items: items, ordered: ordered)

        case .horizontalRule:
            Divider().padding(.vertical, EchoSpacing.xs)

        case .table(let table):
            MarkdownTableView(table: table)

        case .codeBlock(_, let code):
            MarkdownCodeBlockView(code: code)
        }
    }
}

// MARK: - Lists

private struct MarkdownListView: View {
    let items: [MarkdownListItem]
    let ordered: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(items.enumerated()), id: \.offset) { position, item in
                MarkdownListItemView(item: item, ordered: ordered, position: position)
            }
        }
    }
}

private struct MarkdownListItemView: View {
    let item: MarkdownListItem
    let ordered: Bool
    let position: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: EchoSpacing.s) {
                // A fixed-minimum marker column keeps wrapped item text aligned
                // to its own left edge instead of the marker's.
                marker
                    .frame(minWidth: MarkdownRendering.listIndent, alignment: .leading)
                Text(MarkdownRendering.attributedString(for: item.spans, baseFont: EchoFont.body))
                    .lineSpacing(EchoFont.bodyLineSpacing)
                    .textSelection(.enabled)
                    // A done item recedes: same content, less pull.
                    .foregroundStyle(item.checkbox == .checked ? EchoColor.textSecondary : EchoColor.textPrimary)
            }
            if !item.children.isEmpty {
                // One indent step per structural level — recursion accumulates
                // the rest, so the constant is relative, not absolute depth.
                MarkdownListView(items: item.children, ordered: item.childrenOrdered)
                    .padding(.leading, MarkdownRendering.indent(level: 1))
            }
        }
    }

    @ViewBuilder
    private var marker: some View {
        if let checkbox = item.checkbox {
            Image(systemName: checkbox == .checked ? "checkmark.square.fill" : "square")
                .font(EchoFont.body)
                .foregroundStyle(checkbox == .checked ? EchoColor.accent : EchoColor.textTertiary)
        } else if ordered {
            Text(MarkdownRendering.orderedMarker(position: position))
                .font(EchoFont.body.monospacedDigit())
                .foregroundStyle(EchoColor.textSecondary)
        } else {
            Text("•")
                .font(EchoFont.body)
                .foregroundStyle(EchoColor.textSecondary)
        }
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
                        Text(MarkdownRendering.attributedString(for: cell, baseFont: EchoFont.body.weight(.semibold)))
                            .textSelection(.enabled)
                    }
                }
                Divider()
                ForEach(Array(table.rows.enumerated()), id: \.offset) { _, row in
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                            Text(MarkdownRendering.attributedString(for: cell, baseFont: EchoFont.body))
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
            .font(EchoFont.mono(13))
            .textSelection(.enabled)
            .padding(EchoSpacing.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            // A faint primary-tinted fill, not a flat theme color: it reads as a
            // panel over any wallpaper-tinted material, light or dark.
            .background(Color.primary.opacity(0.05), in: .rect(cornerRadius: EchoRadius.control))
    }
}
