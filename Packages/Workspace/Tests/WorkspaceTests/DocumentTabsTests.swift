import Foundation
import Testing

@testable import Workspace

@Suite("The document's tabs")
@MainActor
struct DocumentTabsTests {

    @Test("two tabs and no more, Summary first")
    func order() {
        #expect(WorkspaceModel.DocumentTab.allCases == [.summary, .transcript])
        #expect(WorkspaceModel.DocumentTab.allCases.map(\.title) == ["Summary", "Transcript"])
    }

    @Test("a meeting opens on its summary, and on the transcript only when asked")
    func openingTab() {
        let workspace = WorkspaceModel()
        #expect(workspace.documentTab == .summary)
        workspace.open(UUID(), tab: .transcript)
        #expect(workspace.documentTab == .transcript)
        // Opening another meeting keeps the tab the user is reading.
        workspace.open(UUID())
        #expect(workspace.documentTab == .transcript)
    }
}
