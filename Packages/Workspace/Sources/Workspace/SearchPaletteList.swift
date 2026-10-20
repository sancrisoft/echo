//
//  SearchPaletteList.swift
//  Workspace
//
//  What the ⌘K palette lists and how the keyboard walks it, as values: the
//  meetings a search found — the first fifty drawn, every one counted — then
//  the actions; the row the keyboard is on, held at either end as Spotlight's
//  lists are; which results ⌘1–⌘9 open; whether each action can run; and the
//  words the palette says around them. The view draws this and decides
//  nothing.
//

import Foundation
import Meetings

/// One of the palette's actions, as `Search.dc.html` lists them.
enum PaletteAction: Hashable, CaseIterable, Sendable {
    case startRecording
    case openSettings
    case openTrash

    var title: String {
        switch self {
        case .startRecording: return "Start recording"
        case .openSettings: return "Open settings"
        case .openTrash: return "Open Trash"
        }
    }

    /// The shortcut the artboard draws beside it, which works from anywhere
    /// in the window.
    var shortcut: String? {
        switch self {
        case .startRecording: return "⌘R"
        case .openSettings: return "⌘,"
        case .openTrash: return nil
        }
    }

    enum State: Equatable, Sendable {
        case available
        /// Held back, with the title bar's reason when it gives one.
        case heldBack(reason: String?)
    }

    /// Start recording is held back exactly when the title bar's New
    /// recording is, and says why in the same words.
    func state(titleBar: TitleBarState) -> State {
        guard self == .startRecording else { return .available }
        switch titleBar {
        case .newRecording: return .available
        case .waiting(let reason): return .heldBack(reason: reason)
        case .recording, .stopping: return .heldBack(reason: nil)
        }
    }
}

struct SearchPaletteList: Equatable {

    enum Item: Equatable {
        case meeting(MeetingSearchHit)
        case action(PaletteAction)
    }

    /// The most results the palette draws: a palette, not a report. The
    /// group's count stays the true one.
    static let drawnResults = 50

    /// The results drawn, best first.
    let hits: [MeetingSearchHit]
    /// How many meetings the search found.
    let total: Int
    let items: [Item]

    init(hits: [MeetingSearchHit]) {
        self.hits = Array(hits.prefix(Self.drawnResults))
        total = hits.count
        items = self.hits.map(Item.meeting) + PaletteAction.allCases.map(Item.action)
    }

    func item(at index: Int) -> Item? {
        items.indices.contains(index) ? items[index] : nil
    }

    /// Where ↑ or ↓ goes from `index`: held at the first and the last row.
    func moved(from index: Int, by offset: Int) -> Int {
        clamped(index + offset)
    }

    /// A row that is still in the list, for when the list has changed under
    /// the keyboard.
    func clamped(_ index: Int) -> Int {
        min(max(index, 0), max(items.count - 1, 0))
    }

    /// The row ⌘`number` opens: the first nine results, and nothing else.
    func indexOfResult(number: Int) -> Int? {
        (1...9).contains(number) && number <= hits.count ? number - 1 : nil
    }

    /// The number a result answers to while ⌘ is held.
    func shortcutNumber(forResultAt index: Int) -> Int? {
        index < 9 && index < hits.count ? index + 1 : nil
    }
}

/// What the palette says.
enum SearchPaletteText {

    /// The artboard's own promise of what search reads, from its Search row.
    static let placeholder = "Search meetings, transcripts and summaries"

    /// The scope line at the foot (product owner, 2026-10-20).
    static let scope = "Titles, summaries and transcripts"

    /// While the meetings are still being read, the scope line says so: a
    /// search answered meanwhile is not yet the whole answer.
    static let reading = "Reading transcripts…"

    static func noMatchTitle(_ typed: String) -> String {
        "No meeting matches “\(typed)”"
    }

    /// Product owner, 2026-10-20: the empty state says what search reads.
    static let noMatchMessage = "Search reads titles, one-line descriptions, summaries and transcripts."

    /// The foot's right side: what search reads, that it is still reading,
    /// or — right after ⌘C — that the summary was copied, in the document's
    /// Copy's own word.
    static func scopeLine(isReading: Bool, copied: Bool) -> String {
        if copied { return "Copied" }
        return isReading ? reading : scope
    }

    /// A result's day, as the artboard writes it: "Aug 27", with the year
    /// only when it is not this one.
    static func day(_ date: Date, now: Date = .now, calendar: Calendar = .current) -> String {
        calendar.isDate(date, equalTo: now, toGranularity: .year)
            ? date.formatted(.dateTime.month(.abbreviated).day())
            : date.formatted(.dateTime.month(.abbreviated).day().year())
    }
}
