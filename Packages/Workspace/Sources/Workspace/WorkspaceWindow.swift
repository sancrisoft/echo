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
//  frame overrides, so a smaller window clips both columns. The right pane
//  paints no background of its own — the window's material shows through, and
//  a flat color over it reads as a band in dark mode.
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
        HStack(spacing: 0) {
            MeetingSidebar()
                .frame(width: EchoLayout.sidebarWidth)
            Divider()
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: EchoLayout.minimumWindow.width, minHeight: EchoLayout.minimumWindow.height)
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
        switch workspace.section {
        case .meetings:
            if library.metas.isEmpty {
                EmptyState(
                    symbol: "waveform",
                    title: "No meetings yet",
                    message: "Record a call and it will show up here with its transcript and notes."
                )
            } else if let id = workspace.selectedMeetingID, let meta = library.meta(for: id) {
                MeetingDocumentView(meta: meta)
                    .id(id)
            } else {
                EmptyState(
                    symbol: "sidebar.left",
                    title: "Select a meeting",
                    message: "Pick a meeting from the sidebar to read its summary and transcript."
                )
            }
        case .trash:
            TrashView()
        case .settings:
            SettingsScreen(dataRoot: dataRoot)
        }
    }
}
