//
//  VectorMath.swift
//  Echo
//
//  Pure, allocation-light vector helpers for on-device retrieval (SPEC-06 RAG,
//  SPEC-09 cross-meeting). No vector DB: a year-long library is only a few
//  thousand vectors, so exact brute-force cosine/top-k is both correct and fast
//  enough (see SPEC-06 §2). Numerics go through Accelerate/vDSP — the volume is
//  small, but the primitives are free and keep the code honest about intent.
//
//  All vectors passed in are expected to be L2-normalized (that is what
//  EmbeddingsService returns), which is why `cosineSimilarity` is literally a
//  dot product — see its doc comment.
//

import Accelerate
import Foundation

nonisolated enum VectorMath {

    /// Dot product of `a` and `b`. This equals cosine similarity **iff** both
    /// inputs are L2-normalized (cos θ = a·b / (‖a‖‖b‖), and the denominator is
    /// 1 for unit vectors). `EmbeddingsService` always returns normalized
    /// vectors, so callers get cosine similarity for the price of a dot product.
    ///
    /// - Precondition: `a.count == b.count` (mismatched dimensions are a
    ///   programming error, not a runtime-recoverable condition).
    static func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        precondition(
            a.count == b.count,
            "cosineSimilarity requires equal dimensions (got \(a.count) and \(b.count))"
        )
        guard !a.isEmpty else { return 0 }
        var result: Float = 0
        vDSP_dotpr(a, 1, b, 1, &result, vDSP_Length(a.count))
        return result
    }

    /// Returns `v` scaled to unit L2 norm. A zero (or near-zero) vector cannot
    /// be normalized, so it is returned unchanged rather than producing NaNs.
    static func l2Normalized(_ v: [Float]) -> [Float] {
        guard !v.isEmpty else { return v }
        var sumOfSquares: Float = 0
        vDSP_svesq(v, 1, &sumOfSquares, vDSP_Length(v.count))
        let norm = sqrt(sumOfSquares)
        guard norm > 1e-12 else { return v }
        var scale = 1 / norm
        var out = [Float](repeating: 0, count: v.count)
        vDSP_vsmul(v, 1, &scale, &out, 1, vDSP_Length(v.count))
        return out
    }

    /// Indices of the `k` highest-scoring candidates against `query`, ordered by
    /// descending score. Scoring is `cosineSimilarity` (dot product on the
    /// normalized vectors this module works with).
    ///
    /// Ties are broken by ascending original index, so the result is stable and
    /// deterministic regardless of the sort implementation. `k` is clamped to
    /// `0...candidates.count`.
    ///
    /// - Precondition: every candidate has the same dimension as `query`.
    static func topK(
        query: [Float],
        candidates: [[Float]],
        k: Int
    ) -> [(index: Int, score: Float)] {
        guard k > 0, !candidates.isEmpty else { return [] }
        let scored = candidates.enumerated().map { index, candidate in
            (index: index, score: cosineSimilarity(query, candidate))
        }
        let ranked = scored.sorted { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return lhs.index < rhs.index
        }
        return Array(ranked.prefix(k))
    }
}
