//
//  ActivationPolicy.swift
//  Echo
//

import AppKit

/// Echo ships as an `LSUIElement` agent so the menu bar item keeps the app
/// alive with no windows on screen (see `EchoApp`). The cost is that macOS
/// hides accessory apps from Cmd-Tab and the Dock *even while they own a
/// visible window* — the dashboard shows up in Mission Control but there is no
/// way to switch back to it, which reads as "the app is open but gone".
///
/// So the policy tracks the dashboard instead of being fixed at launch:
/// `.regular` (Dock icon + Cmd-Tab) for as long as a dashboard window is on
/// screen, back to `.accessory` once it closes. Minimizing keeps the window in
/// `NSApp.windows` as visible, so a minimized dashboard stays switchable.
@MainActor
final class EchoAppDelegate: NSObject, NSApplicationDelegate {
    private var observers: [NSObjectProtocol] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        let center = NotificationCenter.default
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.willCloseNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated {
                    // `willClose` fires *before* the window leaves the visible
                    // set, so always settle on the next run-loop tick and read
                    // the final state rather than trusting the notification.
                    DispatchQueue.main.async { Self.sync() }
                }
            })
        }
        Self.sync()
    }

    /// The menu bar item is the app, not the window: closing the dashboard must
    /// never terminate a recording in progress.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    /// Promotes to `.regular` while the dashboard is on screen, demotes back to
    /// `.accessory` when it isn't. Cheap and idempotent — safe to over-call.
    static func sync() {
        let dashboardIsOpen = NSApp.windows.contains {
            $0.isVisible && $0.identifier?.rawValue == EchoWindow.dashboard
        }
        let desired: NSApplication.ActivationPolicy = dashboardIsOpen ? .regular : .accessory
        guard NSApp.activationPolicy() != desired else { return }
        NSApp.setActivationPolicy(desired)
        if desired == .regular {
            // Promoting an accessory app can leave it behind whatever was
            // frontmost, so re-assert the dashboard the user just opened.
            NSApp.activate(ignoringOtherApps: true)
            NSApp.windows
                .first { $0.identifier?.rawValue == EchoWindow.dashboard }?
                .makeKeyAndOrderFront(nil)
        }
    }
}
