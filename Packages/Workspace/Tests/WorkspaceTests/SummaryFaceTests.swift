//
//  SummaryFaceTests.swift
//  WorkspaceTests
//
//  The Summary tab between Stop and the notes, as values: which face a
//  meeting wears for each state of the work — its pass, the queue, the model,
//  the generation, the notes streaming in, a failure — and what each says.
//

import Foundation
import Recording
import Testing

@testable import Workspace

@Suite("The Summary tab's faces")
struct SummaryFaceTests {

    private let meeting = UUID()
    private let other = UUID()

    private func face(
        hasLoadedSummary: Bool = false,
        metaHasSummary: Bool = false,
        phase: RecordingPhase = .idle,
        queued: [UUID] = [],
        aheadTitle: String? = nil,
        modelLoading: Bool = false,
        draft: String? = nil,
        failure: String? = nil,
        transcriptReadable: Bool = true,
        summaryModelOnDisk: Bool = false
    ) -> SummaryFace {
        SummaryFace.resolve(
            meetingID: meeting, hasLoadedSummary: hasLoadedSummary, metaHasSummary: metaHasSummary, phase: phase,
            queued: queued, aheadTitle: aheadTitle, modelLoading: modelLoading, draft: draft, failure: failure,
            transcriptReadable: transcriptReadable, summaryModelOnDisk: summaryModelOnDisk)
    }

    @Test("written notes win over everything")
    func notesWin() {
        #expect(face(hasLoadedSummary: true, phase: .summarizing(meetingID: meeting), failure: "x") == .summary)
    }

    @Test("its own pass shows the pass's percentage, cut down to a whole one")
    func finalizing() {
        #expect(face(phase: .finalizing(meetingID: meeting, progress: 0.629)) == .finalizing(percent: 62))
        #expect(face(phase: .finalizing(meetingID: meeting, progress: 1)) == .finalizing(percent: 100))
        // Another meeting's pass is not this one's.
        #expect(face(phase: .finalizing(meetingID: other, progress: 0.5)) == .notYet(transcriptReadable: true))
    }

    @Test("a queued meeting waits behind the one ahead of it, or the one being worked on")
    func waiting() {
        let third = UUID()
        let running = RecordingPhase.finalizing(meetingID: other, progress: 0.2)
        #expect(SummaryFace.meetingAhead(of: meeting, phase: running, queued: [meeting, third]) == other)
        #expect(SummaryFace.meetingAhead(of: third, phase: running, queued: [meeting, third]) == meeting)
        #expect(SummaryFace.meetingAhead(of: meeting, phase: .idle, queued: [meeting]) == nil)
        #expect(SummaryFace.meetingAhead(of: meeting, phase: running, queued: []) == nil)
        #expect(face(phase: running, queued: [meeting], aheadTitle: "Weekly") == .waitingToFinalize(behind: "Weekly"))
    }

    @Test("while its summary runs: the model loading, then generating, then the notes streaming in")
    func summarizing() {
        let summarizing = RecordingPhase.summarizing(meetingID: meeting)
        #expect(face(phase: summarizing, modelLoading: true) == .loadingModel)
        #expect(face(phase: summarizing) == .generating)
        #expect(face(phase: summarizing, draft: "") == .generating, "an empty draft has nothing to show")
        #expect(face(phase: summarizing, draft: "### Action Items") == .writing(markdown: "### Action Items"))
        // Another meeting's summary is not this one's.
        #expect(face(phase: .summarizing(meetingID: other), draft: nil) == .notYet(transcriptReadable: true))
    }

    @Test("written but not read back yet: the last of the draft, never a flash of 'No summary yet'")
    func settling() {
        #expect(face(metaHasSummary: true, draft: "# Notes") == .settling(markdown: "# Notes"))
        #expect(face(metaHasSummary: true) == .settling(markdown: nil))
    }

    @Test("a failure says why, and gives way to the work when it is asked for again")
    func failed() {
        #expect(face(failure: "The model returned nothing.") == .failed(reason: "The model returned nothing."))
        #expect(face(phase: .summarizing(meetingID: meeting), failure: "old") == .generating)
    }

    @Test("with no work under way and no notes, the tab says so")
    func notYet() {
        #expect(face() == .notYet(transcriptReadable: true))
        #expect(face(transcriptReadable: false) == .notYet(transcriptReadable: false))
    }

    @Test("with the transcript in and the model on disk, the way out is Generate summary")
    func canGenerate() {
        #expect(face(summaryModelOnDisk: true) == .canGenerate)
        // Nothing to ground notes in yet.
        #expect(face(transcriptReadable: false, summaryModelOnDisk: true) == .notYet(transcriptReadable: false))
        // Another meeting's summary running does not hold this one's request back.
        #expect(face(phase: .summarizing(meetingID: other), summaryModelOnDisk: true) == .canGenerate)
    }

    @Test("the work under way, a failure or written notes always come before the button")
    func workBeforeTheButton() {
        #expect(face(failure: "Out of memory", summaryModelOnDisk: true) == .failed(reason: "Out of memory"))
        #expect(face(metaHasSummary: true, summaryModelOnDisk: true) == .settling(markdown: nil))
        #expect(face(phase: .summarizing(meetingID: meeting), summaryModelOnDisk: true) == .generating)
        #expect(face(queued: [meeting], summaryModelOnDisk: true) == .waitingToFinalize(behind: nil))
    }

    @Test("the Transcript tab wears the pass's faces, and nothing else")
    func transcriptTab() {
        #expect(
            SummaryFace.passFace(
                meetingID: meeting, phase: .finalizing(meetingID: meeting, progress: 0.4), queued: [], aheadTitle: nil)
                == .finalizing(percent: 40))
        #expect(
            SummaryFace.passFace(meetingID: meeting, phase: .idle, queued: [meeting], aheadTitle: "Weekly")
                == .waitingToFinalize(behind: "Weekly"))
        #expect(
            SummaryFace.passFace(
                meetingID: meeting, phase: .summarizing(meetingID: meeting), queued: [], aheadTitle: nil) == nil)
    }

    @Test("what the faces say")
    func copy() {
        #expect(
            SummaryFace.waitingMessage(behind: "Sancrisoft weekly")
                == "One meeting is finalized at a time. This one starts when Sancrisoft weekly is done.")
        #expect(SummaryFace.waitingMessage(behind: nil) == "One meeting is finalized at a time.")
        #expect(
            SummaryFace.loadingMessage(modelName: "Qwen3.5 4B")
                == "Bringing Qwen3.5 4B into memory. It is released again after a minute idle.")
        #expect(
            SummaryFace.failedMessage(reason: "The summary model returned an empty summary.")
                == "The summary model returned an empty summary. The transcript is safe — you can try again.")
        #expect(
            SummaryFace.failedMessage(reason: "Out of memory")
                == "Out of memory. The transcript is safe — you can try again.")
    }
}
