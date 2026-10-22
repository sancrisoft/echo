//
//  MenuBarItemTests.swift
//  AppTests
//
//  Which mouse button opens which thing. Hosted because the type belongs to the
//  app target and there is no other way to reach it; the rule itself is pure
//  and asks nothing of the host. The gesture that carries it — a real click, on
//  a real status item — is the half only a person can see.
//

import AppKit
import Testing

@testable import Echo

@Suite("The menu bar item's two buttons")
struct MenuBarItemTests {

    @Test("a left click opens the dashboard, not the menu")
    func leftClickOpensTheDashboard() {
        #expect(!MenuBarItem.opensMenu(for: .leftMouseUp, modifiers: []))
    }

    @Test("the right button opens the menu")
    func rightClickOpensTheMenu() {
        #expect(MenuBarItem.opensMenu(for: .rightMouseUp, modifiers: []))
    }

    /// The macOS convention: Control-click is a right click. It arrives as a
    /// left click carrying `.control`, which is why the rule cannot be about
    /// the button alone.
    @Test("Control-click is a right click")
    func controlClickOpensTheMenu() {
        #expect(MenuBarItem.opensMenu(for: .leftMouseUp, modifiers: .control))
        #expect(MenuBarItem.opensMenu(for: .rightMouseUp, modifiers: .control))
    }

    /// Control is the only modifier that means it. The others leave a left
    /// click meaning what it always meant.
    @Test(
        "no other modifier turns a left click into a right one",
        arguments: [NSEvent.ModifierFlags.shift, .option, .command, .capsLock, [.shift, .command]]
    )
    func otherModifiersLeaveTheLeftClickAlone(modifiers: NSEvent.ModifierFlags) {
        #expect(!MenuBarItem.opensMenu(for: .leftMouseUp, modifiers: modifiers))
    }
}
