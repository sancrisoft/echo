//
//  RowContextClick.swift
//  Workspace
//
//  Makes a right-click select the row it is about to open a menu on, the way
//  Finder does.
//
//  SwiftUI has no hook for it: a right-click is not a `TapGesture`, and
//  `contextMenu` never says which row it is opening for, or when. But a
//  context click can only land on the row the pointer is over, and the list
//  already tracks that row for its hover state — so a local event monitor and
//  that one id are the whole mechanism. The event is returned untouched, so
//  the menu opens exactly as it would have.
//
//  Ported from the PoC, which paid for this with a menu that acted on one
//  meeting while the highlight sat on another.
//
//  The monitor sees every click in the app, and the hover it trusts is a
//  fact with an expiry: SwiftUI owes no exit when the rows move under a
//  pointer that never left one, or when the window stops being the one the
//  user is in. So a click has to land in the list's own window, and anything
//  that can strand the hover — a scroll, the window ceasing to be key —
//  forgets it. The failure left is the harmless one: a click right after a
//  scroll selects nothing until the pointer moves, instead of selecting a row
//  the pointer is no longer on.
//

import AppKit
import Foundation

@MainActor
final class RowContextClickWatcher {

    /// The row the pointer is over, kept in step by the list. Without it a
    /// click has no row, and nothing happens.
    var hoveredID: UUID?

    /// The window the list is in. A click in any other window of the app — a
    /// panel, a menu of its own — is not a click on a row, however recently
    /// the pointer was over one.
    weak var listWindow: NSWindow?

    /// Called with the row a context click landed on, before its menu opens.
    var onContextClick: ((UUID) -> Void)?

    private var monitor: Any?
    private var observers: [any NSObjectProtocol] = []

    /// Whether an event raises a context menu. Control-click is the other way
    /// to ask for one, and it arrives as an ordinary left click.
    nonisolated static func isContextClick(type: NSEvent.EventType, modifiers: NSEvent.ModifierFlags) -> Bool {
        switch type {
        case .rightMouseDown: return true
        case .leftMouseDown: return modifiers.contains(.control)
        default: return false
        }
    }

    /// What one event does: a context click over a row, in the window that
    /// row is in, selects it; anything else changes nothing. Separated from
    /// the monitor so the rule can be exercised without a window.
    func handle(isContextClick: Bool, isInListWindow: Bool) {
        guard isContextClick, isInListWindow, let hoveredID else { return }
        onContextClick?(hoveredID)
    }

    /// Drops the hovered row, for the moments when the pointer may no longer
    /// be over it and nothing will say so.
    func forgetHover() {
        hoveredID = nil
    }

    /// Starts watching. Idempotent, so a view that appears twice installs one
    /// monitor.
    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown, .leftMouseDown, .scrollWheel]) {
            [weak self] event in
            MainActor.assumeIsolated {
                guard let self else { return }
                guard event.type != .scrollWheel else { return self.forgetHover() }
                self.handle(
                    isContextClick: Self.isContextClick(type: event.type, modifiers: event.modifierFlags),
                    isInListWindow: event.window != nil && event.window === self.listWindow)
            }
            return event
        }
        observers = [NSWindow.didResignKeyNotification, NSApplication.didResignActiveNotification].map { name in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.forgetHover() }
            }
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
    }
}
