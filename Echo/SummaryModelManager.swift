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
    /// mid-download); carries the bytes already there so the UI can offer
    /// "Resume" instead of a from-scratch "Download".
    case partiallyDownloaded(bytesOnDisk: Int64)
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

    private var engine: MLXTextEngine?
    private var loadTask: Task<any TextGenerating, Error>?
    /// The one in-flight snapshot download, shared by every caller: the
    /// recording-start prefetch and a post-stop `ensureReady` must join the
    /// same transfer, never race two of them.
    private var downloadTask: Task<Void, Error>?

    /// Downloads (once) + loads the MLX container. Progress ∈ [0, 1] with a
    /// phase label ("Downloading summary model…" / "Loading summary model…").
    /// Concurrent callers share one in-flight load; a failure clears it so the
    /// next call retries from scratch.
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
    /// weights — the recording-start prefetch, which must never put the 12B
    /// weights in memory while Whisper is transcribing live. Joins any
    /// in-flight download; a no-op once the snapshot (or the engine) exists.
    func ensureDownloaded(
        progress: @Sendable @escaping (String, Double) -> Void
    ) async throws {
        if engine != nil { return }
        try await downloadIfNeeded(progress: progress)
    }

    /// Whether a complete snapshot is already on disk — cheap enough to paint
    /// the UI state without touching the network or loading weights.
    func cachedModelExists() -> Bool {
        let directory = Self.snapshotDirectory
        let fm = FileManager.default
        for file in Self.requiredFiles {
            guard fm.fileExists(atPath: directory.appending(path: file).path) else { return false }
        }
        guard let shards = Self.weightShards(in: directory) else { return false }
        for shard in shards {
            guard fm.fileExists(atPath: directory.appending(path: shard).path) else { return false }
        }
        return true
    }

    /// Bytes an interrupted download already put on disk (complete files plus
    /// the Hub's resumable `*.incomplete` partials under `.cache/`), or nil
    /// when nothing is there. Powers the banner's "Resume download — X of
    /// 8.3 GB done"; a resumed download skips all of it.
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

    /// Releases the loaded container. Not called in normal operation (v1 keeps
    /// the model warm between summaries); reserved for failure recovery.
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
            // Bound MLX's buffer cache so idle memory between generations
            // stays small relative to the 12B weights.
            MLX.GPU.set(cacheLimit: 20 * 1024 * 1024)
            let container = try await LLMModelFactory.shared.loadContainer(
                from: directory,
                using: EchoTokenizerLoader()
            )
            let engine = MLXTextEngine(container: container)
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
        if cachedModelExists() { return }
        if let downloadTask { return try await downloadTask.value }

        let task = Task<Void, Error> { try await performDownload(progress: progress) }
        downloadTask = task
        defer { downloadTask = nil }
        try await task.value
    }

    private func performDownload(
        progress: @Sendable @escaping (String, Double) -> Void
    ) async throws {
        try Self.checkDiskSpace()
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
                    Self.log.warning("Summary model download stalled; retrying (attempt \(attempt, privacy: .public))")
                    progress("Download stalled — retrying…", reached.value)
                }
            ) { noteProgress in
                let hub = HubApiWrapper(downloadBase: EchoPaths.modelsDirectory)
                let repo = HubApiWrapper.Repo(id: Self.modelID)
                return try await hub.snapshot(
                    from: repo,
                    matching: Self.downloadGlobs
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
