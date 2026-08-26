//
//  MarkdownDocument.swift
//  Echo
//
//  The pure parser behind adaptive Markdown summaries. The local 4B model
//  streams a Markdown document token by token, and the UI re-parses the
//  accumulated text on every tick — so this parser's contract is leniency,
//  not conformance: `parse` accepts ANY string, including a prefix cut in the
//  middle of a fence, a table, or a `**bold` run, and always returns blocks a
//  renderer can draw. It never throws and never crashes.
//
//  The grammar is deliberately a subset of Markdown — the vocabulary a
//  Notion-style meeting summary actually uses: ATX headings, paragraphs,
//  bullet/ordered/task lists with indentation nesting, pipe tables, fenced
//  code, horizontal rules, and FLAT inline styles (bold/italic/code combine
//  as an OptionSet, they do not nest as a tree). Setext headings are out:
//  a `---` line is always a horizontal rule, so the parser never has to
//  retroactively reinterpret the previous line — which is what makes
//  prefix-stable streaming parses cheap. Anything unrecognized degrades to
//  a paragraph rather than being dropped.
//

import Foundation

// MARK: - Blocks

/// One renderable unit of the document, in source order.
nonisolated enum MarkdownBlock: Hashable, Sendable {
    case heading(level: Int, spans: [MarkdownSpan])   // level clamped 1...6
    case paragraph(spans: [MarkdownSpan])
    case list(items: [MarkdownListItem], ordered: Bool)
    case horizontalRule
    case table(MarkdownTable)
    case codeBlock(language: String?, code: String)
}

// MARK: - Inline spans

/// Flat inline styling: a span carries the full set of styles active over its
/// text. `**bold *italic***` becomes [bold]("bold "), [bold, italic]("italic")
/// — no span tree for the renderer to recurse into.
nonisolated struct MarkdownSpanStyle: OptionSet, Hashable, Sendable {
    let rawValue: Int
    init(rawValue: Int) { self.rawValue = rawValue }

    static let bold = MarkdownSpanStyle(rawValue: 1 << 0)
    static let italic = MarkdownSpanStyle(rawValue: 1 << 1)
    static let code = MarkdownSpanStyle(rawValue: 1 << 2)
}

/// A run of text with one uniform style set.
nonisolated struct MarkdownSpan: Hashable, Sendable {
    var text: String
    var style: MarkdownSpanStyle
}

// MARK: - Lists

/// Task-list state. `nil` checkbox on the item means a plain bullet.
nonisolated enum MarkdownCheckbox: Hashable, Sendable {
    case checked
    case unchecked
}

/// One list item, possibly carrying a nested child list.
nonisolated struct MarkdownListItem: Hashable, Sendable {
    var spans: [MarkdownSpan]
    var checkbox: MarkdownCheckbox?
    var children: [MarkdownListItem]
    var childrenOrdered: Bool
}

// MARK: - Tables

/// A pipe table: one header row plus body rows, every row padded/truncated
/// to the header's width so the renderer can lay out a rigid grid.
nonisolated struct MarkdownTable: Hashable, Sendable {
    var header: [[MarkdownSpan]]
    var rows: [[[MarkdownSpan]]]
}

// MARK: - Parser

nonisolated enum MarkdownDocument {

    /// Turns any string — full document or streaming prefix — into blocks.
    /// Never throws; unrecognized input degrades to paragraphs.
    static func parse(_ text: String) -> [MarkdownBlock] {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> String in
                // Tolerate CRLF from any transport without a separate pass.
                var s = String(line)
                if s.hasSuffix("\r") { s.removeLast() }
                return s
            }

        var blocks: [MarkdownBlock] = []
        var i = 0

        // A pipe line opens a table only when the line right after it is a
        // separator row — otherwise it is prose that happens to contain "|".
        func isTableStart(_ index: Int) -> Bool {
            guard case .pipeRow = classify(lines[index]) else { return false }
            return index + 1 < lines.count && isTableSeparator(lines[index + 1])
        }

        // Paragraph: consecutive plain lines soft-wrap into one. Any special
        // line (heading, rule, list, fence, table start…) interrupts it — the
        // model does not always leave blank lines between blocks.
        func consumeParagraph() {
            var parts: [String] = []
            consume: while i < lines.count {
                switch classify(lines[i]) {
                case .text(_, let content):
                    parts.append(content)
                    i += 1
                case .pipeRow(let content) where !isTableStart(i):
                    parts.append(content)
                    i += 1
                default:
                    break consume
                }
            }
            blocks.append(.paragraph(spans: spans(from: parts.joined(separator: " "))))
        }

        while i < lines.count {
            switch classify(lines[i]) {
            case .blank:
                i += 1

            case .fence(let language):
                // Everything until the closing fence is verbatim — no
                // trimming, no Markdown. A missing close fence is the
                // streaming case: the rest of the input is code so far.
                i += 1
                var codeLines: [String] = []
                while i < lines.count, !isCloseFence(lines[i]) {
                    codeLines.append(lines[i])
                    i += 1
                }
                if i < lines.count { i += 1 } // consume the close fence
                blocks.append(.codeBlock(language: language, code: codeLines.joined(separator: "\n")))

            case .rule:
                blocks.append(.horizontalRule)
                i += 1

            case .heading(let level, let text):
                blocks.append(.heading(level: level, spans: spans(from: text)))
                i += 1

            case .listItem:
                // Collect the whole run: marker lines plus indented
                // continuation lines (which append to the previous item).
                // Anything else — blank line, heading, rule, plain prose at
                // the margin — ends the list.
                var entries: [ListEntry] = []
                var minLevel = Int.max
                var topOrdered = false
                collect: while i < lines.count {
                    switch classify(lines[i]) {
                    case .listItem(let level, let ordered, let checkbox, let text):
                        if level < minLevel {
                            // A shallower entry re-anchors the run; its kind
                            // becomes the block's kind.
                            minLevel = level
                            topOrdered = ordered
                        } else if level == minLevel, ordered != topOrdered {
                            // Bullets then "1." at the same level: the block's
                            // ordered flag cannot describe both — a new list
                            // starts here.
                            break collect
                        }
                        entries.append(ListEntry(level: level, ordered: ordered, checkbox: checkbox, text: text))
                        i += 1
                    case .text(let indent, let content) where indent > 0 && !entries.isEmpty:
                        entries[entries.count - 1].text += " " + content
                        i += 1
                    default:
                        break collect
                    }
                }
                blocks.append(listBlock(from: entries))

            case .pipeRow(let headerLine):
                guard isTableStart(i) else {
                    consumeParagraph()
                    continue
                }
                // Header + separator confirmed. Rows follow until the first
                // non-pipe line; every row is padded/truncated to the header
                // width so the renderer can lay out a rigid grid. A stream
                // cut mid-table simply yields the rows received so far.
                let header = tableCells(headerLine).map(spans(from:))
                let width = header.count
                i += 2
                var rows: [[[MarkdownSpan]]] = []
                while i < lines.count, case .pipeRow(let rowLine) = classify(lines[i]) {
                    var cells = tableCells(rowLine).map(spans(from:))
                    if cells.count < width {
                        cells.append(contentsOf: Array(repeating: [], count: width - cells.count))
                    } else if cells.count > width {
                        cells.removeSubrange(width...)
                    }
                    rows.append(cells)
                    i += 1
                }
                blocks.append(.table(MarkdownTable(header: header, rows: rows)))

            case .text:
                consumeParagraph()
            }
        }
        return blocks
    }

    // MARK: Tables

    /// Splits one pipe line into trimmed cell strings. Outer pipes are
    /// optional; "a | b", "| a | b", and "| a | b |" all mean two cells.
    private static func tableCells(_ line: String) -> [String] {
        var body = line.trimmingCharacters(in: .whitespaces)
        if body.hasPrefix("|") { body.removeFirst() }
        if body.hasSuffix("|") { body.removeLast() }
        return body.components(separatedBy: "|")
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// The `|---|:--:|` row that turns the line above it into a table
    /// header: every cell is dashes with optional alignment colons, and at
    /// least one pipe is present (a bare "---" stays a horizontal rule).
    private static func isTableSeparator(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains("|") else { return false }
        return tableCells(trimmed).allSatisfy { cell in
            var body = Substring(cell)
            if body.first == ":" { body = body.dropFirst() }
            if body.last == ":" { body = body.dropLast() }
            return !body.isEmpty && body.allSatisfy { $0 == "-" }
        }
    }

    // MARK: Lists

    /// One marker line, flattened: nesting level, marker kind, and raw text
    /// (continuations already joined). The tree is rebuilt afterwards.
    private struct ListEntry {
        var level: Int
        var ordered: Bool
        var checkbox: MarkdownCheckbox?
        var text: String
    }

    private static func listBlock(from entries: [ListEntry]) -> MarkdownBlock {
        // The shallowest entry anchors the block, so a run that starts
        // mid-indent (a streaming artifact) still yields every item.
        let minLevel = entries.map(\.level).min() ?? 0
        var index = 0
        let items = buildItems(entries, &index, level: minLevel)
        let ordered = entries.first(where: { $0.level == minLevel })?.ordered ?? false
        return .list(items: items, ordered: ordered)
    }

    /// Rebuilds the item tree from the flat run: entries at `level` are
    /// siblings, a deeper entry starts a child group under the previous
    /// sibling, a shallower one returns to the caller.
    private static func buildItems(_ entries: [ListEntry], _ index: inout Int, level: Int) -> [MarkdownListItem] {
        var items: [MarkdownListItem] = []
        while index < entries.count {
            let entry = entries[index]
            if entry.level < level { break }
            if entry.level > level {
                let childOrdered = entry.ordered
                let children = buildItems(entries, &index, level: entry.level)
                if items.isEmpty {
                    // A deeper entry with no sibling yet to hang it on (the
                    // run began mid-indent): adopt the group at this level
                    // rather than dropping the items.
                    items.append(contentsOf: children)
                } else {
                    items[items.count - 1].children.append(contentsOf: children)
                    items[items.count - 1].childrenOrdered = childOrdered
                }
            } else {
                items.append(MarkdownListItem(
                    spans: spans(from: entry.text),
                    checkbox: entry.checkbox,
                    children: [],
                    childrenOrdered: false
                ))
                index += 1
            }
        }
        return items
    }

    // MARK: Line classification

    /// What one raw line means on its own. Context-dependent meanings (table
    /// rows, list continuations) are resolved by the block loops above.
    private enum Line {
        case blank
        case fence(language: String?)
        case rule
        case heading(level: Int, text: String)
        case listItem(level: Int, ordered: Bool, checkbox: MarkdownCheckbox?, text: String)
        case pipeRow(String)                    // contains "|": a table row —
                                                // or plain prose, if no
                                                // separator line follows
        case text(indent: Int, content: String) // trimmed prose + its indent,
                                                // so lists can tell a nested
                                                // continuation from prose that
                                                // ends them
    }

    private static func classify(_ line: String) -> Line {
        if isBlank(line) { return .blank }
        let trimmed = line.trimmingCharacters(in: .whitespaces)

        // Code fence: 3+ backticks, optionally followed by a language word.
        if trimmed.hasPrefix("```") {
            let afterTicks = trimmed.drop(while: { $0 == "`" })
            let language = afterTicks
                .trimmingCharacters(in: .whitespaces)
                .split(separator: " ")
                .first
                .map(String.init)
            return .fence(language: language)
        }

        // Horizontal rule: 3+ of one character among -, *, _ with nothing
        // else but spaces. Checked BEFORE the list marker so "- - -" is a
        // rule, and there are no setext headings to disambiguate against.
        let ruleBody = trimmed.filter { $0 != " " }
        if ruleBody.count >= 3, let ruleChar = ruleBody.first,
           "-*_".contains(ruleChar), ruleBody.allSatisfy({ $0 == ruleChar }) {
            return .rule
        }

        // ATX heading: 1+ hashes then a space (or nothing — a bare "#" is a
        // heading the model is still typing). Depth clamps to the contract's
        // 1...6 so the renderer never sees an impossible level.
        if trimmed.hasPrefix("#") {
            let hashes = trimmed.prefix(while: { $0 == "#" })
            let rest = trimmed.dropFirst(hashes.count)
            if rest.isEmpty || rest.first == " " {
                let level = min(hashes.count, 6)
                return .heading(level: level, text: rest.trimmingCharacters(in: .whitespaces))
            }
        }

        // Indentation decides list nesting: every 2 spaces is one level, a
        // tab counts as 4 spaces (the model occasionally emits tabs).
        var indent = 0
        var body = Substring(line)
        while let first = body.first, first == " " || first == "\t" {
            indent += first == "\t" ? 4 : 1
            body = body.dropFirst()
        }

        // List markers: "-", "*", "+" bullets, or digits + "." / ")" ordered.
        // The space after the marker is mandatory — "-tight" and "1.5" are
        // prose. (A bare "-" is also prose: mid-stream it is just as likely
        // the first byte of a rule, so guessing "list" buys nothing.)
        if let marker = body.first, "-*+".contains(marker), body.dropFirst().first == " " {
            let rest = body.dropFirst(2)
            let (checkbox, text) = splitCheckbox(rest)
            return .listItem(level: indent / 2, ordered: false, checkbox: checkbox, text: text)
        }
        let digits = body.prefix(while: \.isNumber)
        if !digits.isEmpty {
            let afterDigits = body.dropFirst(digits.count)
            if let punct = afterDigits.first, punct == "." || punct == ")",
               afterDigits.dropFirst().first == " " {
                let text = afterDigits.dropFirst(2).trimmingCharacters(in: .whitespaces)
                return .listItem(level: indent / 2, ordered: true, checkbox: nil, text: text)
            }
        }

        // A pipe anywhere makes the line a candidate table row; whether it
        // really is one depends on the NEXT line (header + separator), which
        // only the block loop can see.
        if trimmed.contains("|") {
            return .pipeRow(trimmed)
        }

        return .text(indent: indent, content: trimmed)
    }

    /// Splits a task checkbox off a bullet's text: "[ ] ", "[x] ", "[X] "
    /// (or the bare box at end of line — the model may pause right there).
    private static func splitCheckbox(_ rest: Substring) -> (MarkdownCheckbox?, String) {
        guard rest.count >= 3, rest.first == "[" else {
            return (nil, rest.trimmingCharacters(in: .whitespaces))
        }
        let mark = rest[rest.index(after: rest.startIndex)]
        let close = rest[rest.index(rest.startIndex, offsetBy: 2)]
        let after = rest.dropFirst(3)
        guard close == "]", after.isEmpty || after.first == " " else {
            return (nil, rest.trimmingCharacters(in: .whitespaces))
        }
        let text = after.trimmingCharacters(in: .whitespaces)
        switch mark {
        case " ": return (.unchecked, text)
        case "x", "X": return (.checked, text)
        default: return (nil, rest.trimmingCharacters(in: .whitespaces))
        }
    }

    // MARK: Inline

    /// Parses inline text into flat styled spans.
    ///
    /// Delimiters TOGGLE styles in a running set — `**` bold, `*`/`_` italic,
    /// backtick code — so nesting flattens naturally (`**bold *italic***` →
    /// bold, then bold+italic) and an unclosed delimiter styles to the end of
    /// the block. That last part is the streaming contract: while the model
    /// is mid-`**bold`, the text renders bold instead of flashing literal
    /// asterisks that vanish a tick later. Inside a code span every other
    /// delimiter is literal; only the closing backtick (or end of text)
    /// leaves it.
    private static func spans(from text: String) -> [MarkdownSpan] {
        var result: [MarkdownSpan] = []
        var buffer = ""
        var style: MarkdownSpanStyle = []

        func flush() {
            guard !buffer.isEmpty else { return }
            // Coalesce adjacent same-style runs (a toggled-off-and-on pair
            // would otherwise split text the renderer sees as one run).
            if var last = result.last, last.style == style {
                last.text += buffer
                result[result.count - 1] = last
            } else {
                result.append(MarkdownSpan(text: buffer, style: style))
            }
            buffer = ""
        }

        let chars = Array(text)
        var i = 0
        while i < chars.count {
            let c = chars[i]

            if style.contains(.code) {
                // Verbatim until the closing backtick: `a ** b` keeps its
                // asterisks.
                if c == "`" {
                    flush()
                    style.remove(.code)
                } else {
                    buffer.append(c)
                }
                i += 1
                continue
            }

            switch c {
            case "`":
                flush()
                style.insert(.code)
                i += 1
            case "*":
                flush()
                if i + 1 < chars.count, chars[i + 1] == "*" {
                    style.formSymmetricDifference(.bold)
                    i += 2
                } else {
                    style.formSymmetricDifference(.italic)
                    i += 1
                }
            case "_":
                flush()
                style.formSymmetricDifference(.italic)
                i += 1
            default:
                buffer.append(c)
                i += 1
            }
        }
        flush()
        return result
    }

    // MARK: Line helpers

    private static func isBlank(_ line: String) -> Bool {
        line.allSatisfy { $0 == " " || $0 == "\t" }
    }

    /// A closing fence is backticks and nothing else (an info word only
    /// belongs on the OPENING fence).
    private static func isCloseFence(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.count >= 3 && trimmed.allSatisfy { $0 == "`" }
    }
}
