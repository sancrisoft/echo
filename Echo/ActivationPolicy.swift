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

    /// Promotes to `.regular` while the dashboard OR the native settings
    /// window is on screen, demotes back to `.accessory` when neither is.
    /// Cheap and idempotent — safe to over-call. Without the settings half,
    /// an open Settings window would be unreachable from Cmd-Tab.
    static func sync() {
        let promoting = NSApp.windows.filter {
            $0.isVisible && ($0.identifier?.rawValue == EchoWindow.dashboard || isSettingsWindow($0))
        }
        let desired: NSApplication.ActivationPolicy = promoting.isEmpty ? .accessory : .regular
        guard NSApp.activationPolicy() != desired else { return }
        NSApp.setActivationPolicy(desired)
        if desired == .regular {
            // Promoting an accessory app can leave it behind whatever was
            // frontmost, so re-assert the window the user just opened —
            // the dashboard when it is what's open, else the settings window
            // that triggered the promotion.
            NSApp.activate(ignoringOtherApps: true)
            (promoting.first { $0.identifier?.rawValue == EchoWindow.dashboard } ?? promoting.first)?
                .makeKeyAndOrderFront(nil)
        }
    }

    /// The SwiftUI `Settings` scene's window. Its identifier is the runtime's,
    /// not ours to set — "com_apple_SwiftUI_Settings_window" on this OS
    /// (verified via the ECHO_SETTINGS_PROBE dump). Matched loosely, with the
    /// window title ("Echo Settings", also runtime-owned) as the fallback for
    /// an identifier rename in a future OS; the dashboard's identifier is
    /// "dashboard", so neither test can capture it.
    private static func isSettingsWindow(_ window: NSWindow) -> Bool {
        if window.identifier?.rawValue.localizedCaseInsensitiveContains("settings") == true {
            return true
        }
        return !(window is NSPanel) && window.title.localizedCaseInsensitiveContains("settings")
    }
}
