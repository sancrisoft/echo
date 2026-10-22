//
//  MenuBarMenuTests.swift
//  AppTests
//
//  How the menu is put together from the island's part and the app's: the
//  island's lines and commands first, a rule only when there is something
//  above it — SwiftUI's `Menu` elided a leading divider and `NSMenu` draws
//  it — then the way back into the app, which never changes. What the island's
//  part holds for each face is the island's, and tested there.
//
//  Hosted because the type belongs to the app target and there is no other way
//  to reach it; the menu it builds asks nothing of the host.
//

import AppKit
import EchoCore
import Foundation
import Island
import Testing

@testable import Echo

@Suite("The menu bar item's menu")
@MainActor
struct MenuBarMenuTests {

    private func contents(_ entries: @escaping () -> [IslandMenuEntry]) -> MenuBarMenu {
        MenuBarMenu(
            island: { _ in entries() },
            requests: MenuBarMenu.Requests(openEcho: {}, openSettings: {}, checkForUpdates: {}, update: {})
        )
    }

    private func menu(_ entries: [IslandMenuEntry]) -> NSMenu {
        contents { entries }.build()
    }

    private func titles(_ menu: NSMenu) -> [String] {
        menu.items.map { $0.isSeparatorItem ? "—" : $0.title }
    }

    @Test("with nothing from the island, the menu opens at Open Echo, never on a rule")
    func nothingFromTheIsland() throws {
        let first = try #require(menu([]).items.first)
        #expect(!first.isSeparatorItem)
        #expect(first.title == "Open Echo")
    }

    @Test("the island's part comes first, with a rule beneath it")
    func theIslandsPartComesFirst() {
        let menu = menu([
            IslandMenuEntry(title: "Zoom call detected", kind: .status),
            IslandMenuEntry(title: "Record", kind: .action({})),
        ])
        #expect(Array(titles(menu).prefix(4)) == ["Zoom call detected", "Record", "—", "Open Echo"])
    }

    @Test("a line that says is not a command")
    func aStatusLineDoesNothing() throws {
        let menu = menu([IslandMenuEntry(title: "Writing the summary", kind: .status)])
        menu.update()
        let line = try #require(menu.items.first)
        #expect(line.action == nil)
        #expect(!line.isEnabled)
    }

    @Test("a command runs what the island handed over")
    func aCommandRuns() throws {
        var ran = 0
        let menu = menu([IslandMenuEntry(title: "Stop", kind: .action({ ran += 1 }))])
        menu.performActionForItem(at: 0)
        #expect(ran == 1)
    }

    @Test("a disabled command stays disabled")
    func aDisabledCommand() throws {
        let menu = menu([IslandMenuEntry(title: "Record", kind: .action({}), isEnabled: false)])
        menu.update()
        #expect(try #require(menu.items.first).isEnabled == false)
    }

    @Test("the capture choice is a submenu, the choice in force checked")
    func theCaptureChoice() throws {
        var picked: [String] = []
        let menu = menu([
            IslandMenuEntry(
                title: "Zoom only",
                kind: .choice([
                    .init(title: "Zoom only", isSelected: true, pick: { picked.append("zoom") }),
                    .init(title: "Everything", isSelected: false, pick: { picked.append("everything") }),
                ]))
        ])
        let submenu = try #require(menu.items.first?.submenu)
        #expect(submenu.items.map(\.title) == ["Zoom only", "Everything"])
        #expect(submenu.items.map(\.state) == [.on, .off])
        submenu.performActionForItem(at: 1)
        #expect(picked == ["everything"])
    }

    @Test("the way back, the version and Quit are always there")
    func theRestOfTheMenuIsConstant() {
        for entries in [[], [IslandMenuEntry(title: "Record", kind: .action({}))]] {
            let titles = menu(entries).items.filter { !$0.isSeparatorItem }.map(\.title)
            #expect(titles.contains("Open Echo"))
            #expect(titles.contains("Settings"))
            #expect(titles.last == "Quit Echo")
        }
    }

    @Test("a refresh replaces the island's part and leaves the rest alone")
    func aRefreshReplacesOnlyTheIslandsPart() {
        var entries = [
            IslandMenuEntry(title: "00:12:41 · Everything", kind: .status),
            IslandMenuEntry(title: "Stop", kind: .action({})),
        ]
        let contents = contents { entries }
        let menu = contents.build()
        let tail = Array(titles(menu).dropFirst(3))

        entries = [IslandMenuEntry(title: "Zoom call ended · Auto-stop in 8 s", kind: .status)]
        contents.refresh(menu)
        #expect(Array(titles(menu).prefix(2)) == ["Zoom call ended · Auto-stop in 8 s", "—"])
        #expect(Array(titles(menu).dropFirst(2)) == tail)

        entries = []
        contents.refresh(menu)
        #expect(titles(menu) == tail)
    }

    /// The menu with nothing from the island, an update found or not, and
    /// what each update command was asked to do. The contents come back too:
    /// a menu item's target is weak, and in the app the menu bar item is what
    /// keeps them.
    private func updateMenu(available: String?) -> (contents: MenuBarMenu, menu: NSMenu, asked: () -> [String]) {
        var asked: [String] = []
        let contents = MenuBarMenu(
            island: { _ in [] },
            availableUpdate: { available },
            requests: MenuBarMenu.Requests(
                openEcho: {}, openSettings: {},
                checkForUpdates: { asked.append("check") },
                update: { asked.append("update") }
            )
        )
        return (contents, contents.build(), { asked })
    }

    @Test("Check for Updates sits under the version and runs a check")
    func checkForUpdates() throws {
        let (contents, menu, asked) = updateMenu(available: nil)
        let titles = titles(menu)
        let index = try #require(titles.firstIndex(of: "Check for Updates"))
        #expect(titles[index - 1] == AppIdentity.version.display)
        withExtendedLifetime(contents) { menu.performActionForItem(at: index) }
        #expect(asked() == ["check"])
    }

    @Test("once a check has found a newer version, the same place names it and updates")
    func updateToTheVersionFound() throws {
        let (contents, menu, asked) = updateMenu(available: "0.1.1")
        let titles = titles(menu)
        #expect(!titles.contains("Check for Updates"))
        let index = try #require(titles.firstIndex(of: "Update to Echo 0.1.1"))
        #expect(titles[index - 1] == AppIdentity.version.display)
        withExtendedLifetime(contents) { menu.performActionForItem(at: index) }
        #expect(asked() == ["update"])
    }
}
