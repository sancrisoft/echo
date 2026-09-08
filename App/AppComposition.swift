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

@MainActor
final class AppComposition {

    /// The debug flags this launch was given.
    let environment: LaunchEnvironment

    /// Where everything on disk lives. `ECHO_DATA_ROOT` (DEBUG) points it at a
    /// scratch folder; otherwise it is the folder v1 and v2 share.
    let dataRoot: DataRoot

    /// Persisted preferences.
    let settings: AppSettings

    /// Opens the main window from places that have no `openWindow` of their
    /// own (the app menu, AppKit).
    let windowOpener: WindowOpener

    private let errorLog: ErrorTraceLog
    private var started = false

    init(environment: LaunchEnvironment = .current) {
        self.environment = environment
        dataRoot = environment.dataRootOverride.map(DataRoot.init(url:)) ?? .standard
        settings = AppSettings(dataRoot: dataRoot)
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
    }
}
