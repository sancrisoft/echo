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
        // never quits it. The label is the one view an agent app always has
        // instantiated, so it hosts the bridge that captures `openWindow` for
        // the app menu and the AppKit side.
        MenuBarExtra {
            MenuBarMenu(composition: composition)
        } label: {
            Image(systemName: "waveform")
                .background(WindowOpenerBridge(opener: composition.windowOpener))
        }
        .menuBarExtraStyle(.menu)

        // The main window opens on demand — from the menu bar, ⌘, or a debug
        // flag — never at launch on its own.
        Window("Echo", id: EchoWindow.main) {
            WorkspaceWindow(dataRoot: composition.dataRoot)
                .environment(composition.library)
                .environment(composition.settings)
                .environment(composition.workspace)
                .environment(composition.session)
                .preferredColorScheme(colorSchemeOverride)
                .snapshotIfRequested(composition)
        }
        .defaultLaunchBehavior(composition.environment.opensWindowAtLaunch ? .presented : .suppressed)
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
