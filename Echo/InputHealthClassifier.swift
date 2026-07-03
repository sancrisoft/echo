//
//  InputHealthClassifier.swift
//  Echo
//
//  Input-health classification for SP-002's "no silent dropout" and
//  "earbuds combo resolved or surfaced" criteria (US-3, US-4, US-6).
//
//  "Input health" (glossary) is the recording-time classification of an
//  input channel's usability: usable, sustained-gated-out, or unsupported
//  combination. The classifier consumes the per-chunk gate-decision record
//  stream (both channels) plus input-device signals, tracks sustained-discard
//  episodes, and drives the input-health notice — closing the "silent
//  dropout" signature where the waveform shows live signal while the speech
//  gates discard every chunk before Whisper sees it.
//
//  ADR-006, followed to the letter: this is an OBSERVATIONAL classifier,
//  separate from the SP-001 echo-handling mode machine. It raises and clears
//  notices and never switches the audio path — structurally: `Effect` can
//  only express notice effects, so a path switch, a gain change, or a capture
//  stop is unrepresentable (the same way `EchoModeMachine.Effect` makes a
//  stop-recording outcome unrepresentable). There is deliberately no feedback
//  from classification into the signal being classified.
//

import Foundation

/// Deterministic, observational input-health classifier (ADR-006).
///
/// Pure logic in the `EchoModeMachine` mold: events in, at most one notice
/// effect out, fully table-testable. Time never comes from a clock — the
/// gate-decision records' own chunk durations are the time base, so the
/// classifier is replayable from logged decisions alone.
///
/// Episode semantics (one per channel, independently):
/// - Dropped chunks whose stats clear the discarded-activity heuristic below
///   accumulate their duration; crossing the onset bound raises the channel's
///   notice once per episode (SP-002 Reliability: no flapping spam).
/// - A transcribed chunk on the channel is recovery: it ends the episode and
///   clears an active notice, and a later episode may notify again.
nonisolated struct InputHealthClassifier {

    /// The observational inputs. Gate decisions arrive for both channels at
    /// chunk cadence; device signals arrive from the input-device machinery.
    enum Event {
        /// One finalized chunk's speech-gate decision (SP-002 US-12 stream).
        case gateDecision(GateDecisionRecord)
        /// The mic's capture device changed — a switch to a new device, or
        /// the device being lost/restored (the S4 lifecycle machine's
        /// restart/stop actions, which fire only on real identity changes).
        case micDeviceChanged
    }

    /// The only side effects the classifier can request — notices, nothing
    /// else. ADR-006's "never switches processing" is structural here: there
    /// is no effect case that could touch capture, the AEC, the gates, or
    /// the mode machine, so no event sequence can change the audio path.
    enum Effect: Equatable, Sendable {
        /// Mic-channel sustained-gated-out episode (SP-002 US-3): the user's
        /// speech is being wholly discarded — surface it during the meeting.
        case showMicHealthNotice
        /// System-channel sustained-gated-out episode (SP-002 US-6): the
        /// Team channel is silently mute — the earbuds-style unsupported
        /// combination, including when it begins mid-recording.
        case showSystemHealthNotice
        /// The channel recovered (or its evidence no longer applies): the
        /// notice clears automatically (SP-002 Reliability).
        case clearHealthNotice(AudioChannel)
    }

    // MARK: - Onset bound and discrimination thresholds

    // TUNABLE (SP-002 OQ7): every constant in this block is a provisional,
    // deliberately conservative starting point. The exact numbers that
    // separate "discarded speech-like activity" from "discarded ambient room
    // tone" are open question 7 — they get fixed against the recorded device
    // fixtures (DJI, earbuds, ambient/quiet-room takes) in the measurement
    // phase. Structure is what this slice pins; keep all knobs here.

    /// Accumulated discarded-activity duration at which the notice fires —
    /// SP-002's "starting point 30 seconds of sustained discard, the exact
    /// bound a tunable fixed against the recorded fixtures".
    static let onsetBound: TimeInterval = 30

    /// The waveform meter's visible floor (== the gates' hard-floor RMS).
    /// Below it the UI shows a dead waveform, so no "shown activity vs.
    /// empty transcript" contradiction exists — the honest-UI property SP-002
    /// protects — and true silence must accumulate nothing.
    static let activityMinimumRMS: Float = 0.004

    /// Speech occupies a sustained fraction of a chunk's ~30 ms probe
    /// windows; sparse blips (a cough, a keyboard click, a bumped desk) do
    /// not, and must not count toward a *sustained*-discard episode.
    static let activityMinimumActiveRatio: Float = 0.3

    /// Speech is peaky. Steady room tone is flat — a pure tone's crest
    /// factor is √2 ≈ 1.41 — so requiring headroom above it keeps ambient
    /// hum (HVAC, fans) from ever accumulating (the false-positive direction
    /// the spec binds hardest).
    static let activityMinimumCrestFactor: Float = 1.5

    /// Whether a *dropped* chunk counts as discarded speech-like activity —
    /// the "speech gates discarded something the meter showed as live"
    /// evidence — rather than silence/ambient room tone, which is neutral.
    /// Deliberately conservative: all three guards must hold, so doubt about
    /// a chunk's speechiness never advances an episode toward a notice.
    static func isDiscardedActivity(_ stats: AudioStats) -> Bool {
        stats.rms >= activityMinimumRMS
            && stats.activeRatio >= activityMinimumActiveRatio
            && stats.crestFactor >= activityMinimumCrestFactor
    }

    // MARK: - Per-channel episode state

    private struct ChannelHealth {
        /// Seconds of discarded speech-like activity in the current episode.
        var accumulatedDiscardedActivity: TimeInterval = 0
        /// Whether this episode already raised its notice (once per episode).
        var isNoticeActive = false
    }

    private var micHealth = ChannelHealth()
    private var systemHealth = ChannelHealth()

    // MARK: - Event handling

    @discardableResult
    mutating func handle(_ event: Event) -> Effect? {
        switch event {
        case .gateDecision(let record):
            switch record.channel {
            case .microphone:
                return Self.classify(record, into: &micHealth, show: .showMicHealthNotice)
            case .system:
                return Self.classify(record, into: &systemHealth, show: .showSystemHealthNotice)
            }

        case .micDeviceChanged:
            // New device, new evidence: discarded-activity accumulated
            // against the old device says nothing about this one, so the
            // episode resets and the new device gets a full onset bound of
            // its own (the conservative direction). An active notice clears
            // with it — it described the old device, and leaving it up would
            // be a standing false positive; if the new device also fails, a
            // fresh episode re-notices within its own bound. Device loss
            // arrives through the same reset, so S4's mic-unavailable notice
            // (a separate surface by design) never sits above a stale mic
            // health notice. The system channel is untouched: the input
            // device is mic-side hardware, and an earbuds-style Team episode
            // must survive input flapping (US-6).
            micHealth.accumulatedDiscardedActivity = 0
            guard micHealth.isNoticeActive else { return nil }
            micHealth.isNoticeActive = false
            return .clearHealthNotice(.microphone)
        }
    }

    /// Folds one gate decision into a channel's episode state. Channel state
    /// is fully independent — a mic episode can never touch the system
    /// notice, and vice versa (the two channels fail for different physical
    /// reasons: mic device vs. tap/route).
    private static func classify(
        _ record: GateDecisionRecord,
        into health: inout ChannelHealth,
        show: Effect
    ) -> Effect? {
        switch record.verdict {
        case .transcribe:
            // Recovery: the channel is producing transcript again, so the
            // sustained-discard episode is over — evidence resets and an
            // active notice clears automatically (SP-002 Reliability). A
            // later episode starts from zero and may notify again.
            health.accumulatedDiscardedActivity = 0
            guard health.isNoticeActive else { return nil }
            health.isNoticeActive = false
            return .clearHealthNotice(record.channel)
        case .drop:
            // Silence/ambient drops are neutral: they add nothing (never a
            // notice from a quiet room) — and they don't reset either, so a
            // speaker's natural pauses can't indefinitely defer the notice
            // a genuinely gated-out mic owes the user (the "always fires
            // within the onset bound" direction of SP-002 Reliability).
            guard isDiscardedActivity(record.stats) else { return nil }
            health.accumulatedDiscardedActivity += record.chunkDuration
            guard !health.isNoticeActive,
                  health.accumulatedDiscardedActivity >= onsetBound
            else { return nil }
            health.isNoticeActive = true
            return show
        }
    }
}

/// User-facing wording for the input-health notice (English only per project
/// rules). Pure, like `EchoDegradationNotice` and `InputDeviceNotice`, so the
/// mapping stays unit-testable — and deliberately a separate surface from
/// S4's mic-unavailable notice: "device gone" and "device delivering
/// untranscribable signal" are different problems with different fixes.
///
/// The mic wording surfaces the sustained-gated-out classification (SP-002
/// US-3: fix the setup during the meeting, not after); the system wording
/// surfaces the unsupported-combination classification (US-6: the earbuds
/// case — never a silently mute Team channel). Naming the specific input
/// device in the notice is deferred to the measurement phase alongside open
/// question 6 (which UI surface the notice finally lives on).
nonisolated enum InputHealthNotice {

    static let micMessage =
        "Your mic audio isn't reaching the transcript — check your input device."

    static let systemMessage =
        "Meeting audio isn't reaching the transcript — this audio device combination may be unsupported."
}

/// Broadcasts each gate-decision record to every sink, in order. Lets the
/// controller keep the permanent OSLog diagnostic (SP-002 US-12) and the
/// input-health classifier (ADR-006) both fed from the pipeline's single
/// `gateDiagnostics` seam. Stateless, so it adds nothing to the sink
/// contract's timing budget beyond its members.
nonisolated struct FanOutGateDiagnosticsSink: GateDiagnosticsSink {

    private let sinks: [any GateDiagnosticsSink]

    init(_ sinks: [any GateDiagnosticsSink]) {
        self.sinks = sinks
    }

    func record(_ record: GateDecisionRecord) {
        for sink in sinks {
            sink.record(record)
        }
    }
}

/// Session-scoped adapter that runs the pure `InputHealthClassifier` behind
/// the `GateDiagnosticsSink` contract: `record` arrives synchronously on the
/// transcription pipeline's actor executor (≤ ~1/sec/channel) while device
/// signals and session lifecycle arrive from the main actor, so state is
/// lock-guarded — the same pattern as `MicCaptureGapTracker`, and the same
/// uncontended-lock cost the sink contract's "fast, non-blocking" clause
/// allows.
///
/// Effects are delivered tagged with the generation of the session whose
/// evidence produced them; the controller drops stale deliveries by
/// generation (the `onEngineEvent` discipline), so a teardown straggler can
/// never raise a notice while idle or leak one into the next session.
nonisolated final class InputHealthTracker: GateDiagnosticsSink, @unchecked Sendable {

    private let lock = NSLock()
    private var classifier = InputHealthClassifier()
    /// Generation of the running session; `nil` between sessions, which
    /// makes the tracker inert (records classify only mid-session).
    private var sessionGeneration: Int?
    private var effectHandler: (@Sendable (Int, InputHealthClassifier.Effect) -> Void)?

    /// Receives `(sessionGeneration, effect)` for every effect the
    /// classifier emits. Set once at wiring time (lock-guarded regardless,
    /// since `record` runs off the main actor).
    var onEffect: (@Sendable (Int, InputHealthClassifier.Effect) -> Void)? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return effectHandler
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            effectHandler = newValue
        }
    }

    /// Starts a session: fresh classifier state (no evidence or notice
    /// bookkeeping ever crosses sessions) under the session's generation.
    func beginSession(generation: Int) {
        lock.lock()
        defer { lock.unlock() }
        classifier = InputHealthClassifier()
        sessionGeneration = generation
    }

    /// Ends the session: the tracker goes inert and drops its state, so
    /// straggler records from capture teardown classify into nothing.
    func endSession() {
        lock.lock()
        defer { lock.unlock() }
        sessionGeneration = nil
        classifier = InputHealthClassifier()
    }

    // MARK: - GateDiagnosticsSink

    func record(_ record: GateDecisionRecord) {
        handle(.gateDecision(record))
    }

    // MARK: - Device signals (from the S4 lifecycle machinery)

    func noteMicDeviceChanged() {
        handle(.micDeviceChanged)
    }

    private func handle(_ event: InputHealthClassifier.Event) {
        lock.lock()
        guard let generation = sessionGeneration else {
            lock.unlock()
            return
        }
        let effect = classifier.handle(event)
        let deliver = effectHandler
        lock.unlock()
        // Delivery runs outside the lock: the handler hops to the main actor
        // anyway, and a sink must never block the pipeline's executor.
        guard let effect, let deliver else { return }
        deliver(generation, effect)
    }
}
