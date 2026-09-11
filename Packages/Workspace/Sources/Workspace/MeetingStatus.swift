//
//  MeetingStatus.swift
//  Workspace
//
//  The one face a saved meeting shows in the list and the document header,
//  derived from its meta and nothing else — never from ad-hoc checks in a
//  view. When the Recording package lands, its session and finalization state
//  become further inputs here (recording, waiting, transcribing) and every
//  surface picks the change up at once.
//

import DesignSystem
import Meetings

public enum MeetingStatus: Equatable, Sendable {
    /// Transcript and notes are in.
    case summarized
    /// The transcript is final; no notes yet.
    case transcribed
    /// The pass exhausted its retries: no transcript. Retry exists while the
    /// kept audio does.
    case failed
    /// A legacy draft: real text from a live transcript that stood in for a
    /// failed pass.
    case draft
    /// No transcript yet and no terminal outcome: a pass is owed.
    case pending

    /// The resolution table. Provenance is the disambiguating bit that
    /// survives relaunch: `terminalFailure` is a failed meeting, `liveFloor` a
    /// legacy draft, `finalPass` a final transcript; no provenance with a
    /// transcript is a plain success-path meeting, no provenance and no
    /// transcript is pending.
    public static func resolve(_ meta: MeetingMeta) -> MeetingStatus {
        switch meta.transcriptProvenance?.source {
        case .terminalFailure:
            return .failed
        case .liveFloor:
            return .draft
        case .finalPass:
            return meta.hasSummary ? .summarized : .transcribed
        case nil:
            if meta.segmentCount == 0 { return .pending }
            return meta.hasSummary ? .summarized : .transcribed
        }
    }

    public var label: String {
        switch self {
        case .summarized: return "Summarized"
        case .transcribed: return "Transcribed"
        case .failed: return "Transcription failed"
        case .draft: return "Draft"
        case .pending: return "Pending"
        }
    }

    /// What a sidebar row carries at its trailing edge, or nothing when the
    /// meeting is complete. The design draws one word there — `draft`, for a
    /// meeting whose summary has not landed — and no mark at all for a
    /// finished one. It draws nothing for a meeting whose transcription
    /// failed, and calling that a draft would be a lie, so failure takes the
    /// same shape with its own word and the one colour the palette keeps for
    /// it.
    public enum RowMark: String, Equatable, Sendable {
        case draft
        case failed
    }

    public var rowMark: RowMark? {
        switch self {
        case .summarized: return nil
        case .transcribed, .pending, .draft: return .draft
        case .failed: return .failed
        }
    }

    public var tone: StatusBadge.Tone {
        switch self {
        case .summarized: return .success
        case .transcribed: return .neutral
        case .failed: return .danger
        case .draft: return .warning
        case .pending: return .accent
        }
    }

    /// Whether the transcript tab has words to show.
    public var isTranscriptReadable: Bool {
        switch self {
        case .summarized, .transcribed, .draft: return true
        case .failed, .pending: return false
        }
    }
}
