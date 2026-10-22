//
//  ShortcutsPanelTests.swift
//  WorkspaceTests
//
//  The keyboard shortcuts panel, as values: that it and the palette are never
//  up together, that its list holds the keys this package answers to and
//  the global shortcut it is handed, and that while it is up the keyboard
//  stops at it.
//

import AppKit
import Testing

@testable import Workspace

@Suite("The keyboard shortcuts panel")
@MainActor
struct ShortcutsPanelTests {

    private let groups = ShortcutsList.groups(globalShortcut: "⌃⌥E")

    private func keys(in title: String) -> Set<String> {
        Set(groups.first { $0.title == title }?.rows.flatMap(\.keys) ?? [])
    }

    @Test("one panel at a time: the shortcuts and the palette put each other away")
    func onePanelAtATime() {
        let workspace = WorkspaceModel()
        workspace.presentSearch()
        workspace.presentShortcuts()
        #expect(workspace.isShortcutsPresented)
        #expect(!workspace.isSearchPresented)

        workspace.toggleSearch()
        #expect(workspace.isSearchPresented)
        #expect(!workspace.isShortcutsPresented)

        workspace.toggleShortcuts()
        #expect(workspace.isShortcutsPresented)
        workspace.toggleShortcuts()
        #expect(!workspace.isShortcutsPresented)
        #expect(!workspace.isSearchPresented)
    }

    @Test("the global shortcut it is handed comes first, as Record or Stop from anywhere")
    func theGlobalShortcutComesFirst() throws {
        let first = try #require(groups.first)
        #expect(first.title == "Anywhere")
        #expect(first.rows.map(\.keys) == [["⌃⌥E"]])
    }

    @Test("every row says what it does and with which keys, once per group")
    func everyRowIsComplete() {
        #expect(!groups.isEmpty)
        #expect(Set(groups.map(\.title)).count == groups.count)
        for group in groups {
            #expect(!group.rows.isEmpty, "\(group.title) lists nothing")
            #expect(Set(group.rows.map(\.label)).count == group.rows.count, "\(group.title) repeats a row")
            for row in group.rows {
                #expect(!row.label.isEmpty)
                #expect(!row.keys.isEmpty && row.keys.allSatisfy { !$0.isEmpty }, "\(row.label) has no keys")
            }
        }
    }

    @Test("the palette's actions' shortcuts, and the panel's own, are listed in the window's group")
    func thePalettesShortcutsAreListed() {
        let window = keys(in: "In the window")
        for shortcut in PaletteAction.allCases.compactMap(\.shortcut) {
            #expect(window.contains(shortcut), "\(shortcut) is missing")
        }
        #expect(window.contains(ShortcutsList.toggleKeys))
    }

    @Test("every key the palette reads first is listed under search")
    func thePalettesKeyboardIsListed() {
        #expect(keys(in: "In search") == ["↑↓", "↵", "⌘↵", "tab", "⇧tab", "⌘1–9", "⌘C", "⌘K", "esc"])
    }

    @Test("Esc puts the panel away, a command goes through, and every other key stops at the panel")
    func theKeyboardStopsAtThePanel() {
        func classify(_ keyCode: UInt16, _ modifiers: NSEvent.ModifierFlags = []) -> ShortcutsPanelKey {
            ShortcutsPanelKey.classify(keyCode: keyCode, modifiers: modifiers)
        }
        #expect(classify(53) == .close)
        // ⌘/ shuts it from the Help menu; ⌘K trades it for the palette.
        #expect(classify(44, .command) == .passThrough)
        #expect(classify(40, .command) == .passThrough)
        // ⌫, the arrows and a letter would act on the list beneath.
        #expect(classify(51) == .swallow)
        #expect(classify(126, [.numericPad, .function]) == .swallow)
        #expect(classify(0) == .swallow)
        // Esc with a modifier is not Esc.
        #expect(classify(53, .shift) == .swallow)
    }
}
