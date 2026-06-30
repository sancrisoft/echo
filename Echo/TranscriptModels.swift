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

/// A speaker label. The microphone channel always resolves to `.me`.
/// On the system channel, SpeakerKit diarization assigns stable speaker indices.
enum Speaker: Hashable, Codable, Sendable {
    case me
    case teammate(Int)   // diarized speaker index on the system stream

    var displayName: String {
        switch self {
        case .me: return "Tú"
        case .teammate(let i): return "Participante \(i + 1)"
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

    init(
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
}
