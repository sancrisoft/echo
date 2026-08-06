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
    // Per-session, scoped sessions only (SP-008, ADR-025): the second tap of
    // the dual topology — a *global* tap that feeds the echo canceller's
    // far-end reference and nothing else, so the canceller keeps hearing
    // everything the speakers play while `system` records only the scoped
    // app. `nil` for global sessions (today's single tap serves both
    // consumers) and after every stop.
    private var referenceTap: SystemAudioCapture?
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
    // Per-session (built in `start`): retains the session's pipeline-ingested
    // audio for the post-stop final re-transcription pass (SP-005, ADR-013).
    // Subordinate to recording: it disables itself on failure and nothing in
    // the capture path ever awaits its health.
    private var retainedWriter: RetainedAudioWriter?
    private let summarizer = SummarizationPipeline()
    private let summaryModelManager = SummaryModelManager()
    /// SP-005 S5 (ADR-015): the optional final-pass model's tier/download/
    /// completeness lifecycle. Never consulted by recording readiness.
    private let finalPassModelManager = FinalPassModelManager()
    /// SP-005 S4 (ADR-014/ADR-016): owns finalization admission — one pass at
    /// a time, never while recording or during summary work, bounded retries,
    /// launch-time resume. The UI reads its queue/current state (S6).
    let finalization = FinalizationCoordinator()
    private var sessionGeneration = 0
    /// Dashboard-facing lifecycle of the summary model (download/load/ready).
    /// Owned here so the UI never talks to the manager actor directly.
    private(set) var summaryModelState: SummaryModelState = .notDownloaded
    /// Same for the speech model — fed by the pipeline's phase handler. Starts
    /// as `.loading` because `prepare()` kicks the (cache-first) load at init.
    private(set) var speechModelState: SpeechModelState = .loading
    /// And for the optional final-pass model (SP-005 S6, story 16) — fed by
    /// the manager's state handler, which reflects the real tier/disk state
    /// the moment it is wired in `init`. The dashboard hides the row entirely
    /// on the `.notNeeded` tier and while nothing needs attention.
    private(set) var finalPassModelState: FinalPassModelState = .notNeeded(.reuseLive)

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

    /// One-shot request (set on every record press blocked by a not-ready
    /// speech model) for the dashboard to raise the explanatory "can't record
    /// yet" dialog. Distinct from the sticky flag above — that one drives the
    /// persistent progress banner and stays set, so it can't re-trigger the
    /// modal on a repeat press. Consumed and cleared by `DashboardView`; the
    /// dashboard is the stable host (a menu-bar popover would dismiss the
    /// alert as it closes), so the menu bar routes here by opening the window.
    var pendingSpeechModelGateNotice = false

    /// The gate callout's dismiss. The download itself keeps running — only
    /// the "you pressed record too early" framing goes away.
    func dismissSpeechModelGate() { recordingAwaitingSpeechModel = false }

    /// One-shot per app run: the record gesture primes both capture-permission
    /// prompts exactly once, ahead of the readiness check (ADR-009).
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

        // SP-005 S4: the coordinator's work is injected here (it owns WHEN a
        // pass runs; the controller owns HOW). `prepareForPass` releases any
        // idle-warm summary model so it is never resident while a pass
        // decodes; a concluded resumed pass kicks the backfill for its
        // summary.
        finalization.runPass = { [weak self] meetingID, shouldYield in
            guard let self else { return .failed }
            return await self.performFinalizationPass(for: meetingID, shouldYield: shouldYield)
        }
        finalization.prepareForPass = { [summaryModelManager] in
            await summaryModelManager.unload()
        }
        // Terminal convergence (ADR-024): ONE atomic act — record liveFloor
        // provenance on the meeting's meta. The retained audio is KEPT for
        // the manual Retry, and the single write is the crash safety: a
        // crash BEFORE it re-enters pending on the next launch and simply
        // converges again; after it, the scan reads the draft.
        finalization.convergeTerminally = { [weak self] meetingID in
            guard let self else { return }
            await self.library.recordLiveFloorProvenance(
                for: meetingID,
                provenance: Self.liveFloorProvenance()
            )
        }
        finalization.onPassConcluded = { [weak self] meetingID in
            guard let self else { return }
            // A deferred or launch-resumed pass may just have replaced the
            // transcript of the meeting whose segments are still the live
            // in-memory state (a just-stopped meeting whose pass was
            // preempted): re-read from disk so an open detail — and a later
            // retrySummary — shows the final transcript (SP-005 S6).
            self.refreshLiveSegments(for: meetingID)
            self.kickSummaryBackfill()
        }

        // Under a test host every launch side effect below is skipped (see
        // `TestHost`): the hosted app must not load models, download
        // anything, sweep staging dirs, resume finalizations or backfill
        // summaries against the REAL store — a test run doing so raced a
        // concurrently recording Echo instance and destroyed a meeting.
        // Everything above (handler wiring, pure setup) stays: it is inert
        // without these tasks, and tests drive their own instances.
        guard !TestHost.isActive else { return }

        // Warm up the speech model at launch so pressing record is instant,
        // then resume finalizations a quit or crash interrupted (SP-005 S4 —
        // the passes themselves queue behind the coordinator's admission),
        // then eagerly fetch the summary model — chained AFTER the speech
        // preload so a fresh install's bandwidth goes to the record-gating
        // speech download first and the two never co-saturate the link (OQ6).
        // The optional final-pass model (ADR-015) fetches LAST — behind the
        // record-gating speech download and the summary model — and defers
        // while a recording is active or a pass is running/pending (ADR-014:
        // the 947 MB transfer never competes with a pass either). It never
        // gates recording (ADR-009).
        Task {
            // Wire the final-pass model's dashboard row first (cheap): the
            // handler reflects the manager's current state immediately, so
            // the row never sits on the placeholder default.
            await finalPassModelManager.setStateHandler { [weak self] state in
                Task { @MainActor in self?.finalPassModelState = state }
            }
            await prepare()
            await resumePendingFinalizations()
            await startEagerSummaryDownloadIfNeeded()
            await finalPassModelManager.initialize(deferWhile: { @MainActor [weak self] in
                guard let self else { return false }
                return self.isRecording || self.finalization.isBusy
            })
        }
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

    /// Starts a session with the given system-channel coverage (SP-008).
    /// `.everything` is today's session, byte-for-byte; `.app` runs the
    /// ADR-025 dual-tap topology, collapsing to a global session if scoped
    /// establishment fails at start (ADR-027). The *effective* scope is fixed
    /// by the end of this method and published on `state.captureScope`.
    func start(scope requestedScope: CaptureScope = .everything) async {
        guard !state.isRecording else { return }

        // Permissions are a gesture effect, not a download-wait effect
        // (ADR-009): raise the mic + system-audio prompts here — before the
        // readiness check and awaited — so the OS dialogs are tied to the
        // user's intent to record, never to a background download, and settle
        // before either the gate message or real capture. Once per run
        // (guarded). A brand-new user with no speech model yet sees the prompts
        // and then the "can't record yet" gate — the accepted order (OQ5).
        await primeCapturePermissions()

        // Recording readiness is "the speech model is LOADED and transcribing-
        // capable", not merely present on disk (ADR-009). Gate on the observed
        // lifecycle: still downloading, still loading, or a failed download/load
        // must NOT enter a recording state. The old `needsModelDownload` gate
        // (absent-only) let the loading and load-failed cases slip straight to
        // `markStarted`, flipping `isRecording` before (or despite) the load
        // resolving — the hole this closes. Reading `speechModelState`
        // synchronously is authoritative: it becomes `.ready` only after the
        // pipeline reports the load finished, and the speech model never
        // unloads once ready.
        switch RecordingGateDecision.decide(speechModelState) {
        case .blocked(let message):
            // Don't start: surface the sub-state-accurate callout on the
            // dashboard (the menu bar routes here off this same flag) and make
            // sure the download/load is running. `prepare()` is idempotent and
            // also retries a failed load, so a record press on a failed model
            // IS the retry gesture. No `markStarted` — the record button must
            // not lie on any surface.
            Self.log.info("Record gesture blocked — speech model not ready: \(message, privacy: .public)")
            recordingAwaitingSpeechModel = true
            // Fire the one-shot so the dashboard raises the dialog on THIS press
            // (the sticky flag above already being set can't re-trigger it).
            pendingSpeechModelGateNotice = true
            Task { await prepare() }
            return
        case .record:
            recordingAwaitingSpeechModel = false
        }

        sessionGeneration += 1
        // Recording preempts all post-meeting model work (ADR-014): a running
        // pass sees this signal at its next decode-window check and yields;
        // no new pass or summary sequencing starts until stop. Signalled
        // before any capture setup so the yield begins immediately, and
        // always balanced — every path out of a started session goes through
        // `stop(summarize:)`, which signals the stop.
        finalization.noteRecordingStarted()
        state.status = "Requesting permissions…"

        // SP-005 (ADR-013): retain this session's ingested audio for the
        // post-stop final pass. Staged under a hidden sibling of the meeting
        // folders (same volume, so adoption at stop is a rename) — the
        // meeting folder itself doesn't exist until the live transcript
        // persists, and retained audio may only appear there after the floor
        // does (ADR-016).
        retainedWriter = RetainedAudioWriter(
            directory: EchoPaths.meetingsDirectory
                .appending(path: MeetingStore.retentionStagingDirectoryName, directoryHint: .isDirectory)
                .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        )

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
            let effectiveScope = try await startSystemCapture(
                requestedScope: requestedScope,
                aecStage: aecStage
            )
            // Fixed for the whole session (ADR-027: a running session never
            // silently widens) — the one value every surface renders and the
            // stop path persists onto the meeting's meta.
            state.setCaptureScope(effectiveScope)
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
    /// (one dialog at a time) and awaits them, so both are settled before the
    /// gate check and any real capture — no permission probe ever races a live
    /// capture session. Denials are not handled here: the session start paths
    /// already surface them (`MicrophoneCapture.start` aborts the session; the
    /// system tap fails with its own error).
    private func primeCapturePermissions() async {
        guard !capturePermissionsPrimed else { return }
        capturePermissionsPrimed = true
        _ = await MicrophoneCapture.requestPermission()
        await SystemAudioCapture.primePermission()
    }

    func retrySummary() async {
        guard !state.isRecording else { return }
        // Ground the retry in the PERSISTED transcript when the meeting saved:
        // the final pass may have replaced the on-disk segments since the
        // in-memory ones were captured (SP-005 S6), and a summary must never
        // be grounded in words the disk no longer holds. A session that never
        // persisted (no meeting folder) falls back to the in-memory segments,
        // exactly as before. `lastSavedMeetingID` still points at the meeting,
        // so a successful retry attaches to that same meeting.
        var transcript = state.segments
        if let id = lastSavedMeetingID, let record = await library.loadRecord(id) {
            transcript = record.segments
        }
        await generateSummary(
            from: transcript,
            sessionGeneration: sessionGeneration,
            meetingID: lastSavedMeetingID
        )
    }

    /// Reloads `state.segments` from disk when `meetingID` is the meeting the
    /// live in-memory state still mirrors (SP-005 S6 swap-in). A no-op for any
    /// other meeting and during a recording — a live session owns its segments
    /// (`replaceSegments` re-checks after the load's suspension too).
    private func refreshLiveSegments(for meetingID: UUID) {
        guard meetingID == lastSavedMeetingID, !state.isRecording else { return }
        Task { [weak self] in
            guard let self else { return }
            guard let record = await self.library.loadRecord(meetingID) else { return }
            self.state.replaceSegments(record.segments)
        }
    }

    /// Explicit download from the dashboard's model controls (the same download
    /// runs implicitly on the first summary if the user never pressed a button).
    /// Download only — NEVER load: pulling the 4B into RAM merely because the
    /// user pressed "Download" is the ~3 GB "doing nothing" bug (ADR-008). The
    /// weights come into memory only for active summary work and are released
    /// after a short idle period, so here "Ready" means "snapshot on disk" and
    /// the first summary pays the load.
    func downloadSummaryModel() async {
        guard !summaryModelState.isBusy else { return }
        do {
            try await summaryModelManager.ensureDownloaded { [weak self] phase, fraction in
                Task { @MainActor in self?.applySummaryModelProgress(phase, fraction) }
            }
            summaryModelState = .ready
            if !state.isRecording { state.updateStatus("") }
            // The model just became usable: meetings that were waiting for it
            // (the launch backfill skips everything while it isn't on disk)
            // can be processed right away instead of on the next launch.
            kickSummaryBackfill()
        } catch {
            await applyDownloadFailureOrPause(error)
        }
    }

    /// Pauses the background summary-model download (SP-003 US-10). Records the
    /// intent (persisted, so the eager download won't silently resume it now or
    /// on the next launch) and cancels the in-flight transfer; completed shards
    /// stay on disk. Only meaningful while actively downloading — a pause is not
    /// a failure, so the state lands on `.paused`, never `.failed`.
    func pauseSummaryDownload() async {
        guard case .downloading = summaryModelState else { return }
        await summaryModelManager.pauseDownload()
        summaryModelState = .paused
        if !state.isRecording { state.updateStatus("") }
    }

    /// Resumes a paused summary-model download (SP-003 US-10): clears the paused
    /// intent, then re-runs the single shared download, which skips whatever is
    /// already complete on disk (no re-fetch of finished shards) and lands back
    /// in `.downloading` → `.ready`.
    func resumeSummaryDownload() async {
        await summaryModelManager.resumeDownload()
        await downloadSummaryModel()
    }

    /// Routes a download-path error to the honest state: a pause cancelled the
    /// transfer (`isDownloadPaused` was set before the cancel) → `.paused`, never
    /// `.failed`; anything else is a real download failure (SP-003: cancel ≠
    /// failure).
    private func applyDownloadFailureOrPause(_ error: Error) async {
        if await summaryModelManager.isDownloadPaused {
            summaryModelState = .paused
        } else {
            summaryModelState = .failed(error.localizedDescription)
        }
        if !state.isRecording { state.updateStatus("") }
    }

    /// Fetches the summary model's files while a recording runs (download
    /// only — the 4B weights must never load into RAM while Whisper is
    /// transcribing live; the post-stop `ensureReady` does the load). Joins
    /// any in-flight download, so at most one transfer ever runs. A failure
    /// only paints the banner: the stop path and its own retry buttons own
    /// recovery, and the session itself is never disturbed.
    private func prefetchSummaryModelIfNeeded() {
        guard !summaryModelState.isBusy else { return }
        if case .ready = summaryModelState { return }
        Task { [weak self] in
            guard let self else { return }
            // Respect a user pause: the record-start prefetch is a background
            // fetch (SP-003 US-10), so it leaves a paused download alone. The
            // post-stop summary's own load still fetches what it needs.
            if await self.summaryModelManager.isDownloadPaused {
                self.summaryModelState = .paused
                return
            }
            do {
                try await self.summaryModelManager.ensureDownloaded { [weak self] phase, fraction in
                    Task { @MainActor in self?.applySummaryModelProgress(phase, fraction) }
                }
                self.summaryModelState = .ready
            } catch {
                await self.applyDownloadFailureOrPause(error)
            }
        }
    }

    /// Eagerly downloads the summary model on first launch, sequenced BEHIND the
    /// speech-model preload (`init` chains this after `prepare()` returns): on a
    /// fresh install the ~626 MB speech download — the one that gates recording —
    /// wins the bandwidth first and never co-saturates the link with this ~3.3 GB
    /// one (OQ6 resolved; SP-003 "Speech-model download has priority"). Download
    /// only, never loads (ADR-008); a no-op once the snapshot is on disk or a
    /// transfer is already in flight (the manager dedups to one download, and an
    /// explicit Dashboard download or record-start prefetch may have started
    /// first). Because it resumes on the next launch, it is also what makes a
    /// queued summary's "auto-generate once ready" durable across a quit — once
    /// the files land, the backfill runs.
    private func startEagerSummaryDownloadIfNeeded() async {
        guard !summaryModelState.isBusy else { return }
        if case .ready = summaryModelState { return }
        // A pause the user set (this run or a previous one — the intent is
        // persisted) must survive the launch: don't auto-resume it (SP-003
        // US-10). Reflect it so the dashboard offers Resume, not Download.
        if await summaryModelManager.isDownloadPaused {
            summaryModelState = .paused
            return
        }
        do {
            try await summaryModelManager.ensureDownloaded { [weak self] phase, fraction in
                Task { @MainActor in self?.applySummaryModelProgress(phase, fraction) }
            }
            summaryModelState = .ready
            if !state.isRecording { state.updateStatus("") }
            // The files are now on disk: a summary queued behind the download
            // (or an older summary-less meeting) can be generated now instead
            // of on the next launch.
            kickSummaryBackfill()
        } catch {
            await applyDownloadFailureOrPause(error)
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

            // A meeting pending finalization is not summary-eligible (SP-005,
            // ADR-016): its transcript is about to be replaced, so a summary
            // now would be grounded in the wrong words. It becomes eligible
            // when its pass concludes — success OR terminal failure — and the
            // coordinator kicks this backfill at that moment. Re-read per
            // iteration: the marker is on-disk state a concluding pass clears.
            let pending = Set(await library.pendingFinalizationMeetingIDs())

            // A user-requested meeting front-runs the newest-first scan;
            // consumed exactly once so the loop then resumes normal order.
            let requested = requestedSummaryID.flatMap { id in
                library.metas.first { $0.id == id && !$0.hasSummary && !pending.contains(id) }
            }
            requestedSummaryID = nil
            guard let meta = requested
                ?? library.metas.first(where: {
                    !$0.hasSummary && !backfillFailedIDs.contains($0.id) && !pending.contains($0.id)
                })
            else { return }

            guard let record = await library.loadRecord(meta.id), !record.segments.isEmpty else {
                backfillFailedIDs.insert(meta.id)
                continue
            }
            backfillingMeetingID = meta.id

            do {
                // Route the generation through the work scope so the model is
                // released only after backfill goes idle (ADR-008). The engine
                // work returns whether the whole backfill should stop (a
                // recording started, or the task was cancelled) — the same
                // early-exit conditions that used to `return` from this function
                // directly; the scope releases the engine on the way out.
                let shouldStop = try await withSummaryEngine(progress: { [weak self] phase, fraction in
                    Task { @MainActor in self?.applySummaryModelProgress(phase, fraction) }
                }) { engine -> Bool in
                    summaryModelState = .ready
                    if !state.isRecording { state.updateStatus("") }
                    guard !state.isRecording else { return true }

                    var latest: MeetingSummary?
                    let stream = await summarizer.generate(from: record.segments, using: engine)
                    for try await partial in stream {
                        // A recording started mid-generation: abandon this meeting
                        // (ending the loop cancels the generation task) so the LLM
                        // never competes with live transcription.
                        guard !state.isRecording else { return true }
                        latest = partial
                    }
                    // Insurance against an externally cancelled run: a cut-short
                    // stream must never persist a partial summary.
                    guard !Task.isCancelled else { return true }

                    if let latest {
                        let description = await summarizer.oneLineDescription(for: latest, using: engine)
                        await library.attachSummary(
                            latest,
                            description: description,
                            modelName: SummaryModelManager.modelID,
                            to: meta.id
                        )
                        // A failed write (logged by the library) must not spin
                        // the loop — skip the meeting for the rest of this run.
                        if library.meta(for: meta.id)?.hasSummary != true {
                            backfillFailedIDs.insert(meta.id)
                        }
                    } else {
                        ErrorTrace.record(
                            "Summary backfill produced an empty summary",
                            category: "RecordingController",
                            metadata: ["meetingID": meta.id.uuidString]
                        )
                        backfillFailedIDs.insert(meta.id)
                    }
                    return false
                }
                if shouldStop { return }
            } catch {
                ErrorTrace.record(
                    "Summary backfill failed",
                    error: error,
                    category: "RecordingController",
                    metadata: ["meetingID": meta.id.uuidString]
                )
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
        } else if await summaryModelManager.isDownloadPaused {
            // The user paused in a previous run: the persisted intent wins over
            // the crash-interrupted heuristic below, so we offer "Resume" and
            // the eager launch download leaves it alone (SP-003 US-10).
            summaryModelState = .paused
        } else if await summaryModelManager.partialDownloadBytes() != nil {
            // A quit mid-download left resumable files behind: offer "Resume"
            // instead of a from-scratch "Download". Only the existence of a
            // partial matters here — its byte count is untrustworthy for
            // display (ADR-007), so the state carries none.
            summaryModelState = .partiallyDownloaded
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
        // model control carry the progress there. The percent goes through the
        // clamped projection so this line (and the menu bar that mirrors it)
        // can never print past 100% (ADR-007).
        if !state.isRecording {
            let percent = ModelDownloadProgress(fraction: fraction).percent
            state.updateStatus(phase.hasPrefix("Downloading") ? "\(phase) \(percent)%" : phase)
        }
    }

    private func stop(summarize: Bool) async {
        // Take the session's retention writer: callbacks hold their own
        // reference, and the finalization task below owns it from here.
        let writer = retainedWriter
        retainedWriter = nil
        // First: no input-device event or in-flight restart may revive the
        // mic once teardown begins.
        await stopInputDeviceHandling()
        mic.stop()
        system.stop()
        // A scoped session's second tap (ADR-025) dies with the session; a
        // global session has none and this is a no-op.
        referenceTap?.stop()
        referenceTap = nil
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
        // Likewise the session's effective scope (SP-008, ADR-027): fixed at
        // start, persisted below onto the meeting's meta. `nil` only for a
        // session that aborted before system capture came up — which never
        // persists a meeting anyway.
        let captureScope = state.captureScope
        state.markStopped()
        // The post-stop pipeline (this meeting's pass → its summary) opens
        // here; deferred passes stay held until it closes (ADR-014). Every
        // path below balances it with one `notePostStopWorkFinished()`.
        finalization.noteRecordingStopped()

        guard summarize else {
            // An aborted session start: nothing persists, so the staged
            // retention has no meeting to belong to.
            if let writer { Task { await writer.discard() } }
            finalization.notePostStopWorkFinished()
            return
        }

        // Persist BEFORE the summary runs (SPEC-03 criterion 1): a crash in the
        // LLM must never lose the transcript. Empty transcripts are not saved.
        var meetingID: UUID?
        if !transcript.isEmpty {
            meetingID = await library.persist(
                segments: transcript,
                startedAt: startedAt,
                endedAt: Date(),
                captureScope: captureScope.map(CaptureScopeRecord.init(scope:))
            )
        }
        lastSavedMeetingID = meetingID

        // Fire-and-forget: `stop()` returns once the meeting is persisted, so
        // the UI (the popover's Stop → dashboard hand-off in particular) never
        // sits blocked behind minutes of generation. The summary streams into
        // `state.summaryState` and the open detail follows it live.
        Task { [weak self] in
            guard let self else { return }
            // SP-005 post-stop sequence (ADR-014, serial by dependency): the
            // final pass runs first, on the speech model alone, and only then
            // may summary work begin — grounded in the final transcript when
            // the pass succeeded, in the live floor when it terminally
            // couldn't (ADR-016).
            var summaryInput = transcript
            if let meetingID, let writer {
                switch await self.runFinalizationPass(for: meetingID, writer: writer) {
                case .replaced(let final):
                    summaryInput = final
                    // SP-005 S6 swap-in: an open detail of this just-stopped
                    // meeting renders the in-memory live segments — surface
                    // the final set that now exists on disk. Generation-
                    // guarded: a session that started meanwhile owns
                    // `state.segments` (and `replaceSegments` re-checks
                    // `isRecording` itself).
                    if generation == self.sessionGeneration {
                        self.state.replaceSegments(final)
                    }
                case .floorStands, nil:
                    break   // the live floor stands — the summary grounds in it
                case .deferred:
                    // A new recording preempted the pass: the meeting stays
                    // pending (backfill-excluded), its pass resumes after
                    // that recording stops, and the summary follows THAT
                    // pass's conclusion. This pipeline is done.
                    self.finalization.notePostStopWorkFinished()
                    return
                }
            } else if let writer {
                // The meeting never persisted — retention has nothing to
                // finalize against.
                await writer.discard()
            }
            await self.generateSummary(from: summaryInput, sessionGeneration: generation, meetingID: meetingID)
            self.finalization.notePostStopWorkFinished()
            // A stop is also a natural catch-up point: the model is warm, and
            // any meeting still missing its summary (one whose backfill was
            // aborted when this session began, or this very meeting if its
            // generation just failed) gets an attempt without waiting for a
            // relaunch.
            self.kickSummaryBackfill()
        }
    }

    // MARK: - Final re-transcription pass (SP-005 S1/S4)

    /// The stop path's finalization: stage → adopt (arming the ADR-016
    /// pending marker) → hand the meeting to the coordinator, which runs the
    /// pass under the admission rule (ADR-014) with bounded retries
    /// (ADR-016). Returns the awaited outcome, or `nil` when no pass could be
    /// armed for this meeting (retention disabled mid-session, nothing
    /// captured, or adoption failed) — the live transcript stands either way.
    private func runFinalizationPass(
        for meetingID: UUID,
        writer: RetainedAudioWriter
    ) async -> FinalizationCoordinator.StopOutcome? {
        let staged = await writer.finish()
        guard !staged.isEmpty else {
            // Retention was disabled mid-session (or nothing was captured):
            // no final pass for this meeting, the live transcript stands.
            // That outcome is known and permanent — record it (ADR-022: a
            // meeting whose retention never armed records liveFloor).
            await writer.discard()
            await library.recordLiveFloorProvenance(for: meetingID, provenance: Self.liveFloorProvenance())
            return nil
        }
        guard await library.adoptRetainedAudio(staged, for: meetingID) != nil else {
            await writer.discard()
            await library.recordLiveFloorProvenance(for: meetingID, provenance: Self.liveFloorProvenance())
            return nil
        }
        // The staged files just moved out; drop the empty staging folder.
        await writer.discard()
        return await finalization.finalizeStopped(meetingID)
    }

    /// The provenance of a meeting that keeps its live transcript: produced by
    /// the live turbo checkpoint, on this machine's tier, no fallback involved
    /// (whether retention never armed or a pass cycle terminally converged,
    /// no pass output ever landed — the persisted words are the live model's,
    /// and the floor tier reusing it is by design).
    private static func liveFloorProvenance() -> TranscriptProvenance {
        TranscriptProvenance(
            source: .liveFloor,
            modelName: TranscriptionPipeline.modelVariant,
            tier: FinalPassTier.current.rawValue,
            servedByFallback: false
        )
    }

    /// One pass attempt — the mechanics the coordinator's `runPass` seam
    /// invokes (the coordinator owns WHEN; this owns HOW): read the retained
    /// files (the audio is the checkpoint, so a launch-resumed attempt needs
    /// nothing else), window-decode on the tiered model, atomically replace
    /// the transcript, and delete exactly this meeting's retained files on
    /// success. Any failure leaves the live transcript byte-identical and the
    /// retained audio in place (the coordinator decides retry vs terminal).
    private func performFinalizationPass(
        for meetingID: UUID,
        shouldYield: @escaping @Sendable () -> Bool
    ) async -> FinalizationCoordinator.PassResult {
        let retained = await library.retainedAudioFiles(for: meetingID)
        guard !retained.isEmpty else {
            // The pending marker vanished under us (meeting deleted, or a
            // cleanup raced) — nothing to finalize.
            Self.log.error("Final pass found no retained audio for \(meetingID.uuidString, privacy: .public)")
            return .failed
        }
        // A local so the success path can read back which model actually
        // served the pass (`lastServed`) for the provenance record (ADR-022).
        let provider = TieredFinalPassModelProvider(
            manager: finalPassModelManager,
            fallback: LivePipelineModelProvider(pipeline: pipeline),
            onServed: { [weak self] choice in
                // Degraded-pass honesty (SP-005 S6): worth a caption
                // only when a full-tier machine fell back to the live
                // model — the floor tier reusing it is by design.
                let fallback = choice == .liveModel && FinalPassTier.current == .fullLargeV3
                Task { @MainActor [weak self] in
                    self?.finalization.noteServedModel(
                        isFallbackOnFullTier: fallback,
                        for: meetingID
                    )
                }
            }
        )
        do {
            let final = try await FinalizationPass.run(
                retainedFiles: retained,
                model: provider,
                shouldYield: shouldYield,
                onProgress: { [weak self] fraction in
                    // The single ADR-007 fraction, hopped to the main actor;
                    // the coordinator's forward-only guard absorbs any
                    // out-of-order Task delivery.
                    Task { @MainActor [weak self] in
                        self?.finalization.noteProgress(fraction, for: meetingID)
                    }
                }
            )
            // An empty `final` here is a legitimate success: `run` returns
            // empty only when the energy evidence itself says nobody spoke
            // (ADR-019 — speech regions with all segments dropped throws
            // `emptyDisciplinedOutput` and lands in `.failed` below).
            // Which checkpoint actually decoded this pass (ADR-022): the
            // provider recorded its per-lend choice. A silence-only pass may
            // never lend the model (`lastServed` nil) — it records the live
            // checkpoint name and NO fallback flag, because no degraded
            // decode happened.
            let served = await provider.lastServed
            let tier = FinalPassTier.current
            let provenance = TranscriptProvenance(
                source: .finalPass,
                modelName: served == .fullLargeV3
                    ? FinalPassModelManager.variant
                    : TranscriptionPipeline.modelVariant,
                tier: tier.rawValue,
                servedByFallback: served == .liveModel && tier == .fullLargeV3
            )
            guard await library.replaceTranscript(final, provenance: provenance, for: meetingID) else {
                return .failed
            }
            #if DEBUG
            // SP-007 keep flag (user story 12): preserve this meeting's audio
            // as a replayable fixture; the deletion below then finds nothing,
            // harmlessly. DEBUG-only and off by default (SP-007 Privacy).
            if ProcessInfo.processInfo.environment["ECHO_KEEP_RETAINED_AUDIO"] == "1" {
                await library.preserveRetainedAudioAsDebugFixture(for: meetingID)
            }
            #endif
            await library.deleteRetainedAudio(for: meetingID)
            Self.log.info("""
            Final pass succeeded for meeting \(meetingID.uuidString, privacy: .public): \
            \(final.count, privacy: .public) segments, retained audio deleted
            """)
            return .replaced(final)
        } catch FinalizationPass.PassError.preempted {
            Self.log.info("""
            Final pass deferred for meeting \(meetingID.uuidString, privacy: .public) — \
            a recording started (resumes after stop)
            """)
            return .preempted
        } catch {
            Self.log.error("""
            Final pass failed for meeting \(meetingID.uuidString, privacy: .public) — \
            live transcript stands, retained audio kept: \
            \(error.localizedDescription, privacy: .public)
            """)
            return .failed
        }
    }

    /// SP-005 S4 launch resume (ADR-016: crash-resume is a directory scan),
    /// three-way since ADR-024: sweep staging a previous run orphaned, sweep
    /// the audio of finalPass orphans (a success whose cleanup crashed —
    /// already final, never re-run), then enqueue only the TRUE pending
    /// meetings (retained audio, no provenance), newest first. Terminal
    /// drafts (audio + liveFloor) are never auto-resumed — the pending query
    /// excludes them; only the user's Retry re-opens one. The coordinator
    /// runs the queue one at a time — never while recording, never alongside
    /// summary work.
    private func resumePendingFinalizations() async {
        // A session started before this ran (unlikely — it is chained right
        // after the model preload): its staging is live, so skip the sweeps;
        // pending meetings still enqueue and simply defer until stop, and
        // any orphan is re-swept next launch.
        if !isRecording {
            await library.sweepRetentionStaging()
            await library.sweepFinalPassAudioOrphans()
        }
        let pending = await library.pendingFinalizationMeetingIDs()
        guard !pending.isEmpty else { return }
        Self.log.info("Resuming \(pending.count, privacy: .public) pending finalization(s) from retained audio")
        finalization.requestResume(of: pending)
    }

    // MARK: - Terminal-draft actions (SP-007, ADR-024)

    /// User-initiated Retry from the terminal-draft state: re-admits the
    /// meeting's pass with a FRESH bounded attempt budget at the front of
    /// the deferred queue (the user-request discipline). Admission is not
    /// bypassed — an active recording, summary work, or an open post-stop
    /// pipeline still gates the start — and a cycle that converges again
    /// returns to the draft with the audio still kept. Valid whether the
    /// meeting converged this run (clears the coordinator's terminal mark)
    /// or in a previous one (nothing to clear; the on-disk audio is the
    /// checkpoint the resumed pass reads).
    func retryFinalization(_ meetingID: UUID) {
        finalization.requestManualRetry(meetingID)
    }

    /// "Keep draft" (ADR-024): the user accepts the draft as the meeting's
    /// final transcript and ends retention — deletes exactly this meeting's
    /// kept audio; transcript and liveFloor provenance stay untouched (the
    /// Draft badge survives; the Retry disappears with its audio). The
    /// coordinator's in-memory terminal set deliberately keeps the meeting:
    /// that set only blocks AUTO re-admission, which is exactly right for an
    /// accepted draft — and with the audio gone there is nothing a pass
    /// could re-decode anyway.
    func keepDraft(_ meetingID: UUID) async {
        await library.deleteRetainedAudio(for: meetingID)
    }

    /// Runs `body` with a summary engine, counting the generation as active LLM
    /// work so the manager keeps the ~3.3 GB model warm for its whole duration
    /// and arms the idle release only once this returns (ADR-008). The engine is
    /// acquired on the manager actor; `body` runs here on the main actor with
    /// its streaming, guards, and persistence unchanged. Release is un-missable
    /// across every exit — early return, throw, cancellation — because it's
    /// driven from this do/catch rather than a `defer` (Swift forbids `await` in
    /// a defer body). A failed acquire releases its own count, so we release
    /// only after a successful acquire.
    private func withSummaryEngine<T>(
        progress: @Sendable @escaping (String, Double) -> Void,
        _ body: (any TextGenerating) async throws -> T
    ) async throws -> T {
        // ADR-014 admission: summary work and a final pass are never resident
        // together. Waits until no pass is decoding; while held, the
        // coordinator starts none. Balanced on every exit below.
        await finalization.beginSummaryWork()
        let engine: any TextGenerating
        do {
            engine = try await summaryModelManager.acquireEngine(progress: progress)
        } catch {
            finalization.endSummaryWork()
            throw error
        }
        do {
            let result = try await body(engine)
            await summaryModelManager.releaseEngine()
            finalization.endSummaryWork()
            return result
        } catch {
            await summaryModelManager.releaseEngine()
            finalization.endSummaryWork()
            throw error
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
            // First run downloads (~3.3 GB, once — resuming whatever the
            // recording-start prefetch already fetched) and loads the model;
            // later runs reuse the warm engine. The work scope counts this
            // generation so the model is released only after it finishes and
            // stays idle (ADR-008); the progress drives `summaryModelState`,
            // which the detail's generating view renders as the real phase —
            // never "Generating…" over a download. The early `return`s below
            // leave the work scope (releasing the engine) exactly as they used
            // to leave the function.
            try await withSummaryEngine(progress: { [weak self] phase, fraction in
                Task { @MainActor in self?.applySummaryModelProgress(phase, fraction) }
            }) { engine in
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
                        await library.attachSummary(
                            latest,
                            description: description,
                            modelName: SummaryModelManager.modelID,
                            to: meetingID
                        )
                    }
                } else {
                    state.markSummaryUnavailable("The summary model returned an empty summary.")
                }
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
        // The retention tee (SP-005, ADR-013) mirrors ingest exactly: the
        // same post-AEC/post-downmix samples and the same declared gaps, in
        // the same task, so the retained timeline can't diverge from the
        // live clock. Captured directly — the callbacks never touch `self`.
        let writer = retainedWriter
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
                if let gap { await writer?.noteGap(seconds: gap, on: .microphone) }
                await writer?.append(cleaned, to: .microphone)
            }
        }
        // Every session starts wired in the global combined shape; a scoped
        // start rewires the system side (`startSystemCapture`) before any
        // tap runs, so no sample is ever routed by the wrong shape.
        wireGlobalSystemCallbacks(aecStage: aecStage)
    }

    /// The system side of a *global* session — today's single tap serving
    /// both consumers, verbatim (ADR-025: global sessions carry zero change).
    /// Also the shape a scoped start falls back to (ADR-027).
    private func wireGlobalSystemCallbacks(aecStage: any AECStage) {
        let writer = retainedWriter
        system.onLevel = { [state] level in
            Task { @MainActor in state.pushOutput(level) }
        }
        system.onSamples = { [pipeline] frames in
            // Read-only fan-out (ADR-002): the far end gets a value copy; the
            // Team ingest path below must stay byte-identical to today.
            aecStage.feedFarEnd(frames)
            Task {
                await pipeline.ingest(frames, from: .system)
                await writer?.append(frames, to: .system)
            }
        }
    }

    /// The system side of a *scoped* session (SP-008, ADR-025): the scoped
    /// tap feeds exactly what the system callback feeds today MINUS the far
    /// end — pipeline ingest, retention, the output meter — and the global
    /// reference tap feeds ONLY `aecStage.feedFarEnd`. Nothing from the
    /// reference tap is ever persisted, transcribed, metered, or shown, so
    /// its `onLevel` deliberately stays nil.
    private func wireScopedSystemCallbacks(aecStage: any AECStage, referenceTap: SystemAudioCapture) {
        let writer = retainedWriter
        system.onLevel = { [state] level in
            Task { @MainActor in state.pushOutput(level) }
        }
        system.onSamples = { [pipeline] frames in
            Task {
                await pipeline.ingest(frames, from: .system)
                await writer?.append(frames, to: .system)
            }
        }
        referenceTap.onSamples = { frames in
            // Synchronous, like today's fan-out line — the canceller's
            // far-end buffer is fed on the capture callback, no Task hop.
            aecStage.feedFarEnd(frames)
        }
    }

    /// Starts the session's system-side capture in the requested scope and
    /// returns the scope the session actually runs with. `.everything` is
    /// exactly today's single-tap path. `.app` establishes the ADR-025 dual
    /// topology — reference tap first, so a scoped tap never runs without
    /// the far-end that keeps SP-001's invariant intact; if EITHER tap fails
    /// the session collapses to the known-good global topology with one
    /// `ErrorTrace` and effective scope Everything (ADR-027 — recording more
    /// than intended, visibly, beats a silently degraded You channel). If
    /// that global start also fails, the throw aborts the session exactly as
    /// today.
    private func startSystemCapture(
        requestedScope: CaptureScope,
        aecStage: any AECStage
    ) async throws -> CaptureScope {
        guard let app = requestedScope.scopedApp else {
            // Global session: the combined wiring from `wireCallbacks` is
            // already in place; nothing else changes.
            try await system.start()
            return .everything
        }

        let reference = SystemAudioCapture()
        wireScopedSystemCallbacks(aecStage: aecStage, referenceTap: reference)
        referenceTap = reference
        do {
            try await reference.start()
            try await system.start(scope: requestedScope)
            return requestedScope
        } catch {
            // ADR-027 start-time fallback. Both taps down first (`stop` is
            // idempotent — a failed scoped start already unwound `system`
            // itself), then the one trace, then rewire to the combined shape
            // so the global tap feeds the far end again.
            reference.stop()
            system.stop()
            referenceTap = nil
            ErrorTrace.record(
                "Scoped capture failed — falling back to a global session",
                error: error,
                category: "RecordingController",
                metadata: ["app": app.displayName]
            )
            wireGlobalSystemCallbacks(aecStage: aecStage)
            try await system.start()
            return .everything
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
                ErrorTrace.record("Mic restart failed", error: error, category: "RecordingController")
                self.handleInputLifecycleEvent(.micCaptureFailed)
            }
        }
    }
}
