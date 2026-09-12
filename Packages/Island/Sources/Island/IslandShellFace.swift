//
//  IslandShellFace.swift
//  Island
//
//  Which face the shell is wearing, and how wide that makes it.
//
//  This is the shell's vocabulary, not the faces' content: what each one SAYS
//  is its own work. It exists here because the shell has to know its own
//  silhouette before a word has been written into it, and because the face is
//  nobody's single opinion — detection owns the half that asks a question, the
//  session owns the half that reports work, and the island is the only place
//  those two meet.
//

import CallDetection
import DesignSystem
import Recording

/// The faces the design draws, as silhouettes.
public nonisolated enum IslandShellFace: Equatable, Sendable, CaseIterable {

    /// Nothing is happening. The app's permanent presence: empty ears while
    /// collapsed, and the way in to a recording once it opens.
    case idle

    /// A call was noticed and a recording is offered.
    case callDetected

    /// A session is live.
    case recording

    /// The call ended under a live recording and the stop is counting down.
    case callEnded

    /// The meeting is on disk.
    case saved

    /// The summary is being written.
    case summarizing

    /// This face's width, collapsed and expanded.
    public var width: IslandWidth {
        switch self {
        case .idle: .idle
        case .callDetected: .callDetected
        case .recording: .recording
        case .callEnded: .callEnded
        case .saved: .saved
        case .summarizing: .summarizing
        }
    }
}

extension IslandShellFace {

    /// The face for what detection is showing and what the session is doing.
    ///
    /// Detection wins wherever it has something to show. Its faces are the
    /// ones that ask a question — record this call, the call ended, the
    /// meeting is saved — and a question outranks a report: the session's own
    /// faces say what is happening, which is still true a moment later.
    ///
    /// Two phases the design draws no face for, each resolved to the nearest
    /// one it does draw rather than to a face invented here:
    ///
    ///   - `.stopping` keeps the recording silhouette. It is the shape already
    ///     on screen, the meeting is not saved yet, and the alternative —
    ///     jumping to `saved` while the save is still running — is the exact
    ///     lie the asynchronous stop exists to prevent. What the face stops
    ///     showing while it is there (a clock that is no longer running) is
    ///     the content's business.
    ///   - `.finalizing` — the transcription pass — takes the summarizing
    ///     silhouette. There is one face for post-stop work and this is it;
    ///     whether the words on it can cover both passes honestly is a
    ///     question for whoever writes them.
    public static func resolve(detection: IslandFace?, phase: RecordingPhase) -> IslandShellFace {
        switch detection {
        case .startPrompt, .compactPill: return .callDetected
        case .endGrace: return .callEnded
        case .saved: return .saved
        case nil: break
        }

        switch phase {
        case .recording, .stopping: return .recording
        case .finalizing, .summarizing: return .summarizing
        case .idle: return .idle
        }
    }

    /// Whether this face opens on its own, with no pointer on it.
    ///
    /// Three of the six do, and they are exactly the three that need an
    /// answer or announce a result the user did not ask to see: an offer to
    /// record, a countdown to a stop, and a saved meeting. The other three
    /// report something the user already knows is happening, so they stay in
    /// the ears until the pointer arrives.
    ///
    /// `detection` settles the one case the face alone cannot. `.callDetected`
    /// covers both the offer and the pill the offer retracts into, and the
    /// pill is retracted by definition: an ignored offer shrinks to the ears
    /// rather than nagging, and the machine that decided so is the only thing
    /// that may decide it back.
    public func expandsOnItsOwn(detection: IslandFace?) -> Bool {
        if detection == .compactPill { return false }
        switch self {
        case .callDetected, .callEnded, .saved: return true
        case .idle, .recording, .summarizing: return false
        }
    }

    /// Whether the shell is open.
    ///
    /// The pointer opens any face — that is what hover is for, and it is how
    /// the idle face is reached at all. A face that opened on its own stays
    /// open without it: the pointer can bring the shell out, never put it
    /// back.
    public func isOpen(detection: IslandFace?, hovered: Bool) -> Bool {
        hovered || expandsOnItsOwn(detection: detection)
    }
}
