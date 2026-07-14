//
//  RAGIndex.swift
//  Echo
//
//  Per-meeting RAG index sidecar (SPEC-06): chunk texts + their embedding
//  vectors, persisted as `rag_index.json` next to the meeting's other files in
//  the SPEC-03 folder layout. There is no vector DB — a meeting is only a few
//  hundred chunks, so `VectorMath.topK` over vectors held in memory is exact and
//  instant at this scale (SPEC-06 §2).
//
//  The index is built lazily the first time a meeting is queried (chunk → embed
//  → write) and reused afterwards, both in-process (an in-memory cache keyed by
//  meeting id) and across launches (the sidecar). It is invalidated and rebuilt
//  if the embedding model, the output dimension, or the transcript's segment
//  count no longer matches — the saved transcript is immutable today, but the
//  guard is cheap and keeps the sidecar honest.
//
//  Chunking is `TranscriptChunker` (SPEC-02, deterministic: same transcript →
//  same chunks) and embedding is `EmbeddingsService` (SPEC-04). Neither is
//  modified here; the `RAGEmbedding` seam below lets tests inject fake vectors
//  without touching SPEC-04, and `EmbeddingsService` conforms to it via an
//  extension in this file.
//

import Foundation
import os

// MARK: - Embedding seam

/// The slice of `EmbeddingsService` this feature needs, expressed as a protocol
/// so tests can inject deterministic fake vectors (SPEC-06 §5.2). Created in
/// SPEC-06's own file — SPEC-04 is consumed unchanged and conforms via the
/// extension below. `modelID` is exposed per-instance so the invalidation guard
/// can compare the model an index was built with against the current one.
protocol RAGEmbedding: Sendable {
    nonisolated var dimension: Int { get }
    nonisolated var modelID: String { get }
    func ensureReady(progress: @Sendable @escaping (String, Double) -> Void) async throws
    func cachedModelExists() async -> Bool
    func embedDocuments(_ texts: [String]) async throws -> [[Float]]
    func embedQuery(_ text: String) async throws -> [Float]
}

extension EmbeddingsService: RAGEmbedding {
    /// The static repo id, surfaced per-instance for the index invalidation
    /// guard. (`EmbeddingsService` fixes the model at the type level.)
    nonisolated var modelID: String { Self.modelID }
}

// MARK: - Sidecar model

/// One chunk of a meeting, indexed for retrieval: its plain text (speakers +
/// timestamps, exactly what was embedded), its time range and segment ids for
/// citation, and the normalized embedding vector.
///
/// `nonisolated` so its `Codable` conformance is usable from the store actor's
/// off-main sidecar I/O (the project builds with `-default-isolation MainActor`,
/// under which an unannotated type's conformance would be main-actor-bound —
/// the same reason `MeetingMeta` is `nonisolated`).
nonisolated struct RAGIndexedChunk: Codable, Hashable, Sendable {
    let chunkIndex: Int
    let text: String                 // TranscriptChunk.plainText (speakers + timestamps)
    let start: TimeInterval
    let end: TimeInterval
    let segmentIDs: [UUID]           // all segments in the chunk
    let vector: [Float]              // normalized, EmbeddingsService dimension
}

/// The on-disk `rag_index.json`. The three guard fields (`embeddingModelID`,
/// `dimension`, `transcriptSegmentCount`) let a reader reject an index built
/// against a different model / dimension / transcript and rebuild instead of
/// silently returning stale vectors. `nonisolated` for the same reason as
/// `RAGIndexedChunk`.
nonisolated struct RAGIndex: Codable, Sendable {
    var schemaVersion: Int           // = 1
    var embeddingModelID: String     // invalidation guard
    var dimension: Int
    var transcriptSegmentCount: Int  // invalidation guard vs record
    var chunks: [RAGIndexedChunk]
}

/// A `Sendable` snapshot of one `TranscriptChunk`'s fields, extracted on the
/// main actor so the store can embed it off-main without touching the
/// main-actor-isolated `TranscriptChunk` API.
private nonisolated struct ExtractedChunk: Sendable {
    let index: Int
    let text: String
    let start: TimeInterval
    let end: TimeInterval
    let segmentIDs: [UUID]
}

// MARK: - Store

actor RAGIndexStore {

    private static let log = Logger(subsystem: "com.sancrisoft.Echo", category: "RAGIndexStore")

    /// First persisted version; readers reject anything they don't understand.
    static let schemaVersion = 1
    /// Sidecar filename inside the meeting's folder (SPEC-03 layout).
    static let sidecarFilename = "rag_index.json"
    /// Embed in batches so a large meeting doesn't build one giant padded tensor
    /// and progress can advance mid-build. Independent of EmbeddingsService's own
    /// internal batching (this bound governs the progress granularity).
    private static let embedBatchSize = 16

    private let meetingStore: MeetingStore
    private let embeddings: any RAGEmbedding
    private let chunkingConfig: ChunkingConfig

    /// In-memory cache keyed by meeting id: once an index is built or loaded this
    /// session, further questions about the same meeting skip disk entirely. The
    /// saved transcript is immutable, so a session-lived entry never goes stale.
    private var inMemory: [UUID: RAGIndex] = [:]

    /// - Parameters:
    ///   - meetingStore: locates each meeting's folder and loads its transcript.
    ///   - embeddings: the vector source (production: `EmbeddingsService`).
    ///   - chunkingConfig: SPEC-02 chunking tunables. Injectable so tests can
    ///     force multiple chunks from short transcripts; production passes the
    ///     default `ChunkingConfig()` (constructed by the caller so its
    ///     main-actor-isolated initializer runs in the caller's context).
    init(
        meetingStore: MeetingStore,
        embeddings: any RAGEmbedding,
        chunkingConfig: ChunkingConfig
    ) {
        self.meetingStore = meetingStore
        self.embeddings = embeddings
        self.chunkingConfig = chunkingConfig
    }

    /// Loads the sidecar if valid; otherwise builds it (chunk → embed → write)
    /// with textual progress ("Indexing meeting… 40%"). Reused from memory on
    /// repeat calls within a session.
    func index(
        for meetingID: UUID,
        progress: @Sendable @escaping (String, Double) -> Void
    ) async throws -> RAGIndex {
        if let cached = inMemory[meetingID] { return cached }

        // The record is needed to validate the segment-count guard and, on a
        // miss, to build. Loading it decodes the transcript off the main thread
        // (MeetingStore is an actor); the expensive embedding step is what the
        // caches actually save.
        let record = try await meetingStore.loadRecord(meetingID)
        let url = meetingStore.directory(for: meetingID).appending(path: Self.sidecarFilename)

        if let existing = Self.loadSidecar(at: url), isValid(existing, for: record) {
            inMemory[meetingID] = existing
            return existing
        }

        let built = try await build(from: record, progress: progress)
        Self.writeSidecar(built, to: url)
        inMemory[meetingID] = built
        return built
    }

    // MARK: - Validation

    private func isValid(_ index: RAGIndex, for record: MeetingRecord) -> Bool {
        index.schemaVersion == Self.schemaVersion
            && index.embeddingModelID == embeddings.modelID
            && index.dimension == embeddings.dimension
            && index.transcriptSegmentCount == record.segments.count
    }

    // MARK: - Build

    private func build(
        from record: MeetingRecord,
        progress: @Sendable @escaping (String, Double) -> Void
    ) async throws -> RAGIndex {
        // `TranscriptChunker` and `TranscriptChunk.plainText` are main-actor
        // isolated (SPEC-02, consumed unchanged), so chunking and text
        // extraction happen on the main actor; they are cheap string ops. The
        // expensive embedding pass below runs off the main thread.
        let chunks = await Self.extractedChunks(from: record.segments, config: chunkingConfig)

        // Empty transcript → empty index. Retrieval over it degrades to an
        // honest refusal, so nothing downstream has to special-case it.
        guard !chunks.isEmpty else {
            return RAGIndex(
                schemaVersion: Self.schemaVersion,
                embeddingModelID: embeddings.modelID,
                dimension: embeddings.dimension,
                transcriptSegmentCount: record.segments.count,
                chunks: []
            )
        }

        // Download/load the embedding model first (its own phase labels), then
        // report the embedding pass as "Indexing meeting… X%".
        try await embeddings.ensureReady(progress: progress)
        progress("Indexing meeting…", 0)

        let texts = chunks.map(\.text)
        var vectors: [[Float]] = []
        vectors.reserveCapacity(texts.count)

        var start = 0
        while start < texts.count {
            try Task.checkCancellation()
            let end = min(start + Self.embedBatchSize, texts.count)
            let batch = Array(texts[start..<end])
            vectors.append(contentsOf: try await embeddings.embedDocuments(batch))
            start = end
            progress("Indexing meeting…", Double(start) / Double(texts.count))
        }

        let indexed = zip(chunks, vectors).map { chunk, vector in
            RAGIndexedChunk(
                chunkIndex: chunk.index,
                text: chunk.text,
                start: chunk.start,
                end: chunk.end,
                segmentIDs: chunk.segmentIDs,
                vector: vector
            )
        }

        return RAGIndex(
            schemaVersion: Self.schemaVersion,
            embeddingModelID: embeddings.modelID,
            dimension: embeddings.dimension,
            transcriptSegmentCount: record.segments.count,
            chunks: indexed
        )
    }

    /// Runs `TranscriptChunker` on the main actor (where its main-actor-isolated
    /// API lives) and flattens each chunk into a `Sendable` snapshot the store
    /// can carry off-main for embedding.
    @MainActor
    private static func extractedChunks(
        from segments: [TranscriptSegment],
        config: ChunkingConfig
    ) -> [ExtractedChunk] {
        TranscriptChunker.chunks(from: segments, config: config).map { chunk in
            ExtractedChunk(
                index: chunk.index,
                text: chunk.plainText,
                start: chunk.start,
                end: chunk.end,
                segmentIDs: chunk.segments.map(\.id)
            )
        }
    }

    // MARK: - Sidecar I/O

    /// Nil on any read/decode failure — a missing or corrupt sidecar just means
    /// "rebuild", never a thrown error.
    private static func loadSidecar(at url: URL) -> RAGIndex? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(RAGIndex.self, from: data)
    }

    /// Best-effort write: a failure is logged and swallowed. The in-memory index
    /// is already valid, so the current session works; the next session simply
    /// rebuilds. Compact (not pretty) encoding — the vectors dominate the size.
    private static func writeSidecar(_ index: RAGIndex, to url: URL) {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(index)
            try data.write(to: url, options: .atomic)
        } catch {
            log.error("Writing \(Self.sidecarFilename, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
