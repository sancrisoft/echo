//
//  InputHealthClassifier.swift
//  Audio
//
//  Whether an input channel is actually usable: usable, sustained-gated-out,
//  or an unsupported device combination. The classifier consumes the
//  per-chunk gate-decision record stream for both channels plus input-device
//  signals, tracks sustained-discard episodes, and drives the input-health
//  notice — closing the silent-dropout signature, where the meter shows live
//  signal while the speech gates discard every chunk of it.
//
//  This is an OBSERVATIONAL classifier, separate from the echo-handling mode
//  machine. It raises and clears notices and never switches the audio path,
//  and that is structural rather than a rule: `Effect` can only express
//  notice effects, so a path switch, a gain change or a capture stop is
//  unrepresentable — the same way `EchoModeMachine.Effect` makes a
//  stop-recording outcome unrepresentable. There is deliberately no feedback
//  from classification into the signal being classified.
//
//  Where a notice is SHOWN is not decided here: the classifier emits values,
//  and the surface that renders them owns the presentation.
//

import EchoCore
import Foundation
import Synchronization

/// Deterministic, observational input-health classifier.
///
/// Pure logic in the `EchoModeMachine` mold: events in, at most one notice
/// effect out, fully table-testable. Time never comes from a clock — the
/// gate-decision records' own chunk durations are the time base, so the
/// classifier is replayable from logged decisions alone.
///
/// Episode semantics, one per channel and independently:
/// - Dropped chunks whose stats clear the discarded-activity heuristic below
///   accumulate their duration; crossing the onset bound raises the channel's
///   notice once per episode, so a flapping input cannot spam notices.
/// - A transcribed chunk on the channel is recovery: it ends the episode and
///   clears an active notice, and a later episode may notify again.
public struct InputHealthClassifier: Sendable {

    /// The observational inputs. Gate decisions arrive for both channels at
    /// chunk cadence; device signals arrive from the input-device machinery.
    public enum Event: Sendable {
        /// One finalized chunk's speech-gate decision.
        case gateDecision(GateDecisionRecord)
        /// The mic's capture device changed — a switch to a new device, or
        /// the device being lost or restored — `InputDeviceLifecycleMachine`'s
        /// restart and stop actions, which fire only on real identity
        /// changes.
        case micDeviceChanged
    }

    /// The only side effects the classifier can request — notices, nothing
    /// else. "Never switches processing" is structural here: there is no
    /// effect case that could touch capture, the AEC, the gates or the mode
    /// machine, so no event sequence can change the audio path.
    public enum Effect: Equatable, Sendable {
        /// Mic-channel sustained-gated-out episode: the user's own speech is
        /// being wholly discarded — surface it during the meeting, while the
        /// setup can still be fixed.
        case showMicHealthNotice
        /// System-channel sustained-gated-out episode: the Others channel is
        /// silently mute — the earbuds-style unsupported combination,
        /// including when it begins mid-recording.
        case showSystemHealthNotice
        /// The channel recovered, or its evidence no longer applies: the
        /// notice clears automatically.
        case clearHealthNotice(AudioChannel)
    }

    // MARK: - Onset bound and discrimination thresholds

    // TUNABLE, and not yet measured: every constant in this block is a
    // provisional, deliberately conservative starting point. The exact
    // numbers that separate "discarded speech-like activity" from "discarded
    // ambient room tone" are still open — they get fixed against the recorded
    // device fixtures (the USB receiver, earbuds and quiet-room takes). What
    // is settled is the structure; every knob stays in this block so a
    // measurement has one place to change.

    /// Accumulated discarded-activity duration at which the notice fires. 30
    /// seconds of sustained discard is the provisional bound.
    public static let onsetBound: TimeInterval = 30

    /// The level meter's visible floor, which is the gates' hard-floor RMS.
    /// Below it the meter reads dead, so there is no "shown activity against
    /// an empty transcript" contradiction to explain, and true silence must
    /// accumulate nothing.
    public static let activityMinimumRMS: Float = 0.004

    /// Speech occupies a sustained fraction of a chunk's ~30 ms probe
    /// windows; sparse blips (a cough, a keyboard click, a bumped desk) do
    /// not, and must not count toward a *sustained*-discard episode.
    public static let activityMinimumActiveRatio: Float = 0.3

    /// Speech is peaky. Steady room tone is flat — a pure tone's crest
    /// factor is √2 ≈ 1.41 — so requiring headroom above it keeps ambient
    /// hum (HVAC, fans) from ever accumulating. A false notice is the worse
    /// failure here, so this is the direction that is bound hardest.
    public static let activityMinimumCrestFactor: Float = 1.5

    /// Whether a *dropped* chunk counts as discarded speech-like activity —
    /// the "speech gates discarded something the meter showed as live"
    /// evidence — rather than silence/ambient room tone, which is neutral.
    /// Deliberately conservative: all three guards must hold, so doubt about
    /// a chunk's speechiness never advances an episode toward a notice.
    public static func isDiscardedActivity(_ stats: AudioStats) -> Bool {
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

    public init() {}

    @discardableResult
    public mutating func handle(_ event: Event) -> Effect? {
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
            // arrives through the same reset, so the mic-unavailable notice —
            // a separate surface by design — never sits above a stale mic
            // health notice. The system channel is untouched: the input
            // device is mic-side hardware, and an earbuds-style Others
            // episode has to survive input flapping.
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
            // active notice clears automatically. A later episode starts from
            // zero and may notify again.
            health.accumulatedDiscardedActivity = 0
            guard health.isNoticeActive else { return nil }
            health.isNoticeActive = false
            return .clearHealthNotice(record.channel)
        case .drop:
            // Silence/ambient drops are neutral: they add nothing (never a
            // notice from a quiet room) — and they don't reset either, so a
            // speaker's natural pauses can't indefinitely defer the notice
            // a genuinely gated-out mic owes the user: the notice always
            // fires within the onset bound.
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

/// Wording for the input-health notice. A value, like `EchoDegradationNotice`
/// and `InputDeviceNotice` — and deliberately a separate surface from the
/// mic-unavailable notice: "device gone" and "device delivering
/// untranscribable signal" are different problems with different fixes.
///
/// The mic wording surfaces the sustained-gated-out classification, so the
/// setup can be fixed during the meeting rather than after; the system
/// wording surfaces the unsupported-combination classification, the earbuds
/// case, so the Others channel is never silently mute. Naming the specific
/// input device in the notice waits on a measurement.
public enum InputHealthNotice {

    public static let micMessage =
        "Your mic audio isn't reaching the transcript — check your input device."

    public static let systemMessage =
        "Meeting audio isn't reaching the transcript — this audio device combination may be unsupported."
}

/// Broadcasts each gate-decision record to every sink, in order. Lets a
/// caller keep the permanent OSLog diagnostic and the input-health classifier
/// both fed from the monitor's single `gateDiagnostics` seam. Stateless, so
/// it adds nothing to the sink contract's timing budget beyond its members.
public struct FanOutGateDiagnosticsSink: GateDiagnosticsSink {

    private let sinks: [any GateDiagnosticsSink]

    public init(_ sinks: [any GateDiagnosticsSink]) {
        self.sinks = sinks
    }

    public func record(_ record: GateDecisionRecord) {
        for sink in sinks {
            sink.record(record)
        }
    }
}

/// Session-scoped adapter that runs the pure `InputHealthClassifier` behind
/// the `GateDiagnosticsSink` contract.
///
/// `record` arrives synchronously on the monitor's actor executor, at most
/// about once per second per channel, while device signals and session
/// lifecycle arrive from wherever Recording drives them. A lock rather than
/// an actor for the same reason `CaptureGapTracker` uses one: the sink
/// contract requires `record` to be fast and non-blocking, and an actor would
/// put a suspension point in a callback that must not have one. The
/// uncontended acquisition is what that contract allows for.
///
/// Effects are delivered tagged with the generation of the session whose
/// evidence produced them, so Recording can drop stale deliveries by
/// generation: a teardown straggler can never raise a notice while idle, nor
/// leak one into the next session.
public final class InputHealthTracker: GateDiagnosticsSink {

    private struct State {
        var classifier = InputHealthClassifier()
        /// Generation of the running session; `nil` between sessions, which
        /// makes the tracker inert — records classify only mid-session.
        var sessionGeneration: Int?
    }

    private let state = Mutex(State())

    /// Receives `(sessionGeneration, effect)` for every effect the classifier
    /// emits. Immutable: handed over at construction, so the sink's hot path
    /// reads nothing that can change under it.
    private let onEffect: (@Sendable (Int, InputHealthClassifier.Effect) -> Void)?

    public init(onEffect: (@Sendable (Int, InputHealthClassifier.Effect) -> Void)? = nil) {
        self.onEffect = onEffect
    }

    /// Starts a session: fresh classifier state — no evidence and no notice
    /// bookkeeping ever crosses sessions — under the session's generation.
    public func beginSession(generation: Int) {
        state.withLock { state in
            state.classifier = InputHealthClassifier()
            state.sessionGeneration = generation
        }
    }

    /// Ends the session: the tracker goes inert and drops its state, so
    /// straggler records from capture teardown classify into nothing.
    public func endSession() {
        state.withLock { state in
            state.sessionGeneration = nil
            state.classifier = InputHealthClassifier()
        }
    }

    // MARK: - GateDiagnosticsSink

    public func record(_ record: GateDecisionRecord) {
        handle(.gateDecision(record))
    }

    // MARK: - Device signals

    public func noteMicDeviceChanged() {
        handle(.micDeviceChanged)
    }

    private func handle(_ event: InputHealthClassifier.Event) {
        let delivery = state.withLock { state -> (Int, InputHealthClassifier.Effect)? in
            guard let generation = state.sessionGeneration else { return nil }
            guard let effect = state.classifier.handle(event) else { return nil }
            return (generation, effect)
        }
        // Delivery runs outside the lock: the handler hops to whatever
        // isolation it belongs to, and a sink must never block the monitor's
        // executor.
        guard let (generation, effect) = delivery else { return }
        onEffect?(generation, effect)
    }
}
