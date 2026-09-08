//
//  EchoApp.swift
//  Echo
//
//  The app's scenes and nothing else. Everything the scenes show is built and
//  wired in `AppComposition`; every launch side effect starts in
//  `AppComposition.start()`, once, from here.
//

import EchoCore
import SwiftUI

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
        // never quits it. The label is the one view an agent app always has
        // instantiated, so it hosts the bridge that captures `openWindow` for
        // the app menu and the AppKit side.
        MenuBarExtra {
            MenuBarMenu()
                .environment(composition.windowOpener)
        } label: {
            Image(systemName: "waveform")
                .background(WindowOpenerBridge(opener: composition.windowOpener))
        }
        .menuBarExtraStyle(.menu)

        // The main window opens on demand — from the menu bar, ⌘, or a debug
        // flag — never at launch on its own.
        Window("Echo", id: EchoWindow.main) {
            MainWindowPlaceholder()
                .environment(composition.settings)
        }
        .defaultLaunchBehavior(composition.environment.opensWindowAtLaunch ? .presented : .suppressed)
        // No state restoration: the window opens on demand, and restoring it
        // after a force-quit can resurrect a blank window that never
        // reconnects to the scene content.
        .restorationBehavior(.disabled)
        .defaultSize(width: 1100, height: 720)
        .windowResizability(.contentMinSize)
        // ⌘, lands in the main window's settings section. There is no
        // `Settings` scene: a second, bare window with its own Cmd-Tab entry
        // was the worse of two hosts for the same screen.
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { composition.windowOpener.openSettings() }
                    .keyboardShortcut(",", modifiers: .command)
            }
        }
    }
}

/// Stands in for the workspace until the Workspace package lands.
private struct MainWindowPlaceholder: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "waveform")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("Echo")
                .font(.title2.weight(.semibold))
            Text(AppIdentity.version.display)
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(minWidth: 900, minHeight: 560)
    }
}
