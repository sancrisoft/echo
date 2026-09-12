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

import CallDetection
import DesignSystem
import EchoCore
import Foundation
import Island
import Meetings
import ModelDelivery
import Recording
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

    /// The one truth about a recording: phase, live levels, notices, the
    /// meeting being worked on, and the actions.
    let session: RecordingSession

    /// Notices a call and asks for the three things it cannot do itself. It
    /// exists only now that there is a panel to show what it decides:
    /// detection without one could stop a recording with nothing on screen to
    /// explain why.
    let detector: CallDetector

    /// The island: the panel, the face it wears, and the only place detection
    /// and the session meet.
    let island: IslandController

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
        session = RecordingSession(library: library, settings: settings, dataRoot: dataRoot)
        workspace = WorkspaceModel()
        windowOpener = WindowOpener()
        errorLog = ErrorTraceLog(directory: dataRoot.logs)

        // Detection's three verbs, served here because this is the only place
        // that holds all of the session, the window's navigation and the
        // opener at once. Each is the same call every other surface makes:
        // the island's reach is exactly "the start and stop the rest of the
        // app runs", and nothing wider is representable.
        // Bound locally so the three closures capture the three objects and
        // not the composition root: capturing `self` here would put every
        // long-lived object in the app behind a detection request, and leave
        // the root retained by something it owns.
        let session = session
        let workspace = workspace
        let windowOpener = windowOpener
        detector = CallDetector(
            settings: settings,
            requests: CallDetectionRequests(
                startRecording: { scope in Task { await session.start(scope: scope) } },
                stopRecording: { await session.stop() },
                openSavedMeeting: {
                    // The meeting the stop just persisted: the session is
                    // transcribing or summarising it, and that is the one it
                    // is carrying. With none, the window still opens —
                    // landing somewhere is better than a tap that does
                    // nothing.
                    if let meetingID = session.currentMeetingID {
                        workspace.open(meetingID)
                    }
                    windowOpener.openMainWindow()
                }
            )
        )
        island = IslandController(detector: detector, session: session)
    }

    /// Starts every launch side effect. Idempotent; a no-op under a test host.
    func start() {
        guard !started else { return }
        started = true
        guard !TestHost.isActive else { return }

        ErrorTrace.configure(log: errorLog)

        // The design's typefaces, registered with the process before anything
        // draws. Registration is a launch effect, not something a font token
        // does on first use, so it happens exactly once and here. A failure is
        // survivable — `EchoFont` falls back to the system faces the design
        // names as its fallback — but it is never silent.
        for failure in EchoFont.registerBundledTypefaces().failures {
            ErrorTrace.record(
                "A bundled typeface did not register; the interface falls back to the system face",
                category: "EchoFont",
                metadata: ["file": failure.file, "reason": failure.reason]
            )
        }

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
            await library.foldLegacySummaries()
            await library.purgeExpiredTrash()
            await library.backfillWordCounts()
        }

        // Models this build no longer uses, deleted by name. Detached at
        // utility priority beside the log prune: it is pure reclamation, it
        // must never delay a launch, and nothing waits on its result.
        Task.detached(priority: .utility) { [dataRoot] in
            RetiredModelCleanup.run(modelsRoot: dataRoot.models)
        }

        // Pick up where a quit or a crash left off. The two staging sweeps
        // run inside this call, before the enqueue, because the order matters
        // and keeping it inside the session is what makes it impossible to
        // get wrong from out here. Then the first summary scan — one of its
        // four triggers, the other three being each Stop, the window opening,
        // and a model download finishing.
        Task { [session] in
            await session.resumePendingFinalizations()
            session.kickSummaryBackfill()
        }

        // The island goes up before detection starts watching: a call noticed
        // with no panel on screen would be a decision nobody could see being
        // made. It is also the app's permanent presence — the design has it
        // on screen with nothing happening, which is where a recording is
        // started from.
        island.start()
        detector.start()
    }

    /// Shows the settings section in the main window.
    func openSettings() {
        workspace.section = .settings
        windowOpener.openMainWindow()
    }
}
