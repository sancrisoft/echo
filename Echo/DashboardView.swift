//
//  DashboardView.swift
//  Echo
//
//  The full window opened from the menu bar. The library redesign makes this a
//  meetings browser: a custom top bar, a sidebar (All Meetings / Trash + a
//  storage footer), and a searchable, sortable, date-grouped list of compact
//  meeting rows with working quick actions. Opening a meeting pushes the
//  (reused) Transcript/Summary detail; recording still starts from the menu bar
//  ("New Recording" here is present but inactive for now).
//

import SwiftUI
#if DEBUG
import AppKit
#endif

private enum DetailTab: Hashable { case transcript, summary }

/// A meeting the detail stack is pushed to, with the tab it should open on.
private struct OpenedMeeting: Hashable, Identifiable {
    let id: UUID
    var tab: DetailTab
}

enum MeetingSortOrder: String, CaseIterable, Identifiable {
    case recent, oldest, name, longest

    var id: String { rawValue }

    var label: String {
        switch self {
        case .recent: return "Recent"
        case .oldest: return "Oldest"
        case .name: return "Name"
        case .longest: return "Longest"
        }
    }

    var systemImage: String {
        switch self {
        case .recent: return "clock"
        case .oldest: return "clock.arrow.circlepath"
        case .name: return "textformat"
        case .longest: return "timer"
        }
    }

    /// Only the two chronological orders get date section headers; Name/Longest
    /// show a flat list where date buckets would be misleading.
    var groupsByDate: Bool { self == .recent || self == .oldest }
}

// MARK: - Shell

struct DashboardView: View {
    @Environment(RecordingController.self) private var controller

    var body: some View {
        // A plain HStack instead of NavigationSplitView: on this macOS the
        // split view's columns carry a rigid AppKit fitting height of roughly
        // the screen (~1376pt) that no SwiftUI frame/ideal can override, so a
        // smaller window clips the top and bottom of both columns (blank
        // sidebar, list header pushed out of view). The mockup wants a plain
        // fixed sidebar anyway — no split-view chrome needed.
        HStack(spacing: 0) {
            LibrarySidebar()
                .frame(width: 240)
            Divider()
            MeetingLibraryDetail()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .textBackgroundColor))
        }
        .frame(
            minWidth: 900, idealWidth: 1100, maxWidth: .infinity,
            minHeight: 560, idealHeight: 720, maxHeight: .infinity
        )
        .navigationTitle("")
        #if DEBUG
        // Dev-only verification loop: with ECHO_SNAPSHOT_PATH set (and the
        // window auto-opened via ECHO_OPEN_DASHBOARD, see EchoApp), renders
        // this window to PNG every 2 s so UI work can be inspected from the
        // CLI without screen-recording permission. Inert in normal runs.
        .task {
            guard let path = ProcessInfo.processInfo.environment["ECHO_SNAPSHOT_PATH"] else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard let window = NSApp.windows.first(where: { $0.identifier?.rawValue == EchoWindow.dashboard }),
                      let frameView = window.contentView?.superview,
                      let rep = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds)
                else { continue }
                // An occluded window (user on another app/space) never gets a
                // display pass, so both capture paths render blank. Join the
                // active space and force a paint — verification mode only.
                if !window.occlusionState.contains(.visible) {
                    window.collectionBehavior.insert(.canJoinAllSpaces)
                    window.orderFrontRegardless()
                    window.display()
                    // Give CoreAnimation a beat to commit before capturing.
                    try? await Task.sleep(for: .milliseconds(600))
                }
                frameView.cacheDisplay(in: frameView.bounds, to: rep)
                if let data = rep.representation(using: .png, properties: [:]) {
                    try? data.write(to: URL(fileURLWithPath: path))
                }
                // Second capture path: render the committed CALayer tree.
                // cacheDisplay misses layer-only SwiftUI content on this OS;
                // the layer render shows what is actually composited.
                if let layer = frameView.layer {
                    let scale = window.backingScaleFactor
                    let width = Int(frameView.bounds.width * scale)
                    let height = Int(frameView.bounds.height * scale)
                    if let ctx = CGContext(
                        data: nil, width: width, height: height,
                        bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                    ) {
                        ctx.scaleBy(x: scale, y: scale)
                        layer.render(in: ctx)
                        if let cg = ctx.makeImage() {
                            let rep2 = NSBitmapImageRep(cgImage: cg)
                            if let data = rep2.representation(using: .png, properties: [:]) {
                                try? data.write(to: URL(fileURLWithPath: path.replacingOccurrences(of: ".png", with: "-layer.png")))
                            }
                        }
                    }
                }
            }
        }
        #endif
        .toolbar {
            // The window's native title bar hosts the top bar (breadcrumb +
            // on-device pill on the left, New Recording on the right), so the
            // window stays draggable and respects the header.
            // Flat breadcrumb: no glass platter behind it — it should blend
            // into the title bar, not read as a raised control.
            if #available(macOS 26.0, *) {
                ToolbarItem(placement: .navigation) { breadcrumb }
                    .sharedBackgroundVisibility(.hidden)
            } else {
                ToolbarItem(placement: .navigation) { breadcrumb }
            }
            ToolbarItem(placement: .primaryAction) {
                RecordToolbarButton()
            }
        }
    }

    private var breadcrumb: some View {
        HStack(spacing: 8) {
            MeetingGlyph(size: 20)
            Text("Echo").font(.headline)
            Text("/").foregroundStyle(.tertiary)
            Text(controller.library.section == .trash ? "Trash" : "Meetings")
                .font(.headline)
                .foregroundStyle(.secondary)
        }
    }
}

/// Start/stop toggle in the window toolbar. Mirrors the menu bar control: New
/// Recording starts a session; while recording it becomes a red Stop button,
/// and stopping lands the new meeting in the list.
private struct RecordToolbarButton: View {
    @Environment(RecordingController.self) private var controller

    var body: some View {
        let isRecording = controller.state.isRecording
        Button {
            Task { await controller.toggle() }
        } label: {
            Label(
                isRecording ? "Stop Recording" : "New Recording",
                systemImage: isRecording ? "stop.fill" : "play.fill"
            )
            // Toolbars collapse Labels to icon-only by default; the mockup
            // shows a labeled button.
            .labelStyle(.titleAndIcon)
            .fontWeight(.semibold)
        }
        // Same look as the menu bar popover's record button: a prominent
        // tinted capsule (indigo idle, red while recording).
        .buttonStyle(.borderedProminent)
        .tint(isRecording ? Color.red : Color.echoIndigo)
        .clipShape(Capsule())
        .help(isRecording ? "Stop recording" : "Start recording")
    }
}

// MARK: - Sidebar

private struct LibrarySidebar: View {
    @Environment(RecordingController.self) private var controller

    var body: some View {
        let library = controller.library

        // Custom rows instead of List: a List in this sidebar column renders
        // no rows at all on this macOS (verified via the view-tree dump — the
        // outline view materializes zero row views even for plain Texts).
        // Custom rows also match the mockup's look more closely.
        VStack(alignment: .leading, spacing: 4) {
            SidebarRow(
                title: "All Meetings",
                systemImage: "square.stack.3d.up.fill",
                count: library.metas.count,
                isSelected: library.section == .all
            ) { library.section = .all }

            SidebarRow(
                title: "Trash",
                systemImage: "trash",
                count: library.trashedMetas.count,
                isSelected: library.section == .trash
            ) { library.section = .trash }

            Spacer()

            Divider()
            storageFooter
        }
        .padding(10)
    }

    private var storageFooter: some View {
        HStack(spacing: 8) {
            Image(systemName: "internaldrive")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text("Stored on this Mac")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(storageText)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 10)
    }

    private var storageText: String {
        guard let bytes = controller.library.storageBytes else { return "Calculating…" }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) + " used"
    }
}

/// One selectable sidebar row: icon + title + trailing count, with the
/// selected state drawn as a tinted rounded rectangle (as in the mockup).
private struct SidebarRow: View {
    let title: String
    let systemImage: String
    let count: Int
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.callout)
                    .foregroundStyle(isSelected ? Color.echoIndigo : .secondary)
                    .frame(width: 20)
                Text(title)
                    .font(.body.weight(isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? Color.echoIndigo : .primary)
                Spacer()
                Text("\(count)")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(isSelected ? Color.echoIndigo : .secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected ? Color.echoIndigo.opacity(0.12) : .clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Detail routing

/// Hosts the navigation stack: the list for the current section is the root,
/// and opening a meeting pushes the reused detail.
private struct MeetingLibraryDetail: View {
    @Environment(RecordingController.self) private var controller
    @State private var opened: OpenedMeeting?

    var body: some View {
        let library = controller.library
        Group {
            switch library.section {
            case .all:
                AllMeetingsView(opened: $opened)
            case .trash:
                TrashView(opened: $opened)
            }
        }
        // Opening a meeting shows the detail as a full-cover overlay (with its
        // own back button) rather than a pushed NavigationStack view, so it
        // never contends with the window toolbar. Opaque background so it
        // fully covers the list.
        .overlay {
            if let target = opened {
                MeetingDetailScreen(id: target.id, initialTab: target.tab) { opened = nil }
                    .background(.background)
            }
        }
        // Leaving a section closes any open detail so it can't point at a
        // meeting that is no longer in view.
        .onChange(of: library.section) { _, _ in opened = nil }
    }
}

// MARK: - All meetings

private struct AllMeetingsView: View {
    @Environment(RecordingController.self) private var controller
    @Environment(AppSettings.self) private var settings
    @Binding var opened: OpenedMeeting?

    @State private var searchText = ""
    @State private var sortOrder: MeetingSortOrder = .recent
    @State private var selection: UUID?
    @State private var renameTarget: MeetingMeta?
    @State private var renameText = ""
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            if !settings.privacyBannerDismissed {
                PrivacyBanner { settings.dismissPrivacyBanner() }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 8)
            }
            content
        }
        .navigationTitle("")
        .alert("Rename meeting", isPresented: renamePresented) {
            TextField("Meeting name", text: $renameText)
            Button("Cancel", role: .cancel) { renameTarget = nil }
            Button("Rename") {
                if let target = renameTarget {
                    let newName = renameText
                    Task { await controller.library.rename(target.id, to: newName) }
                }
                renameTarget = nil
            }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 12) {
            Text("Meetings")
                .font(.title2.bold())
            Text("\(controller.library.metas.count)")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(.quaternary, in: Capsule())

            Spacer()

            searchField
            sortMenu

            // Invisible ⌘F affordance to focus the search field.
            Button("") { searchFocused = true }
                .keyboardShortcut("f", modifiers: .command)
                .opacity(0)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 12)
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search meetings…", text: $searchText)
                .textFieldStyle(.plain)
                .focused($searchFocused)
            if !searchText.isEmpty {
                Button { searchText = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .font(.callout)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(width: 260)
        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var sortMenu: some View {
        Menu {
            Picker("Sort", selection: $sortOrder) {
                ForEach(MeetingSortOrder.allCases) { order in
                    Label(order.label, systemImage: order.systemImage).tag(order)
                }
            }
            .pickerStyle(.inline)
        } label: {
            Label(sortOrder.label, systemImage: "arrow.up.arrow.down")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        let visible = sortedFilteredMetas
        if controller.library.metas.isEmpty {
            ContentUnavailableView(
                "No meetings yet",
                systemImage: "waveform",
                description: Text("Start a recording from the Echo menu bar and it will appear here.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if visible.isEmpty {
            ContentUnavailableView.search(text: searchText)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            meetingList(visible)
        }
    }

    private func meetingList(_ metas: [MeetingMeta]) -> some View {
        // Plain style + explicit 20pt row insets: rows share the header's
        // horizontal padding, so each row's ⋯ button lines up with the
        // header's sort control.
        List(selection: $selection) {
            if sortOrder.groupsByDate {
                ForEach(MeetingDateGroup.groups(for: metas)) { group in
                    Section(group.title) { rows(for: group.metas) }
                }
            } else {
                rows(for: metas)
            }
        }
        .listStyle(.plain)
        .onDeleteCommand { trashSelected() }
        .onKeyPress(.return) {
            guard let selection else { return .ignored }
            opened = OpenedMeeting(id: selection, tab: .transcript)
            return .handled
        }
    }

    private func rows(for metas: [MeetingMeta]) -> some View {
        ForEach(metas) { meta in
            MeetingRow(
                meta: meta,
                isActive: meta.id == controller.library.activeMeetingID,
                summaryState: controller.state.summaryState,
                onOpen: { tab in opened = OpenedMeeting(id: meta.id, tab: tab) },
                onRename: {
                    renameTarget = meta
                    renameText = meta.title
                }
            )
            .tag(meta.id)
            .listRowInsets(EdgeInsets(top: 4, leading: 20, bottom: 4, trailing: 20))
            .simultaneousGesture(TapGesture(count: 2).onEnded {
                opened = OpenedMeeting(id: meta.id, tab: .transcript)
            })
        }
    }

    // MARK: Data

    private var sortedFilteredMetas: [MeetingMeta] {
        MeetingFilter.apply(to: controller.library.metas, search: searchText, sort: sortOrder)
    }

    private var renamePresented: Binding<Bool> {
        Binding(get: { renameTarget != nil }, set: { if !$0 { renameTarget = nil } })
    }

    private func trashSelected() {
        guard let selection else { return }
        self.selection = nil
        Task { await controller.library.trash(selection) }
    }
}

// MARK: - Trash

private struct TrashView: View {
    @Environment(RecordingController.self) private var controller
    @Binding var opened: OpenedMeeting?

    @State private var selection: UUID?
    @State private var confirmDelete: MeetingMeta?
    @State private var confirmEmpty = false

    var body: some View {
        VStack(spacing: 0) {
            header
            content
        }
        .navigationTitle("")
        .confirmationDialog(
            "Delete permanently?",
            isPresented: deletePresented,
            presenting: confirmDelete
        ) { meta in
            Button("Delete Permanently", role: .destructive) {
                Task { await controller.library.deletePermanently(meta.id) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { meta in
            Text("“\(meta.title)” and its transcript and summary will be deleted immediately. This cannot be undone.")
        }
        .confirmationDialog("Empty Trash?", isPresented: $confirmEmpty) {
            Button("Empty Trash", role: .destructive) {
                Task { await controller.library.emptyTrash() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("All meetings in Trash will be permanently deleted. This cannot be undone.")
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text("Trash")
                .font(.title2.bold())
            Text("\(controller.library.trashedMetas.count)")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(.quaternary, in: Capsule())
            Spacer()
            Button("Empty Trash", role: .destructive) { confirmEmpty = true }
                .disabled(controller.library.trashedMetas.isEmpty)
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 12)
    }

    @ViewBuilder
    private var content: some View {
        let trashed = controller.library.trashedMetas
        if trashed.isEmpty {
            ContentUnavailableView(
                "Trash is empty",
                systemImage: "trash",
                description: Text("Meetings you delete land here and are removed for good after 30 days.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(selection: $selection) {
                ForEach(trashed) { meta in
                    TrashRow(
                        meta: meta,
                        onOpen: { opened = OpenedMeeting(id: meta.id, tab: .transcript) },
                        onRestore: { Task { await controller.library.restore(meta.id) } },
                        onDelete: { confirmDelete = meta }
                    )
                    .tag(meta.id)
                    .listRowInsets(EdgeInsets(top: 4, leading: 20, bottom: 4, trailing: 20))
                    .simultaneousGesture(TapGesture(count: 2).onEnded {
                        opened = OpenedMeeting(id: meta.id, tab: .transcript)
                    })
                }
            }
            .listStyle(.plain)
            .onDeleteCommand {
                if let selection, let meta = controller.library.meta(for: selection) {
                    confirmDelete = meta
                }
            }
        }
    }

    private var deletePresented: Binding<Bool> {
        Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } })
    }
}

// MARK: - Rows

/// The small indigo app mark used for meeting rows and the top bar.
private struct MeetingGlyph: View {
    var size: CGFloat = 34

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [Color(red: 0.43, green: 0.41, blue: 0.99), .echoIndigo],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .frame(width: size, height: size)
            .overlay(
                Image(systemName: "waveform")
                    .font(.system(size: size * 0.5, weight: .bold))
                    .foregroundStyle(.white)
            )
    }
}

private struct MeetingRow: View {
    @Environment(RecordingController.self) private var controller
    let meta: MeetingMeta
    let isActive: Bool
    let summaryState: SummaryState
    let onOpen: (DetailTab) -> Void
    let onRename: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            MeetingGlyph(size: 34)

            VStack(alignment: .leading, spacing: 2) {
                Text(meta.title)
                    .font(.body.weight(.semibold))
                    .lineLimit(1)
                if let description = meta.oneLineDescription, !description.isEmpty {
                    Text(description)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Text(metadataText)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 12)

            Button { onOpen(.transcript) } label: {
                Label("Transcript", systemImage: "doc.text")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("View transcript")

            StatusPill(meta: meta, isActive: isActive, summaryState: summaryState)

            quickActions
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    private var quickActions: some View {
        Menu {
            Button { onOpen(.transcript) } label: { Label("Open meeting", systemImage: "arrow.up.forward.square") }
            Button { onOpen(.transcript) } label: { Label("View transcript", systemImage: "doc.text") }
            Button(action: onRename) { Label("Rename", systemImage: "pencil") }

            Menu {
                ForEach(MeetingExportFormat.allCases) { format in
                    Button(format.menuTitle) { export(as: format) }
                }
            } label: {
                Label("Export…", systemImage: "square.and.arrow.up")
            }

            Button { copySummary() } label: { Label("Copy summary", systemImage: "doc.on.doc") }
                .disabled(!meta.hasSummary)
            Button { reveal() } label: { Label("Reveal in Finder", systemImage: "folder") }

            Divider()
            Button(role: .destructive) { trash() } label: { Label("Delete", systemImage: "trash") }
        } label: {
            Image(systemName: "ellipsis")
                .font(.body.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private var metadataText: String {
        let date = meta.startedAt.formatted(date: .abbreviated, time: .shortened)
        let minutes = max(1, Int((meta.duration / 60).rounded()))
        var parts = ["\(date)", "\(minutes) min"]
        if let words = meta.wordCount { parts.append("\(words.formatted()) words") }
        return parts.joined(separator: "  ·  ")
    }

    private func export(as format: MeetingExportFormat) {
        Task {
            if let record = await controller.library.loadRecord(meta.id) {
                MeetingActions.export(record, as: format)
            }
        }
    }

    private func copySummary() {
        Task {
            if let record = await controller.library.loadRecord(meta.id) {
                MeetingActions.copySummary(record)
            }
        }
    }

    private func reveal() {
        MeetingActions.revealInFinder(controller.library.directory(for: meta.id))
    }

    private func trash() {
        Task { await controller.library.trash(meta.id) }
    }
}

private struct TrashRow: View {
    @Environment(RecordingController.self) private var controller
    let meta: MeetingMeta
    let onOpen: () -> Void
    let onRestore: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            MeetingGlyph(size: 34)
                .opacity(0.6)

            VStack(alignment: .leading, spacing: 2) {
                Text(meta.title)
                    .font(.body.weight(.semibold))
                    .lineLimit(1)
                Text(deletionText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 12)

            Button("Restore", action: onRestore)
                .buttonStyle(.bordered)
                .controlSize(.small)

            Menu {
                Button(action: onRestore) { Label("Restore", systemImage: "arrow.uturn.backward") }
                Button { MeetingActions.revealInFinder(controller.library.directory(for: meta.id)) } label: {
                    Label("Reveal in Finder", systemImage: "folder")
                }
                Divider()
                Button(role: .destructive, action: onDelete) { Label("Delete Permanently", systemImage: "trash") }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    /// "Deleted 3 days ago · 27 days left" — reassures the user of the window.
    private var deletionText: String {
        guard let trashedAt = meta.trashedAt else { return "In Trash" }
        let deleted = trashedAt.formatted(.relative(presentation: .named))
        let expiry = trashedAt.addingTimeInterval(MeetingLibrary.trashRetention)
        let daysLeft = max(0, Calendar.current.dateComponents([.day], from: Date(), to: expiry).day ?? 0)
        return "Deleted \(deleted)  ·  \(daysLeft) days left"
    }
}

private struct StatusPill: View {
    let meta: MeetingMeta
    let isActive: Bool
    let summaryState: SummaryState

    var body: some View {
        let style = style
        HStack(spacing: 4) {
            if style.spins {
                ProgressView().controlSize(.mini)
            } else {
                Image(systemName: style.systemImage)
            }
            Text(style.text)
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(style.color)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(style.color.opacity(0.14), in: Capsule())
    }

    private var style: (text: String, color: Color, systemImage: String, spins: Bool) {
        if isActive {
            switch summaryState {
            case .generating, .streaming:
                return ("Processing", .orange, "clock", true)
            case .failed:
                return ("Summary failed", .red, "exclamationmark.triangle", false)
            default:
                break
            }
        }
        if meta.hasSummary {
            return ("Processed", .green, "checkmark.circle", false)
        }
        return ("No summary", .secondary, "doc", false)
    }
}

// MARK: - Privacy banner

private struct PrivacyBanner: View {
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "checkmark.shield.fill")
                .foregroundStyle(.green)
                .font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text("Everything stays on this Mac")
                    .font(.callout.weight(.semibold))
                Text("Only each meeting's details and transcript are saved on-device — never uploaded to the cloud, no account needed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Dismiss")
        }
        .padding(12)
        .background(Color.green.opacity(0.10), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.green.opacity(0.20))
        )
    }
}

// MARK: - Filtering / grouping

private enum MeetingFilter {
    static func apply(to metas: [MeetingMeta], search: String, sort: MeetingSortOrder) -> [MeetingMeta] {
        let filtered = filter(metas, search: search)
        switch sort {
        case .recent:  return filtered.sorted { $0.startedAt > $1.startedAt }
        case .oldest:  return filtered.sorted { $0.startedAt < $1.startedAt }
        case .name:    return filtered.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        case .longest: return filtered.sorted { $0.duration > $1.duration }
        }
    }

    private static func filter(_ metas: [MeetingMeta], search: String) -> [MeetingMeta] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return metas }
        return metas.filter { meta in
            meta.title.localizedCaseInsensitiveContains(query)
                || (meta.oneLineDescription?.localizedCaseInsensitiveContains(query) ?? false)
                || meta.startedAt.formatted(date: .abbreviated, time: .shortened).localizedCaseInsensitiveContains(query)
        }
    }
}

private struct MeetingDateGroup: Identifiable {
    let id: String
    let title: String
    let metas: [MeetingMeta]

    /// Buckets meetings into Today / Yesterday / Earlier this Week / month-year,
    /// preserving the incoming (already-sorted) order both within and across
    /// groups.
    static func groups(for metas: [MeetingMeta]) -> [MeetingDateGroup] {
        let calendar = Calendar.current
        let now = Date()
        var order: [String] = []
        var buckets: [String: [MeetingMeta]] = [:]
        for meta in metas {
            let title = bucketTitle(for: meta.startedAt, calendar: calendar, now: now)
            if buckets[title] == nil { buckets[title] = []; order.append(title) }
            buckets[title]?.append(meta)
        }
        return order.map { MeetingDateGroup(id: $0, title: $0, metas: buckets[$0] ?? []) }
    }

    private static func bucketTitle(for date: Date, calendar: Calendar, now: Date) -> String {
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        let startOfDate = calendar.startOfDay(for: date)
        let startOfNow = calendar.startOfDay(for: now)
        if let days = calendar.dateComponents([.day], from: startOfDate, to: startOfNow).day, days < 7 {
            return "Earlier this Week"
        }
        return date.formatted(.dateTime.month(.wide).year())
    }
}

// MARK: - Detail screen (reused Transcript/Summary views)

/// Routes an opened meeting between the live in-memory state (the just-stopped
/// session, so a summary can still stream in) and a saved record loaded from
/// disk. This is the interim detail — the redesigned detail replaces it later.
private struct MeetingDetailScreen: View {
    let id: UUID
    let initialTab: DetailTab
    let onClose: () -> Void
    @Environment(RecordingController.self) private var controller
    @State private var selectedTab: DetailTab

    init(id: UUID, initialTab: DetailTab, onClose: @escaping () -> Void) {
        self.id = id
        self.initialTab = initialTab
        self.onClose = onClose
        _selectedTab = State(initialValue: initialTab)
    }

    var body: some View {
        let library = controller.library
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button(action: onClose) {
                    Label("All Meetings", systemImage: "chevron.left")
                        .font(.body.weight(.medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tint)

                Divider().frame(height: 16)

                Text(library.meta(for: id)?.title ?? "Meeting")
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)

            Divider()

            if id == library.activeMeetingID {
                LiveMeetingDetail(selectedTab: $selectedTab)
            } else {
                PastMeetingDetail(id: id, selectedTab: $selectedTab)
                    .id(id)
            }
        }
        // Escape returns to the list.
        .onExitCommand(perform: onClose)
    }
}

/// The current session (or empty idle state): transcript with live partials and
/// the streaming/regenerable summary over `controller.state`.
private struct LiveMeetingDetail: View {
    @Environment(RecordingController.self) private var controller
    @Binding var selectedTab: DetailTab

    var body: some View {
        TabView(selection: $selectedTab) {
            TranscriptScroll(rows: transcriptRows, isRecording: controller.state.isRecording)
                .tabItem { Label("Transcript", systemImage: "text.bubble") }
                .tag(DetailTab.transcript)
            summary
                .tabItem { Label("Summary", systemImage: "sparkles") }
                .tag(DetailTab.summary)
        }
        .padding(.top, 8)
    }

    private var transcriptRows: [TranscriptDisplayRow] {
        let finalRows = controller.state.segments.map {
            TranscriptDisplayRow(segment: $0, isPartial: false)
        }
        let partialRows = controller.state.partialSegments.values.map {
            TranscriptDisplayRow(segment: $0, isPartial: true)
        }

        return (finalRows + partialRows).sorted {
            if $0.segment.start == $1.segment.start {
                return !$0.isPartial && $1.isPartial
            }
            return $0.segment.start < $1.segment.start
        }
    }

    @ViewBuilder
    private var summary: some View {
        switch controller.state.summaryState {
        case .idle:
            VStack(spacing: 18) {
                ContentUnavailableView(
                    controller.state.isRecording ? "Summary after recording" : "No summary yet",
                    systemImage: "sparkles",
                    description: Text(controller.state.isRecording
                        ? "Echo will generate this once the recording stops."
                        : "Start and stop a recording to generate meeting notes.")
                )
                summaryModelControl
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .generating:
            VStack(spacing: 12) {
                ProgressView()
                    .controlSize(.large)
                Text("Generating summary…")
                    .font(.headline)
                Text("Gemma is reading the final transcript locally.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .streaming(let meetingSummary):
            SummaryContentView(summary: meetingSummary, segments: controller.state.segments, isStreaming: true)

        case .ready(let meetingSummary):
            SummaryContentView(summary: meetingSummary, segments: controller.state.segments)

        case .unavailable(let message):
            ContentUnavailableView(
                message,
                systemImage: "text.badge.xmark",
                description: Text("There is no final transcript to summarize.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .failed(let message):
            VStack(spacing: 18) {
                ContentUnavailableView(
                    "Summary failed",
                    systemImage: "exclamationmark.triangle",
                    description: Text(message)
                )
                summaryModelControl
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var summaryModelControl: some View {
        HStack(spacing: 10) {
            Image(systemName: "cpu")
                .foregroundStyle(.secondary)
            Text(summaryModelDescription)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 300, alignment: .leading)

            if showsDownloadButton {
                Button {
                    Task { await controller.downloadSummaryModel() }
                } label: {
                    Label("Download model", systemImage: "arrow.down.circle")
                }
                .buttonStyle(.bordered)
                .disabled(controller.summaryModelState.isBusy)
            }

            if canRetrySummary {
                Button {
                    Task { await controller.retrySummary() }
                } label: {
                    Label("Retry", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderedProminent)
                .disabled(controller.summaryModelState.isBusy)
            }
        }
        .padding(.horizontal)
    }

    private var summaryModelDescription: String {
        switch controller.summaryModelState {
        case .notDownloaded:
            return "Summary model not downloaded"
        case .downloading(let fraction):
            return "Downloading summary model… \(Int(fraction * 100))%"
        case .loading:
            return "Loading summary model…"
        case .ready:
            return "Summary model ready · \(SummaryModelManager.modelDisplaySize)"
        case .failed(let message):
            return message
        }
    }

    private var showsDownloadButton: Bool {
        switch controller.summaryModelState {
        case .notDownloaded, .failed, .downloading:
            return true
        case .loading, .ready:
            return false
        }
    }

    private var canRetrySummary: Bool {
        !controller.state.isRecording && !controller.state.segments.isEmpty
    }
}

/// A saved meeting, read-only. Loads its `MeetingRecord` off the main thread
/// (the actor decodes) and shows the same transcript/summary views — no live
/// partials, and a fixed summary (or an "unavailable" state).
private struct PastMeetingDetail: View {
    let id: UUID
    @Binding var selectedTab: DetailTab
    @Environment(RecordingController.self) private var controller

    @State private var record: MeetingRecord?
    @State private var isLoading = true

    var body: some View {
        Group {
            if let record {
                TabView(selection: $selectedTab) {
                    TranscriptScroll(rows: rows(for: record), isRecording: false)
                        .tabItem { Label("Transcript", systemImage: "text.bubble") }
                        .tag(DetailTab.transcript)
                    summary(for: record)
                        .tabItem { Label("Summary", systemImage: "sparkles") }
                        .tag(DetailTab.summary)
                }
                .padding(.top, 8)
            } else if isLoading {
                ProgressView()
                    .controlSize(.large)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView(
                    "Couldn't open this meeting",
                    systemImage: "exclamationmark.triangle",
                    description: Text("Its files may be missing or corrupted.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: id) {
            isLoading = true
            record = await controller.library.loadRecord(id)
            isLoading = false
        }
    }

    private func rows(for record: MeetingRecord) -> [TranscriptDisplayRow] {
        record.segments.map { TranscriptDisplayRow(segment: $0, isPartial: false) }
    }

    @ViewBuilder
    private func summary(for record: MeetingRecord) -> some View {
        if let summary = record.summary {
            SummaryContentView(summary: summary, segments: record.segments)
        } else {
            ContentUnavailableView(
                "No summary",
                systemImage: "sparkles",
                description: Text("No summary was generated for this meeting.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: - Shared transcript list

private struct TranscriptScroll: View {
    let rows: [TranscriptDisplayRow]
    let isRecording: Bool

    var body: some View {
        if rows.isEmpty {
            ContentUnavailableView(
                isRecording ? "Listening…" : "No transcript",
                systemImage: "text.bubble",
                description: Text(isRecording
                    ? "Text will appear here as people speak."
                    : "This meeting has no transcript.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(rows) { row in
                        SegmentRow(segment: row.segment, isPartial: row.isPartial)
                    }
                }
                .padding()
            }
        }
    }
}

private struct TranscriptDisplayRow: Identifiable {
    let segment: TranscriptSegment
    let isPartial: Bool

    var id: String {
        isPartial ? "partial-\(segment.channel.rawValue)" : segment.id.uuidString
    }
}

private struct SegmentRow: View {
    let segment: TranscriptSegment
    var isPartial = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(isPartial ? accent.opacity(0.45) : accent)
                .frame(width: 8, height: 8)
                .padding(.top, 6)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(segment.speaker.displayName)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(accent)
                    Text(isPartial ? "Live" : timestamp)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Text(segment.text)
                    .font(.body)
                    .foregroundStyle(isPartial ? .secondary : .primary)
                    .opacity(isPartial ? 0.78 : 1)
                    .textSelection(.enabled)
            }
        }
    }

    private var accent: Color {
        segment.channel == .microphone ? .blue : .purple
    }

    private var timestamp: String {
        let total = Int(segment.start)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

private struct SummaryContentView: View {
    let summary: MeetingSummary
    let segments: [TranscriptSegment]
    var isStreaming: Bool = false

    private var segmentByID: [String: TranscriptSegment] {
        Dictionary(uniqueKeysWithValues: segments.map { ($0.id.uuidString.lowercased(), $0) })
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if isStreaming {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Generating summary…")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }

                // While streaming, only reveal blocks once they have content so
                // the layout fills in instead of flashing placeholders.
                if !isStreaming || !summary.shortSummary.isEmpty {
                    SummaryTextBlock(
                        title: "Short summary",
                        systemImage: "text.line.first.and.arrowtriangle.forward",
                        text: summary.shortSummary
                    )
                }

                if !isStreaming || !summary.detailedSummary.isEmpty {
                    SummaryTextBlock(
                        title: "Detailed summary",
                        systemImage: "doc.text",
                        text: summary.detailedSummary
                    )
                }

                if !isStreaming || !summary.decisions.isEmpty { decisionsSection }
                if !isStreaming || !summary.actionItems.isEmpty { actionItemsSection }
                if !isStreaming || !summary.openQuestions.isEmpty { openQuestionsSection }
                if !isStreaming || !summary.risks.isEmpty { risksSection }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var decisionsSection: some View {
        SummarySection(title: "Decisions", systemImage: "checkmark.seal") {
            if summary.decisions.isEmpty {
                EmptySummaryRow(text: "No decisions captured.")
            } else {
                ForEach(summary.decisions.indices, id: \.self) { index in
                    let decision = summary.decisions[index]
                    SummaryItemRow(
                        title: decision.title,
                        detail: decision.details,
                        metadata: evidenceText(decision.evidenceSegmentIDs)
                    )
                }
            }
        }
    }

    private var actionItemsSection: some View {
        SummarySection(title: "Action items", systemImage: "checklist") {
            if summary.actionItems.isEmpty {
                EmptySummaryRow(text: "No action items captured.")
            } else {
                ForEach(summary.actionItems.indices, id: \.self) { index in
                    let item = summary.actionItems[index]
                    SummaryItemRow(
                        title: item.task,
                        detail: actionItemDetail(item),
                        metadata: evidenceText(item.evidenceSegmentIDs)
                    )
                }
            }
        }
    }

    private var openQuestionsSection: some View {
        SummarySection(title: "Open questions", systemImage: "questionmark.circle") {
            if summary.openQuestions.isEmpty {
                EmptySummaryRow(text: "No open questions captured.")
            } else {
                ForEach(summary.openQuestions.indices, id: \.self) { index in
                    let question = summary.openQuestions[index]
                    SummaryItemRow(
                        title: question.question,
                        detail: question.context,
                        metadata: evidenceText(question.evidenceSegmentIDs)
                    )
                }
            }
        }
    }

    private var risksSection: some View {
        SummarySection(title: "Risks or blockers", systemImage: "exclamationmark.triangle") {
            if summary.risks.isEmpty {
                EmptySummaryRow(text: "No risks or blockers captured.")
            } else {
                ForEach(summary.risks.indices, id: \.self) { index in
                    let risk = summary.risks[index]
                    SummaryItemRow(
                        title: risk.risk,
                        detail: risk.details,
                        metadata: evidenceText(risk.evidenceSegmentIDs)
                    )
                }
            }
        }
    }

    private func actionItemDetail(_ item: SummaryActionItem) -> String? {
        var parts: [String] = []
        if let owner = item.owner, !owner.isEmpty {
            parts.append("Owner: \(owner)")
        }
        if let dueDate = item.dueDate, !dueDate.isEmpty {
            parts.append("Due: \(dueDate)")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func evidenceText(_ ids: [String]) -> String? {
        let times = ids
            .compactMap { segmentByID[$0.lowercased()]?.start }
            .map(Self.timestamp)
        guard !times.isEmpty else { return nil }
        return "Evidence: " + times.joined(separator: ", ")
    }

    nonisolated private static func timestamp(_ value: TimeInterval) -> String {
        let total = Int(value)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

private struct SummaryTextBlock: View {
    let title: String
    let systemImage: String
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: systemImage)
                .font(.headline)
            Text(text.isEmpty ? "Not available." : text)
                .font(.body)
                .textSelection(.enabled)
        }
    }
}

private struct SummarySection<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: systemImage)
                .font(.headline)
            VStack(alignment: .leading, spacing: 10) {
                content
            }
        }
    }
}

private struct SummaryItemRow: View {
    let title: String
    let detail: String?
    let metadata: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.body.weight(.medium))
                .textSelection(.enabled)
            if let detail, !detail.isEmpty {
                Text(detail)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            if let metadata {
                Text(metadata)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.leading, 4)
    }
}

private struct EmptySummaryRow: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.body)
            .foregroundStyle(.secondary)
    }
}
