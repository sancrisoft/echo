//
//  QAPipelineTests.swift
//  EchoTests
//
//  Drives the full Q&A path (retrieval → relevance floor → grounded streamed
//  generation) with FAKES: the shared FakeRAGEmbedding (deterministic keyword
//  vectors) feeds a real RAGIndexStore over a temp MeetingStore, and a scripted
//  TextGenerating stands in for Gemma (SPEC-06 §5.3). Asserts the three
//  behaviors that make Q&A trustworthy: a weak match refuses WITHOUT calling the
//  model, a good match streams a grounded answer citing the retrieved chunks'
//  time ranges, and top-k bounds how many chunks are offered.
//

import Foundation
import Testing
@testable import Echo

/// Scripted engine: replays fixed deltas, ignoring the prompt. Records whether
/// it was ever asked to generate — the refusal path must never reach it.
private final class ScriptedTextEngine: TextGenerating, @unchecked Sendable {
    private let chunks: [String]
    init(chunks: [String]) { self.chunks = chunks }

    func stream(system: String, user: String, params: GenerationParams)
        -> AsyncThrowingStream<String, Error>
    {
        let chunks = self.chunks
        return AsyncThrowingStream { continuation in
            for chunk in chunks { continuation.yield(chunk) }
            continuation.finish()
        }
    }
}

private final class FakeModelManager: TextEngineProviding, @unchecked Sendable {
    private let engine: any TextGenerating
    private let lock = NSLock()
    private var _ensureCalls = 0

    init(engine: any TextGenerating) { self.engine = engine }

    var ensureCalls: Int { lock.withLock { _ensureCalls } }

    func ensureReady(progress: @Sendable @escaping (String, Double) -> Void) async throws -> any TextGenerating {
        lock.withLock { _ensureCalls += 1 }
        progress("Loading summary model…", 1)
        return engine
    }

    func cachedModelExists() async -> Bool { true }
}

@Suite("QAPipeline")
struct QAPipelineTests {

    private static let config = ChunkingConfig(
        targetTokens: 20, hardMaxTokens: 40, overlapTokens: 0,
        longGap: 10, turnGap: 2, minChunkTokens: 1
    )

    /// Six topic groups separated by long gaps → six retrievable chunks.
    private func topicSegments() -> [TranscriptSegment] {
        let groups: [[String]] = [
            ["The budget for Q3 was set to 40k.", "We confirmed the budget again."],
            ["We will migrate to postgres next sprint.", "postgres is the plan."],
            ["We ship on friday.", "friday is the launch day."],
            ["The onboarding guide needs an update.", "onboarding is still pending."],
            ["Which regions get the beta first?", "regions are undecided."],
            ["The analytics contract is unsigned.", "analytics vendor is a risk."],
        ]
        var segments: [TranscriptSegment] = []
        for (groupIndex, group) in groups.enumerated() {
            let base = TimeInterval(groupIndex * 100)
            for (lineIndex, text) in group.enumerated() {
                let start = base + TimeInterval(lineIndex * 4)
                segments.append(TranscriptSegment(
                    channel: .system, speaker: .teammates, text: text, start: start, end: start + 3
                ))
            }
        }
        return segments
    }

    /// Builds a temp store with the six-topic meeting and returns everything a
    /// test needs to drive a QAPipeline over it.
    private func fixture(
        engine: any TextGenerating
    ) async throws -> (pipeline: QAPipeline, meetingID: UUID, manager: FakeModelManager, chunkCount: Int, root: URL) {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "QAPipelineTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        let store = MeetingStore(rootDirectory: root)
        let segments = topicSegments()
        let id = UUID()
        let meta = MeetingMeta(
            id: id, title: "Test", startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            endedAt: Date(timeIntervalSince1970: 1_700_000_600),
            segmentCount: segments.count, hasSummary: false
        )
        try await store.save(MeetingRecord(meta: meta, segments: segments, summary: nil))

        let embedding = FakeRAGEmbedding(dimension: 8)
        let indexStore = RAGIndexStore(meetingStore: store, embeddings: embedding, chunkingConfig: Self.config)
        let manager = FakeModelManager(engine: engine)
        let pipeline = QAPipeline(indexStore: indexStore, embeddings: embedding, modelManager: manager)
        let chunkCount = TranscriptChunker.chunks(from: segments, config: Self.config).count
        return (pipeline, id, manager, chunkCount, root)
    }

    private func collect(
        _ stream: AsyncThrowingStream<QAAnswer, Error>
    ) async throws -> [QAAnswer] {
        var out: [QAAnswer] = []
        for try await answer in stream { out.append(answer) }
        return out
    }

    // MARK: - Refusal

    @Test("a question the meeting doesn't cover refuses without calling the model")
    func refusesBelowFloor() async throws {
        let engine = ScriptedTextEngine(chunks: ["should never be used"])
        let (pipeline, id, manager, _, root) = try await fixture(engine: engine)
        defer { try? FileManager.default.removeItem(at: root) }

        let answers = try await collect(
            await pipeline.answer(question: "What is the company vacation policy?", meetingID: id) { _, _ in }
        )

        #expect(answers.count == 1)
        #expect(answers.first?.isRefusal == true)
        #expect(answers.first?.text == QAPipeline.refusalText)
        #expect(answers.first?.citations.isEmpty == true)
        #expect(manager.ensureCalls == 0)   // the LLM was never touched
    }

    // MARK: - Grounded answer + citations

    @Test("a covered question streams a grounded answer citing the retrieved chunks")
    func answersWithCitations() async throws {
        let engine = ScriptedTextEngine(chunks: ["The budget ", "for Q3 was ", "40k [0:00]."])
        let (pipeline, id, manager, _, root) = try await fixture(engine: engine)
        defer { try? FileManager.default.removeItem(at: root) }

        let answers = try await collect(
            await pipeline.answer(question: "What was the budget for Q3?", meetingID: id) { _, _ in }
        )

        let final = try #require(answers.last)
        #expect(final.isRefusal == false)
        #expect(final.text == "The budget for Q3 was 40k [0:00].")
        #expect(manager.ensureCalls == 1)
        // Citations are the retrieved chunks' time ranges; the budget chunk (the
        // one that actually holds the answer, starting at 0:00) must be cited.
        #expect(!final.citations.isEmpty)
        #expect(final.citations.contains { abs($0.start) < 0.001 })
        // Every citation is a real chunk range (start < end, non-negative).
        #expect(final.citations.allSatisfy { $0.start >= 0 && $0.end >= $0.start })
    }

    @Test("the answer accumulates across the stream")
    func streamingAccumulates() async throws {
        let engine = ScriptedTextEngine(chunks: ["Postgres ", "next ", "sprint [1:40]."])
        let (pipeline, id, _, _, root) = try await fixture(engine: engine)
        defer { try? FileManager.default.removeItem(at: root) }

        let answers = try await collect(
            await pipeline.answer(question: "When are we migrating to postgres?", meetingID: id) { _, _ in }
        )

        // More than one snapshot, each a prefix-growing accumulation of the last.
        #expect(answers.count > 1)
        let texts = answers.filter { !$0.isRefusal }.map(\.text)
        for (earlier, later) in zip(texts, texts.dropFirst()) {
            #expect(later.hasPrefix(earlier))
            #expect(later.count >= earlier.count)
        }
        #expect(answers.last?.text == "Postgres next sprint [1:40].")
    }

    // MARK: - Top-k

    @Test("retrieval offers at most k chunks")
    func topKBoundsCitations() async throws {
        let engine = ScriptedTextEngine(chunks: ["Answer [0:00]."])
        let (pipeline, id, _, chunkCount, root) = try await fixture(engine: engine)
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(chunkCount > QAPipeline.topK)   // there is something to exclude

        let answers = try await collect(
            await pipeline.answer(question: "Tell me about the budget.", meetingID: id) { _, _ in }
        )
        let final = try #require(answers.last)
        #expect(final.isRefusal == false)
        #expect(final.citations.count == QAPipeline.topK)
    }

    // MARK: - Validation

    @Test("an empty question throws without retrieving or generating")
    func emptyQuestionThrows() async throws {
        let engine = ScriptedTextEngine(chunks: ["unused"])
        let (pipeline, id, manager, _, root) = try await fixture(engine: engine)
        defer { try? FileManager.default.removeItem(at: root) }

        var thrown: Error?
        do {
            _ = try await collect(
                await pipeline.answer(question: "   ", meetingID: id) { _, _ in }
            )
        } catch {
            thrown = error
        }

        guard case .emptyQuestion? = thrown as? QAError else {
            Issue.record("Expected emptyQuestion, got \(String(describing: thrown))")
            return
        }
        #expect(manager.ensureCalls == 0)
    }
}
