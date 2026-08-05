//
//  MeetingDisplayState.swift
//  Echo
//
//  SP-007 S6: pending-display resolution as ONE pure function. Every meeting
//  surface (detail tabs, list pill) derives its face from this table — never
//  from ad-hoc checks — so the "every pending meeting always resolves" NFR is
//  a testable property: exactly one of recording / waiting / transcribing /
//  draft / final, with the transcript readable only in the last two.
//
//  The function IS the spec's post-stop state diagram (SP-007 Further Notes):
//  Recording → Pending (waiting ⇄ transcribing) → Final, or → Draft (audio
//  kept, manual Retry — ADR-024), with Keep-draft / retention-never-armed as
//  the Retry-less draft. Provenance is the disambiguating bit that survives
//  relaunch (ADR-022/ADR-024): `liveFloor` is a terminal draft, `finalPass`
//  is final, absence with retained audio is a pending meeting awaiting its
//  launch resume.
//

import Foundation

/// Plain inputs for one meeting, snapshotted by the view layer: the
/// coordinator's sync observables, the meta's persisted provenance, and the
/// (async-probed) retained-audio bit.
nonisolated struct MeetingDisplaySnapshot: Equatable, Sendable {
    /// This meeting IS the live recording (only ever true for the live
    /// target — a saved meeting is never the one being recorded).
    var isRecordingThisMeeting: Bool
    /// ANY recording is active in the app. A pass that is nominally running
    /// while a recording is active is yielding (ADR-014) and must read as
    /// waiting — never a progress bar pretending to work.
    var isRecordingActive: Bool
    /// The coordinator's running pass is this meeting's.
    var isPassRunning: Bool
    /// This meeting's pass is queued (deferred behind other work).
    var isQueued: Bool
    /// The running pass's real fraction (the single ADR-007 source). Only
    /// meaningful while `isPassRunning`; never invented anywhere else.
    var progressFraction: Double?
    /// Persisted transcript provenance (`meta.json`, ADR-022). `nil` for
    /// pre-SP-007 meetings and for pending meetings whose pass hasn't
    /// concluded.
    var transcriptSource: TranscriptProvenance.Source?
    /// The meeting's kept audio exists on disk — the exact lifetime of the
    /// draft state's Retry affordance (ADR-024).
    var hasRetainedAudio: Bool

    nonisolated init(
        isRecordingThisMeeting: Bool = false,
        isRecordingActive: Bool = false,
        isPassRunning: Bool = false,
        isQueued: Bool = false,
        progressFraction: Double? = nil,
        transcriptSource: TranscriptProvenance.Source? = nil,
        hasRetainedAudio: Bool = false
    ) {
        self.isRecordingThisMeeting = isRecordingThisMeeting
        self.isRecordingActive = isRecordingActive
        self.isPassRunning = isPassRunning
        self.isQueued = isQueued
        self.progressFraction = progressFraction
        self.transcriptSource = transcriptSource
        self.hasRetainedAudio = hasRetainedAudio
    }
}

/// The one face a meeting shows. The transcript is readable only in `draft`
/// and `final` (SP-007 final-only UX — SP-005's read-during-the-pass story is
/// deliberately retired).
nonisolated enum MeetingDisplayState: Equatable, Sendable {
    case recording
    /// Queued, deferred behind an active recording, or awaiting launch
    /// resume. Honest copy, never a fake percentage.
    case waiting
    /// The pass is decoding right now, with its real fraction.
    case transcribing(fraction: Double)
    /// Terminal draft: the live floor stands, labeled. Retry exists exactly
    /// while the meeting's kept audio does (ADR-024).
    case draft(retryAvailable: Bool)
    case final

    /// The only two states whose transcript text renders.
    var isTranscriptReadable: Bool {
        switch self {
        case .draft, .final: return true
        case .recording, .waiting, .transcribing: return false
        }
    }

    /// The resolution table. Order encodes precedence:
    ///   1. Recording wins over everything — no transcript text, no pass state.
    ///   2. A running pass is transcribing — unless a recording is active,
    ///      when it is yielding and must read as waiting.
    ///   3. Queued (including a manual Retry waiting its turn — the queue
    ///      outranks the liveFloor provenance still on disk mid-cycle).
    ///   4. Provenance: `liveFloor` is the terminal draft (Retry iff the kept
    ///      audio exists); `finalPass` is final.
    ///   5. No provenance: retained audio means pending, awaiting its launch
    ///      resume (still waiting, never a bare floor transcript); no audio
    ///      means final — pre-SP-007 meetings and plain success-path
    ///      meetings read as final ("unknown renders as unknown" applies to
    ///      model NAMES, never to gating the transcript).
    nonisolated static func resolve(_ snapshot: MeetingDisplaySnapshot) -> MeetingDisplayState {
        if snapshot.isRecordingThisMeeting { return .recording }
        if snapshot.isPassRunning {
            return snapshot.isRecordingActive
                ? .waiting
                : .transcribing(fraction: snapshot.progressFraction ?? 0)
        }
        if snapshot.isQueued { return .waiting }
        switch snapshot.transcriptSource {
        case .liveFloor:
            return .draft(retryAvailable: snapshot.hasRetainedAudio)
        case .finalPass:
            return .final
        case nil:
            return snapshot.hasRetainedAudio ? .waiting : .final
        }
    }
}
