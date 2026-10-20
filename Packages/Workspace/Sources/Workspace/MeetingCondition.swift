//
//  MeetingCondition.swift
//  Workspace
//
//  When a meeting has nothing to read, why — the meeting-wide faces of the
//  empty-states artboard — and otherwise its document. A silent meeting, a
//  failed pass and a folder that cannot be read are about the meeting, not
//  one tab, so they take the place of both tabs. Decided here, from the
//  meeting's own facts, so every rule is tested without a window.
//

import Foundation
import Meetings

enum MeetingCondition: Equatable, Sendable {
    /// There is a document to read, or one is still to come.
    case readable
    /// The final pass ran and found no words. Whether the recording was kept
    /// decides whether it can be transcribed again.
    case silent(duration: TimeInterval, canRetranscribe: Bool)
    /// The pass gave up. Whether its audio is still on disk decides whether
    /// it can run again.
    case failed(canRetry: Bool)
    /// Its files are missing or unreadable.
    case unreadable

    /// - Parameters:
    ///   - segmentCount: the loaded transcript's segments, `nil` while the
    ///     record is still loading — nothing is decided about words not read.
    ///   - keepsRecording: the meeting's recording was kept after the pass.
    ///   - canRetry: a failed pass still holds the audio to run again.
    static func resolve(
        _ meta: MeetingMeta, loadFailed: Bool, segmentCount: Int?, keepsRecording: Bool, canRetry: Bool
    ) -> MeetingCondition {
        if loadFailed { return .unreadable }
        if MeetingStatus.resolve(meta) == .failed { return .failed(canRetry: canRetry) }
        // Only a pass that finished can say nothing was said; no transcript
        // and no outcome yet is a pass still owed.
        if meta.transcriptProvenance?.source == .finalPass, segmentCount == 0 {
            return .silent(duration: meta.duration, canRetranscribe: keepsRecording)
        }
        return .readable
    }

    /// What the silent face says. The artboard's second sentence is true only
    /// while the recording is kept; without it the sentence gives the reason
    /// Re-transcribe is held back (product owner, 2026-10-20).
    static func silentMessage(duration: TimeInterval, canRetranscribe: Bool) -> String {
        let ran = "The recording ran for \(ranFor(duration)) and came back silent."
        return canRetranscribe
            ? "\(ran) If the wrong input was selected, the audio is still here."
            : "\(ran) Its audio was not kept, so it cannot be transcribed again."
    }

    /// What the failed face says. The artboard blames a quit, and a pass also
    /// gives up after its retries with Echo running, so the first sentence
    /// says only what is always true (product owner, 2026-10-20).
    static func failedMessage(canRetry: Bool) -> String {
        canRetry
            ? "The final pass did not finish. The audio survived, so the pass can run again from the start."
            : "The final pass did not finish, and its audio was not kept, so it cannot run again."
    }

    /// "42 seconds", "1 second", or the document's own minutes: "58 min".
    static func ranFor(_ seconds: TimeInterval) -> String {
        let whole = Int(seconds.rounded())
        guard whole < 60 else { return MeetingProperty.duration(seconds) }
        return whole == 1 ? "1 second" : "\(whole) seconds"
    }
}
