//
//  MarkdownRenderingTests.swift
//  EchoTests
//
//  The pure half of the adaptive-summary renderer: span runs → one
//  AttributedString, ordered-list markers, and nesting-indent math. These are
//  the parts MarkdownView leans on every streaming tick, so they get direct
//  tests — the view itself is composition over these plus the already-tested
//  parser, and is verified by compilation and the suite. The last two tests
//  drive a realistic summary document (and every streaming prefix of it)
//  through parse → convert, pinning the "never crashes mid-stream" contract
//  end to end without a render pass.
//

import Foundation
import SwiftUI
import Testing
@testable import Echo

@Suite("Markdown rendering helpers")
struct MarkdownRenderingTests {

    // MARK: - Span conversion

    @Test func plainSpanKeepsTheBaseFont() {
        let attributed = MarkdownRendering.attributedString(
            for: [MarkdownSpan(text: "plain", style: [])],
            baseFont: .body
        )
        let runs = Array(attributed.runs)
        #expect(String(attributed.characters) == "plain")
        #expect(runs.count == 1)
        #expect(runs.first?.font == Font.body)
    }

    @Test func boldSpanCarriesBoldTraits() {
        let attributed = MarkdownRendering.attributedString(
            for: [MarkdownSpan(text: "strong", style: .bold)],
            baseFont: .body
        )
        let font = Array(attributed.runs).first?.font
        #expect(font == Font.body.bold())
        #expect(font != Font.body)
    }

    @Test func italicSpanCarriesItalicTraits() {
        let attributed = MarkdownRendering.attributedString(
            for: [MarkdownSpan(text: "leaning", style: .italic)],
            baseFont: .body
        )
        let font = Array(attributed.runs).first?.font
        #expect(font == Font.body.italic())
        #expect(font != Font.body)
    }

    @Test func boldItalicCombinesBothTraits() {
        let attributed = MarkdownRendering.attributedString(
            for: [MarkdownSpan(text: "both", style: [.bold, .italic])],
            baseFont: .body
        )
        let font = Array(attributed.runs).first?.font
        #expect(font == Font.body.bold().italic())
        #expect(font != Font.body.bold())
        #expect(font != Font.body.italic())
    }

    @Test func codeSpanIsMonospacedWithASubtleBackground() {
        let attributed = MarkdownRendering.attributedString(
            for: [MarkdownSpan(text: "let x", style: .code)],
            baseFont: .body
        )
        let run = Array(attributed.runs).first
        #expect(run?.font == Font.body.monospaced())
        #expect(run?.backgroundColor != nil)
    }

    @Test func nonCodeSpansHaveNoBackground() {
        let attributed = MarkdownRendering.attributedString(
            for: [MarkdownSpan(text: "prose", style: .bold)],
            baseFont: .body
        )
        #expect(Array(attributed.runs).first?.backgroundColor == nil)
    }

    @Test func spanRunsConcatenateInOrder() {
        let attributed = MarkdownRendering.attributedString(
            for: [
                MarkdownSpan(text: "a ", style: []),
                MarkdownSpan(text: "b", style: .bold),
                MarkdownSpan(text: " c", style: [])
            ],
            baseFont: .body
        )
        #expect(String(attributed.characters) == "a b c")
    }

    @Test func emptySpansProduceAnEmptyStringWithoutCrashing() {
        // The parser's contract allows an empty spans array on any block
        // (a bare "#" mid-stream, a padded table cell) — render nothing.
        let attributed = MarkdownRendering.attributedString(for: [], baseFont: .body)
        #expect(attributed.characters.isEmpty)
    }

    // MARK: - Ordered markers and indent math

    @Test func orderedMarkersCountFromOneByPosition() {
        #expect(MarkdownRendering.orderedMarker(position: 0) == "1.")
        #expect(MarkdownRendering.orderedMarker(position: 1) == "2.")
        #expect(MarkdownRendering.orderedMarker(position: 9) == "10.")
    }

    @Test func indentGrowsEighteenPointsPerNestingLevel() {
        #expect(MarkdownRendering.indent(level: 0) == 0)
        #expect(MarkdownRendering.indent(level: 1) == 18)
        #expect(MarkdownRendering.indent(level: 2) == 36)
        // A negative level is impossible from the parser, but the math must
        // never push content off the leading edge.
        #expect(MarkdownRendering.indent(level: -1) == 0)
    }

    // MARK: - Typography scale

    @Test func headingFontsFollowTheDocumentScale() {
        #expect(MarkdownRendering.headingFont(level: 1) == Font.title2.weight(.bold))
        #expect(MarkdownRendering.headingFont(level: 2) == Font.title3.weight(.semibold))
        #expect(MarkdownRendering.headingFont(level: 3) == Font.headline)
        // h4–h6 share the smallest tier: the document's depth budget is spent
        // by h3 (the workhorse), anything deeper just reads as a strong label.
        #expect(MarkdownRendering.headingFont(level: 4) == Font.subheadline.weight(.semibold))
        #expect(MarkdownRendering.headingFont(level: 5) == Font.subheadline.weight(.semibold))
        #expect(MarkdownRendering.headingFont(level: 6) == Font.subheadline.weight(.semibold))
    }

    // MARK: - Full document pass

    /// A realistic adaptive summary: headings, styled prose, nested bullets,
    /// checkboxes, an ordered list, a table, a rule, and fenced code.
    private static let sampleDocument = """
    # Weekly Sync

    The team reviewed the **capture pipeline** and agreed on next steps for \
    the `v0.0.12` release.

    ## Highlights

    - Parakeet migration is *complete*
    - Dedup v2 shipped with the bleed fix
      - Own-voice guard enabled by default
    - Release notes drafted

    ### Action Items

    - [ ] Validate the AirPods field test
    - [x] Merge the settings page branch

    ### Decisions

    1. Ship zip-only releases for now
    2. Defer Sparkle integration

    | Area | Owner | Status |
    | --- | --- | --- |
    | Capture | Diego | **Done** |
    | Summaries | Team | In progress |

    ---

    ```swift
    let answer = 42
    ```
    """

    @Test func everyTextBearingBlockOfARealisticDocumentConverts() {
        let blocks = MarkdownDocument.parse(Self.sampleDocument)

        // The document must exercise the whole block vocabulary — otherwise
        // this test silently stops covering what it claims to.
        #expect(blocks.contains { if case .heading = $0 { return true } else { return false } })
        #expect(blocks.contains { if case .table = $0 { return true } else { return false } })
        #expect(blocks.contains { if case .horizontalRule = $0 { return true } else { return false } })
        #expect(blocks.contains { if case .codeBlock = $0 { return true } else { return false } })
        #expect(blocks.contains { block in
            if case .list(let items, _) = block { return items.contains { $0.checkbox != nil } }
            return false
        })

        for block in blocks {
            for spans in Self.spanRuns(in: block) where !spans.isEmpty {
                let attributed = MarkdownRendering.attributedString(for: spans, baseFont: .body)
                #expect(!attributed.characters.isEmpty)
            }
        }
    }

    @Test func everyStreamingPrefixParsesAndConvertsWithoutCrashing() {
        // The UI re-parses the accumulated text on every streaming tick, so a
        // cut at ANY offset — mid-fence, mid-table, mid-`**bold` — must make
        // it through parse → convert. Every 100 characters is plenty to cross
        // each block boundary in the sample.
        let characters = Array(Self.sampleDocument)
        var offsets = Array(stride(from: 0, to: characters.count, by: 100))
        offsets.append(characters.count)

        for offset in offsets {
            let prefix = String(characters[0..<offset])
            for block in MarkdownDocument.parse(prefix) {
                for spans in Self.spanRuns(in: block) {
                    _ = MarkdownRendering.attributedString(for: spans, baseFont: .body)
                }
            }
        }

        // The loop surviving IS the assertion; pin the full parse as sanity.
        #expect(!MarkdownDocument.parse(Self.sampleDocument).isEmpty)
    }

    // MARK: - Helpers

    /// Every span run a renderer would convert for one block, list children
    /// included — mirroring exactly what MarkdownView walks. `nonisolated`
    /// so the recursive references inside `flatMap` need no actor hop.
    private nonisolated static func spanRuns(in block: MarkdownBlock) -> [[MarkdownSpan]] {
        switch block {
        case .heading(_, let spans): return [spans]
        case .paragraph(let spans): return [spans]
        case .list(let items, _): return items.flatMap(spanRuns(in:))
        case .table(let table): return table.header + table.rows.flatMap { $0 }
        case .horizontalRule, .codeBlock: return []
        }
    }

    private nonisolated static func spanRuns(in item: MarkdownListItem) -> [[MarkdownSpan]] {
        [item.spans] + item.children.flatMap(spanRuns(in:))
    }
}
