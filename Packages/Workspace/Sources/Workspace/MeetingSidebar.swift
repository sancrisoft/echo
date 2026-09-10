//
//  MeetingSidebar.swift
//  Workspace
//
//  The meetings, grouped by date, with search and sort at the top and the
//  way to Trash and Settings at the bottom. Rows are custom views in a scroll
//  view: a `List` in a sidebar column rendered zero rows on this macOS, and a
//  `List(selection:)` with a custom selection card paints the highlight twice.
//  Selection lives in `WorkspaceModel`; the sidebar only reads and writes it.
//

import DesignSystem
import EchoCore
import Meetings
import SwiftUI

struct MeetingSidebar: View {
    @Environment(MeetingLibrary.self) private var library
    @Environment(WorkspaceModel.self) private var workspace

    @FocusState private var searchFocused: Bool
    @FocusState private var listFocused: Bool
    @State private var hoveredID: UUID?
    @State private var renameTarget: MeetingMeta?
    @State private var renameText = ""

    var body: some View {
        @Bindable var workspace = workspace
        VStack(spacing: 0) {
            header
            searchField
            list
            Divider()
            footer
        }
        .alert(
            "Rename Meeting", isPresented: Binding(get: { renameTarget != nil }, set: { if !$0 { renameTarget = nil } })
        ) {
            TextField("Title", text: $renameText)
            Button("Rename") {
                if let target = renameTarget {
                    Task { await library.rename(target.id, to: renameText) }
                }
                renameTarget = nil
            }
            Button("Cancel", role: .cancel) { renameTarget = nil }
        }
    }

    // MARK: Header and search

    private var header: some View {
        HStack {
            Text("Meetings")
                .font(EchoFont.sectionTitle)
                .foregroundStyle(EchoColor.textPrimary)
            if !library.metas.isEmpty {
                Text("\(library.metas.count)")
                    .font(EchoFont.mono(11.5))
                    .foregroundStyle(EchoColor.textTertiary)
            }
            Spacer()
            Menu {
                Picker("Sort", selection: Binding(get: { workspace.sortOrder }, set: { workspace.sortOrder = $0 })) {
                    ForEach(MeetingSortOrder.allCases) { order in
                        Text(order.menuTitle).tag(order)
                    }
                }
                .pickerStyle(.inline)
            } label: {
                Image(systemName: "arrow.up.arrow.down")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(EchoColor.textSecondary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Sort")
        }
        .padding(.horizontal, EchoSpacing.l)
        .padding(.top, EchoSpacing.l)
        .padding(.bottom, EchoSpacing.s)
    }

    private var searchField: some View {
        @Bindable var workspace = workspace
        return HStack(spacing: EchoSpacing.xs) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(EchoColor.textTertiary)
                .font(.system(size: 12))
            TextField("Search meetings", text: $workspace.searchText)
                .textFieldStyle(.plain)
                .font(EchoFont.row.weight(.regular))
                .focused($searchFocused)
            if !workspace.searchText.isEmpty {
                Button {
                    workspace.searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(EchoColor.textTertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, EchoSpacing.s)
        .padding(.vertical, 6)
        .background(EchoColor.surfaceRaised.opacity(0.6), in: .rect(cornerRadius: EchoRadius.control))
        .overlay(RoundedRectangle(cornerRadius: EchoRadius.control).strokeBorder(EchoColor.border))
        .padding(.horizontal, EchoSpacing.m)
        .padding(.bottom, EchoSpacing.s)
        .background {
            // ⌘F focuses the search field from anywhere in the window.
            Button("") { searchFocused = true }
                .keyboardShortcut("f", modifiers: .command)
                .frame(width: 0, height: 0)
                .opacity(0)
        }
    }

    // MARK: List

    private var visible: [MeetingMeta] { workspace.visibleMeetings(in: library.metas) }

    @ViewBuilder
    private var list: some View {
        if library.metas.isEmpty {
            Spacer()
            Text("No meetings yet")
                .font(EchoFont.control)
                .foregroundStyle(EchoColor.textTertiary)
            Spacer()
        } else if workspace.searchHidesEverything(in: library.metas) {
            Spacer()
            Text("No results for “\(workspace.searchText)”")
                .font(EchoFont.control)
                .foregroundStyle(EchoColor.textTertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, EchoSpacing.l)
            Spacer()
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: EchoSpacing.xxs) {
                        ForEach(MeetingDateGroup.groups(for: visible, sort: workspace.sortOrder)) { group in
                            if !group.title.isEmpty {
                                Text(group.title)
                                    .font(EchoFont.micro.weight(.semibold))
                                    .foregroundStyle(EchoColor.textTertiary)
                                    .padding(.horizontal, EchoSpacing.l)
                                    .padding(.top, EchoSpacing.m)
                                    .padding(.bottom, EchoSpacing.xs)
                            }
                            ForEach(group.meetings) { meta in
                                row(for: meta)
                            }
                        }
                    }
                    .padding(.horizontal, EchoSpacing.s)
                    .padding(.bottom, EchoSpacing.s)
                }
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

    private func row(for meta: MeetingMeta) -> some View {
        MeetingRowView(
            meta: meta,
            isSelected: workspace.selectedMeetingID == meta.id && workspace.section == .meetings,
            isHovered: hoveredID == meta.id
        )
        .id(meta.id)
        .contentShape(.rect(cornerRadius: EchoRadius.row))
        .onTapGesture {
            workspace.open(meta.id)
            listFocused = true
        }
        .onHover { hovering in hoveredID = hovering ? meta.id : (hoveredID == meta.id ? nil : hoveredID) }
        .contextMenu { contextMenu(for: meta) }
    }

    @ViewBuilder
    private func contextMenu(for meta: MeetingMeta) -> some View {
        Button("Open Summary") { workspace.open(meta.id, tab: .summary) }
        Button("Open Transcript") { workspace.open(meta.id, tab: .transcript) }
        Divider()
        Button("Rename…") {
            renameText = meta.title
            renameTarget = meta
        }
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

    // MARK: Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: EchoSpacing.xxs) {
            footerRow("trash", "Trash", count: library.trashedMetas.count, section: .trash)
            footerRow("gearshape", "Settings", count: nil, section: .settings)
            if let storage = library.storage {
                Text("\(ByteCountFormatter.string(fromByteCount: storage.libraryBytes, countStyle: .file)) on this Mac")
                    .font(EchoFont.micro)
                    .foregroundStyle(EchoColor.textTertiary)
                    .padding(.horizontal, EchoSpacing.l)
                    .padding(.top, EchoSpacing.xs)
                    .padding(.bottom, EchoSpacing.s)
            }
        }
        .padding(.top, EchoSpacing.s)
    }

    private func footerRow(_ symbol: String, _ title: String, count: Int?, section: WorkspaceModel.Section) -> some View
    {
        Button {
            workspace.section = section
        } label: {
            HStack(spacing: EchoSpacing.s) {
                Image(systemName: symbol)
                    .font(.system(size: 12))
                    .frame(width: 16)
                Text(title)
                    .font(EchoFont.row)
                Spacer()
                if let count, count > 0 {
                    Text("\(count)")
                        .font(EchoFont.mono(11.5))
                        .foregroundStyle(EchoColor.textTertiary)
                }
            }
            .foregroundStyle(workspace.section == section ? EchoColor.accent : EchoColor.textSecondary)
            .padding(.horizontal, EchoSpacing.m)
            .padding(.vertical, 6)
            .background(SelectableRowChrome(isSelected: workspace.section == section, isHovered: false))
            .contentShape(.rect(cornerRadius: EchoRadius.row))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, EchoSpacing.s)
    }
}

/// One meeting in the sidebar: the title, a status badge when the meeting is
/// not fully processed, and a compact meta line.
struct MeetingRowView: View {
    let meta: MeetingMeta
    let isSelected: Bool
    let isHovered: Bool

    var body: some View {
        let status = MeetingStatus.resolve(meta)
        VStack(alignment: .leading, spacing: EchoSpacing.xxs) {
            HStack(spacing: EchoSpacing.s) {
                Text(meta.title)
                    .font(EchoFont.row)
                    .foregroundStyle(EchoColor.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
                if status != .summarized {
                    StatusBadge(status.label, tone: status.tone)
                }
            }
            Text(metaLine)
                .font(EchoFont.control)
                .foregroundStyle(EchoColor.textSecondary)
                .monospacedDigit()
                .lineLimit(1)
        }
        .padding(.horizontal, EchoSpacing.m)
        .padding(.vertical, 7)
        .background(SelectableRowChrome(isSelected: isSelected, isHovered: isHovered))
    }

    private var metaLine: String {
        var parts = [meta.startedAt.formatted(date: .omitted, time: .shortened)]
        parts.append(Self.duration(meta.duration))
        if let words = meta.wordCount, words > 0 {
            parts.append("\(words.formatted()) words")
        }
        return parts.joined(separator: " · ")
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let minutes = max(1, Int((seconds / 60).rounded()))
        if minutes < 60 { return "\(minutes) min" }
        return "\(minutes / 60) h \(minutes % 60) min"
    }
}
