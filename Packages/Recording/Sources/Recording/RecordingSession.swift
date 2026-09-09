//
//  RecordingSession.swift
//  Recording
//
//  The one truth about a recording. Every surface — the window, the island,
//  the menu bar — reads this object and nothing else, which is the whole
//  point of ADR-003: in the PoC each surface tracked its own idea of what was
//  happening, and they contradicted each other.
//
//  It is a rewrite, not a port (ADR-006). The PoC's `RecordingController` was
//  1 821 lines with no injection seams and therefore no tests for any of the
//  orchestration; what survives from it is the ORDER of things — which is
//  where the measurements live — not its shape. Every ordering comment below
//  records why that order and not another.
//
//  Isolation: `@MainActor` stated explicitly, because this is the observable
//  façade the UI reads (ADR-002); the package has no default isolation, so
//  everything else here decides for itself. The capture callbacks run on the
//  AVAudioEngine render thread and the Core Audio IO queue and never touch
//  this object directly — they capture the actors and lock-guarded values
//  they need and hop once, per batch.
//

import Audio
import EchoCore
import Foundation
import Meetings
import Observation
import Summarization
import Transcription
import os

@Observable
@MainActor
public final class RecordingSession {

    private static let log = Logger(subsystem: AppIdentity.logSubsystem, category: "RecordingSession")

    // MARK: - What the UI reads

    /// What is happening right now. The only lifecycle truth in the app.
    ///
    /// Composed rather than assigned, because three owners contribute to it:
    /// this object drives capture, the finalization driver publishes the
    /// running pass, and the summary scheduler publishes the meeting being
    /// summarized. Assigning one field from three places is how a phase ends
    /// up briefly wrong — a flash of `.idle` between a pass finishing and its
    /// summary starting is exactly the gap that made "summarizing" invisible
    /// in v1.
    ///
    /// Capture wins: whatever post-stop work is in flight, a live recording
    /// is what the user is doing.
    public var phase: RecordingPhase {
        switch capturePhase {
        case .recording(let startedAt, let scope):
            return .recording(startedAt: startedAt, scope: scope)
        case .stopping:
            return .stopping
        case .idle:
            if let meetingID = summarizingMeetingID {
                return .summarizing(meetingID: meetingID)
            }
            if let meetingID = finalization.meetingID {
                return .finalizing(meetingID: meetingID, progress: finalization.progress ?? 0)
            }
            return .idle
        }
    }

    /// Meetings waiting for a pass, front first. Published by the driver, not
    /// re-derived here.
    public var queuedMeetingIDs: [UUID] { finalization.queued }

    /// Meetings whose finalization gave up this run. Their audio is kept and
    /// only the user's Retry opens a new cycle; the set is in-memory, so a
    /// relaunch offers them again.
    public var terminalFailureMeetingIDs: Set<UUID> { finalization.terminalFailures }

    /// The meeting this session's post-stop work is about, if any. Derived
    /// from `phase`, never stored: a second field would be a second truth.
    public var currentMeetingID: UUID? { phase.meetingID }

    /// Live per-channel amplitudes, from real capture only.
    ///
    /// Computed at read time rather than stored, because staleness is a
    /// function of *now*: a channel whose device disappeared must fall to the
    /// resting line without a callback arriving to push it there.
    public var levels: CaptureLevels {
        let now = ContinuousClock.now
        return CaptureLevels(
            you: micLevels.amplitude(at: now),
            others: systemLevels.amplitude(at: now)
        )
    }

    /// Active notices, in a stable render order (see `RecordingNotice.Kind`).
    public var notices: [RecordingNotice] {
        noticeMessages
            .sorted { $0.key < $1.key }
            .map { RecordingNotice(kind: $0.key, message: $0.value) }
    }

    /// The capture half of the lifecycle — the only part this object drives
    /// imperatively.
    private enum CapturePhase: Equatable {
        case idle
        case recording(startedAt: Date, scope: CaptureScope)
        case stopping

        var isRecording: Bool {
            if case .recording = self { return true }
            return false
        }

        var startedAt: Date? {
            if case .recording(let startedAt, _) = self { return startedAt }
            return nil
        }

        /// Non-nil only once the system tap is actually up, which is what
        /// makes it usable as "system capture is established" — the rebuild
        /// scheduler needs that, not "a scope was requested".
        var captureScope: CaptureScope? {
            if case .recording(_, let scope) = self { return scope }
            return nil
        }
    }

    private var capturePhase: CapturePhase = .idle
    private var finalization: FinalizationDriver.Snapshot = .idle
    private var summarizingMeetingID: UUID?

    // MARK: - Collaborators

    private let library: MeetingLibrary
    private let settings: AppSettings
    private let summaryModel: SummaryModel
    private let runTranscriptionPass: TranscriptionPassRunning
    private let generateSummary: SummaryGenerating
    private let generateCaption: CaptionGenerating
    private let factories: CaptureFactories

    // MARK: - Session-scoped state

    /// The session epoch. Every continuation that resumes after an `await`
    /// asks `isCurrentSession` or `isCapturing` with the generation it was
    /// created under — one helper each, rather than the PoC's eight inline
    /// conjunctions (architecture §6).
    @ObservationIgnored private var sessionGeneration = 0

    @ObservationIgnored private var micCapture: (any MicCapturing)?
    @ObservationIgnored private var systemCapture: (any SystemCapturing)?
    /// The second, global tap a scoped session runs to feed the AEC far end
    /// and nothing else. Nil for a global session.
    @ObservationIgnored private var referenceCapture: (any SystemCapturing)?

    @ObservationIgnored private var switchingStage: SwitchingAECStage?
    @ObservationIgnored private var echoMode: EchoModeMachine?
    @ObservationIgnored private var inputLifecycle: InputDeviceLifecycleMachine?

    // Both watchers take their callbacks at construction, like the capture
    // sources and for the same reason, so they are built per session rather
    // than reconfigured. Building one performs no side effect; only `start()`
    // arms a Core Audio listener.
    @ObservationIgnored private var inputDeviceWatcher: (any InputDeviceWatching)?
    @ObservationIgnored private var outputRouteWatcher: (any OutputRouteWatching)?

    @ObservationIgnored private var micGapTracker: CaptureGapTracker?
    @ObservationIgnored private var systemGapTracker: CaptureGapTracker?
    @ObservationIgnored private var deliveredFrames: ChannelFrameCounter?
    @ObservationIgnored private var retainedWriter: RetainedAudioWriter?

    /// The chain that keeps `start` and `stop` from interleaving.
    ///
    /// Both are `async` and both take seconds — a cold system tap and its
    /// private aggregate device are not cheap — so without this a Stop landing
    /// mid-bring-up tears down what exists at that instant while the start
    /// goes on building the rest, and the leftovers keep capturing with no
    /// session behind them. Worse, a Start after that Stop would have the
    /// older call assign its sources over the newer session's. Serializing
    /// the two entry points removes the whole class: a Stop during a start
    /// simply waits for it, which is also the honest answer to "stop what?".
    @ObservationIgnored private var sessionTask: Task<Void, Never>?

    @ObservationIgnored private var micRestartTask: Task<Void, Never>?
    @ObservationIgnored private var systemRestartTask: Task<Void, Never>?

    private var micLevels = LevelWindow()
    private var systemLevels = LevelWindow()
    private var noticeMessages: [RecordingNotice.Kind: String] = [:]

    /// Permission dialogs are raised once per app run, on the first record
    /// gesture (ADR-009: permissions are a gesture effect, never a launch or
    /// download effect).
    @ObservationIgnored private var capturePermissionsPrimed = false

    /// Session-scoped speech-gate health classification. `lazy` because both
    /// of these hand a callback back to this object, and an initializer may
    /// not reference `self` before every stored property has a value; nothing
    /// is created until the first session, so construction still performs no
    /// side effect.
    @ObservationIgnored private lazy var inputHealth: InputHealthTracker = InputHealthTracker {
        [weak self] generation, effect in
        Task { @MainActor in self?.applyInputHealthEffect(effect, generation: generation) }
    }

    /// Chunk-level gate decisions for the health classifier. It does NOT
    /// transcribe: nothing produces words during a recording.
    @ObservationIgnored private lazy var liveMonitor: LiveInputMonitor = LiveInputMonitor(
        gateDiagnostics: FanOutGateDiagnosticsSink([OSLogGateDiagnosticsSink(), inputHealth])
    )

    /// Decides when a pass may run and runs it.
    ///
    /// Built on first use rather than in `init`, for the reason the two
    /// above are: its seams close over this object. Not `lazy`, because a
    /// `lazy` initializer is treated as a default argument and Swift 6 will
    /// not let one be main-actor isolated while the closures inside it are.
    @ObservationIgnored private var driverStorage: FinalizationDriver?

    private var driver: FinalizationDriver {
        if let driverStorage { return driverStorage }
        let created = FinalizationDriver(
            runPass: { [weak self] meetingID, shouldYield in
                guard let self else { return .failed }
                return await self.runPass(meetingID, shouldYield: shouldYield)
            },
            prepareForPass: { [weak self] in
                // Weights are never resident without work, and never two models'
                // worth at once: the summary engine goes before the first decode
                // of every pass, warm or not.
                guard let model = self?.summaryModel else { return }
                await model.unload()
            },
            convergeTerminally: { [weak self] meetingID in
                await self?.convergeTerminally(meetingID)
            },
            onBackgroundPassConcluded: { [weak self] _, result in
                // A resumed or retried pass has no stop path awaiting it, so its
                // summary is the backfill's job.
                guard case .replaced = result else { return }
                self?.summaryScheduler.kick()
            },
            onStateChanged: { [weak self] snapshot in
                self?.finalization = snapshot
            }
        )
        driverStorage = created
        return created
    }

    @ObservationIgnored private var summarySchedulerStorage: SummaryScheduler?

    private var summaryScheduler: SummaryScheduler {
        if let summarySchedulerStorage { return summarySchedulerStorage }
        let created = SummaryScheduler(
            library: library,
            settings: settings,
            model: summaryModel,
            driver: driver,
            generate: generateSummary,
            caption: generateCaption,
            isRecording: { [weak self] in self?.capturePhase.isRecording ?? false },
            onSummarizingChanged: { [weak self] meetingID in
                self?.summarizingMeetingID = meetingID
            }
        )
        summarySchedulerStorage = created
        return created
    }

    /// Meetings whose summary must be regenerated once their re-transcription
    /// lands. In-memory: a relaunch simply leaves the old summary in place
    /// until the user asks again.
    @ObservationIgnored private var retranscribedAwaitingSummary: Set<UUID> = []

    // MARK: - Construction

    /// Everything is injected, and nothing here touches the disk, the network
    /// or a device: an initializer performs no side effects (ADR-004), and
    /// the monitors only arm their Core Audio listeners in `start()`.
    init(
        library: MeetingLibrary,
        settings: AppSettings,
        summaryModel: SummaryModel,
        transcriptionModel: ParakeetModel,
        runTranscriptionPass: TranscriptionPassRunning? = nil,
        generateSummary: SummaryGenerating? = nil,
        generateCaption: CaptionGenerating? = nil,
        factories: CaptureFactories = .live
    ) {
        self.library = library
        self.settings = settings
        self.summaryModel = summaryModel
        // The model is only ever reached through the pass, so it is bound
        // into the default here rather than stored: nothing else in a session
        // has any business asking a transcription model a question.
        self.runTranscriptionPass =
            runTranscriptionPass ?? { retainedFiles, shouldYield, onProgress in
                try await TranscriptionPass.run(
                    retainedFiles: retainedFiles,
                    model: transcriptionModel,
                    shouldYield: shouldYield,
                    onProgress: onProgress
                )
            }
        // The summarizer carries the model's display name into every
        // document it writes, so a meeting records what wrote its notes
        // without asking a second object. Bound into the defaults for the
        // reason the pass is: what Recording owns is the SCHEDULING, and a
        // test of the scheduling should not have to drive real prompts.
        let summarizer = Summarizer(modelName: SummaryModel.modelDisplayName)
        self.generateSummary =
            generateSummary ?? { segments, engine in
                await summarizer.generate(from: segments, using: engine)
            }
        self.generateCaption =
            generateCaption ?? { document, engine in
                await summarizer.caption(for: document, using: engine)
            }
        self.factories = factories
    }

    /// The composition root's convenience: real everything, built from the
    /// data root.
    public convenience init(library: MeetingLibrary, settings: AppSettings, dataRoot: DataRoot) {
        self.init(
            library: library,
            settings: settings,
            summaryModel: SummaryModel(
                modelsRoot: dataRoot.models,
                pauseStateFile: dataRoot.summaryDownloadStateFile
            ),
            transcriptionModel: ParakeetModel(modelsRoot: dataRoot.models)
        )
    }

    // MARK: - Staleness

    /// Whether `generation` is still the newest session. Post-stop work uses
    /// this: it must survive `.stopping` and `.finalizing`, and only a NEW
    /// session invalidates it.
    private func isCurrentSession(_ generation: Int) -> Bool {
        generation == sessionGeneration
    }

    /// Whether `generation` is still the newest session AND capture is live.
    /// Anything that may only touch a running session asks this.
    private func isCapturing(_ generation: Int) -> Bool {
        isCurrentSession(generation) && capturePhase.isRecording
    }

    // MARK: - Start

    /// Begins a session. Nothing records without this being called from an
    /// explicit gesture.
    ///
    /// `scope` is what the caller asked for; the phase ends up carrying what
    /// was actually established, which can be wider (a scoped tap that fails
    /// collapses to `.everything`, visibly).
    public func start(scope requestedScope: CaptureScope = .everything) async {
        await serialized { await self.performStart(scope: requestedScope) }
    }

    /// Links one lifecycle call onto the chain and waits for it. The body runs
    /// only after every earlier call has finished, so `capturePhase` is never
    /// read by one of them while another is midway through changing it.
    private func serialized(_ body: @escaping @MainActor () async -> Void) async {
        let previous = sessionTask
        let task = Task { @MainActor in
            await previous?.value
            await body()
        }
        sessionTask = task
        await task.value
    }

    private func performStart(scope requestedScope: CaptureScope) async {
        switch capturePhase {
        case .recording, .stopping:
            // Already live, or mid-teardown: a second gesture is a no-op, not
            // a second session. Post-stop work does not block a new one — a
            // recording that starts mid-pass preempts it.
            return
        case .idle:
            break
        }

        // Both dialogs, sequentially, before anything else — and their
        // denials are NOT handled here: the start paths below surface their
        // own failures, and a user who denies the mic still gets a
        // meeting-audio session.
        await primeCapturePermissions()

        sessionGeneration += 1
        let generation = sessionGeneration
        // Signalled before any capture setup, so a pass that is decoding
        // right now begins yielding immediately rather than one decode window
        // into the new session. Balanced by exactly one
        // `noteRecordingStopped()` — every path out of a started session goes
        // through `teardown`.
        driver.noteRecordingStarted()
        clearAllNotices()

        // Staged under a hidden sibling of the meeting folders, on the same
        // volume, so adoption at stop is a rename. The folder name is a
        // staging id, NOT the meeting id: the meeting does not exist until
        // stop persists it.
        let stagingDirectory = library.store.retentionStagingDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let writer = RetainedAudioWriter(
            directory: stagingDirectory,
            fileName: MeetingStore.retainedAudioFileName
        )
        retainedWriter = writer

        let aec = buildEchoHandling(generation: generation)
        micGapTracker = CaptureGapTracker()
        systemGapTracker = CaptureGapTracker()
        deliveredFrames = ChannelFrameCounter()
        inputHealth.beginSession(generation: generation)

        micLevels.reset()
        systemLevels.reset()
        capturePhase = .recording(startedAt: Date(), scope: requestedScope)
        startInputDeviceHandling()

        do {
            await liveMonitor.start()
            try await startMicIfExpected()

            // Opened the instant the mic went live, BEFORE the tap is built.
            // The Others channel is deaf from here until its tap exists —
            // seconds on a cold start, because the tap and its private
            // aggregate device are not cheap — and an undeclared hole would
            // shift every later Others timestamp earlier by its whole length:
            // teammates answering before the question, and the dedup gate
            // comparing the two channels off by seconds. Both channels count
            // from the same zero.
            systemGapTracker?.beginEpisode()

            let effective = try await startSystemCapture(requested: requestedScope, aec: aec)
            guard isCapturing(generation) else { return }

            // Fixed for the whole session: a running session never silently
            // widens, not even through a device rebuild.
            capturePhase = .recording(
                startedAt: capturePhase.startedAt ?? Date(), scope: effective)

            // Recording is the implicit request for this meeting's summary,
            // so fetch the model's FILES during the session. Download only —
            // nothing is ever loaded into RAM while capture runs.
            prefetchSummaryModel()
        } catch {
            ErrorTrace.record("Recording could not start", error: error, category: "RecordingSession")
            await teardown(persisting: false)
            // Raised after the teardown, which clears the session's notices.
            raise(.captureFailed, error.localizedDescription)
        }
    }

    /// Raises both OS dialogs, in order, once per app run.
    ///
    /// The system-audio half is a probe, not a query: the prompt only fires
    /// when a process tap actually runs, so `primePermission` starts a
    /// throwaway capture and tears it down.
    private func primeCapturePermissions() async {
        guard !capturePermissionsPrimed else { return }
        capturePermissionsPrimed = true
        await factories.primePermissions()
    }

    // MARK: - Echo handling

    /// Builds the session's echo-cancellation stage and arms the route
    /// monitor. Returns the stage the capture callbacks will use.
    private func buildEchoHandling(generation: Int) -> any AECStage {
        let watcher = factories.makeOutputRouteWatcher(
            { [weak self] route in
                Task { @MainActor in self?.applyRouteChange(route, generation: generation) }
            },
            { [weak self] _ in
                Task { @MainActor in self?.scheduleSystemCaptureRestart(generation: generation) }
            }
        )
        outputRouteWatcher = watcher

        var machine = EchoModeMachine(initialRoute: watcher.currentRoute())
        let engine = factories.makeEchoCanceller()

        engine.setEngineEventHandler { [weak self] healthy in
            Task { @MainActor in self?.applyEngineHealth(healthy, generation: generation) }
        }
        // An engine that never came up must not block the session: fold the
        // failure in now, so the mode is right before the first frame and the
        // notice does not wait for a transition that already happened.
        if machine.mode == .cancelling, !engine.isEngineHealthy {
            applyEchoEffect(machine.handle(.engineFailed))
        }

        let stage = SwitchingAECStage(engineStage: engine, mode: machine.mode)
        switchingStage = stage
        echoMode = machine

        watcher.start()
        Self.log.info("Echo handling: \(machine.mode.rawValue, privacy: .public)")
        return stage
    }

    /// A route change. Reported before the device change that may accompany
    /// it, so echo handling has already switched mode by the time the tap
    /// rebuilds.
    private func applyRouteChange(_ route: OutputRouteClass, generation: Int) {
        guard isCapturing(generation), var machine = echoMode else { return }
        let effect = machine.handle(.routeChanged(route))
        echoMode = machine
        switchingStage?.setMode(machine.mode)
        // Reset only here: cancelling ↔ degraded keeps the engine fed, so
        // recovery means it is already processing frames successfully.
        switchingStage?.reset()
        applyEchoEffect(effect)
    }

    /// The engine reported a health TRANSITION. It reports transitions only,
    /// so a stage that failed once never reports again — a route round trip
    /// can therefore leave the mode machine back in `.cancelling` with the
    /// engine still down. The audio is unharmed (a failed frame emits the raw
    /// input); what is lost is the notice.
    private func applyEngineHealth(_ healthy: Bool, generation: Int) {
        guard isCapturing(generation), var machine = echoMode else { return }
        let effect = machine.handle(healthy ? .engineRecovered : .engineFailed)
        echoMode = machine
        switchingStage?.setMode(machine.mode)
        applyEchoEffect(effect)
    }

    private func applyEchoEffect(_ effect: EchoModeMachine.Effect?) {
        guard let effect else { return }
        if let message = EchoDegradationNotice.notice(after: effect) {
            raise(.echoCancellation, message)
        } else {
            clear(.echoCancellation)
        }
    }

    private func stopEchoHandling() {
        outputRouteWatcher?.stop()
        outputRouteWatcher = nil
        switchingStage?.reset()
        switchingStage = nil
        echoMode = nil
    }

    // MARK: - Input device lifecycle

    private func startInputDeviceHandling() {
        let generation = sessionGeneration
        let watcher = factories.makeInputDeviceWatcher { [weak self] device in
            Task { @MainActor in
                self?.handleInputDeviceEvent(.defaultInputChanged(device), generation: generation)
            }
        }
        inputDeviceWatcher = watcher

        var machine = InputDeviceLifecycleMachine()
        // A Mac with no input device at all begins Others-only rather than
        // failing: the microphone is optional, the meeting audio is not.
        let actions = machine.handle(.recordingStarted(device: watcher.currentDefaultInputDevice()))
        inputLifecycle = machine

        watcher.start()
        apply(inputActions: actions, generation: generation)
    }

    /// Feeds one device event through the lifecycle machine and applies what
    /// it asks for. Internal rather than private so a test can drive a device
    /// loss and a recovery without a Core Audio listener — the machine itself
    /// is table-tested in `Audio`; what this covers is the wiring.
    func handleInputDeviceEvent(
        _ event: InputDeviceLifecycleMachine.Event, generation: Int
    ) {
        guard isCapturing(generation), var machine = inputLifecycle else { return }
        let actions = machine.handle(event)
        inputLifecycle = machine
        apply(inputActions: actions, generation: generation)
    }

    private func apply(inputActions: [InputDeviceLifecycleMachine.Action], generation: Int) {
        for action in inputActions {
            switch action {
            case .restartMicCapture:
                scheduleMicRestart(generation: generation)
            case .resetEchoProcessing:
                // Echo processing has to reset and re-converge on every
                // input-device change; the health classifier's mic evidence
                // is about the old device and must not carry over.
                switchingStage?.reset()
                inputHealth.noteMicDeviceChanged()
            case .stopMicCapture:
                micGapTracker?.beginEpisode()
                micCapture?.stop()
                micCapture = nil
            case .showMicUnavailableNotice:
                raise(.microphoneUnavailable, InputDeviceNotice.micUnavailableMessage)
            case .clearMicUnavailableNotice:
                clear(.microphoneUnavailable)
            }
        }
    }

    /// Rebuilds the mic engine on the new device, one rebuild at a time.
    private func scheduleMicRestart(generation: Int) {
        let previous = micRestartTask
        micGapTracker?.beginEpisode()
        micCapture?.stop()
        micCapture = nil
        micRestartTask = Task { @MainActor [weak self] in
            _ = await previous?.value
            guard let self, !Task.isCancelled, self.isCapturing(generation),
                self.inputLifecycle?.expectsMicCapture == true
            else { return }
            do {
                try await self.startMicIfExpected()
            } catch {
                ErrorTrace.record(
                    "Microphone restart failed", error: error, category: "RecordingSession")
                self.handleInputDeviceEvent(.micCaptureFailed, generation: generation)
            }
        }
    }

    /// Rebuilds the system tap after the default OUTPUT device changed.
    ///
    /// Not cosmetic: the tap lives inside an aggregate device anchored to
    /// whichever output device was default when it was built, and that anchor
    /// — with its sample rate — survives the user moving the sound elsewhere.
    /// Putting on AirPods mid-meeting would otherwise leave the Others
    /// channel clocked by a device nobody is listening to.
    ///
    /// Rebuilt with the session's EFFECTIVE scope, never the requested one: a
    /// session that fell back to global stays global, a scoped one is rebuilt
    /// scoped.
    private func scheduleSystemCaptureRestart(generation: Int) {
        let previous = systemRestartTask
        systemRestartTask = Task { @MainActor [weak self] in
            _ = await previous?.value
            guard let self, !Task.isCancelled, self.isCapturing(generation),
                let scope = self.capturePhase.captureScope, let aec = self.switchingStage
            else { return }

            self.systemGapTracker?.beginEpisode()
            self.systemCapture?.stop()
            self.systemCapture = nil
            self.referenceCapture?.stop()
            self.referenceCapture = nil
            do {
                let effective = try await self.startSystemCapture(requested: scope, aec: aec)
                guard self.isCapturing(generation) else { return }
                self.capturePhase = .recording(
                    startedAt: self.capturePhase.startedAt ?? Date(), scope: effective)
            } catch {
                ErrorTrace.record(
                    "System capture rebuild failed", error: error, category: "RecordingSession")
            }
        }
    }

    private func stopInputDeviceHandling() async {
        // First out: no device event and no in-flight rebuild may revive the
        // mic once teardown has begun.
        inputDeviceWatcher?.stop()
        inputDeviceWatcher = nil
        micRestartTask?.cancel()
        _ = await micRestartTask?.value
        micRestartTask = nil
        if var machine = inputLifecycle {
            let actions = machine.handle(.recordingStopped)
            inputLifecycle = machine
            // Only the notice actions matter now; capture is coming down
            // anyway, so a restart request would be a rebuild into a stop.
            for action in actions where action == .clearMicUnavailableNotice {
                clear(.microphoneUnavailable)
            }
        }
        inputLifecycle = nil
    }

    private func stopOutputDeviceHandling() async {
        // Disarmed before the awaits below, mirroring the input side: a route
        // change landing mid-teardown would otherwise schedule a tap rebuild
        // that still sees `.recording` and outlives the session it rebuilt
        // for. `stopEchoHandling` stops it again, harmlessly — the monitor
        // only unregisters a listener it still holds.
        outputRouteWatcher?.stop()
        systemRestartTask?.cancel()
        _ = await systemRestartTask?.value
        systemRestartTask = nil
    }

    // MARK: - Capture wiring

    /// Brings the mic up, unless the session is running meeting-audio only.
    ///
    /// A missing input device DEGRADES the session rather than failing it —
    /// the Others channel is inviolable. Permission denial and anything
    /// unexpected propagate and abort, because those are not degradation.
    private func startMicIfExpected() async throws {
        guard inputLifecycle?.expectsMicCapture == true else {
            micGapTracker?.beginEpisode()
            return
        }
        guard let aec = switchingStage else { return }
        let capture = makeMicrophoneCapture(aec: aec)
        micCapture = capture
        do {
            try await capture.start()
        } catch MicrophoneCapture.CaptureError.noInputDevice {
            micCapture = nil
            handleInputDeviceEvent(.micCaptureFailed, generation: sessionGeneration)
        }
    }

    private func makeMicrophoneCapture(aec: any AECStage) -> any MicCapturing {
        // The callbacks capture exactly what they touch — the actors, the
        // lock-guarded trackers and the stage — and never `self`: they run on
        // the render thread, and a real-time callback must not race on this
        // object's reference.
        let gaps = micGapTracker
        let frames = deliveredFrames
        let monitor = liveMonitor
        let writer = retainedWriter
        return factories.makeMicrophone(
            { samples in
                let gap = gaps?.noteDelivery(
                    batchDuration: Double(samples.count) / AudioConstants.sampleRate)
                let processed = aec.processMicSamples(samples)
                frames?.add(processed.count, to: .microphone)
                // ONE task per callback carrying the gap and the samples
                // together, never one per operation. That is what keeps a
                // gap's clock realignment attached to the batch that closed
                // it, so the two can never be separated by another callback's
                // work.
                //
                // It does NOT order one callback against the next: unstructured
                // tasks reach an actor in whatever order the executor gives
                // them, and actor isolation only promises mutual exclusion.
                // The measured shape is the PoC's and is carried unchanged
                // (ADR-006); reordering between batches is a known cost of it,
                // and changing the hand-off needs a measurement, not an
                // opinion.
                Task {
                    if let gap {
                        await monitor.noteCaptureGap(seconds: gap, on: .microphone)
                    }
                    await monitor.ingest(processed, from: .microphone)
                    if let gap {
                        await writer?.noteGap(seconds: gap, on: .microphone)
                    }
                    await writer?.append(processed, to: .microphone)
                }
            },
            { [weak self] level in
                Task { @MainActor in self?.pushLevel(level, on: .microphone) }
            }
        )
    }

    /// The ingest tap. `feedsFarEnd` is true for a global session, where the
    /// same tap is both the Others channel and the AEC reference; a scoped
    /// session sets it false and runs a second, global tap for the reference
    /// alone.
    private func makeSystemCapture(aec: any AECStage, feedsFarEnd: Bool) -> any SystemCapturing {
        let gaps = systemGapTracker
        let frames = deliveredFrames
        let monitor = liveMonitor
        let writer = retainedWriter
        return factories.makeSystem(
            { samples in
                let gap = gaps?.noteDelivery(
                    batchDuration: Double(samples.count) / AudioConstants.sampleRate)
                // The AEC only ever READS this stream as its far-end
                // reference; it never writes into it.
                if feedsFarEnd { aec.feedFarEnd(samples) }
                frames?.add(samples.count, to: .system)
                // One task per callback, gap and samples together — see the
                // microphone path for what that does and does not guarantee.
                Task {
                    if let gap {
                        await monitor.noteCaptureGap(seconds: gap, on: .system)
                    }
                    await monitor.ingest(samples, from: .system)
                    if let gap {
                        await writer?.noteGap(seconds: gap, on: .system)
                    }
                    await writer?.append(samples, to: .system)
                }
            },
            { [weak self] level in
                Task { @MainActor in self?.pushLevel(level, on: .system) }
            }
        )
    }

    /// Starts the system side and returns the coverage actually established.
    ///
    /// A scoped session runs TWO taps: the scoped one for ingest, retention
    /// and the meter, and a second global one whose only job is the AEC far
    /// end. The reference comes up FIRST, so a scoped tap never runs without
    /// the far end that keeps cancellation honest, and nothing from it is
    /// ever persisted, transcribed, metered or shown — which is why it is
    /// built with no level callback at all.
    ///
    /// If either tap fails, the session collapses to a global one VISIBLY:
    /// recording more than intended, and saying so, beats a silently
    /// degraded You channel.
    private func startSystemCapture(
        requested: CaptureScope, aec: any AECStage
    ) async throws -> CaptureScope {
        guard let app = requested.scopedApp else {
            let capture = makeSystemCapture(aec: aec, feedsFarEnd: true)
            systemCapture = capture
            try startAndUnwindOnFailure(capture, scope: .everything)
            return .everything
        }

        let reference = factories.makeSystem({ samples in aec.feedFarEnd(samples) }, nil)
        let scoped = makeSystemCapture(aec: aec, feedsFarEnd: false)
        referenceCapture = reference
        systemCapture = scoped
        do {
            try startAndUnwindOnFailure(reference, scope: .everything)
            try startAndUnwindOnFailure(scoped, scope: requested)
            return requested
        } catch {
            reference.stop()
            scoped.stop()
            referenceCapture = nil
            ErrorTrace.record(
                "Scoped capture failed — falling back to a global session",
                error: error,
                category: "RecordingSession",
                metadata: ["app": app.displayName]
            )
            let fallback = makeSystemCapture(aec: aec, feedsFarEnd: true)
            systemCapture = fallback
            try startAndUnwindOnFailure(fallback, scope: .everything)
            return .everything
        }
    }

    /// Starts a tap and tears it down if the start threw.
    ///
    /// The global start path does not unwind a half-built topology on its own
    /// (the scoped path does), so a failed start can leave a process tap and
    /// a private aggregate device orphaned for the next attempt to trip over.
    /// `stop()` is idempotent, so calling it unconditionally is safe on both
    /// paths.
    private func startAndUnwindOnFailure(_ capture: any SystemCapturing, scope: CaptureScope) throws {
        do {
            try capture.start(scope: scope)
        } catch {
            capture.stop()
            throw error
        }
    }

    // MARK: - Stop

    /// Ends the session and persists the meeting.
    ///
    /// Returns as soon as the meeting is on disk. Transcription and the
    /// summary run afterwards: a Stop that blocked for minutes is what made
    /// the PoC's hand-off from the popover to the window feel broken.
    public func stop() async {
        await serialized {
            guard self.capturePhase.isRecording else { return }
            await self.teardown(persisting: true)
        }
    }

    /// The one teardown. `persisting: false` is the aborted-start path: the
    /// staged audio is dropped and no meeting is created.
    private func teardown(persisting: Bool) async {
        let writer = retainedWriter
        // Nil'd first: the capture callbacks hold their own reference, and
        // from here the stop path owns it.
        retainedWriter = nil

        await stopInputDeviceHandling()
        await stopOutputDeviceHandling()

        // Read while the tap still knows what it did: `stop()` clears the
        // activation instant and the tap format the accessor needs, and
        // without them it reports nothing at all.
        let systemStats = systemCapture?.deliveryStats()

        micCapture?.stop()
        micCapture = nil
        systemCapture?.stop()
        systemCapture = nil
        referenceCapture?.stop()
        referenceCapture = nil
        stopEchoHandling()

        // The monitor before the tracker: stopping the monitor finalizes
        // whatever is pending in both channel buffers, and those last chunks
        // travel to the tracker as gate records. Ending the tracker's session
        // first would make it inert and silently drop exactly the
        // end-of-session evidence the classifier exists to see.
        await liveMonitor.stop()
        inputHealth.endSession()

        let startedAt = capturePhase.startedAt ?? Date()
        let scope = capturePhase.captureScope
        let frames = deliveredFrames

        capturePhase = .stopping
        // Lowers the preemption signal and opens this meeting's post-stop
        // pipeline. Balanced by exactly one `notePostStopWorkFinished()` on
        // each of the three paths below.
        driver.noteRecordingStopped()
        micLevels.reset()
        systemLevels.reset()
        clearAllNotices()
        micGapTracker = nil
        systemGapTracker = nil
        deliveredFrames = nil

        guard persisting else {
            if let writer { await writer.discard() }
            capturePhase = .idle
            driver.notePostStopWorkFinished()
            return
        }

        let endedAt = Date()
        let meetingID = await armFinalization(
            writer: writer, startedAt: startedAt, endedAt: endedAt, scope: scope)

        // After adoption, so the counts are final and every straggler ingest
        // task has had the round trips above to land or be turned away.
        if let writer {
            await recordRetentionAccounting(
                writer: writer,
                frames: frames,
                wallSeconds: endedAt.timeIntervalSince(startedAt),
                systemStats: systemStats
            )
        }

        guard let meetingID else {
            capturePhase = .idle
            driver.notePostStopWorkFinished()
            return
        }

        // Idle first, so the composed phase can report what the driver is
        // about to publish. The retained audio IS the pending marker; the
        // phase only says so.
        capturePhase = .idle
        driver.requestStopPass(meetingID)
        await library.refresh()

        // Fire and forget: `stop()` returns once the meeting is on disk, so
        // no surface sits blocked behind minutes of transcription.
        Task { @MainActor [weak self] in
            guard let self else { return }
            let outcome = await self.driver.awaitStopOutcome(for: meetingID)
            if case .replaced = outcome {
                // Awaited inside the pipeline on purpose: deferred passes
                // resume behind this meeting's pass AND its summary.
                await self.summaryScheduler.summarizeAfterFinalization(meetingID)
            }
            // `.failed` is terminal, so there is no transcript to summarize;
            // `.deferred` means a new recording took over and the summary
            // follows THAT pass.
            self.driver.notePostStopWorkFinished()
            // A stop is also a natural catch-up point for everything else.
            self.summaryScheduler.kick()
        }
    }

    /// Closes the retention files, persists the meeting, and adopts the audio
    /// into its folder. Returns the meeting id, or nil when there is no
    /// meeting to finalize.
    ///
    /// The order is load-bearing and each step gates the next: `save` is what
    /// CREATES the folder (writing `meta.json` last, so a reader that finds a
    /// meta also finds everything beside it), and `adoptRetainedAudio` moves
    /// into a folder it does not create. Adopt-then-save would leave audio in
    /// a meta-less folder that `listMetas` never lists.
    private func armFinalization(
        writer: RetainedAudioWriter?, startedAt: Date, endedAt: Date, scope: CaptureScope?
    ) async -> UUID? {
        guard let writer else { return nil }
        let staged = await writer.finish()
        guard !staged.isEmpty else {
            // Retention was disabled mid-session, or nothing was captured.
            // There is no payload and no pending marker, so there is no
            // meeting: a folder claiming a recording that produced no audio
            // would be a row that can never become words.
            await writer.discard()
            return nil
        }

        let id = UUID()
        let meta = MeetingMeta(
            id: id,
            title: MeetingMeta.autoTitle(startedAt: startedAt),
            startedAt: startedAt,
            endedAt: endedAt,
            // The meeting is persisted from its retained audio, not from a
            // transcript: nothing transcribes during a recording, so there
            // are no words yet and an empty `transcript.json` beside it would
            // claim one that does not exist.
            segmentCount: 0,
            hasSummary: false,
            captureScope: scope.map(CaptureScopeRecord.init(capturing:))
        )
        do {
            try await library.store.save(MeetingRecord(meta: meta, segments: []))
        } catch {
            ErrorTrace.record(
                "Persisting the stopped meeting failed", error: error, category: "RecordingSession")
            await writer.discard()
            return nil
        }

        do {
            _ = try await library.store.adoptRetainedAudio(staged, for: id)
        } catch {
            // Adoption is all-or-nothing, so every staged file is still in
            // the staging tree — which is a named sweep target, cleaned at
            // the next launch. Nothing is rescued and nothing is deleted from
            // here.
            ErrorTrace.record(
                "Adopting the retained audio failed", error: error, category: "RecordingSession",
                metadata: ["meeting": id.uuidString, "channels": String(staged.count)])
            // The recording did happen, so the meeting stands — but it has no
            // audio and will never have words. Recording the terminal
            // provenance now is what keeps it from reading as "pending
            // transcription" forever: with no audio present the disposition
            // is `.none`, so it is never resumed and never retried, and the
            // row shows the honest failed state instead.
            do {
                try await library.store.recordTerminalProvenance(
                    for: id,
                    provenance: TranscriptProvenance(
                        source: .terminalFailure, modelName: ParakeetModel.modelID))
            } catch {
                ErrorTrace.record(
                    "Recording the terminal provenance failed", error: error,
                    category: "RecordingSession", metadata: ["meeting": id.uuidString])
            }
            raise(.retentionLost, Self.retentionLostMessage)
            await writer.discard()
            await library.refresh()
            return nil
        }

        // The staged files just moved out; drop the empty staging folder.
        await writer.discard()
        return id
    }

    static let retentionLostMessage =
        "The recording was saved, but its audio could not be kept — it cannot be transcribed."

    /// Traces the retention shortfall when a channel comes up materially
    /// short of the meeting's wall time.
    ///
    /// This exists for a measured, unexplained defect: the Others channel's
    /// retained file is systematically shorter than the meeting — 4–8 % on
    /// real recordings, growing with load — and the audio itself ruled out
    /// the obvious explanations (no silence padding at the head, and the
    /// speed is right, so nothing is resampled wrong). The three counters
    /// separate the three possible causes: audio never captured (the tap's
    /// own delivery), captured but never written (the writer's accepted
    /// frames against what the pipeline handed over), and written after the
    /// file closed (the writer's rejections). The Others channel spawns ~86
    /// ingest tasks a second against the mic's 10, which is why the third
    /// cause is plausible at all.
    ///
    /// Short sessions are all edge — bring-up, encoder priming — and would
    /// trace noise rather than a defect, so they are skipped. Traced rather
    /// than logged because `notice` lines are not always retrievable later.
    private func recordRetentionAccounting(
        writer: RetainedAudioWriter,
        frames: ChannelFrameCounter?,
        wallSeconds: TimeInterval,
        systemStats: SystemAudioCapture.DeliveryStats?
    ) async {
        guard wallSeconds > 10 else { return }
        let accounting = await writer.currentAccounting()
        for channel in AudioChannel.allCases {
            let written = Double(accounting.writtenFrames[channel] ?? 0) / AudioConstants.sampleRate
            guard wallSeconds - written > wallSeconds * 0.02 else { continue }
            var metadata: [String: String] = [
                "channel": channel.rawValue,
                "wallSeconds": String(format: "%.1f", wallSeconds),
                "writtenSeconds": String(format: "%.1f", written),
                "rejectedFrames": String(accounting.rejectedFrames[channel] ?? 0),
            ]
            if let frames {
                metadata["deliveredSeconds"] = String(format: "%.1f", frames.seconds(channel))
            }
            if channel == .system, let systemStats {
                metadata["tapSeconds"] = String(format: "%.1f", systemStats.deliveredSeconds)
            }
            ErrorTrace.record(
                "Retained audio is short of the session's wall time",
                category: "RecordingSession", metadata: metadata)
        }
    }

    // MARK: - Levels and notices

    /// One measured level from a capture callback. The only way a level ever
    /// enters this object — there is no simulated, animated or placeholder
    /// path, and a meter that moves when nothing is captured would make a
    /// broken microphone look fine.
    private func pushLevel(_ level: Double, on channel: AudioChannel) {
        guard capturePhase.isRecording else { return }
        let now = ContinuousClock.now
        switch channel {
        case .microphone: micLevels.append(level, at: now)
        case .system: systemLevels.append(level, at: now)
        }
    }

    /// A speech-gate health verdict, tagged with the session whose evidence
    /// produced it. Stale deliveries are dropped by generation, so a teardown
    /// straggler can neither raise a notice while idle nor leak one into the
    /// next session.
    private func applyInputHealthEffect(
        _ effect: InputHealthClassifier.Effect, generation: Int
    ) {
        guard isCapturing(generation) else { return }
        switch effect {
        case .showMicHealthNotice:
            raise(.microphoneHealth, InputHealthNotice.micMessage)
        case .showSystemHealthNotice:
            raise(.meetingAudioHealth, InputHealthNotice.systemMessage)
        case .clearHealthNotice(.microphone):
            clear(.microphoneHealth)
        case .clearHealthNotice(.system):
            clear(.meetingAudioHealth)
        }
    }

    private func raise(_ kind: RecordingNotice.Kind, _ message: String) {
        noticeMessages[kind] = message
    }

    private func clear(_ kind: RecordingNotice.Kind) {
        noticeMessages[kind] = nil
    }

    private func clearAllNotices() {
        noticeMessages.removeAll()
    }

    // MARK: - Finalization

    /// Decodes one meeting's retained audio and replaces its transcript.
    ///
    /// The pass itself neither deletes audio nor writes anything: what
    /// happens to the files and to `Meetings/` is decided here, and the order
    /// is what makes a crash at any point recoverable.
    private func runPass(
        _ meetingID: UUID, shouldYield: @escaping @Sendable () -> Bool
    ) async -> FinalizationDriver.PassResult {
        let store = library.store
        let retained = await store.retainedAudioFiles(for: meetingID)
        guard !retained.isEmpty else {
            // The pending marker vanished under us — nothing to decode, and
            // retrying cannot help.
            ErrorTrace.record(
                "A pass was admitted for a meeting with no retained audio",
                category: "RecordingSession", metadata: ["meeting": meetingID.uuidString])
            return .failed
        }

        do {
            let segments = try await runTranscriptionPass(
                retained,
                shouldYield,
                { [weak self] fraction in
                    Task { @MainActor in self?.driver.noteProgress(fraction, for: meetingID) }
                }
            )

            // An empty segment set is a legitimate success: the model heard
            // no speech, and that is a finished transcript, not a failure.
            try await store.replaceTranscript(
                segments,
                provenance: TranscriptProvenance(
                    source: .finalPass, modelName: ParakeetModel.modelID),
                for: meetingID
            )

            // After the replace, never before: the summary is retired where
            // the replacement it was waiting for actually happened. Clearing
            // `hasSummary` is also what re-admits the meeting to the backfill.
            if retranscribedAwaitingSummary.remove(meetingID) != nil {
                try? await store.removeSummaryArtifacts(for: meetingID)
            }

            await disposeOfRetainedAudio(for: meetingID, store: store)
            await library.refresh()
            return .replaced(segments)
        } catch TranscriptionError.preempted {
            // A deferral, not a failure: the audio is untouched and the
            // meeting stays pending.
            return .preempted
        } catch {
            ErrorTrace.record(
                "Transcription pass failed — the retained audio is kept", error: error,
                category: "RecordingSession", metadata: ["meeting": meetingID.uuidString])
            return .failed
        }
    }

    /// What happens to the audio after a successful pass.
    private func disposeOfRetainedAudio(for meetingID: UUID, store: MeetingStore) async {
        #if DEBUG
            // Takes precedence over the product preservation below: with both
            // armed the audio lands under the debug names, and the rename
            // then finds nothing.
            if LaunchEnvironment.current.keepsRetainedAudio {
                _ = await store.preserveRetainedAudioAsDebugFixture(for: meetingID)
            }
        #endif
        // Read at pass-success time rather than at record time, so a toggle
        // flipped mid-pass affects that pass.
        if settings.keepRecordingsAfterTranscription {
            _ = await store.preserveRetainedAudio(for: meetingID)
        }
        // Always, and last. Named targets only — never a directory sweep — so
        // siblings and sidecars are untouched, and after a preserve rename it
        // harmlessly finds nothing.
        await store.deleteRetainedAudio(for: meetingID)
    }

    /// Retries are exhausted for this run.
    ///
    /// Exactly one atomic meta write and nothing beside it, which is what
    /// makes the terminal transition crash-safe: a crash BEFORE it leaves the
    /// meeting pending, so the next launch converges again; after it, the
    /// scan reads the failure and never auto-resumes. The retained audio is
    /// KEPT — it is what the user's Retry works from.
    private func convergeTerminally(_ meetingID: UUID) async {
        do {
            try await library.store.recordTerminalProvenance(
                for: meetingID,
                provenance: TranscriptProvenance(
                    source: .terminalFailure, modelName: ParakeetModel.modelID)
            )
        } catch {
            // Best effort: a failure here leaves the meeting pending, and the
            // next launch converges it again.
            ErrorTrace.record(
                "Recording the terminal provenance failed", error: error,
                category: "RecordingSession", metadata: ["meeting": meetingID.uuidString])
        }
        await library.refresh()
    }

    // MARK: - Launch and user actions

    /// Cleans up what a quit or a crash left behind and re-enqueues the
    /// meetings still waiting for words. Called once by the composition root.
    ///
    /// The sweeps are skipped while a session runs: its staging tree is live.
    /// Pending meetings still enqueue and simply defer until the stop, and
    /// any orphan is re-swept at the next launch.
    public func resumePendingFinalizations() async {
        let store = library.store
        if !capturePhase.isRecording {
            await store.sweepRetentionStaging()
            await store.sweepFinalPassAudioOrphans()
        }
        // Newest first: request order is queue order.
        driver.requestResume(of: await store.pendingFinalizationMeetingIDs())
    }

    /// The user pressed Retry on a meeting whose finalization gave up.
    ///
    /// A fresh bounded cycle, at the front of the queue — but it bypasses no
    /// admission gate, so it starts only when nothing is recording and no
    /// summary is streaming. Bounded within every cycle, user-paced across
    /// cycles, never an automatic loop.
    public func retryTranscription(_ meetingID: UUID) {
        driver.requestManualRetry(meetingID)
    }

    /// Re-transcribes a meeting from the recording it preserved.
    ///
    /// The archive is never consumed: the pass reads a CLONE written under
    /// the retained names, so the existing pending machinery runs unmodified
    /// and `audio-*` survives however the pass ends. A meeting that already
    /// had a summary regenerates it on success — re-transcribing is an
    /// explicit action, so the summary it invalidates is replaced even with
    /// automatic summaries off.
    public func retranscribe(_ meetingID: UUID) async {
        let store = library.store
        guard await store.hasPreservedAudio(for: meetingID) else { return }
        guard await store.cloneAudioForRetranscription(for: meetingID) else { return }
        if library.meta(for: meetingID)?.hasSummary == true {
            retranscribedAwaitingSummary.insert(meetingID)
        }
        driver.requestManualRetry(meetingID)
    }

    /// The user asked for this meeting's summary. It front-runs the scan,
    /// works with automatic summaries off, and is the one trigger allowed to
    /// fetch a model that is not on disk yet.
    public func requestSummary(_ meetingID: UUID) {
        summaryScheduler.request(meetingID)
    }

    /// Re-runs the summary scan. The window calls this when it opens, and the
    /// composition root when a model download completes.
    public func kickSummaryBackfill() {
        summaryScheduler.kick()
    }

    // MARK: - Summary model prefetch

    /// Fetches the summary model's FILES while the meeting runs, because
    /// recording is the implicit request for this meeting's summary.
    ///
    /// Download only — never a load. Pulling multiple gigabytes of weights
    /// into RAM during a recording is exactly what ADR-008 forbids, and the
    /// fetch honours a paused intent because a pause is a persisted decision,
    /// not a failure to work around.
    private func prefetchSummaryModel() {
        let model = summaryModel
        Task {
            do {
                try await model.ensureDownloaded()
            } catch {
                // Subordinate to the recording: the model's own state carries
                // the failure for the UI, and the session goes on regardless.
                ErrorTrace.record(
                    "Summary model prefetch failed", error: error, category: "RecordingSession")
            }
        }
    }
}
