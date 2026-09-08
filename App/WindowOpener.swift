//
//  WindowOpener.swift
//  Echo
//
//  Opens the main window from code that has no SwiftUI `openWindow` of its own:
//  the app menu's Settings command and, later, the island. As an LSUIElement
//  agent, activating and opening the window does not reliably raise it — the
//  window can appear behind other apps — so it is forced front on the next
//  run-loop tick, once SwiftUI has created or surfaced the scene.
//

import AppKit
import EchoCore
import Observation
import SwiftUI

@Observable
final class WindowOpener {

    /// The section the window should show when it next opens, if any. The
    /// workspace consumes it on appearance so the window never flashes another
    /// page first.
    var pendingSection: PendingSection?

    enum PendingSection: Sendable {
        case settings
    }

    private var open: ((String) -> Void)?

    /// Called by the bridge view once SwiftUI hands it `openWindow`.
    func register(_ open: @escaping (String) -> Void) {
        self.open = open
    }

    /// Opens (or fronts) the main window.
    func openMainWindow() {
        guard let open else {
            ErrorTrace.record("Main window requested before the opener was registered", category: "WindowOpener")
            return
        }
        // Promote to a Dock/Cmd-Tab app before fronting: the activation
        // policy's own hook only fires once the window becomes key.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        open(EchoWindow.main)
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            NSApp.windows
                .first { $0.identifier?.rawValue == EchoWindow.main }?
                .makeKeyAndOrderFront(nil)
        }
    }

    /// Opens the main window on its settings section.
    func openSettings() {
        pendingSection = .settings
        openMainWindow()
    }
}

/// A zero-size view that captures SwiftUI's `openWindow` for the opener. It
/// sits in the menu bar item's label, the one view an agent app always has.
struct WindowOpenerBridge: View {
    @Environment(\.openWindow) private var openWindow
    let opener: WindowOpener

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onAppear { opener.register { id in openWindow(id: id) } }
    }
}
