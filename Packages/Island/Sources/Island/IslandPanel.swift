//
//  IslandPanel.swift
//  Island
//
//  The window the shell lives in: borderless, non-activating, above the menu
//  bar, on every Space and over full-screen apps.
//
//  It must never become key. The island sits on top of whatever the user is
//  actually doing — a call, usually — and a panel that took focus to be
//  hovered would interrupt the very thing it exists to watch. Spike #69
//  confirmed on hardware that it does not have to: `isKeyWindow` and
//  `NSApp.isActive` were false through every crossing.
//
//  Dumb by construction. It owns frame and visibility; what is on it is the
//  controller's business.
//

import AppKit

final class IslandPanel: NSPanel {

    init() {
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isFloatingPanel = true
        // AFTER `isFloatingPanel`, which silently resets the level to
        // `.floating` (3). Set first, the island ends up below the menu bar
        // (24) and below Notification Center's full-screen window (21):
        // created, placed, ordered front — and invisible. The PoC found this
        // with CGWindowListCopyWindowInfo, which is the only thing that shows
        // the real compositing order; a view-tree snapshot renders fine either
        // way.
        level = .statusBar
        hidesOnDeactivate = false
        isMovable = false
        // The shell paints its own black, and the flares have to show what is
        // behind them.
        backgroundColor = .clear
        isOpaque = false
        // The pill draws its own; the notched shell casts nothing.
        hasShadow = false
        becomesKeyOnlyIfNeeded = true
        // The controller holds the only reference; a stray close must not
        // release it out from under it.
        isReleasedWhenClosed = false
    }

    /// Belt to the `.nonactivatingPanel` brace: nothing on the island takes
    /// text, so there is no state in which becoming key would be right.
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
