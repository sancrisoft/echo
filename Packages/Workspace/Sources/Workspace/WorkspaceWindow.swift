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
import Recording
import SwiftUI

public struct WorkspaceWindow: View {
    @Environment(MeetingLibrary.self) private var library
    @Environment(WorkspaceModel.self) private var workspace
    @Environment(RecordingSession.self) private var session
    @Environment(AppSettings.self) private var settings

    private let dataRoot: DataRoot
    private let startRecording: () async -> Void

    /// - Parameter startRecording: New recording. The composition root's, so
    ///   the window starts the same gated recording, with the same capture, as
    ///   every other surface (`TitleBar`). It returns once the start has
    ///   landed, so the window knows whether there is a session to show.
    public init(dataRoot: DataRoot, startRecording: @escaping () async -> Void) {
        self.dataRoot = dataRoot
        self.startRecording = startRecording
    }

    public var body: some View {
        Group {
            if workspace.showsWelcome {
                // The welcome screen takes the whole window, title bar
                // included, as `FirstRun.dc.html` draws it: no sidebar, no
                // hairline, nothing in the toolbar.
                WelcomeScreen(dataRoot: dataRoot) {
                    settings.noteLeftWelcome()
                    workspace.leaveWelcome()
                }
            } else {
                workspaceLayout
            }
        }
        .frame(minWidth: EchoLayout.minimumWindow.width, minHeight: EchoLayout.minimumWindow.height)
        .background(WindowChromeReader(background: EchoColor.windowBackground))
        .toolbar {
            if !workspace.showsWelcome {
                TitleBarToolbar(startRecording: { recordFromTheWindow() })
            }
        }
        // Capture ended: if the window was showing the session, it follows
        // the meeting the stop saved into the library.
        .onChange(of: session.phase) { _, phase in
            switch phase {
            case .recording, .stopping:
                break
            case .idle, .finalizing, .summarizing:
                workspace.liveSessionEnded(savedMeeting: phase.meetingID)
            }
        }
        // A selection the library no longer holds (trashed, deleted, purged)
        // is dropped so the document never shows a meeting that is gone, and
        // the library opens on another rather than on nothing.
        .onChange(of: library.metas.map(\.id)) { _, _ in
            workspace.reconcileSelection(with: library.metas)
            settleSelection()
        }
        // The window opens on the meeting last open, and remembers each one
        // it opens for the next launch.
        .onAppear { settleSelection() }
        .onChange(of: workspace.selectedMeetingID) { _, id in
            if let id {
                settings.noteOpenMeeting(id)
            } else {
                settleSelection()
            }
        }
        .onChange(of: library.trashedMetas.map(\.id)) { _, _ in
            workspace.reconcileTrashSelection(with: library.trashedMetas)
        }
    }

    /// The sidebar and, always to its right, the document.
    private var workspaceLayout: some View {
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
                VStack(spacing: 0) {
                    // Above the meetings, never above Trash or Settings,
                    // which take the document's place and are not about the
                    // meetings at all.
                    if workspace.section == .meetings || workspace.section == .recording {
                        ModelsPanel()
                    }
                    detail
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(EchoColor.windowBackground)
            }
        }
    }

    private func settleSelection() {
        workspace.settleSelection(in: library.metas, lastOpen: settings.lastOpenMeeting)
    }

    /// New recording, from the title bar. The window shows the session only
    /// once there is one: a refused start, or one whose capture failed, has
    /// nothing to show, and the window stays where it was.
    private func recordFromTheWindow() {
        Task {
            await startRecording()
            if session.phase.isRecording {
                workspace.showLiveSession()
            }
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
            meta: { id in library.metas.first { $0.id == id } },
            phase: session.phase,
            openedTrashedID: workspace.openedTrashedID,
            trashedMeta: { id in library.trashedMetas.first { $0.id == id } })
        {
        case .meeting(let meta):
            MeetingDocumentView(meta: meta, dataRoot: dataRoot)
                .id(meta.id)
        case .liveSession(let live):
            LiveSessionDocument(session: live)
        case .savingSession:
            // A moment's blank rather than the meeting that was open before:
            // the one being saved is about to take its place.
            Color.clear
        case .noMeetings:
            EmptyState(
                glyph: .waveform, title: "No meetings yet",
                message:
                    "Start one from the island in the notch, or right here. Echo also offers on its own when it notices a call."
            ) {
                // The title bar's own start, held back the same way and for
                // the same reasons; the title bar says why beside its button.
                Button("New recording") { recordFromTheWindow() }
                    .buttonStyle(.echoControlProminent)
                    .disabled(
                        TitleBarState.resolve(phase: session.phase, readiness: session.readiness) != .newRecording)
            }
        case .noSelection:
            // Never shown for long: the window opens on the meeting last open,
            // or the most recent (product owner, 2026-10-02), and settles on
            // one the moment the library has any. A blank for that instant,
            // as while a session is saved.
            Color.clear
        case .trash:
            TrashView()
        case .trashedMeeting(let meta):
            MeetingDocumentView(meta: meta, dataRoot: dataRoot)
                .id(meta.id)
        case .settings:
            SettingsScreen(dataRoot: dataRoot)
        }
    }
}
