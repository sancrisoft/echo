//
//  ShortcutsPanel.swift
//  Workspace
//
//  Every keyboard shortcut, in a panel over the dimmed window — ⌘/, Help ›
//  Keyboard Shortcuts, or the palette's action (product owner, 2026-10-22).
//  The design does not draw it, so it is drawn as the ⌘K palette is, on the
//  same surface and with the same group labels, rules and keycaps; what
//  that left open (the title in the query's type, the keycaps emphasized) is
//  chosen here.
//
//  A modal, so it keeps the keyboard: Esc puts it away, a command still
//  reaches the menus and the window (⌘/ shuts it, ⌘K trades it for the
//  palette), and every other key stops at it rather than move or trash a
//  meeting in the list beneath.
//

import AppKit
import DesignSystem
import SwiftUI

struct ShortcutsPanel: View {
    @Environment(WorkspaceModel.self) private var workspace

    let groups: [ShortcutGroup]

    @State private var keys = ShortcutsPanelKeyWatcher()
    @State private var contentHeight: CGFloat = 0

    static let title = "Keyboard shortcuts"

    var body: some View {
        GeometryReader { window in
            ZStack(alignment: .top) {
                EchoColor.paletteScrim
                    .contentShape(.rect)
                    .onTapGesture { workspace.dismissShortcuts() }
                    .accessibilityHidden(true)
                panel(maxListHeight: maxListHeight(in: window.size.height))
                    .padding(.top, EchoLayout.paletteTopInset)
            }
        }
        .background(WindowReader { keys.window = $0 })
        .onAppear {
            keys.onClose = { workspace.dismissShortcuts() }
            keys.start()
        }
        .onDisappear { keys.stop() }
    }

    /// The list scrolls inside the panel rather than push it past the
    /// window's foot, as the palette's does.
    private func maxListHeight(in height: CGFloat) -> CGFloat {
        let chrome = EchoLayout.paletteFieldHeight + EchoLayout.hairline
        return max(EchoLayout.paletteActionHeight, height - 2 * EchoLayout.paletteTopInset - chrome)
    }

    private func panel(maxListHeight: CGFloat) -> some View {
        VStack(spacing: 0) {
            header
            EchoColor.paletteDivider
                .frame(height: EchoLayout.hairline)
            list(maxHeight: maxListHeight)
        }
        .paletteSurface()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Self.title)
        .accessibilityAddTraits(.isModal)
    }

    /// Where the palette has its query: the panel's name, and `esc`.
    private var header: some View {
        HStack(spacing: EchoLayout.paletteFieldGap) {
            Text(Self.title)
                .font(EchoFont.paletteQuery)
                .tracking(EchoFont.paletteQueryTracking)
                .foregroundStyle(EchoColor.textPrimary)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: EchoSpacing.s)
            Keycap("esc")
        }
        .padding(.horizontal, EchoLayout.paletteFieldInset)
        .frame(height: EchoLayout.paletteFieldHeight)
    }

    private func list(maxHeight: CGFloat) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(groups.enumerated()), id: \.element.id) { index, group in
                    if index > 0 { PaletteRule() }
                    PaletteGroupLabel(title: group.title)
                    ForEach(group.rows, id: \.label) { row in
                        rowView(row)
                    }
                }
            }
            .padding(EchoLayout.paletteListInset)
            .onGeometryChange(for: CGFloat.self) {
                $0.size.height
            } action: {
                contentHeight = $0
            }
        }
        .frame(height: min(contentHeight, maxHeight))
        .scrollIndicators(contentHeight > maxHeight ? .automatic : .never)
    }

    private func rowView(_ row: ShortcutRow) -> some View {
        HStack(spacing: EchoLayout.paletteRowGap) {
            Text(row.label)
                .font(EchoFont.rowTitle)
                .foregroundStyle(EchoColor.textProse)
                .lineLimit(1)
            Spacer(minLength: EchoSpacing.s)
            HStack(spacing: EchoLayout.keyHintGap) {
                ForEach(row.keys, id: \.self) { key in
                    Keycap(key, isEmphasized: true)
                }
            }
        }
        .padding(.horizontal, EchoLayout.paletteRowInset)
        .frame(height: EchoLayout.paletteActionHeight)
        .accessibilityElement(children: .combine)
    }
}

/// What a key does while the panel is up.
enum ShortcutsPanelKey: Equatable, Sendable {
    /// Esc puts the panel away.
    case close
    /// A command: the menus' and the window's shortcuts keep working.
    case passThrough
    /// Anything else, which would otherwise act on the list beneath — ⌫
    /// would move a meeting to Trash.
    case swallow

    private static let escape: UInt16 = 53

    static func classify(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> ShortcutsPanelKey {
        let pressed = modifiers.intersection([.command, .shift, .option, .control])
        if keyCode == escape, pressed.isEmpty { return .close }
        return pressed.contains(.command) ? .passThrough : .swallow
    }
}

/// Reads every key in the panel's window first, while the panel is up — the
/// palette's arrangement (`PaletteKeyWatcher`), with the panel's rule.
@MainActor
final class ShortcutsPanelKeyWatcher {
    /// The window the panel is in. A key pressed in any other window of the
    /// app is not the panel's.
    weak var window: NSWindow?
    var onClose: (() -> Void)?

    private var monitor: Any?

    /// Idempotent, so a panel that appears twice installs one monitor.
    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let swallowed = MainActor.assumeIsolated { () -> Bool in
                guard let self, let window = self.window, event.window === window else { return false }
                switch ShortcutsPanelKey.classify(keyCode: event.keyCode, modifiers: event.modifierFlags) {
                case .close:
                    self.onClose?()
                    return true
                case .passThrough:
                    return false
                case .swallow:
                    return true
                }
            }
            return swallowed ? nil : event
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
