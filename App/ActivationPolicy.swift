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
//  The delegate is also where a reopen arrives — asking for an app that is
//  already running — which for an agent app is the only place the window can
//  be put back from.
//

import AppKit

final class EchoAppDelegate: NSObject, NSApplicationDelegate {

    /// How a reopen puts the main window back. Static because the delegate is
    /// SwiftUI's: the adaptor builds it and keeps it, and `NSApp.delegate` is
    /// not it — SwiftUI puts its own delegate there and forwards. There is one
    /// Echo delegate per process, so one place to leave this is enough.
    private static var openMainWindow: (() -> Void)?

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

    /// Spotlight, Launchpad, `open -a` and the Dock all ask for an already
    /// running app through here. Echo may have no window at all, so without
    /// this a reopen brings the app to the front with nothing to look at,
    /// which is worse than nothing happening.
    ///
    /// This does not reverse "the window opens on demand, never at launch on
    /// its own": a reopen is not a launch, it is the user asking for the app
    /// by name.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        // `hasVisibleWindows` is AppKit's answer about every window the app
        // owns; the question here is only ever about the main one. A minimized
        // main window counts as on screen, and returning true then is exactly
        // right: AppKit's own reopen deminiaturizes it.
        guard Self.mainWindow == nil else { return true }
        Self.openMainWindow?()
        return false
    }

    /// Hands the delegate the one thing it cannot build for itself: the way to
    /// open the main window.
    ///
    /// Called from the bridge that captures `openWindow`, not from
    /// `AppComposition.start()`: SwiftUI builds the `App` before it creates
    /// `NSApplication`, so at launch-wiring time `NSApp` is still nil and there
    /// is nothing to hand this to. The bridge appears once the app is running,
    /// which is the first moment a reopen could arrive anyway.
    static func handleReopen(by openMainWindow: @escaping () -> Void) {
        self.openMainWindow = openMainWindow
    }

    /// The main window while it is on screen. Minimized counts: it stays
    /// switchable, and a reopen is what brings it back.
    private static var mainWindow: NSWindow? {
        NSApp.windows.first { $0.isVisible && $0.identifier?.rawValue == EchoWindow.main }
    }

    /// Promotes to `.regular` iff the main window is visible; demotes otherwise.
    private static func sync() {
        let mainWindow = Self.mainWindow
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
