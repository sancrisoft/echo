//
//  SummaryModelManager.swift
//  Echo
//
//  Downloads (once), caches, and loads the summary LLM. The snapshot lives
//  under EchoPaths.modelsDirectory — a user-level path shared by all
//  worktrees and app relaunches, so the ~8.3 GB download happens exactly one
//  time. Loading produces a TextGenerating engine backed by MLX (in-process;
//  no server subprocess, no HTTP, no Homebrew).
//
//  Memory lifecycle (ADR-008): the 8.3 GB weights are brought into RAM only
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

import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import WhisperKit  // @_exported ArgmaxCore: HubApiWrapper / AutoTokenizerWrapper
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
    case downloading(Double)   // fraction ∈ [0, 1]
    case loading
    case ready
    case failed(String)

    /// Download/load in flight — the trigger buttons disable on this.
    var isBusy: Bool {
        switch self {
        case .downloading, .loading: return true
        case .notDownloaded, .partiallyDownloaded, .ready, .failed: return false
        }
    }
}

actor SummaryModelManager {

    static let log = Logger(subsystem: "com.sancrisoft.Echo", category: "SummaryModelManager")

    static let modelID = "mlx-community/gemma-4-12B-it-qat-OptiQ-4bit"
    /// Human name for the models banner ("which model is this and why").
    static let modelDisplayName = "Gemma 4 12B"
    /// Shown next to "Ready" in the UI; the on-disk size of the text-path
    /// snapshot (two weight shards + configs + tokenizer).
    static let modelDisplaySize = "8.3 GB"

    /// Idle window after the last summary generation before the ~8.3 GB weights
    /// are released from RAM (ADR-008). Provisional starting value for SP-003
    /// open question 2: long enough to span a regenerate or a quick follow-up
    /// summary (the model stays warm across a burst), short enough that the app
    /// returns to its light baseline soon after the user is done. Tuned later
    /// against the manual RSS measurements (SP-003 open question 4).
    static let summaryModelIdleTimeout: Duration = .seconds(120)

    /// The repo also carries a bf16 vision sidecar (optiq/optiq_vision.safetensors,
    /// ~105 MB) that the text path neither downloads nor loads: these globs
    /// match the weight shards (`model-*.safetensors`) and the top-level
    /// configs/tokenizer, and cannot match anything under optiq/.
    private static let downloadGlobs = ["model*.safetensors", "*.json"]

    /// Files that must exist for the cache to count as complete; the weight
    /// shards are validated against the index's weight_map on top of these.
    private static let requiredFiles = [
        "config.json",
        "generation_config.json",
        "tokenizer.json",
        "tokenizer_config.json",
        "model.safetensors.index.json",
    ]

    private static let minimumFreeDiskBytes: Int64 = 15 * 1_000_000_000

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

    /// Designated initializer. All parameters default to the real MLX / HubApi /
    /// disk / Task-based implementations, so production call sites remain
    /// `SummaryModelManager()`; tests inject counting fakes and a manual
    /// release scheduler.
    init(
        loader: @escaping EngineLoader = SummaryModelManager.liveLoader,
        downloader: @escaping SnapshotDownloader = SummaryModelManager.liveDownloader,
        snapshotExists: @escaping @Sendable () -> Bool = SummaryModelManager.liveSnapshotExists,
        scheduler: any IdleReleaseScheduling = TaskIdleReleaseScheduler(),
        idleTimeout: Duration = SummaryModelManager.summaryModelIdleTimeout
    ) {
        self.loader = loader
        self.downloader = downloader
        self.snapshotExistsCheck = snapshotExists
        self.scheduler = scheduler
        self.idleTimeout = idleTimeout
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
    /// prefetch, which must never put the 12B weights in memory while Whisper is
    /// transcribing live. Joins any in-flight download; a no-op once the
    /// snapshot (or the engine) exists.
    func ensureDownloaded(
        progress: @Sendable @escaping (String, Double) -> Void
    ) async throws {
        if engine != nil { return }
        try await downloadIfNeeded(progress: progress)
    }

    /// Whether a complete snapshot is already on disk — cheap enough to paint
    /// the UI state without touching the network or loading weights. Delegates
    /// to the injected check (real disk scan in production).
    func cachedModelExists() -> Bool {
        snapshotExistsCheck()
    }

    /// Bytes an interrupted download already put on disk (complete files plus
    /// the Hub's resumable `*.incomplete` partials under `.cache/`), or nil
    /// when nothing is there. Consumed only as a boolean "is there a resumable
    /// partial" signal — the number itself must never reach the UI: it sums
    /// staging alongside committed files and can exceed the committed total, so
    /// it cannot back a percentage or an "X of Y" readout (ADR-007). A resumed
    /// download skips whatever is already on disk regardless.
    func partialDownloadBytes() -> Int64? {
        guard !cachedModelExists() else { return nil }
        guard let enumerator = FileManager.default.enumerator(
            at: Self.snapshotDirectory,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]
        ) else { return nil }

        var total: Int64 = 0
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true else { continue }
            total += Int64(values.fileSize ?? 0)
        }
        return total > 0 ? total : nil
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
    /// generations stays small relative to the 12B weights, loads the
    /// container, and wraps it in the streaming engine.
    static let liveLoader: EngineLoader = { directory in
        MLX.GPU.set(cacheLimit: 20 * 1024 * 1024)
        let container = try await LLMModelFactory.shared.loadContainer(
            from: directory,
            using: EchoTokenizerLoader()
        )
        return MLXTextEngine(container: container)
    }

    /// The real Hub snapshot download (repo-metadata fraction + stall-retry).
    static let liveDownloader: SnapshotDownloader = { progress in
        try SummaryModelManager.checkDiskSpace()
        progress("Downloading summary model…", 0)
        // The bar must not snap back to zero on a stall retry — remember the
        // fraction the download actually reached (callbacks arrive on
        // URLSession worker threads, hence the lock).
        let reached = LockedFraction()
        do {
            // Stall watchdog + retry: a download whose connection goes
            // idle is cancelled and re-run (the Hub snapshot skips files
            // already on disk, so a retry resumes where it stalled).
            _ = try await ModelDownload.withStallRetry(
                onRetry: { attempt in
                    log.warning("Summary model download stalled; retrying (attempt \(attempt, privacy: .public))")
                    progress("Download stalled — retrying…", reached.value)
                }
            ) { noteProgress in
                let hub = HubApiWrapper(downloadBase: EchoPaths.modelsDirectory)
                let repo = HubApiWrapper.Repo(id: SummaryModelManager.modelID)
                return try await hub.snapshot(
                    from: repo,
                    matching: SummaryModelManager.downloadGlobs
                ) { snapshotProgress in
                    noteProgress(snapshotProgress.fractionCompleted)
                    reached.update(snapshotProgress.fractionCompleted)
                    progress("Downloading summary model…", snapshotProgress.fractionCompleted)
                }
            }
        } catch {
            throw SummaryModelError.downloadFailed(error.localizedDescription)
        }
    }

    /// The real on-disk snapshot check (required files + every weight shard).
    static let liveSnapshotExists: @Sendable () -> Bool = {
        cachedSnapshotExists()
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

    /// downloadBase/models/<org>/<repo> — HubApi's snapshot layout.
    private static var snapshotDirectory: URL {
        HubApiWrapper(downloadBase: EchoPaths.modelsDirectory)
            .localRepoLocation(HubApiWrapper.Repo(id: modelID))
    }

    /// The real "is a complete snapshot on disk" check backing `liveSnapshotExists`.
    private static func cachedSnapshotExists() -> Bool {
        let directory = snapshotDirectory
        let fm = FileManager.default
        for file in requiredFiles {
            guard fm.fileExists(atPath: directory.appending(path: file).path) else { return false }
        }
        guard let shards = weightShards(in: directory) else { return false }
        for shard in shards {
            guard fm.fileExists(atPath: directory.appending(path: shard).path) else { return false }
        }
        return true
    }

    /// Distinct shard filenames from model.safetensors.index.json's
    /// weight_map, or nil if the index is missing/unreadable.
    private static func weightShards(in directory: URL) -> Set<String>? {
        let indexURL = directory.appending(path: "model.safetensors.index.json")
        guard
            let data = try? Data(contentsOf: indexURL),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let weightMap = object["weight_map"] as? [String: String]
        else {
            return nil
        }
        return Set(weightMap.values)
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
/// real implementation drives HubApi; a test fake counts transfers and never
/// touches the network. `progress` is `@escaping` because the live downloader
/// hands it to the stall-retry's `onRetry` and the Hub snapshot callback.
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

/// Bridges the tokenizer stack Echo already ships (ArgmaxCore's vendored
/// swift-transformers, surfaced as TokenizerWrapper) into MLXLMCommon's
/// Tokenizer. Chat templating is deliberately unsupported: the wrapper does
/// not expose it, and MLXTextEngine builds the Gemma turn format itself.
nonisolated struct EchoTokenizerLoader: TokenizerLoader {
    func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
        let wrapper = try await AutoTokenizerWrapper.from(modelFolder: directory)
        return EchoBridgedTokenizer(wrapper: wrapper)
    }
}

private nonisolated struct EchoBridgedTokenizer: MLXLMCommon.Tokenizer {
    let wrapper: TokenizerWrapper

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
            return "Not enough disk space to download the summary model (~8.3 GB needed, \(free) free). Free up space and retry."
        case .downloadFailed(let message):
            return "Could not download the summary model: \(message)"
        case .loadFailed(let message):
            return "Could not load the summary model: \(message)"
        }
    }
}
