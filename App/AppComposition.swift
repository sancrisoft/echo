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
import Updates
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

    /// Whether a newer Echo exists. The one instance; Settings, the app menu
    /// and the launch prompt all read it and none keeps a copy.
    let updates: UpdateChecker

    /// Starts an update and reads what a failed one left behind. A value over
    /// the data root, not state.
    let updateInstaller: UpdateInstaller

    /// The only place Echo interrupts: the alert at launch, and the answer the
    /// app menu's Check for Updates owes whoever clicked it.
    let updatePrompt: UpdatePrompt

    /// The main window's navigation state.
    let workspace: WorkspaceModel

    /// Opens the main window from places that have no `openWindow` of their
    /// own (the app menu, the menu bar item).
    let windowOpener: WindowOpener

    /// The menu bar item: Echo's permanent presence, the click that opens the
    /// dashboard and the menu behind the other button.
    let menuBarItem: MenuBarItem

    /// Whether the main window is on screen as soon as the scene is built.
    /// True for `ECHO_OPEN_WINDOW`, and for the one launch that finds this Mac
    /// has never run Echo before. Read by the scene, which SwiftUI builds only
    /// after `start()` has had its say.
    private(set) var opensWindowAtLaunch: Bool

    private let errorLog: ErrorTraceLog
    private let showSettings: () -> Void
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
        opensWindowAtLaunch = environment.opensWindowAtLaunch

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

        // One definition of what opening Settings means, for the two surfaces
        // that ask for it: the app menu's ⌘, and the menu bar item's Settings….
        let showSettings = {
            workspace.section = .settings
            windowOpener.openMainWindow()
        }
        self.showSettings = showSettings
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

        updates = UpdateChecker()
        updateInstaller = UpdateInstaller(dataRoot: dataRoot)
        updatePrompt = UpdatePrompt(checker: updates, installer: updateInstaller, session: session)

        menuBarItem = MenuBarItem(
            contents: MenuBarMenu(
                phase: { session.phase },
                requests: MenuBarMenu.Requests(
                    startRecording: { Task { await session.start() } },
                    stopRecording: { Task { await session.stop() } },
                    openEcho: { windowOpener.openMainWindow() },
                    openSettings: showSettings
                )
            ),
            windowOpener: windowOpener
        )
    }

    /// Starts every launch side effect. Idempotent; a no-op under a test host.
    func start() {
        guard !started else { return }
        started = true
        guard !TestHost.isActive else { return }

        ErrorTrace.configure(log: errorLog)

        // The one launch that shows itself. A fresh install is otherwise a
        // menu bar icon and an island hiding in the cutout: nothing that says
        // where the app went. Marked as taken here, before the scene reads the
        // answer, so every launch after this one is silent again.
        if !settings.hasLaunchedBefore {
            settings.noteLaunched()
            opensWindowAtLaunch = true
        }

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

        // The menu bar item is AppKit's, and AppKit is not up yet: SwiftUI runs
        // this before it creates `NSApplication`. The delegate installs it the
        // moment there is an app to install it into.
        EchoAppDelegate.whenLaunched { [menuBarItem] in menuBarItem.install() }

        // A failed Update Now reopened the Echo that was there and left a
        // report behind; Settings shows it once, and reading it consumes it.
        if let failure = updateInstaller.takeFailureReport() {
            updates.noteInstallFailure(failure)
        }

        // The launch check, and then the daily one. The first check is made
        // here rather than by the timer's initial tick because its answer is
        // the prompt's: an offer is worth more at launch than 30 seconds of
        // quiet, and letting the timer also open with one would mean two
        // requests inside the same minute against GitHub's 60-an-hour limit.
        // The timer's own first tick is therefore a day away, and the
        // preference is still read at every tick after it.
        Task { [updates, settings, updatePrompt, environment] in
            if settings.checkForUpdatesAutomatically {
                await updates.check()
                // A snapshot run renders one surface and quits, and a modal
                // alert blocks it before it can — while `ECHO_INSTALLED_VERSION`
                // is exactly how that surface is given an update to draw.
                if environment.snapshotPath == nil {
                    updatePrompt.offerIfAvailable()
                }
            }
            updates.startAutomaticChecks(
                initialDelay: .seconds(24 * 60 * 60),
                isEnabled: { settings.checkForUpdatesAutomatically }
            )
        }
    }

    /// The app menu's Check for Updates: a check the user asked for, which
    /// always answers.
    func checkForUpdates() {
        Task { [updatePrompt] in await updatePrompt.checkAndReport() }
    }

    /// Shows the settings section in the main window.
    func openSettings() {
        showSettings()
    }
}
