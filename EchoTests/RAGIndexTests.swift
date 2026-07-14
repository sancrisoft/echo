//
//  RAGIndexTests.swift
//  EchoTests
//
//  Exercises the per-meeting RAG index sidecar (SPEC-06) with FAKE embeddings
//  injected through the RAGEmbedding seam (SPEC-06 §5.2) — no model download,
//  deterministic vectors. Covers: build → embed → write roundtrip, sidecar
//  reuse (lazy build once), and invalidation by embedding model id and by the
//  transcript's segment count. Constructed text segments (no audio) are the
//  sanctioned fixture style for store/index tests (workflow §0.5).
//

import Foundation
import Testing
@testable import Echo

/// Deterministic keyword embedding: each known topic maps to one dimension,
/// weighted by how many times it appears; text with no known topic lands on a
/// dedicated "misc" dimension. Vectors are L2-normalized (via the real
/// VectorMath), so cosine behaves exactly as production. Thread-safe call
/// counting proves when a build actually re-embedded vs reused the sidecar.
final class FakeRAGEmbedding: RAGEmbedding, @unchecked Sendable {
    nonisolated let dimension: Int
    private let _modelID: String
    nonisolated var modelID: String { _modelID }
    private let cached: Bool

    private let lock = NSLock()
    private var _docCalls = 0
    private var _queryCalls = 0

    init(dimension: Int = 8, modelID: String = "fake-embed-v1", cached: Bool = true) {
        self.dimension = dimension
        self._modelID = modelID
        self.cached = cached
    }

    var docCalls: Int { lock.withLock { _docCalls } }
    var queryCalls: Int { lock.withLock { _queryCalls } }

    func ensureReady(progress: @Sendable @escaping (String, Double) -> Void) async throws {
        progress("Loading embedding model…", 1)
    }

    func cachedModelExists() async -> Bool { cached }

    func embedDocuments(_ texts: [String]) async throws -> [[Float]] {
        lock.withLock { _docCalls += 1 }
        return texts.map { Self.vector(for: $0, dimension: dimension) }
    }

    func embedQuery(_ text: String) async throws -> [Float] {
        lock.withLock { _queryCalls += 1 }
        return Self.vector(for: text, dimension: dimension)
    }

    static let topics = ["budget", "postgres", "friday", "onboarding", "regions", "analytics"]

    static func vector(for text: String, dimension: Int) -> [Float] {
        let lower = text.lowercased()
        var vector = [Float](repeating: 0, count: dimension)
        var matched = false
        for (index, topic) in topics.enumerated() where index < dimension {
            let count = lower.components(separatedBy: topic).count - 1
            if count > 0 {
                vector[index] = Float(count)
                matched = true
            }
        }
        if !matched {
            let miscIndex = min(topics.count, dimension - 1)
            vector[miscIndex] = 1
        }
        return VectorMath.l2Normalized(vector)
    }
}

@Suite("RAGIndexStore")
struct RAGIndexTests {

    /// Small thresholds + big inter-group gaps force one chunk per topic group,
    /// so an index has several chunks to retrieve over (the default 6K-token
    /// config would fold this tiny transcript into a single chunk).
    private static let config = ChunkingConfig(
        targetTokens: 20, hardMaxTokens: 40, overlapTokens: 0,
        longGap: 10, turnGap: 2, minChunkTokens: 1
    )

    private func topicSegments() -> [TranscriptSegment] {
        let groups: [[String]] = [
            ["The budget for Q3 was set to 40k.", "We confirmed the budget again."],
            ["We will migrate to postgres next sprint.", "postgres is the plan."],
            ["We ship on friday.", "friday is the launch day."],
        ]
        var segments: [TranscriptSegment] = []
        for (groupIndex, group) in groups.enumerated() {
            let base = TimeInterval(groupIndex * 100)   // 100 s gap → chunk boundary
            for (lineIndex, text) in group.enumerated() {
                let start = base + TimeInterval(lineIndex * 4)
                segments.append(TranscriptSegment(
                    channel: .system, speaker: .teammates, text: text, start: start, end: start + 3
                ))
            }
        }
        return segments
    }

    private func withTempStore<T>(_ body: (MeetingStore) async throws -> T) async rethrows -> T {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "RAGIndexTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        return try await body(MeetingStore(rootDirectory: root))
    }

    @discardableResult
    private func saveMeeting(
        _ store: MeetingStore, segments: [TranscriptSegment]
    ) async throws -> UUID {
        let id = UUID()
        let meta = MeetingMeta(
            id: id, title: "Test", startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            endedAt: Date(timeIntervalSince1970: 1_700_000_300),
            segmentCount: segments.count, hasSummary: false
        )
        try await store.save(MeetingRecord(meta: meta, segments: segments, summary: nil))
        return id
    }

    // MARK: - Build + roundtrip

    @Test("index builds, embeds every chunk, and writes a reusable sidecar")
    func buildRoundTrip() async throws {
        try await withTempStore { store in
            let segments = topicSegments()
            let id = try await saveMeeting(store, segments: segments)
            let embedding = FakeRAGEmbedding(dimension: 8)
            let ragStore = RAGIndexStore(meetingStore: store, embeddings: embedding, chunkingConfig: Self.config)

            let index = try await ragStore.index(for: id) { _, _ in }

            let expectedChunks = TranscriptChunker.chunks(from: segments, config: Self.config)
            #expect(expectedChunks.count > 1)   // the config really split the transcript
            #expect(index.schemaVersion == 1)
            #expect(index.embeddingModelID == "fake-embed-v1")
            #expect(index.dimension == 8)
            #expect(index.transcriptSegmentCount == segments.count)
            #expect(index.chunks.count == expectedChunks.count)
            #expect(index.chunks.allSatisfy { $0.vector.count == 8 })
            // Chunk metadata is copied faithfully from the chunker.
            #expect(index.chunks.first?.chunkIndex == expectedChunks.first?.index)
            #expect(index.chunks.first?.start == expectedChunks.first?.start)
            #expect(index.chunks.first?.text == expectedChunks.first?.plainText)

            // Sidecar landed next to the meeting's files.
            let url = store.directory(for: id).appending(path: RAGIndexStore.sidecarFilename)
            #expect(FileManager.default.fileExists(atPath: url.path))

            // A fresh store over the same folder decodes the sidecar byte-for-byte
            // and never re-embeds (lazy build happens once).
            let embedding2 = FakeRAGEmbedding(dimension: 8)
            let ragStore2 = RAGIndexStore(meetingStore: store, embeddings: embedding2, chunkingConfig: Self.config)
            let reloaded = try await ragStore2.index(for: id) { _, _ in }
            #expect(reloaded.chunks == index.chunks)
            #expect(embedding2.docCalls == 0)
        }
    }

    @Test("a second index call in the same session reuses the in-memory index")
    func lazyBuildOnce() async throws {
        try await withTempStore { store in
            let id = try await saveMeeting(store, segments: topicSegments())
            let embedding = FakeRAGEmbedding(dimension: 8)
            let ragStore = RAGIndexStore(meetingStore: store, embeddings: embedding, chunkingConfig: Self.config)

            _ = try await ragStore.index(for: id) { _, _ in }
            let callsAfterBuild = embedding.docCalls
            #expect(callsAfterBuild > 0)

            _ = try await ragStore.index(for: id) { _, _ in }
            #expect(embedding.docCalls == callsAfterBuild)   // no re-embed
        }
    }

    // MARK: - Invalidation

    @Test("a different embedding model id invalidates and rebuilds the index")
    func invalidatesOnModelID() async throws {
        try await withTempStore { store in
            let id = try await saveMeeting(store, segments: topicSegments())

            let v1 = FakeRAGEmbedding(dimension: 8, modelID: "fake-embed-v1")
            _ = try await RAGIndexStore(meetingStore: store, embeddings: v1, chunkingConfig: Self.config)
                .index(for: id) { _, _ in }

            // Fresh store (no in-memory cache) with a different model id.
            let v2 = FakeRAGEmbedding(dimension: 8, modelID: "fake-embed-v2")
            let rebuilt = try await RAGIndexStore(meetingStore: store, embeddings: v2, chunkingConfig: Self.config)
                .index(for: id) { _, _ in }

            #expect(rebuilt.embeddingModelID == "fake-embed-v2")
            #expect(v2.docCalls > 0)   // it really rebuilt rather than trusting the stale sidecar
        }
    }

    @Test("a changed transcript segment count invalidates and rebuilds the index")
    func invalidatesOnSegmentCount() async throws {
        try await withTempStore { store in
            let id = try await saveMeeting(store, segments: topicSegments())
            let embedding = FakeRAGEmbedding(dimension: 8)
            _ = try await RAGIndexStore(meetingStore: store, embeddings: embedding, chunkingConfig: Self.config)
                .index(for: id) { _, _ in }

            // Overwrite the same meeting with a longer transcript.
            let longer = topicSegments() + [TranscriptSegment(
                channel: .system, speaker: .teammates,
                text: "One extra analytics remark.", start: 500, end: 503
            )]
            let meta = MeetingMeta(
                id: id, title: "Test", startedAt: Date(timeIntervalSince1970: 1_700_000_000),
                endedAt: Date(timeIntervalSince1970: 1_700_000_300),
                segmentCount: longer.count, hasSummary: false
            )
            try await store.save(MeetingRecord(meta: meta, segments: longer, summary: nil))

            let embedding2 = FakeRAGEmbedding(dimension: 8)
            let rebuilt = try await RAGIndexStore(meetingStore: store, embeddings: embedding2, chunkingConfig: Self.config)
                .index(for: id) { _, _ in }

            #expect(rebuilt.transcriptSegmentCount == longer.count)
            #expect(embedding2.docCalls > 0)
        }
    }

    @Test("an empty transcript yields an empty, valid index")
    func emptyTranscript() async throws {
        try await withTempStore { store in
            let id = try await saveMeeting(store, segments: [])
            let embedding = FakeRAGEmbedding(dimension: 8)
            let index = try await RAGIndexStore(meetingStore: store, embeddings: embedding, chunkingConfig: Self.config)
                .index(for: id) { _, _ in }

            #expect(index.chunks.isEmpty)
            #expect(index.transcriptSegmentCount == 0)
            #expect(embedding.docCalls == 0)   // nothing to embed
        }
    }
}
