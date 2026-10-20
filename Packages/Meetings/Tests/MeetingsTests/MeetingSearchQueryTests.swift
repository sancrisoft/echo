//
//  MeetingSearchQueryTests.swift
//  MeetingsTests
//
//  What a typed line becomes: folded words, quoted phrases, and the filters
//  written among them — who said it, a date by name, Trash — against a fixed
//  clock and calendar, so every date rule is a value.
//

import EchoCore
import Foundation
import Meetings
import Testing

@Suite("MeetingSearchQuery")
struct MeetingSearchQueryTests {

    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        return calendar
    }()

    /// Tuesday 20 October 2026, noon UTC.
    private var now: Date { date(2026, 10, 20, hour: 12) }

    private func date(_ year: Int, _ month: Int, _ day: Int, hour: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour)) ?? .distantPast
    }

    private func parse(_ text: String, scope: MeetingSearchScope = .all) -> MeetingSearchQuery {
        MeetingSearchQuery.parse(text, scope: scope, now: now, calendar: calendar)
    }

    // MARK: - Words

    @Test("words are folded for case and accents, and the longest is kept as typed for find")
    func wordsAreFolded() {
        let query = parse("Budget Déjà vu")
        #expect(query.terms == [.word("budget"), .word("deja"), .word("vu")])
        #expect(query.findText == "Budget")
        #expect(query.filters.isEmpty)
    }

    @Test("quotes make a phrase, and an open quote is a phrase still being typed")
    func quotesMakePhrases() {
        #expect(parse("\"budget review\"").terms == [.phrase(["budget", "review"])])
        #expect(parse("\"budget review\"").findText == "budget review")
        #expect(parse("\"budget rev").terms == [.phrase(["budget", "rev"])])
        #expect(parse("“budget review”").terms == [.phrase(["budget", "review"])])
    }

    @Test("an empty line, or only spaces, asks for nothing")
    func emptyAsksForNothing() {
        #expect(parse("").isEmpty)
        #expect(parse("   ").isEmpty)
        #expect(parse("\"\"").isEmpty)
    }

    // MARK: - Filters

    @Test("you: and others: ask for one side of the call, with or without a space after the colon")
    func speakerFilters() {
        #expect(parse("you: budget").speaker == .me)
        #expect(parse("you: budget").terms == [.word("budget")])
        #expect(parse("You:budget").speaker == .me)
        #expect(parse("You:budget").terms == [.word("budget")])
        #expect(parse("others:").speaker == .teammates)
        #expect(!parse("others:").isEmpty)
        // The last of a kind wins.
        #expect(parse("you: others:").speaker == .teammates)
        // Without its colon, "you" is a word like any other.
        #expect(parse("you").speaker == nil)
        #expect(parse("you").terms == [.word("you")])
    }

    @Test("in:trash reaches into Trash")
    func trashFilter() {
        let query = parse("in:trash budget")
        #expect(query.includesTrash)
        #expect(query.terms == [.word("budget")])
        #expect(!parse("in:trash").isEmpty)
    }

    @Test("the filters a line became are listed in the order the palette shows them")
    func filtersInOrder() {
        #expect(parse("in:trash today you:").filters.map(\.label) == ["You", "Today", "Trash"])
    }

    // MARK: - Dates

    @Test("today, yesterday, week and month are spans of whole days ending tonight")
    func relativeDates() throws {
        let today = try #require(parse("today").dates)
        #expect(today.interval == DateInterval(start: date(2026, 10, 20), end: date(2026, 10, 21)))
        #expect(today.label == "Today")

        let yesterday = try #require(parse("yesterday").dates)
        #expect(yesterday.interval == DateInterval(start: date(2026, 10, 19), end: date(2026, 10, 20)))

        let week = try #require(parse("week").dates)
        #expect(week.interval == DateInterval(start: date(2026, 10, 13), end: date(2026, 10, 21)))
        #expect(week.label == "Past week")

        let month = try #require(parse("month").dates)
        #expect(month.interval == DateInterval(start: date(2026, 9, 20), end: date(2026, 10, 21)))
        #expect(month.label == "Past month")
        #expect(parse("today").terms.isEmpty)
    }

    @Test("a month by name is the latest one that has begun")
    func monthsByName() throws {
        let october = try #require(parse("oct").dates)
        #expect(october.interval == DateInterval(start: date(2026, 10, 1), end: date(2026, 11, 1)))
        #expect(october.label == "October 2026")
        let november = try #require(parse("November").dates)
        #expect(november.interval == DateInterval(start: date(2025, 11, 1), end: date(2025, 12, 1)))
        #expect(november.label == "November 2025")
    }

    @Test("quotes take a filter word back: \"may\" is the word, may is the month")
    func quotesTakeFiltersBack() {
        #expect(parse("may").dates?.label == "May 2026")
        #expect(parse("may").terms.isEmpty)
        #expect(parse("\"may\"").dates == nil)
        #expect(parse("\"may\"").terms == [.word("may")])
        #expect(parse("\"today\"").terms == [.word("today")])
    }

    @Test("2026-10 is a month and 2026-10-14 a day; an impossible day is words")
    func isoDates() throws {
        let february = try #require(parse("2026-02").dates)
        #expect(february.interval == DateInterval(start: date(2026, 2, 1), end: date(2026, 3, 1)))
        let day = try #require(parse("2026-10-14").dates)
        #expect(day.interval == DateInterval(start: date(2026, 10, 14), end: date(2026, 10, 15)))
        #expect(day.label == "Oct 14, 2026")
        #expect(parse("2026-02-30").dates == nil)
        #expect(parse("2026-13").dates == nil)
        #expect(!parse("2026-02-30").terms.isEmpty)
    }

    @Test("a span holds its start and not its end")
    func spanBounds() throws {
        let today = try #require(parse("today").dates)
        #expect(today.contains(date(2026, 10, 20)))
        #expect(today.contains(date(2026, 10, 20, hour: 23)))
        #expect(!today.contains(date(2026, 10, 21)))
    }

    // MARK: - Scope

    @Test("Tab steps through the scopes and wraps; ⇧Tab goes back")
    func scopesCycle() {
        #expect(MeetingSearchScope.all.stepped(by: 1) == .titles)
        #expect(MeetingSearchScope.transcripts.stepped(by: 1) == .all)
        #expect(MeetingSearchScope.all.stepped(by: -1) == .transcripts)
        #expect(MeetingSearchScope.allCases.map(\.title) == ["All", "Titles", "Summaries", "Transcripts"])
        #expect(parse("budget", scope: .summaries).scope == .summaries)
    }
}
