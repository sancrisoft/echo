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

import EchoCore
import Recording
import SwiftUI

struct MenuBarMenu: View {
    let composition: AppComposition

    /// The session's own phase decides which of the two is offered, so the
    /// menu can never ask for a start over a running recording or a second
    /// stop over a teardown that has already begun. Same gated calls every
    /// other surface makes.
    var body: some View {
        switch composition.session.phase {
        case .idle:
            Button("Record") { Task { await composition.session.start() } }
        case .recording:
            Button("Stop Recording") { Task { await composition.session.stop() } }
        case .stopping, .finalizing, .summarizing:
            // Work the user cannot answer, and no copy for it: the design
            // draws this menu with four items and inventing a fifth to
            // narrate a phase is not this file's to do. The island is where
            // post-stop work is reported.
            EmptyView()
        }
        Divider()
        Button("Open Echo") { composition.windowOpener.openMainWindow() }
        Button("Settings…") { composition.openSettings() }
        Divider()
        Text(AppIdentity.version.display)
        Divider()
        Button("Quit Echo") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q", modifiers: .command)
    }
}
