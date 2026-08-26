//
//  MarkdownView.swift
//  Echo
//
//  The adaptive summary's native renderer. `MeetingSummary.resolvedMarkdown`
//  is the one string both eras produce — the model's document verbatim, or a
//  legacy fixed-schema summary serialized to the same grammar — and this view
//  turns it into real formatting: headings on the app's type scale, nested
//  bullets and checkboxes, inline bold/italic/code, tables, rules, and code
//  blocks.
//
//  Two constraints shape the design. First, streaming: the summary tab shows
//  the document while the model is still writing it, so `body` re-parses the
//  markdown on every tick. That is deliberate — `MarkdownDocument.parse` is
//  microseconds for a summary-sized document, and stateless re-parsing means
//  there is no incremental-update machinery to get out of sync. Second,
//  theming (macOS 26): window backgrounds are wallpaper-tinted materials, so
//  nothing here paints a flat theme color behind text — only semantic styles
//  and faint `Color.primary` opacities that read correctly over any material.
//
//  The span→AttributedString conversion and the list marker/indent math live
//  in `MarkdownRendering` as pure `nonisolated` functions so tests exercise
//  them directly, without a render pass.
//

import SwiftUI

// MARK: - Pure formatting helpers

/// The testable half of the renderer: everything that turns parsed markdown
/// values into drawable primitives without touching a view.
nonisolated enum MarkdownRendering {

    /// Leading indent added per list nesting level.
    static let listIndent: CGFloat = 18

    /// The document's type scale, mapped onto the app's. h3 is the workhorse
    /// heading a Notion-style summary leans on (and what the legacy
    /// serialization emits), so it gets `.headline` — the same rank the old
    /// fixed section titles had. h4–h6 share the smallest tier: by then the
    /// hierarchy is spent and anything deeper is just a strong label.
    static func headingFont(level: Int) -> Font {
        switch level {
        case 1: return .title2.weight(.bold)
        case 2: return .title3.weight(.semibold)
        case 3: return .headline
        default: return .subheadline.weight(.semibold)
        }
    }

    /// Ordered-list marker for a zero-based position: "1.", "2.", …
    /// The parser doesn't preserve source numbers (the model's numbering
    /// drifts mid-stream); position is the honest count.
    static func orderedMarker(position: Int) -> String {
        "\(position + 1)."
    }

    /// Leading indent for a nesting level. Clamped at zero so no input can
    /// push content off the leading edge.
    static func indent(level: Int) -> CGFloat {
        CGFloat(max(0, level)) * listIndent
    }

    /// Converts one flat span run into a single AttributedString. Styles map
    /// onto the base font's traits — bold/italic compose, code swaps to the
    /// monospaced design and picks up a faint primary-tinted highlight (an
    /// opacity, never a flat theme color, per the material-background rule).
    /// An empty run converts to an empty string; there is nothing to index.
    static func attributedString(for spans: [MarkdownSpan], baseFont: Font) -> AttributedString {
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

/// Renders an adaptive markdown document. Stateless: parse lives in `body`,
/// so a growing streaming string simply re-renders with more blocks.
struct MarkdownView: View {
    let markdown: String

    var body: some View {
        let blocks = MarkdownDocument.parse(markdown)
        VStack(alignment: .leading, spacing: 14) {
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
            Text(MarkdownRendering.attributedString(
                for: spans,
                baseFont: MarkdownRendering.headingFont(level: level)
            ))
            .textSelection(.enabled)

        case .paragraph(let spans):
            Text(MarkdownRendering.attributedString(for: spans, baseFont: .body))
                .textSelection(.enabled)

        case .list(let items, let ordered):
            MarkdownListView(items: items, ordered: ordered)

        case .horizontalRule:
            Divider().padding(.vertical, 4)

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
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                // A fixed-minimum marker column keeps wrapped item text
                // aligned to its own left edge instead of the marker's.
                marker
                    .frame(minWidth: MarkdownRendering.listIndent, alignment: .leading)
                Text(MarkdownRendering.attributedString(for: item.spans, baseFont: .body))
                    .textSelection(.enabled)
                    // A done item recedes: same content, less pull.
                    .foregroundStyle(item.checkbox == .checked
                        ? AnyShapeStyle(.secondary)
                        : AnyShapeStyle(.primary))
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
                .font(.body)
                .foregroundStyle(.secondary)
        } else if ordered {
            Text(MarkdownRendering.orderedMarker(position: position))
                .font(.body.monospacedDigit())
                .foregroundStyle(.secondary)
        } else {
            Text("•")
                .font(.body)
                .foregroundStyle(.secondary)
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
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                GridRow {
                    // Rows are pre-padded to the header's width (parser
                    // contract), so the grid is rigid by construction.
                    ForEach(Array(table.header.enumerated()), id: \.offset) { _, cell in
                        Text(MarkdownRendering.attributedString(
                            for: cell,
                            baseFont: .body.weight(.semibold)
                        ))
                        .textSelection(.enabled)
                    }
                }
                Divider()
                ForEach(Array(table.rows.enumerated()), id: \.offset) { _, row in
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                            Text(MarkdownRendering.attributedString(for: cell, baseFont: .body))
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
            .font(.body.monospaced())
            .textSelection(.enabled)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            // A faint primary-tinted fill, not a flat theme color: it reads as
            // a panel over any wallpaper-tinted material, light or dark.
            .background(
                Color.primary.opacity(0.05),
                in: RoundedRectangle(cornerRadius: 6)
            )
    }
}
