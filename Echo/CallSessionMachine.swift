//
//  CallSessionMachine.swift
//  Echo
//
//  SP-006: the whole behavior of the call-detection island — when it appears,
//  which face it wears, when a recording is offered, and when a forgotten one
//  stops — as a pure, exhaustively table-tested machine.
//
//  Structure mirrors `InputDeviceLifecycleMachine`: Core Audio and AppKit stay
//  thin and manual (`MicActivityMonitor`, `CallIslandPanelController`); every
//  decision, suppression rule and timer edge lives here.
//
//  Two product lines are enforced structurally, not by review:
//
//    • Nothing records without an explicit click. `requestStartRecording` is
//      emitted from exactly one place — the `startTapped` handler — so no
//      sequence of detection or timer events can start capture.
//    • A recording overlapping a detected call never runs unbounded after the
//      call ends. Every path out of `endGrace` either stops the recording or
//      is a deliberate user choice to keep it.
//

import Foundation

/// The island's timing constants (SP-006 §3.8; ship these, tune from lived
/// experience — spec open question 3). Defined once so the machine, the
/// controller's timers and the tests can never disagree.
nonisolated enum CallDetectionTiming {
    /// Catalogued mic capture must persist this long before a call is
    /// considered started, so a blip (an app probing the mic, a device
    /// reconfiguration) never prompts.
    static let startDebounce: TimeInterval = 3
    /// How long a recording survives after the call ends before auto-stopping.
    /// Also the reconnect window: capture resuming inside it cancels silently.
    static let endGrace: TimeInterval = 30
    /// An ignored start prompt collapses to the compact pill after this.
    static let promptRetract: TimeInterval = 15
    /// The "Meeting saved" confirmation retracts after this.
    static let savedRetract: TimeInterval = 8
}

/// What the island shows right now. `nil` means the panel is hidden — the
/// island's resting state, and the only state it has while nothing is
/// happening.
nonisolated enum IslandFace: Equatable, Sendable {
    /// The one face that offers to record. `appName` is island copy only
    /// (ADR-017: never persisted as meeting metadata).
    case startPrompt(appName: String)
    /// The retracted start prompt: a dot and a word, re-expanding on click.
    case compactPill
    /// "Call ended — stopping in Ns". The countdown is rendered from the
    /// deadline the controller publishes, so the view owns no authority.
    case endGrace(appName: String)
    /// Post-auto-stop confirmation, with a way into the saved meeting.
    case saved
}

/// Maps catalogued mic-capture changes, timer expiries, recording-state
/// changes and island taps to island faces and recording requests.
///
/// The `Action` surface is deliberately narrow: it can show a face, arm or
/// cancel one of three timers, ask for a recording start or stop, and open the
/// dashboard. It cannot touch capture, persistence, or the summary path — the
/// island's blast radius is unrepresentable beyond "the same start/stop the
/// menu bar runs".
nonisolated struct CallSessionMachine {

    /// Where the machine is in a call's life.
    ///
    /// `candidate` is the debounce window (capture seen, call not yet
    /// declared); `inCall` is a confirmed call; `endGrace` is a confirmed call
    /// that ended while a recording was running and is now counting down.
    enum Phase: Equatable, Sendable {
        case idle
        case candidate
        case inCall
        case endGrace
    }

    enum Event: Equatable, Sendable {
        /// The catalogued apps currently capturing mic input — deduped, in
        /// catalog order. `[]` means no catalogued process is capturing.
        case matchedAppsChanged([CallApp])
        case debounceFired
        /// `promptRetract` or `savedRetract` — whichever was armed. The face
        /// decides what retracting means, so one event covers both.
        case retractFired
        case graceFired
        /// `RecordingController.state.isRecording` changed (any surface: the
        /// island, the menu bar, or the dashboard).
        case recordingChanged(Bool)
        case startTapped
        case pillTapped
        case dismissTapped
        case stopNowTapped
        case keepRecordingTapped
        case openEchoTapped
        case setEnabled(Bool)
    }

    enum Action: Equatable, Sendable {
        /// Show this face; `nil` hides the panel.
        case setFace(IslandFace?)
        /// Arm for `CallDetectionTiming.startDebounce`.
        case startDebounceTimer
        case cancelDebounceTimer
        /// Arm for the carried interval (`promptRetract` or `savedRetract`).
        case startRetractTimer(TimeInterval)
        case cancelRetractTimer
        /// Arm for `CallDetectionTiming.endGrace`.
        case startGraceTimer
        case cancelGraceTimer
        /// Run the same gated start the menu bar's button runs (ADR-009).
        case requestStartRecording
        /// Run the same stop the menu bar's button runs (SP-005 sequencing
        /// inherited, not reimplemented).
        case requestStopRecording
        case openDashboardToSavedMeeting
    }

    /// The feature's setting (SP-006: on by default). Off means inert: no
    /// face, no timers, no requests.
    private(set) var enabled = true

    private(set) var phase: Phase = .idle

    /// The app the current call is attributed to — the first catalog match in
    /// the reported set. Non-nil for the whole life of a call (`candidate`
    /// through `endGrace`), which is what makes the face copy honest.
    private(set) var currentApp: CallApp?

    /// Mirrors `RecordingController.state.isRecording`. Tracked even while the
    /// feature is disabled: a machine that forgot a live recording would
    /// prompt over it when re-enabled (rule 5).
    private(set) var isRecording = false

    /// Set by ✕ and by a manual stop mid-call: this call gets no further start
    /// prompt (rules 5 and 9). Scoped to the call — it resets when capture
    /// stops, so the next call prompts again.
    private(set) var dismissedThisCall = false

    /// Set by "Keep recording": the *next* end of this call raises no grace
    /// countdown. Survives the return to idle and is cleared when a new call
    /// is confirmed, which is exactly "until a new call starts (and ends)"
    /// (rule 6).
    private(set) var keptRecordingLatch = false

    /// The face currently on screen, kept in step with every `setFace` emitted
    /// so face-dependent transitions (retract, taps) need no view feedback.
    private(set) var face: IslandFace?

    /// Copy for the current call. The fallback is unreachable while a call is
    /// live (a call is only ever confirmed with a match in hand); the island
    /// renders an app-less prompt honestly rather than inventing a name.
    private var appName: String { currentApp?.displayName ?? "" }

    @discardableResult
    mutating func handle(_ event: Event) -> [Action] {
        // The setting is the outermost gate: while off, the only event that
        // does anything is turning it back on. Recording state is still
        // mirrored (it is observed external truth, not feature state) so
        // re-enabling starts from reality.
        if case .setEnabled(let on) = event { return setEnabled(on) }
        guard enabled else {
            if case .recordingChanged(let recording) = event { isRecording = recording }
            return []
        }

        switch event {
        case .setEnabled:
            return []   // handled above
        case .matchedAppsChanged(let apps):
            return handleMatchedApps(apps)
        case .debounceFired:
            return handleDebounceFired()
        case .retractFired:
            return handleRetractFired()
        case .graceFired:
            return handleGraceFired()
        case .recordingChanged(let recording):
            return handleRecordingChanged(recording)
        case .startTapped:
            return handleStartTapped()
        case .pillTapped:
            return handlePillTapped()
        case .dismissTapped:
            return handleDismissTapped()
        case .stopNowTapped:
            return handleStopNowTapped()
        case .keepRecordingTapped:
            return handleKeepRecordingTapped()
        case .openEchoTapped:
            return handleOpenEchoTapped()
        }
    }

    // MARK: - Detection

    private mutating func handleMatchedApps(_ apps: [CallApp]) -> [Action] {
        switch phase {
        case .idle:
            // Catalogued capture appeared: start the debounce, declare nothing
            // yet. A new call also clears the previous call's dismissal.
            guard let first = apps.first else { return [] }
            phase = .candidate
            currentApp = first
            dismissedThisCall = false
            return [.startDebounceTimer]

        case .candidate:
            guard let first = apps.first else {
                // Capture stopped inside the debounce window: a blip, not a
                // call. Nothing was ever shown, so nothing needs hiding.
                phase = .idle
                currentApp = nil
                return [.cancelDebounceTimer]
            }
            // The reported set changed shape while the debounce runs (a helper
            // process joined, a second app opened the mic): same pending call,
            // re-attributed, timer untouched.
            currentApp = first
            return []

        case .inCall:
            guard apps.isEmpty else {
                // Capture continues; only attribution can change.
                currentApp = apps[0]
                return []
            }
            guard isRecording else {
                // The call ended with nothing recording: retract whatever the
                // island was showing and forget the call.
                endCall()
                return [.cancelRetractTimer, .setFace(nil)]
            }
            guard !keptRecordingLatch else {
                // Defense in depth for rule 6: a call whose end the user chose
                // to record through never raises a second countdown. Confirming
                // a call clears the latch, so this branch is unreachable today
                // — it exists so the rule survives a future path into `inCall`
                // that skips the debounce.
                endCall()
                return [.setFace(nil)]
            }
            // A recording overlapped this call and the call is over: count
            // down to the stop the user forgot.
            phase = .endGrace
            face = .endGrace(appName: appName)
            return [.setFace(face), .startGraceTimer]

        case .endGrace:
            guard let first = apps.first else { return [] }
            // Capture resumed inside the grace (reconnect, brief drop): the
            // pending stop cancels silently and the call continues. No new
            // debounce — recording continuity wins over re-confirmation.
            phase = .inCall
            currentApp = first
            face = nil
            return [.cancelGraceTimer, .setFace(nil)]
        }
    }

    private mutating func handleDebounceFired() -> [Action] {
        guard phase == .candidate else { return [] }
        phase = .inCall
        // A newly confirmed call clears the previous call's "keep recording"
        // suppression: it covered the call that was running when the user
        // pressed it, not this one.
        keptRecordingLatch = false
        // Already recording (any surface): the offer is moot, so the call runs
        // quietly and only its end raises the island (rules 5, 8).
        guard !isRecording, !dismissedThisCall else { return [] }
        face = .startPrompt(appName: appName)
        return [.setFace(face), .startRetractTimer(CallDetectionTiming.promptRetract)]
    }

    // MARK: - Timers

    private mutating func handleRetractFired() -> [Action] {
        switch face {
        case .startPrompt:
            // Politeness: an ignored offer shrinks instead of nagging.
            face = .compactPill
            return [.setFace(face)]
        case .saved:
            face = nil
            return [.setFace(nil)]
        case .compactPill, .endGrace, .none:
            // Nothing retractable is showing — a straggler from a cancelled
            // timer.
            return []
        }
    }

    private mutating func handleGraceFired() -> [Action] {
        guard phase == .endGrace else { return [] }
        endCall()
        face = .saved
        // `isRecording` stays true until the controller reports the stop; the
        // machine is back in idle, where recording changes are tracked only.
        return [.requestStopRecording, .setFace(face), .startRetractTimer(CallDetectionTiming.savedRetract)]
    }

    // MARK: - Recording state (any surface)

    private mutating func handleRecordingChanged(_ recording: Bool) -> [Action] {
        guard recording != isRecording else { return [] }
        isRecording = recording

        if recording {
            // Started elsewhere while the island was offering: the offer is
            // answered, so it goes away without a word.
            switch face {
            case .startPrompt, .compactPill:
                face = nil
                return [.cancelRetractTimer, .setFace(nil)]
            case .endGrace, .saved, .none:
                return []
            }
        }

        switch phase {
        case .endGrace:
            // A manual stop won the race with the countdown: honour it, drop
            // the pending auto-stop, no second stop, no orphan island.
            endCall()
            return [.cancelGraceTimer, .setFace(nil)]
        case .inCall:
            // Stopped by hand mid-call: not a mistake to correct, so this call
            // is not offered a recording again (rule 5).
            dismissedThisCall = true
            return []
        case .idle, .candidate:
            return []
        }
    }

    // MARK: - Island taps

    private mutating func handleStartTapped() -> [Action] {
        // The single source of `requestStartRecording` in the whole feature.
        guard phase == .inCall, case .startPrompt = face else { return [] }
        face = nil
        return [.cancelRetractTimer, .setFace(nil), .requestStartRecording]
    }

    private mutating func handlePillTapped() -> [Action] {
        guard phase == .inCall, face == .compactPill, !dismissedThisCall else { return [] }
        face = .startPrompt(appName: appName)
        return [.setFace(face), .startRetractTimer(CallDetectionTiming.promptRetract)]
    }

    private mutating func handleDismissTapped() -> [Action] {
        switch face {
        case .startPrompt, .compactPill:
            dismissedThisCall = true
            face = nil
            return [.cancelRetractTimer, .setFace(nil)]
        case .endGrace, .saved, .none:
            // The end-of-call countdown has its own two answers ("Stop now",
            // "Keep recording"); it carries no ✕.
            return []
        }
    }

    private mutating func handleStopNowTapped() -> [Action] {
        guard phase == .endGrace else { return [] }
        endCall()
        face = .saved
        return [
            .cancelGraceTimer,
            .requestStopRecording,
            .setFace(face),
            .startRetractTimer(CallDetectionTiming.savedRetract),
        ]
    }

    private mutating func handleKeepRecordingTapped() -> [Action] {
        guard phase == .endGrace else { return [] }
        endCall()
        keptRecordingLatch = true
        return [.cancelGraceTimer, .setFace(nil)]
    }

    private mutating func handleOpenEchoTapped() -> [Action] {
        guard face == .saved else { return [] }
        face = nil
        return [.cancelRetractTimer, .setFace(nil), .openDashboardToSavedMeeting]
    }

    // MARK: - Setting

    private mutating func setEnabled(_ on: Bool) -> [Action] {
        guard on != enabled else { return [] }
        enabled = on
        resetCallState()
        guard !on else { return [] }
        // Off takes effect immediately in the middle of anything: the island
        // goes away and every timer is disarmed. All three cancels are emitted
        // unconditionally — they are idempotent in the controller, and knowing
        // which one was armed is not worth extra state.
        return [.cancelDebounceTimer, .cancelRetractTimer, .cancelGraceTimer, .setFace(nil)]
    }

    // MARK: - Helpers

    /// Returns to the resting state at the end of a call, island hidden.
    /// Callers that end a call *into* a face (the countdown's "Meeting saved")
    /// set `face` afterwards. Deliberately leaves `isRecording` (observed
    /// external truth) and `keptRecordingLatch` (which spans calls by design)
    /// to their callers.
    private mutating func endCall() {
        phase = .idle
        currentApp = nil
        dismissedThisCall = false
        face = nil
    }

    /// Forgets everything about the current call. Used by the setting on both
    /// edges so re-enabling starts clean.
    private mutating func resetCallState() {
        phase = .idle
        currentApp = nil
        dismissedThisCall = false
        keptRecordingLatch = false
        face = nil
    }
}
