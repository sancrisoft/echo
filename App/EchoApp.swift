//
//  EchoApp.swift
//  Echo
//
//  The app's scenes and nothing else. Everything the scenes show is built and
//  wired in `AppComposition`; every launch side effect starts in
//  `AppComposition.start()`, once, from here.
//

import DesignSystem
import EchoCore
import Recording
import SwiftUI
import Workspace

/// Window identifiers, for `openWindow(id:)` and the activation policy.
enum EchoWindow {
    static let main = "main"
}

@main
struct EchoApp: App {
    /// Owns the Dock/Cmd-Tab visibility of the agent app: `.regular` while the
    /// main window is on screen, `.accessory` otherwise.
    @NSApplicationDelegateAdaptor(EchoAppDelegate.self) private var appDelegate

    @State private var composition: AppComposition

    init() {
        let composition = AppComposition()
        composition.start()
        _composition = State(initialValue: composition)
    }

    var body: some Scene {
        // Echo lives in the menu bar as an LSUIElement agent: closing the window
        // never quits it. The menu bar item itself is not a scene — it is an
        // `NSStatusItem` built in `MenuBarItem`, because `MenuBarExtra` cannot
        // tell a left click from a right one and the two mean different things.
        //
        // The main window opens on demand — from the menu bar, ⌘, a reopen,
        // or a debug flag — and at launch only on the first launch this Mac
        // ever gives Echo, which is the one that would otherwise leave a new
        // user with nothing on screen to find.
        Window("Echo", id: EchoWindow.main) {
            WorkspaceWindow(dataRoot: composition.dataRoot)
                .environment(composition.library)
                .environment(composition.settings)
                .environment(composition.workspace)
                .environment(composition.session)
                .environment(composition.updates)
                .preferredColorScheme(colorSchemeOverride)
                .snapshotIfRequested(composition)
        }
        .defaultLaunchBehavior(composition.opensWindowAtLaunch ? .presented : .suppressed)
        // No state restoration: the window opens on demand, and restoring it
        // after a force-quit can resurrect a blank window that never
        // reconnects to the scene content.
        .restorationBehavior(.disabled)
        .defaultSize(width: EchoLayout.defaultWindow.width, height: EchoLayout.defaultWindow.height)
        .windowResizability(.contentMinSize)
        // ⌘, lands in the main window's settings section. There is no
        // `Settings` scene: a second, bare window with its own Cmd-Tab entry
        // was the worse of two hosts for the same screen.
        .commands {
            // Where every Mac app puts it: under the app menu, beside
            // Settings. Not the menu bar item — the design draws that menu
            // with four items and this is not one of them.
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { composition.checkForUpdates() }
            }
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { composition.openSettings() }
                    .keyboardShortcut(",", modifiers: .command)
            }
        }
    }

    /// `ECHO_APPEARANCE` (DEBUG) forces an appearance for design review.
    private var colorSchemeOverride: ColorScheme? {
        switch composition.environment.appearanceOverride {
        case .light: return .light
        case .dark: return .dark
        case nil: return nil
        }
    }
}

extension View {
    /// `ECHO_SNAPSHOT_PATH` (DEBUG): render the window to a file and quit.
    /// A no-op in release builds.
    fileprivate func snapshotIfRequested(_ composition: AppComposition) -> some View {
        #if DEBUG
            return modifier(WindowSnapshot(composition: composition))
        #else
            return self
        #endif
    }
}
