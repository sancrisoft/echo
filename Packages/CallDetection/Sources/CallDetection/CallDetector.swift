//
//  CallDetector.swift
//  CallDetection
//
//  Detection's orchestrator: it owns the mic-activity monitor, the pure
//  session machine and the three timers, and it publishes what a surface has
//  to render — the face, the countdown's real deadline, and the apps currently
//  on a call.
//
//  It holds no policy of its own. Every decision arrives as an `Action` from
//  `CallSessionMachine`; this file turns actions into timers, published state,
//  and the two recording requests it cannot serve itself.
//
//  Why the requests are a seam rather than a call: starting and stopping a
//  recording belongs to `Recording`, which sits ABOVE this package, and the
//  panel that shows a face belongs to `Island`, above it too. So detection
//  asks, and whoever wired it acts — with exactly three verbs, which is the
//  same narrowness the machine's `Action` has. The island's blast radius stays
//  "the same start and stop the menu bar runs".
//

import Audio
import EchoCore
import Foundation
import Observation
import os

/// What detection asks of the surface that wired it. Three verbs, no more:
/// nothing here can touch capture settings, persistence or the summary path.
@MainActor
public struct CallDetectionRequests {

    /// Run the same gated start every other surface runs, narrowed to this
    /// scope.
    public var startRecording: (CaptureScope) -> Void

    /// Run the same stop every other surface runs. It is `async` because
    /// "Meeting saved" must not lie: the face is only shown once this returns,
    /// which is once the meeting is persisted.
    public var stopRecording: () async -> Void

    /// Land the user inside the just-stopped meeting, exactly as a manual stop
    /// does.
    public var openSavedMeeting: () -> Void

    public init(
        startRecording: @escaping (CaptureScope) -> Void,
        stopRecording: @escaping () async -> Void,
        openSavedMeeting: @escaping () -> Void
    ) {
        self.startRecording = startRecording
        self.stopRecording = stopRecording
        self.openSavedMeeting = openSavedMeeting
    }
}

/// The mic-activity side of detection, as this object needs it. A protocol so
/// a test can drive reports without opening Core Audio; `MicActivityMonitor`
/// is the only implementation that ships.
protocol MicActivityWatching: Sendable {
    func start()
    func stop()
}

extension MicActivityMonitor: MicActivityWatching {}

/// Builds the watcher around its callback, because the callback is a
/// constructor parameter: the monitor is `Sendable` and its listeners fire on
/// its own queue, so what that queue reads has to be immutable.
///
/// The callback is main-actor isolated, which makes the hop off the monitor's
/// queue the LIVE factory's business rather than the detector's — and lets a
/// test deliver a report synchronously, on the actor the detector already
/// runs on.
typealias MicActivityWatcherMaking =
    @MainActor (_ onClientsChanged: @escaping @MainActor ([MicCaptureClient]) -> Void) ->
    any MicActivityWatching

/// The installed-browser tier. A seam because the live one asks
/// LaunchServices, and a test's answer must be a fixed table.
typealias InstalledBrowsersReading = @MainActor () -> [ProcessSelector]

/// Arms a one-shot timer and returns the way to cancel it.
///
/// A seam so the tests can prove which timer was armed, for how long, and what
/// firing it does, without sleeping. What each timer event then means to the
/// machine is the machine's own table, tested there.
typealias TimerArming =
    @MainActor (_ seconds: TimeInterval, _ fire: @escaping @MainActor () -> Void) ->
    @MainActor () -> Void

@Observable
@MainActor
public final class CallDetector {

    @ObservationIgnored
    private static let log = Logger(subsystem: AppIdentity.logSubsystem, category: "CallDetection")

    /// What the island shows right now; `nil` while it is hidden. The panel
    /// renders from this, so the machine's face table is the only thing that
    /// can change what is on screen.
    public private(set) var face: IslandFace?

    /// When the pending auto-stop will fire. The countdown face renders the
    /// remaining seconds from this, so the number on screen is the real
    /// deadline rather than a second clock that could drift from it.
    public private(set) var graceDeadline: Date?

    /// The catalogued apps currently capturing the mic — the exact deduped,
    /// catalog-ordered set the machine attributes from (one detection path;
    /// this is a mirror, never a second matcher). A scope picker reads it to
    /// offer per-app choices. Empty while the monitor is off.
    public private(set) var appsInCall: [ProcessSelector] = []

    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let requests: CallDetectionRequests
    @ObservationIgnored private let installedBrowsers: InstalledBrowsersReading
    @ObservationIgnored private let armTimer: TimerArming

    @ObservationIgnored private var machine = CallSessionMachine()
    @ObservationIgnored private var monitor: (any MicActivityWatching)?
    @ObservationIgnored private let makeMonitor: MicActivityWatcherMaking

    /// The monitor's most recent raw report, kept so a settings change
    /// (disabling an app mid-call) can re-run the filter without waiting for
    /// the next Core Audio event. Cleared whenever the monitor stops.
    @ObservationIgnored private var latestClients: [MicCaptureClient] = []

    @ObservationIgnored private var cancelDebounce: (@MainActor () -> Void)?
    @ObservationIgnored private var cancelRetract: (@MainActor () -> Void)?
    @ObservationIgnored private var cancelGrace: (@MainActor () -> Void)?

    /// The live object: a real Core Audio monitor, the real installed-browser
    /// query, and timers that really sleep.
    public convenience init(settings: AppSettings, requests: CallDetectionRequests) {
        self.init(
            settings: settings,
            requests: requests,
            makeMonitor: { onChange in
                MicActivityMonitor(onClientsChanged: { clients in
                    // Each report is a COMPLETE snapshot rather than a delta,
                    // and the machine waits out a 3 s debounce before acting
                    // on one, so even an inverted pair resolves on the next
                    // listener fire.
                    Task { @MainActor in onChange(clients) }
                })
            },
            installedBrowsers: BrowserCatalog.installed,
            armTimer: Self.liveTimer
        )
    }

    init(
        settings: AppSettings,
        requests: CallDetectionRequests,
        makeMonitor: @escaping MicActivityWatcherMaking,
        installedBrowsers: @escaping InstalledBrowsersReading,
        armTimer: @escaping TimerArming
    ) {
        self.settings = settings
        self.requests = requests
        self.makeMonitor = makeMonitor
        self.installedBrowsers = installedBrowsers
        self.armTimer = armTimer
    }

    static let liveTimer: TimerArming = { seconds, fire in
        let task = Task { @MainActor in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            fire()
        }
        return { task.cancel() }
    }

    // MARK: - Lifecycle

    /// Begins detection if the setting allows it, and starts following the
    /// setting. Recording state arrives from above through
    /// `recordingChanged(_:)` — this package sits below `Recording` and cannot
    /// observe a session itself.
    public func start() {
        let monitor = makeMonitor { [weak self] clients in
            self?.report(clients)
        }
        self.monitor = monitor
        observeSetting()
        // The machine starts enabled; only an off setting needs applying, and
        // doing it through the same path keeps the monitor and the machine in
        // step from the first instant.
        applySetting(settings.callDetectionEnabled)
    }

    /// Stops detection entirely: no listener, no timers, no face. The setting
    /// is untouched — this is teardown, not "off".
    ///
    /// Disabling the machine first is what disarms the live timers and hides
    /// the panel, since both are `Action`s; the machine is then replaced
    /// rather than re-enabled, so a restarted detector begins from nothing.
    /// `isRecording` goes with it: whoever restarts detection reports the
    /// truth again.
    public func stop() {
        apply(machine.handle(.setEnabled(false)))
        machine = CallSessionMachine()
        monitor?.stop()
        monitor = nil
        latestClients = []
        appsInCall = []
    }

    // MARK: - Input from above

    /// Whether a recording is running, from any surface. The machine's
    /// suppression rules need the truth, which only `Recording` has.
    public func recordingChanged(_ isRecording: Bool) {
        apply(machine.handle(.recordingChanged(isRecording)))
    }

    // MARK: - Island taps

    public func startTapped() { apply(machine.handle(.startTapped)) }
    public func pillTapped() { apply(machine.handle(.pillTapped)) }
    public func dismissTapped() { apply(machine.handle(.dismissTapped)) }
    public func stopNowTapped() { apply(machine.handle(.stopNowTapped)) }
    public func keepRecordingTapped() { apply(machine.handle(.keepRecordingTapped)) }
    public func openEchoTapped() { apply(machine.handle(.openEchoTapped)) }

    // MARK: - Detection

    private func report(_ clients: [MicCaptureClient]) {
        latestClients = clients
        applyMatchedClients()
    }

    /// Runs the filter over the latest raw report and feeds the machine —
    /// called on every monitor event and again when the disabled set changes,
    /// so disabling an app mid-call dismisses its island immediately.
    private func applyMatchedClients() {
        let apps = CallAppCatalog.matchedApps(
            from: latestClients,
            disabledNames: Set(settings.disabledCallApps),
            browsers: installedBrowsers()
        )
        appsInCall = apps
        apply(machine.handle(.matchedAppsChanged(apps)))
    }

    // MARK: - The setting

    private func observeSetting() {
        withObservationTracking {
            _ = settings.callDetectionEnabled
            _ = settings.disabledCallApps
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, self.monitor != nil else { return }
                self.observeSetting()
                self.settingsChanged()
            }
        }
    }

    /// Applies whatever the settings now say. Split from the observation so a
    /// test can exercise the effect directly; the observation's own job is
    /// only to call this after the value lands (`onChange` fires before it).
    func settingsChanged() {
        applySetting(settings.callDetectionEnabled)
        // A disabled-set change while detection runs re-filters the latest
        // report in place — the mid-call island of a newly disabled app
        // retracts without a Core Audio event.
        if settings.callDetectionEnabled {
            applyMatchedClients()
        }
    }

    /// Both halves of the setting: the machine tears down (or re-arms) its
    /// state, and the monitor stops (or starts) so "off" has no side effects
    /// at all — not even a listener.
    private func applySetting(_ enabled: Bool) {
        apply(machine.handle(.setEnabled(enabled)))
        if enabled {
            monitor?.start()
        } else {
            monitor?.stop()
            // A stopped monitor reports nothing, so the mirror empties with it
            // — a scope picker must never offer apps nobody is watching.
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

            case .startDebounceTimer:
                cancelDebounce?()
                cancelDebounce = armTimer(CallDetectionTiming.startDebounce) { [weak self] in
                    self?.fire(.debounceFired)
                }
            case .cancelDebounceTimer:
                cancelDebounce?()
                cancelDebounce = nil

            case .startRetractTimer(let seconds):
                cancelRetract?()
                cancelRetract = armTimer(seconds) { [weak self] in
                    self?.fire(.retractFired)
                }
            case .cancelRetractTimer:
                cancelRetract?()
                cancelRetract = nil

            case .startGraceTimer:
                cancelGrace?()
                graceDeadline = Date().addingTimeInterval(CallDetectionTiming.endGrace)
                cancelGrace = armTimer(CallDetectionTiming.endGrace) { [weak self] in
                    self?.graceDeadline = nil
                    self?.fire(.graceFired)
                }
            case .cancelGraceTimer:
                cancelGrace?()
                cancelGrace = nil
                graceDeadline = nil

            case .requestStartRecording(let scope):
                requests.startRecording(scope)

            case .requestStopRecording:
                // "Meeting saved" must not lie: the stop returns once the
                // meeting is persisted, so every action after the stop request
                // is applied on the far side of it.
                let deferred = Array(actions[(index + 1)...])
                Self.log.info("Auto-stopping the recording: its call ended")
                Task { [weak self] in
                    await self?.requests.stopRecording()
                    self?.apply(deferred)
                }
                return

            case .openWindowToSavedMeeting:
                requests.openSavedMeeting()
            }
        }
    }

    private func fire(_ event: CallSessionMachine.Event) {
        switch event {
        case .debounceFired: cancelDebounce = nil
        case .retractFired: cancelRetract = nil
        case .graceFired: cancelGrace = nil
        default: break
        }
        apply(machine.handle(event))
    }
}
