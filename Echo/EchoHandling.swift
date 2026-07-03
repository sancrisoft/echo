//
//  EchoHandling.swift
//  Echo
//
//  Pure echo-handling logic for SP-001: the output-route classification and
//  the echo-handling mode machine. No Core Audio here — everything in this
//  file is deterministic and unit-testable.
//

/// Classification of the current audio output route (SP-001 glossary:
/// "output route"). Distinct from the raw Core Audio device: this is the
/// only property of the route the echo-handling mode machine cares about.
nonisolated enum OutputRouteClass: Equatable, Sendable {
    /// The Mac's built-in loudspeakers — the only route with speaker bleed.
    case builtInSpeakers
    /// Wired headphones on the built-in jack — no echo path, mic stays raw.
    case headphones
    /// Anything that can't be confidently classified (Bluetooth, multi-output,
    /// virtual, unknown transports). Conservative per SP-001 Reliability.
    case unsupported
}

/// The state a recording session is in with respect to speaker bleed
/// (SP-001 state diagram). Transcript dedup is active in every mode.
nonisolated enum EchoHandlingMode: String, Equatable, Sendable {
    /// Built-in loudspeakers: the AEC engine cancels bleed from the mic.
    case cancelling
    /// Headphones: no echo path, the mic signal is left completely untouched.
    case bypassed
    /// Unsupported/ambiguous route: raw mic, transcript dedup is the defense.
    case dedupOnly
    /// Engine failure on a supported route: raw mic + dedup, subtle notice.
    case degraded
}

/// Deterministic mode machine driving echo handling from route and
/// engine-health events. It can only ever change modes and raise/clear the
/// degradation notice — no event sequence stops or fails a recording
/// (SP-001 Reliability: graceful degradation, never a failure).
nonisolated struct EchoModeMachine {

    enum Event: Equatable, Sendable {
        case routeChanged(OutputRouteClass)
        case engineFailed
        case engineRecovered
    }

    /// The only side effects the machine can request. Deliberately no
    /// stop/fail outcome: an echo-processing problem must never end a
    /// recording (SP-001 US-8).
    enum Effect: Equatable, Sendable {
        case showDegradationNotice
        case clearDegradationNotice
    }

    private(set) var mode: EchoHandlingMode
    private var isNoticeActive = false

    init(initialRoute: OutputRouteClass) {
        mode = Self.mode(for: initialRoute)
    }

    @discardableResult
    mutating func handle(_ event: Event) -> Effect? {
        switch event {
        case .routeChanged(let route):
            // A loudspeaker route while degraded is not a recovery: the engine
            // is still down, and only `engineRecovered` re-engages cancellation.
            if mode == .degraded && route == .builtInSpeakers { return nil }
            mode = Self.mode(for: route)
            // Leaving the loudspeaker route ends the degradation episode.
            return endEpisode()
        case .engineFailed:
            guard mode == .cancelling else { return nil }
            mode = .degraded
            // At most one notice per degradation episode (SP-001 Reliability).
            guard !isNoticeActive else { return nil }
            isNoticeActive = true
            return .showDegradationNotice
        case .engineRecovered:
            guard mode == .degraded else { return nil }
            mode = .cancelling
            return endEpisode()
        }
    }

    private mutating func endEpisode() -> Effect? {
        guard isNoticeActive else { return nil }
        isNoticeActive = false
        return .clearDegradationNotice
    }

    private static func mode(for route: OutputRouteClass) -> EchoHandlingMode {
        switch route {
        case .builtInSpeakers: return .cancelling
        case .headphones: return .bypassed
        case .unsupported: return .dedupOnly
        }
    }
}

/// Maps mode-machine effects to the subtle user-facing degradation notice
/// (SP-001 US-7). Pure so the glue is unit-testable without the controller.
nonisolated enum EchoDegradationNotice {

    static let message = "Echo cancellation reduced — headphones recommended"

    static func notice(after effect: EchoModeMachine.Effect) -> String? {
        switch effect {
        case .showDegradationNotice: return message
        case .clearDegradationNotice: return nil
        }
    }
}
