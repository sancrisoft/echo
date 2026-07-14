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
    case downloading(Double)   // fraction ∈ [0, 1]
    case loading
    case ready
    case failed(String)

    /// Download/load in flight — the trigger buttons disable on this.
    var isBusy: Bool {
        switch self {
        case .downloading, .loading: return true
        case .notDownloaded, .ready, .failed: return false
        }
    }
}

actor SummaryModelManager {

    static let log = Logger(subsystem: "com.sancrisoft.Echo", category: "SummaryModelManager")

    static let modelID = "mlx-community/gemma-4-12B-it-qat-OptiQ-4bit"
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

        if !cachedModelExists() {
            try Self.checkDiskSpace()
            progress("Downloading summary model…", 0)
            do {
                let hub = HubApiWrapper(downloadBase: EchoPaths.modelsDirectory)
                let repo = HubApiWrapper.Repo(id: Self.modelID)
                _ = try await hub.snapshot(
                    from: repo,
                    matching: Self.downloadGlobs
                ) { snapshotProgress in
                    progress("Downloading summary model…", snapshotProgress.fractionCompleted)
                }
            } catch {
                throw SummaryModelError.downloadFailed(error.localizedDescription)
            }
        }

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
