//
//  WorkspaceShellTests.swift
//  WorkspaceTests
//
//  The shell is checked by rendering it, because the thing that went wrong
//  before was geometry: `NavigationSplitView` fits at roughly the height of a
//  screen whatever frame it is given, so the window clipped at any smaller
//  size. `ImageRenderer` needs no host app, so this is an ordinary package
//  test — and it fails the moment the two panes stop fitting at the floor.
//

import DesignSystem
import EchoCore
import EchoCoreTestSupport
import Foundation
import Meetings
import SwiftUI
import Testing

@testable import Workspace

@Suite("The window shell")
struct WorkspaceShellTests {

    /// The size the shell asks for when nothing constrains it. A render that
    /// produced no image is a failure, never a zero size: every expectation
    /// below is an upper bound, and zero would satisfy all of them while
    /// proving nothing.
    private func idealSize(of view: some View) throws -> CGSize {
        let renderer = ImageRenderer(content: view.fixedSize())
        renderer.scale = 2
        let image = try #require(renderer.nsImage, "the shell rendered nothing")
        #expect(image.size.width > 0 && image.size.height > 0, "the shell rendered an empty image")
        return image.size
    }

    private func window(_ library: MeetingLibrary, _ dataRoot: DataRoot) -> some View {
        WorkspaceWindow(dataRoot: dataRoot)
            .environment(library)
            .environment(WorkspaceModel())
            .environment(AppSettings(dataRoot: dataRoot))
    }

    private func save(_ titles: [String], to store: MeetingStore) async throws {
        for (index, title) in titles.enumerated() {
            let start = Date(timeIntervalSince1970: 1_756_900_000 - Double(index) * 3600)
            let meta = MeetingMeta(
                id: UUID(), title: title, startedAt: start, endedAt: start.addingTimeInterval(1800),
                segmentCount: 0, hasSummary: false)
            try await store.save(MeetingRecord(meta: meta, segments: []))
        }
    }

    @Test("the two panes fit inside the smallest window the layout promises")
    func fitsAtTheFloor() throws {
        let temporary = try TemporaryDirectory()
        defer { temporary.remove() }
        let dataRoot = DataRoot(url: temporary.url)
        let size = try idealSize(of: window(MeetingLibrary(dataRoot: dataRoot), dataRoot))
        #expect(size.width <= EchoLayout.minimumWindow.width, "the shell is wider than the smallest window")
        #expect(size.height <= EchoLayout.minimumWindow.height, "the shell is taller than the smallest window")
    }

    @Test("the sidebar holds its width however long the titles are")
    func longTitlesDoNotWidenTheSidebar() async throws {
        let temporary = try TemporaryDirectory()
        defer { temporary.remove() }
        let dataRoot = DataRoot(url: temporary.url)
        let store = MeetingStore(dataRoot: dataRoot)
        try await save(
            (0..<12).map { "Meeting \($0) with a title far longer than any sidebar could ever show at once" },
            to: store)
        let library = MeetingLibrary(dataRoot: dataRoot)
        await library.refresh()
        #expect(library.metas.count == 12)
        let size = try idealSize(of: window(library, dataRoot))
        #expect(size.width <= EchoLayout.minimumWindow.width, "a long title pushed the panes apart")
    }
}
