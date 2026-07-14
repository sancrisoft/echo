//
//  QAPipeline.swift
//  Echo
//
//  Grounded question answering over ONE recorded meeting (SPEC-06). The flow is
//  strictly retrieval-first: embed the question, take the exact top-k chunks of
//  the meeting's RAG index by cosine similarity, and — only if the best match
//  clears a relevance floor — ask the local LLM to answer using ONLY those
//  excerpts. Below the floor the pipeline refuses without ever calling the
//  model, so the app can never answer from the model's own knowledge (the
//  grounding rule in AGENTS.md / _workflow.md §0.3).
//
//  Retrieval math is `VectorMath.topK` (SPEC-04) over vectors held in memory —
//  no vector DB (SPEC-06 §2). The generative engine is the same Gemma the
//  summarizer uses, reached through the `SummaryModelManager`; the
//  `TextEngineProviding` seam below lets tests inject a scripted engine without
//  touching SPEC-01.
//

import Foundation
import os

// MARK: - Engine seam

/// The slice of `SummaryModelManager` this feature needs, as a protocol so
/// tests can drive the full answer path with a scripted `TextGenerating`
/// (SPEC-06 §5.3) instead of a real model. Declared here — SPEC-01 is consumed
/// unchanged and conforms via the extension below.
protocol TextEngineProviding: Sendable {
    func ensureReady(progress: @Sendable @escaping (String, Double) -> Void) async throws -> any TextGenerating
    func cachedModelExists() async -> Bool
}

extension SummaryModelManager: TextEngineProviding {}

// MARK: - Output

/// A time range of a retrieved chunk the answer is grounded in.
struct QACitation: Hashable, Sendable {
    let start: TimeInterval
    let end: TimeInterval
}

/// A streamed answer snapshot. `text` grows token by token; `citations` are the
/// time ranges of the chunks actually offered to the model (fixed for the whole
/// answer). `isRefusal` marks the relevance-floor "not covered" response, which
/// never touches the model.
struct QAAnswer: Hashable, Sendable {
    var text: String
    var citations: [QACitation]      // time ranges of the retrieved chunks actually offered
    var isRefusal: Bool              // relevance floor hit
}

enum QAError: LocalizedError {
    case emptyQuestion
    case modelUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .emptyQuestion:
            return "Ask a question first."
        case .modelUnavailable(let message):
            return "The answer model is unavailable: \(message)"
        }
    }
}

// MARK: - Pipeline

actor QAPipeline {

    /// Number of chunks retrieved and offered to the model.
    static let topK = 4

    /// Cosine-similarity floor (dot product on normalized vectors) below which
    /// the meeting is judged not to cover the question and the pipeline refuses
    /// WITHOUT calling the LLM. Calibrated at 0.40 against EmbeddingGemma
    /// (SPEC-06 §7.1, measured 2026-07-14 + confirmed with the user): on-topic
    /// questions score ≥0.43 and clearly off-topic ones ≤0.39, so 0.40 sits in
    /// the gap — it catches blatant off-topic at retrieval time while the LLM,
    /// prompted to answer only from the excerpts, remains the backstop for the
    /// borderline band (it refuses honestly on its own). The initial 0.30 let
    /// nearly every off-topic question through the floor, so it was raised.
    static let relevanceFloor: Float = 0.40

    /// Fixed response when retrieval is too weak (never model-generated).
    static let refusalText = "This meeting doesn't seem to cover that."

    /// Lower temperature than the summarizer: Q&A wants faithful recall, not
    /// creative prose, and answers are short so `maxTokens` is modest.
    static let params = GenerationParams(
        temperature: 0.2,
        topP: 0.9,
        maxTokens: 1024,
        repetitionPenalty: 1.1,
        frequencyPenalty: 0.3,
        presencePenalty: 0.2
    )

    private static let log = Logger(subsystem: "com.sancrisoft.Echo", category: "QAPipeline")

    private let indexStore: RAGIndexStore
    private let embeddings: any RAGEmbedding
    private let modelManager: any TextEngineProviding

    init(
        indexStore: RAGIndexStore,
        embeddings: any RAGEmbedding,
        modelManager: any TextEngineProviding
    ) {
        self.indexStore = indexStore
        self.embeddings = embeddings
        self.modelManager = modelManager
    }

    /// Streams the growing answer for `question` about `meetingID`. Each element
    /// is a snapshot of the answer so far, carrying the citations for the chunks
    /// it is grounded in; a refusal is a single element with `isRefusal == true`.
    /// Terminating the stream cancels the underlying generation, so the caller
    /// can cancel an in-flight question by starting a new one.
    func answer(
        question: String,
        meetingID: UUID,
        progress: @Sendable @escaping (String, Double) -> Void
    ) -> AsyncThrowingStream<QAAnswer, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await self.run(
                        question: question,
                        meetingID: meetingID,
                        progress: progress,
                        into: continuation
                    )
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func run(
        question: String,
        meetingID: UUID,
        progress: @Sendable @escaping (String, Double) -> Void,
        into continuation: AsyncThrowingStream<QAAnswer, Error>.Continuation
    ) async throws {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw QAError.emptyQuestion }

        // 1. Index (build lazily on first use, then reused). Reports its own
        //    download/load/indexing progress.
        let index = try await indexStore.index(for: meetingID, progress: progress)
        try Task.checkCancellation()

        // 2. Retrieval: embed the question, exact top-k cosine over the chunks.
        let queryVector = try await embeddings.embedQuery(trimmed)
        try Task.checkCancellation()

        let ranked = VectorMath.topK(
            query: queryVector,
            candidates: index.chunks.map(\.vector),
            k: Self.topK
        )

        // 3. Relevance floor → refuse without touching the model.
        guard let best = ranked.first, best.score >= Self.relevanceFloor else {
            Self.log.info("Refusing (maxScore=\(ranked.first?.score ?? -1, privacy: .public) < floor \(Self.relevanceFloor, privacy: .public))")
            continuation.yield(QAAnswer(text: Self.refusalText, citations: [], isRefusal: true))
            return
        }

        // Present excerpts (and cite) in chronological order — easier to read
        // than similarity order and stable regardless of scores.
        let retrieved = ranked
            .map { index.chunks[$0.index] }
            .sorted { $0.start < $1.start }
        let citations = retrieved.map { QACitation(start: $0.start, end: $0.end) }

        // 4. Grounded generation over ONLY the retrieved excerpts.
        let engine = try await modelManager.ensureReady(progress: progress)
        try Task.checkCancellation()

        let system = Self.systemPrompt
        let user = Self.userPrompt(question: trimmed, chunks: retrieved)

        var text = ""
        var yielded = false
        do {
            for try await delta in engine.stream(system: system, user: user, params: Self.params) {
                try Task.checkCancellation()
                guard !delta.isEmpty else { continue }
                text += delta
                continuation.yield(QAAnswer(text: text, citations: citations, isRefusal: false))
                yielded = true
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw QAError.modelUnavailable(error.localizedDescription)
        }

        // Guarantee at least one element carrying the citations, even if the
        // model emitted nothing.
        if !yielded {
            continuation.yield(QAAnswer(text: text, citations: citations, isRefusal: false))
        }
    }

    // MARK: - Prompt

    /// Verbatim from SPEC-06 §4 (binding skeleton, written out in full). The
    /// "use ONLY the excerpts / never outside knowledge" instruction is the
    /// second half of the grounding guarantee — the relevance floor is the
    /// first, and it runs before this prompt is ever built.
    static let systemPrompt = """
    You answer questions about one recorded meeting for a local-first macOS \
    app. Use ONLY the transcript excerpts provided by the user. If the excerpts \
    do not contain the answer, say so plainly. Never use outside knowledge. \
    Cite the timestamps of the excerpts you rely on, in [m:ss] form. "You" is \
    the current user; "Team" is the teammates. Answer in the language of the \
    question.
    """

    static func userPrompt(question: String, chunks: [RAGIndexedChunk]) -> String {
        var parts: [String] = ["Excerpts from the meeting (each with its time range):", ""]
        for (offset, chunk) in chunks.enumerated() {
            parts.append("Excerpt \(offset + 1) [\(timestamp(chunk.start))–\(timestamp(chunk.end))]:")
            parts.append(chunk.text)
            parts.append("---")
        }
        parts.append("Question: \(question)")
        return parts.joined(separator: "\n")
    }

    /// `m:ss` under one hour, `h:mm:ss` at or above — matches
    /// `TranscriptChunk`/`SummarizationPipeline`.
    private static func timestamp(_ value: TimeInterval) -> String {
        let total = Int(value)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }
}
