//
//  MarkdownDocumentTests.swift
//  EchoTests
//
//  The adaptive-summary parser's contract: any string the 4B model has emitted
//  so far — including a prefix cut mid-token by streaming — becomes renderable
//  blocks, never a throw, never a crash. These tests pin the grammar subset a
//  Notion-style meeting summary actually uses (headings, lists, checkboxes,
//  tables, fenced code, flat inline styles) and the leniency rules that make
//  live rendering possible (unclosed fences and delimiters close implicitly).
//

import Foundation
import Testing
@testable import Echo

@Suite("MarkdownDocument parser")
struct MarkdownDocumentTests {

    // MARK: - Nothing to render

    @Test func emptyStringParsesToNoBlocks() {
        #expect(MarkdownDocument.parse("") == [])
    }

    @Test func whitespaceOnlyParsesToNoBlocks() {
        #expect(MarkdownDocument.parse("  \n\t\n   \n") == [])
    }

    @Test func aSinglePlainLineIsAParagraph() {
        #expect(MarkdownDocument.parse("Hello world") == [
            .paragraph(spans: [MarkdownSpan(text: "Hello world", style: [])])
        ])
    }

    // MARK: - Paragraphs

    @Test func softWrappedLinesJoinWithASingleSpace() {
        // The model wraps prose freely; the renderer must see one paragraph.
        let text = "The team walked the\nrelease checklist\nend to end."
        #expect(MarkdownDocument.parse(text) == [
            .paragraph(spans: [MarkdownSpan(text: "The team walked the release checklist end to end.", style: [])])
        ])
    }

    @Test func aBlankLineSplitsParagraphs() {
        let text = "First thought.\n\nSecond thought."
        #expect(MarkdownDocument.parse(text) == [
            .paragraph(spans: [MarkdownSpan(text: "First thought.", style: [])]),
            .paragraph(spans: [MarkdownSpan(text: "Second thought.", style: [])])
        ])
    }

    @Test func indentedProseIsStillAParagraphNotCode() {
        // Four-space indent code blocks are NOT in the grammar — only fenced
        // code is. Stray indentation degrades to prose.
        #expect(MarkdownDocument.parse("    just indented text") == [
            .paragraph(spans: [MarkdownSpan(text: "just indented text", style: [])])
        ])
    }

    // MARK: - Headings

    @Test(arguments: 1...6)
    func atxHeadingsParseAtEveryLevel(level: Int) {
        let text = String(repeating: "#", count: level) + " Topic"
        #expect(MarkdownDocument.parse(text) == [
            .heading(level: level, spans: [MarkdownSpan(text: "Topic", style: [])])
        ])
    }

    @Test func headingLevelSevenPlusClampsToSix() {
        // The block contract promises level 1...6; over-deep hashes clamp
        // rather than degrade, so a rambling model still yields a heading.
        #expect(MarkdownDocument.parse("####### Too deep") == [
            .heading(level: 6, spans: [MarkdownSpan(text: "Too deep", style: [])])
        ])
    }

    @Test func hashWithoutASpaceIsAParagraph() {
        #expect(MarkdownDocument.parse("#hashtag") == [
            .paragraph(spans: [MarkdownSpan(text: "#hashtag", style: [])])
        ])
    }

    @Test func aLoneHashIsAnEmptyHeading() {
        // Streaming: "#" is the first byte of a heading the model is still
        // typing. Rendering an empty H1 beats flashing a literal "#".
        #expect(MarkdownDocument.parse("#") == [
            .heading(level: 1, spans: [])
        ])
    }

    // MARK: - Inline styles

    /// Convenience: the spans of a one-paragraph parse.
    private func inline(_ text: String) -> [MarkdownSpan] {
        guard case .paragraph(let spans)? = MarkdownDocument.parse(text).first else {
            return []
        }
        return spans
    }

    @Test func boldSpansParse() {
        #expect(inline("a **bold** word") == [
            MarkdownSpan(text: "a ", style: []),
            MarkdownSpan(text: "bold", style: .bold),
            MarkdownSpan(text: " word", style: [])
        ])
    }

    @Test(arguments: ["an *italic* word", "an _italic_ word"])
    func italicSpansParseWithBothMarkers(text: String) {
        #expect(inline(text) == [
            MarkdownSpan(text: "an ", style: []),
            MarkdownSpan(text: "italic", style: .italic),
            MarkdownSpan(text: " word", style: [])
        ])
    }

    @Test func codeSpansParse() {
        #expect(inline("run `make test` now") == [
            MarkdownSpan(text: "run ", style: []),
            MarkdownSpan(text: "make test", style: .code),
            MarkdownSpan(text: " now", style: [])
        ])
    }

    @Test func boldAndItalicCombineAsFlatStyleSets() {
        // Flat spans: nested emphasis is a style-set union, not a tree.
        #expect(inline("**bold *italic***") == [
            MarkdownSpan(text: "bold ", style: .bold),
            MarkdownSpan(text: "italic", style: [.bold, .italic])
        ])
    }

    @Test func delimitersInsideCodeSpansStayLiteral() {
        #expect(inline("`a ** b _ c`") == [
            MarkdownSpan(text: "a ** b _ c", style: .code)
        ])
    }

    @Test func unclosedBoldStylesToTheEndOfTheBlock() {
        // Streaming: text turns bold the moment ** opens, rather than the
        // renderer flashing literal asterisks until the close arrives.
        #expect(inline("ship **on Friday") == [
            MarkdownSpan(text: "ship ", style: []),
            MarkdownSpan(text: "on Friday", style: .bold)
        ])
    }

    @Test func unclosedCodeSpanStylesToTheEndOfTheBlock() {
        #expect(inline("call `resolve(") == [
            MarkdownSpan(text: "call ", style: []),
            MarkdownSpan(text: "resolve(", style: .code)
        ])
    }

    @Test func inlineStylesApplyInsideHeadings() {
        #expect(MarkdownDocument.parse("## The **Plan**") == [
            .heading(level: 2, spans: [
                MarkdownSpan(text: "The ", style: []),
                MarkdownSpan(text: "Plan", style: .bold)
            ])
        ])
    }

    // MARK: - Tables

    /// Convenience: one unstyled cell.
    private func cell(_ text: String) -> [MarkdownSpan] {
        text.isEmpty ? [] : [MarkdownSpan(text: text, style: [])]
    }

    @Test func aTableParsesWithOuterPipes() {
        let text = """
        | Owner | Task |
        | --- | :--: |
        | Ana | Cut branch |
        | Luis | Changelog |
        """
        #expect(MarkdownDocument.parse(text) == [
            .table(MarkdownTable(
                header: [cell("Owner"), cell("Task")],
                rows: [
                    [cell("Ana"), cell("Cut branch")],
                    [cell("Luis"), cell("Changelog")]
                ]
            ))
        ])
    }

    @Test func aTableParsesWithoutOuterPipes() {
        let text = "Owner | Task\n--- | ---\nAna | Cut branch"
        #expect(MarkdownDocument.parse(text) == [
            .table(MarkdownTable(
                header: [cell("Owner"), cell("Task")],
                rows: [[cell("Ana"), cell("Cut branch")]]
            ))
        ])
    }

    @Test func rowsArePaddedAndTruncatedToTheHeaderWidth() {
        let text = "| a | b |\n|---|---|\n| only |\n| x | y | extra |"
        #expect(MarkdownDocument.parse(text) == [
            .table(MarkdownTable(
                header: [cell("a"), cell("b")],
                rows: [
                    [cell("only"), []],          // padded
                    [cell("x"), cell("y")]       // truncated
                ]
            ))
        ])
    }

    @Test func tableCellsCarryInlineStyles() {
        let text = "| Task |\n| --- |\n| **urgent** fix |"
        #expect(MarkdownDocument.parse(text) == [
            .table(MarkdownTable(
                header: [cell("Task")],
                rows: [[[
                    MarkdownSpan(text: "urgent", style: .bold),
                    MarkdownSpan(text: " fix", style: [])
                ]]]
            ))
        ])
    }

    @Test func aPipeLineWithoutASeparatorIsAParagraph() {
        // "a | b" alone is prose that happens to contain pipes — only the
        // header+separator pair opens a table.
        #expect(MarkdownDocument.parse("a | b\nplain next line") == [
            .paragraph(spans: [MarkdownSpan(text: "a | b plain next line", style: [])])
        ])
    }

    @Test func aTableEndsAtTheFirstNonPipeLine() {
        let text = "| a |\n| --- |\n| one |\nprose after"
        #expect(MarkdownDocument.parse(text) == [
            .table(MarkdownTable(header: [cell("a")], rows: [[cell("one")]])),
            .paragraph(spans: [MarkdownSpan(text: "prose after", style: [])])
        ])
    }

    // MARK: - Fenced code

    @Test func fencedCodeParsesWithALanguage() {
        let text = "```swift\nlet x = 1\nlet y = 2\n```"
        #expect(MarkdownDocument.parse(text) == [
            .codeBlock(language: "swift", code: "let x = 1\nlet y = 2")
        ])
    }

    @Test func fencedCodeWithoutALanguageHasNilLanguage() {
        let text = "```\nplain\n```"
        #expect(MarkdownDocument.parse(text) == [
            .codeBlock(language: nil, code: "plain")
        ])
    }

    @Test func codeKeepsMarkdownAndIndentationVerbatim() {
        // Nothing inside a fence is Markdown: markers, hashes, blank lines
        // and leading spaces all survive byte-for-byte.
        let text = "```\n# not a heading\n\n  - not a list\n```"
        #expect(MarkdownDocument.parse(text) == [
            .codeBlock(language: nil, code: "# not a heading\n\n  - not a list")
        ])
    }

    @Test func anUnclosedFenceSwallowsTheRestOfTheInput() {
        // Streaming: the close fence has not arrived yet. Everything after
        // the open fence is code — the renderer shows a growing code block.
        let text = "before\n```python\nprint(1)\nprint(2)"
        #expect(MarkdownDocument.parse(text) == [
            .paragraph(spans: [MarkdownSpan(text: "before", style: [])]),
            .codeBlock(language: "python", code: "print(1)\nprint(2)")
        ])
    }

    @Test func anEmptyFencePairIsAnEmptyCodeBlock() {
        #expect(MarkdownDocument.parse("```\n```") == [
            .codeBlock(language: nil, code: "")
        ])
    }

    // MARK: - Horizontal rules

    @Test(arguments: ["---", "----", "***", "___", "- - -", " ---  ", "*  *  *"])
    func horizontalRuleVariantsParse(text: String) {
        // No setext headings in this grammar, so a dash line is ALWAYS a
        // rule — even the spaced "- - -" form, which must beat the bullet
        // reading ("- " + "- -").
        #expect(MarkdownDocument.parse(text) == [.horizontalRule])
    }

    @Test func mixedRuleCharactersDegradeToAParagraph() {
        // Not an hr (chars differ). The trailing "*" is then an inline italic
        // toggle that styles nothing yet — consumed, exactly as it would be
        // mid-stream — leaving just the dashes.
        #expect(MarkdownDocument.parse("--*") == [
            .paragraph(spans: [MarkdownSpan(text: "--", style: [])])
        ])
    }

    @Test func twoDashesAreNotARule() {
        #expect(MarkdownDocument.parse("--") == [
            .paragraph(spans: [MarkdownSpan(text: "--", style: [])])
        ])
    }

    @Test func aRuleUnderProseIsARuleNotASetextHeading() {
        let text = "Some prose\n---\nmore prose"
        #expect(MarkdownDocument.parse(text) == [
            .paragraph(spans: [MarkdownSpan(text: "Some prose", style: [])]),
            .horizontalRule,
            .paragraph(spans: [MarkdownSpan(text: "more prose", style: [])])
        ])
    }

    @Test func aHeadingInterruptsAParagraph() {
        let text = "Some prose\n## Next Topic\nmore prose"
        #expect(MarkdownDocument.parse(text) == [
            .paragraph(spans: [MarkdownSpan(text: "Some prose", style: [])]),
            .heading(level: 2, spans: [MarkdownSpan(text: "Next Topic", style: [])]),
            .paragraph(spans: [MarkdownSpan(text: "more prose", style: [])])
        ])
    }

    // MARK: - Lists

    /// Convenience: a leaf item with no checkbox and no children.
    private func item(_ text: String, checkbox: MarkdownCheckbox? = nil,
                      children: [MarkdownListItem] = [], childrenOrdered: Bool = false) -> MarkdownListItem {
        MarkdownListItem(
            spans: text.isEmpty ? [] : [MarkdownSpan(text: text, style: [])],
            checkbox: checkbox,
            children: children,
            childrenOrdered: childrenOrdered
        )
    }

    @Test(arguments: ["-", "*", "+"])
    func bulletListsParseWithEveryMarker(marker: String) {
        let text = "\(marker) alpha\n\(marker) beta"
        #expect(MarkdownDocument.parse(text) == [
            .list(items: [item("alpha"), item("beta")], ordered: false)
        ])
    }

    @Test(arguments: ["1. one\n2. two", "1) one\n2) two", "7. one\n99. two"])
    func orderedListsParseWithDotOrParenAndAnyNumbers(text: String) {
        #expect(MarkdownDocument.parse(text) == [
            .list(items: [item("one"), item("two")], ordered: true)
        ])
    }

    @Test func checkboxesParseInBothStates() {
        let text = "- [ ] Cut the release branch\n- [x] Update the changelog\n- [X] Ping QA"
        #expect(MarkdownDocument.parse(text) == [
            .list(items: [
                item("Cut the release branch", checkbox: .unchecked),
                item("Update the changelog", checkbox: .checked),
                item("Ping QA", checkbox: .checked)
            ], ordered: false)
        ])
    }

    @Test func listItemsCarryInlineStyles() {
        #expect(MarkdownDocument.parse("- **Owner**: Ana") == [
            .list(items: [
                MarkdownListItem(
                    spans: [
                        MarkdownSpan(text: "Owner", style: .bold),
                        MarkdownSpan(text: ": Ana", style: [])
                    ],
                    checkbox: nil, children: [], childrenOrdered: false
                )
            ], ordered: false)
        ])
    }

    @Test func aDashWithoutASpaceIsProse() {
        // "-tight" is prose, not a bullet — markers need their space.
        #expect(MarkdownDocument.parse("-tight") == [
            .paragraph(spans: [MarkdownSpan(text: "-tight", style: [])])
        ])
    }

    @Test func nestedListsBuildATreeFromIndentation() {
        let text = """
        - top one
          - child one
          - child two
            - grandchild
        - top two
        """
        #expect(MarkdownDocument.parse(text) == [
            .list(items: [
                item("top one", children: [
                    item("child one"),
                    item("child two", children: [item("grandchild")])
                ]),
                item("top two")
            ], ordered: false)
        ])
    }

    @Test func orderedChildrenUnderABulletKeepTheirOrder() {
        let text = "- steps\n  1. first\n  2. second"
        #expect(MarkdownDocument.parse(text) == [
            .list(items: [
                item("steps", children: [item("first"), item("second")], childrenOrdered: true)
            ], ordered: false)
        ])
    }

    @Test func continuationLinesAppendToTheItem() {
        // An indented line with no marker is the item's own soft wrap.
        let text = "- a task that wraps\n  onto the next line\n- second"
        #expect(MarkdownDocument.parse(text) == [
            .list(items: [
                item("a task that wraps onto the next line"),
                item("second")
            ], ordered: false)
        ])
    }

    @Test func tenLevelDeepNestingParsesWithoutCrashing() {
        // Pathology from the spec: indentation runs away. The tree must
        // follow it faithfully (and cheaply — recursion depth == list depth).
        let text = (0..<10).map { String(repeating: "  ", count: $0) + "- d\($0)" }
            .joined(separator: "\n")
        var expected = item("d9")
        for depth in stride(from: 8, through: 0, by: -1) {
            expected = item("d\(depth)", children: [expected])
        }
        #expect(MarkdownDocument.parse(text) == [.list(items: [expected], ordered: false)])
    }

    @Test func switchingMarkerKindAtTheTopLevelStartsANewList() {
        // Bullets then "1." at the same level is a NEW list — the block's
        // ordered flag cannot honestly describe both.
        let text = "- alpha\n- beta\n1. first\n2. second"
        #expect(MarkdownDocument.parse(text) == [
            .list(items: [item("alpha"), item("beta")], ordered: false),
            .list(items: [item("first"), item("second")], ordered: true)
        ])
    }

    @Test func aRunStartingMidIndentKeepsEveryItem() {
        // Streaming artifact: the first visible entry is deeper than a later
        // one. Nothing is dropped; the shallow entry anchors the block.
        let text = "  - deep first\n- shallow second"
        #expect(MarkdownDocument.parse(text) == [
            .list(items: [item("deep first"), item("shallow second")], ordered: false)
        ])
    }

    @Test func aListEndsAtAHeadingAndAParagraph() {
        let text = "- alpha\n# Head\n- beta\nplain prose"
        #expect(MarkdownDocument.parse(text) == [
            .list(items: [item("alpha")], ordered: false),
            .heading(level: 1, spans: [MarkdownSpan(text: "Head", style: [])]),
            .list(items: [item("beta")], ordered: false),
            .paragraph(spans: [MarkdownSpan(text: "plain prose", style: [])])
        ])
    }

    // MARK: - Streaming leniency

    /// A document exercising every block type, cut at every possible byte
    /// boundary the model could pause at.
    private static let streamingFixture = """
    # Sprint **Review**

    Prose with *italic*, `code`, and
    a soft wrap.

    ---

    ## Action Items
    - [ ] Cut the **release** branch
      - [x] nested done item
    1. first step
    2. second step

    | Owner | Task |
    | --- | --- |
    | Ana | Cut branch |
    | Luis | Changelog |

    ```swift
    let done = true
    ```
    tail prose
    """

    @Test func everyPrefixParsesAndTheFullPrefixMatchesTheFullParse() {
        let text = Self.streamingFixture
        let full = MarkdownDocument.parse(text)
        #expect(full.count == 9)

        // Every character prefix must parse without crashing — this is the
        // renderer's tick-by-tick reality. (String indices, not byte counts:
        // prefixes always land on character boundaries.)
        var boundary = text.startIndex
        while boundary <= text.endIndex {
            let partial = MarkdownDocument.parse(String(text[..<boundary]))
            _ = partial
            if boundary == text.endIndex { break }
            boundary = text.index(after: boundary)
        }
        #expect(MarkdownDocument.parse(String(text[..<text.endIndex])) == full)
    }

    @Test func aTableCutAfterTheHeaderLineIsStillAParagraph() {
        // The separator has not streamed in yet, so the pipes are prose —
        // one tick later the same line becomes a table header.
        #expect(MarkdownDocument.parse("| Owner | Task |") == [
            .paragraph(spans: [MarkdownSpan(text: "| Owner | Task |", style: [])])
        ])
    }

    @Test func aTableCutMidRowsKeepsTheRowsSoFar() {
        let text = "| Owner | Task |\n| --- | --- |\n| Ana | Cut branch |"
        #expect(MarkdownDocument.parse(text) == [
            .table(MarkdownTable(
                header: [cell("Owner"), cell("Task")],
                rows: [[cell("Ana"), cell("Cut branch")]]
            ))
        ])
    }

    // MARK: - Realistic meeting summary

    @Test func aNotionStyleMeetingSummaryParsesIntoTheExpectedBlocks() {
        // The document shape SPEC's adaptive summaries actually emit: a
        // title, an italic meta line, a checkbox Action Items section, and
        // ### topic sections mixing bold terms, nested bullets, and a table.
        let text = """
        # Weekly Sync — Summary

        _2026-08-25 · 30 min_

        ## Action Items
        - [ ] **Ana**: cut the release branch
        - [x] Update the `CHANGELOG`
        - [ ] Schedule the retro
          - [ ] find a slot before *Friday*

        ### Release readiness
        The team walked the checklist end to end
        and QA signs off tomorrow.

        - **Blocker**: staging environment is down
        - **Owner**: unassigned

        ### Metrics review
        | Metric | Value |
        | --- | --- |
        | WER | 12% |
        | Latency | 480ms |
        """

        #expect(MarkdownDocument.parse(text) == [
            .heading(level: 1, spans: [MarkdownSpan(text: "Weekly Sync — Summary", style: [])]),
            .paragraph(spans: [MarkdownSpan(text: "2026-08-25 · 30 min", style: .italic)]),
            .heading(level: 2, spans: [MarkdownSpan(text: "Action Items", style: [])]),
            .list(items: [
                MarkdownListItem(
                    spans: [
                        MarkdownSpan(text: "Ana", style: .bold),
                        MarkdownSpan(text: ": cut the release branch", style: [])
                    ],
                    checkbox: .unchecked, children: [], childrenOrdered: false
                ),
                MarkdownListItem(
                    spans: [
                        MarkdownSpan(text: "Update the ", style: []),
                        MarkdownSpan(text: "CHANGELOG", style: .code)
                    ],
                    checkbox: .checked, children: [], childrenOrdered: false
                ),
                MarkdownListItem(
                    spans: [MarkdownSpan(text: "Schedule the retro", style: [])],
                    checkbox: .unchecked,
                    children: [
                        MarkdownListItem(
                            spans: [
                                MarkdownSpan(text: "find a slot before ", style: []),
                                MarkdownSpan(text: "Friday", style: .italic)
                            ],
                            checkbox: .unchecked, children: [], childrenOrdered: false
                        )
                    ],
                    childrenOrdered: false
                )
            ], ordered: false),
            .heading(level: 3, spans: [MarkdownSpan(text: "Release readiness", style: [])]),
            .paragraph(spans: [MarkdownSpan(text: "The team walked the checklist end to end and QA signs off tomorrow.", style: [])]),
            .list(items: [
                MarkdownListItem(
                    spans: [
                        MarkdownSpan(text: "Blocker", style: .bold),
                        MarkdownSpan(text: ": staging environment is down", style: [])
                    ],
                    checkbox: nil, children: [], childrenOrdered: false
                ),
                MarkdownListItem(
                    spans: [
                        MarkdownSpan(text: "Owner", style: .bold),
                        MarkdownSpan(text: ": unassigned", style: [])
                    ],
                    checkbox: nil, children: [], childrenOrdered: false
                )
            ], ordered: false),
            .heading(level: 3, spans: [MarkdownSpan(text: "Metrics review", style: [])]),
            .table(MarkdownTable(
                header: [cell("Metric"), cell("Value")],
                rows: [
                    [cell("WER"), cell("12%")],
                    [cell("Latency"), cell("480ms")]
                ]
            ))
        ])
    }

    // MARK: - Pathologies

    @Test func triplePipeAloneIsAParagraph() {
        #expect(MarkdownDocument.parse("|||") == [
            .paragraph(spans: [MarkdownSpan(text: "|||", style: [])])
        ])
    }
}
