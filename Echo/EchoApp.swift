//
//  EchoApp.swift
//  Echo
//
//  Created by Diego Díaz on 22/06/26.
//

import SwiftUI

enum EchoWindow {
    static let dashboard = "dashboard"
}

@main
struct EchoApp: App {
    /// Owns the Dock/Cmd-Tab visibility of the agent app: `.regular` while the
    /// dashboard is on screen, `.accessory` otherwise (see `ActivationPolicy`).
    @NSApplicationDelegateAdaptor(EchoAppDelegate.self) private var appDelegate

    /// Single shared session controller for both the menu bar and the dashboard.
    @State private var controller: RecordingController
    /// Persisted UI state (e.g. the dismissed privacy banner). Loaded once from
    /// `settings.json`; the dashboard reads and mutates it.
    @State private var settings: AppSettings
    /// SP-006's call-detection island. Held here so it lives as long as the
    /// app does; it drives its own AppKit panel, and the menu-bar popup reads
    /// its `appsInCall` for the SP-008 scope selector.
    @State private var callDetection: CallDetectionController

    init() {
        // Reclaim the retired summary model's snapshot (ADR-011): every
        // launch, scoped to exactly the retired repo directories, non-fatal,
        // no dialog. Detached at utility priority so deleting a multi-GB tree
        // never competes with startup on the main thread. "Before or
        // alongside the new model's download" (SP-004) holds without any
        // sequencing: the eager summary download is chained behind the
        // speech-model preload (RecordingController.init), while this fires
        // immediately.
        //
        // Skipped entirely under a test host (see `TestHost`): the host app
        // must be inert scaffolding, never a second instance mutating the
        // real data folder while tests — or a concurrently running real
        // Echo — are working.
        if !TestHost.isActive {
            Task.detached(priority: .utility) {
                RetiredModelCleanup.run()
                // Bound the error trace log's disk footprint: drop daily files
                // older than the retention window. Same fire-and-forget slot —
                // non-fatal, never competes with startup on the main thread.
                await ErrorTrace.shared.prune()
            }
        }

        // The three long-lived objects, wired here because SP-006's call
        // detection needs both of the others. Constructing them is required
        // even under a test host (SwiftUI @State needs values); the side
        // effects live in `start()` and the launch tasks, both gated.
        let recording = RecordingController()
        let settings = AppSettings()
        // The retention and auto-summary seams read the preference at the
        // moment they act; the controller deliberately doesn't hold
        // AppSettings (§3.3, §3.6).
        recording.shouldKeepRecordingsAfterTranscription = { settings.keepRecordingsAfterTranscription }
        recording.shouldAutoGenerateSummaries = { settings.autoGenerateSummaries }
        let callDetection = CallDetectionController(recording: recording, settings: settings)
        if !TestHost.isActive {
            callDetection.start()
        }
        _controller = State(initialValue: recording)
        _settings = State(initialValue: settings)
        _callDetection = State(initialValue: callDetection)
    }

    /// The dashboard opens on demand from the menu bar — never at launch. In
    /// DEBUG builds, ECHO_OPEN_DASHBOARD=1 opens it immediately so the UI can
    /// be driven and screenshotted from the CLI (see DashboardView's
    /// ECHO_SNAPSHOT_PATH hook).
    private static var dashboardLaunchBehavior: SceneLaunchBehavior {
        #if DEBUG
        if ProcessInfo.processInfo.environment["ECHO_OPEN_DASHBOARD"] == "1" { return .presented }
        #endif
        return .suppressed
    }

    var body: some Scene {
        // Lives in the menu bar. Because the app launches as an LSUIElement
        // agent, this keeps Echo running when the dashboard window is closed or
        // minimized (only Force Quit terminates it). While the dashboard *is*
        // open the policy is promoted to `.regular` so the app is reachable
        // from Cmd-Tab and the Dock — see `EchoAppDelegate`.
        MenuBarExtra {
            MenuBarView()
                .environment(controller)
                .environment(settings)
                // SP-008: the popup's scope selector reads `appsInCall` —
                // the same detection state the island renders from.
                .environment(callDetection)
        } label: {
            Image(systemName: controller.isRecording ? "waveform.circle.fill" : "waveform")
                // Captures SwiftUI's `openWindow` for the AppKit side (SP-006's
                // island): the label is the one view an agent app always has
                // instantiated, so it is the earliest reliable hook.
                .background(DashboardOpenerBridge())
        }
        .menuBarExtraStyle(.window)

        // The dashboard opens on demand via "Abrir dashboard"; it must not open
        // automatically at launch.
        Window("Echo", id: EchoWindow.dashboard) {
            DashboardView()
                .environment(controller)
                .environment(settings)
        }
        .defaultLaunchBehavior(Self.dashboardLaunchBehavior)
        // No state restoration: the window opens on demand from the menu bar,
        // and restoring it after a force-quit can resurrect a blank zombie
        // window that never reconnects to the scene content.
        .restorationBehavior(.disabled)
        .defaultSize(width: 1100, height: 720)
        .windowResizability(.contentMinSize)

        // The native settings window (Cmd+, and the menu-bar gear). The same
        // SettingsView the dashboard sidebar embeds — one view, two hosts.
        // `EchoAppDelegate.sync()` keeps the app `.regular` while it is open,
        // exactly as it does for the dashboard.
        Settings {
            SettingsView()
                .environment(controller)
                .environment(settings)
                .environment(callDetection)
                .frame(minWidth: 520, minHeight: 400)
        }
    }
}
