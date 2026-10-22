//
//  RecordingPhase.swift
//  Recording
//
//  What is happening to a meeting right now, as one value. It replaces the
//  PoC's `RecordingState`, whose `isRecording` / `startedAt` / `captureScope`
//  / `summaryState.generating` all described the same lifecycle from
//  different angles and could disagree — three surfaces reading three of them
//  is how the popover, the window and the island contradicted each other
//  (ADR-003).
//
//  Every field here is a payload of the phase it belongs to, so a phase with
//  no meeting cannot carry a meeting id and a phase that is not recording
//  cannot carry a start time.
//

import Audio
import Foundation

public enum RecordingPhase: Equatable, Sendable {

    /// Nothing is being captured and no post-stop work is in flight.
    case idle

    /// Capture is live. `scope` is the session's EFFECTIVE coverage, not what
    /// was asked for: a scoped session whose tap failed collapses to
    /// `.everything` and says so here, because a session that records more
    /// than intended must do it visibly (discovery §7).
    case recording(startedAt: Date, scope: CaptureScope)

    /// Capture is being torn down and the meeting persisted. Brief, and
    /// deliberately its own phase: the session is no longer capturing, so a
    /// meter must rest, but it is not idle either and a second Stop must not
    /// start a second teardown.
    case stopping

    /// A transcription pass is running for `meetingID`. `progress` is the
    /// pass's own clamped, monotonic fraction — carried, never re-derived and
    /// never clamped a second time (ADR-007).
    case finalizing(meetingID: UUID, progress: Double)

    /// The transcript is final and a summary is being generated for
    /// `meetingID`. Visible from the first day on purpose: in the PoC this
    /// state had no representation, so a user who pressed Stop watched the
    /// app appear to do nothing for a couple of minutes.
    case summarizing(meetingID: UUID)

    /// Whether capture is live. The one question the audio path asks.
    public var isRecording: Bool {
        if case .recording = self { return true }
        return false
    }

    /// The meeting this phase is about, when it is about one.
    public var meetingID: UUID? {
        switch self {
        case .finalizing(let id, _), .summarizing(let id): return id
        case .idle, .recording, .stopping: return nil
        }
    }

    /// The live session's effective coverage, or nil when nothing is
    /// recording.
    public var captureScope: CaptureScope? {
        if case .recording(_, let scope) = self { return scope }
        return nil
    }

    /// When the live session began, or nil when nothing is recording. The
    /// elapsed time a surface shows is derived from this, never stored.
    public var startedAt: Date? {
        if case .recording(let startedAt, _) = self { return startedAt }
        return nil
    }
}
