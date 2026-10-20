//
//  MeetingSearchQuery.swift
//  Meetings
//
//  What a line typed into search asks for: the words to find, and the
//  filters written among them — `you:` and `others:` for who said it (the
//  channel, as everywhere in Echo), a date by name, `in:trash` to reach into
//  Trash — plus the scope, which is not typed but chosen. Parsing is pure and
//  takes the clock and the calendar, so every rule is testable as a value.
//
//  A filter word is a filter wherever it stands. Quotes take it back: "may"
//  in quotes is the word, `may` bare is the month. Whatever was taken as a
//  filter is listed in `filters`, so the surface can show the user what their
//  words became.
//

import EchoCore
import Foundation

/// Which kind of text a search reads.
public enum MeetingSearchScope: String, CaseIterable, Hashable, Sendable {
    case all
    /// Titles, one-line descriptions and dates: what the sidebar shows.
    case titles
    case summaries
    case transcripts

    public var title: String {
        switch self {
        case .all: return "All"
        case .titles: return "Titles"
        case .summaries: return "Summaries"
        case .transcripts: return "Transcripts"
        }
    }

    /// The scope `offset` steps on, wrapping at either end, as Tab and ⇧Tab
    /// cycle them.
    public func stepped(by offset: Int) -> MeetingSearchScope {
        let scopes = Self.allCases
        let index = scopes.firstIndex(of: self) ?? 0
        return scopes[((index + offset) % scopes.count + scopes.count) % scopes.count]
    }
}

/// A span of days a query named, and how to say it.
public struct MeetingSearchDates: Hashable, Sendable {
    /// Start included, end excluded.
    public let interval: DateInterval
    public let label: String

    public init(interval: DateInterval, label: String) {
        self.interval = interval
        self.label = label
    }

    public func contains(_ date: Date) -> Bool {
        date >= interval.start && date < interval.end
    }
}

/// A filter a query's words turned into.
public enum MeetingSearchFilter: Hashable, Sendable {
    case speaker(Speaker)
    case dates(MeetingSearchDates)
    case trash

    public var label: String {
        switch self {
        case .speaker(let speaker): return speaker.displayName
        case .dates(let dates): return dates.label
        case .trash: return "Trash"
        }
    }
}

public struct MeetingSearchQuery: Hashable, Sendable {

    /// One thing every result must contain.
    public enum Term: Hashable, Sendable {
        /// A folded word, found as the start of any word: "budg" finds
        /// "budget", as the user types it. A single letter is a whole word,
        /// or it would find nearly everything.
        case word(String)
        /// Folded words, quoted, found one after the other; the last may be
        /// the start of a word, since it is usually still being typed.
        case phrase([String])
    }

    public var terms: [Term]
    /// Only what this speaker said; `nil` for both.
    public var speaker: Speaker?
    /// Only meetings that started in this span.
    public var dates: MeetingSearchDates?
    /// Trashed meetings answer too.
    public var includesTrash: Bool
    public var scope: MeetingSearchScope
    /// The longest of the words as typed: what a transcript's find looks for
    /// once a result is opened.
    public var findText: String?

    public init(
        terms: [Term] = [],
        speaker: Speaker? = nil,
        dates: MeetingSearchDates? = nil,
        includesTrash: Bool = false,
        scope: MeetingSearchScope = .all,
        findText: String? = nil
    ) {
        self.terms = terms
        self.speaker = speaker
        self.dates = dates
        self.includesTrash = includesTrash
        self.scope = scope
        self.findText = findText
    }

    /// What the words became, in the order the surface shows them.
    public var filters: [MeetingSearchFilter] {
        var filters: [MeetingSearchFilter] = []
        if let speaker { filters.append(.speaker(speaker)) }
        if let dates { filters.append(.dates(dates)) }
        if includesTrash { filters.append(.trash) }
        return filters
    }

    /// Nothing typed asks for anything.
    public var isEmpty: Bool {
        terms.isEmpty && speaker == nil && dates == nil && !includesTrash
    }

    // MARK: - Parsing

    /// Reads a typed line. The last filter of a kind wins: `you: others:`
    /// asks for the other side.
    public static func parse(
        _ text: String,
        scope: MeetingSearchScope = .all,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> MeetingSearchQuery {
        var query = MeetingSearchQuery(scope: scope)
        var typed: [String] = []
        for piece in pieces(of: text) {
            switch piece {
            case .quoted(let phrase):
                let words = SearchText.words(in: phrase)
                guard let first = words.first else { continue }
                query.terms.append(words.count == 1 ? .word(first.token) : .phrase(words.map(\.token)))
                typed.append(phrase.trimmingCharacters(in: .whitespaces))
            case .bare(let raw):
                let folded = SearchText.fold(raw)
                var rest = Substring(raw)
                if folded == "in:trash" {
                    query.includesTrash = true
                    continue
                } else if let (speaker, prefix) = speakerPrefix(of: folded) {
                    query.speaker = speaker
                    rest = rest.dropFirst(prefix)
                } else if let dates = dates(named: folded, now: now, calendar: calendar) {
                    query.dates = dates
                    continue
                }
                let source = String(rest)
                for word in SearchText.words(in: source) {
                    query.terms.append(.word(word.token))
                    typed.append(String(source[word.range]))
                }
            }
        }
        query.findText = typed.max { $0.count < $1.count }
        return query
    }

    private enum Piece: Equatable {
        case bare(String)
        case quoted(String)
    }

    /// The line cut at spaces, except inside quotes. An open quote runs to
    /// the end: it is a phrase still being typed.
    private static func pieces(of text: String) -> [Piece] {
        var pieces: [Piece] = []
        var current = ""
        var quoted = false
        func flush() {
            if quoted {
                if !current.trimmingCharacters(in: .whitespaces).isEmpty { pieces.append(.quoted(current)) }
            } else if !current.isEmpty {
                pieces.append(.bare(current))
            }
            current = ""
        }
        for character in text {
            if character == "\"" || character == "“" || character == "”" {
                flush()
                quoted.toggle()
            } else if character.isWhitespace && !quoted {
                flush()
            } else {
                current.append(character)
            }
        }
        flush()
        return pieces
    }

    /// `you:` or `others:` at the start of a piece, and how many characters
    /// it takes; what follows the colon is still words.
    private static func speakerPrefix(of folded: String) -> (Speaker, Int)? {
        for (prefix, speaker) in [("you:", Speaker.me), ("others:", Speaker.teammates)] where folded.hasPrefix(prefix) {
            return (speaker, prefix.count)
        }
        return nil
    }

    // MARK: - Dates by name

    private static let months: [String: Int] = [
        "jan": 1, "january": 1, "feb": 2, "february": 2, "mar": 3, "march": 3, "apr": 4, "april": 4,
        "may": 5, "jun": 6, "june": 6, "jul": 7, "july": 7, "aug": 8, "august": 8, "sep": 9, "sept": 9,
        "september": 9, "oct": 10, "october": 10, "nov": 11, "november": 11, "dec": 12, "december": 12,
    ]

    /// `today`, `yesterday`, `week` (the last seven days and today, the
    /// sidebar's "Last week"), `month` (the last thirty and today), a month by
    /// name — the latest one that has begun — and `2026-10` or `2026-10-14`.
    static func dates(named word: String, now: Date, calendar: Calendar) -> MeetingSearchDates? {
        let today = calendar.startOfDay(for: now)
        func day(_ offset: Int) -> Date? { calendar.date(byAdding: .day, value: offset, to: today) }
        func span(from start: Date?, to end: Date?, _ label: String) -> MeetingSearchDates? {
            guard let start, let end, start <= end else { return nil }
            return MeetingSearchDates(interval: DateInterval(start: start, end: end), label: label)
        }
        switch word {
        case "today": return span(from: today, to: day(1), "Today")
        case "yesterday": return span(from: day(-1), to: today, "Yesterday")
        case "week": return span(from: day(-7), to: day(1), "Past week")
        case "month": return span(from: day(-30), to: day(1), "Past month")
        default: break
        }
        if let month = months[word] {
            let year = calendar.component(.year, from: now)
            let begun = month <= calendar.component(.month, from: now)
            return monthSpan(year: begun ? year : year - 1, month: month, calendar: calendar)
        }
        let parts = word.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2 || parts.count == 3, parts[0].count == 4,
            parts.allSatisfy({ !$0.isEmpty && $0.count <= 4 && $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }),
            let year = Int(parts[0]), let month = Int(parts[1]), (1...12).contains(month)
        else { return nil }
        guard parts.count == 3 else { return monthSpan(year: year, month: month, calendar: calendar) }
        guard let dayNumber = Int(parts[2]),
            let date = calendar.date(from: DateComponents(year: year, month: month, day: dayNumber)),
            calendar.component(.day, from: date) == dayNumber,
            let interval = calendar.dateInterval(of: .day, for: date)
        else { return nil }
        return MeetingSearchDates(interval: interval, label: label(date, "MMM d, yyyy", calendar))
    }

    private static func monthSpan(year: Int, month: Int, calendar: Calendar) -> MeetingSearchDates? {
        guard let first = calendar.date(from: DateComponents(year: year, month: month, day: 1)),
            let interval = calendar.dateInterval(of: .month, for: first)
        else { return nil }
        return MeetingSearchDates(interval: interval, label: label(first, "MMMM yyyy", calendar))
    }

    /// In English, as everything Echo says, whatever the Mac's language.
    private static func label(_ date: Date, _ format: String, _ calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = format
        return formatter.string(from: date)
    }
}
