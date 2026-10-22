//
//  SummaryFace.swift
//  Workspace
//
//  What a meeting's Summary tab says between Stop and its notes: one face per
//  step of the work, as the design draws them — the final pass and
//  its real percentage, waiting behind another meeting's pass, the summary
//  model coming into memory, the generation, the notes streaming in, and a
//  generation that failed. Each names the work Echo is doing rather than one
//  shared spinner. The Transcript tab, while there is no transcript yet, says
//  the same about the pass.
//
//  Decided here from what the session publishes, so every rule is tested
//  without a window; `SummaryFaceView` draws the result. The artboard's
//  first face carries a draft badge and a line about live text, which v2 does
//  not have; both are dropped and the line is the recording artboard's
//  (product owner, 2026-10-02).
//

import Foundation
import Recording

enum SummaryFace: Equatable, Sendable {
    /// The notes are on disk and loaded: the document shows them.
    case summary
    /// This meeting's final pass is running.
    case finalizing(percent: Int)
    /// This meeting waits for a pass behind another meeting, named when
    /// there is one to name.
    case waitingToFinalize(behind: String?)
    /// The summary model is coming into memory for this meeting.
    case loadingModel
    /// The model is reading the transcript and has written nothing yet.
    case generating
    /// The notes so far, still being written.
    case writing(markdown: String)
    /// The notes were just written and the document is reading them back:
    /// the last of the draft, without its cursor — or nothing, rather than a
    /// flash of "No summary yet" in between.
    case settling(markdown: String?)
    /// This run's generation threw.
    case failed(reason: String)
    /// No work under way, and no notes yet.
    case notYet(transcriptReadable: Bool)
    /// No work under way and no notes yet, with nothing in the way of
    /// writing them: the transcript is in and the summary model is on disk.
    /// The way out is the user's own Generate summary — with automatic
    /// summaries off, the only one there is.
    case canGenerate

    /// - Parameters:
    ///   - hasLoadedSummary: the loaded record carries notes.
    ///   - metaHasSummary: the meeting's header says notes are on disk.
    ///   - aheadTitle: the meeting this one waits behind, when it is queued.
    ///   - modelLoading: the summary model is coming into memory.
    ///   - draft: what the model has written so far for this meeting — or
    ///     wrote last, held until the notes are read back.
    ///   - failure: why this meeting's generation failed this run.
    ///   - summaryModelOnDisk: the summary model is on disk. Without it a
    ///     request would start a download of several gigabytes that this tab
    ///     has no face for; the models panel is where that one is fetched.
    static func resolve(
        meetingID: UUID,
        hasLoadedSummary: Bool,
        metaHasSummary: Bool,
        phase: RecordingPhase,
        queued: [UUID],
        aheadTitle: String?,
        modelLoading: Bool,
        draft: String?,
        failure: String?,
        transcriptReadable: Bool,
        summaryModelOnDisk: Bool
    ) -> SummaryFace {
        if hasLoadedSummary { return .summary }
        if let pass = passFace(meetingID: meetingID, phase: phase, queued: queued, aheadTitle: aheadTitle) {
            return pass
        }
        let written = draft.flatMap { $0.isEmpty ? nil : $0 }
        if case .summarizing(let summarizing) = phase, summarizing == meetingID {
            if let written { return .writing(markdown: written) }
            return modelLoading ? .loadingModel : .generating
        }
        if metaHasSummary { return .settling(markdown: written) }
        if let failure { return .failed(reason: failure) }
        if transcriptReadable && summaryModelOnDisk { return .canGenerate }
        return .notYet(transcriptReadable: transcriptReadable)
    }

    /// The faces about the transcript's pass, which the Transcript tab wears
    /// too while there is no transcript to show; `nil` when no pass is owed
    /// to this meeting right now.
    static func passFace(meetingID: UUID, phase: RecordingPhase, queued: [UUID], aheadTitle: String?) -> SummaryFace? {
        if case .finalizing(let finalizing, let progress) = phase, finalizing == meetingID {
            return .finalizing(percent: percent(of: progress))
        }
        if queued.contains(meetingID) { return .waitingToFinalize(behind: aheadTitle) }
        return nil
    }

    /// The meeting a queued one waits behind: the one ahead of it in the
    /// queue, or — at its front — the one being worked on now.
    static func meetingAhead(of meetingID: UUID, phase: RecordingPhase, queued: [UUID]) -> UUID? {
        guard let index = queued.firstIndex(of: meetingID) else { return nil }
        return index > 0 ? queued[index - 1] : phase.meetingID
    }

    /// The pass's own fraction as the whole percent the face reads: carried,
    /// never re-derived, and not clamped again (ADR-007) — only cut to a
    /// whole number, down, so it never claims a percent it has not reached.
    static func percent(of progress: Double) -> Int {
        Int((progress * 100).rounded(.down))
    }

    // MARK: - What it says

    static let finalizingTitle = "Finalizing transcript…"
    static let finalizingMessage = "Echo writes the transcript when you stop, then the notes right after."
    static let waitingTitle = "Waiting to finalize"
    static let loadingTitle = "Loading summary model…"
    static let generatingTitle = "Generating summary…"
    static let generatingMessage = "Echo is reading the final transcript locally."
    static let writingBadge = "Writing"
    static let failedTitle = "Summary failed"
    static let notYetTitle = "No summary yet"
    /// The PoC's sentence for the same state.
    static let canGenerateMessage = "The transcript is saved, so you can generate one now."

    static func waitingMessage(behind: String?) -> String {
        let one = "One meeting is finalized at a time."
        guard let behind else { return one }
        return "\(one) This one starts when \(behind) is done."
    }

    /// "A minute" is the summary model's idle release (`SummaryModel.idleTimeout`,
    /// 60 seconds): change one and the other is no longer true.
    static func loadingMessage(modelName: String) -> String {
        "Bringing \(modelName) into memory. It is released again after a minute idle."
    }

    /// The reason, then what is still true: a failed summary never touches
    /// the transcript.
    static func failedMessage(reason: String) -> String {
        let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        let ended = trimmed.last.map { ".!?".contains($0) } ?? true
        let sentence = ended ? trimmed : trimmed + "."
        return "\(sentence) The transcript is safe — you can try again."
    }
}
