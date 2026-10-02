//
//  MenuBarMenu.swift
//  Echo
//
//  The menu bar item's menu: the island's open face as a menu, then the way
//  back into the app.
//
//  The top part is whatever the island would offer right now — its line and
//  its commands, in its words (`Island.IslandMenu`). It is there whether the
//  island is switched on or off: switched off, it is how the island's actions
//  are reached at all, and switched on, it is still the keyboard's and
//  VoiceOver's way to every one of them (#119, DEC-1, product owner
//  2026-10-02). The bottom part never changes.
//
//  An `NSMenu` and not SwiftUI's, because the item it hangs from is an
//  `NSStatusItem`: `MenuBarExtra` opens its menu on either mouse button and
//  cannot tell them apart, and the left one belongs to the dashboard.
//

import AppKit
import EchoCore
import Island

final class MenuBarMenu: NSObject {

    /// The two things the bottom of the menu asks of the rest of the app.
    struct Requests {
        let openEcho: () -> Void
        let openSettings: () -> Void
    }

    private let island: (Date) -> [IslandMenuEntry]
    private let requests: Requests

    /// - Parameter island: the island's part of the menu at an instant. Asked
    ///   each time the menu is built or refreshed and never held, so what the
    ///   menu offers is what the island offers at that moment.
    init(island: @escaping (Date) -> [IslandMenuEntry], requests: Requests) {
        self.island = island
        self.requests = requests
    }

    /// Built fresh for each click: the menu can never ask for a start over a
    /// running recording, or a second stop over a teardown already under way.
    func build(now: Date = .now) -> NSMenu {
        let menu = NSMenu()
        for item in islandItems(now: now) {
            menu.addItem(item)
        }
        menu.addItem(button("Open Echo", #selector(openEcho)))
        menu.addItem(button("Settings…", #selector(openSettings)))
        menu.addItem(.separator())
        // No action, so `autoenablesItems` draws it as the label it is.
        menu.addItem(NSMenuItem(title: AppIdentity.version.display, action: nil, keyEquivalent: ""))
        menu.addItem(.separator())
        let quit = button("Quit Echo", #selector(quit))
        quit.keyEquivalent = "q"
        quit.keyEquivalentModifierMask = .command
        menu.addItem(quit)
        return menu
    }

    /// Brings the island's part of an open menu up to `now`: a clock or a
    /// countdown moves on, and a face that changed under the open menu is
    /// replaced by the one that took its place. The rest is left alone.
    func refresh(_ menu: NSMenu, now: Date = .now) {
        for item in menu.items where item.tag == Self.islandTag {
            menu.removeItem(item)
        }
        for (index, item) in islandItems(now: now).enumerated() {
            menu.insertItem(item, at: index)
        }
    }

    /// Marks the items the island owns, so a refresh replaces exactly those.
    static let islandTag = 0x4953_4C44

    /// The island's entries, then the rule beneath them — only when there is
    /// something for it to separate, since `NSMenu` draws a leading divider
    /// that SwiftUI's `Menu` used to drop.
    private func islandItems(now: Date) -> [NSMenuItem] {
        let entries = island(now)
        guard !entries.isEmpty else { return [] }
        let items = entries.map(Self.item(for:)) + [.separator()]
        for item in items { item.tag = Self.islandTag }
        return items
    }

    private static func item(for entry: IslandMenuEntry) -> NSMenuItem {
        switch entry.kind {
        case .status:
            // No action, so it reads as a line rather than a command.
            return NSMenuItem(title: entry.title, action: nil, keyEquivalent: "")
        case .action(let run):
            return MenuCommand.item(entry.title, isEnabled: entry.isEnabled, run: run)
        case .choice(let options):
            let item = NSMenuItem(title: entry.title, action: nil, keyEquivalent: "")
            let submenu = NSMenu()
            for option in options {
                let choice = MenuCommand.item(option.title, run: option.pick)
                choice.state = option.isSelected ? .on : .off
                submenu.addItem(choice)
            }
            item.submenu = submenu
            return item
        }
    }

    private func button(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func openEcho() { requests.openEcho() }
    @objc private func openSettings() { requests.openSettings() }
    @objc private func quit() { NSApp.terminate(nil) }
}

/// What a menu item built from a closure reports to. `NSMenuItem` speaks
/// target–action, and the island hands its commands over as closures.
private final class MenuCommand: NSObject, NSMenuItemValidation {

    private let run: () -> Void
    private let isEnabled: Bool

    private init(isEnabled: Bool, run: @escaping () -> Void) {
        self.isEnabled = isEnabled
        self.run = run
    }

    /// An item that runs `run`. The item keeps its command alive through
    /// `representedObject`, because its `target` is weak.
    static func item(_ title: String, isEnabled: Bool = true, run: @escaping () -> Void) -> NSMenuItem {
        let command = MenuCommand(isEnabled: isEnabled, run: run)
        let item = NSMenuItem(title: title, action: #selector(fire), keyEquivalent: "")
        item.target = command
        item.representedObject = command
        return item
    }

    /// Asked by the menu, which enables on its own any item whose target
    /// answers its action: setting `isEnabled` on the item would be undone.
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        isEnabled
    }

    @objc private func fire() { run() }
}
