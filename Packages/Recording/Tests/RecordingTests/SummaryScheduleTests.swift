//
//  SummaryScheduleTests.swift
//  RecordingTests
//
//  What a Stop actually leaves behind: the pass that turns retained audio
//  into a transcript, what happens to the audio afterwards, and the summary
//  that follows — all through a real `RecordingSession` over a real
//  `MeetingStore` in a temporary folder.
//
//  The PoC could test none of this. Its pass, its retry budget and one of its
//  four summary triggers lived inside a controller and a view with no seams,
//  so the only thing with a table was the eligibility rule. Here the
//  transcription pass, the document stream and the caption are all injected
//  (`ScriptedPass`, `ScriptedSummarizer`), which leaves exactly the
//  scheduling under test — no model is downloaded, no weights are loaded, and
//  the `InertTextEngine` the summary model hands out records an issue if
//  anything tries to stream from it.
//
//  Nothing sleeps: every wait is `waitUntil` on a condition the work itself
//  makes true, and the negatives ("no pass ran") use `settle`, which is a
//  bounded number of cooperative turns rather than a disguised clock.
//

import Audio
import EchoCore
import EchoCoreTestSupport
import Foundation
import Meetings
import Testing
import Transcription

@testable import Recording

/// A transcript with words in it, for the assertions that count segments.
private func spokenSegments() -> [TranscriptSegment] {
    [
        TranscriptSegment(channel: .microphone, speaker: .me, text: "Shall we start?", start: 0, end: 2),
        TranscriptSegment(channel: .system, speaker: .teammates, text: "Yes, go ahead.", start: 2, end: 4),
    ]
}

// MARK: - The post-stop pass

@Suite("RecordingSession — the post-stop pass")
@MainActor
struct PostStopPassTests {

    @Test func aSuccessfulStopPassPersistsTheTranscriptAndDropsTheAudio() async throws {
        let segments = spokenSegments()
        let pass = ScriptedPass([.segments(segments)])
        try await withSession(pass: pass) { harness in
            // Off, so this test is about the transcript alone: an automatic
            // summary would need an engine, and no unit test loads one.
            harness.settings.setAutoGenerateSummaries(enabled: false)
            await harness.session.start()
            try await harness.captureAudibleAudio()
            await harness.session.stop()

            let meetingID = try #require(harness.session.currentMeetingID)
            pass.releaseAll()
            await waitUntil("the pass to replace the transcript") {
                harness.library.meta(for: meetingID)?.transcriptProvenance != nil
            }

            let meta = try #require(harness.library.meta(for: meetingID))
            #expect(meta.segmentCount == segments.count)
            // The provenance is written in the same step as the transcript it
            // describes, and it names the real checkpoint — a year from now
            // that is the only record of what produced these words.
            #expect(meta.transcriptProvenance?.source == .finalPass)
            #expect(meta.transcriptProvenance?.modelName == ParakeetModel.modelID)

            let folder = try #require(harness.meetingFolders().first)
            #expect(harness.fileNames(in: folder).contains("transcript.json"))
            let record = try #require(await harness.library.loadRecord(meetingID))
            #expect(record.segments.map(\.text) == segments.map(\.text))

            // The retained audio WAS the pending marker; the transcript
            // replaced it, so the meeting is no longer resumable.
            let stillRetained = await harness.store.hasRetainedAudio(for: meetingID)
            #expect(!stillRetained)
            let pending = await harness.store.pendingFinalizationMeetingIDs()
            #expect(pending.isEmpty)
        }
    }

    @Test func keepRecordingsPreservesTheAudioUnderItsArchiveNames() async throws {
        let pass = ScriptedPass([.segments(spokenSegments())])
        try await withSession(pass: pass) { harness in
            harness.settings.setAutoGenerateSummaries(enabled: false)
            harness.settings.setKeepRecordings(enabled: true)
            await harness.session.start()
            try await harness.captureAudibleAudio()
            await harness.session.stop()

            let meetingID = try #require(harness.session.currentMeetingID)
            pass.releaseAll()
            await waitUntil("the pass to conclude") {
                harness.library.meta(for: meetingID)?.transcriptProvenance != nil
            }

            let folder = try #require(harness.meetingFolders().first)
            let names = harness.fileNames(in: folder)
            // Renamed, not copied — and deliberately NOT `retained-*`, so the
            // archive never classifies as pending and is never swept.
            #expect(names.isSuperset(of: ["audio-mic.m4a", "audio-system.m4a"]))
            #expect(!names.contains("retained-mic.m4a"))
            #expect(!names.contains("retained-system.m4a"))
            let hasPreserved = await harness.store.hasPreservedAudio(for: meetingID)
            #expect(hasPreserved)
        }
    }

    @Test func withoutKeepRecordingsTheAudioIsGoneAltogether() async throws {
        let pass = ScriptedPass([.segments(spokenSegments())])
        try await withSession(pass: pass) { harness in
            harness.settings.setAutoGenerateSummaries(enabled: false)
            await harness.session.start()
            try await harness.captureAudibleAudio()
            await harness.session.stop()

            let meetingID = try #require(harness.session.currentMeetingID)
            pass.releaseAll()
            await waitUntil("the pass to conclude") {
                harness.library.meta(for: meetingID)?.transcriptProvenance != nil
            }

            let folder = try #require(harness.meetingFolders().first)
            let names = harness.fileNames(in: folder)
            // Neither name: the recording is not kept, and nothing is left
            // behind that a later sweep would have to reason about.
            #expect(!names.contains("audio-mic.m4a"))
            #expect(!names.contains("audio-system.m4a"))
            #expect(!names.contains("retained-mic.m4a"))
            #expect(!names.contains("retained-system.m4a"))
        }
    }

    @Test func aPendingPassIsNotAdmittedWhileARecordingRuns() async throws {
        let pass = ScriptedPass([.segments([])])
        try await withSession(pass: pass) { harness in
            harness.settings.setAutoGenerateSummaries(enabled: false)
            let pending = try await plantPendingMeeting(in: harness, minutesAgo: 10)

            await harness.session.start()
            await harness.session.resumePendingFinalizations()

            await settle()
            // Nothing decodes while the microphone is live: the GPU belongs to
            // the recording, and the queue says so honestly.
            #expect(pass.calls == 0)
            #expect(harness.session.queuedMeetingIDs == [pending])

            pass.releaseAll()
            // No audio was captured, so this stop persists no meeting — it
            // only opens and closes a pipeline, which is what lets the
            // deferred pass in.
            await harness.session.stop()
            await waitUntil("the deferred pass to run once the session ended") {
                harness.library.meta(for: pending)?.transcriptProvenance?.source == .finalPass
            }
            #expect(pass.calls == 1)
        }
    }

    @Test func aRecordingStartedMidPassDefersItWithoutConsumingAnAttempt() async throws {
        // The first pass reads the real yield signal; the two failures after
        // it are the proof that the deferral cost the meeting nothing.
        let pass = ScriptedPass([.yieldingIfAsked([]), .failure, .failure])
        try await withSession(pass: pass) { harness in
            harness.settings.setAutoGenerateSummaries(enabled: false)
            let pending = try await plantPendingMeeting(in: harness, minutesAgo: 10)

            pass.holdPasses()
            await harness.session.resumePendingFinalizations()
            await waitUntil("the pass to reach its gate") { pass.entered == 1 }

            await harness.session.start()  // raises the preemption signal
            pass.releaseAll()
            await waitUntil("the pass to be deferred back onto the queue") {
                harness.session.queuedMeetingIDs == [pending]
            }

            // A deferral, not a failure: the audio is untouched, so the
            // meeting is still exactly what the launch scan would resume.
            let stillPending = await harness.store.isPendingFinalization(pending)
            #expect(stillPending)
            #expect(harness.library.meta(for: pending)?.transcriptProvenance == nil)
            #expect(harness.session.terminalFailureMeetingIDs.isEmpty)

            await harness.session.stop()
            // Two more attempts before it gives up. A consumed attempt would
            // have converged after the first of them.
            await waitUntil("the meeting to spend both of its attempts") { pass.calls == 3 }
            await waitUntil("the meeting to converge terminally") {
                harness.session.terminalFailureMeetingIDs.contains(pending)
            }
        }
    }

    @Test func twoFailuresConvergeTerminallyAndKeepTheAudio() async throws {
        let pass = ScriptedPass([.failure, .failure])
        try await withSession(pass: pass) { harness in
            harness.settings.setAutoGenerateSummaries(enabled: false)
            pass.releaseAll()
            await harness.session.start()
            try await harness.captureAudibleAudio()
            await harness.session.stop()

            let meetingID = try #require(harness.library.metas.first?.id)
            await waitUntil("the meeting to converge terminally") {
                harness.library.meta(for: meetingID)?.transcriptProvenance?.source
                    == .terminalFailure
            }

            #expect(pass.calls == 2)
            #expect(harness.session.terminalFailureMeetingIDs == [meetingID])
            // The audio is KEPT — it is what the user's Retry works from — and
            // its disposition says terminal, so nothing auto-resumes it.
            let disposition = await harness.store.retainedAudioDisposition(for: meetingID)
            #expect(disposition == .terminalFailure)
            let pending = await harness.store.pendingFinalizationMeetingIDs()
            #expect(pending.isEmpty)
        }
    }

    @Test func retryTranscriptionReopensAConvergedMeeting() async throws {
        let segments = spokenSegments()
        let pass = ScriptedPass([.failure, .failure, .segments(segments)])
        try await withSession(pass: pass) { harness in
            harness.settings.setAutoGenerateSummaries(enabled: false)
            pass.releaseAll()
            await harness.session.start()
            try await harness.captureAudibleAudio()
            await harness.session.stop()

            let meetingID = try #require(harness.library.metas.first?.id)
            await waitUntil("the meeting to converge terminally") {
                harness.session.terminalFailureMeetingIDs.contains(meetingID)
            }

            harness.session.retryTranscription(meetingID)
            // The terminal mark is cleared the moment the user asks, so the
            // row stops offering a Retry it is already running.
            #expect(harness.session.terminalFailureMeetingIDs.isEmpty)

            await waitUntil("the retry to land a transcript") {
                harness.library.meta(for: meetingID)?.transcriptProvenance?.source == .finalPass
            }
            let meta = try #require(harness.library.meta(for: meetingID))
            #expect(meta.segmentCount == segments.count)
            #expect(harness.session.terminalFailureMeetingIDs.isEmpty)
            let stillRetained = await harness.store.hasRetainedAudio(for: meetingID)
            #expect(!stillRetained)
        }
    }
}

// MARK: - The summary schedule

@Suite("RecordingSession — the summary schedule")
@MainActor
struct SummaryScheduleTests {

    @Test func aStreamCutShortPersistsNothing() async throws {
        let drafts = [
            summaryDocument("# Notes\n\nStill writing", isFinal: false),
            summaryDocument("# Notes\n\nStill writing more", isFinal: false),
        ]
        let summarizer = ScriptedSummarizer([.cutShort(drafts)])
        try await withSession(summarizer: summarizer) { harness in
            let meeting = try await plantTranscribedMeeting(
                in: harness, minutesAgo: 5, text: "alpha")

            harness.session.kickSummaryBackfill()
            await waitUntil("the generation to end") { summarizer.terminations == 1 }
            await settle()

            // A generation that never emitted a final document has nothing to
            // persist: a half-written summary read as a finished one is worse
            // than no summary at all.
            let folder = try #require(harness.meetingFolders().first)
            #expect(!harness.fileNames(in: folder).contains("summary.md"))
            await harness.library.refresh()
            #expect(harness.library.meta(for: meeting)?.hasSummary == false)
            // And no caption either — it is written inside the same
            // acquisition as the summary it describes.
            #expect(summarizer.captions == 0)
        }
    }

    @Test func aCleanStreamPersistsExactlyTheFinalDocument() async throws {
        let final = summaryDocument(
            "# Notes\n\n- The decision was taken.", isFinal: true, modelName: "Scripted 1B")
        let summarizer = ScriptedSummarizer(
            [.documents([summaryDocument("# Notes\n\nDraft", isFinal: false), final])],
            caption: "The team agreed on the rollout date."
        )
        try await withSession(summarizer: summarizer) { harness in
            let meeting = try await plantTranscribedMeeting(
                in: harness, minutesAgo: 5, text: "alpha")

            harness.session.kickSummaryBackfill()
            await waitUntil("the summary to be persisted") {
                harness.library.meta(for: meeting)?.hasSummary == true
            }

            let record = try #require(await harness.library.loadRecord(meeting))
            // The final document, not the last draft: every earlier element of
            // the stream is a partial the model had not finished writing.
            #expect(record.summaryMarkdown == final.markdown)
            #expect(record.meta.oneLineDescription == "The team agreed on the rollout date.")
            // The name comes off the document, so a meeting records what
            // actually wrote its notes.
            #expect(record.meta.summaryModelName == "Scripted 1B")
            #expect(summarizer.generations == 1)
            #expect(summarizer.captions == 1)
        }
    }

    @Test func theScanNeverSummarizesAgainstAModelThatIsNotOnDisk() async throws {
        let summarizer = ScriptedSummarizer([.documents([summaryDocument("# Notes", isFinal: true)])])
        try await withSession(summarizer: summarizer, summaryModelOnDisk: false) { harness in
            let meeting = try await plantTranscribedMeeting(
                in: harness, minutesAgo: 5, text: "alpha")

            harness.session.kickSummaryBackfill()
            await settle()

            // The scan never triggers the multi-gigabyte download on its own —
            // only a summary the user asked for may do that. (The same meeting
            // and the same script are summarized in the test above, where the
            // snapshot is present, so the model gate is the only difference.)
            #expect(summarizer.generations == 0)
            #expect(harness.library.meta(for: meeting)?.hasSummary == false)
        }
    }

    @Test func theBackfillSummarizesOneMeetingAtATimeNewestFirst() async throws {
        let summarizer = ScriptedSummarizer([
            .documents([summaryDocument("# Newest", isFinal: true)]),
            .documents([summaryDocument("# Older", isFinal: true)]),
        ])
        try await withSession(summarizer: summarizer) { harness in
            let older = try await plantTranscribedMeeting(
                in: harness, minutesAgo: 100, text: "older")
            let newest = try await plantTranscribedMeeting(
                in: harness, minutesAgo: 1, text: "newest")

            harness.session.kickSummaryBackfill()
            await waitUntil("both meetings to be summarized") { summarizer.generations == 2 }

            // The seam is handed segments rather than an id, so the transcript
            // text is what says which meeting went first.
            #expect(summarizer.transcripts.map { $0.first?.text } == ["newest", "older"])

            await waitUntil("the older meeting's summary to land") {
                harness.library.meta(for: older)?.hasSummary == true
            }
            #expect(harness.library.meta(for: newest)?.hasSummary == true)
            let newestRecord = try #require(await harness.library.loadRecord(newest))
            #expect(newestRecord.summaryMarkdown == "# Newest")
        }
    }

    @Test func aGenerationAbandonedByARecordingTouchesNothing() async throws {
        let summarizer = ScriptedSummarizer([
            .documents([
                summaryDocument("# Notes\n\nDraft", isFinal: false),
                summaryDocument("# Notes\n\nComplete", isFinal: true),
            ])
        ])
        try await withSession(summarizer: summarizer) { harness in
            let meeting = try await plantTranscribedMeeting(
                in: harness, minutesAgo: 5, text: "alpha")

            // Held after its first document, so a recording can start in the
            // middle of the generation rather than around it.
            summarizer.holdAfterDocument(1)
            harness.session.kickSummaryBackfill()
            await waitUntil("the generation to be under way") { summarizer.yielded == 1 }
            #expect(harness.session.phase == .summarizing(meetingID: meeting))

            await harness.session.start()
            summarizer.releaseAll()
            await waitUntil("the abandoned generation to be torn down") {
                summarizer.terminations == 1
            }

            await harness.session.stop()
            await waitUntil("the session to settle") { harness.session.phase == .idle }

            // The final document did arrive — after the generation had already
            // been abandoned. A late arrival from a previous generation writes
            // nothing, and the phase does not linger on `.summarizing` for a
            // generation nobody is running any more.
            let folder = try #require(harness.meetingFolders().first)
            #expect(!harness.fileNames(in: folder).contains("summary.md"))
            await harness.library.refresh()
            #expect(harness.library.meta(for: meeting)?.hasSummary == false)
            #expect(summarizer.captions == 0)
            #expect(harness.session.currentMeetingID == nil)
        }
    }
}
