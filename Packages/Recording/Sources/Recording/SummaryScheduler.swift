//
//  SummaryScheduler.swift
//  Recording
//
//  Which meeting gets summarized, when, and what is allowed to be written
//  when it finishes.
//
//  In the PoC this lived in the controller and, for one of its four triggers,
//  inside a view — which is why the only part with tests was the eligibility
//  rule. That rule ports unchanged as `SummaryBackfillPolicy`; everything
//  around it is rewritten here so the gates are one object with one entry
//  point.
//
//  One meeting at a time, newest first, and never against a model that is not
//  already on disk — except for an explicit user request, which is the one
//  trigger allowed to start a download. Recording never waits for a model;
//  summarizing may, but only because a person asked it to.
//

import EchoCore
import Foundation
import Meetings
import Summarization
import os

/// Produces the document stream for one transcript. A seam so the scheduling
/// can be tested without the summarizer's whole routing, prompt and merge
/// pipeline, which `Summarization` already tests on its own.
typealias SummaryGenerating =
    @Sendable ([TranscriptSegment], any TextGenerating) async ->
    AsyncThrowingStream<SummaryDocument, Error>

/// Produces the library row's one-line caption, or nil. Best effort by
/// contract: a row with no caption is correct, an invented one is not.
typealias CaptionGenerating = @Sendable (SummaryDocument, any TextGenerating) async -> String?

@MainActor
final class SummaryScheduler {

    private static let log = Logger(
        subsystem: AppIdentity.logSubsystem, category: "SummaryScheduler")

    /// Thrown to abandon a generation. It exists so abandonment travels the
    /// error path: the persist happens only after the stream completes
    /// cleanly, so throwing is what guarantees a cut-short stream writes
    /// nothing.
    private struct SummaryAbandoned: Error {}

    private let library: MeetingLibrary
    private let settings: AppSettings
    private let model: SummaryModel
    private let driver: FinalizationDriver
    private let generate: SummaryGenerating
    private let caption: CaptionGenerating
    private let isRecording: @MainActor () -> Bool
    private let onSummarizingChanged: @MainActor (UUID?) -> Void

    /// The tail of the work chain. Every entry point links onto it, so one
    /// meeting is summarized at a time however many triggers fire — and a
    /// redundant run costs a library refresh and a policy call that returns
    /// nil.
    private var runTask: Task<Void, Never>?

    /// The meeting an explicit request named, kept until it is actually
    /// served. The PoC consumed it before the policy ran, so a request whose
    /// meeting happened to be ineligible at that instant was silently lost;
    /// here it survives to the next kick, because the user pressed a button
    /// and something has to come of it.
    private var requestedID: UUID?

    /// Meetings whose generation failed this run. In-memory only, so a
    /// transcript the model chokes on cannot burn a generation on every
    /// trigger — and is retried at the next launch, when this set dies with
    /// the process.
    private var failedIDs: Set<UUID> = []

    init(
        library: MeetingLibrary,
        settings: AppSettings,
        model: SummaryModel,
        driver: FinalizationDriver,
        generate: @escaping SummaryGenerating,
        caption: @escaping CaptionGenerating,
        isRecording: @escaping @MainActor () -> Bool,
        onSummarizingChanged: @escaping @MainActor (UUID?) -> Void
    ) {
        self.library = library
        self.settings = settings
        self.model = model
        self.driver = driver
        self.generate = generate
        self.caption = caption
        self.isRecording = isRecording
        self.onSummarizingChanged = onSummarizingChanged
    }

    /// The user asked for this meeting's summary. It front-runs the scan and
    /// works with automatic summaries off — and it is the one trigger that
    /// may fetch a model that is not on disk yet.
    func request(_ meetingID: UUID) {
        requestedID = meetingID
        failedIDs.remove(meetingID)
        kick()
    }

    /// Runs the scan. Called at launch, after every Stop, when the window
    /// opens, and when the model's download completes.
    func kick() {
        _ = enqueue { [weak self] in await self?.run() }
    }

    /// The just-finalized meeting's own summary, awaited by the stop path so
    /// the post-stop pipeline stays open across it — deferred passes resume
    /// behind the new meeting's pass AND its summary, not between them.
    ///
    /// It asks the same policy the scan asks, with no request outstanding. If
    /// the answer is a different meeting the pipeline is left alone and the
    /// backfill picks it up after the pipeline closes: the policy stays one
    /// implementation, and the pipeline stays scoped to one meeting.
    func summarizeAfterFinalization(_ meetingID: UUID) async {
        await enqueue { [weak self] in
            guard let self else { return }
            await self.library.refresh()
            guard !self.isRecording(), await self.model.snapshotExists() else { return }
            guard let meta = await self.nextEligibleMeeting(requested: nil), meta.id == meetingID
            else {
                return
            }
            _ = await self.summarize(meta)
        }.value
    }

    /// Links `body` onto the work chain and hands back its task.
    private func enqueue(_ body: @escaping @MainActor () async -> Void) -> Task<Void, Never> {
        let previous = runTask
        let task = Task { @MainActor in
            await previous?.value
            await body()
        }
        runTask = task
        return task
    }

    /// Waits for everything currently queued. For tests and for a caller that
    /// must not race the chain.
    func waitForCurrentRun() async {
        await runTask?.value
    }

    private func run() async {
        // The library loads asynchronously at launch, and a concluding pass
        // changes `hasSummary` on disk; an explicit refresh is what makes
        // `metas` current for the policy below.
        await library.refresh()

        while !isRecording() {
            let onDisk = await model.snapshotExists()
            let requested = pendingRequest(onDisk: onDisk)
            // The scan never triggers the multi-gigabyte download on its own.
            // Only a request the user made does, and only for the meeting
            // they named.
            guard requested != nil || onDisk else { return }

            guard let meta = await nextEligibleMeeting(requested: requested) else { return }

            if meta.id == requested { requestedID = nil }
            let keepGoing = await summarize(meta)
            guard keepGoing else { return }
            await library.refresh()
        }
    }

    /// Asks the policy which meeting is next, against a freshly read
    /// ineligibility set.
    ///
    /// Re-read on every call: the pending marker is on-disk state that a
    /// concluding pass clears, and a queued re-transcribe is not pending on
    /// disk at all — its clone carries `finalPass` provenance — yet its
    /// transcript is equally about to be replaced.
    private func nextEligibleMeeting(requested: UUID?) async -> MeetingMeta? {
        let pending = await library.store.pendingFinalizationMeetingIDs()
        var ineligible = Set(pending).union(driver.queuedMeetingIDs)
        if let running = driver.currentMeetingID { ineligible.insert(running) }
        return SummaryBackfillPolicy.nextMeeting(
            metas: library.metas,
            requestedID: requested,
            autoGenerateSummaries: settings.autoGenerateSummaries,
            failedIDs: failedIDs,
            ineligibleIDs: ineligible
        )
    }

    /// The outstanding request, dropped once there is nothing left it could
    /// ask for — the meeting is gone, or it already has its summary.
    private func pendingRequest(onDisk: Bool) -> UUID? {
        guard let requestedID else { return nil }
        guard let meta = library.meta(for: requestedID), !meta.hasSummary else {
            self.requestedID = nil
            return nil
        }
        return requestedID
    }

    /// Generates and persists one meeting's summary. Returns whether the run
    /// should continue to the next meeting.
    private func summarize(_ meta: MeetingMeta) async -> Bool {
        guard let record = await library.loadRecord(meta.id), !record.segments.isEmpty else {
            // Nothing to ground a summary in. Not the model's fault and not
            // worth retrying this run.
            failedIDs.insert(meta.id)
            return true
        }

        onSummarizingChanged(meta.id)
        defer { onSummarizingChanged(nil) }

        do {
            try await withSummaryEngine { engine in
                var final: SummaryDocument?
                for try await document in await self.generate(record.segments, engine) {
                    // A recording started: abandon rather than compete with
                    // live capture for the GPU. Throwing is what keeps the
                    // half-written document from being persisted.
                    guard !self.isRecording() else { throw SummaryAbandoned() }
                    if document.isFinal { final = document }
                }
                // A clean finish yields exactly one final document, and it is
                // always the last element; a cancelled or failed generation
                // yields none and throws instead. So this is the whole
                // persistence rule.
                try Task.checkCancellation()
                guard let final else { throw SummarizationError.emptyModelResponse }

                // Generated inside the SAME engine acquisition as the summary
                // it describes, so the idle release arms once, after both.
                let captionText = await self.caption(final, engine)
                try await self.library.store.attachSummary(
                    markdown: final.markdown,
                    caption: captionText,
                    modelName: final.modelName,
                    to: meta.id
                )
            }
        } catch is SummaryAbandoned {
            return false
        } catch is CancellationError {
            return false
        } catch let error as SummaryModelError {
            // A model-level failure would fail every remaining meeting too,
            // so the meeting is not blamed and the run ends. The model's own
            // state carries the message and the retry.
            ErrorTrace.record(
                "Summary model unavailable", error: error, category: "SummaryScheduler")
            return false
        } catch {
            failedIDs.insert(meta.id)
            ErrorTrace.record(
                "Summary generation failed", error: error, category: "SummaryScheduler",
                metadata: ["meeting": meta.id.uuidString])
            return true
        }
        return true
    }

    /// Runs `body` with a loaded engine, under the pass gate.
    ///
    /// The balance IS the contract, and it is asymmetric: a FAILED acquire
    /// has already decremented its own work count, so releasing after it
    /// would decrement twice — and an over-release is silently swallowed, so
    /// the bug would be invisible rather than loud. Every exit from the body,
    /// including a throw and a cancellation, releases exactly once. A `defer`
    /// cannot do this: Swift forbids `await` in one.
    private func withSummaryEngine<T>(
        _ body: @MainActor (any TextGenerating) async throws -> T
    ) async throws -> T {
        await driver.beginSummaryWork()
        let engine: any TextGenerating
        do {
            engine = try await model.acquireEngine()
        } catch {
            driver.endSummaryWork()
            throw error
        }
        do {
            let result = try await body(engine)
            await model.releaseEngine()
            driver.endSummaryWork()
            return result
        } catch {
            await model.releaseEngine()
            driver.endSummaryWork()
            throw error
        }
    }
}
