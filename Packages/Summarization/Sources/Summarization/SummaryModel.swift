//
//  SummaryModel.swift
//  Summarization
//
//  Owns the on-disk and in-memory lifecycle of the ONE model Echo summarizes
//  with: Qwen3.5 4B OptiQ 4-bit (~3.3 GB), through MLX.
//
//  The discipline this type exists to enforce: the weights are never resident
//  without work.
//
//  - Download is not load. `ensureDownloaded` puts ~3.3 GB on disk and no bytes
//    in RAM, which is what the eager first-launch fetch and the record-start
//    prefetch need; `ensureReady` does both, and only a summary the user set in
//    motion goes through it.
//  - Work is counted, not guessed. The idle release is armed only when the last
//    generation finishes and cancelled the instant new work arrives, so the
//    model stays warm across a burst — a regenerate, a quick follow-up — and is
//    never released while anything is in flight.
//  - `unload()` is public so the transcription pass can force the weights out
//    before it runs. That gate belongs to Recording; this exposes the means.
//
//  MLX has no memory ceiling. `memoryLimit` is a garbage-collection threshold,
//  not a cap, and exceeding it exits the process outright — so memory is
//  bounded by deciding what to admit, never by setting a limit. What can be
//  bounded is the buffer cache between generations, and `liveLoader` does that.
//
//  A pause is stored state, recorded before the transfer is cancelled, and
//  never a `CancellationError` read back afterwards: at the catch site the
//  watchdog's own cancel, a user pause and a torn connection are
//  indistinguishable. That ordering is why `state` can tell a pause from a
//  failure, and why the pause store is synchronous.
//

import EchoCore
import Foundation
import MLX
import MLXLLM
import ModelDelivery
import os

/// The summary model's lifecycle, as the UI reads it.
///
/// `ready` means "a complete snapshot is on disk", NOT "weights in memory":
/// loading is lazy and the weights come and go underneath a `ready` state.
public enum SummaryModelState: Equatable, Sendable {

    case notDownloaded

    /// An interrupted download left resumable files on disk — a quit
    /// mid-download — so the UI offers Resume rather than a from-scratch
    /// Download.
    ///
    /// Carries no byte figure on purpose. The only trustworthy count is the
    /// downloader's own fraction, which is absent at rest, and the recursive
    /// disk sum that used to fill this overflowed the total: it shipped
    /// "8.93 GB of 8.3 GB".
    case partiallyDownloaded

    /// The user deliberately paused the background download. Distinct from
    /// `partiallyDownloaded`, which is a crash-interrupted download that SHOULD
    /// auto-resume: a pause is a persisted intent the eager fetch must not
    /// silently override.
    case paused

    /// Fraction ∈ [0, 1], from the one clamp in `ModelDelivery`.
    case downloading(Double)

    case loading

    case ready

    case failed(String)

    /// Download or load in flight — the trigger buttons disable on this. A
    /// paused download is at rest, so its Resume affordance stays enabled.
    public var isBusy: Bool {
        switch self {
        case .downloading, .loading: return true
        case .notDownloaded, .partiallyDownloaded, .paused, .ready, .failed: return false
        }
    }
}

/// Produces an engine from an on-disk snapshot directory. The real one loads an
/// MLX container; a test fake returns a scripted engine and counts loads.
public typealias SummaryEngineLoader = @Sendable (_ directory: URL) async throws -> any TextGenerating

/// Transfers the snapshot to disk, reporting the byte-weighted fraction. The
/// real one drives `ModelDelivery`; a test fake counts transfers and flips a
/// flag without touching the network.
public typealias SummaryModelDownloader =
    @Sendable (_ progress: @escaping @Sendable (SnapshotDownloadPhase, Double) -> Void) async throws -> Void

public actor SummaryModel {

    static let log = Logger(subsystem: AppIdentity.logSubsystem, category: "SummaryModel")

    // MARK: - Identity

    /// The Hugging Face repo id. An on-disk contract, never a display string.
    public static let modelID = "mlx-community/Qwen3.5-4B-OptiQ-4bit"

    /// Human name for the models banner, and what a meeting's meta records as
    /// the model that wrote its summary.
    public static let modelDisplayName = "Qwen3.5 4B"

    /// Shown next to "Ready": the on-disk size of the text-path snapshot,
    /// measured from a complete download. Display string only — never a
    /// progress input.
    public static let modelDisplaySize = "3.3 GB"

    /// Idle window after the last generation before the ~3.3 GB of weights are
    /// released from RAM. Long enough to span a regenerate or a quick follow-up
    /// summary, short enough that the app returns to its light baseline soon
    /// after the user is done.
    public static let idleTimeout: Duration = .seconds(60)

    /// What delivery needs to know about this model.
    ///
    /// The two bookkeeping file names are v1's, verbatim, because v1 and v2
    /// share a data folder: an existing install already has a
    /// `summary-model-manifest.json` and a `summary-model-download/` beside its
    /// models tree, and invented names would orphan both and force a needless
    /// re-verification of 3.3 GB.
    ///
    /// The globs are disjoint, which the two transports require:
    /// `model.safetensors.index.json` is a config, not a weight. They also
    /// cannot match the bf16 sidecars the repo carries under `optiq/`
    /// (`mtp.safetensors`, `optiq_vision.safetensors`), which the text path
    /// neither downloads nor loads.
    public static let snapshotSpec = SnapshotSpec(
        repoID: modelID,
        weightGlobs: ["model*.safetensors"],
        configGlobs: ["*.json"],
        manifestFileName: "summary-model-manifest.json",
        partialDirectoryName: "summary-model-download"
    )

    // MARK: - State

    public private(set) var state: SummaryModelState = .notDownloaded

    private var engine: (any TextGenerating)?
    private var loadTask: Task<any TextGenerating, Error>?

    /// The one in-flight transfer, shared by every caller: a record-start
    /// prefetch and a post-stop `ensureReady` join the same download rather
    /// than racing two of them.
    private var downloadTask: Task<Void, Error>?

    /// Generations currently holding the engine. The idle release is armed only
    /// when this hits zero and cancelled the instant it leaves zero.
    private var workInFlight = 0

    private let loader: SummaryEngineLoader
    private let downloader: SummaryModelDownloader
    private let snapshotExistsCheck: @Sendable () -> Bool
    private let partialBytesCheck: @Sendable () -> Int64?
    private let scheduler: any IdleReleaseScheduling
    private let idleTimeout: Duration
    private let pauseStore: any DownloadPauseStore

    /// Where the snapshot lives. Held so `performLoad` can name the directory
    /// it hands the loader without rebuilding a downloader to ask.
    private let snapshotDirectory: URL

    /// `modelsRoot` and `pauseStateFile` are required rather than defaulted to
    /// the real data folder, for the reason `ModelDelivery` made them required:
    /// library code that can reach the user's real files on its own is a test
    /// that can delete them by forgetting an argument.
    ///
    /// Every other parameter defaults to the real MLX, delivery, disk and task
    /// implementations, so the lifecycle is testable without a 3.3 GB download,
    /// a Metal device or a real clock.
    public init(
        modelsRoot: URL,
        pauseStateFile: URL,
        loader: SummaryEngineLoader? = nil,
        downloader: SummaryModelDownloader? = nil,
        snapshotExists: (@Sendable () -> Bool)? = nil,
        partialBytes: (@Sendable () -> Int64?)? = nil,
        scheduler: (any IdleReleaseScheduling)? = nil,
        idleTimeout: Duration = SummaryModel.idleTimeout,
        pauseStore: (any DownloadPauseStore)? = nil
    ) {
        let delivery = SnapshotDownloader(modelsRoot: modelsRoot, spec: Self.snapshotSpec)
        self.snapshotDirectory = delivery.snapshotDirectory
        self.loader = loader ?? Self.liveLoader
        self.downloader =
            downloader ?? { progress in
                try await delivery.download(progress: progress)
            }
        self.snapshotExistsCheck = snapshotExists ?? { delivery.snapshotExists() }
        self.partialBytesCheck = partialBytes ?? { delivery.partialDownloadBytes() }
        self.scheduler = scheduler ?? TaskIdleReleaseScheduler()
        self.idleTimeout = idleTimeout
        self.pauseStore = pauseStore ?? FileDownloadPauseStore(fileURL: pauseStateFile)
    }

    // MARK: - At-rest state

    /// Resolve the at-rest state from disk. Cheap: a manifest read and, at
    /// most, a directory walk. Nothing is downloaded and nothing is loaded.
    ///
    /// Not done in `init`, because an initializer performs no side effects; the
    /// composition root calls this at launch. A busy state is left alone — an
    /// in-flight download's fraction is more truthful than anything on disk.
    ///
    /// Precedence is `ready` > `failed` > `paused` > `partiallyDownloaded`: a
    /// complete snapshot makes a stale pause or a stale error irrelevant, a
    /// failure the user has not acted on outlives a refresh, and a pause
    /// outranks the partial files it left behind, because the UI must offer
    /// Resume rather than silently auto-resuming.
    ///
    /// `failed` ranking above the at-rest answers is the non-obvious one. Disk
    /// cannot tell that the last attempt failed, so resolving from disk alone
    /// would replace the message and its Retry affordance with a bare "not
    /// downloaded" — and architecture section 7 puts an expected failure on this
    /// state precisely so the UI has copy to show and an action to offer. The
    /// notice clears when the user acts (`resumeDownload`, or a retry that
    /// succeeds) or when the snapshot turns out to be complete after all.
    public func refreshState() {
        guard !state.isBusy else { return }
        if snapshotExistsCheck() {
            state = .ready
            return
        }
        if case .failed = state { return }
        if pauseStore.isPaused {
            state = .paused
        } else {
            state = partialBytesCheck() != nil ? .partiallyDownloaded : .notDownloaded
        }
    }

    /// Whether a complete snapshot is already on disk — cheap enough to paint
    /// the UI without touching the network or loading weights.
    public func snapshotExists() -> Bool {
        snapshotExistsCheck()
    }

    /// Bytes an interrupted download already put on disk, or nil when there is
    /// nothing to resume.
    ///
    /// Consumed only as a boolean "is there something to resume". The number
    /// must never reach the UI: it sums staging alongside committed files and
    /// can exceed the committed total, so it cannot back a percentage or an
    /// "X of Y" readout.
    public func partialDownloadBytes() -> Int64? {
        guard !snapshotExistsCheck() else { return nil }
        return partialBytesCheck()
    }

    // MARK: - Work scope

    /// Runs `body` with a loaded engine, counted as active work so the idle
    /// release can neither fire during the generation nor be armed while one is
    /// in flight.
    ///
    /// `body` gets its OWN strong reference, so a concurrent release nil-ing
    /// this actor's reference cannot pull the engine out from under a running
    /// generation. The count is decremented on EVERY exit path — success,
    /// throw, early return, cancellation — through a synchronous `defer`, which
    /// is what makes the release un-missable.
    public func withEngine<T: Sendable>(
        _ body: @Sendable (any TextGenerating) async throws -> T
    ) async throws -> T {
        let engine = try await acquireEngine()
        defer { releaseEngine() }
        return try await body(engine)
    }

    /// Loads (or reuses) the engine and counts one unit of work, cancelling any
    /// pending idle release BEFORE the load so an in-flight release timer
    /// re-checks the now non-zero count and bails.
    ///
    /// Must be balanced by exactly one `releaseEngine()` — but only on success.
    /// A failed acquire decrements its own count here, so a caller must NOT
    /// release after a throw. Exposed alongside `withEngine` because a
    /// main-actor caller cannot put its body on this actor.
    public func acquireEngine() async throws -> any TextGenerating {
        workInFlight += 1
        scheduler.cancel()
        do {
            return try await ensureReady()
        } catch {
            // The load never produced usable work, so undo the count; a failed
            // acquire must not wedge the release forever. If this drops the
            // count to zero it arms a release of a nil engine, a harmless no-op.
            releaseEngine()
            throw error
        }
    }

    /// Ends one unit of work. When the last one finishes, arms the idle
    /// release; the weights stay resident until it fires, and even then only if
    /// still idle.
    public func releaseEngine() {
        guard workInFlight > 0 else { return }
        workInFlight -= 1
        guard workInFlight == 0 else { return }
        scheduler.arm(after: idleTimeout) { [weak self] in
            await self?.releaseIfIdle()
        }
    }

    /// The idle timer fired. Re-checked on the actor because a burst may have
    /// re-acquired between the timer elapsing and this re-entry, and the
    /// re-acquire's `cancel()` can lose that race with an already-elapsed
    /// timer. Work in flight is the guarantee; the cancellation is only the
    /// optimization.
    private func releaseIfIdle() {
        guard workInFlight == 0 else { return }
        unload()
    }

    // MARK: - Download and load

    /// Downloads once, then loads the container. Concurrent callers share one
    /// in-flight load; a failure clears it so the next call retries from
    /// scratch.
    ///
    /// Deliberately NOT gated on the pause: a summary the user set in motion
    /// still fetches the model it needs. `ensureDownloaded` is the one that
    /// honours a pause, and the two must not be unified for that reason.
    ///
    /// Loading here is not self-releasing — a caller doing work must come
    /// through `withEngine` or `acquireEngine` so the idle lifecycle can see it.
    public func ensureReady() async throws -> any TextGenerating {
        if let engine { return engine }
        if let loadTask { return try await loadTask.value }

        let task = Task<any TextGenerating, Error> { try await self.performLoad() }
        loadTask = task
        do {
            return try await task.value
        } catch {
            loadTask = nil
            throw error
        }
    }

    /// Downloads the snapshot if it is not already complete, WITHOUT loading
    /// the weights — the eager first-launch fetch and the record-start
    /// prefetch, neither of which may put 3.3 GB in RAM while a recording or a
    /// transcription pass is running.
    ///
    /// Honours a paused intent, and does so persistently: the store is a file,
    /// so a quit while paused is still paused on the next launch. Joins any
    /// in-flight download, and no-ops once the snapshot (or the engine) exists.
    public func ensureDownloaded() async throws {
        if engine != nil { return }
        if pauseStore.isPaused { return }
        try await downloadIfNeeded()
    }

    private func performLoad() async throws -> any TextGenerating {
        try await downloadIfNeeded()

        state = .loading
        do {
            let engine = try await loader(snapshotDirectory)
            self.engine = engine
            state = .ready
            Self.log.info("Summary model loaded (\(Self.modelID, privacy: .public))")
            return engine
        } catch {
            let failure = SummaryModelError.loadFailed(error.localizedDescription)
            state = .failed(failure.localizedDescription)
            ErrorTrace.record("Summary model load failed", error: error, category: "SummaryModel")
            throw failure
        }
    }

    /// Runs, or joins, the snapshot download.
    ///
    /// A joiner's own progress stays silent: the in-flight transfer keeps
    /// reporting into `state`, which every caller reads anyway.
    private func downloadIfNeeded() async throws {
        // Already complete: say so rather than leaving whatever stale state was
        // there, so a caller that never called `refreshState` is not told the
        // model is missing while it sits on disk.
        if snapshotExistsCheck() {
            state = .ready
            return
        }
        if let downloadTask { return try await downloadTask.value }

        // Captured locally so the unstructured task does not reach back into
        // actor-isolated storage.
        let downloader = self.downloader
        state = .downloading(0)
        let task = Task<Void, Error> {
            try await downloader { phase, fraction in
                Task { await self.noteDownloadProgress(phase: phase, fraction: fraction) }
            }
        }
        downloadTask = task
        defer { downloadTask = nil }
        do {
            try await task.value
        } catch {
            // A pause and a failure arrive identically here, which is exactly
            // why the intent was written down before the cancel. `isPaused`
            // already answers truthfully, so a real failure can never be
            // swallowed as a pause, nor a pause reported as one.
            if pauseStore.isPaused {
                state = .paused
            } else {
                let failure = SummaryModelError.downloadFailed(error.localizedDescription)
                state = .failed(failure.localizedDescription)
                ErrorTrace.record(
                    "Summary model download failed", error: error, category: "SummaryModel")
            }
            throw error
        }
        // Verify from disk rather than trusting the transfer's return value.
        state = snapshotExistsCheck() ? .ready : .failed("The downloaded model files did not verify.")
    }

    private func noteDownloadProgress(phase: SnapshotDownloadPhase, fraction: Double) {
        // Only forward, and only while downloading: a straggler from a
        // cancelled attempt must neither rewind the bar nor resurrect a final
        // state. The phase is carried for the UI's copy, not stored — a retry
        // is not a different state, it is the same download still trying.
        guard case .downloading(let current) = state else { return }
        _ = phase
        guard fraction > current else { return }
        state = .downloading(fraction)
    }

    // MARK: - Pause and resume

    /// Whether the user paused the background download. Persisted, so it
    /// answers truthfully on a fresh launch too — which is what stops the eager
    /// launch fetch from silently resuming a pause across a quit.
    public var isDownloadPaused: Bool { pauseStore.isPaused }

    /// Pauses the background download.
    ///
    /// Records the intent BEFORE cancelling the transfer, so by the time a
    /// joined awaiter sees the `CancellationError`, `isDownloadPaused` is
    /// already true. Completed files stay on disk and a later resume continues
    /// from them rather than re-fetching gigabytes.
    public func pauseDownload() {
        pauseStore.setPaused(true)
        downloadTask?.cancel()
        // A pause with the snapshot already complete changes nothing a user
        // should see: the model is ready, and only an unfinished download has a
        // pause to show.
        if !snapshotExistsCheck() { state = .paused }
    }

    /// Clears the paused intent. The caller re-runs `ensureDownloaded`, which
    /// resumes from the files already on disk.
    ///
    /// Resuming IS the user acting on a failure, so a failure notice is dropped
    /// here — this is the one place besides a completed snapshot that clears
    /// one. `refreshState` deliberately preserves it, so without this a user
    /// who hit Resume after a failed attempt would keep staring at the old
    /// error until the next transfer overwrote it.
    public func resumeDownload() {
        pauseStore.setPaused(false)
        if case .failed = state { state = .notDownloaded }
        refreshState()
    }

    // MARK: - Unload

    /// Releases the loaded container's RAM.
    ///
    /// Public because Recording forces it before every transcription pass: two
    /// multi-GB models must not be resident at once. Does NOT change `state` —
    /// the snapshot is still on disk, so the model is still `ready`. Clearing
    /// `loadTask` means the next `ensureReady` reloads from disk.
    public func unload() {
        engine = nil
        loadTask = nil
    }

    // MARK: - Live seams

    /// The real MLX load.
    ///
    /// Bounds the buffer cache so idle memory between generations stays small
    /// relative to the 4B weights. This is not a memory ceiling — none exists —
    /// it is the one thing about MLX's memory that CAN be bounded, and it is set
    /// on every load because it is a global.
    ///
    /// 20 MB is the measured value and is carried unchanged; only the spelling
    /// moved. `GPU.set(cacheLimit:)`, which the PoC calls, is deprecated in
    /// mlx-swift 0.31.6 in favour of this property, and is implemented as a
    /// one-line forwarder to it — so this is the same call, without the warning.
    static let liveLoader: SummaryEngineLoader = { directory in
        MLX.Memory.cacheLimit = 20 * 1024 * 1024
        let container = try await LLMModelFactory.shared.loadContainer(
            from: directory,
            using: SummaryTokenizerLoader()
        )
        return MLXTextEngine(container: container)
    }
}

/// What the model's lifecycle throws. Transport failures arrive as
/// `ModelDeliveryError` and are not re-wrapped: that package owns the disk
/// floor, the stall and the integrity check, and owns their copy too.
public enum SummaryModelError: Error, LocalizedError, Equatable {
    case downloadFailed(String)
    case loadFailed(String)

    public var errorDescription: String? {
        switch self {
        case .downloadFailed(let message):
            return "Could not download the summary model: \(message)"
        case .loadFailed(let message):
            return "Could not load the summary model: \(message)"
        }
    }
}
