//
//  DashboardView.swift
//  Echo
//
//  The full window opened from the menu bar. A meetings browser: the window
//  title bar hosts the breadcrumb (or, with a detail open, the meeting title
//  and back chevron), the REC pill while recording, and the New Recording /
//  Stop button; a sidebar (All Meetings / Trash + a storage footer); and a
//  searchable, sortable, date-grouped list of compact meeting rows with
//  working quick actions. Opening a meeting (or the pinned live row / REC
//  pill while recording) covers the list with the detail: an underlined
//  Transcript / AI Summary tab bar and the committed transcript. While
//  recording, the Transcript tab shows a calm "Recording" placeholder and a
//  footer with the popover's live waves — never transcript text (SP-007
//  final-only UX; the transcript is ready after the meeting ends).
//

import SwiftUI
#if DEBUG
import AppKit
import ScreenCaptureKit
#endif

private enum DetailTab: Hashable { case transcript, summary }

/// What the detail overlay is showing: the in-progress recording session, or a
/// saved meeting by id.
private enum DetailTarget: Hashable {
    case live
    case saved(UUID)
}

/// A detail the window has open, with the tab it should open on.
private struct OpenedDetail: Hashable {
    let target: DetailTarget
    var tab: DetailTab = .transcript
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

    /// The detail currently covering the list, if any. Lives on the shell so
    /// the window title bar can swap between the breadcrumb and the opened
    /// meeting's title (with its back chevron).
    @State private var opened: OpenedDetail?

    /// Drives the "can't start recording yet" dialog. Hosted here on the stable
    /// window (not the menu-bar popover, which would dismiss an alert as it
    /// closes) so both surfaces route through it; its CTA just closes the
    /// dialog, leaving the live download status visible in the banners behind.

    var body: some View {
        // A plain HStack instead of NavigationSplitView: on this macOS the
        // split view's columns carry a rigid AppKit fitting height of roughly
        // the screen (~1376pt) that no SwiftUI frame/ideal can override, so a
        // smaller window clips the top and bottom of both columns (blank
        // sidebar, list header pushed out of view). The mockup wants a plain
        // fixed sidebar anyway — no split-view chrome needed.
        HStack(spacing: 0) {
            LibrarySidebar(opened: $opened)
                .frame(width: 240)
            Divider()
            // No explicit background: the window's native contentBackground
            // material must show through. On macOS 26 that material carries a
            // wallpaper tint (CAChameleonLayer) that the title bar, sidebar,
            // and the List's own scroll background all render — an opaque
            // color here covers it only under the list header, which then
            // reads as a mismatched band in dark mode.
            MeetingLibraryDetail(opened: $opened)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(
            minWidth: 900, idealWidth: 1100, maxWidth: .infinity,
            minHeight: 560, idealHeight: 720, maxHeight: .infinity
        )
        .navigationTitle("")
        // Opening the window is a natural catch-up point: any meeting still
        // missing its summary starts processing in view (row pill flips to
        // "Processing"). `onAppear` + the controller's fire-and-forget kick —
        // NOT `.task` — so closing the window mid-run can't cancel a
        // generation halfway through.
        .onAppear {
            controller.kickSummaryBackfill()
            consumePendingLiveDetailOpen()
            // The menu bar opens this window on a gated press; the notice was
            // set before the window existed, so onChange can't catch it —
            // consume it here as the window appears.
        }
        // The window may already be open when the menu bar's Stop asks for the
        // live detail — onAppear won't re-fire then, so follow the flag too.
        .onChange(of: controller.pendingLiveDetailOpen) { _, pending in
            if pending { consumePendingLiveDetailOpen() }
        }
        #if DEBUG
        // Dev-only verification loop: with ECHO_SNAPSHOT_PATH set (and the
        // window auto-opened via ECHO_OPEN_DASHBOARD, see EchoApp), renders
        // this window to PNG every 2 s so UI work can be inspected from the
        // CLI without screen-recording permission. Inert in normal runs.
        .task {
            // ECHO_OPEN_SETTINGS=1 (+ ECHO_SETTINGS_PROBE=path): fire the app
            // menu's own "Settings…" item from the CLI, then dump what it did
            // — the item's shortcut, the section the library landed on, the
            // window census, and the activation policy — and quit. It used to
            // call `openSettings()` and check which window appeared; with the
            // native Settings scene gone, Cmd-, must instead select the
            // dashboard's Settings page and open no second window, and this
            // exercises that whole chain rather than the destination alone.
            if ProcessInfo.processInfo.environment["ECHO_OPEN_SETTINGS"] == "1" {
                try? await Task.sleep(for: .seconds(1))
                var invoked: [String] = []
                if let appMenu = NSApp.mainMenu?.items.first?.submenu,
                   let index = appMenu.items.firstIndex(where: { $0.title.hasPrefix("Settings") }) {
                    let item = appMenu.items[index]
                    invoked.append("item=\"\(item.title)\" key=\"\(item.keyEquivalent)\" cmd=\(item.keyEquivalentModifierMask.contains(.command))")
                    appMenu.performActionForItem(at: index)
                } else {
                    invoked.append("item=MISSING")
                }
                try? await Task.sleep(for: .seconds(2))
                if let probePath = ProcessInfo.processInfo.environment["ECHO_SETTINGS_PROBE"] {
                    let lines = invoked
                        + ["section=\(controller.library.section)"]
                        + NSApp.windows.map {
                            "id=\($0.identifier?.rawValue ?? "nil") title=\($0.title) visible=\($0.isVisible) class=\(type(of: $0))"
                        }
                        + ["policy=\(NSApp.activationPolicy().rawValue)"]
                    try? lines.joined(separator: "\n")
                        .write(toFile: probePath, atomically: true, encoding: .utf8)
                    NSApp.terminate(nil)
                }
            }
            guard let path = ProcessInfo.processInfo.environment["ECHO_SNAPSHOT_PATH"] else { return }
            // ECHO_APPEARANCE=dark|light forces the app-wide appearance so
            // dark-mode rendering can be verified regardless of the system
            // setting. Verification mode only.
            if let forced = ProcessInfo.processInfo.environment["ECHO_APPEARANCE"] {
                NSApp.appearance = NSAppearance(named: forced == "dark" ? .darkAqua : .aqua)
            }
            // ECHO_DUMP_ONESHOT=1: activate the window (so scroll-edge
            // effects and toolbar chrome are in their real, focused state),
            // capture once via ScreenCaptureKit (real pixels; works because
            // Echo already holds a capture entitlement for system audio),
            // write the dumps, and quit. Avoids stealing the user's focus
            // every 2 s like the recurring loop would.
            let oneShot = ProcessInfo.processInfo.environment["ECHO_DUMP_ONESHOT"] == "1"
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard let window = NSApp.windows.first(where: { $0.identifier?.rawValue == EchoWindow.dashboard }),
                      let frameView = window.contentView?.superview,
                      let rep = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds)
                else { continue }
                if oneShot {
                    NSApp.activate(ignoringOtherApps: true)
                    window.makeKeyAndOrderFront(nil)
                    // The dump is only meaningful once the meeting list has
                    // loaded (the List doesn't exist in the empty state).
                    for _ in 0..<20 where controller.library.metas.isEmpty {
                        try? await Task.sleep(for: .milliseconds(500))
                    }
                    try? await Task.sleep(for: .milliseconds(1200))
                    do {
                        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                        if let scWindow = content.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) }) {
                            let filter = SCContentFilter(desktopIndependentWindow: scWindow)
                            let config = SCStreamConfiguration()
                            let scale = window.backingScaleFactor
                            config.width = Int(window.frame.width * scale)
                            config.height = Int(window.frame.height * scale)
                            config.showsCursor = false
                            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                            let pngRep = NSBitmapImageRep(cgImage: image)
                            if let data = pngRep.representation(using: .png, properties: [:]) {
                                try? data.write(to: URL(fileURLWithPath: path.replacingOccurrences(of: ".png", with: "-sck.png")))
                            }
                        }
                    } catch {
                        try? "SCK capture failed: \(error)".write(
                            toFile: path.replacingOccurrences(of: ".png", with: "-sck-error.txt"),
                            atomically: true, encoding: .utf8)
                    }
                }
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
                // Third verification path: dump the layer tree's background
                // colors. When neither pixel capture path composites the
                // SwiftUI content (occluded window, locked screen), this still
                // answers "which layer paints which color where".
                do {
                    var lines: [String] = []
                    func hex(_ color: NSColor?) -> String {
                        guard let srgb = color?.usingColorSpace(.sRGB) else { return "nil" }
                        return String(format: "#%02X%02X%02X a=%.2f",
                                      Int(srgb.redComponent * 255), Int(srgb.greenComponent * 255),
                                      Int(srgb.blueComponent * 255), srgb.alphaComponent)
                    }
                    func walk(_ view: NSView, depth: Int) {
                        var desc = String(repeating: "  ", count: depth) + "\(type(of: view))"
                        let f = view.convert(view.bounds, to: nil)
                        desc += String(format: " (%.0f,%.0f %.0fx%.0f)", f.origin.x, f.origin.y, f.width, f.height)
                        view.effectiveAppearance.performAsCurrentDrawingAppearance {
                            if let scroll = view as? NSScrollView {
                                desc += " drawsBG=\(scroll.drawsBackground) bg=\(hex(scroll.backgroundColor))"
                            }
                            if let table = view as? NSTableView {
                                desc += " tableBG=\(hex(table.backgroundColor)) style=\(table.style.rawValue)"
                            }
                            if let clip = view as? NSClipView {
                                desc += " clipDrawsBG=\(clip.drawsBackground) bg=\(hex(clip.backgroundColor))"
                            }
                            if let effect = view as? NSVisualEffectView {
                                desc += " material=\(effect.material.rawValue) blend=\(effect.blendingMode.rawValue)"
                            }
                            if let bg = view.layer?.backgroundColor, bg.alpha > 0 {
                                desc += " layerBG=\(hex(NSColor(cgColor: bg)))"
                            }
                        }
                        if view.isHidden { desc += " hidden" }
                        lines.append(desc)
                        for sub in view.subviews { walk(sub, depth: depth + 1) }
                    }
                    walk(frameView, depth: 0)
                    try? lines.joined(separator: "\n")
                        .write(toFile: path.replacingOccurrences(of: ".png", with: "-views.txt"),
                               atomically: true, encoding: .utf8)
                    // Companion dump of the CALayer tree: SwiftUI paints into
                    // layers with no NSView counterpart, so only this shows
                    // the opaque backgrounds the view walk can't see.
                    if let root = frameView.layer {
                        var layerLines: [String] = []
                        func walkLayer(_ layer: CALayer, depth: Int) {
                            var desc = String(repeating: "  ", count: depth) + "\(type(of: layer))"
                            if let d = layer.delegate { desc += "/\(type(of: d))" }
                            let f = layer.convert(layer.bounds, to: root)
                            desc += String(format: " (%.0f,%.0f %.0fx%.0f)", f.origin.x, f.origin.y, f.width, f.height)
                            if let bg = layer.backgroundColor, bg.alpha > 0 {
                                desc += " bg=\(hex(NSColor(cgColor: bg)))"
                            }
                            if layer.contents != nil { desc += " has-contents" }
                            if let filter = layer.compositingFilter { desc += " filter=\(filter)" }
                            if layer.opacity < 1 { desc += String(format: " opacity=%.2f", layer.opacity) }
                            if layer.isHidden { desc += " hidden" }
                            layerLines.append(desc)
                            for sub in layer.sublayers ?? [] { walkLayer(sub, depth: depth + 1) }
                        }
                        walkLayer(root, depth: 0)
                        try? layerLines.joined(separator: "\n")
                            .write(toFile: path.replacingOccurrences(of: ".png", with: "-layers.txt"),
                                   atomically: true, encoding: .utf8)
                    }
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
                if oneShot { NSApp.terminate(nil) }
            }
        }
        #endif
        .toolbar {
            // The window's native title bar hosts the top bar (breadcrumb or
            // the opened meeting's title on the left, plus the REC pill while
            // recording; New Recording / Stop on the right), so the window
            // stays draggable and respects the header.
            // Flat leading content: no glass platter behind it — it should
            // blend into the title bar, not read as a raised control.
            if #available(macOS 26.0, *) {
                ToolbarItem(placement: .navigation) { topBarLeading }
                    .sharedBackgroundVisibility(.hidden)
            } else {
                ToolbarItem(placement: .navigation) { topBarLeading }
            }
            ToolbarItem(placement: .primaryAction) {
                RecordToolbarButton { opened = OpenedDetail(target: .live) }
            }
        }
    }

    private var topBarLeading: some View {
        HStack(spacing: 8) {
            if opened != nil {
                Button {
                    opened = nil
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Back to all meetings")

                MeetingGlyph(size: 20)
                Text(openedTitle)
                    .font(.headline)
                    .lineLimit(1)

                // SP-008 scope chip (resolved open question 5): a scoped
                // meeting's detail says so right next to its title — the
                // detail's meta lives up here since the redesign, so this
                // *is* its meta row. Quiet capsule (the meetings-count
                // badge's register, not the red REC pill's): the scope is
                // provenance, not an alert. No chip means full coverage —
                // Everything sessions and pre-SP-008 meetings render nothing.
                if let scopeLabel = openedScopeLabel {
                    Text(scopeLabel)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(.quaternary, in: Capsule())
                        .help("System audio was captured from this app only")
                }
            } else {
                MeetingGlyph(size: 20)
                Text("Echo").font(.headline)
                Text("/").foregroundStyle(.tertiary)
                Text(sectionTitle)
                    .font(.headline)
                    .foregroundStyle(.secondary)
            }

            // Global recording indicator: visible in both the list and any
            // open detail, only while a session is running. Clicking it jumps
            // to the live meeting.
            if controller.state.isRecording {
                RecPill { opened = OpenedDetail(target: .live) }
            }
        }
    }

    private var sectionTitle: String {
        switch controller.library.section {
        case .all: return "Meetings"
        case .trash: return "Trash"
        case .settings: return "Settings"
        }
    }

    private var openedTitle: String {
        switch opened?.target {
        case .saved(let id):
            return controller.library.meta(for: id)?.title ?? "Meeting"
        case .live:
            return liveMeetingTitle(controller)
        case nil:
            return ""
        }
    }

    /// The opened detail's scope chip label: "Zoom only" for a scoped
    /// meeting; `nil` — no chip — for everything sessions, pre-SP-008
    /// meetings, and unknown future kinds (absence means full coverage,
    /// ADR-027). `scopedDisplayLabel` already encodes exactly that rule,
    /// so this only routes the opened target to its persisted meta.
    private var openedScopeLabel: String? {
        switch opened?.target {
        case .saved(let id):
            return controller.library.meta(for: id)?.captureScope?.scopedDisplayLabel
        case .live:
            // The live target has no meta until the stop-save lands; while
            // recording the pinned live row (and menu bar) carry the scope,
            // and the chip appears here the moment the meeting persists.
            return controller.library.activeMeetingID.flatMap {
                controller.library.meta(for: $0)?.captureScope?.scopedDisplayLabel
            }
        case nil:
            return nil
        }
    }

    /// Honors the menu bar Stop's one-shot request to land inside the
    /// just-stopped meeting. Opens on the AI Summary tab when the summary
    /// already finished; otherwise the detail switches itself on completion.
    private func consumePendingLiveDetailOpen() {
        guard controller.pendingLiveDetailOpen else { return }
        controller.pendingLiveDetailOpen = false
        let summaryDone: Bool
        if case .ready = controller.state.summaryState { summaryDone = true } else { summaryDone = false }
        opened = OpenedDetail(target: .live, tab: summaryDone ? .summary : .transcript)
    }

}

/// The display title for the in-progress session: the auto title it will be
/// saved under while recording, or — once stopped and persisted — the saved
/// meeting's title.
@MainActor
private func liveMeetingTitle(_ controller: RecordingController) -> String {
    if let startedAt = controller.state.startedAt {
        return MeetingMeta.autoTitle(startedAt: startedAt)
    }
    if let active = controller.library.activeMeetingID,
       let meta = controller.library.meta(for: active) {
        return meta.title
    }
    return "New Recording"
}

/// The red "● REC 00:24:18" capsule in the title bar. Ticks once a second and
/// opens the live meeting detail when clicked.
private struct RecPill: View {
    @Environment(RecordingController.self) private var controller
    let action: () -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            Button(action: action) {
                HStack(spacing: 6) {
                    Circle().fill(.red).frame(width: 7, height: 7)
                    Text("REC")
                        .font(.caption.weight(.bold))
                    Text(recTimerString(controller.state.elapsed))
                        .font(.caption.weight(.medium).monospacedDigit())
                }
                .foregroundStyle(.red)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Color.red.opacity(0.12), in: Capsule())
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .help("Open the live meeting")
        }
    }
}

private func recTimerString(_ interval: TimeInterval) -> String {
    let total = max(0, Int(interval))
    return String(format: "%02d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
}

/// Start/stop toggle in the window toolbar. Mirrors the menu bar control: New
/// Recording starts a session (and opens the live detail); while recording it
/// becomes a red Stop button, and stopping lands the new meeting in the list.
private struct RecordToolbarButton: View {
    @Environment(RecordingController.self) private var controller
    /// Called when a session actually started, so the window can jump to the
    /// live meeting detail.
    let onStart: () -> Void

    var body: some View {
        let isRecording = controller.state.isRecording
        Button {
            Task {
                let wasRecording = controller.state.isRecording
                await controller.toggle()
                // A press blocked on a not-ready speech model sets the
                // controller's one-shot gate notice; the DashboardView shell
                // observes it and raises the "can't record yet" dialog.
                if !wasRecording && controller.state.isRecording { onStart() }
            }
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
    @Binding var opened: OpenedDetail?

    var body: some View {
        let library = controller.library

        // Custom rows instead of List: a List in this sidebar column renders
        // no rows at all on this macOS (verified via the view-tree dump — the
        // outline view materializes zero row views even for plain Texts).
        // Custom rows also match the mockup's look more closely.
        // Clicking a section always lands on its list, so any open detail
        // closes even when the section itself doesn't change.
        VStack(alignment: .leading, spacing: 4) {
            SidebarRow(
                title: "All Meetings",
                systemImage: "square.stack.3d.up.fill",
                count: library.metas.count,
                isSelected: library.section == .all
            ) {
                library.section = .all
                opened = nil
            }

            SidebarRow(
                title: "Trash",
                systemImage: "trash",
                count: library.trashedMetas.count,
                isSelected: library.section == .trash
            ) {
                library.section = .trash
                opened = nil
            }

            SidebarRow(
                title: "Settings",
                systemImage: "gear",
                count: nil,
                isSelected: library.section == .settings
            ) {
                library.section = .settings
                opened = nil
            }

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
            // So internal testers can see at a glance which build they run.
            Text(AppVersion.display)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 10)
    }

    private var storageText: String {
        guard let bytes = controller.library.storageBytes else { return "Calculating…" }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) + " used"
    }
}

/// One selectable sidebar row: icon + title + trailing count (`nil` hides
/// the badge — the Settings row has nothing to count), with the selected
/// state drawn as a tinted rounded rectangle (as in the mockup).
private struct SidebarRow: View {
    let title: String
    let systemImage: String
    let count: Int?
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
                if let count {
                    Text("\(count)")
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(isSelected ? Color.echoIndigo : .secondary)
                }
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

/// Hosts the right pane: the list for the current section is the root, and
/// opening a meeting covers it with the detail.
private struct MeetingLibraryDetail: View {
    @Environment(RecordingController.self) private var controller
    @Binding var opened: OpenedDetail?

    var body: some View {
        let library = controller.library
        Group {
            switch library.section {
            case .all:
                AllMeetingsView(opened: $opened)
            case .trash:
                TrashView(opened: $opened)
            case .settings:
                SettingsPageView()
            }
        }
        // Opening a meeting shows the detail as a full-cover overlay (its back
        // affordance lives in the window title bar) rather than a pushed
        // NavigationStack view, so it never contends with the window toolbar.
        // Opaque background so it fully covers the list.
        .overlay {
            if let detail = opened {
                MeetingDetailScreen(target: detail.target, initialTab: detail.tab) { opened = nil }
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
    @Binding var opened: OpenedDetail?

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
            // Renders only while a model is downloading/loading/failed, so
            // "what is the app doing" is answered here instead of behind a
            // vague status line. Carries its own padding: when hidden it must
            // contribute zero height, and padding a collapsed conditional
            // would still take up space.
            ModelStatusBanner()
            // The in-progress session has no saved row yet (it persists on
            // stop), so while recording a pinned live row sits above the list
            // and opens the live detail.
            if controller.state.isRecording {
                LiveMeetingRow { opened = OpenedDetail(target: .live) }
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
            opened = OpenedDetail(target: .saved(selection))
            return .handled
        }
    }

    private func rows(for metas: [MeetingMeta]) -> some View {
        ForEach(metas) { meta in
            MeetingRow(
                meta: meta,
                isActive: meta.id == controller.library.activeMeetingID,
                isBackfilling: meta.id == controller.backfillingMeetingID,
                summaryState: controller.state.summaryState,
                onOpen: { tab in opened = OpenedDetail(target: .saved(meta.id), tab: tab) },
                onRename: {
                    renameTarget = meta
                    renameText = meta.title
                }
            )
            .tag(meta.id)
            .listRowInsets(EdgeInsets(top: 4, leading: 20, bottom: 4, trailing: 20))
            .simultaneousGesture(TapGesture(count: 2).onEnded {
                opened = OpenedDetail(target: .saved(meta.id))
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
    @Binding var opened: OpenedDetail?

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
                        onOpen: { opened = OpenedDetail(target: .saved(meta.id)) },
                        onRestore: { Task { await controller.library.restore(meta.id) } },
                        onDelete: { confirmDelete = meta }
                    )
                    .tag(meta.id)
                    .listRowInsets(EdgeInsets(top: 4, leading: 20, bottom: 4, trailing: 20))
                    .simultaneousGesture(TapGesture(count: 2).onEnded {
                        opened = OpenedDetail(target: .saved(meta.id))
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

// MARK: - Settings (embedded host)

/// The dashboard's Settings page — since the native `Settings` scene was
/// dropped, the only host of `SettingsView`, reached from the sidebar row and
/// from Cmd-, . Header matches the Meetings/Trash panes.
private struct SettingsPageView: View {
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text("Settings")
                    .font(.title2.bold())
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 12)

            SettingsView()
                .frame(maxWidth: 720)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
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
    let isBackfilling: Bool
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

            StatusPill(
                meta: meta,
                isActive: isActive,
                isBackfilling: isBackfilling,
                summaryState: summaryState,
                finalization: finalizationStatus
            )

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

    /// This meeting's finalization face for the row pill, from the same pure
    /// function as the details (SP-007 S6) — the pill renders a subset (no
    /// Retry, so the retained-audio probe is skipped; a draft reads the same
    /// either way), never a re-derivation.
    private var finalizationStatus: StatusPill.Finalization? {
        switch meetingDisplayState(for: meta.id, controller: controller) {
        case .transcribing(let fraction): return .finalizing(fraction)
        case .waiting: return .waiting
        case .failed: return .failed
        case .draft: return .draft
        case .recording, .final: return nil
        }
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

/// The pinned row shown above the list while a recording is running: the
/// session's auto title, a ticking elapsed/word-count line, and a red
/// "Recording" badge. Clicking anywhere opens the live detail.
private struct LiveMeetingRow: View {
    @Environment(RecordingController.self) private var controller
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 12) {
                MeetingGlyph(size: 34)

                VStack(alignment: .leading, spacing: 2) {
                    Text(liveMeetingTitle(controller))
                        .font(.body.weight(.semibold))
                        .lineLimit(1)
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        Text(metadataText)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer(minLength: 12)

                HStack(spacing: 4) {
                    Circle().fill(.red).frame(width: 7, height: 7)
                    Text("Recording")
                }
                .font(.caption.weight(.medium))
                .foregroundStyle(.red)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color.red.opacity(0.12), in: Capsule())
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.red.opacity(0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.red.opacity(0.15))
            )
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .help("Open the live meeting")
    }

    private var metadataText: String {
        // No transcript-derived number while recording: nothing is
        // transcribed until the meeting stops. The word count reappears from
        // `meta.wordCount` once the pass writes the transcript.
        var text = recTimerString(controller.state.elapsed)
        // SP-008: a scoped session says so right on the row ("Zoom only") —
        // `captureScope` reflects the effective scope after any fallback, so
        // this never overstates the narrowing. A global session renders
        // exactly as today: the row's red badge already says it's recording,
        // and "Everything" here would add words without information.
        if let scope = controller.state.captureScope, scope.scopedApp != nil {
            text += "  ·  \(scope.indicatorLabel)"
        }
        return text
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
    /// The row's finalization face: a running pass with its honest fraction,
    /// a queued/deferred/pending pass waiting its turn, a terminally failed
    /// meeting, or a legacy draft (persisted `liveFloor` provenance).
    enum Finalization: Equatable {
        case finalizing(Double?)
        case waiting
        case failed
        case draft
    }

    let meta: MeetingMeta
    let isActive: Bool
    let isBackfilling: Bool
    let summaryState: SummaryState
    var finalization: Finalization? = nil

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
        // Finalization first: while a pass runs (or waits) the meeting has no
        // summary yet, and "Finalizing" is the honest answer to "what is Echo
        // doing with this meeting right now" (SP-005 S6).
        switch finalization {
        case .finalizing(let fraction):
            let percent = ModelDownloadProgress(fraction: fraction ?? 0).percent
            return ("Finalizing \(percent)%", .echoIndigo, "clock", true)
        case .waiting:
            return ("Waiting to finalize", .secondary, "clock", false)
        case .failed:
            // Persistent, like the detail's face: keyed on persisted
            // provenance, and it outranks every summary state below (a
            // meeting with no transcript has nothing to summarize).
            return ("Transcription failed", .red, "exclamationmark.triangle", false)
        case .draft:
            // Persistent, like the detail's badge: it keys on persisted
            // provenance and outranks the summary states below (a draft's
            // summary is a draft's summary).
            return ("Draft", .orange, "doc.text", false)
        case nil:
            break
        }
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
        // The launch backfill is summarizing this meeting right now.
        if isBackfilling {
            return ("Processing", .orange, "clock", true)
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

// MARK: - AI models banner

/// Status card for the two on-device models: which model, what it's for, and
/// what it's doing right now — live download progress, loading, ready, or a
/// failure with its retry. Renders nothing once both models are ready: the
/// steady state needs no chrome.
private struct ModelStatusBanner: View {
    @Environment(RecordingController.self) private var controller

    var body: some View {
        if needsAttention {
            VStack(alignment: .leading, spacing: 10) {
                row(
                    icon: "waveform",
                    name: "Transcription · \(ParakeetModelManager.modelDisplayName) · \(ParakeetModelManager.modelDisplaySize)",
                    // CC-BY-4.0 attribution rides with the model's name — the
                    // one surface that names it.
                    purpose: "Transcribes each meeting after it ends · \(ParakeetModelManager.attribution)"
                ) { transcriptionStatus }
                Divider()
                row(
                    icon: "sparkles",
                    name: "Summary · \(SummaryModelManager.modelDisplayName) · \(SummaryModelManager.modelDisplaySize)",
                    purpose: "Writes the meeting notes after each recording"
                ) { summaryStatus }
            }
            .padding(12)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .padding(.horizontal, 20)
            .padding(.bottom, 8)
        }
    }

    /// Both models ready → the banner disappears entirely.
    private var needsAttention: Bool {
        if case .ready = controller.parakeetModelState,
           case .ready = controller.summaryModelState {
            return false
        }
        return true
    }

    @ViewBuilder
    private var transcriptionStatus: some View {
        switch controller.parakeetModelState {
        case .absent:
            // Queued behind the launch sequence; the fetch starts on its own.
            Text("Waiting to download")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .downloading(let fraction):
            downloadProgress(fraction)
        case .ready:
            readyLabel
        case .failed(let message):
            // No Retry button: acquisition is once per launch by design (the
            // manager resumes the transfer on the next launch, skipping the
            // files already on disk), and recording never depends on it.
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
                .lineLimit(2)
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: 280, alignment: .trailing)
        }
    }

    private func row(
        icon: String,
        name: String,
        purpose: String,
        @ViewBuilder trailing: () -> some View
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(Color.echoIndigo)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(name)
                    .font(.callout.weight(.semibold))
                Text(purpose)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            trailing()
        }
    }

    @ViewBuilder
    private var summaryStatus: some View {
        switch controller.summaryModelState {
        case .notDownloaded:
            downloadButton("Download")
        case .partiallyDownloaded:
            // No "X of Y on disk" here: the resumable partial's byte count is
            // untrustworthy for display (staging can exceed the total — ADR-007).
            // The Resume action is the whole affordance; it skips what's on disk.
            HStack(spacing: 8) {
                Text("Download incomplete")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                downloadButton("Resume download")
            }
        case .paused:
            // The user paused this download (SP-003 US-10): Resume clears the
            // persisted intent and picks up where it left off, skipping the
            // shards already on disk.
            HStack(spacing: 8) {
                Text("Paused")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                resumeButton
            }
        case .downloading(let fraction):
            // A Pause control rides alongside the live progress (SP-003 US-10).
            HStack(spacing: 8) {
                downloadProgress(fraction)
                pauseButton
            }
        case .loading:
            loadingIndicator
        case .ready:
            readyLabel
        case .failed(let message):
            failure(message) {
                Task { await controller.downloadSummaryModel() }
            }
        }
    }

    private var pauseButton: some View {
        Button {
            Task { await controller.pauseSummaryDownload() }
        } label: {
            Label("Pause", systemImage: "pause.circle")
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    private var resumeButton: some View {
        Button {
            Task { await controller.resumeSummaryDownload() }
        } label: {
            Label("Resume download", systemImage: "arrow.down.circle")
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    // MARK: Shared status elements

    private func downloadProgress(_ fraction: Double) -> some View {
        // Single honest source for both the bar and the number (ADR-007): the
        // clamped fraction can't drive the bar past full, and the percent can't
        // read over 100. Shared by the speech and summary rows.
        let progress = ModelDownloadProgress(fraction: fraction)
        return HStack(spacing: 8) {
            ProgressView(value: progress.fraction)
                .frame(width: 140)
            Text("\(progress.percent)%")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    private var loadingIndicator: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text("Loading…")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var readyLabel: some View {
        Label("Ready", systemImage: "checkmark.circle.fill")
            .font(.caption.weight(.medium))
            .foregroundStyle(.green)
    }

    private func failure(_ message: String, retry: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
                .lineLimit(2)
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: 280, alignment: .trailing)
            Button("Retry", action: retry)
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
    }

    private func downloadButton(_ title: String) -> some View {
        Button {
            Task { await controller.downloadSummaryModel() }
        } label: {
            Label(title, systemImage: "arrow.down.circle")
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
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

/// Routes an opened detail between the live in-memory state (the running or
/// just-stopped session, so partials render in the footer and a summary can
/// still stream in) and a saved record loaded from disk. Chrome per the
/// redesign: an underlined Transcript / AI Summary tab bar at the top (the
/// title and back affordance live in the window title bar) and, while
/// recording, the live-transcription footer at the bottom.
private struct MeetingDetailScreen: View {
    let target: DetailTarget
    let initialTab: DetailTab
    let onClose: () -> Void
    @Environment(RecordingController.self) private var controller
    @State private var selectedTab: DetailTab

    init(target: DetailTarget, initialTab: DetailTab, onClose: @escaping () -> Void) {
        self.target = target
        self.initialTab = initialTab
        self.onClose = onClose
        _selectedTab = State(initialValue: initialTab)
    }

    var body: some View {
        let library = controller.library
        VStack(spacing: 0) {
            DetailTabBar(selection: $selectedTab)

            // The saved-recording strip (settings-page retention §3.4):
            // exists exactly while the meeting's folder holds preserved
            // audio; renders nothing otherwise. The live target maps to the
            // just-stopped meeting once its stop-save lands.
            if let recordingMeetingID {
                PreservedRecordingBar(meetingID: recordingMeetingID)
                    .id(recordingMeetingID)
            }

            switch target {
            case .live:
                LiveMeetingDetail(selectedTab: $selectedTab)
            case .saved(let id):
                // A saved meeting that is still "active" is the just-stopped
                // session: keep it on the live state so its summary streams in.
                if id == library.activeMeetingID {
                    LiveMeetingDetail(selectedTab: $selectedTab)
                } else {
                    PastMeetingDetail(id: id, selectedTab: $selectedTab)
                        .id(id)
                }
            }
        }
        // Escape returns to the list.
        .onExitCommand(perform: onClose)
    }

    private var recordingMeetingID: UUID? {
        switch target {
        case .saved(let id): return id
        case .live: return controller.library.activeMeetingID
        }
    }
}

// MARK: - Meeting display state (SP-007 S6)

/// The ONE assembler behind every meeting face: snapshots the coordinator's
/// sync observables and the meta's persisted provenance into the pure
/// `MeetingDisplayState.resolve` inputs. `hasRetainedAudio` is the only
/// async input — surfaces that render Retry probe it (`MeetingTranscriptFace`);
/// the list pill and summary checks pass `false`, which only narrows
/// draft-with-Retry to draft-without (a subset, same function).
@MainActor
private func meetingDisplayState(
    for meetingID: UUID?,
    controller: RecordingController,
    isLiveTarget: Bool = false,
    hasRetainedAudio: Bool = false
) -> MeetingDisplayState {
    let finalization = controller.finalization
    return MeetingDisplayState.resolve(MeetingDisplaySnapshot(
        isRecordingThisMeeting: isLiveTarget && controller.state.isRecording,
        isRecordingActive: controller.state.isRecording,
        isPassRunning: meetingID != nil && finalization.currentMeetingID == meetingID,
        isQueued: meetingID.map { finalization.queuedMeetingIDs.contains($0) } ?? false,
        progressFraction: finalization.finalizationProgress,
        transcriptSource: meetingID.flatMap {
            controller.library.meta(for: $0)?.transcriptProvenance?.source
        },
        hasRetainedAudio: hasRetainedAudio
    ))
}

/// The Transcript tab's whole face, for both details (SP-007 S6): exactly one
/// of recording / waiting / transcribing / draft / final, from the pure
/// display-state function. Transcript text renders only in `draft` and
/// `final` — while a pass runs or waits the user reads the honest state
/// instead (SP-005's read-during-the-pass story is deliberately retired).
private struct MeetingTranscriptFace: View {
    /// The saved meeting (nil only for the live target before its stop-save).
    let meetingID: UUID?
    /// This face fronts the live in-memory session (the recording, or the
    /// just-stopped meeting whose segments are still `controller.state`).
    var isLiveTarget = false
    let segments: [TranscriptSegment]
    @Environment(RecordingController.self) private var controller

    /// The async input of the snapshot: probed on appear and re-probed when
    /// the pass lifecycle or the persisted provenance moves (`probeKey`).
    @State private var hasRetainedAudio = false
    @State private var confirmKeepDraft = false

    var body: some View {
        Group {
            switch displayState {
            case .recording:
                ContentUnavailableView(
                    "Recording",
                    systemImage: "waveform",
                    description: Text("Echo is capturing and transcribing locally. The transcript will be ready after the meeting ends.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            case .waiting:
                // Honest waiting — never a bar, never a fake percentage.
                ContentUnavailableView(
                    "Waiting to finalize",
                    systemImage: "clock",
                    description: Text(controller.state.isRecording
                        ? "The transcript will be finalized after the current recording stops."
                        : "This meeting's transcript will be finalized shortly.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            case .transcribing(let fraction):
                transcribing(fraction: fraction)

            case .failed(let retryAvailable):
                // No transcript exists — an empty transcript shell would read
                // as "the meeting had no words" instead of "we couldn't
                // transcribe it".
                failedFace(retryAvailable: retryAvailable)

            case .draft(let retryAvailable):
                VStack(spacing: 0) {
                    draftStrip(retryAvailable: retryAvailable)
                    TranscriptScroll(segments: segments)
                }

            case .final:
                TranscriptScroll(segments: segments)
            }
        }
        .task(id: probeKey) {
            guard let meetingID else {
                hasRetainedAudio = false
                return
            }
            hasRetainedAudio = await controller.library.hasRetainedAudio(for: meetingID)
        }
        // ADR-024: releasing the audio is irreversible — confirm it.
        .confirmationDialog("Keep draft?", isPresented: $confirmKeepDraft) {
            Button("Keep Draft") { keepDraft() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The meeting's audio will be deleted and this draft becomes the final transcript. This can't be undone.")
        }
    }

    private var displayState: MeetingDisplayState {
        meetingDisplayState(
            for: meetingID,
            controller: controller,
            isLiveTarget: isLiveTarget,
            hasRetainedAudio: hasRetainedAudio
        )
    }

    /// Re-probes the retained audio when a pass starts/ends (success deletes
    /// it) or the persisted provenance lands (convergence keeps it). Keep
    /// draft refreshes locally in `keepDraft()` — it changes no meta.
    private struct ProbeKey: Equatable {
        let meetingID: UUID?
        let runningMeetingID: UUID?
        let source: TranscriptProvenance.Source?
    }

    private var probeKey: ProbeKey {
        ProbeKey(
            meetingID: meetingID,
            runningMeetingID: controller.finalization.currentMeetingID,
            source: meetingID.flatMap {
                controller.library.meta(for: $0)?.transcriptProvenance?.source
            }
        )
    }

    private func transcribing(fraction: Double) -> some View {
        let progress = ModelDownloadProgress(fraction: fraction)
        return VStack(spacing: 12) {
            ProgressView(value: progress.fraction)
                .frame(maxWidth: 280)
            Text("Finalizing transcript… \(progress.percent)%")
                .font(.headline)
            Text(controller.finalization.currentPassUsesFallbackModel
                ? "Re-transcribing the meeting with full context, using the standard model for this pass."
                : "Re-transcribing the meeting with full context.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal, 40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The honest terminal-failure face: the meeting's audio is kept and the
    /// user decides — Retry (a fresh bounded cycle from that audio) or Delete
    /// from the meeting's own menu. No Keep action: there is no text to keep.
    @ViewBuilder
    private func failedFace(retryAvailable: Bool) -> some View {
        VStack(spacing: 14) {
            ContentUnavailableView(
                "Transcription failed",
                systemImage: "exclamationmark.triangle",
                description: Text(retryAvailable
                    ? "The audio is kept. Retry to transcribe again."
                    : "The audio is no longer available, so this meeting can't be transcribed.")
            )
            if retryAvailable {
                Button {
                    if let meetingID { controller.retryFinalization(meetingID) }
                } label: {
                    Label("Retry", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderedProminent)
                .help("Run a fresh transcription pass from the meeting's kept audio")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// LEGACY (pre-migration meetings only): the draft chrome above a floor
    /// transcript — the persistent badge keyed on persisted `liveFloor`
    /// provenance, plus Retry / Keep draft exactly while the kept audio
    /// exists (ADR-024). Nothing writes `liveFloor` any more.
    private func draftStrip(retryAvailable: Bool) -> some View {
        HStack(spacing: 10) {
            Text("Draft")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.orange)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color.orange.opacity(0.14), in: Capsule())
            Text("Finalization didn't complete — this is the live transcript.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer(minLength: 12)
            if retryAvailable {
                Button {
                    if let meetingID { controller.retryFinalization(meetingID) }
                } label: {
                    Label("Retry", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderedProminent)
                .help("Run a fresh finalization pass from the meeting's kept audio")
                Button("Keep draft") {
                    confirmKeepDraft = true
                }
                .buttonStyle(.bordered)
                .help("Accept this draft as final and delete the meeting's kept audio")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .padding(.horizontal, 24)
        .padding(.top, 10)
    }

    private func keepDraft() {
        guard let meetingID else { return }
        Task {
            await controller.keepDraft(meetingID)
            // Local refresh: no meta changed, so the probe key won't fire —
            // the Retry disappears here; the state stays draft (now final by
            // the user's acceptance, badge and all).
            hasRetainedAudio = false
        }
    }
}

/// The mockup's underlined tab strip: Transcript / AI Summary.
private struct DetailTabBar: View {
    @Binding var selection: DetailTab

    var body: some View {
        HStack(spacing: 24) {
            tab("Transcript", .transcript)
            tab("AI Summary", .summary)
            Spacer()
        }
        .padding(.horizontal, 24)
        .padding(.top, 14)
    }

    private func tab(_ title: String, _ value: DetailTab) -> some View {
        let isSelected = selection == value
        return Button {
            selection = value
        } label: {
            VStack(spacing: 7) {
                Text(title)
                    .font(.body.weight(isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? .primary : .secondary)
                Rectangle()
                    .fill(isSelected ? Color.echoIndigo : .clear)
                    .frame(height: 2)
            }
            .fixedSize()
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// The current session (or empty idle state): the committed transcript and the
/// streaming/regenerable summary over `controller.state`, plus — while
/// recording — the footer with the popover's waves. While recording, the
/// Transcript tab shows a placeholder instead of transcript text (SP-007:
/// the user never sees a live transcript); the segments keep accumulating
/// invisibly and surface once the meeting resolves.
private struct LiveMeetingDetail: View {
    @Environment(RecordingController.self) private var controller
    @Binding var selectedTab: DetailTab

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch selectedTab {
                case .transcript:
                    // The pure display state routes the whole tab (SP-007
                    // S6): recording placeholder → waiting/transcribing
                    // faces → final transcript or draft-labeled floor. On
                    // pass success `replaceSegments` swaps `state.segments`
                    // in place, so the final transcript appears here without
                    // reopening.
                    MeetingTranscriptFace(
                        meetingID: controller.library.activeMeetingID,
                        isLiveTarget: true,
                        segments: controller.state.segments
                    )
                case .summary:
                    summary
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if controller.state.isRecording {
                LiveTranscriptFooter()
            }
        }
        // The finished summary announces itself: the moment generation
        // completes, the detail lands on it instead of leaving it hidden
        // behind an unselected tab.
        .onChange(of: summaryIsComplete) { _, complete in
            if complete { selectedTab = .summary }
        }
    }

    /// True exactly while the session's summary is finished (not streaming,
    /// not failed) — the transition edge that flips the tab.
    private var summaryIsComplete: Bool {
        if case .ready = controller.state.summaryState { return true }
        return false
    }

    @ViewBuilder
    private var summary: some View {
        switch controller.state.summaryState {
        case .idle:
            VStack(spacing: 18) {
                ContentUnavailableView(
                    controller.state.isRecording ? "Summary after recording" : "No summary yet",
                    systemImage: "sparkles",
                    description: Text(idleSummaryDescription)
                )
                // A summary-less meeting offers to make one, whether or not it
                // is still the live session's — the same "Generate summary"
                // the saved-meeting detail shows. Before, this idle state only
                // ever carried the model control's "Retry", which named a
                // failure that never happened and disappeared once the app was
                // relaunched and the meeting stopped being the active one.
                if let generate = generateSummaryAction {
                    Button(action: generate) {
                        Label("Generate summary", systemImage: "sparkles")
                    }
                    .buttonStyle(.borderedProminent)
                    .help("Generate this meeting's summary now")
                } else {
                    SummaryModelControl()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .generating:
            SummaryGenerationProgressView(subject: "the final transcript")
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
                SummaryModelControl(onRetrySummary: retrySummaryAction)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Honest idle copy (SP-005 S6): while the just-stopped meeting's final
    /// pass runs or waits, the summary is deliberately held back — say so
    /// instead of implying nothing is coming.
    private var idleSummaryDescription: String {
        if controller.state.isRecording {
            return "Echo will generate this once the recording stops."
        }
        if let id = controller.library.activeMeetingID,
           controller.finalization.currentMeetingID == id
            || controller.finalization.queuedMeetingIDs.contains(id) {
            return "Echo will generate this once the transcript finishes finalizing."
        }
        // A transcript with no summary is not a dead end — say what the button
        // below it can do, or what the model still needs, instead of asking
        // for a recording the user has already made.
        if !controller.state.segments.isEmpty {
            if case .ready = controller.summaryModelState {
                return "The transcript is saved, so you can generate one now."
            }
            return "Generating one needs the summary model. Download it and this meeting will be processed automatically."
        }
        return "Start and stop a recording to generate meeting notes."
    }

    /// Generates this meeting's summary on demand — the same work the
    /// automatic post-stop generation does, so it is also what "Retry" runs
    /// after a failure. Offered only with a transcript to ground it in and the
    /// model on disk; otherwise the model control takes the space instead.
    private var generateSummaryAction: (() -> Void)? {
        guard case .ready = controller.summaryModelState else { return nil }
        return retrySummaryAction
    }

    /// Re-runs the just-stopped session's summary — only while its segments
    /// are still in memory (they clear when the next recording starts).
    private var retrySummaryAction: (() -> Void)? {
        guard !controller.state.isRecording, !controller.state.segments.isEmpty else { return nil }
        return { Task { await controller.retrySummary() } }
    }
}

/// The "working on it" face of a summary. It tells the user what is actually
/// happening — downloading the model (with a real progress bar), loading it
/// into memory, or genuinely generating — instead of claiming "Generating…"
/// over a multi-GB download.
private struct SummaryGenerationProgressView: View {
    @Environment(RecordingController.self) private var controller
    /// What the generation reads — "the final transcript" (live session) or
    /// "this meeting's transcript" (backfill on a saved meeting).
    let subject: String

    var body: some View {
        VStack(spacing: 12) {
            switch controller.summaryModelState {
            case .downloading(let fraction):
                let progress = ModelDownloadProgress(fraction: fraction)
                ProgressView(value: progress.fraction)
                    .frame(maxWidth: 280)
                Text("Downloading summary model… \(progress.percent)%")
                    .font(.headline)
                Text("One-time \(SummaryModelManager.modelDisplaySize) download. The summary is generated as soon as it finishes.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

            case .loading:
                ProgressView()
                    .controlSize(.large)
                Text("Loading summary model…")
                    .font(.headline)
                Text("Bringing \(SummaryModelManager.modelDisplayName) into memory.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

            default:
                ProgressView()
                    .controlSize(.large)
                Text("Generating summary…")
                    .font(.headline)
                Text("Echo is reading \(subject) locally.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal, 40)
    }
}

/// The summary model's status line plus its download/resume/retry action.
/// Reused by the live detail's idle/failed states and the past detail's
/// no-summary state.
private struct SummaryModelControl: View {
    @Environment(RecordingController.self) private var controller
    /// Prominent extra action (the live detail's "Retry" for the last
    /// session's summary); nil hides it.
    var onRetrySummary: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "cpu")
                .foregroundStyle(.secondary)
            Text(description)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 300, alignment: .leading)

            if showsDownloadButton {
                Button {
                    Task {
                        // A paused download resumes (clearing the persisted
                        // intent); every other state is a fresh/retry download.
                        if case .paused = controller.summaryModelState {
                            await controller.resumeSummaryDownload()
                        } else {
                            await controller.downloadSummaryModel()
                        }
                    }
                } label: {
                    Label(downloadButtonTitle, systemImage: "arrow.down.circle")
                }
                .buttonStyle(.bordered)
                .disabled(controller.summaryModelState.isBusy)
            }

            if let onRetrySummary {
                Button(action: onRetrySummary) {
                    Label("Retry", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderedProminent)
                .disabled(controller.summaryModelState.isBusy)
            }
        }
        .padding(.horizontal)
    }

    private var description: String {
        switch controller.summaryModelState {
        case .notDownloaded:
            return "Summary model not downloaded · \(SummaryModelManager.modelDisplaySize)"
        case .partiallyDownloaded:
            // No "X of Y on disk": the partial's disk sum overflowed the total
            // ("8.93 GB of 8.3 GB") because it counted staging; the Resume
            // button is the honest affordance (ADR-007).
            return "Download incomplete · resume to finish"
        case .paused:
            return "Download paused · resume to finish"
        case .downloading(let fraction):
            return "Downloading summary model… \(ModelDownloadProgress(fraction: fraction).percent)%"
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
        case .notDownloaded, .partiallyDownloaded, .paused, .failed, .downloading:
            return true
        case .loading, .ready:
            return false
        }
    }

    /// A failed download reads as a retry, an interrupted or paused one as a
    /// resume — not a from-scratch download.
    private var downloadButtonTitle: String {
        switch controller.summaryModelState {
        case .failed: return "Retry download"
        case .partiallyDownloaded, .paused: return "Resume download"
        default: return "Download model"
        }
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
                switch selectedTab {
                case .transcript:
                    // Same routing as the live detail (SP-007 S6): a pending
                    // meeting opened from the list shows waiting/transcribing,
                    // never its floor transcript; a draft shows the draft face.
                    MeetingTranscriptFace(meetingID: id, segments: record.segments)
                case .summary:
                    summary(for: record)
                }
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
        // Composite reload key (the view's `.id(id)` already resets identity
        // per meeting): `hasSummary` catches the backfill attaching a summary
        // while this detail is open; `isFinalizing` flipping back to false
        // catches this meeting's final pass concluding — the record re-reads
        // and the final transcript swaps in without reselection (SP-005 S6).
        .task(id: reloadKey) {
            isLoading = true
            record = await controller.library.loadRecord(id)
            isLoading = false
        }
    }

    private struct ReloadKey: Equatable {
        let hasSummary: Bool
        let isFinalizing: Bool
        let transcriptSource: TranscriptProvenance.Source?
    }

    private var reloadKey: ReloadKey {
        ReloadKey(
            hasSummary: controller.library.meta(for: id)?.hasSummary ?? false,
            isFinalizing: controller.finalization.currentMeetingID == id,
            // Provenance landing (replace or terminal convergence) re-reads
            // the record, so the face keys on fresh persisted state.
            transcriptSource: controller.library.meta(for: id)?.transcriptProvenance?.source
        )
    }

    @ViewBuilder
    private func summary(for record: MeetingRecord) -> some View {
        if let summary = record.summary {
            SummaryContentView(summary: summary, segments: record.segments)
        } else if controller.backfillingMeetingID == id {
            SummaryGenerationProgressView(subject: "this meeting's transcript")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if hasNoTranscriptYet {
            // Nothing to ground a summary in: the pass is still owed (or
            // failed outright). Offering "Generate summary" here would
            // promise notes over words that don't exist.
            ContentUnavailableView(
                "Summary after transcription",
                systemImage: "sparkles",
                description: Text(isTranscriptionFailed
                    ? "This meeting has no transcript. Retry transcription first."
                    : "Echo will generate this once the transcript is ready.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            // Not a dead end: the transcript is saved, so the summary can be
            // generated right here — or the missing model downloaded first.
            VStack(spacing: 18) {
                ContentUnavailableView(
                    "No summary",
                    systemImage: "sparkles",
                    description: Text(noSummaryDescription)
                )
                if case .ready = controller.summaryModelState {
                    Button {
                        controller.requestSummary(for: id)
                    } label: {
                        Label("Generate summary", systemImage: "sparkles")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(controller.state.isRecording)
                    .help(controller.state.isRecording
                        ? "Available after the current recording stops"
                        : "Generate this meeting's summary now")
                } else {
                    SummaryModelControl()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var noSummaryDescription: String {
        if case .ready = controller.summaryModelState {
            return "The transcript is saved, so you can generate one now."
        }
        return "Generating one needs the summary model. Download it and this meeting will be processed automatically."
    }

    /// The meeting has no transcript to summarize — still owed (waiting /
    /// transcribing) or permanently absent (failed). From the same pure
    /// function as the faces: the sync subset (no audio probe, which only
    /// distinguishes Retry availability — irrelevant here).
    private var hasNoTranscriptYet: Bool {
        switch meetingDisplayState(for: id, controller: controller) {
        case .waiting, .transcribing, .failed: return true
        case .recording, .draft, .final: return false
        }
    }

    private var isTranscriptionFailed: Bool {
        if case .failed = meetingDisplayState(for: id, controller: controller) { return true }
        return false
    }
}

// MARK: - Shared transcript list

/// The committed (final) transcript of a resolved meeting, rendered as
/// derived utterances (ADR-021): consecutive same-speaker segments merge
/// into paragraphs with a time range, and standalone backchannel stays out
/// of the flow — the persisted segments are untouched. Never rendered while
/// recording (SP-007 final-only UX): the live detail shows a "Recording"
/// placeholder instead, so this view has no live-follow machinery — it is a
/// plain, read-only scroll.
private struct TranscriptScroll: View {
    let segments: [TranscriptSegment]

    var body: some View {
        let utterances = TranscriptUtterance.derive(from: segments)
        if utterances.isEmpty {
            ContentUnavailableView(
                "No transcript",
                systemImage: "text.bubble",
                description: Text("This meeting has no transcript.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 22) {
                    ForEach(utterances) { utterance in
                        UtteranceRow(utterance: utterance)
                    }
                }
                // A readable column as in the mockup: capped width,
                // centered in the pane.
                .frame(maxWidth: 720, alignment: .leading)
                .padding(.horizontal, 24)
                .padding(.vertical, 20)
                .frame(maxWidth: .infinity)
            }
        }
    }
}

/// One derived utterance: speaker, time range, merged paragraph.
private struct UtteranceRow: View {
    let utterance: TranscriptUtterance

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(utterance.speaker.displayName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(accent)
                Text(timeRange)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Text(utterance.text)
                .font(.body)
                .textSelection(.enabled)
        }
    }

    /// Speaker accent: the user keeps the brand indigo (their wave, the
    /// glyph); everyone on the system stream gets a distinguishable purple.
    private var accent: Color {
        utterance.speaker == .me ? .echoIndigo : .purple
    }

    private var timeRange: String {
        "\(recTimerString(utterance.start))–\(recTimerString(utterance.end))"
    }
}

// MARK: - Live transcription footer

/// The detail's bottom bar while recording: the same dual waves as the menu
/// bar popover (real capture levels — the capture-health signal) and the
/// transcribing / processed-locally status. No transcript text ever renders
/// here (SP-007: the user never sees a live transcript).
private struct LiveTranscriptFooter: View {
    @Environment(RecordingController.self) private var controller

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 14) {
                DualWaveView(
                    inputLevel: controller.state.inputAmplitude,
                    outputLevel: controller.state.outputAmplitude
                )
                .frame(width: 130, height: 30)

                Spacer(minLength: 12)

                // Honest status: nothing is transcribed during a recording —
                // the audio is being captured and the meeting is transcribed
                // once it stops. "Transcribing…" here would be a lie.
                Text("Recording…")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(Color.echoIndigo)

                HStack(spacing: 5) {
                    Image(systemName: "checkmark.shield")
                    Text("Processed locally")
                }
                .font(.callout)
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
        }
        .background(Color(nsColor: .windowBackgroundColor))
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
