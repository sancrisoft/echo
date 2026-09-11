//
//  WorkspaceWindow.swift
//  Workspace
//
//  The main window: a fixed sidebar of meetings and, always to its right, the
//  document — so switching meetings never loses context. Trash and Settings
//  take the document's place while they are open.
//
//  A plain HStack, not `NavigationSplitView`: on this macOS the split view's
//  columns carry a rigid fitting height of roughly the screen that no SwiftUI
//  frame overrides, so a smaller window clips both columns, and a List inside
//  its sidebar column can render zero rows.
//
//  Both panes paint the backdrops the design draws — the document the
//  window's, the sidebar its own, a step darker — and the window itself takes
//  the same background, title bar included (`WindowChrome`). That last part is
//  the whole trick: what banded in the PoC was a flat colour over *part* of a
//  wallpaper-tinted window, the painted pane meeting the material beside and
//  above it. With nothing translucent left to meet, the artboard's flat
//  backdrops are simply what the window is, and the design's hairline — not
//  the system's separator — draws the line under the title bar.
//

import DesignSystem
import EchoCore
import Meetings
import SwiftUI

public struct WorkspaceWindow: View {
    @Environment(MeetingLibrary.self) private var library
    @Environment(WorkspaceModel.self) private var workspace

    private let dataRoot: DataRoot

    public init(dataRoot: DataRoot) {
        self.dataRoot = dataRoot
    }

    public var body: some View {
        VStack(spacing: 0) {
            // The hairline under the title bar, drawn at the content's top
            // edge because that is where the title bar ends.
            EchoColor.divider
                .frame(height: EchoLayout.hairline)
            HStack(spacing: 0) {
                MeetingSidebar()
                    .frame(width: EchoLayout.sidebarWidth)
                    .background(EchoColor.sidebarBackground)
                EchoColor.divider
                    .frame(width: EchoLayout.hairline)
                detail
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(EchoColor.windowBackground)
            }
        }
        .frame(minWidth: EchoLayout.minimumWindow.width, minHeight: EchoLayout.minimumWindow.height)
        .background(WindowChromeReader(background: EchoColor.windowBackground))
        // A selection the library no longer holds (trashed, deleted, purged)
        // is dropped so the document never shows a meeting that is gone.
        .onChange(of: library.metas.map(\.id)) { _, _ in
            workspace.reconcileSelection(with: library.metas)
        }
        .onChange(of: library.trashedMetas.map(\.id)) { _, _ in
            workspace.reconcileTrashSelection(with: library.trashedMetas)
        }
    }

    @ViewBuilder
    private var detail: some View {
        // Questions, not a copy: `body` runs on every change, and the list of
        // ids it used to build was an allocation per pass. Only the live
        // meetings answer — a trashed meeting is one the library no longer
        // holds, whatever its folder still contains.
        switch WorkspaceDetail.resolve(
            section: workspace.section,
            selection: workspace.selectedMeetingID,
            hasMeetings: !library.metas.isEmpty,
            meta: { id in library.metas.first { $0.id == id } })
        {
        case .meeting(let meta):
            MeetingDocumentView(meta: meta)
                .id(meta.id)
        case .noMeetings:
            EmptyState(
                symbol: "waveform",
                title: "No meetings yet",
                message: "Record a call and it will show up here with its transcript and notes."
            )
        case .noSelection:
            EmptyState(
                symbol: "sidebar.left",
                title: "Select a meeting",
                message: "Pick a meeting from the sidebar to read its summary and transcript."
            )
        case .trash:
            TrashView()
        case .settings:
            SettingsScreen(dataRoot: dataRoot)
        }
    }
}
