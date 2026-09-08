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
    let composition: AppComposition

    var body: some View {
        Button("Open Echo") { composition.windowOpener.openMainWindow() }
        Button("Settings…") { composition.openSettings() }
        Divider()
        Text(AppIdentity.version.display)
        Divider()
        Button("Quit Echo") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q", modifiers: .command)
    }
}
