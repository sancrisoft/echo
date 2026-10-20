import Foundation
import Meetings
import Recording
import Testing

@testable import Workspace

@Suite("Trash")
@MainActor
struct TrashTests {

    private let now = Date(timeIntervalSince1970: 1_790_000_000)
    private let day: TimeInterval = 86_400

    private func meta(title: String = "Design sync", hasSummary: Bool = true, words: Int? = 4806) -> MeetingMeta {
        let start = Date(timeIntervalSince1970: 1_787_824_000)
        return MeetingMeta(
            id: UUID(), title: title, startedAt: start, endedAt: start.addingTimeInterval(52 * 60), segmentCount: 9,
            hasSummary: hasSummary, wordCount: words, trashedAt: now)
    }

    // MARK: Days left

    @Test("a meeting counts down the thirty days, a part of a day counting as a day")
    func daysLeft() {
        #expect(TrashRow.daysLeft(trashedAt: now, now: now) == 30)
        #expect(TrashRow.daysLeft(trashedAt: now - 2 * day, now: now) == 28)
        #expect(TrashRow.daysLeft(trashedAt: now - 29.5 * day, now: now) == 1)
        #expect(TrashRow.daysLeft(trashedAt: now - 31 * day, now: now) == 0)
    }

    @Test("the last three days are the red ones")
    func expiring() {
        #expect(TrashRow.isExpiring(3))
        #expect(TrashRow.isExpiring(1))
        #expect(!TrashRow.isExpiring(4))
    }

    @Test("one day is a day, the rest are days")
    func daysText() {
        #expect(TrashRow.daysLeftText(1) == "1 day left")
        #expect(TrashRow.daysLeftText(28) == "28 days left")
    }

    // MARK: The caption

    @Test("a row says its words, or that it has no summary")
    func caption() {
        #expect(TrashRow.caption(meta()).detail == .words(4806))
        #expect(TrashRow.caption(meta(hasSummary: false)).detail == .noSummary)
        #expect(TrashRow.caption(meta(words: nil)).detail == nil)
        #expect(TrashRow.caption(meta()).duration == "52 min")
    }

    // MARK: Opening from Trash

    @Test("Return opens a trashed meeting's document, and back is the same row")
    func openAndClose() {
        let trashed = meta()
        let workspace = WorkspaceModel()
        workspace.openTrashed(trashed.id)
        #expect(workspace.section == .trash)
        #expect(detail(workspace, trashed: [trashed]) == .trashedMeeting(trashed))
        workspace.closeTrashed()
        #expect(detail(workspace, trashed: [trashed]) == .trash)
        #expect(workspace.selectedTrashedID == trashed.id)
    }

    @Test("a meeting restored or deleted while open gives the pane back to the list")
    func goneWhileOpen() {
        let trashed = meta()
        let workspace = WorkspaceModel()
        workspace.openTrashed(trashed.id)
        #expect(detail(workspace, trashed: []) == .trash)
        workspace.reconcileTrashSelection(with: [])
        #expect(workspace.openedTrashedID == nil)
        #expect(workspace.selectedTrashedID == nil)
    }

    @Test("going to Trash from the sidebar shows the list, whatever was open in it")
    func showTrash() {
        let trashed = meta()
        let workspace = WorkspaceModel()
        workspace.openTrashed(trashed.id)
        workspace.section = .meetings
        workspace.showTrash()
        #expect(detail(workspace, trashed: [trashed]) == .trash)
    }

    @Test("the arrows move the trash selection and hold at the ends, as the library's do")
    func arrows() {
        let first = meta(title: "First")
        let second = meta(title: "Second")
        let workspace = WorkspaceModel()
        workspace.moveTrashSelection(.down, in: [first, second])
        #expect(workspace.selectedTrashedID == first.id)
        workspace.moveTrashSelection(.down, in: [first, second])
        #expect(workspace.selectedTrashedID == second.id)
        workspace.moveTrashSelection(.down, in: [first, second])
        #expect(workspace.selectedTrashedID == second.id)
        // An empty Trash has nowhere to go, and the key falls through.
        let moved = workspace.moveTrashSelection(.down, in: [])
        #expect(!moved)
    }

    private func detail(_ workspace: WorkspaceModel, trashed: [MeetingMeta]) -> WorkspaceDetail {
        WorkspaceDetail.resolve(
            section: workspace.section, selection: nil, hasMeetings: true, meta: { _ in nil }, phase: .idle,
            openedTrashedID: workspace.openedTrashedID,
            trashedMeta: { id in trashed.first { $0.id == id } })
    }
}
