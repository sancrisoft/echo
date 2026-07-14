//
//  EmbeddingsService.swift
//  Echo
//
//  On-device text embeddings for RAG (SPEC-06) and cross-meeting queries
//  (SPEC-09). Wraps EmbeddingGemma 308M (google/embeddinggemma-300m, MLX build)
//  behind an actor: downloads the weights exactly once into the shared model
//  cache (same HubApi base as SummaryModelManager, under
//  ~/Library/Application Support/Echo/Models), loads them in-process via
//  MLXEmbedders, and returns L2-normalized Float vectors.
//
//  Multilingual by design: the user meets in English and Spanish, and
//  EmbeddingGemma covers 100+ languages with a single model — the Whisper
//  pipeline already restricts transcription to en/es.
//
//  This service produces vectors only. Indexing/persistence, retrieval, and any
//  UI belong to SPEC-06; the public API here is a binding contract for it.
//

import Foundation
import MLX
import MLXEmbedders
import MLXLMCommon
import WhisperKit  // @_exported ArgmaxCore: HubApiWrapper (shared model cache)
import os

nonisolated enum EmbeddingsError: Error {
    /// A caller passed an empty (or whitespace-only) string to embed. Embedding
    /// nothing is almost always a bug upstream, so it is surfaced, not silently
    /// mapped to a zero vector.
    case emptyInput
    /// The model could not be downloaded or loaded; the associated string is a
    /// human-readable reason suitable for logging/surfacing.
    case modelUnavailable(String)
}

actor EmbeddingsService {

    static let log = Logger(subsystem: "com.sancrisoft.Echo", category: "EmbeddingsService")

    /// mlx-community MLX build of google/embeddinggemma-300m, bf16
    /// (~654 MB). The quantized builds (4/8-bit) are unusable with
    /// mlx-swift-lm 3.31.4: their dense projection head is quantized, but
    /// `EmbeddingGemma.sanitize` swaps `dense.0/1` for plain `Linear`, so the
    /// packed int weights load as garbage and every vector comes out NaN. bf16
    /// has an unquantized dense head, so it loads correctly.
    /// `model_type: gemma3_text` → MLXEmbedders' `EmbeddingGemma`
    /// (mean-pool + dense head + L2-norm).
    static let modelID = "mlx-community/embeddinggemma-300m-bf16"

    /// Native output width of EmbeddingGemma's projection head. Callers may
    /// truncate to a shorter Matryoshka dimension (512/256/128) via `init`.
    static let nativeDimension = 768

    // MARK: - Task prompt prefixes
    //
    // EmbeddingGemma is instruction-tuned: the query and document sides use
    // DIFFERENT prefixes, and retrieval quality drops materially if they are
    // omitted or swapped. These strings are copied verbatim from the official
    // model card (NOT reconstructed from memory):
    //   https://huggingface.co/google/embeddinggemma-300m
    // ("Retrieval-query": `task: search result | query: {content}`,
    //  "Retrieval-document": `title: {title | "none"} | text: {content}`).
    // Meeting chunks carry no title, so the document side uses the sanctioned
    // `none` sentinel.

    /// Prepended to meeting-chunk text before embedding as a document.
    static let documentPromptPrefix = "title: none | text: "
    /// Prepended to a user question before embedding as a query.
    static let queryPromptPrefix = "task: search result | query: "

    /// `embedDocuments` chunks its input into batches of this size so a large
    /// meeting (100–300 chunks) does not build one giant padded tensor.
    private static let batchSize = 16

    /// Gemma reserves token id 0 as `<pad>`; EmbeddingGemma's mean pooling masks
    /// exactly these positions out. Padding with 0 (rather than EOS) therefore
    /// keeps real trailing tokens inside the pooled average.
    private static let padTokenID = 0

    /// Files that must exist for the on-disk snapshot to count as complete.
    private static let requiredFiles = [
        "config.json",
        "tokenizer_config.json",
        "tokenizer.json",
        "model.safetensors",
    ]

    /// HubApi glob set: weight shard(s), every JSON config, and the SentencePiece
    /// model. Mirrors SummaryModelManager's "download only what the load path
    /// needs" approach.
    private static let downloadGlobs = ["*.safetensors", "*.json", "*.model"]

    private static let minimumFreeDiskBytes: Int64 = 2 * 1_000_000_000

    private let cacheDirectory: URL

    /// Output dimensionality after optional Matryoshka truncation. Exposed
    /// nonisolated so callers can size buffers without awaiting the actor.
    nonisolated let dimension: Int

    private var container: EmbedderModelContainer?
    private var loadTask: Task<EmbedderModelContainer, Error>?

    /// - Parameters:
    ///   - cacheDirectory: HubApi download base; defaults to the shared model
    ///     cache so the weights are fetched once across worktrees and relaunches.
    ///   - dimension: Matryoshka truncation target. Defaults to the native 768;
    ///     512/256/128 are the values EmbeddingGemma was trained to support.
    init(
        cacheDirectory: URL = EchoPaths.modelsDirectory,
        truncateTo dimension: Int = EmbeddingsService.nativeDimension
    ) {
        precondition(
            (1...EmbeddingsService.nativeDimension).contains(dimension),
            "truncateTo must be in 1...\(EmbeddingsService.nativeDimension) (got \(dimension))"
        )
        self.cacheDirectory = cacheDirectory
        self.dimension = dimension
    }

    // MARK: - Lifecycle

    /// Downloads (once) then loads the model. Progress ∈ [0, 1] with a phase
    /// label, matching SummaryModelManager's convention. Concurrent callers
    /// share one in-flight load; a failure clears it so the next call retries.
    func ensureReady(
        progress: @Sendable @escaping (String, Double) -> Void
    ) async throws {
        _ = try await loadedContainer(progress: progress)
    }

    /// Whether a complete snapshot is already on disk — cheap enough to paint UI
    /// state without touching the network or loading weights.
    func cachedModelExists() -> Bool {
        let directory = snapshotDirectory
        let fm = FileManager.default
        for file in Self.requiredFiles {
            guard fm.fileExists(atPath: directory.appending(path: file).path) else {
                return false
            }
        }
        return true
    }

    // MARK: - Embedding

    /// Embeds meeting-chunk texts as documents (document task prefix), one
    /// normalized vector each, in the same order as the input.
    ///
    /// - Throws: `EmbeddingsError.emptyInput` if any element is empty/whitespace;
    ///   `EmbeddingsError.modelUnavailable` if the model cannot be loaded.
    func embedDocuments(_ texts: [String]) async throws -> [[Float]] {
        guard !texts.isEmpty else { return [] }
        for text in texts where text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw EmbeddingsError.emptyInput
        }

        let container = try await loadedContainer(progress: { _, _ in })
        let prompted = texts.map { Self.documentPromptPrefix + $0 }

        var vectors: [[Float]] = []
        vectors.reserveCapacity(texts.count)
        var start = 0
        while start < prompted.count {
            let end = min(start + Self.batchSize, prompted.count)
            let batch = Array(prompted[start..<end])
            let raw = try await Self.embed(batch, in: container)
            for vector in raw {
                vectors.append(Self.matryoshka(vector, to: dimension))
            }
            start = end
        }
        return vectors
    }

    /// Embeds a single user question as a query (query task prefix).
    ///
    /// - Throws: `EmbeddingsError.emptyInput` if the text is empty/whitespace;
    ///   `EmbeddingsError.modelUnavailable` if the model cannot be loaded.
    func embedQuery(_ text: String) async throws -> [Float] {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw EmbeddingsError.emptyInput
        }
        let container = try await loadedContainer(progress: { _, _ in })
        let raw = try await Self.embed([Self.queryPromptPrefix + text], in: container)
        guard let vector = raw.first else {
            throw EmbeddingsError.modelUnavailable("Model returned no embedding")
        }
        return Self.matryoshka(vector, to: dimension)
    }

    // MARK: - Load

    private func loadedContainer(
        progress: @Sendable @escaping (String, Double) -> Void
    ) async throws -> EmbedderModelContainer {
        if let container { return container }
        if let loadTask { return try await loadTask.value }

        let task = Task<EmbedderModelContainer, Error> {
            try await performLoad(progress: progress)
        }
        loadTask = task
        do {
            let container = try await task.value
            self.container = container
            return container
        } catch {
            loadTask = nil
            throw error
        }
    }

    private func performLoad(
        progress: @Sendable @escaping (String, Double) -> Void
    ) async throws -> EmbedderModelContainer {
        let directory = snapshotDirectory

        if !cachedModelExists() {
            try checkDiskSpace()
            progress("Downloading embedding model…", 0)
            do {
                let hub = HubApiWrapper(downloadBase: cacheDirectory)
                let repo = HubApiWrapper.Repo(id: Self.modelID)
                _ = try await hub.snapshot(
                    from: repo,
                    matching: Self.downloadGlobs
                ) { snapshotProgress in
                    progress("Downloading embedding model…", snapshotProgress.fractionCompleted)
                }
            } catch {
                throw EmbeddingsError.modelUnavailable(
                    "Could not download the embedding model: \(error.localizedDescription)"
                )
            }
        }

        progress("Loading embedding model…", 1)
        do {
            let container = try await EmbedderModelFactory.shared.loadContainer(
                from: directory,
                using: EchoTokenizerLoader()
            )
            Self.log.info("Embedding model loaded from \(directory.path, privacy: .public)")
            return container
        } catch {
            throw EmbeddingsError.modelUnavailable(
                "Could not load the embedding model: \(error.localizedDescription)"
            )
        }
    }

    // MARK: - Forward pass

    /// Runs one padded batch through the model and returns the native
    /// 768-d normalized vectors (EmbeddingGemma's `pooledOutput` already does
    /// mean-pool + dense head + L2-norm, so no external pooling is applied —
    /// applying `Pooling.mean` here would bypass the dense head and be wrong).
    private nonisolated static func embed(
        _ batch: [String],
        in container: EmbedderModelContainer
    ) async throws -> [[Float]] {
        try await container.perform { context in
            let tokenizer = context.tokenizer
            let encoded = batch.map { tokenizer.encode(text: $0, addSpecialTokens: true) }
            let maxLength = encoded.reduce(into: 1) { $0 = max($0, $1.count) }

            let padded = stacked(
                encoded.map { ids in
                    MLXArray(ids + Array(repeating: padTokenID, count: maxLength - ids.count))
                }
            )
            let mask = padded .!= padTokenID
            let output = context.model(
                padded, positionIds: nil, tokenTypeIds: nil, attentionMask: mask
            )
            guard let pooled = output.pooledOutput else {
                throw EmbeddingsError.modelUnavailable("Model produced no pooled output")
            }
            pooled.eval()
            return pooled.map { $0.asArray(Float.self) }
        }
    }

    /// Truncates a native vector to `dimension` and re-normalizes. Matryoshka
    /// embeddings are trained so the leading dims are a valid shorter embedding
    /// *after* re-normalization; at the native 768 this is effectively identity
    /// (the input is already unit length).
    ///
    /// Internal (not private) so the pure test suite can exercise the truncate +
    /// re-normalize contract without downloading the model.
    nonisolated static func matryoshka(_ vector: [Float], to dimension: Int) -> [Float] {
        guard dimension < vector.count else { return VectorMath.l2Normalized(vector) }
        return VectorMath.l2Normalized(Array(vector.prefix(dimension)))
    }

    // MARK: - Paths & validation

    /// downloadBase/models/<org>/<repo> — HubApi's snapshot layout.
    private var snapshotDirectory: URL {
        HubApiWrapper(downloadBase: cacheDirectory)
            .localRepoLocation(HubApiWrapper.Repo(id: Self.modelID))
    }

    private func checkDiskSpace() throws {
        let values = try? cacheDirectory.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]
        )
        guard let free = values?.volumeAvailableCapacityForImportantUsage else { return }
        if free < Self.minimumFreeDiskBytes {
            let readable = ByteCountFormatter.string(fromByteCount: free, countStyle: .file)
            throw EmbeddingsError.modelUnavailable(
                "Not enough disk space to download the embedding model (~654 MB needed, \(readable) free)."
            )
        }
    }
}
