//
//  RecordingController.swift
//  Echo
//
//  Orchestrates a recording session: starts the two native capture channels,
//  routes their loudness levels into `RecordingState` for the waveforms, and
//  feeds 16 kHz mono Float frames into the transcription pipeline.
//
//  This is the object the UI talks to (injected via the environment).
//

import SwiftUI
import Observation
import os

/// Measures real mic-capture gaps for SP-002's "input switch mid-recording"
/// criterion: wall time in which the mic channel captured nothing while the
/// Team channel kept running. `RecordingController` opens an episode when it
/// takes the mic down (device-switch rebuild, lost-device degradation, or a
/// session that starts with no input device), and the first delivered batch
/// afterwards closes it; the measured gap is reported to
/// `TranscriptionPipeline.noteCaptureGap` so the mic clock stays wall-aligned
/// with the Team channel (SP-001's 100 ms skew budget, ADR-003's timing gate).
///
/// `ContinuousClock` on purpose: the gap feeds a clock *correction*, so the
/// measurement must be monotonic — wall-clock `Date` drifts and jumps with
/// NTP/user changes.
///
/// Thread-safety: `noteDelivery` runs on the mic capture callback while
/// `beginEpisode` runs on the main actor, so state is lock-guarded (the same
/// pattern as the diagnostics sinks); the per-batch cost is one uncontended
/// lock acquisition.
nonisolated final class MicCaptureGapTracker: @unchecked Sendable {

    private let lock = NSLock()
    /// Instant of the most recent delivered batch ≈ the end of the last
    /// audio that actually reached the pipeline (a tap delivers a buffer as
    /// soon as its last sample is captured).
    private var lastDeliveryEnd: ContinuousClock.Instant?
    /// Set while the mic is (about to be) down; cleared by the delivery
    /// that closes the episode.
    private var episodeStart: ContinuousClock.Instant?

    /// Marks the mic as going down (engine teardown, device lost, or a
    /// degraded no-device session start). Idempotent within an episode: with
    /// no delivery in between, chained teardowns (a failed restart followed
    /// by another under device churn) keep the earliest instant, so one
    /// continuous outage measures as one gap.
    func beginEpisode(now: ContinuousClock.Instant = .now) {
        lock.lock()
        defer { lock.unlock() }
        guard episodeStart == nil else { return }
        episodeStart = now
    }

    /// Records one delivered mic batch (`batchDuration` seconds of audio
    /// ending at `now`). Returns the measured capture gap when this batch is
    /// the first after a pending episode, `nil` on the steady-state path.
    ///
    /// The gap is the ingest-timeline hole: from the end of the last
    /// *delivered* audio (a torn-down tap drops its partially filled buffer,
    /// so captured-but-undelivered audio is honestly part of the hole — and
    /// a device that died before its loss was noticed stopped delivering at
    /// death, not at the notice) to the start of this batch's audio, which
    /// began `batchDuration` before its delivery.
    func noteDelivery(batchDuration: TimeInterval, now: ContinuousClock.Instant = .now) -> TimeInterval? {
        lock.lock()
        defer { lock.unlock() }
        let previousEnd = lastDeliveryEnd
        let episode = episodeStart
        lastDeliveryEnd = now
        episodeStart = nil
        guard let episode else { return nil }

        let holeStart = previousEnd ?? episode
        let gap = Self.seconds(holeStart.duration(to: now)) - batchDuration
        // An episode resolved within one batch left no positive hole in the
        // ingest timeline — nothing to declare.
        return gap > 0 ? gap : nil
    }

    private static func seconds(_ duration: Duration) -> TimeInterval {
        let parts = duration.components
        return TimeInterval(parts.seconds) + TimeInterval(parts.attoseconds) / 1e18
    }
}

@Observable
@MainActor
final class RecordingController {

    static let log = Logger(subsystem: "com.sancrisoft.Echo", category: "RecordingController")

    let state = RecordingState()

    /// Persistent meeting history (SPEC-03). Owned here so the controller can
    /// save on stop and attach summaries; the dashboard reads it for the sidebar.
    let library = MeetingLibrary()

    /// The meeting saved for the just-stopped session, so both the stop path and
    /// a later `retrySummary` attach their summary to the correct meeting.
    private var lastSavedMeetingID: UUID?

    private let mic = MicrophoneCapture()
    private let system = SystemAudioCapture()
    private let pipeline: TranscriptionPipeline
    // Controller-long, reset per session via begin/endSession: consumes the
    // gate-decision record stream and the input-device signals to drive the
    // input-health notices (SP-002 "no silent dropout"). Observational by
    // decision (ADR-006): its effects are notice-only, so nothing here can
    // ever switch the audio path.
    private let inputHealth: InputHealthTracker
    private let routeMonitor = OutputRouteMonitor()
    private var echoMode: EchoModeMachine?
    private let inputMonitor = InputDeviceMonitor()
    // Per-session (built in `startInputDeviceHandling`): maps default-input
    // device events to mic restart / Team-only degradation actions (SP-002).
    private var inputLifecycle: InputDeviceLifecycleMachine?
    // Serializes engine rebuilds under device churn: each restart awaits the
    // previous one, so two rebuilds can never interleave.
    private var micRestartTask: Task<Void, Never>?
    // Per-session (built in `wireCallbacks`): measures how long the mic
    // channel captured nothing across device-change rebuilds and lost-device
    // episodes, so the pipeline's mic clock can be realigned (SP-002 "input
    // switch mid-recording"; SP-001 100 ms skew budget).
    private var micGapTracker: MicCaptureGapTracker?
    // Per-session (built in `startEchoHandling`): wraps a fresh engine stage
    // and applies the mode machine's current mode to the audio path.
    private var switchingStage: SwitchingAECStage?
    private let summarizer = SummarizationPipeline()
    private let summaryModelManager = SummaryModelManager()
    private var sessionGeneration = 0
    /// Dashboard-facing lifecycle of the summary model (download/load/ready).
    /// Owned here so the UI never talks to the manager actor directly.
    private(set) var summaryModelState: SummaryModelState = .notDownloaded
    /// Same for the speech model — fed by the pipeline's phase handler. Starts
    /// as `.loading` because `prepare()` kicks the (cache-first) load at init.
    private(set) var speechModelState: SpeechModelState = .loading

    /// One-shot request (set by the menu bar's Stop) for the dashboard to open
    /// straight onto the just-stopped meeting, so the streaming summary — and
    /// the finished one, via the detail's auto-switch to the AI Summary tab —
    /// is actually seen. Consumed and cleared by `DashboardView`.
    var pendingLiveDetailOpen = false

    /// Set when the user pressed record but the speech model still needed its
    /// (multi-minute) download — fresh install, or an earlier one that failed.
    /// While true the dashboard shows the "downloading — recording unlocks
    /// when it finishes" callout and the menu bar opens the dashboard onto it.
    /// Cleared when a session actually starts or the callout is dismissed.
    private(set) var recordingAwaitingSpeechModel = false

    /// The gate callout's dismiss. The download itself keeps running — only
    /// the "you pressed record too early" framing goes away.
    func dismissSpeechModelGate() { recordingAwaitingSpeechModel = false }

    /// One-shot per app run: the record-while-not-downloaded gate uses the
    /// wait to get both capture-permission prompts out of the way.
    private var capturePermissionsPrimed = false

    var isRecording: Bool { state.isRecording }

    init() {
        // Every finalized-chunk gate decision fans out to the permanent
        // OSLog diagnostic (SP-002 US-12, previously the pipeline's default)
        // and to the input-health classifier (ADR-006) — one stream, two
        // observational consumers, neither able to influence the decision.
        let inputHealth = InputHealthTracker()
        self.inputHealth = inputHealth
        self.pipeline = TranscriptionPipeline(
            gateDiagnostics: FanOutGateDiagnosticsSink([OSLogGateDiagnosticsSink(), inputHealth])
        )
        inputHealth.onEffect = { [weak self] generation, effect in
            // Arrives on the pipeline's executor (gate decisions) or the
            // main actor (device signals); notice state lives on the main
            // actor. The generation + isRecording guards drop teardown
            // stragglers — e.g. effects from the end-of-session flush — so
            // a health notice can never appear while idle or leak into a
            // later session (the `onEngineEvent` discipline).
            Task { @MainActor [weak self] in
                guard let self, self.sessionGeneration == generation,
                      self.state.isRecording else { return }
                self.state.applyInputHealthEffect(effect)
            }
        }

        // Warm up the (large) models at launch so pressing record is instant.
        Task { await prepare() }
        // Paint the summary-model control from the on-disk cache state.
        Task { await refreshSummaryModelState() }
        // Catch up on summaries a quit interrupted (or that never ran): scan
        // the saved meetings once the library loads.
        kickSummaryBackfill()
    }

    /// Loads the transcription models ahead of time. Idempotent — also the
    /// banner's speech-model Retry action (a failed load resets itself so a
    /// later call genuinely retries).
    func prepare() async {
        await pipeline.setModelPhaseHandler { [weak self] phase in
            Task { @MainActor in self?.speechModelState = phase }
        }
        await pipeline.preload(updating: state)
    }

    // MARK: - Control

    func toggle() async {
        if state.isRecording {
            await stop()
        } else {
            await start()
        }
    }

    func start() async {
        guard !state.isRecording else { return }

        // Recording without the speech model would capture audio the session
        // can't transcribe. When the model still needs its download, don't
        // start: surface the progress in the dashboard instead, and use the
        // wait to get the one-time setup done — kick the download (idempotent;
        // also retries a failed load) and raise both capture-permission
        // prompts. A cache-only load is not gated: it resolves in seconds and
        // `pipeline.start` below awaits it as it always has.
        if await pipeline.needsModelDownload {
            recordingAwaitingSpeechModel = true
            Task { await prepare() }
            primeCapturePermissions()
            return
        }

        recordingAwaitingSpeechModel = false
        sessionGeneration += 1
        state.status = "Requesting permissions…"

        let aecStage = startEchoHandling()
        wireCallbacks(aecStage: aecStage)
        state.markStarted()
        // The previous session's live state is about to be reused; select the
        // "Live" row so the dashboard follows the new recording.
        library.beginLiveSession()
        startInputDeviceHandling()

        do {
            await pipeline.start(appendingTo: state)
            // `pipeline.start` awaits the (re)load, so "not ready" here means
            // the model genuinely failed to load and this session's audio is
            // being dropped — surface it instead of pretending to transcribe.
            let transcriberReady = await pipeline.isReady
            state.markTranscriberUnavailable(!transcriberReady)
            try await startMicIfExpected()
            try await system.start()
            state.status = ""
            // Recording is the implicit request for this meeting's summary:
            // fetch the model's files during the session, after the speech
            // model is up (so on a fresh install Whisper's download — the one
            // that gates recording — never shares bandwidth with this one).
            prefetchSummaryModelIfNeeded()
        } catch {
            state.status = error.localizedDescription
            await stop(summarize: false)
        }
    }

    func stop() async {
        await stop(summarize: true)
    }

    /// Raises the microphone and system-audio permission prompts sequentially
    /// (one dialog at a time) so both are settled before the first real
    /// session. Denials are not handled here: the session start paths already
    /// surface them (`MicrophoneCapture.start` aborts the session; the system
    /// tap fails with its own error).
    private func primeCapturePermissions() {
        guard !capturePermissionsPrimed else { return }
        capturePermissionsPrimed = true
        Task {
            _ = await MicrophoneCapture.requestPermission()
            await SystemAudioCapture.primePermission()
        }
    }

    func retrySummary() async {
        guard !state.isRecording else { return }
        // The segments stay in `state.segments` until the next recording, and
        // `lastSavedMeetingID` still points at the meeting they were saved as, so
        // a successful retry attaches to that same meeting.
        await generateSummary(
            from: state.segments,
            sessionGeneration: sessionGeneration,
            meetingID: lastSavedMeetingID
        )
    }

    /// Explicit download from the dashboard's model controls (the same
    /// download runs implicitly on the first summary if the user never
    /// pressed a button). While idle it downloads AND loads, so "Ready" means
    /// the next summary starts instantly; while recording it fetches files
    /// only — the 12B load must never compete with live transcription.
    func downloadSummaryModel() async {
        guard !summaryModelState.isBusy else { return }
        do {
            let progress: @Sendable (String, Double) -> Void = { [weak self] phase, fraction in
                Task { @MainActor in self?.applySummaryModelProgress(phase, fraction) }
            }
            if state.isRecording {
                try await summaryModelManager.ensureDownloaded(progress: progress)
            } else {
                _ = try await summaryModelManager.ensureReady(progress: progress)
            }
            summaryModelState = .ready
            if !state.isRecording { state.updateStatus("") }
            // The model just became usable: meetings that were waiting for it
            // (the launch backfill skips everything while it isn't on disk)
            // can be processed right away instead of on the next launch.
            kickSummaryBackfill()
        } catch {
            summaryModelState = .failed(error.localizedDescription)
            if !state.isRecording { state.updateStatus("") }
        }
    }

    /// Fetches the summary model's files while a recording runs (download
    /// only — the 12B weights must never load into RAM while Whisper is
    /// transcribing live; the post-stop `ensureReady` does the load). Joins
    /// any in-flight download, so at most one transfer ever runs. A failure
    /// only paints the banner: the stop path and its own retry buttons own
    /// recovery, and the session itself is never disturbed.
    private func prefetchSummaryModelIfNeeded() {
        guard !summaryModelState.isBusy else { return }
        if case .ready = summaryModelState { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.summaryModelManager.ensureDownloaded { [weak self] phase, fraction in
                    Task { @MainActor in self?.applySummaryModelProgress(phase, fraction) }
                }
                self.summaryModelState = .ready
            } catch {
                self.summaryModelState = .failed(error.localizedDescription)
            }
        }
    }

    // MARK: - Summary backfill (catch-up for summary-less meetings)

    /// The meeting the backfill is currently summarizing, if any. The
    /// library list shows its row as "Processing" and its detail as generating.
    private(set) var backfillingMeetingID: UUID?

    /// Guards against overlapping backfill runs.
    private var isBackfillingSummaries = false

    /// Meetings whose backfill attempt failed (or was unreadable) this app
    /// run. They are skipped by later triggers — so a transcript the model
    /// chokes on can't burn a generation on every trigger — and retried on
    /// the next launch, when this set dies with the process.
    private var backfillFailedIDs: Set<UUID> = []

    /// A meeting the user explicitly asked to summarize (the past detail's
    /// "Generate summary" button): the next backfill iteration takes it
    /// before the newest-first scan. Survives until a run actually consumes
    /// it, so a request made while a generation is busy still lands.
    private var requestedSummaryID: UUID?

    /// User-initiated summary generation for one saved meeting. Clears the
    /// meeting's failed-this-run mark so the backfill genuinely retries it.
    func requestSummary(for id: UUID) {
        backfillFailedIDs.remove(id)
        requestedSummaryID = id
        kickSummaryBackfill()
    }

    /// Fire-and-forget entry point for every backfill trigger: launch, each
    /// recording stop, opening the dashboard window, and a completed model
    /// download. Deliberately detached from the caller's lifetime so closing
    /// the window can never cancel a generation halfway through a write.
    func kickSummaryBackfill() {
        Task { await backfillMissingSummaries() }
    }

    /// Summarizes saved meetings that have no summary yet — a quit during
    /// generation, an earlier failure, or an old unprocessed meeting (user
    /// decision 2026-07-17: every summary-less meeting qualifies, not only
    /// interrupted sessions). One meeting at a time, newest first; a
    /// recording starting aborts the run and the next trigger catches up.
    /// With no model on disk it does nothing — the backfill never triggers
    /// the multi-GB download on its own.
    private func backfillMissingSummaries() async {
        guard !isBackfillingSummaries else { return }
        isBackfillingSummaries = true
        defer {
            isBackfillingSummaries = false
            backfillingMeetingID = nil
        }

        // The library loads asynchronously at launch; an explicit (idempotent)
        // refresh guarantees `metas` is current before scanning.
        await library.refresh()
        guard await summaryModelManager.cachedModelExists() else { return }

        while !state.isRecording {
            // Never run alongside the just-stopped session's own generation —
            // the post-stop trigger re-checks the moment it finishes.
            switch state.summaryState {
            case .generating, .streaming: return
            default: break
            }

            // A user-requested meeting front-runs the newest-first scan;
            // consumed exactly once so the loop then resumes normal order.
            let requested = requestedSummaryID.flatMap { id in
                library.metas.first { $0.id == id && !$0.hasSummary }
            }
            requestedSummaryID = nil
            guard let meta = requested
                ?? library.metas.first(where: { !$0.hasSummary && !backfillFailedIDs.contains($0.id) })
            else { return }

            guard let record = await library.loadRecord(meta.id), !record.segments.isEmpty else {
                backfillFailedIDs.insert(meta.id)
                continue
            }
            backfillingMeetingID = meta.id

            do {
                let engine = try await summaryModelManager.ensureReady { [weak self] phase, fraction in
                    Task { @MainActor in self?.applySummaryModelProgress(phase, fraction) }
                }
                summaryModelState = .ready
                if !state.isRecording { state.updateStatus("") }
                guard !state.isRecording else { return }

                var latest: MeetingSummary?
                let stream = await summarizer.generate(from: record.segments, using: engine)
                for try await partial in stream {
                    // A recording started mid-generation: abandon this meeting
                    // (ending the loop cancels the generation task) so the LLM
                    // never competes with live transcription.
                    guard !state.isRecording else { return }
                    latest = partial
                }
                // Insurance against an externally cancelled run: a cut-short
                // stream must never persist a partial summary.
                guard !Task.isCancelled else { return }

                if let latest {
                    let description = await summarizer.oneLineDescription(for: latest, using: engine)
                    await library.attachSummary(latest, description: description, to: meta.id)
                    // A failed write (logged by the library) must not spin
                    // the loop — skip the meeting for the rest of this run.
                    if library.meta(for: meta.id)?.hasSummary != true {
                        backfillFailedIDs.insert(meta.id)
                    }
                } else {
                    Self.log.error("Summary backfill: empty summary for \(meta.id.uuidString, privacy: .public)")
                    backfillFailedIDs.insert(meta.id)
                }
            } catch {
                Self.log.error("""
                Summary backfill failed for \(meta.id.uuidString, privacy: .public): \
                \(error.localizedDescription, privacy: .public)
                """)
                // A model-level failure would fail every remaining meeting
                // too; the meeting itself is not at fault, so it stays
                // eligible for the next trigger.
                if error is SummaryModelError {
                    summaryModelState = .failed(error.localizedDescription)
                    return
                }
                backfillFailedIDs.insert(meta.id)
            }
            backfillingMeetingID = nil
        }
    }

    private func refreshSummaryModelState() async {
        if await summaryModelManager.cachedModelExists() {
            summaryModelState = .ready
        } else if let bytes = await summaryModelManager.partialDownloadBytes() {
            // A quit mid-download left resumable files behind: offer "Resume"
            // instead of a from-scratch "Download".
            summaryModelState = .partiallyDownloaded(bytesOnDisk: bytes)
        } else {
            summaryModelState = .notDownloaded
        }
    }

    private func applySummaryModelProgress(_ phase: String, _ fraction: Double) {
        if phase.hasPrefix("Loading") {
            summaryModelState = .loading
        } else {
            summaryModelState = .downloading(fraction)
        }
        // The popover's status line tells the same truth while idle. During a
        // recording it shows the live word count instead — the banner and the
        // model control carry the progress there.
        if !state.isRecording {
            let percent = Int(fraction * 100)
            state.updateStatus(phase.hasPrefix("Downloading") ? "\(phase) \(percent)%" : phase)
        }
    }

    private func stop(summarize: Bool) async {
        // First: no input-device event or in-flight restart may revive the
        // mic once teardown begins.
        await stopInputDeviceHandling()
        mic.stop()
        system.stop()
        stopEchoHandling()
        await pipeline.stop()
        // After the pipeline flush: the end-of-session chunks still classify
        // (their effects are dropped by the isRecording guard once
        // `markStopped` runs), and from here the tracker is inert until the
        // next session begins.
        inputHealth.endSession()
        let transcript = state.segments
        let generation = sessionGeneration
        // Capture before `markStopped` clears it — the meeting's real start.
        let startedAt = state.startedAt ?? Date()
        state.markStopped()

        guard summarize else { return }

        // Persist BEFORE the summary runs (SPEC-03 criterion 1): a crash in the
        // LLM must never lose the transcript. Empty transcripts are not saved.
        var meetingID: UUID?
        if !transcript.isEmpty {
            meetingID = await library.persist(segments: transcript, startedAt: startedAt, endedAt: Date())
        }
        lastSavedMeetingID = meetingID

        // Fire-and-forget: `stop()` returns once the meeting is persisted, so
        // the UI (the popover's Stop → dashboard hand-off in particular) never
        // sits blocked behind minutes of generation. The summary streams into
        // `state.summaryState` and the open detail follows it live.
        Task { [weak self] in
            guard let self else { return }
            await self.generateSummary(from: transcript, sessionGeneration: generation, meetingID: meetingID)
            // A stop is also a natural catch-up point: the model is warm, and
            // any meeting still missing its summary (one whose backfill was
            // aborted when this session began, or this very meeting if its
            // generation just failed) gets an attempt without waiting for a
            // relaunch.
            self.kickSummaryBackfill()
        }
    }

    private func generateSummary(
        from transcript: [TranscriptSegment],
        sessionGeneration generation: Int,
        meetingID: UUID?
    ) async {
        guard !transcript.isEmpty else {
            state.markSummaryUnavailable("No transcript was captured.")
            return
        }

        state.markSummaryGenerating()

        do {
            // First run downloads (~8.3 GB, once — resuming whatever the
            // recording-start prefetch already fetched) and loads the model;
            // later runs return the warm engine immediately. The progress
            // drives `summaryModelState`, which the detail's generating view
            // renders as the real phase — never "Generating…" over a download.
            let engine = try await summaryModelManager.ensureReady { [weak self] phase, fraction in
                Task { @MainActor in self?.applySummaryModelProgress(phase, fraction) }
            }
            summaryModelState = .ready
            guard generation == sessionGeneration, !state.isRecording else { return }
            // Re-assert now that the model phase is over: the status line
            // returns from download/load text to the honest "Generating…".
            state.markSummaryGenerating()

            var latest: MeetingSummary?
            // Long transcripts map-reduce; surface per-part progress on the
            // existing status line ("Summarizing part 3/7…"). Short ones emit none.
            let stream = await summarizer.generate(from: transcript, using: engine) { [weak self] phase in
                Task { @MainActor in self?.state.updateStatus(phase) }
            }
            for try await partial in stream {
                guard generation == sessionGeneration, !state.isRecording else { return }
                latest = partial
                state.markSummaryStreaming(partial)
            }

            guard generation == sessionGeneration, !state.isRecording else { return }
            if let latest {
                state.markSummaryReady(latest)
                // Persist the finished summary alongside its meeting (SPEC-03
                // criterion 2). A failure state is never persisted as a summary.
                // The AI one-line caption for the library row is generated from
                // the finished summary in the same step (best-effort — `nil` if
                // it fails, leaving the row without a caption).
                if let meetingID {
                    let description = await summarizer.oneLineDescription(for: latest, using: engine)
                    await library.attachSummary(latest, description: description, to: meetingID)
                }
            } else {
                state.markSummaryUnavailable("Gemma returned an empty summary.")
            }
        } catch {
            if error is SummaryModelError {
                summaryModelState = .failed(error.localizedDescription)
            }
            state.updateStatus("")
            guard generation == sessionGeneration, !state.isRecording else { return }
            state.markSummaryFailed(error.localizedDescription)
        }
    }

    // MARK: - Wiring

    private func wireCallbacks(aecStage: any AECStage) {
        // Capture `state`/`pipeline`/`aecStage` directly (not `self`) so these
        // real-time audio callbacks don't race on the controller's `self`
        // reference.
        let gapTracker = MicCaptureGapTracker()   // fresh per session: no stale episodes
        micGapTracker = gapTracker
        // Fresh input-health evidence per session, tagged with this
        // session's generation: no sustained-discard episode (or notice
        // bookkeeping) ever crosses a session boundary.
        inputHealth.beginSession(generation: sessionGeneration)
        mic.onLevel = { [state] level in
            Task { @MainActor in state.pushInput(level) }
        }
        mic.onSamples = { [pipeline] frames in
            // Every batch feeds the gap tracker at arrival; the first one
            // after a mic outage closes the episode and carries the measured
            // gap.
            let gap = gapTracker.noteDelivery(
                batchDuration: Double(frames.count) / AudioConstants.sampleRate
            )
            let cleaned = aecStage.processMicSamples(frames)
            // Gap and audio go to the pipeline in one task so the clock
            // realignment always lands immediately before the first post-gap
            // samples, never after them.
            Task {
                if let gap { await pipeline.noteCaptureGap(seconds: gap, on: .microphone) }
                await pipeline.ingest(cleaned, from: .microphone)
            }
        }
        system.onLevel = { [state] level in
            Task { @MainActor in state.pushOutput(level) }
        }
        system.onSamples = { [pipeline] frames in
            // Read-only fan-out (ADR-002): the far end gets a value copy; the
            // Team ingest path below must stay byte-identical to today.
            aecStage.feedFarEnd(frames)
            Task { await pipeline.ingest(frames, from: .system) }
        }
    }

    // MARK: - Echo handling (SP-001)

    /// Builds the session's mode machine and AEC stage and returns the stage
    /// for the capture callbacks to run.
    private func startEchoHandling() -> any AECStage {
        var machine = EchoModeMachine(initialRoute: routeMonitor.currentRoute())

        // A fresh engine per session: no adaptation state leaks across
        // recordings, and an init failure only degrades this session.
        let engine = WebRTCAECStage()
        let generation = sessionGeneration
        engine.onEngineEvent = { [weak self] healthy in
            // May arrive on either capture thread; the machine and the notice
            // live on the main actor. The generation guard drops any late
            // event from an engine of a previous session.
            Task { @MainActor [weak self] in
                guard let self, self.sessionGeneration == generation else { return }
                self.handleEngineEvent(healthy: healthy)
            }
        }

        // SP-001 US-8: an engine that never comes up must not block the
        // session — it starts on the degraded path (raw mic + dedup) instead.
        if machine.mode == .cancelling, !engine.isHealthy,
           let effect = machine.handle(.engineFailed) {
            state.applyEchoHandlingEffect(effect)
        }

        Self.log.info("Echo-handling mode: \(machine.mode.rawValue, privacy: .public)")
        let stage = SwitchingAECStage(engineStage: engine, mode: machine.mode)
        echoMode = machine
        switchingStage = stage
        routeMonitor.onRouteChange = { [weak self] route in
            self?.handleRouteChange(route)
        }
        routeMonitor.start()
        return stage
    }

    private func stopEchoHandling() {
        routeMonitor.stop()
        routeMonitor.onRouteChange = nil
        switchingStage?.reset()
        switchingStage = nil
        echoMode = nil
    }

    private func handleRouteChange(_ route: OutputRouteClass) {
        guard var machine = echoMode else { return }
        let previous = machine.mode
        let effect = machine.handle(.routeChanged(route))
        echoMode = machine

        if machine.mode != previous {
            Self.log.info("""
            Echo-handling mode: \(previous.rawValue, privacy: .public) → \
            \(machine.mode.rawValue, privacy: .public)
            """)
            switchingStage?.setMode(machine.mode)
            // SP-001: on any route change the canceller resets and re-converges.
            switchingStage?.reset()
        }
        if let effect {
            state.applyEchoHandlingEffect(effect)
        }
    }

    private func handleEngineEvent(healthy: Bool) {
        guard var machine = echoMode else { return }
        let previous = machine.mode
        let effect = machine.handle(healthy ? .engineRecovered : .engineFailed)
        echoMode = machine

        if machine.mode != previous {
            Self.log.info("""
            Echo-handling mode: \(previous.rawValue, privacy: .public) → \
            \(machine.mode.rawValue, privacy: .public) (engine \
            \(healthy ? "recovered" : "failed", privacy: .public))
            """)
            // No reset here: Cancelling ↔ Degraded keeps the engine fed, and
            // recovery means it is already processing frames successfully.
            switchingStage?.setMode(machine.mode)
        }
        if let effect {
            state.applyEchoHandlingEffect(effect)
        }
    }

    // MARK: - Input-device handling (SP-002)

    /// Builds the session's input-device machine and starts following the
    /// default input. Never touches the system/Team capture path: the
    /// machine's actions can only restart/stop the mic, reset echo
    /// processing, and drive the mic-unavailable notice.
    private func startInputDeviceHandling() {
        var machine = InputDeviceLifecycleMachine()
        let actions = machine.handle(.recordingStarted(device: inputMonitor.currentDefaultInputDevice()))
        inputLifecycle = machine
        inputMonitor.onDefaultInputChange = { [weak self] device in
            self?.handleInputLifecycleEvent(.defaultInputChanged(device))
        }
        inputMonitor.start()
        apply(inputActions: actions)
    }

    private func stopInputDeviceHandling() async {
        inputMonitor.stop()
        inputMonitor.onDefaultInputChange = nil
        micRestartTask?.cancel()
        // Wait out any in-flight rebuild so nothing races the session teardown.
        _ = await micRestartTask?.value
        micRestartTask = nil
        if var machine = inputLifecycle {
            apply(inputActions: machine.handle(.recordingStopped))
        }
        inputLifecycle = nil
    }

    /// Starts mic capture unless the session already degraded to Team-only
    /// (no input device at start). A no-device failure degrades the session
    /// instead of ending it (SP-002 Reliability); permission denial still
    /// aborts the session exactly as before.
    private func startMicIfExpected() async throws {
        guard inputLifecycle?.expectsMicCapture == true else {
            // Team-only start: the mic channel is silent from the session's
            // first moment. Open the gap episode now so a device appearing
            // later realigns the mic clock over the whole silent stretch.
            micGapTracker?.beginEpisode()
            return
        }
        do {
            try await mic.start()
        } catch MicrophoneCapture.CaptureError.noInputDevice {
            // The device vanished between the monitor read and engine start.
            handleInputLifecycleEvent(.micCaptureFailed)
        }
    }

    private func handleInputLifecycleEvent(_ event: InputDeviceLifecycleMachine.Event) {
        guard var machine = inputLifecycle else { return }
        let actions = machine.handle(event)
        inputLifecycle = machine
        guard !actions.isEmpty else { return }

        Self.log.info("""
        Input-device event: \(String(describing: event), privacy: .public) → \
        \(String(describing: actions), privacy: .public)
        """)
        apply(inputActions: actions)
    }

    private func apply(inputActions actions: [InputDeviceLifecycleMachine.Action]) {
        for action in actions {
            switch action {
            case .restartMicCapture:
                // New device, new input-health evidence: the lifecycle
                // machine emits this only on a real identity change, so the
                // classifier resets its mic episode (ADR-006 — a signal
                // *into* the observational classifier, never back out).
                inputHealth.noteMicDeviceChanged()
                scheduleMicRestart()
            case .resetEchoProcessing:
                // SP-002 inherits SP-001's discipline: on every input-device
                // change the canceller drops its adaptation state and
                // re-converges on the new device.
                switchingStage?.reset()
            case .stopMicCapture:
                // Losing the device is a device change for input health too:
                // stale sustained-discard evidence must not outlive the
                // device it was gathered against, and S4's mic-unavailable
                // notice (raised below) must not sit above a stale mic
                // health notice.
                inputHealth.noteMicDeviceChanged()
                // The mic goes down for an unbounded episode (device lost /
                // capture failed) while Team keeps running: open the gap
                // episode so the eventual recovery reports the full outage
                // to the pipeline clock.
                micGapTracker?.beginEpisode()
                mic.stop()
            case .showMicUnavailableNotice:
                state.applyInputDeviceNotice(InputDeviceNotice.micUnavailableMessage)
            case .clearMicUnavailableNotice:
                state.applyInputDeviceNotice(nil)
            }
        }
    }

    /// Rebuilds mic capture on the current default device. Runs as a task
    /// because the handler is synchronous; the synchronous `reset` in
    /// `apply(inputActions:)` therefore always lands before the new device's
    /// first frames. Restarts are chained so rapid device churn can never
    /// interleave two engine rebuilds.
    private func scheduleMicRestart() {
        let generation = sessionGeneration
        let previous = micRestartTask
        micRestartTask = Task { @MainActor [weak self] in
            _ = await previous?.value
            guard let self, !Task.isCancelled,
                  self.sessionGeneration == generation,
                  self.state.isRecording,
                  self.inputLifecycle?.expectsMicCapture == true
            else { return }

            // Teardown begins here — not at the device event: the old
            // engine keeps delivering until this stop, and the tracker's
            // last-delivery edge must stay fresh up to the real teardown.
            self.micGapTracker?.beginEpisode()
            self.mic.stop()
            do {
                try await self.mic.start()
                Self.log.info("Mic capture restarted on the new input device")
            } catch {
                Self.log.error("""
                Mic restart failed: \(error.localizedDescription, privacy: .public)
                """)
                self.handleInputLifecycleEvent(.micCaptureFailed)
            }
        }
    }
}
