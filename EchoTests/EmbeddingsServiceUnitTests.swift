//
//  EmbeddingsServiceUnitTests.swift
//  EchoTests
//
//  Pure-logic coverage for EmbeddingsService (SPEC-04) that needs no model:
//  Matryoshka truncation + re-normalization, the configured output dimension,
//  and empty-input rejection (validated before any model load). Runs on every
//  plain test invocation.
//

import Foundation
import Testing
@testable import Echo

struct EmbeddingsServiceUnitTests {

    private let tolerance: Float = 1e-5

    private func isUnitLength(_ v: [Float]) -> Bool {
        var sumSq: Float = 0
        for x in v { sumSq += x * x }
        return abs(sqrt(sumSq) - 1) < 1e-3
    }

    // MARK: - Matryoshka truncation

    @Test("matryoshka truncates to the target dimension and re-normalizes", arguments: [128, 256, 512])
    func matryoshkaTruncatesAndRenormalizes(dimension: Int) {
        // A non-unit native vector; matryoshka must both shorten AND re-normalize.
        let native = (0..<EmbeddingsService.nativeDimension).map { Float($0 % 7) + 1 }
        let truncated = EmbeddingsService.matryoshka(native, to: dimension)

        #expect(truncated.count == dimension)
        #expect(isUnitLength(truncated))
        // Equivalent to normalizing the raw prefix.
        let expected = VectorMath.l2Normalized(Array(native.prefix(dimension)))
        for (a, b) in zip(truncated, expected) { #expect(abs(a - b) < tolerance) }
    }

    @Test("matryoshka at the native dimension normalizes without dropping dims")
    func matryoshkaNativeIsFullWidth() {
        let native = (0..<EmbeddingsService.nativeDimension).map { _ in Float(2) }
        let out = EmbeddingsService.matryoshka(native, to: EmbeddingsService.nativeDimension)
        #expect(out.count == EmbeddingsService.nativeDimension)
        #expect(isUnitLength(out))
    }

    // MARK: - Configured dimension

    @Test("dimension reflects the truncation passed to init")
    func dimensionMatchesInit() {
        #expect(EmbeddingsService().dimension == EmbeddingsService.nativeDimension)
        #expect(EmbeddingsService(truncateTo: 256).dimension == 256)
    }

    // MARK: - Empty-input rejection (no model load)

    @Test("embedQuery rejects empty and whitespace-only input")
    func embedQueryRejectsEmpty() async {
        let service = EmbeddingsService()
        await #expect(throws: EmbeddingsError.self) { try await service.embedQuery("") }
        await #expect(throws: EmbeddingsError.self) { try await service.embedQuery("   \n\t") }
    }

    @Test("embedDocuments rejects a batch containing an empty string")
    func embedDocumentsRejectsEmptyElement() async {
        let service = EmbeddingsService()
        await #expect(throws: EmbeddingsError.self) {
            _ = try await service.embedDocuments(["a valid chunk", "   "])
        }
    }

    @Test("embedDocuments returns empty for an empty batch")
    func embedDocumentsEmptyBatch() async throws {
        let service = EmbeddingsService()
        let result = try await service.embedDocuments([])
        #expect(result.isEmpty)
    }
}
