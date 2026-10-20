//
//  MeetingSidebar.swift
//  Workspace
//
//  The sidebar the design draws: the app's row with the mark, Search and
//  Settings as rows under it, the meetings under a section label that counts
//  them, grouped by date — with the session being recorded pinned above the
//  groups while there is one — and the way to Trash with what the library
//  occupies at the foot.
//
//  Every row is the same shape — one height, one inset, one radius — so the
//  list reads as one column whatever a row holds. Rows are custom views in a
//  scroll view: a `List` in a sidebar column rendered zero rows on this macOS,
//  and a `List(selection:)` with a custom selection card paints the highlight
//  twice. Selection lives in `WorkspaceModel`; the sidebar only reads and
//  writes it.
//

import DesignSystem
import EchoCore
import Meetings
import Recording
import SwiftUI

struct MeetingSidebar: View {
    @Environment(MeetingLibrary.self) private var library
    @Environment(WorkspaceModel.self) private var workspace
    @Environment(RecordingSession.self) private var session

    @FocusState private var searchFocused: Bool
    @FocusState private var listFocused: Bool
    @State private var hovered: SidebarHover?
    @State private var contextClicks = RowContextClickWatcher()
    @State private var renameTarget: MeetingMeta?

    /// Which row the pointer is over. One value for the whole column, because
    /// the pointer is only ever over one row.
    private enum SidebarHover: Hashable {
        case search
        case settings
        case liveSession
        case trash
        case meeting(UUID)
    }

    var body: some View {
        VStack(spacing: 0) {
            appRow
            searchRow
            settingsRow
            sectionLabel
            if let startedAt = session.phase.startedAt {
                liveRow(startedAt)
            }
            list
            footer
        }
        .padding(EchoSpacing.s)
        // A right-click selects the row it is about to open its menu on, and
        // only while the pointer is over one of these rows, in this window.
        .background(WindowReader { contextClicks.listWindow = $0 })
        .onAppear {
            contextClicks.onContextClick = { id in workspace.open(id) }
            contextClicks.start()
        }
        .onDisappear { contextClicks.stop() }
        .renameMeetingAlert($renameTarget)
    }

    // MARK: The app

    /// The mark and the app's name. The artboard puts a chevron at the end of
    /// this row and no artboard says what it opens, so it is left out until
    /// one does (product owner, 2026-10-19): a chevron that opens nothing
    /// reads as broken.
    private var appRow: some View {
        // The mark carries its clear space with it. The artboard measures the
        // row's inset and the gap to the name from the mark's grid, so the
        // clear space comes out of both rather than being added to them.
        let clear = EchoMark.clearSpaceInset(for: EchoControl.appMarkSize).width
        return HStack(spacing: EchoSpacing.s - clear) {
            EchoMark(size: EchoControl.appMarkSize, ink: EchoColor.accent)
            Text("Echo")
                .font(EchoFont.appName)
                .tracking(EchoFont.appNameTracking)
                .foregroundStyle(EchoColor.textPrimary)
            Spacer(minLength: 0)
        }
        .padding(.leading, EchoLayout.appRowInset - clear)
        .padding(.trailing, EchoLayout.appRowInset)
        .frame(height: EchoLayout.appRowHeight)
        .padding(.bottom, EchoSpacing.s)
    }

    // MARK: Search

    /// The search row types in place: the design draws it as a row with its
    /// shortcut, so it stays a row and becomes a field where it stands. What
    /// ⌘K eventually opens is an open decision; today it puts the caret here,
    /// where the filter already lives.
    private var searchRow: some View {
        @Bindable var workspace = workspace
        return HStack(spacing: EchoSpacing.s) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: EchoControl.sidebarGlyphSize))
                .frame(width: EchoControl.sidebarGlyphSize)
                .foregroundStyle(EchoColor.textTertiary)
            ZStack(alignment: .leading) {
                if workspace.searchText.isEmpty {
                    // The placeholder the design draws, in the design's own
                    // colour. It is decoration: the field below carries the
                    // name, and a reader that heard both would hear it twice.
                    Text("Search")
                        .font(EchoFont.row)
                        .foregroundStyle(EchoColor.textSecondary)
                        .accessibilityHidden(true)
                }
                TextField("", text: $workspace.searchText)
                    .textFieldStyle(.plain)
                    .font(EchoFont.row)
                    .foregroundStyle(EchoColor.textPrimary)
                    .accessibilityLabel("Search")
                    .focused($searchFocused)
                    .onExitCommand {
                        workspace.searchText = ""
                        searchFocused = false
                    }
            }
            Text("⌘K")
                .font(EchoFont.mono(11))
                .foregroundStyle(EchoColor.textQuaternary)
        }
        .sidebarRow(isSelected: false, isHovered: hovered == .search || searchFocused)
        .onHover { hovering in hover(.search, hovering) }
        .onTapGesture { searchFocused = true }
        .background {
            // ⌘K focuses the search field from anywhere in the window.
            Button("") { searchFocused = true }
                .keyboardShortcut("k", modifiers: .command)
                .frame(width: 0, height: 0)
                .opacity(0)
        }
    }

    // MARK: Settings

    private var settingsRow: some View {
        Button {
            workspace.section = .settings
        } label: {
            HStack(spacing: EchoSpacing.s) {
                Image(systemName: "gearshape")
                    .font(.system(size: EchoControl.sidebarGlyphSize))
                    .frame(width: EchoControl.sidebarGlyphSize)
                    .foregroundStyle(EchoColor.textTertiary)
                rowTitle("Settings", isSelected: workspace.section == .settings)
                Spacer(minLength: EchoSpacing.s)
            }
            .sidebarRow(isSelected: workspace.section == .settings, isHovered: hovered == .settings)
        }
        .buttonStyle(.plain)
        .onHover { hovering in hover(.settings, hovering) }
    }

    // MARK: The meetings

    private var sectionLabel: some View {
        HStack(spacing: EchoSpacing.s) {
            Text("Meetings")
                .font(EchoFont.sectionLabel)
                .tracking(EchoFont.sectionLabelTracking)
                .foregroundStyle(EchoColor.textTertiary)
            // The label takes the row and the count sits at its right edge,
            // where every other count in the column sits.
            Spacer(minLength: EchoSpacing.s)
            Text("\(library.metas.count)")
                .font(EchoFont.mono(11))
                .foregroundStyle(EchoColor.textQuaternary)
        }
        .padding(.horizontal, EchoLayout.sidebarRowInset)
        .frame(height: EchoLayout.sectionLabelHeight)
        .padding(.top, EchoLayout.sectionLabelTopMargin)
        // The design draws no sort control; the orders stay reachable without
        // putting a second affordance on a row that is a label.
        .contextMenu { sortMenu }
    }

    @ViewBuilder
    private var sortMenu: some View {
        Picker("Sort", selection: Binding(get: { workspace.sortOrder }, set: { workspace.sortOrder = $0 })) {
            ForEach(MeetingSortOrder.allCases) { order in
                Text(order.menuTitle).tag(order)
            }
        }
        .pickerStyle(.inline)
    }

    // MARK: The live session

    /// The session being recorded, pinned above the date groups for as long
    /// as capture runs. It is the session, not a stored meeting: the meeting
    /// joins the groups once the stop has saved it.
    private func liveRow(_ startedAt: Date) -> some View {
        Button {
            workspace.showLiveSession()
        } label: {
            LiveSessionRow(
                startedAt: startedAt,
                isSelected: workspace.section == .recording,
                isHovered: hovered == .liveSession
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in hover(.liveSession, hovering) }
    }

    private var visible: [MeetingMeta] { workspace.visibleMeetings(in: library.metas) }

    @ViewBuilder
    private var list: some View {
        if library.metas.isEmpty {
            // The document says so, with the one action out of it; the list
            // saying it too would be the same sentence twice.
            Spacer()
        } else if workspace.searchHidesEverything(in: library.metas) {
            // In the list's place, where the rows were (product owner,
            // 2026-10-20); the document keeps the meeting being read. It says
            // what search reads, because it does not read transcripts.
            EmptyState(
                glyph: .magnifier, title: "No meeting matches “\(workspace.searchText)”",
                message: "Search reads titles, one-line descriptions and dates — not the body of the transcript."
            ) {
                Button("Clear search") { workspace.searchText = "" }
                    .buttonStyle(.echoControl)
            }
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        let groups = MeetingDateGroup.groups(for: visible, sort: workspace.sortOrder)
                        ForEach(Array(groups.enumerated()), id: \.element.id) { index, group in
                            if !group.title.isEmpty {
                                groupHeader(group.title, isFirst: index == 0)
                            }
                            ForEach(group.meetings) { meta in
                                row(for: meta)
                            }
                        }
                    }
                }
                .scrollIndicators(.never)
                .focusable()
                .focusEffectDisabled()
                .focused($listFocused)
                .onKeyPress(.upArrow) { move(.up, proxy) }
                .onKeyPress(.downArrow) { move(.down, proxy) }
                .onKeyPress(.home) { move(.first, proxy) }
                .onKeyPress(.end) { move(.last, proxy) }
                .onKeyPress(.return) {
                    guard workspace.selectedMeetingID != nil else { return .ignored }
                    workspace.section = .meetings
                    return .handled
                }
                .onDeleteCommand {
                    if let id = workspace.selectedMeetingID { trash(id) }
                }
            }
        }
    }

    private func groupHeader(_ title: String, isFirst: Bool) -> some View {
        Text(title)
            .font(EchoFont.groupHeader)
            .foregroundStyle(EchoColor.textQuaternary)
            .padding(.horizontal, EchoLayout.sidebarRowInset)
            .frame(height: EchoLayout.groupHeaderHeight, alignment: .leading)
            .padding(.top, isFirst ? 0 : EchoLayout.groupHeaderTopMargin)
    }

    private func row(for meta: MeetingMeta) -> some View {
        MeetingRowView(
            meta: meta,
            isSelected: workspace.selectedMeetingID == meta.id && workspace.section == .meetings,
            isHovered: hovered == .meeting(meta.id)
        )
        .id(meta.id)
        .onTapGesture {
            workspace.open(meta.id)
            listFocused = true
        }
        .onHover { hovering in hover(.meeting(meta.id), hovering) }
        .contextMenu { contextMenu(for: meta) }
    }

    @ViewBuilder
    private func contextMenu(for meta: MeetingMeta) -> some View {
        Button("Open Summary") { workspace.open(meta.id, tab: .summary) }
        Button("Open Transcript") { workspace.open(meta.id, tab: .transcript) }
        Divider()
        Button("Rename…") { renameTarget = meta }
        Menu("Export…") {
            ForEach(MeetingExportFormat.allCases) { format in
                Button(format.menuTitle) {
                    Task {
                        if let record = await library.loadRecord(meta.id) {
                            MeetingActions.export(record, as: format)
                        }
                    }
                }
            }
        }
        Button("Copy Summary as Markdown") {
            Task {
                if let record = await library.loadRecord(meta.id) {
                    MeetingActions.copySummary(record.summaryMarkdown, meta: record.meta)
                }
            }
        }
        .disabled(!meta.hasSummary)
        Button("Reveal in Finder") { MeetingActions.revealInFinder(library.directory(for: meta.id)) }
        Divider()
        Button("Move to Trash", role: .destructive) { trash(meta.id) }
    }

    private func move(_ move: MeetingListSelection.Move, _ proxy: ScrollViewProxy) -> KeyPress.Result {
        // `.ignored` when there is nowhere to go, so the key falls through to
        // whatever would normally handle it instead of being silently eaten.
        guard workspace.moveSelection(move, in: library.metas) else { return .ignored }
        workspace.section = .meetings
        if let id = workspace.selectedMeetingID {
            withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(id, anchor: nil) }
        }
        return .handled
    }

    private func trash(_ id: UUID) {
        // Re-home the selection before the row leaves, so a run of deletes
        // keeps working from the keyboard.
        workspace.selectionAfterRemoving(id, in: library.metas)
        Task { await library.trash(id) }
    }

    /// Keeps the hover state and the context-click watcher's idea of the
    /// hovered row in step: the watcher has no other way to know which row a
    /// right-click landed on.
    private func hover(_ row: SidebarHover, _ hovering: Bool) {
        if hovering {
            hovered = row
        } else if hovered == row {
            hovered = nil
        }
        contextClicks.hoveredID = if case .meeting(let id) = hovered { id } else { nil }
    }

    // MARK: Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                workspace.showTrash()
            } label: {
                HStack(spacing: EchoSpacing.s) {
                    Image(systemName: "trash")
                        .font(.system(size: EchoControl.sidebarGlyphSize))
                        .frame(width: EchoControl.sidebarGlyphSize)
                        .foregroundStyle(EchoColor.textTertiary)
                    rowTitle("Trash", isSelected: workspace.section == .trash)
                    Spacer(minLength: EchoSpacing.s)
                    if library.trashedMetas.count > 0 {
                        Text("\(library.trashedMetas.count)")
                            .font(EchoFont.mono(11))
                            .foregroundStyle(EchoColor.textQuaternary)
                    }
                }
                .sidebarRow(isSelected: workspace.section == .trash, isHovered: hovered == .trash)
            }
            .buttonStyle(.plain)
            .onHover { hovering in hover(.trash, hovering) }
            if let line = SidebarStorageLine.text(for: library.storage) {
                Text(line)
                    .font(EchoFont.mono(10.5))
                    .foregroundStyle(EchoColor.textFaint)
                    .lineLimit(1)
                    .padding(.top, EchoSpacing.s)
                    .padding(.horizontal, EchoLayout.sidebarRowInset)
                    .padding(.bottom, EchoSpacing.xs)
            }
        }
    }

    private func rowTitle(_ title: String, isSelected: Bool) -> some View {
        Text(title)
            .font(isSelected ? EchoFont.rowSelected : EchoFont.row)
            .foregroundStyle(isSelected ? EchoColor.textPrimary : EchoColor.textSecondary)
            .lineLimit(1)
    }
}

/// The session being recorded, as a sidebar row: the red dot, the word, and
/// the clock.
struct LiveSessionRow: View {
    let startedAt: Date
    let isSelected: Bool
    let isHovered: Bool

    var body: some View {
        HStack(spacing: EchoSpacing.s) {
            Circle()
                .fill(EchoColor.recording)
                .frame(width: EchoControl.recordingDotSize, height: EchoControl.recordingDotSize)
                .accessibilityHidden(true)
            Text("Recording")
                .font(isSelected ? EchoFont.rowSelected : EchoFont.row)
                .foregroundStyle(isSelected ? EchoColor.textPrimary : EchoColor.textSecondary)
                .lineLimit(1)
            Spacer(minLength: EchoSpacing.s)
            TimelineView(.periodic(from: startedAt, by: 1)) { context in
                Text(EchoClock.compact(EchoClock.elapsedSeconds(since: startedAt, now: context.date)))
                    .font(EchoFont.mono(11.5))
                    .foregroundStyle(EchoColor.recordingTimer)
                    .fixedSize()
            }
        }
        .sidebarRow(isSelected: isSelected, isHovered: isHovered)
    }
}

/// One meeting in the sidebar: its title, and a mark when the meeting is not
/// finished. One line — the caption, the time and the word count belong to the
/// document, and a second line here would halve how much history fits.
struct MeetingRowView: View {
    let meta: MeetingMeta
    let isSelected: Bool
    let isHovered: Bool

    var body: some View {
        HStack(spacing: EchoSpacing.s) {
            Text(meta.title)
                .font(isSelected ? EchoFont.rowSelected : EchoFont.row)
                .foregroundStyle(isSelected ? EchoColor.textPrimary : EchoColor.textSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: EchoSpacing.s)
            if let mark = MeetingStatus.resolve(meta).rowMark {
                Text(mark.rawValue)
                    .font(EchoFont.mono(10))
                    .foregroundStyle(mark == .failed ? EchoColor.danger : EchoColor.textQuaternary)
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        .sidebarRow(isSelected: isSelected, isHovered: isHovered)
    }
}

extension View {
    /// The shape every sidebar row shares: one height, one inset, one radius,
    /// and the chrome behind it. A row's content decides nothing about its
    /// geometry, so Search, Settings, a meeting and Trash line up exactly.
    fileprivate func sidebarRow(isSelected: Bool, isHovered: Bool) -> some View {
        padding(.horizontal, EchoLayout.sidebarRowInset)
            .frame(height: EchoLayout.sidebarRowHeight)
            .background(SelectableRowChrome(isSelected: isSelected, isHovered: isHovered))
            .contentShape(.rect(cornerRadius: EchoRadius.row))
    }
}
