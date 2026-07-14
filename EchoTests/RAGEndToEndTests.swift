//
//  RAGEndToEndTests.swift
//  EchoTests
//
//  Acceptance-gated (ECHO_ACCEPTANCE=1): real EmbeddingGemma + real Gemma, real
//  retrieval and generation end to end (SPEC-06 §5.5). Builds a synthetic
//  meeting with a distinctive fact buried mid-transcript, indexes it with the
//  real embedding model, and asks two questions: one whose answer is present
//  (must be recalled and cited at the right timestamp) and one whose answer is
//  absent (must be refused, never invented). Constructed text segments (no
//  audio) are the sanctioned fixture style for LLM tests (workflow §0.5).
//
//  This is also where the relevance floor (QAPipeline.relevanceFloor, 0.30) is
//  validated against the real model. If the absent-question refusal fails or the
//  present-question is wrongly refused, that is the SPEC-06 §7.1 signal to
//  remeasure the floor and confirm a new value with the user.
//

import Foundation
import Testing
@testable import Echo

private let acceptanceEnabled = ProcessInfo.processInfo.environment["ECHO_ACCEPTANCE"] == "1"

@Suite("RAG Q&A E2E", .enabled(if: acceptanceEnabled))
struct RAGEndToEndTests {

    /// Split by topic so retrieval has real choices; the budget fact sits in the
    /// middle group, not the first or last line.
    private static let config = ChunkingConfig(
        targetTokens: 60, hardMaxTokens: 120, overlapTokens: 10,
        longGap: 10, turnGap: 4, minChunkTokens: 1
    )

    /// The budget fact is at group index 2 → time base 200 s.
    private static let budgetTime: TimeInterval = 200

    private func meeting() -> [TranscriptSegment] {
        let groups: [[(Speaker, String)]] = [
            [(.teammates, "Let's kick off with the mobile app redesign timeline."),
             (.me, "The new navigation is done; visual polish is the last piece.")],
            [(.teammates, "Next, the hiring plan for the platform team."),
             (.me, "We agreed to open two backend roles this quarter.")],
            [(.teammates, "Now finances. What number are we committing for Q3?"),
             (.me, "The budget for Q3 was set to 40k, final."),
             (.teammates, "Great, 40k for Q3 it is.")],
            [(.teammates, "Marketing wants the launch date locked."),
             (.me, "We ship the beta on Friday, no change there.")],
            [(.teammates, "Last item: the analytics vendor contract."),
             (.me, "Still unsigned; legal is reviewing it this week.")],
        ]
        var segments: [TranscriptSegment] = []
        for (groupIndex, group) in groups.enumerated() {
            let base = TimeInterval(groupIndex * 100)
            for (lineIndex, line) in group.enumerated() {
                let start = base + TimeInterval(lineIndex * 5)
                segments.append(TranscriptSegment(
                    channel: line.0 == .me ? .microphone : .system,
                    speaker: line.0, text: line.1, start: start, end: start + 4
                ))
            }
        }
        return segments
    }

    private func makePipeline() async throws -> (QAPipeline, UUID, URL) {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "RAGEndToEndTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        let store = MeetingStore(rootDirectory: root)
        let segments = meeting()
        let id = UUID()
        let meta = MeetingMeta(
            id: id, title: "E2E", startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            endedAt: Date(timeIntervalSince1970: 1_700_000_600),
            segmentCount: segments.count, hasSummary: false
        )
        try await store.save(MeetingRecord(meta: meta, segments: segments, summary: nil))

        let embeddings = EmbeddingsService()
        let indexStore = RAGIndexStore(meetingStore: store, embeddings: embeddings, chunkingConfig: Self.config)
        let pipeline = QAPipeline(
            indexStore: indexStore, embeddings: embeddings, modelManager: SummaryModelManager()
        )
        return (pipeline, id, root)
    }

    private func finalAnswer(
        _ pipeline: QAPipeline, question: String, meetingID: UUID
    ) async throws -> QAAnswer {
        var last: QAAnswer?
        for try await answer in await pipeline.answer(question: question, meetingID: meetingID, progress: { phase, fraction in
            print("[RAG-E2E] \(phase) \(Int(fraction * 100))%")
        }) {
            last = answer
        }
        return try #require(last)
    }

    @Test("a buried fact is recalled with the right timestamp; an absent fact is refused")
    func recallAndRefuse() async throws {
        let (pipeline, id, root) = try await makePipeline()
        defer { try? FileManager.default.removeItem(at: root) }

        // 1. Present fact → grounded recall, cited at the budget group's time.
        let present = try await finalAnswer(pipeline, question: "What was the Q3 budget?", meetingID: id)
        print("[RAG-E2E] present answer: \(present.text)")
        #expect(present.isRefusal == false)
        #expect(present.text.contains("40"))
        #expect(!present.citations.isEmpty)
        let citesBudget = present.citations.contains { $0.start <= Self.budgetTime && $0.end >= Self.budgetTime }
        #expect(citesBudget)

        // 2. Absent fact → honest refusal, no invention. The refusal can come
        // from the relevance floor (deterministic, no LLM) OR from the LLM
        // itself disclaiming coverage — both are correct grounding behavior.
        // Which one fires depends on the retrieval score, which is chunk-size
        // dependent; the floor's own no-LLM path is covered by QAPipelineTests.
        let absent = try await finalAnswer(
            pipeline, question: "What did they decide about the office cafeteria menu?", meetingID: id
        )
        print("[RAG-E2E] absent answer: isRefusal=\(absent.isRefusal) text=\(absent.text)")
        #expect(absent.isRefusal || Self.disclaimsCoverage(absent.text))

        // 3. Opinion request → must NOT editorialize; it declines to give a
        // personal view and stays anchored to the meeting (grounding rule).
        let opinion = try await finalAnswer(
            pipeline, question: "What is your personal opinion — should they ship on Friday?", meetingID: id
        )
        print("[RAG-E2E] opinion answer: isRefusal=\(opinion.isRefusal) text=\(opinion.text)")
        #expect(opinion.isRefusal || Self.declinesOpinion(opinion.text) || Self.disclaimsCoverage(opinion.text))
    }

    /// True if an English answer signals it will only answer from the meeting
    /// rather than volunteering a personal opinion.
    private static func declinesOpinion(_ text: String) -> Bool {
        let lower = text.lowercased()
        let signals = ["only answer", "can only", "based on the", "based on what",
                       "from the meeting", "from what was said", "i can't provide",
                       "cannot provide", "not able to", "don't have", "do not have"]
        return signals.contains { lower.contains($0) }
    }

    /// True if an English answer explicitly says the meeting/excerpts do not
    /// cover the question (the honest-refusal signal, complementing the
    /// deterministic `isRefusal`).
    private static func disclaimsCoverage(_ text: String) -> Bool {
        let lower = text.lowercased()
        let signals = [
            "not contain", "does not", "doesn't", "do not", "don't",
            "no information", "not mention", "not discuss", "not covered",
            "not provide", "cannot", "can't", "no mention",
        ]
        return signals.contains { lower.contains($0) }
    }
}
