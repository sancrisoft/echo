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
            let apps = Self.matchedApps(from: clients)
            self.appsInCall = apps
            self.apply(self.machine.handle(.matchedAppsChanged(apps)))
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
        switch name {
        case "startPrompt": return .startPrompt(appName: "Zoom", scoped: true)
        case "compactPill": return .compactPill
        case "endGrace": return .endGrace(appName: "Zoom")
        case "saved": return .saved
        default: return nil
        }
    }
    #endif

    /// The catalogued apps behind a set of mic clients: deduped, in catalog
    /// order, so attribution is deterministic when several apps capture at once.
    private static func matchedApps(from clients: [MicActivityMonitor.Client]) -> [CallApp] {
        let matched = Set(clients.compactMap { CallAppCatalog.match(bundleID: $0.bundleID) })
        return CallAppCatalog.apps.filter(matched.contains)
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
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.observeSetting()
                self.applySetting(self.settings.callDetectionEnabled)
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
            // Blocked on a not-ready speech model (ADR-009): the island never
            // shows a recording face it can't back up — the dashboard opens
            // with the explanatory dialog and the live download state.
            if self.recording.recordingAwaitingSpeechModel {
                DashboardOpener.shared.openDashboard()
            }
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
