//
//  ActivationPolicy.swift
//  Echo
//
//  Echo is an LSUIElement agent: no Dock icon, present only in the menu bar.
//  macOS hides accessory apps from Cmd-Tab and the Dock even while they own a
//  visible window — the window shows up in Mission Control but there is no way
//  to switch back to it, which reads as "the app is open but gone". So the
//  activation policy follows the main window: `.regular` while it is on screen
//  (minimized counts — it stays switchable), `.accessory` otherwise.
//

import AppKit

final class EchoAppDelegate: NSObject, NSApplicationDelegate {

    func applicationDidFinishLaunching(_ notification: Notification) {
        let center = NotificationCenter.default
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.willCloseNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { _ in
                // `willClose` fires before the window leaves the visible set,
                // so always settle on the next run-loop tick and read the final
                // state rather than trusting the notification.
                DispatchQueue.main.async { Self.sync() }
            }
        }
        Self.sync()
    }

    /// The menu bar item is the app, not the window: closing the window must
    /// never terminate a recording in progress.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Promotes to `.regular` iff the main window is visible; demotes otherwise.
    private static func sync() {
        let mainWindow = NSApp.windows.first {
            $0.isVisible && $0.identifier?.rawValue == EchoWindow.main
        }
        let wanted: NSApplication.ActivationPolicy = mainWindow == nil ? .accessory : .regular
        guard NSApp.activationPolicy() != wanted else { return }
        NSApp.setActivationPolicy(wanted)
        if wanted == .regular, let mainWindow {
            // Promoting an accessory app can leave it behind whatever was
            // frontmost, so re-assert the window the user just opened.
            NSApp.activate(ignoringOtherApps: true)
            mainWindow.makeKeyAndOrderFront(nil)
        }
    }
}
