//
//  SummaryModelManager.swift
//  Echo
//
//  Downloads (once), caches, and loads the summary LLM. The snapshot lives
//  under EchoPaths.modelsDirectory — a user-level path shared by all
//  worktrees and app relaunches, so the ~3.3 GB download happens exactly one
//  time. Loading produces a TextGenerating engine backed by MLX (in-process;
//  no server subprocess, no HTTP, no Homebrew).
//
//  Memory lifecycle (ADR-008): the ~3.3 GB weights are brought into RAM only
//  for active summary work and released after a short idle timeout — never
//  merely because the download finished or the app launched. `withEngine`
//  (or the `acquireEngine`/`releaseEngine` pair it wraps) counts work in
//  flight; the release is armed only when that count hits zero, cancelled the
//  moment new work arrives, and re-checked on the actor before it lands so it
//  can never interrupt a generation or force a redundant reload mid-burst.
//
//  The load, download, snapshot-check, and idle-release steps are all behind
//  injectable seams (defaulted to the real MLX / HubApi / disk / Task
//  implementations) so the lifecycle is unit-testable without real MLX,
//  network, or clock (SP-003 Testing Decisions, layer 3). Production call
//  sites construct `SummaryModelManager()` unchanged.
//

import CryptoKit
import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import Hub
import Tokenizers
import os

/// Observable-friendly snapshot of the summary model's lifecycle, consumed by
/// the dashboard's model control. `ready` means "snapshot on disk", not
/// "weights in memory" — loading happens lazily on first generation.
enum SummaryModelState: Equatable {
    case notDownloaded
    /// An interrupted download left resumable files on disk (a quit
    /// mid-download), so the UI offers "Resume" instead of a from-scratch
    /// "Download". Carries no byte figure: the only trustworthy count is the
    /// downloader's own fraction, absent at rest, and the recursive disk sum
    /// that used to fill this overflowed the total ("8.93 GB of 8.3 GB") — see
    /// ADR-007.
    case partiallyDownloaded
    /// The user deliberately paused the background download (SP-003 US-10).
    /// Distinct from `.partiallyDownloaded` (a crash-interrupted download that
    /// SHOULD auto-resume): a pause is a persisted intent the eager/launch
    /// download must NOT silently override, so the UI shows "Paused · Resume"
    /// and the background fetch leaves it alone until the user resumes.
    case paused
    case downloading(Double)   // fraction ∈ [0, 1]
    case loading
    case ready
    case failed(String)

    /// Download/load in flight — the trigger buttons disable on this. A paused
    /// download is at rest (its Resume affordance must stay enabled).
    var isBusy: Bool {
        switch self {
        case .downloading, .loading: return true
        case .notDownloaded, .partiallyDownloaded, .paused, .ready, .failed: return false
        }
    }
}

actor SummaryModelManager {

    static let log = Logger(subsystem: "com.sancrisoft.Echo", category: "SummaryModelManager")

    static let modelID = "mlx-community/Qwen3.5-4B-OptiQ-4bit"
    /// Human name for the models banner ("which model is this and why").
    static let modelDisplayName = "Qwen3.5 4B"
    /// Shown next to "Ready" in the UI; the on-disk size of the text-path
    /// snapshot (a single weight file + configs + tokenizer), measured from a
    /// complete download. Display string only — never a progress input (ADR-007).
    static let modelDisplaySize = "3.3 GB"

    /// Idle window after the last summary generation before the ~3.3 GB weights
    /// are released from RAM (ADR-008). Provisional starting value for SP-003
    /// open question 2: long enough to span a regenerate or a quick follow-up
    /// summary (the model stays warm across a burst), short enough that the app
    /// returns to its light baseline soon after the user is done. Tuned later
    /// against the manual RSS measurements (SP-003 open question 4).
    static let summaryModelIdleTimeout: Duration = .seconds(60)

    /// The weight files, which Echo transfers itself: they are the ones big
    /// enough that the Hub client's broken progress reporting turns into a
    /// guaranteed false stall, and the ones worth resuming byte-exactly
    /// (see ResumableFileDownload). Glob, not a filename: a resharded repo
    /// publishes `model-00001-of-0000N.safetensors` and this keeps matching.
    private static let weightGlobs = ["model*.safetensors"]

    /// Everything else — configs and tokenizer — which stays with
    /// HubApi.snapshot. Small enough that its files-finished progress is
    /// accurate to within its own 0.6% of the bytes, and Hub keeps owning
    /// their etag/metadata bookkeeping.
    private static let configGlobs = ["*.json"]

    /// Every file the snapshot is made of, and so what the completeness
    /// manifest records (ADR-012). The repo also carries bf16 sidecars under
    /// optiq/ (mtp.safetensors and optiq_vision.safetensors) that the text path
    /// neither downloads nor loads: these globs match the weight file
    /// (`model.safetensors`) and the top-level configs/tokenizer, and cannot
    /// match anything under optiq/. The two transports' globs are disjoint —
    /// `model.safetensors.index.json` is a config, not a weight file.
    private static let downloadGlobs = weightGlobs + configGlobs

    /// Free-disk floor for starting the download. The retired 12B's 15 GB
    /// floor gave its ~8.9 GB snapshot roughly 1.7× headroom (fetch plus Hub
    /// staging); this is the same ratio applied to the new ~3.3 GB download.
    /// Rescaled deliberately: a floor still sized for the 12B would block the
    /// ~3.3 GB migration on exactly the full disks it is about to relieve
    /// (SP-004 story 18).
    private static let minimumFreeDiskBytes: Int64 = 6 * 1_000_000_000

    private var engine: (any TextGenerating)?
    private var loadTask: Task<any TextGenerating, Error>?
    /// The one in-flight snapshot download, shared by every caller: the
    /// recording-start prefetch and a post-stop `ensureReady` must join the
    /// same transfer, never race two of them.
    private var downloadTask: Task<Void, Error>?

    /// Number of summary generations currently holding the engine. The idle
    /// release is armed only when this hits zero and cancelled the instant it
    /// leaves zero (ADR-008), so the model is kept warm across a burst and is
    /// never released while work is in flight or queued.
    private var workInFlight = 0

    // Injectable seams (defaulted to the real implementations). See the file
    // header: these let the lifecycle be tested without MLX / network / disk /
    // a real clock while production stays `SummaryModelManager()`.
    private let loader: EngineLoader
    private let downloader: SnapshotDownloader
    private let snapshotExistsCheck: @Sendable () -> Bool
    private let scheduler: any IdleReleaseScheduling
    private let idleTimeout: Duration
    /// Persists the user's pause/resume intent for the background download
    /// (SP-003 US-10). A real file in production; an in-memory fake under test.
    private let pauseStore: DownloadPauseStore

    /// Designated initializer. All parameters default to the real MLX / HubApi /
    /// disk / Task-based implementations, so production call sites remain
    /// `SummaryModelManager()`; tests inject counting fakes, a manual release
    /// scheduler, and an in-memory pause store.
    init(
        loader: @escaping EngineLoader = SummaryModelManager.liveLoader,
        downloader: @escaping SnapshotDownloader = SummaryModelManager.liveDownloader,
        snapshotExists: @escaping @Sendable () -> Bool = SummaryModelManager.liveSnapshotExists,
        scheduler: any IdleReleaseScheduling = TaskIdleReleaseScheduler(),
        idleTimeout: Duration = SummaryModelManager.summaryModelIdleTimeout,
        pauseStore: DownloadPauseStore = FileDownloadPauseStore()
    ) {
        self.loader = loader
        self.downloader = downloader
        self.snapshotExistsCheck = snapshotExists
        self.scheduler = scheduler
        self.idleTimeout = idleTimeout
        self.pauseStore = pauseStore
    }

    // MARK: - Work scope (ADR-008 lifecycle)

    /// Runs `body` with a loaded engine, counting it as active summary work so
    /// the idle release can neither fire during the generation nor be armed
    /// while it is in flight. Loads via `ensureReady` (a warm engine is reused);
    /// `body` gets its OWN strong reference to the engine, so a concurrent
    /// release nil-ing the manager's reference cannot pull it out from under an
    /// active generation. The in-flight count is decremented on EVERY exit path
    /// — success, throw, early `return`, cancellation — via a synchronous
    /// `defer`, making the release un-missable.
    ///
    /// The main-actor `RecordingController` cannot use this directly (its body
    /// touches main-actor state and would have to run on this actor); it calls
    /// `acquireEngine`/`releaseEngine` through its own do/catch wrapper instead.
    /// This scope is the same discipline exercised by the lifecycle tests.
    func withEngine<T: Sendable>(
        progress: @Sendable @escaping (String, Double) -> Void,
        _ body: @Sendable (any TextGenerating) async throws -> T
    ) async throws -> T {
        let engine = try await acquireEngine(progress: progress)
        defer { releaseEngine() }
        return try await body(engine)
    }

    /// Loads (or reuses) the engine and counts one unit of active work,
    /// cancelling any pending idle release BEFORE the load so a release timer
    /// mid-flight re-checks the (now non-zero) work count and bails. MUST be
    /// balanced by exactly one `releaseEngine()` — but only on success: a failed
    /// acquire decrements its own count here, so the caller must NOT release
    /// after a throw.
    func acquireEngine(
        progress: @Sendable @escaping (String, Double) -> Void
    ) async throws -> any TextGenerating {
        workInFlight += 1
        scheduler.cancel()
        do {
            return try await ensureReady(progress: progress)
        } catch {
            // The load never produced usable work; undo the count so a failed
            // acquire can't wedge the release forever. (If this drops the count
            // to zero it arms a release of a nil engine — a harmless no-op.)
            releaseEngine()
            throw error
        }
    }

    /// Ends one unit of active work. When the last one finishes, arms the idle
    /// release; the model stays resident until it fires (and even then only if
    /// still idle).
    func releaseEngine() {
        guard workInFlight > 0 else { return }
        workInFlight -= 1
        guard workInFlight == 0 else { return }
        scheduler.arm(after: idleTimeout) { [weak self] in
            await self?.releaseIfIdle()
        }
    }

    /// The idle timer fired. Re-check on the actor: a burst may have re-acquired
    /// between the timer elapsing and this re-entry, and the re-acquire's
    /// `scheduler.cancel()` can lose that race with an already-elapsed timer.
    /// Work-in-flight is the guarantee here; the cancellation is only the
    /// optimization (ADR-008).
    private func releaseIfIdle() {
        guard workInFlight == 0 else { return }
        unload()
    }

    // MARK: - Load / download

    /// Downloads (once) + loads the MLX container. Progress ∈ [0, 1] with a
    /// phase label ("Downloading summary model…" / "Loading summary model…").
    /// Concurrent callers share one in-flight load; a failure clears it so the
    /// next call retries from scratch. Loading here is NOT self-releasing —
    /// active-work callers must go through `withEngine`/`acquireEngine` so the
    /// idle lifecycle can track them.
    func ensureReady(
        progress: @Sendable @escaping (String, Double) -> Void
    ) async throws -> any TextGenerating {
        if let engine { return engine }
        if let loadTask { return try await loadTask.value }

        let task = Task<any TextGenerating, Error> {
            try await performLoad(progress: progress)
        }
        loadTask = task
        do {
            let engine = try await task.value
            return engine
        } catch {
            loadTask = nil
            throw error
        }
    }

    /// Downloads the snapshot if it isn't complete on disk WITHOUT loading the
    /// weights — the eager first-launch download and the recording-start
    /// prefetch, which must never put the 4B weights in memory while Whisper is
    /// transcribing live. Joins any in-flight download; a no-op once the
    /// snapshot (or the engine) exists.
    func ensureDownloaded(
        progress: @Sendable @escaping (String, Double) -> Void
    ) async throws {
        if engine != nil { return }
        // A user-paused download must not be silently resumed by the eager
        // background fetch or the record-start prefetch — the intent is
        // persisted, so this holds on the next launch too (SP-003 US-10). An
        // explicit summary generation runs through `ensureReady` →
        // `downloadIfNeeded`, which is deliberately NOT gated here: a summary
        // the user set in motion still fetches the model it needs.
        if pauseStore.isPaused { return }
        try await downloadIfNeeded(progress: progress)
    }

    // MARK: - Pause / resume (SP-003 US-10)

    /// Whether the user paused the background summary download. Persisted, so it
    /// answers truthfully on a fresh launch too — which is what stops the eager
    /// launch download from silently resuming a pause across a quit.
    var isDownloadPaused: Bool { pauseStore.isPaused }

    /// Pauses the background download. Records the intent (persisted) BEFORE
    /// cancelling the in-flight transfer, so a joined awaiter's `catch` can tell
    /// this cancellation from a real failure — `isDownloadPaused` is already
    /// true by the time the `CancellationError` propagates (SP-003: cancel ≠
    /// failure). Completed shards stay on disk; a later resume re-runs the
    /// download and the snapshot skips whatever is already complete (no
    /// multi-GB re-fetch).
    func pauseDownload() {
        pauseStore.setPaused(true)
        downloadTask?.cancel()
    }

    /// Clears the paused intent so the download may run again. The caller
    /// re-runs `ensureDownloaded` (the single shared transfer), which resumes
    /// from the files already on disk rather than restarting from zero.
    func resumeDownload() {
        pauseStore.setPaused(false)
    }

    /// Whether a complete snapshot is already on disk — cheap enough to paint
    /// the UI state without touching the network or loading weights. Delegates
    /// to the injected check (manifest ∧ files-on-disk in production, ADR-012).
    func cachedModelExists() -> Bool {
        snapshotExistsCheck()
    }

    /// Bytes an interrupted download already put on disk (complete files, the
    /// Hub's resumable `*.incomplete` staging under `.cache/`, and Echo's own
    /// `.partial` weight transfers), or nil when nothing is there. Consumed
    /// only as a boolean "is there a resumable partial" signal — the number
    /// itself must never reach the UI: it sums staging alongside committed
    /// files and can exceed the committed total, so it cannot back a percentage
    /// or an "X of Y" readout (ADR-007). A resumed download continues from
    /// whatever is already on disk regardless.
    func partialDownloadBytes() -> Int64? {
        guard !cachedModelExists() else { return nil }
        let total = Self.byteCount(under: Self.snapshotDirectory)
            + Self.byteCount(under: Self.partialDownloadDirectory)
        return total > 0 ? total : nil
    }

    /// Recursive byte sum of the regular files under `directory`; 0 when it
    /// doesn't exist.
    private static func byteCount(under directory: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]
        ) else { return 0 }

        var total: Int64 = 0
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true else { continue }
            total += Int64(values.fileSize ?? 0)
        }
        return total
    }

    /// Releases the loaded container's RAM. Wired behind the idle timer
    /// (ADR-008): called from `releaseIfIdle` once work has been idle for the
    /// timeout, and reserved for failure recovery. Releases RAM only — it does
    /// NOT change the dashboard's `SummaryModelState` (the snapshot is still on
    /// disk, so the model is still "ready"); clearing `loadTask` means the next
    /// `ensureReady` reloads from disk.
    func unload() {
        engine = nil
        loadTask = nil
    }

    // MARK: - Load

    private func performLoad(
        progress: @Sendable @escaping (String, Double) -> Void
    ) async throws -> any TextGenerating {
        let directory = Self.snapshotDirectory

        try await downloadIfNeeded(progress: progress)

        progress("Loading summary model…", 1)
        do {
            let engine = try await loader(directory)
            self.engine = engine
            Self.log.info("Summary model loaded from \(directory.path, privacy: .public)")
            return engine
        } catch {
            throw SummaryModelError.loadFailed(error.localizedDescription)
        }
    }

    // MARK: - Download

    /// Runs (or joins) the snapshot download. A joiner's own `progress`
    /// closure stays silent — the in-flight download keeps reporting through
    /// the closure it started with, and every caller funnels into the same
    /// controller-side state anyway.
    private func downloadIfNeeded(
        progress: @Sendable @escaping (String, Double) -> Void
    ) async throws {
        if snapshotExistsCheck() { return }
        if let downloadTask { return try await downloadTask.value }

        // Capture the (immutable, Sendable) downloader locally so the detached
        // Task doesn't reach back into actor-isolated storage.
        let downloader = self.downloader
        let task = Task<Void, Error> { try await downloader(progress) }
        downloadTask = task
        defer { downloadTask = nil }
        try await task.value
    }

    // MARK: - Live seams (real MLX / HubApi / disk)

    /// The real MLX load: bounds the buffer cache so idle memory between
    /// generations stays small relative to the 4B weights, loads the
    /// container, and wraps it in the streaming engine.
    static let liveLoader: EngineLoader = { directory in
        MLX.GPU.set(cacheLimit: 20 * 1024 * 1024)
        let container = try await LLMModelFactory.shared.loadContainer(
            from: directory,
            using: EchoTokenizerLoader()
        )
        return MLXTextEngine(container: container)
    }

    /// The real snapshot download (byte-honest progress + stall-retry), plus
    /// the completeness manifest recorded at completion (ADR-012) — part of the
    /// downloader seam so test fakes stand in for both halves at once.
    static let liveDownloader: SnapshotDownloader = { progress in
        try SummaryModelManager.checkDiskSpace()
        progress("Downloading summary model…", 0)
        let hub = SummaryModelManager.hub
        let repo = HubApi.Repo(id: SummaryModelManager.modelID)
        // The bar must not snap back to zero on a stall retry — remember the
        // fraction the download actually reached (callbacks arrive on
        // URLSession worker threads, hence the lock).
        let reached = LockedFraction()
        do {
            // Stall watchdog + retry: a download that stops moving BYTES is
            // cancelled and re-run, resuming from the bytes already on disk.
            // The heartbeat is byte-derived on purpose — fed the Hub client's
            // own fraction, this watchdog killed every healthy multi-GB
            // transfer at the 60 s mark (see ResumableFileDownload).
            _ = try await ModelDownload.withStallRetry(
                onRetry: { attempt in
                    log.warning("Summary model download stalled; retrying (attempt \(attempt, privacy: .public))")
                    progress("Download stalled — retrying…", reached.value)
                }
            ) { noteProgress in
                try await SummaryModelManager.transferSnapshot(hub: hub, repo: repo) { fraction in
                    noteProgress(fraction)
                    reached.update(fraction)
                    progress("Downloading summary model…", fraction)
                }
            }
        } catch is CancellationError {
            // A pause (or the watchdog's own cancel) is not a failure: the
            // partial stays on disk and the resume continues from it. Leaving
            // through the cancellation path keeps `downloadIfNeeded`'s joiners
            // able to tell a pause from a broken download.
            throw CancellationError()
        } catch {
            throw SummaryModelError.downloadFailed(error.localizedDescription)
        }

        // A pause cancels the download task, and the Hub snapshot then
        // RETURNS early between files instead of throwing — never record a
        // manifest for a transfer that didn't finish; completeness stays
        // honestly incomplete and the resume re-enters here.
        if Task.isCancelled { return }

        // Record what "complete" means for this snapshot (ADR-012): the file
        // set the downloader itself resolves — getFilenames(matching:) is the
        // exact resolution hub.snapshot ran on, so no repo layout fact lives
        // in code. Resolved against the repo (not a directory listing) on
        // purpose: a listing measures what arrived, not what the load needs,
        // and would bless a snapshot whose stale staging metadata let a file
        // go missing. Verify-then-write keeps a recorded manifest meaning "a
        // download genuinely completed here".
        do {
            let resolved = try await hub.getFilenames(
                from: repo,
                matching: SummaryModelManager.downloadGlobs
            )
            let manifest = SnapshotManifest(
                modelID: SummaryModelManager.modelID,
                files: resolved.sorted()
            )
            guard manifest.allFilesCommitted(in: SummaryModelManager.snapshotDirectory) else {
                throw SnapshotVerificationFailed()
            }
            try manifest.write(to: SummaryModelManager.manifestFileURL)
            // The transfers were moved into the snapshot, so what's left here is
            // at most an empty directory — or a `.partial` for a file this
            // snapshot no longer contains (a model swap mid-download). Either
            // way it is dead weight the moment completeness is recorded.
            try? FileManager.default.removeItem(at: SummaryModelManager.partialDownloadDirectory)
        } catch {
            // Fail-safe direction: no manifest was recorded, so the snapshot
            // keeps reading incomplete and a retry re-verifies cheaply (the
            // Hub skips files already on disk).
            throw SummaryModelError.downloadFailed(error.localizedDescription)
        }
    }

    /// The snapshot pass returned but a resolved file is still missing on
    /// disk — observed once with stale staging metadata after an interrupted
    /// download. Retrying is cheap (complete files are skipped) and heals it.
    private struct SnapshotVerificationFailed: LocalizedError {
        var errorDescription: String? {
            "The downloaded model files did not pass verification. Retry to resume the download."
        }
    }

    /// The repo answered without the size/etag/location a transfer needs. Its
    /// own error rather than a crash on a force-unwrap: the recovery is a
    /// retry, and the message has to say which file.
    private struct MissingFileMetadata: LocalizedError {
        let file: String
        var errorDescription: String? {
            "The model server did not describe \(file). Retry the download."
        }
    }

    /// A committed file's bytes don't hash to the sha256 the repo published for
    /// it. Nothing is recorded and the file is dropped, so the next attempt
    /// re-fetches it rather than handing MLX a corrupt tensor file.
    private struct IntegrityCheckFailed: LocalizedError {
        let file: String
        var errorDescription: String? {
            "\(file) did not match its published checksum and was discarded. Retry the download."
        }
    }

    // MARK: - The two-transport transfer

    /// Fetches the snapshot: the small files through HubApi, the weight files
    /// through Echo's own resumable transfer, reporting ONE byte-weighted
    /// fraction across both (`SnapshotDownloadTally`).
    ///
    /// Re-resolves repo metadata on every attempt, by design: the `location` a
    /// HEAD returns for an LFS file is a signed CDN URL that expires, so a
    /// stall retry an hour into a slow download needs a fresh one. The HEADs
    /// cost one request per file against a transfer measured in gigabytes.
    private static func transferSnapshot(
        hub: HubApi,
        repo: HubApi.Repo,
        report: @Sendable @escaping (Double) -> Void
    ) async throws {
        let weightNames = try await hub.getFilenames(from: repo, matching: weightGlobs)
        var weights: [(name: String, metadata: HubApi.FileMetadata)] = []
        for name in weightNames {
            guard let metadata = try await hub.getFileMetadata(from: repo, matching: [name]).first else {
                throw MissingFileMetadata(file: name)
            }
            weights.append((name, metadata))
        }

        let configBytes = try await hub.getFileMetadata(from: repo, matching: configGlobs)
            .reduce(Int64(0)) { $0 + Int64($1.size ?? 0) }
        let budget = SnapshotDownloadBudget(
            configBytes: configBytes,
            weightBytes: weights.reduce(Int64(0)) { $0 + Int64($1.metadata.size ?? 0) }
        )
        // Weight bytes an earlier attempt already committed: counted from the
        // start so a resumed download's bar continues instead of restarting.
        let alreadyCommitted = weights.reduce(Int64(0)) { total, weight in
            total + ResumableFileDownload.byteCount(at: snapshotDirectory.appending(path: weight.name))
        }
        let tally = SnapshotDownloadTally(budget: budget, committedWeightBytes: alreadyCommitted)
        report(tally.fraction)

        // The small files first: quick, and it gets the tokenizer/configs on
        // disk early so a snapshot interrupted mid-weights is one file from
        // complete. Hub skips whatever is already committed.
        _ = try await hub.snapshot(from: repo, matching: configGlobs) { snapshotProgress in
            report(tally.noteConfigFraction(snapshotProgress.fractionCompleted))
        }
        report(tally.noteConfigFraction(1))

        for weight in weights {
            try Task.checkCancellation()
            let destination = snapshotDirectory.appending(path: weight.name)
            let expected = weight.metadata.size.map(Int64.init)

            // Already committed at the published size: leave it alone (this is
            // what makes a re-run after a partial snapshot cheap) but make sure
            // the Hub sidecar is there, since a file Echo wrote is otherwise
            // invisible to the Hub's own resume bookkeeping.
            if let expected, ResumableFileDownload.byteCount(at: destination) == expected {
                try writeHubSidecar(for: weight.name, metadata: weight.metadata)
                report(tally.commitWeightFile(bytes: expected))
                continue
            }

            guard let location = URL(string: weight.metadata.location) else {
                throw MissingFileMetadata(file: weight.name)
            }
            let partial = partialFileURL(for: weight.name)
            let bytes = try await ResumableFileDownload.fetch(
                from: location,
                expectedBytes: expected,
                into: partial,
                progress: { report(tally.noteWeightBytes($0)) }
            )
            try commitWeightFile(
                at: partial,
                to: destination,
                name: weight.name,
                metadata: weight.metadata
            )
            report(tally.commitWeightFile(bytes: bytes))
        }
    }

    /// Moves a completed transfer into the snapshot directory, verifying it
    /// first. For LFS files the Hub's etag IS the sha256 of the content
    /// (measured against a file the Hub itself downloaded), so this is a real
    /// end-to-end integrity check on a resumed, range-stitched transfer — the
    /// one place a silent corruption could otherwise enter the snapshot.
    private static func commitWeightFile(
        at partial: URL,
        to destination: URL,
        name: String,
        metadata: HubApi.FileMetadata
    ) throws {
        if let etag = metadata.etag, isSHA256(etag) {
            guard try sha256Hex(of: partial) == etag else {
                try? FileManager.default.removeItem(at: partial)
                throw IntegrityCheckFailed(file: name)
            }
        }

        let fm = FileManager.default
        try fm.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if fm.fileExists(atPath: destination.path) {
            try fm.removeItem(at: destination)
        }
        try fm.moveItem(at: partial, to: destination)
        try writeHubSidecar(for: name, metadata: metadata)
    }

    /// Writes the `.metadata` sidecar HubApi keeps for every file it manages
    /// (`commitHash\netag\ntimestamp`), so a file Echo transferred is
    /// indistinguishable from one the Hub fetched: its download pass returns
    /// early on the etag match instead of re-fetching, and its offline pass
    /// stops rejecting the repo directory for a file without a sidecar.
    private static func writeHubSidecar(for name: String, metadata: HubApi.FileMetadata) throws {
        guard let commitHash = metadata.commitHash, let etag = metadata.etag else { return }
        let sidecar = snapshotDirectory
            .appending(path: ".cache", directoryHint: .isDirectory)
            .appending(path: "huggingface", directoryHint: .isDirectory)
            .appending(path: "download", directoryHint: .isDirectory)
            .appending(path: name + ".metadata", directoryHint: .notDirectory)
        try FileManager.default.createDirectory(
            at: sidecar.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let contents = "\(commitHash)\n\(etag)\n\(Date().timeIntervalSince1970)\n"
        try contents.write(to: sidecar, atomically: true, encoding: .utf8)
    }

    /// Where an in-flight transfer accumulates. Beside the models tree rather
    /// than inside the snapshot directory, for the same reason the completeness
    /// manifest lives there: HubApi's offline pass validates every file it finds
    /// in the repo directory and would reject a `.partial` it never wrote.
    private static func partialFileURL(for name: String) -> URL {
        EchoPaths.modelsDirectory
            .appending(path: "summary-model-download", directoryHint: .isDirectory)
            .appending(path: name + ".partial", directoryHint: .notDirectory)
    }

    /// Directory holding in-flight `.partial` files, consulted by the
    /// "is there something resumable" check.
    static var partialDownloadDirectory: URL {
        EchoPaths.modelsDirectory
            .appending(path: "summary-model-download", directoryHint: .isDirectory)
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy(\.isHexDigit)
    }

    /// Streamed so a 3 GB file is hashed without being held in memory.
    private static func sha256Hex(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 4 * 1024 * 1024), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// The real on-disk snapshot check: manifest ∧ files-on-disk (ADR-012).
    /// Layout-agnostic (no hardcoded file list, no sharding-index parse) and
    /// offline — Echo never needs the network to know it already has the
    /// model. A snapshot predating the manifest mechanism reads incomplete
    /// until the next online pass no-ops per committed file and records one.
    static let liveSnapshotExists: @Sendable () -> Bool = {
        SnapshotManifest.snapshotComplete(
            forModelID: modelID,
            in: snapshotDirectory,
            manifestAt: manifestFileURL
        )
    }

    private final class LockedFraction: @unchecked Sendable {
        private let lock = NSLock()
        private var fraction: Double = 0

        func update(_ new: Double) {
            lock.lock()
            defer { lock.unlock() }
            fraction = max(fraction, new)
        }

        var value: Double {
            lock.lock()
            defer { lock.unlock() }
            return fraction
        }
    }

    // MARK: - Paths & validation

    /// The Hub client every path here shares. `cache: nil` is mandatory, not
    /// a preference: the default `HubCache.default` stores request caches
    /// OUTSIDE the app's data folder, and everything Echo writes must stay
    /// under ~/Library/Application Support/Echo. `hfToken` stays nil so auth
    /// resolves from the environment (unset here) rather than a stale token.
    nonisolated static var hub: HubApi {
        HubApi(downloadBase: EchoPaths.modelsDirectory, cache: nil)
    }

    /// downloadBase/models/<org>/<repo> — HubApi's snapshot layout.
    private static var snapshotDirectory: URL {
        hub.localRepoLocation(HubApi.Repo(id: modelID))
    }

    /// Where the completeness manifest lives (ADR-012): beside the models
    /// tree, NOT inside the Hub-managed snapshot directory — HubApi's
    /// offline-mode snapshot pass validates every repo file matching the
    /// download globs and fails on one without a `.metadata` sidecar, so a
    /// foreign JSON planted in the repo directory would poison offline
    /// resume. One file, scoped to the model by the record's own modelID: a
    /// model swap makes the old record read as absent, and the new model's
    /// first completed download supersedes it.
    private static var manifestFileURL: URL {
        EchoPaths.modelsDirectory
            .appending(path: "summary-model-manifest.json", directoryHint: .notDirectory)
    }

    private static func checkDiskSpace() throws {
        let values = try? EchoPaths.modelsDirectory.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]
        )
        guard let free = values?.volumeAvailableCapacityForImportantUsage else { return }
        if free < minimumFreeDiskBytes {
            throw SummaryModelError.insufficientDiskSpace(freeBytes: free)
        }
    }
}

/// Produces a `TextGenerating` engine from an on-disk snapshot directory. The
/// real implementation loads an MLX container; a test fake returns a scripted
/// engine and counts loads.
typealias EngineLoader = @Sendable (_ directory: URL) async throws -> any TextGenerating

/// Downloads the snapshot to disk, reporting `(phase, fraction)` progress. The
/// real implementation drives HubApi and, on completion, records the
/// completeness manifest the snapshot check consults (ADR-012); a test fake
/// counts transfers, flips its snapshot flag, and never touches the network.
/// `progress` is `@escaping` because the live downloader hands it to the
/// stall-retry's `onRetry` and the Hub snapshot callback.
typealias SnapshotDownloader = @Sendable (_ progress: @escaping @Sendable (String, Double) -> Void) async throws -> Void

/// Schedules (and cancels) the summary model's idle-timeout release. Extracted
/// behind a protocol so the release discipline is deterministic under test — a
/// fake fires the timer on demand instead of a real sleep (SP-003 Testing
/// Decisions layer 3; ADR-008). Production arms a cancellable Task.
nonisolated protocol IdleReleaseScheduling: Sendable {
    /// (Re)arm the release: run `fire` after `timeout` unless `cancel()` (or a
    /// superseding `arm`) intervenes first. `fire` re-enters the manager and
    /// re-checks work-in-flight, so a lost cancellation race is still safe.
    func arm(after timeout: Duration, _ fire: @escaping @Sendable () async -> Void)
    /// Cancel a pending release (new work arrived, or the model was unloaded).
    func cancel()
}

/// Production scheduler: a single cancellable Task that sleeps for the idle
/// timeout, then fires. `arm` supersedes any previous pending release.
nonisolated final class TaskIdleReleaseScheduler: IdleReleaseScheduling, @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<Void, Never>?

    func arm(after timeout: Duration, _ fire: @escaping @Sendable () async -> Void) {
        lock.lock()
        defer { lock.unlock() }
        task?.cancel()
        task = Task {
            // A cancelled sleep (superseded, or work resumed) throws — don't
            // fire. When it does fire, the manager re-checks work-in-flight.
            do { try await Task.sleep(for: timeout) } catch { return }
            await fire()
        }
    }

    func cancel() {
        lock.lock()
        defer { lock.unlock() }
        task?.cancel()
        task = nil
    }
}

/// Persists the user's "pause the summary download" intent so neither the eager
/// launch download nor the record-start prefetch silently resumes it — on this
/// launch or the next (SP-003 US-10). Behind a protocol so tests use an
/// in-memory fake; production uses a tiny JSON file in the single data root
/// (never UserDefaults — 2026-07-13 decision), mirroring `AppSettings`.
nonisolated protocol DownloadPauseStore: Sendable {
    var isPaused: Bool { get }
    func setPaused(_ paused: Bool)
}

/// The production pause store: a one-field JSON file under `EchoPaths`.
/// Reads/writes are synchronous and cheap (called on the manager actor); a
/// missing or unreadable file reads as "not paused", so a first run — or a
/// deleted data folder — starts un-paused.
nonisolated final class FileDownloadPauseStore: DownloadPauseStore, @unchecked Sendable {
    private let lock = NSLock()
    private let fileURL: URL

    init(fileURL: URL = EchoPaths.summaryDownloadStateFile) {
        self.fileURL = fileURL
    }

    /// Every field defaults so a missing key (older file, or none) decodes.
    private struct Stored: Codable { var paused = false }

    var isPaused: Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let data = try? Data(contentsOf: fileURL),
              let stored = try? JSONDecoder().decode(Stored.self, from: data)
        else { return false }
        return stored.paused
    }

    func setPaused(_ paused: Bool) {
        lock.lock()
        defer { lock.unlock() }
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(Stored(paused: paused))
            try data.write(to: fileURL, options: .atomic)
        } catch {
            ErrorTrace.record(
                "Writing summary-download pause state failed",
                error: error,
                category: "SummaryModelManager"
            )
        }
    }
}

/// Bridges swift-transformers' `Tokenizers.Tokenizer` into MLXLMCommon's
/// same-named protocol. Chat templating is deliberately unsupported here:
/// MLXTextEngine builds the turn format itself (ADR-010), so a template the
/// two stacks might disagree about never enters the picture.
nonisolated struct EchoTokenizerLoader: TokenizerLoader {
    func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
        let wrapper = try await AutoTokenizer.from(modelFolder: directory)
        return EchoBridgedTokenizer(wrapper: wrapper)
    }
}

private nonisolated struct EchoBridgedTokenizer: MLXLMCommon.Tokenizer {
    let wrapper: any Tokenizers.Tokenizer

    func encode(text: String, addSpecialTokens: Bool) -> [Int] {
        wrapper.encode(text: text, addSpecialTokens: addSpecialTokens)
    }

    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
        wrapper.decode(tokens: tokenIds, skipSpecialTokens: skipSpecialTokens)
    }

    func convertTokenToId(_ token: String) -> Int? {
        wrapper.convertTokenToId(token)
    }

    func convertIdToToken(_ id: Int) -> String? {
        wrapper.convertIdToToken(id)
    }

    var bosToken: String? { wrapper.bosToken }
    var eosToken: String? { wrapper.eosToken }
    var unknownToken: String? { wrapper.unknownToken }

    func applyChatTemplate(
        messages: [[String: any Sendable]],
        tools: [[String: any Sendable]]?,
        additionalContext: [String: any Sendable]?
    ) throws -> [Int] {
        throw MLXLMCommon.TokenizerError.missingChatTemplate
    }
}

nonisolated enum SummaryModelError: LocalizedError {
    case insufficientDiskSpace(freeBytes: Int64)
    case downloadFailed(String)
    case loadFailed(String)

    var errorDescription: String? {
        switch self {
        case .insufficientDiskSpace(let freeBytes):
            let free = ByteCountFormatter.string(fromByteCount: freeBytes, countStyle: .file)
            return "Not enough disk space to download the summary model (~3.3 GB needed, \(free) free). Free up space and retry."
        case .downloadFailed(let message):
            return "Could not download the summary model: \(message)"
        case .loadFailed(let message):
            return "Could not load the summary model: \(message)"
        }
    }
}
