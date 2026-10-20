//
//  SearchPaletteTests.swift
//  WorkspaceTests
//
//  The ⌘K palette as values: what each key means, how the keyboard walks the
//  list and which rows ⌘1–⌘9 reach, when Start recording is held back, what
//  the palette says, and where a result opens — the tab its line is on, the
//  turn find lands on, Trash for a trashed meeting.
//

import AppKit
import EchoCore
import Foundation
import Meetings
import Recording
import Testing

@testable import Workspace

@Suite("The ⌘K palette")
struct SearchPaletteTests {

    private let base = Date(timeIntervalSince1970: 1_756_900_000)

    private func hit(
        _ title: String = "Weekly", transcriptTurn turn: UUID? = nil, trashed: Bool = false, hasSummary: Bool = true
    ) -> MeetingSearchHit {
        let meta = MeetingMeta(
            id: UUID(), title: title, startedAt: base, endedAt: base.addingTimeInterval(600), segmentCount: 1,
            hasSummary: hasSummary, trashedAt: trashed ? base : nil)
        let snippet = MeetingSearchSnippet(text: "the budget", highlights: [])
        let line: MeetingSearchHit.Line =
            if let turn {
                .transcript(snippet, turn: turn, speaker: .me, start: 64)
            } else {
                .summary(snippet)
            }
        return MeetingSearchHit(meta: meta, titleHighlights: [], line: line)
    }

    // MARK: - Keys

    @Test("the arrows, Return, Tab, Esc, ⌘1–⌘9 and ⌘C are the palette's; every other key is the field's")
    func keys() {
        func key(_ code: UInt16, _ characters: String? = nil, _ modifiers: NSEvent.ModifierFlags = []) -> PaletteKey? {
            PaletteKey.classify(keyCode: code, characters: characters, modifiers: modifiers)
        }
        // The arrows carry their own function and keypad flags.
        #expect(key(126, nil, [.function, .numericPad]) == .move(-1))
        #expect(key(125, nil, [.function, .numericPad]) == .move(1))
        #expect(key(126, nil, [.shift]) == nil)
        #expect(key(36) == .open(otherTab: false))
        #expect(key(76) == .open(otherTab: false))
        #expect(key(36, nil, .command) == .open(otherTab: true))
        #expect(key(36, nil, .option) == nil)
        #expect(key(48) == .stepScope(1))
        #expect(key(48, nil, .shift) == .stepScope(-1))
        #expect(key(53) == .escape)
        #expect(key(18, "1", .command) == .openResult(number: 1))
        #expect(key(25, "9", .command) == .openResult(number: 9))
        #expect(key(29, "0", .command) == nil)
        #expect(key(8, "c", .command) == .copySummary)
        #expect(key(8, "C", [.command, .shift]) == nil)
        // Typing, and the field's own shortcuts, go through.
        #expect(key(0, "a") == nil)
        #expect(key(0, "a", .command) == nil)
        #expect(key(9, "v", .command) == nil)
        #expect(key(18, "1") == nil)
    }

    // MARK: - The list

    @Test("the results come first and the actions after; the keyboard stops at either end")
    func walking() {
        let list = SearchPaletteList(hits: [hit("A"), hit("B")])
        #expect(list.items.count == 2 + PaletteAction.allCases.count)
        #expect(list.item(at: 2) == .action(.startRecording))
        #expect(list.moved(from: 0, by: -1) == 0)
        #expect(list.moved(from: 0, by: 1) == 1)
        #expect(list.moved(from: list.items.count - 1, by: 1) == list.items.count - 1)
        #expect(list.clamped(40) == list.items.count - 1)
        #expect(SearchPaletteList(hits: []).items == PaletteAction.allCases.map(SearchPaletteList.Item.action))
    }

    @Test("⌘1–⌘9 reach the first nine results and nothing past them")
    func numberedResults() {
        let list = SearchPaletteList(hits: (0..<12).map { hit("Meeting \($0)") })
        #expect(list.indexOfResult(number: 1) == 0)
        #expect(list.indexOfResult(number: 9) == 8)
        #expect(list.shortcutNumber(forResultAt: 8) == 9)
        #expect(list.shortcutNumber(forResultAt: 9) == nil)
        let short = SearchPaletteList(hits: [hit()])
        #expect(short.indexOfResult(number: 2) == nil)
        #expect(short.shortcutNumber(forResultAt: 1) == nil, "an action has no number")
    }

    @Test("fifty results are drawn, and the count stays the true one")
    func drawnResults() {
        let list = SearchPaletteList(hits: (0..<70).map { hit("Meeting \($0)") })
        #expect(list.hits.count == SearchPaletteList.drawnResults)
        #expect(list.total == 70)
    }

    @Test("Start recording is held back when the title bar's New recording is, with its reason")
    func startRecordingState() {
        #expect(PaletteAction.startRecording.state(titleBar: .newRecording) == .available)
        #expect(
            PaletteAction.startRecording.state(titleBar: .waiting("Transcription · Downloading"))
                == .heldBack(reason: "Transcription · Downloading"))
        #expect(PaletteAction.startRecording.state(titleBar: .recording(startedAt: base)) == .heldBack(reason: nil))
        #expect(PaletteAction.startRecording.state(titleBar: .stopping) == .heldBack(reason: nil))
        #expect(PaletteAction.openTrash.state(titleBar: .stopping) == .available)
        #expect(PaletteAction.allCases.map(\.shortcut) == ["⌘R", "⌘,", nil])
    }

    // MARK: - What it says

    @Test("the foot says what search reads, that it is still reading, or that the summary was copied")
    func scopeLine() {
        #expect(SearchPaletteText.scopeLine(isReading: false, copied: false) == "Titles, summaries and transcripts")
        #expect(SearchPaletteText.scopeLine(isReading: true, copied: false) == "Reading transcripts…")
        #expect(SearchPaletteText.scopeLine(isReading: true, copied: true) == "Copied")
        #expect(SearchPaletteText.noMatchTitle("budget") == "No meeting matches “budget”")
    }

    @Test("a result's day carries its year only when it is not this year's")
    func days() {
        let calendar = Calendar(identifier: .gregorian)
        let now = base
        let sameYear = SearchPaletteText.day(base.addingTimeInterval(-86_400), now: now, calendar: calendar)
        let lastYear = SearchPaletteText.day(base.addingTimeInterval(-400 * 86_400), now: now, calendar: calendar)
        let year = String(calendar.component(.year, from: base.addingTimeInterval(-400 * 86_400)))
        #expect(!sameYear.contains(String(calendar.component(.year, from: base))))
        #expect(lastYear.contains(year))
    }

    // MARK: - Where a result opens

    @Test("a turn opens the transcript with find on its words, landing on that turn; the palette goes")
    func opensTheTranscript() throws {
        let model = WorkspaceModel()
        model.presentSearch()
        let turn = UUID()
        let found = hit(transcriptTurn: turn)
        model.open(found, findText: "budget")
        #expect(model.section == .meetings)
        #expect(model.selectedMeetingID == found.id)
        #expect(model.documentTab == .transcript)
        #expect(!model.isSearchPresented)
        #expect(model.takeFindRequest(for: UUID()) == nil, "a request waits for its own meeting")
        let request = try #require(model.takeFindRequest(for: found.id))
        #expect(request == TranscriptFindRequest(meetingID: found.id, text: "budget", turn: turn))
        #expect(model.takeFindRequest(for: found.id) == nil, "a request is taken once")
    }

    @Test("⌘↵ opens the other tab: a turn's meeting on its summary, a summary's on its transcript at the first match")
    func opensTheOtherTab() {
        let model = WorkspaceModel()
        let fromTurn = hit(transcriptTurn: UUID())
        model.open(fromTurn, otherTab: true, findText: "budget")
        #expect(model.documentTab == .summary)
        #expect(model.findRequest == nil)

        let fromSummary = hit()
        model.open(fromSummary, otherTab: true, findText: "budget")
        #expect(model.documentTab == .transcript)
        #expect(model.findRequest == TranscriptFindRequest(meetingID: fromSummary.id, text: "budget", turn: nil))

        model.open(fromSummary, findText: "budget")
        #expect(model.documentTab == .summary)
        #expect(model.findRequest == nil, "the summary has no find to open")
    }

    @Test("a trashed meeting opens under Trash, as Trash opens it")
    func opensUnderTrash() {
        let model = WorkspaceModel()
        let trashed = hit(transcriptTurn: UUID(), trashed: true)
        model.open(trashed, findText: "budget")
        #expect(model.section == .trash)
        #expect(model.openedTrashedID == trashed.id)
        #expect(model.documentTab == .transcript)
    }

    @Test("⌘K brings the palette up and puts it away; what was typed stays for next time")
    func toggling() {
        let model = WorkspaceModel()
        model.toggleSearch()
        #expect(model.isSearchPresented)
        model.searchText = "budget"
        model.searchScope = .transcripts
        model.toggleSearch()
        #expect(!model.isSearchPresented)
        #expect(model.searchText == "budget")
        #expect(model.searchScope == .transcripts)
    }
}
