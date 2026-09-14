//
//  MenuBarMenu.swift
//  Echo
//
//  The menu bar item's menu: the way back into the app when no window is open,
//  and — on a screen with no cutout — the only way into a recording at all.
//
//  Deliberately flat and small. It carries Record because the island's idle
//  face does not exist on every screen: it hides in the cutout, and a screen
//  without one shows the island only while something is happening (#194). With
//  no control here, such a screen has no way to start a session, which is a
//  hole rather than a simplification.
//
//  An `NSMenu` and not SwiftUI's, because the item it hangs from is an
//  `NSStatusItem` now: `MenuBarExtra` opens its menu on either mouse button and
//  cannot tell them apart, and the left one belongs to the dashboard.
//

import AppKit
import EchoCore
import Recording

final class MenuBarMenu: NSObject {

    /// Everything the menu can ask of the rest of the app. The same gated calls
    /// every other surface makes; nothing wider is representable from here.
    struct Requests {
        let startRecording: () -> Void
        let stopRecording: () -> Void
        let openEcho: () -> Void
        let openSettings: () -> Void
    }

    private let phase: () -> RecordingPhase
    private let requests: Requests

    /// `phase` is asked at build time and not held: what the menu offers is the
    /// session's phase at the moment of the click, and the menu needs the phase
    /// rather than the session it comes from.
    init(phase: @escaping () -> RecordingPhase, requests: Requests) {
        self.phase = phase
        self.requests = requests
    }

    /// Built fresh for each click, so what it offers is the session's phase at
    /// the moment of that click: the menu can never ask for a start over a
    /// running recording, or a second stop over a teardown already under way.
    func build() -> NSMenu {
        let menu = NSMenu()
        switch phase() {
        case .idle:
            menu.addItem(button("Record", #selector(record)))
        case .recording:
            menu.addItem(button("Stop Recording", #selector(stop)))
        case .stopping, .finalizing, .summarizing:
            // Work the user cannot answer, and no copy for it: the design draws
            // this menu with four items and inventing a fifth to narrate a
            // phase is not this file's to do. The island reports post-stop work.
            break
        }
        // Only once there is something for it to separate. SwiftUI's `Menu`
        // dropped a leading divider; `NSMenu` draws it, and the post-stop
        // phases put nothing above this one — a right click during a
        // transcription pass would open on a stray rule.
        if menu.numberOfItems > 0 {
            menu.addItem(.separator())
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

    private func button(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func record() { requests.startRecording() }
    @objc private func stop() { requests.stopRecording() }
    @objc private func openEcho() { requests.openEcho() }
    @objc private func openSettings() { requests.openSettings() }
    @objc private func quit() { NSApp.terminate(nil) }
}
