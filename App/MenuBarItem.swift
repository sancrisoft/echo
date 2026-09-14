//
//  MenuBarItem.swift
//  Echo
//
//  The menu bar item, managed by hand rather than by `MenuBarExtra`, which
//  opens its menu on any click and cannot tell the two mouse buttons apart.
//  Here they do different things: the left button opens the dashboard, and the
//  right one — Control-click included, which macOS treats as the same gesture —
//  opens the flat menu. The item is the only part of Echo a new user finds
//  unaided, so it leads to the app rather than to a list of things about it.
//
//  It is also the one view an agent app always has on screen, so it carries the
//  bridge that hands SwiftUI's `openWindow` to the AppKit side. Without that,
//  the app menu, the menu's own Open Echo and a reopen all lose the only way
//  they have to put a window up.
//

import AppKit
import SwiftUI

final class MenuBarItem: NSObject, NSMenuDelegate {

    private let contents: MenuBarMenu
    private let windowOpener: WindowOpener
    private var item: NSStatusItem?

    init(contents: MenuBarMenu, windowOpener: WindowOpener) {
        self.contents = contents
        self.windowOpener = windowOpener
    }

    /// Puts the item in the menu bar. Called once the app is actually up: a
    /// status item needs a live `NSApplication`, and `AppComposition.start()`
    /// runs before SwiftUI has created one.
    func install() {
        guard item == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Echo")
            button.target = self
            button.action = #selector(clicked)
            // Both buttons have to reach the action for it to be able to tell
            // them apart; a status item reports only the left one by default.
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.addSubview(bridge())
        }
        self.item = item
    }

    /// The zero-size SwiftUI view that captures `openWindow`. It hitches a ride
    /// on the button because that is the view this app always has, and it
    /// answers no clicks of its own.
    private func bridge() -> NSView {
        let bridge = NSHostingView(
            rootView: WindowOpenerBridge(opener: windowOpener).allowsHitTesting(false)
        )
        bridge.frame = NSRect(x: 0, y: 0, width: 1, height: 1)
        return bridge
    }

    @objc private func clicked() {
        guard let event = NSApp.currentEvent else {
            // Nothing to read the gesture from. The dashboard is the answer to
            // the click this is most likely to be.
            windowOpener.openMainWindow()
            return
        }
        if Self.opensMenu(for: event.type, modifiers: event.modifierFlags) {
            showMenu()
        } else {
            windowOpener.openMainWindow()
        }
    }

    /// The right button opens the menu. So does Control-click: macOS treats it
    /// as the same gesture, and it arrives as a left click carrying `.control`.
    nonisolated static func opensMenu(for type: NSEvent.EventType, modifiers: NSEvent.ModifierFlags) -> Bool {
        if type == .rightMouseUp || type == .rightMouseDown { return true }
        return modifiers.contains(.control)
    }

    /// The menu is attached only while it is open. A status item with a menu
    /// set swallows the click itself, and the left button would never reach the
    /// action again.
    private func showMenu() {
        guard let item, let button = item.button else { return }
        let menu = contents.build()
        menu.delegate = self
        item.menu = menu
        button.performClick(nil)
    }

    func menuDidClose(_ menu: NSMenu) {
        menu.delegate = nil
        item?.menu = nil
    }
}
