//
//  SearchPaletteList.swift
//  Workspace
//
//  What the ⌘K palette lists and how the keyboard walks it, as values: the
//  recent searches while nothing is typed, the meetings a search found — the
//  first fifty drawn, every one counted — then the actions; the row the
//  keyboard is on, held at either end as Spotlight's lists are; which results
//  ⌘1–⌘9 open; whether each action can run; what a row's actions panel (⌘K,
//  as Raycast has it) offers; and the words the palette says around them.
//  The view draws this and decides nothing.
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
        /// A search the user acted on before, offered while nothing is typed.
        case recent(String)
        case meeting(MeetingSearchHit)
        case action(PaletteAction)
    }

    /// The most results the palette draws: a palette, not a report. The
    /// group's count stays the true one.
    static let drawnResults = 50

    let recents: [String]
    /// The results drawn, best first.
    let hits: [MeetingSearchHit]
    /// How many meetings the search found.
    let total: Int
    let items: [Item]

    init(recents: [String] = [], hits: [MeetingSearchHit]) {
        self.recents = recents
        self.hits = Array(hits.prefix(Self.drawnResults))
        total = hits.count
        items = recents.map(Item.recent) + self.hits.map(Item.meeting) + PaletteAction.allCases.map(Item.action)
    }

    /// Where the `position`th result sits among the rows.
    func indexOfResult(at position: Int) -> Int {
        recents.count + position
    }

    /// Where the `position`th action sits among the rows.
    func indexOfAction(at position: Int) -> Int {
        recents.count + hits.count + position
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
        (1...9).contains(number) && number <= hits.count ? indexOfResult(at: number - 1) : nil
    }

    /// The number the row at `index` answers to while ⌘ is held: one of the
    /// first nine results', or none.
    func shortcutNumber(forRowAt index: Int) -> Int? {
        let position = index - recents.count
        return position >= 0 && position < 9 && position < hits.count ? position + 1 : nil
    }
}

/// What a row's actions panel offers (⌘K, as Raycast has it). For a meeting,
/// what its sidebar row's menu offers — open either tab, copy the summary,
/// rename, export, reveal — or, for one in Trash, open it, restore it, reveal
/// it; for a recent search, search again or take it off the list. The
/// actions the palette lists itself have no panel.
enum PaletteItemAction: Hashable, Sendable {
    case open(WorkspaceModel.DocumentTab)
    case copySummary
    case rename
    case export(MeetingExportFormat)
    case revealInFinder
    case restore
    case searchAgain
    case forgetSearch
    case clearRecentSearches

    static func actions(for item: SearchPaletteList.Item) -> [PaletteItemAction] {
        switch item {
        case .meeting(let hit):
            let primary = primaryTab(of: hit)
            let opens: [PaletteItemAction] = [.open(primary), .open(primary == .summary ? .transcript : .summary)]
            if hit.meta.isTrashed { return opens + [.restore, .revealInFinder] }
            let copy: [PaletteItemAction] = hit.meta.hasSummary ? [.copySummary] : []
            return opens + copy + [.rename] + MeetingExportFormat.allCases.map(PaletteItemAction.export)
                + [.revealInFinder]
        case .recent:
            return [.searchAgain, .forgetSearch, .clearRecentSearches]
        case .action:
            return []
        }
    }

    /// Where Return opens a result: where its line is.
    static func primaryTab(of hit: MeetingSearchHit) -> WorkspaceModel.DocumentTab {
        hit.foundInTranscript ? .transcript : .summary
    }

    var title: String {
        switch self {
        case .open(let tab): return "Open \(tab.title)"
        case .copySummary: return "Copy Summary as Markdown"
        case .rename: return "Rename"
        case .export(let format): return "Export as \(format.menuTitle)"
        case .revealInFinder: return "Reveal in Finder"
        case .restore: return "Restore"
        case .searchAgain: return "Search Again"
        case .forgetSearch: return "Remove from Recent Searches"
        case .clearRecentSearches: return "Clear Recent Searches"
        }
    }

    /// The key that does the same from the list, shown beside it.
    func shortcut(for item: SearchPaletteList.Item) -> String? {
        switch (self, item) {
        case (.open(let tab), .meeting(let hit)): return tab == Self.primaryTab(of: hit) ? "↵" : "⌘↵"
        case (.copySummary, _): return "⌘C"
        case (.searchAgain, _): return "↵"
        default: return nil
        }
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
