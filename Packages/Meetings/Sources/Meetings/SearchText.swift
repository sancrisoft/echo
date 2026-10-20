//
//  SearchText.swift
//  Meetings
//
//  How search reads words. One fold — case, accents and width — and one word
//  boundary, the system's, for every field and for the query alike, so what is
//  typed and what it is matched against are cut and folded the same way.
//

import Foundation

enum SearchText {

    /// Lowercased, with accents and width dropped: to search, as to macOS's
    /// own find, "Déjà" and "deja" are one word.
    static func fold(_ text: some StringProtocol) -> String {
        String(text).folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }

    /// Every word in `text`, folded, with where it sits in `text`. The
    /// system's word boundaries, not the user's locale's, so an index built on
    /// one Mac cuts words as a query typed on any other does.
    static func words(in text: String) -> [(token: String, range: Range<String.Index>)] {
        var found: [(token: String, range: Range<String.Index>)] = []
        text.enumerateSubstrings(in: text.startIndex..<text.endIndex, options: .byWords) { word, range, _, _ in
            guard let word else { return }
            found.append((fold(word), range))
        }
        return found
    }

    /// The prose of a summary's Markdown, one entry per line that has any:
    /// heading markers, checkbox and bullet prefixes and emphasis delimiters
    /// come off, and lines with no prose — table rows, rules — are dropped.
    /// What a result shows of a summary is a line of it, read as words.
    static func summaryLines(_ markdown: String) -> [String] {
        markdown.components(separatedBy: .newlines).compactMap { rawLine -> String? in
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { return nil }
            if line.hasPrefix("|") { return nil }
            if line.count >= 3, line.allSatisfy({ $0 == "-" || $0 == "*" || $0 == "_" }) { return nil }
            while line.hasPrefix("#") { line.removeFirst() }
            line = line.trimmingCharacters(in: .whitespaces)
            // The checkbox embeds a bullet, so it goes before the bullets.
            for prefix in ["- [ ] ", "- [x] ", "- [X] "] where line.hasPrefix(prefix) {
                line.removeFirst(prefix.count)
            }
            for prefix in ["- ", "* ", "+ ", "> "] where line.hasPrefix(prefix) {
                line.removeFirst(prefix.count)
            }
            // Bold before italic, so "**" never survives as two orphaned "*".
            line = line.replacingOccurrences(of: "**", with: "")
            line = line.replacingOccurrences(of: "*", with: "")
            line = line.replacingOccurrences(of: "`", with: "")
            line = line.trimmingCharacters(in: .whitespaces)
            return line.isEmpty ? nil : line
        }
    }
}
