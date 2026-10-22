//
//  SummaryText.swift
//  Summarization
//
//  Cleaning up what the model wrote. Three pure transforms, all table-tested:
//  the one sanitation the Markdown routes apply, and the two steps that turn a
//  finished document into a one-line row caption.
//

import Foundation

enum SummaryText {

    // MARK: - Markdown sanitation

    /// The single cleanup applied to raw Markdown output: trim, and unwrap ONE
    /// outer code fence.
    ///
    /// A small model's favourite way to disobey "no code fences" is to wrap the
    /// whole document in ``` or ```markdown. Only a true wrapper is unwrapped —
    /// the first line opens a fence AND the last line closes one — so a document
    /// that merely starts with a code block keeps its fences.
    ///
    /// Prefix-monotonic by construction, which matters because it runs on every
    /// delta: a partial document whose opening fence has no closing line yet is
    /// left alone, and the wrapper disappears the moment its closing line
    /// arrives. Anything subtler — stray HTML, broken tables — is the renderer's
    /// problem, not sanitation's.
    static func sanitizedMarkdown(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.hasPrefix("```") else { return text }

        var lines = text.components(separatedBy: "\n")
        guard lines.count >= 2,
            lines.last?.trimmingCharacters(in: .whitespaces) == "```"
        else { return text }

        lines.removeFirst()
        lines.removeLast()
        text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return text
    }

    // MARK: - Caption

    /// Characters of stripped prose the caption model is shown.
    static let captionSourceBudget = 1_200

    /// Longest caption kept; past this it is truncated with an ellipsis.
    static let captionLimit = 160

    /// The head of a Markdown document, stripped to prose for caption
    /// generation.
    ///
    /// The caption model reads the opening of the notes; fed raw Markdown it
    /// parrots the markup ("### Action Items - [ ] ..."). So heading markers,
    /// checkbox and bullet prefixes and emphasis delimiters come off, and lines
    /// carrying no prose at all — table rows, horizontal rules — are dropped
    /// whole. Stripping happens BEFORE the cap so the budget buys prose, not
    /// asterisks.
    static func captionSource(from markdown: String) -> String {
        let lines = markdown.components(separatedBy: "\n").compactMap { rawLine -> String? in
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { return nil }

            // Table rows (separator rows included) and horizontal rules carry no
            // prose — drop the whole line.
            if line.hasPrefix("|") { return nil }
            if line.count >= 3, line.allSatisfy({ $0 == "-" || $0 == "*" || $0 == "_" }) { return nil }

            // Heading markers, then the checkbox prefix (it embeds a bullet, so
            // it goes first), then plain bullet prefixes.
            while line.hasPrefix("#") { line.removeFirst() }
            line = line.trimmingCharacters(in: .whitespaces)
            for prefix in ["- [ ] ", "- [x] ", "- [X] "] where line.hasPrefix(prefix) {
                line.removeFirst(prefix.count)
            }
            for prefix in ["- ", "* ", "+ "] where line.hasPrefix(prefix) {
                line.removeFirst(prefix.count)
            }

            // Inline delimiters: bold before italic, so "**" never survives as
            // two orphaned "*" strips.
            line = line.replacingOccurrences(of: "**", with: "")
            line = line.replacingOccurrences(of: "*", with: "")
            line = line.replacingOccurrences(of: "`", with: "")

            line = line.trimmingCharacters(in: .whitespaces)
            return line.isEmpty ? nil : line
        }
        return String(lines.joined(separator: "\n").prefix(captionSourceBudget))
    }

    /// First sentence, unwrapped from any quotes or label the model prepends,
    /// trimmed and length-capped. Nil when nothing survives — a row with no
    /// caption is correct, an invented one is not.
    static func cleanCaption(_ raw: String) -> String? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = text.range(of: "sentence:", options: .caseInsensitive) {
            text = String(text[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let newline = text.firstIndex(where: \.isNewline) {
            text = String(text[..<newline])
        }
        if let end = text.firstIndex(where: { $0 == "." || $0 == "!" || $0 == "?" }) {
            text = String(text[...end])
        }
        text = text.trimmingCharacters(in: CharacterSet(charactersIn: " \t\"'“”‘’"))
        guard !text.isEmpty else { return nil }
        if text.count > captionLimit {
            text = String(text.prefix(captionLimit - 3)).trimmingCharacters(in: .whitespaces) + "…"
        }
        return text
    }
}
