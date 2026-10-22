//
//  PassEvent.swift
//  Transcription
//
//  What the developer replay harness observes while a pass runs.
//
//  The PoC's sink was `@Sendable (String) -> Void` and every line it emitted
//  carried transcript text, which is why no production path was ever allowed
//  to pass one. That shape cannot be made safe by discipline: the text is in
//  the string before anyone decides where the string goes. So the sink is
//  structured instead, and carries ids, times and scores only — a harness
//  that wants to print words already holds the segments they came from.
//

import EchoCore
import Foundation

public enum PassEvent: Sendable {
    /// One channel finished decoding. Numbers only.
    case channelDecoded(ChannelDecode)
    /// One segment survived shaping, identified by id and span.
    case segmentProduced(id: UUID, channel: AudioChannel, start: TimeInterval, end: TimeInterval)
    /// One mic segment was suppressed as bleed, with the evidence that did it.
    case segmentSuppressed(Suppression)

    public struct ChannelDecode: Sendable {
        public let channel: AudioChannel
        public let audioSeconds: Double
        public let tokenCount: Int
        public let segmentCount: Int
        public let decodeDuration: Duration
    }

    /// Why one row went — enough for a replay to show the margin, and nothing
    /// that says what anybody said.
    public struct Suppression: Sendable {
        public let segmentID: UUID
        public let channel: AudioChannel
        public let start: TimeInterval
        public let end: TimeInterval
        public let tier: EchoDedupPolicy.Tier
        public let containment: Double
        public let rmsRatio: Float?
        public let ownVoiceSeconds: TimeInterval
        /// The linked Others segment the candidate duplicated most.
        public let matchID: UUID
        public let matchStart: TimeInterval
        public let matchEnd: TimeInterval
    }
}
