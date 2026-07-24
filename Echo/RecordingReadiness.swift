//
//  RecordingReadiness.swift
//  Echo
//
//  The record-gesture readiness gate, as a pure function of the speech model's
//  lifecycle state (ADR-009; SP-003 Testing Decisions, layer 2). "Ready to
//  record" means the speech model is loaded and transcribing-capable — NOT
//  merely present on disk — so every not-ready sub-state maps to a
//  non-recording outcome with a sub-state-accurate message. Extracting the
//  decision here (the way `EchoModeMachine.handle` was lifted out of the
//  controller) is what lets the "record button never lies" invariant be
//  table-tested without spinning up capture, permissions, or the network.
//
//  Pure value type on purpose: no controller/actor/SwiftUI access, so the whole
//  gate reduces to `SpeechModelState -> RecordingGateDecision`.
//

/// The gate's verdict for a record press: proceed to capture, or block with a
/// message the surfaces render (the Dashboard callout, the menu-bar hand-off).
enum RecordingGateDecision: Equatable {
    case record
    case blocked(message: String)

    /// True for every not-ready outcome — the record gesture must not start
    /// capture.
    var isBlocked: Bool {
        if case .blocked = self { return true }
        return false
    }

    /// The block reason, or nil when recording is permitted.
    var message: String? {
        if case .blocked(let message) = self { return message }
        return nil
    }

    /// Maps the speech model's current lifecycle to the record gate.
    /// Only `.ready` — loaded and transcribing-capable — permits recording;
    /// every other sub-state blocks so `isRecording` can never flip over a
    /// model that isn't actually able to transcribe (the ADR-009 hole).
    ///
    /// Exhaustive on purpose (no `default`): a future `SpeechModelState` case
    /// must be given a deliberate outcome here rather than silently slipping
    /// through as "record".
    static func decide(_ state: SpeechModelState) -> RecordingGateDecision {
        switch state {
        case .ready:
            return .record
        case .downloading(let fraction):
            // Percent through the same clamped projection the progress bars use
            // (ADR-007), so the message can never read a raw, out-of-range
            // number even if the raw fraction momentarily overshoots.
            let percent = ModelDownloadProgress(fraction: fraction).percent
            return .blocked(message: "Can't record yet — the speech model is still downloading (\(percent)%).")
        case .loading:
            // On disk but not yet transcribing-capable — the ADR-009 case the
            // old gate let slip straight into a (briefly false) recording state.
            return .blocked(message: "Preparing the speech model…")
        case .failed:
            // Download- and load-failure collapse to one retry outcome
            // (ADR-009): pressing record again re-runs `prepare()`, which
            // retries whichever step failed.
            return .blocked(message: "The speech model isn't ready — retry to finish setting it up.")
        }
    }
}
