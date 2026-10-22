//
//  ShortcutsCoverageTests.swift
//  AppTests
//
//  The keyboard shortcuts panel promises everything the keyboard can do, and
//  the app's menus are the part of that SwiftUI and AppKit add on their own —
//  Hide, Minimize, the Edit menu — beside what Echo's commands add. So every
//  shortcut a menu item shows has to be in the panel. Hosted because only the
//  running app has its menus.
//

import AppKit
import Testing

@testable import Echo
@testable import Workspace

@Suite("The keyboard shortcuts panel and the app's menus")
@MainActor
struct ShortcutsCoverageTests {

    /// Items macOS puts in every Edit menu, with shortcuts that are the
    /// system's and depend on the keyboard; the panel writes them its own way.
    private static let systemItems: Set<String> = ["Emoji & Symbols", "Start Dictation…"]

    /// A menu item's shortcut as the panel writes it: the modifiers in the
    /// order menus put them, then the key.
    private static func display(_ item: NSMenuItem) -> String {
        let modifiers = item.keyEquivalentModifierMask
        let glyphs: [(NSEvent.ModifierFlags, String)] = [
            (.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘"),
        ]
        return glyphs.filter { modifiers.contains($0.0) }.map(\.1).joined() + item.keyEquivalent.uppercased()
    }

    private static func shortcuts(in menu: NSMenu) -> [(title: String, keys: String)] {
        menu.items.flatMap { item -> [(title: String, keys: String)] in
            var found: [(title: String, keys: String)] = []
            if !item.isSeparatorItem, !item.isHidden, !item.isAlternate, !item.keyEquivalent.isEmpty,
                !systemItems.contains(item.title)
            {
                found.append((item.title, display(item)))
            }
            if let submenu = item.submenu { found += shortcuts(in: submenu) }
            return found
        }
    }

    @Test("every shortcut a menu shows is in the panel")
    func everyMenuShortcutIsListed() throws {
        let menu = try #require(NSApp.mainMenu)
        let menuShortcuts = Self.shortcuts(in: menu)
        #expect(!menuShortcuts.isEmpty)
        let listed = Set(
            ShortcutsList.groups(globalShortcut: GlobalShortcut.display).flatMap { $0.rows.flatMap(\.keys) })
        for shortcut in menuShortcuts {
            #expect(listed.contains(shortcut.keys), "\(shortcut.title) (\(shortcut.keys)) is not in the panel")
        }
    }

    @Test("⌘W closes the window: the app's menus carry Close")
    func closeIsInTheMenus() throws {
        let menu = try #require(NSApp.mainMenu)
        #expect(Self.shortcuts(in: menu).contains { $0.title == "Close" && $0.keys == "⌘W" })
    }
}
