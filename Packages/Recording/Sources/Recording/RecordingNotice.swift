//
//  RecordingNotice.swift
//  Recording
//
//  The session's user-facing notices: values with a kind and the copy the
//  surface shows. Tier 2 of the error policy (architecture §7) — an expected
//  failure becomes state on the owning observable, with copy and, where one
//  exists, an action.
//
//  Kind is what carries the episode discipline. Every notice in the product
//  is "at most one per episode" — one degraded AEC episode, one lost-mic
//  episode, one sustained-gated-out episode per channel — and the machines in
//  `Audio` already enforce that by emitting a show effect once and a clear
//  effect once. Keying by kind means the session applies those effects
//  literally: a show replaces, a clear removes, and no counting is needed
//  here.
//
//  The declaration order of `Kind` is the render order, so a health notice
//  can never displace an active device-lost notice — the PoC guaranteed that
//  by giving each notice its own row, and this keeps the guarantee in the
//  value instead of in a view.
//

public struct RecordingNotice: Identifiable, Equatable, Sendable {

    public enum Kind: Int, CaseIterable, Comparable, Sendable {
        /// Capture could not start at all; the session never began.
        case captureFailed
        /// The meeting was saved but its audio could not be kept, so it will
        /// never have words.
        case retentionLost
        /// No usable input device: the session runs with meeting audio only.
        case microphoneUnavailable
        /// Echo cancellation is degraded on a loudspeaker route.
        case echoCancellation
        /// The mic is delivering signal the speech gates discard wholesale.
        case microphoneHealth
        /// The system channel is delivering signal the speech gates discard.
        case meetingAudioHealth

        public static func < (lhs: Kind, rhs: Kind) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    public var id: Kind { kind }
    public let kind: Kind
    public let message: String

    public init(kind: Kind, message: String) {
        self.kind = kind
        self.message = message
    }
}
