//
//  DashboardOpener.swift
//  Echo
//
//  Opening the dashboard from outside the SwiftUI scene.
//
//  SwiftUI's `openWindow` action only exists inside the scene hierarchy, and
//  SP-006's island is an AppKit panel — so the action is captured once from the
//  `MenuBarExtra` label (the one view an agent app always has on screen) and
//  handed to `DashboardOpener`, which the AppKit side calls.
//
//  The fronting dance itself lives here too, so the menu bar and the island
//  share one implementation instead of two that drift.
//

import SwiftUI
import AppKit
import os

@MainActor
enum DashboardOpening {

    /// Opens the dashboard window and actually puts it in front.
    ///
    /// As an `LSUIElement` agent, activating + opening the window doesn't
    /// reliably raise or focus it — the window can appear behind other apps.
    /// It is forced front on the next run-loop tick, once SwiftUI has created
    /// or surfaced the scene, so the CTA always lands the user on the dashboard.
    static func open(using openWindow: OpenWindowAction) {
        NSApp.activate(ignoringOtherApps: true)
        openWindow(id: EchoWindow.dashboard)
        DispatchQueue.main.async {
            // Promote to a Dock/Cmd-Tab app before fronting: the notification
            // hook only fires once the window becomes key, and re-ordering
            // after a policy switch is what keeps it in front.
            EchoAppDelegate.sync()
            NSApp.activate(ignoringOtherApps: true)
            NSApp.windows
                .first { $0.identifier?.rawValue == EchoWindow.dashboard }?
                .makeKeyAndOrderFront(nil)
        }
    }
}

/// The handle AppKit code calls to open the dashboard. Empty until
/// `DashboardOpenerBridge` registers the real action; calling it before then is
/// a no-op rather than a crash — the island simply doesn't open a window.
@MainActor
final class DashboardOpener {

    static let shared = DashboardOpener()

    private var openAction: (() -> Void)?

    func register(_ action: @escaping () -> Void) {
        openAction = action
        #if DEBUG
        MicActivityMonitor.log.info("Dashboard opener registered")
        #endif
    }

    func openDashboard() {
        guard let openAction else {
            ErrorTrace.record(
                "Dashboard open requested before the opener was registered",
                category: "CallDetection"
            )
            return
        }
        openAction()
    }
}

/// Zero-size view living in the `MenuBarExtra` label — always instantiated for
/// an agent app — whose only job is to capture `openWindow` into
/// `DashboardOpener`.
struct DashboardOpenerBridge: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onAppear {
                DashboardOpener.shared.register { DashboardOpening.open(using: openWindow) }
            }
    }
}
