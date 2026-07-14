//
//  VectorMathTests.swift
//  EchoTests
//
//  Pure-logic coverage for the retrieval math (SPEC-04). No model, no network,
//  no fixtures — these run on every plain test invocation.
//

import Foundation
import Testing
@testable import Echo

struct VectorMathTests {

    private let tolerance: Float = 1e-5

    // MARK: - l2Normalized

    @Test("l2Normalized produces a unit vector")
    func normalizeGivesUnitLength() {
        let v: [Float] = [3, 4]           // ‖v‖ = 5
        let n = VectorMath.l2Normalized(v)
        #expect(abs(n[0] - 0.6) < tolerance)
        #expect(abs(n[1] - 0.8) < tolerance)

        var sumSq: Float = 0
        for x in n { sumSq += x * x }
        #expect(abs(sqrt(sumSq) - 1) < tolerance)
    }

    @Test("l2Normalized leaves an already-unit vector unchanged")
    func normalizeIdempotentOnUnit() {
        let unit: [Float] = [0, 1, 0, 0]
        let n = VectorMath.l2Normalized(unit)
        for (a, b) in zip(unit, n) { #expect(abs(a - b) < tolerance) }
    }

    @Test("l2Normalized returns the zero vector unchanged (no NaNs)")
    func normalizeZeroVector() {
        let zero: [Float] = [0, 0, 0]
        let n = VectorMath.l2Normalized(zero)
        #expect(n == zero)
        #expect(!n.contains { $0.isNaN })
    }

    // MARK: - cosineSimilarity

    @Test("cosineSimilarity of identical unit vectors is 1")
    func cosineIdentical() {
        let a = VectorMath.l2Normalized([1, 2, 3])
        #expect(abs(VectorMath.cosineSimilarity(a, a) - 1) < tolerance)
    }

    @Test("cosineSimilarity of orthogonal vectors is 0")
    func cosineOrthogonal() {
        let a: [Float] = [1, 0]
        let b: [Float] = [0, 1]
        #expect(abs(VectorMath.cosineSimilarity(a, b)) < tolerance)
    }

    @Test("cosineSimilarity of opposite unit vectors is -1")
    func cosineOpposite() {
        let a: [Float] = [1, 0, 0]
        let b: [Float] = [-1, 0, 0]
        #expect(abs(VectorMath.cosineSimilarity(a, b) + 1) < tolerance)
    }

    @Test("cosineSimilarity equals the hand-computed dot product")
    func cosineKnownValue() {
        // Normalized so the dot product is a genuine cosine; 45° apart → √2/2.
        let a = VectorMath.l2Normalized([1, 0])
        let b = VectorMath.l2Normalized([1, 1])
        #expect(abs(VectorMath.cosineSimilarity(a, b) - (sqrt(2) / 2)) < tolerance)
    }

    // MARK: - topK

    @Test("topK ranks by descending score and honors k")
    func topKRanksDescending() {
        let query: [Float] = [1, 0]
        let candidates: [[Float]] = [
            [0, 1],           // score 0
            [1, 0],           // score 1  (best)
            [-1, 0],          // score -1 (worst)
            VectorMath.l2Normalized([1, 1]),  // score √2/2
        ]
        let top = VectorMath.topK(query: query, candidates: candidates, k: 2)
        #expect(top.map(\.index) == [1, 3])
        #expect(top[0].score > top[1].score)
    }

    @Test("topK breaks ties by ascending index (stable)")
    func topKStableOnTies() {
        let query: [Float] = [1, 0]
        // Three identical top candidates (score 1) interleaved with a loser.
        let candidates: [[Float]] = [
            [1, 0],   // 0 — tie
            [0, 1],   // 1 — loser
            [1, 0],   // 2 — tie
            [1, 0],   // 3 — tie
        ]
        let top = VectorMath.topK(query: query, candidates: candidates, k: 3)
        #expect(top.map(\.index) == [0, 2, 3])
    }

    @Test("topK clamps k to the candidate count")
    func topKClampsK() {
        let query: [Float] = [1, 0]
        let candidates: [[Float]] = [[1, 0], [0, 1]]
        #expect(VectorMath.topK(query: query, candidates: candidates, k: 99).count == 2)
    }

    @Test("topK returns empty for non-positive k or no candidates")
    func topKEmptyCases() {
        let query: [Float] = [1, 0]
        #expect(VectorMath.topK(query: query, candidates: [[1, 0]], k: 0).isEmpty)
        #expect(VectorMath.topK(query: query, candidates: [], k: 3).isEmpty)
    }
}
