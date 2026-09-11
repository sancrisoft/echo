import Foundation
import Meetings
import Testing
import Workspace

@Suite("Meeting filter and sort")
struct MeetingFilterTests {

    private func meta(_ title: String, daysAgo: Double, minutes: Double = 30, caption: String? = nil) -> MeetingMeta {
        let start = Date(timeIntervalSinceNow: -daysAgo * 86_400)
        return MeetingMeta(
            id: UUID(), title: title, startedAt: start, endedAt: start.addingTimeInterval(minutes * 60),
            segmentCount: 1, hasSummary: false, oneLineDescription: caption)
    }

    @Test("an empty search keeps everything; a title or caption match filters, case-insensitively")
    func filter() {
        let metas = [
            meta("Sprint planning", daysAgo: 0), meta("Design review", daysAgo: 1, caption: "Talked about ICONS"),
        ]
        #expect(MeetingFilter.apply(to: metas, search: "", sort: .recent).count == 2)
        #expect(MeetingFilter.apply(to: metas, search: "sprint", sort: .recent).map(\.title) == ["Sprint planning"])
        #expect(MeetingFilter.apply(to: metas, search: "icons", sort: .recent).map(\.title) == ["Design review"])
        #expect(MeetingFilter.apply(to: metas, search: "nothing", sort: .recent).isEmpty)
    }

    @Test("each sort order orders")
    func sorts() {
        let metas = [
            meta("B", daysAgo: 1, minutes: 10), meta("A", daysAgo: 0, minutes: 60), meta("C", daysAgo: 2, minutes: 30),
        ]
        #expect(MeetingFilter.apply(to: metas, search: "", sort: .recent).map(\.title) == ["A", "B", "C"])
        #expect(MeetingFilter.apply(to: metas, search: "", sort: .oldest).map(\.title) == ["C", "B", "A"])
        #expect(MeetingFilter.apply(to: metas, search: "", sort: .name).map(\.title) == ["A", "B", "C"])
        #expect(MeetingFilter.apply(to: metas, search: "", sort: .longest).map(\.title) == ["A", "C", "B"])
    }
}

@Suite("Meeting date groups")
struct MeetingDateGroupTests {

    private let calendar = Calendar(identifier: .gregorian)
    private let now = Date(timeIntervalSince1970: 1_756_900_000)  // 2026-09-03, mid-day

    private func meta(_ title: String, daysAgo: Int) -> MeetingMeta {
        let start = calendar.date(byAdding: .day, value: -daysAgo, to: now) ?? now
        return MeetingMeta(
            id: UUID(), title: title, startedAt: start, endedAt: start.addingTimeInterval(1800), segmentCount: 1,
            hasSummary: true)
    }

    @Test("the four groups the design draws, in list order, and never a fifth")
    func buckets() {
        let metas = [
            meta("today", daysAgo: 0), meta("yesterday", daysAgo: 1), meta("recent", daysAgo: 4),
            meta("last month", daysAgo: 40), meta("older", daysAgo: 90),
        ]
        let groups = MeetingDateGroup.groups(for: metas, sort: .recent, now: now, calendar: calendar)
        #expect(groups.map(\.title) == ["Today", "Yesterday", "Last week", "Earlier"])
        #expect(groups[3].meetings.map(\.title) == ["last month", "older"], "everything old is one group")
    }

    @Test("a week-old meeting is in the week, an eight-day-old one is earlier")
    func theEdgeOfTheWeek() {
        let groups = MeetingDateGroup.groups(
            for: [meta("seven", daysAgo: 7), meta("eight", daysAgo: 8)], sort: .recent, now: now, calendar: calendar)
        #expect(groups.map(\.title) == ["Last week", "Earlier"])
    }

    @Test("meetings in one bucket keep their list order")
    func orderInsideBucket() {
        let metas = [meta("second", daysAgo: 3), meta("first", daysAgo: 5)]
        let groups = MeetingDateGroup.groups(for: metas, sort: .recent, now: now, calendar: calendar)
        #expect(groups.count == 1)
        #expect(groups[0].meetings.map(\.title) == ["second", "first"])
    }

    @Test("non-chronological sorts yield one untitled group; an empty list yields none")
    func flatGroups() {
        let metas = [meta("a", daysAgo: 0), meta("b", daysAgo: 40)]
        let groups = MeetingDateGroup.groups(for: metas, sort: .name, now: now, calendar: calendar)
        #expect(groups.count == 1)
        #expect(groups[0].title.isEmpty)
        #expect(MeetingDateGroup.groups(for: [], sort: .recent, now: now, calendar: calendar).isEmpty)
    }
}

@Suite("Meeting status")
struct MeetingStatusTests {

    private func meta(segments: Int, summary: Bool, source: TranscriptProvenance.Source?) -> MeetingMeta {
        MeetingMeta(
            id: UUID(), title: "m", startedAt: .now, endedAt: .now, segmentCount: segments, hasSummary: summary,
            transcriptProvenance: source.map { TranscriptProvenance(source: $0, modelName: "test") })
    }

    @Test("provenance decides first; without it, the transcript and summary bits do")
    func resolve() {
        #expect(MeetingStatus.resolve(meta(segments: 0, summary: false, source: .terminalFailure)) == .failed)
        #expect(MeetingStatus.resolve(meta(segments: 5, summary: false, source: .liveFloor)) == .draft)
        #expect(MeetingStatus.resolve(meta(segments: 5, summary: true, source: .finalPass)) == .summarized)
        #expect(MeetingStatus.resolve(meta(segments: 5, summary: false, source: .finalPass)) == .transcribed)
        #expect(MeetingStatus.resolve(meta(segments: 0, summary: false, source: nil)) == .pending)
        #expect(MeetingStatus.resolve(meta(segments: 3, summary: false, source: nil)) == .transcribed)
        #expect(MeetingStatus.resolve(meta(segments: 3, summary: true, source: nil)) == .summarized)
    }

    @Test("the row's mark says draft until the summary lands, and never calls a failure one")
    func rowMarks() {
        #expect(MeetingStatus.summarized.rowMark == nil)
        #expect(MeetingStatus.transcribed.rowMark == .draft)
        #expect(MeetingStatus.pending.rowMark == .draft)
        #expect(MeetingStatus.draft.rowMark == .draft)
        #expect(MeetingStatus.failed.rowMark == .failed)
    }

    @Test("the transcript is readable only when there are words")
    func readability() {
        #expect(MeetingStatus.summarized.isTranscriptReadable)
        #expect(MeetingStatus.transcribed.isTranscriptReadable)
        #expect(MeetingStatus.draft.isTranscriptReadable)
        #expect(!MeetingStatus.failed.isTranscriptReadable)
        #expect(!MeetingStatus.pending.isTranscriptReadable)
    }
}

@Suite("WorkspaceModel selection rules")
struct WorkspaceModelTests {

    private func metas(_ count: Int) -> [MeetingMeta] {
        (0..<count).map { index in
            MeetingMeta(
                id: UUID(), title: "Meeting \(index)", startedAt: Date(timeIntervalSinceNow: -Double(index) * 3600),
                endedAt: Date(timeIntervalSinceNow: -Double(index) * 3600 + 600), segmentCount: 1, hasSummary: true)
        }
    }

    @Test("arrows move through the visible order and stop at the ends")
    func arrows() {
        let model = WorkspaceModel()
        let list = metas(3)
        #expect(model.moveSelection(.down, in: list))
        #expect(model.selectedMeetingID == list[0].id)
        #expect(model.moveSelection(.down, in: list))
        #expect(model.selectedMeetingID == list[1].id)
        #expect(model.moveSelection(.last, in: list))
        #expect(model.selectedMeetingID == list[2].id)
        #expect(model.moveSelection(.down, in: list))
        #expect(model.selectedMeetingID == list[2].id)
        #expect(!model.moveSelection(.down, in: []))
    }

    @Test("the search filters what the arrows walk, but a filtered-away selection survives while the meeting exists")
    func searchAndSelection() {
        let model = WorkspaceModel()
        let list = metas(3)
        model.open(list[2].id)
        model.searchText = "Meeting 0"
        #expect(model.visibleMeetings(in: list).map(\.id) == [list[0].id])
        model.reconcileSelection(with: list)
        #expect(model.selectedMeetingID == list[2].id)
        model.reconcileSelection(with: Array(list.prefix(2)))
        #expect(model.selectedMeetingID == nil)
    }

    @Test("trashing the selected row hands the selection to the row that slides up")
    func afterRemoving() {
        let model = WorkspaceModel()
        let list = metas(3)
        model.open(list[1].id)
        model.selectionAfterRemoving(list[1].id, in: list)
        #expect(model.selectedMeetingID == list[2].id)
        model.selectionAfterRemoving(list[0].id, in: list)
        #expect(model.selectedMeetingID == list[2].id, "an unselected removal changes nothing")
    }

    @Test("opening a meeting shows the library and can pick the tab")
    func open() {
        let model = WorkspaceModel()
        model.section = .settings
        let list = metas(1)
        model.open(list[0].id, tab: .transcript)
        #expect(model.section == .meetings)
        #expect(model.selectedMeetingID == list[0].id)
        #expect(model.documentTab == .transcript)
    }

    @Test("an empty library never reads as 'no results'")
    func emptyLibraryVersusSearch() {
        let model = WorkspaceModel()
        model.searchText = "x"
        #expect(!model.searchHidesEverything(in: []))
        #expect(model.searchHidesEverything(in: metas(2)))
    }
}
