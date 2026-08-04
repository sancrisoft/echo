//
//  TranscriptModels.swift
//  Echo
//
//  Core data models for the aligned, two-stream transcript.
//

import Foundation

/// Which audio stream a piece of transcript came from.
///
/// Per the product assumption (AGENTS.md): the microphone is always the current
/// user, while system audio is always the teammates in the meeting. We never
/// rely on diarization alone to tell the user apart from everyone else.
enum AudioChannel: String, Codable, Hashable, Sendable {
    case microphone   // the current user
    case system       // teammates (meeting output)
}

/// A speaker label. The microphone is always the user (`.me`); everything on the
/// system stream is attributed to a single generic `.teammates` for the PoC
/// (per-speaker diarization was dropped — see notes).
enum Speaker: Hashable, Codable, Sendable {
    case me
    case teammates

    var displayName: String {
        switch self {
        case .me: return "You"
        case .teammates: return "Others"
        }
    }

    /// The stable persisted spelling of each case (ADR-023). Kept separate
    /// from `displayName`, which is free to change with the UI.
    private nonisolated var persistedValue: String {
        switch self {
        case .me: return "me"
        case .teammates: return "teammates"
        }
    }

    // Persist as a plain string ("me" / "teammates") — the synthesized
    // encoding wrote structural noise like {"teammates": {}} (ADR-023).
    nonisolated func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(persistedValue)
    }

    /// The channel-derived attribution — the product's actual source of
    /// truth (mic = user, system = teammates). Used as the tolerant-decoding
    /// fallback when a persisted speaker value isn't recognized (ADR-023).
    nonisolated init(defaultFor channel: AudioChannel) {
        switch channel {
        case .microphone: self = .me
        case .system: self = .teammates
        }
    }

    /// Keys of the pre-SP-007 synthesized encoding ({"me": {}} / {"teammates": {}}).
    /// Kept only so existing meetings on disk decode forever, migration-free.
    private enum LegacyCodingKeys: String, CodingKey {
        case me
        case teammates
    }

    nonisolated init(from decoder: Decoder) throws {
        if let value = try? decoder.singleValueContainer().decode(String.self) {
            switch value {
            case "me": self = .me
            case "teammates": self = .teammates
            default:
                throw DecodingError.dataCorrupted(DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Unrecognized speaker value: \(value)"
                ))
            }
            return
        }
        let container = try decoder.container(keyedBy: LegacyCodingKeys.self)
        if container.contains(.me) {
            self = .me
        } else if container.contains(.teammates) {
            self = .teammates
        } else {
            throw DecodingError.dataCorrupted(DecodingError.Context(
                codingPath: decoder.codingPath,
                debugDescription: "Speaker object has no recognized case key"
            ))
        }
    }
}

/// One contiguous, timestamped piece of transcript on a single channel.
///
/// `start`/`end` are seconds relative to the start of the recording, so the two
/// streams can be merged into a single timeline ordered by `start`.
struct TranscriptSegment: Identifiable, Hashable, Codable, Sendable {
    let id: UUID
    var channel: AudioChannel
    var speaker: Speaker
    var text: String
    var start: TimeInterval
    var end: TimeInterval

    nonisolated init(
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

    private enum CodingKeys: String, CodingKey {
        case id, channel, speaker, text, start, end
    }

    // Custom decoding only for the speaker fallback: an unrecognized or
    // absent speaker value degrades to the channel-derived default instead
    // of failing the whole meeting load (ADR-023). Encoding stays synthesized.
    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        let channel = try container.decode(AudioChannel.self, forKey: .channel)
        self.channel = channel
        speaker = (try? container.decode(Speaker.self, forKey: .speaker))
            ?? Speaker(defaultFor: channel)
        text = try container.decode(String.self, forKey: .text)
        start = try container.decode(TimeInterval.self, forKey: .start)
        end = try container.decode(TimeInterval.self, forKey: .end)
    }
}
