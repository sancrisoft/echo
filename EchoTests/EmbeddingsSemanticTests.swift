//
//  EmbeddingsSemanticTests.swift
//  EchoTests
//
//  Acceptance-gated (ECHO_ACCEPTANCE=1): downloads EmbeddingGemma once into
//  ~/Library/Application Support/Echo/Models and runs real MLX inference, then
//  asserts on externally observable behavior — vectors are unit length, related
//  sentences score higher than unrelated ones (English AND Spanish), and a
//  query retrieves the right document over distractors. Constructed *text* is
//  the sanctioned fixture style (workflow §0.5); no audio involved.
//

import Foundation
import Testing
@testable import Echo

private let acceptanceEnabled = ProcessInfo.processInfo.environment["ECHO_ACCEPTANCE"] == "1"

// `.serialized`: every test builds its own EmbeddingsService, and the parallel
// default would have several of them download the SAME repo into the SAME
// directory at once — HubApi stages weights as a `.incomplete` temp file and
// moves it, so concurrent downloaders clobber each other. Production uses a
// single shared service whose in-flight load is deduplicated, so this
// serialization is a test-harness concern only. It also keeps peak memory sane
// (one model resident at a time).
@Suite("Embeddings semantic", .serialized, .enabled(if: acceptanceEnabled))
struct EmbeddingsSemanticTests {

    private func makeReadyService(truncateTo dimension: Int = EmbeddingsService.nativeDimension)
        async throws -> EmbeddingsService
    {
        let service = EmbeddingsService(truncateTo: dimension)
        try await service.ensureReady { _, _ in }
        return service
    }

    private func norm(_ v: [Float]) -> Float {
        sqrt(v.reduce(into: Float(0)) { $0 += $1 * $1 })
    }

    // MARK: - (a) normalization

    @Test("embeddings are L2-normalized at native and truncated dimensions",
          arguments: [768, 512, 256, 128])
    func vectorsAreUnitLength(dimension: Int) async throws {
        let service = try await makeReadyService(truncateTo: dimension)
        let vectors = try await service.embedDocuments([
            "We agreed to ship the Atlas beta this Friday.",
            "Acordamos lanzar la beta de Atlas este viernes.",
        ])
        for v in vectors {
            #expect(v.count == dimension)
            #expect(abs(norm(v) - 1) < 1e-3)
        }
        let query = try await service.embedQuery("when do we launch?")
        #expect(query.count == dimension)
        #expect(abs(norm(query) - 1) < 1e-3)
    }

    // MARK: - (b) semantic sanity, English + Spanish

    @Test("related sentences score higher than unrelated ones (English)")
    func semanticSanityEnglish() async throws {
        let service = try await makeReadyService()
        let vectors = try await service.embedDocuments([
            "we decided to ship on Friday",   // 0 anchor
            "the launch date was agreed",     // 1 related
            "my cat sleeps all day",          // 2 unrelated
        ])
        let related = VectorMath.cosineSimilarity(vectors[0], vectors[1])
        let unrelated = VectorMath.cosineSimilarity(vectors[0], vectors[2])
        #expect(related > unrelated)
    }

    @Test("related sentences score higher than unrelated ones (Spanish)")
    func semanticSanitySpanish() async throws {
        let service = try await makeReadyService()
        let vectors = try await service.embedDocuments([
            "decidimos lanzar el viernes",        // 0 anchor
            "la fecha de lanzamiento fue acordada", // 1 related
            "mi gato duerme todo el día",         // 2 unrelated
        ])
        let related = VectorMath.cosineSimilarity(vectors[0], vectors[1])
        let unrelated = VectorMath.cosineSimilarity(vectors[0], vectors[2])
        #expect(related > unrelated)
    }

    // MARK: - (c) query-vs-document retrieval

    @Test("a query retrieves the relevant chunk over distractors")
    func queryRanksRelevantDocument() async throws {
        let service = try await makeReadyService()
        let documents = [
            "The team debated which coffee machine to buy for the office kitchen.", // distractor
            "We agreed the product launch will happen on the last Friday of March.", // relevant
            "Someone mentioned the parking garage will be repainted next month.",     // distractor
        ]
        let docVectors = try await service.embedDocuments(documents)
        let queryVector = try await service.embedQuery("when do we launch?")

        let ranking = VectorMath.topK(query: queryVector, candidates: docVectors, k: docVectors.count)
        #expect(ranking.first?.index == 1)
    }
}
