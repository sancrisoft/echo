//
//  MenuBarMenu.swift
//  Echo
//
//  The menu bar item's menu: the way back into the app when no window is open.
//  Deliberately flat and small; recording controls arrive with the Recording
//  package and the island.
//

import EchoCore
import SwiftUI

struct MenuBarMenu: View {
    @Environment(WindowOpener.self) private var windowOpener

    var body: some View {
        Button("Open Echo") { windowOpener.openMainWindow() }
        Button("Settings…") { windowOpener.openSettings() }
        Divider()
        Text(AppIdentity.version.display)
        Divider()
        Button("Quit Echo") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q", modifiers: .command)
    }
}
