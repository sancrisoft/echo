import Foundation
import Meetings
import Testing

@testable import Workspace

@Suite("What the document pane shows")
struct WorkspaceDetailTests {

    private let first = MeetingMeta(
        id: UUID(), title: "GoCoInvest onboarding", startedAt: .now, endedAt: .now, segmentCount: 3, hasSummary: true)
    private let second = MeetingMeta(
        id: UUID(), title: "Quarterly roadmap", startedAt: .now, endedAt: .now, segmentCount: 3, hasSummary: true)

    /// The library's answer to "which meeting is this id", over a given list.
    private func lookup(_ metas: [MeetingMeta]) -> (UUID) -> MeetingMeta? {
        { id in metas.first { $0.id == id } }
    }

    private func detail(
        _ section: WorkspaceModel.Section, selection: UUID?, library: [MeetingMeta]
    ) -> WorkspaceDetail {
        WorkspaceDetail.resolve(
            section: section, selection: selection, hasMeetings: !library.isEmpty, meta: lookup(library))
    }

    @Test("a selected meeting that is in the library is the document, and carries it")
    func selectedMeeting() {
        let resolved = detail(.meetings, selection: first.id, library: [first, second])
        #expect(resolved == .meeting(first))
    }

    @Test("an empty library is a different screen from one with nothing selected")
    func emptyIsNotUnselected() {
        #expect(detail(.meetings, selection: nil, library: []) == .noMeetings)
        #expect(detail(.meetings, selection: nil, library: [first]) == .noSelection)
    }

    @Test("a selection the library no longer holds never reaches the document")
    func staleSelection() {
        #expect(detail(.meetings, selection: first.id, library: [second]) == .noSelection)
        #expect(detail(.meetings, selection: first.id, library: []) == .noMeetings)
    }

    @Test("Trash and Settings take the pane whatever is selected")
    func sectionsWin() {
        #expect(detail(.trash, selection: first.id, library: [first]) == .trash)
        #expect(detail(.settings, selection: first.id, library: [first]) == .settings)
        // And the selection is still there when the library comes back.
        #expect(detail(.meetings, selection: first.id, library: [first]) == .meeting(first))
    }

    @Test("the library is asked once about the selection, and never about anything else")
    func asksTheLibraryOnlyWhatItNeeds() {
        var asked: [UUID] = []
        let counting: (UUID) -> MeetingMeta? = { id in
            asked.append(id)
            return [self.first, self.second].first { $0.id == id }
        }
        _ = WorkspaceDetail.resolve(
            section: .meetings, selection: first.id, hasMeetings: true, meta: counting)
        #expect(asked == [first.id])

        asked.removeAll()
        _ = WorkspaceDetail.resolve(section: .trash, selection: first.id, hasMeetings: true, meta: counting)
        _ = WorkspaceDetail.resolve(section: .meetings, selection: nil, hasMeetings: true, meta: counting)
        #expect(asked.isEmpty, "the pane is decided without walking the library")
    }
}
