//
//  AppComposition.swift
//  Echo
//
//  The composition root: builds every long-lived object the app needs, wires
//  them together, and starts their side effects — once, from `start()`, and
//  never from an initializer. That single door is where the test-host guard
//  lives: under `xcodebuild test` the real app is the host process, and it must
//  stay inert scaffolding that touches no data folder (ADR-004).
//

import EchoCore
import Foundation
import Meetings
import Workspace

@MainActor
final class AppComposition {

    /// The debug flags this launch was given.
    let environment: LaunchEnvironment

    /// Where everything on disk lives. `ECHO_DATA_ROOT` (DEBUG) points it at a
    /// scratch folder; otherwise it is the folder v1 and v2 share (ADR-005).
    let dataRoot: DataRoot

    /// Persisted preferences.
    let settings: AppSettings

    /// The meeting library: disk is the truth, this is the main-actor cache.
    let library: MeetingLibrary

    /// The main window's navigation state.
    let workspace: WorkspaceModel

    /// Opens the main window from places that have no `openWindow` of their
    /// own (the app menu, the menu bar item).
    let windowOpener: WindowOpener

    private let errorLog: ErrorTraceLog
    private var started = false

    init(environment: LaunchEnvironment = .current) {
        self.environment = environment
        dataRoot = environment.dataRootOverride.map(DataRoot.init(url:)) ?? .standard
        settings = AppSettings(dataRoot: dataRoot)
        library = MeetingLibrary(dataRoot: dataRoot)
        workspace = WorkspaceModel()
        windowOpener = WindowOpener()
        errorLog = ErrorTraceLog(directory: dataRoot.logs)
    }

    /// Starts every launch side effect. Idempotent; a no-op under a test host.
    func start() {
        guard !started else { return }
        started = true
        guard !TestHost.isActive else { return }

        ErrorTrace.configure(log: errorLog)

        // Bound the error trace log's disk footprint. Detached at utility
        // priority so it never competes with startup on the main thread.
        Task.detached(priority: .utility) { [errorLog] in
            await errorLog.prune()
        }

        // The library: fold any legacy summary.json into summary.md (every
        // launch, idempotent, non-fatal per meeting), load the headers, drop
        // trash past its retention, then fill in word counts older meetings
        // never had. Reads first so the window has rows as soon as it opens;
        // the housekeeping that writes follows.
        Task { [library] in
            await library.refresh()
            await library.store.migrateLegacySummaries()
            await library.purgeExpiredTrash()
            await library.refresh()
            await library.backfillWordCounts()
        }
    }

    /// Shows the settings section in the main window.
    func openSettings() {
        workspace.section = .settings
        windowOpener.openMainWindow()
    }
}
