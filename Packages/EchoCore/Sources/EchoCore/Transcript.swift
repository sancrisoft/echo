//
//  Transcript.swift
//  EchoCore
//
//  The product's central vocabulary: a transcript is a list of timestamped
//  segments, each from exactly one audio channel. These types are persisted as
//  `transcript.json` in every meeting folder, so their encoding is a contract:
//  additive changes only, tolerant decoding forever (ADR-005).
//

import Foundation

/// Which audio stream a piece of transcript came from.
///
/// The product axiom: the microphone is always the current user, and system
/// audio is always the other participants. Speaker attribution is the channel,
/// never diarization.
public enum AudioChannel: String, Codable, Hashable, Sendable, CaseIterable {
    /// The current user.
    case microphone
    /// The other participants (the meeting's playback).
    case system
}

/// Who said a segment. Derived from the channel: `.me` for the microphone,
/// `.teammates` for system audio.
public enum Speaker: Hashable, Codable, Sendable {
    case me
    case teammates

    /// The label the UI shows. Free to change; the persisted spelling is not.
    public var displayName: String {
        switch self {
        case .me: return "You"
        case .teammates: return "Others"
        }
    }

    /// The channel-derived attribution — the product's actual source of truth.
    /// Also the tolerant-decoding fallback when a persisted value is not
    /// recognized.
    public init(defaultFor channel: AudioChannel) {
        switch channel {
        case .microphone: self = .me
        case .system: self = .teammates
        }
    }

    // The stable persisted spelling ("me" / "teammates"). The synthesized
    // encoding of a case-only enum writes structural noise like
    // {"teammates": {}}; old meetings on disk carry that shape and must decode
    // forever, migration-free.
    private var persistedValue: String {
        switch self {
        case .me: return "me"
        case .teammates: return "teammates"
        }
    }

    private enum LegacyCodingKeys: String, CodingKey {
        case me
        case teammates
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(persistedValue)
    }

    public init(from decoder: any Decoder) throws {
        if let value = try? decoder.singleValueContainer().decode(String.self) {
            switch value {
            case "me": self = .me
            case "teammates": self = .teammates
            default:
                throw DecodingError.dataCorrupted(
                    DecodingError.Context(
                        codingPath: decoder.codingPath,
                        debugDescription: "Unrecognized speaker value: \(value)"
                    )
                )
            }
            return
        }
        let container = try decoder.container(keyedBy: LegacyCodingKeys.self)
        if container.contains(.me) {
            self = .me
        } else if container.contains(.teammates) {
            self = .teammates
        } else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Speaker object has no recognized case key"
                )
            )
        }
    }
}

/// One contiguous, timestamped piece of transcript on a single channel.
///
/// `start` and `end` are seconds relative to the start of the recording, so
/// the two channels merge into one timeline by sorting on `start`.
public struct TranscriptSegment: Identifiable, Hashable, Codable, Sendable {
    public let id: UUID
    public var channel: AudioChannel
    public var speaker: Speaker
    public var text: String
    public var start: TimeInterval
    public var end: TimeInterval

    public init(
        id: UUID = UUID(),
        channel: AudioChannel,
        speaker: Speaker,
        text: String,
        start: TimeInterval,
        end: TimeInterval
    ) {
        self.id = id
        self.channel = channel
        self.speaker = speaker
        self.text = text
        self.start = start
        self.end = end
    }

    /// A segment attributed to its channel's default speaker.
    public init(channel: AudioChannel, text: String, start: TimeInterval, end: TimeInterval) {
        self.init(channel: channel, speaker: Speaker(defaultFor: channel), text: text, start: start, end: end)
    }

    private enum CodingKeys: String, CodingKey {
        case id, channel, speaker, text, start, end
    }

    // Custom decoding only for the speaker fallback: an unrecognized or absent
    // speaker degrades to the channel default instead of failing the whole
    // meeting load. Encoding stays synthesized.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        let channel = try container.decode(AudioChannel.self, forKey: .channel)
        self.channel = channel
        speaker = (try? container.decode(Speaker.self, forKey: .speaker)) ?? Speaker(defaultFor: channel)
        text = try container.decode(String.self, forKey: .text)
        start = try container.decode(TimeInterval.self, forKey: .start)
        end = try container.decode(TimeInterval.self, forKey: .end)
    }

    /// Canonical transcript word count — one source of truth for every row,
    /// stat and denormalized field. Splits on whitespace, matching how a reader
    /// counts words.
    public static func wordCount(of segments: [TranscriptSegment]) -> Int {
        segments.reduce(0) { $0 + $1.text.split(whereSeparator: \.isWhitespace).count }
    }
}
