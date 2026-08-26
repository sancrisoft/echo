//
//  CallDetectionController.swift
//  Echo
//
//  SP-006's orchestrator: owns the mic-activity monitor, the pure session
//  machine, the three timers and the island panel, and is the only place in the
//  feature that talks to `RecordingController`.
//
//  It holds no policy of its own. Every decision arrives as an `Action` from
//  `CallSessionMachine`; this file just turns actions into timers, panel
//  visibility and the same start/stop the menu bar's buttons run.
//

import Foundation
import Observation
import os

@Observable
@MainActor
final class CallDetectionController {

    private let recording: RecordingController
    private let settings: AppSettings
    private let monitor = MicActivityMonitor()
    private var machine = CallSessionMachine()
    private let panel = CallIslandPanelController()

    /// What the island shows right now; `nil` while it is hidden. The island
    /// view renders from this, so the machine's face table is the only thing
    /// that can change what is on screen.
    private(set) var face: IslandFace?

    /// When the pending auto-stop will fire. The countdown face renders the
    /// remaining seconds from this, so the number on screen is the real
    /// deadline rather than a second clock that could drift from it.
    private(set) var graceDeadline: Date?

    /// The catalogued apps currently capturing the mic — the exact deduped,
    /// catalog-ordered set the machine attributes from (one detection path;
    /// this is a mirror, never a second matcher). SP-008's scope popup reads
    /// it to offer per-app choices. Empty while the monitor is off.
    private(set) var appsInCall: [CallApp] = []

    /// The monitor's most recent raw report, kept so a settings change
    /// (disabling an app mid-call) can re-run the filter without waiting for
    /// the next Core Audio event. Cleared whenever the monitor stops.
    @ObservationIgnored private var latestClients: [MicActivityMonitor.Client] = []

    @ObservationIgnored private var debounceTask: Task<Void, Never>?
    @ObservationIgnored private var retractTask: Task<Void, Never>?
    @ObservationIgnored private var graceTask: Task<Void, Never>?

    init(recording: RecordingController, settings: AppSettings) {
        self.recording = recording
        self.settings = settings
    }

    /// Begins detection if the setting allows it, and starts following both the
    /// recording state and the setting.
    func start() {
        #if DEBUG
        // CLI verification hook for the panel itself (the slot
        // ECHO_OPEN_DASHBOARD / ECHO_SNAPSHOT_PATH already use): show one face
        // at launch and leave it there, so placement, sizing and non-activation
        // can be checked from a screenshot without waiting for a real call.
        // Detection stays off in this mode — it is a rendering harness only.
        if let name = ProcessInfo.processInfo.environment["ECHO_ISLAND_PREVIEW"],
           let face = Self.previewFace(named: name) {
            if case .endGrace = face {
                graceDeadline = Date().addingTimeInterval(CallDetectionTiming.endGrace)
            }
            apply([.setFace(face)])
            if let path = ProcessInfo.processInfo.environment["ECHO_ISLAND_SNAPSHOT_PATH"] {
                Task { @MainActor [panel] in
                    // Let SwiftUI lay the face out and CoreAnimation commit.
                    try? await Task.sleep(for: .milliseconds(1200))
                    panel.snapshot(to: path)
                }
            }
            return
        }
        #endif

        monitor.onClientsChanged = { [weak self] clients in
            guard let self else { return }
            self.latestClients = clients
            self.applyMatchedClients()
        }
        observeRecordingState()
        observeSetting()
        // The machine starts enabled; only an off setting needs applying, and
        // doing it through the same path keeps the monitor and the machine in
        // step from the first instant.
        applySetting(settings.callDetectionEnabled)
    }

    #if DEBUG
    private static func previewFace(named name: String) -> IslandFace? {
        // ECHO_ISLAND_PREVIEW_APP renders the face with a chosen app name, so
        // the widest catalog names ("Google Chrome", "Microsoft Teams") can be
        // checked for wrapping without waiting for a call in that app.
        let appName = ProcessInfo.processInfo.environment["ECHO_ISLAND_PREVIEW_APP"] ?? "Zoom"
        switch name {
        case "startPrompt": return .startPrompt(appName: appName, scoped: true)
        case "compactPill": return .compactPill
        case "endGrace": return .endGrace(appName: appName)
        case "saved": return .saved
        default: return nil
        }
    }
    #endif

    /// The apps behind a set of mic clients: deduped, in catalog order, so
    /// attribution is deterministic when several apps capture at once.
    /// `disabledNames` drops apps the user excluded in Settings — filtered
    /// HERE, the single matcher call site, so a disabled app is invisible
    /// everywhere downstream (island, scope dropdown, auto-scope; decision
    /// §2.6). Names, not prefixes: one displayName covers all of an app's
    /// catalog prefixes, and a stale name (catalog renamed the app) is
    /// harmlessly ignored because nothing matches it.
    ///
    /// `browsers` is the installed-browser tier (`BrowserCatalog`), ordered
    /// after the curated table so a Zoom call in front of an open browser tab
    /// is still attributed to Zoom. A browser the curated table already names
    /// resolves to the curated entry, so it can never appear twice.
    static func matchedApps(
        from clients: [MicActivityMonitor.Client],
        disabledNames: Set<String> = [],
        browsers: [CallApp] = []
    ) -> [CallApp] {
        let matched = Set(clients.compactMap {
            CallAppCatalog.match(
                bundleID: $0.bundleID,
                appBundleID: $0.appBundleID,
                browsers: browsers
            )
        })
        var seen = Set<CallApp>()
        return (CallAppCatalog.apps + browsers).filter {
            seen.insert($0).inserted
                && matched.contains($0)
                && !disabledNames.contains($0.displayName)
        }
    }

    /// Runs the filter over the latest raw report and feeds the machine —
    /// called on every monitor event and again when the disabled set changes,
    /// so disabling an app mid-call dismisses its island immediately.
    private func applyMatchedClients() {
        let apps = Self.matchedApps(
            from: latestClients,
            disabledNames: Set(settings.disabledCallApps),
            browsers: BrowserCatalog.installed()
        )
        appsInCall = apps
        apply(machine.handle(.matchedAppsChanged(apps)))
    }

    // MARK: - Island taps

    func startTapped() { apply(machine.handle(.startTapped)) }
    func pillTapped() { apply(machine.handle(.pillTapped)) }
    func dismissTapped() { apply(machine.handle(.dismissTapped)) }
    func stopNowTapped() { apply(machine.handle(.stopNowTapped)) }
    func keepRecordingTapped() { apply(machine.handle(.keepRecordingTapped)) }
    func openEchoTapped() { apply(machine.handle(.openEchoTapped)) }

    // MARK: - Observation

    /// Follows `isRecording` from every surface (menu bar, dashboard, island)
    /// so the machine's suppression rules see the truth. `onChange` fires
    /// *before* the value lands, hence the main-actor hop before reading it.
    private func observeRecordingState() {
        withObservationTracking {
            _ = recording.state.isRecording
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.observeRecordingState()
                self.apply(self.machine.handle(.recordingChanged(self.recording.state.isRecording)))
            }
        }
    }

    private func observeSetting() {
        withObservationTracking {
            _ = settings.callDetectionEnabled
            _ = settings.disabledCallApps
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.observeSetting()
                self.applySetting(self.settings.callDetectionEnabled)
                // A disabled-set change while detection runs re-filters the
                // latest report in place — the mid-call island of a newly
                // disabled app retracts without a Core Audio event.
                if self.settings.callDetectionEnabled {
                    self.applyMatchedClients()
                }
            }
        }
    }

    /// Both halves of the setting: the machine tears down (or re-arms) its
    /// state, and the monitor stops (or starts) so "off" has no side effects at
    /// all — not even a listener.
    private func applySetting(_ enabled: Bool) {
        apply(machine.handle(.setEnabled(enabled)))
        if enabled {
            monitor.start()
        } else {
            monitor.stop()
            // A stopped monitor reports nothing, so the mirror empties with it
            // — the popup must never offer apps nobody is watching.
            appsInCall = []
            latestClients = []
        }
    }

    // MARK: - Applying actions

    private func apply(_ actions: [CallSessionMachine.Action]) {
        for (index, action) in actions.enumerated() {
            switch action {
            case .setFace(let face):
                self.face = face
                if let face {
                    panel.show(face, controller: self)
                } else {
                    panel.hide()
                }

            case .startDebounceTimer:
                debounceTask = armTimer(CallDetectionTiming.startDebounce, event: .debounceFired)
            case .cancelDebounceTimer:
                debounceTask?.cancel()
                debounceTask = nil

            case .startRetractTimer(let seconds):
                retractTask = armTimer(seconds, event: .retractFired)
            case .cancelRetractTimer:
                retractTask?.cancel()
                retractTask = nil

            case .startGraceTimer:
                graceDeadline = Date().addingTimeInterval(CallDetectionTiming.endGrace)
                graceTask = armTimer(CallDetectionTiming.endGrace, event: .graceFired) { [weak self] in
                    self?.graceDeadline = nil
                }
            case .cancelGraceTimer:
                graceTask?.cancel()
                graceTask = nil
                graceDeadline = nil

            case .requestStartRecording(let scope):
                startRecording(scope: scope)

            case .requestStopRecording:
                // "Meeting saved" must not lie: `stop()` returns once the
                // meeting is persisted, so every action after the stop request
                // is applied on the far side of it (SP-006 Quality Safeguards).
                let deferred = Array(actions[(index + 1)...])
                Task { [weak self] in
                    await self?.stopRecording()
                    self?.apply(deferred)
                }
                return

            case .openDashboardToSavedMeeting:
                // Land the user inside the just-stopped meeting, exactly as the
                // menu bar's Stop does.
                recording.pendingLiveDetailOpen = true
                DashboardOpener.shared.openDashboard()
            }
        }
    }

    /// One timer slot: sleeping tasks replace their predecessor, and a
    /// cancelled one never feeds the machine.
    private func armTimer(
        _ seconds: TimeInterval,
        event: CallSessionMachine.Event,
        beforeFiring: (@MainActor () -> Void)? = nil
    ) -> Task<Void, Never> {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, let self else { return }
            beforeFiring?()
            self.apply(self.machine.handle(event))
        }
    }

    // MARK: - Recording (the same paths the menu bar runs)

    private func startRecording(scope: CaptureScope) {
        Task { [weak self] in
            guard let self, !self.recording.state.isRecording else { return }
            await self.recording.start(scope: scope)
        }
    }

    /// Guarded on "still recording" so a manual stop that won the race with the
    /// countdown can never be followed by a second stop.
    private func stopRecording() async {
        guard recording.state.isRecording else { return }
        MicActivityMonitor.log.info("Auto-stopping the recording: its call ended")
        await recording.stop()
    }
}
