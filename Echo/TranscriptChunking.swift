//
//  TranscriptChunking.swift
//  Echo
//
//  Deterministic, pure-Swift assembly of the ordered TranscriptSegment stream
//  into overlapping, token-bounded TranscriptChunks.
//
//  Why this exists
//  ---------------
//  The current summarizer sends the whole transcript in a single prompt. That
//  does not scale: a one-hour meeting is ~12-15K tokens, three hours is >40K,
//  and quality degrades ("lost in the middle") well before the context is full.
//  Downstream features need the transcript pre-cut into digestible pieces:
//    - SPEC-05 (map-reduce): per-chunk structured extraction → merge. Needs
//      segment IDs preserved (evidence references segment UUIDs), a token budget
//      compatible with the extraction prompt (~4-8K), and overlap marked so the
//      same fact is not double-counted across chunks.
//    - SPEC-06 (RAG): one embedding per chunk. Needs plain text with speakers
//      and a time range, and stability (same transcript → same chunks).
//    - SPEC-07 (live): close chunks in-flight during recording. Needs the
//      incremental `ingest(_:) -> chunk?` + `flush()` API.
//
//  Design principles
//  -----------------
//  * Natural boundaries: chunks close at conversational seams — long silences
//    first, then speaker changes with a gap, and only as a last resort a hard
//    token cut. A segment is never split; boundaries fall between segments.
//  * No loss, no duplication: concatenating every chunk's `newSegments`
//    reproduces the input exactly. Overlap only repeats already-emitted
//    segments and is flagged in `overlapSegmentIDs`.
//  * Deterministic and pure: same input + config → same output. No clock, no
//    randomness, no I/O, no model calls.
//  * Incremental ≡ batch: `TranscriptChunker.chunks(from:config:)` is literally
//    an `ChunkAssembler` pass, so live and batch consumers get identical output.
//

import Foundation

// MARK: - Token estimation

/// Estimates LLM token counts without pulling in a tokenizer dependency.
///
/// The heuristic default keeps this module model-agnostic; SPEC-05 may inject a
/// real tokenizer later through this same seam.
protocol TokenEstimating: Sendable {
    func estimate(_ text: String) -> Int
}

/// `ceil(unicodeScalars / 4)`, with a minimum of 1 for any non-empty text
/// (empty text is 0). This deliberately leans toward *over*estimation for
/// Latin-script meeting speech, so chunks stay comfortably under real
/// tokenizer limits rather than risking an overflow at prompt time.
struct HeuristicTokenEstimator: TokenEstimating {
    func estimate(_ text: String) -> Int {
        let scalars = text.unicodeScalars.count
        guard scalars > 0 else { return 0 }
        // ceil(scalars / 4) via integer arithmetic, floored at 1.
        return max(1, (scalars + 3) / 4)
    }
}

// MARK: - Configuration

/// Tunables for where chunk boundaries fall. Defaults target ~6K-token chunks
/// with ~10% overlap, cut at conversational seams.
struct ChunkingConfig: Sendable {
    /// Aim to close a chunk once it reaches this size.
    var targetTokens: Int = 6_000
    /// Never exceed this — except a single segment that is itself larger.
    var hardMaxTokens: Int = 8_000
    /// Roughly 10% of `targetTokens`, taken from the tail of the previous chunk.
    var overlapTokens: Int = 600
    /// Inter-segment silence that always closes a chunk (once past `minChunkTokens`).
    var longGap: TimeInterval = 20
    /// A speaker change plus at least this gap closes a chunk past `targetTokens`.
    var turnGap: TimeInterval = 8
    /// Don't close on a gap while the chunk is still this small.
    var minChunkTokens: Int = 800

    init(
        targetTokens: Int = 6_000,
        hardMaxTokens: Int = 8_000,
        overlapTokens: Int = 600,
        longGap: TimeInterval = 20,
        turnGap: TimeInterval = 8,
        minChunkTokens: Int = 800
    ) {
        self.targetTokens = targetTokens
        self.hardMaxTokens = hardMaxTokens
        self.overlapTokens = overlapTokens
        self.longGap = longGap
        self.turnGap = turnGap
        self.minChunkTokens = minChunkTokens
    }
}

// MARK: - Chunk

/// A contiguous, token-bounded slice of the transcript.
///
/// `segments` is the overlap head (repeated from the previous chunk) followed by
/// this chunk's new segments, in timeline order. `newSegments` is what this
/// chunk contributes for the first time; concatenating `newSegments` across all
/// chunks reproduces the source transcript exactly.
struct TranscriptChunk: Identifiable, Hashable, Sendable {
    /// 0-based, contiguous across a run.
    let index: Int
    /// Overlap head + new segments, in order. Never empty for an emitted chunk.
    let segments: [TranscriptSegment]
    /// IDs repeated from the previous chunk's tail (the overlap head).
    let overlapSegmentIDs: Set<UUID>
    /// Token estimate over ALL segments, overlap included.
    let tokenEstimate: Int

    var id: Int { index }

    /// This chunk's segments minus the overlap head — its unique contribution.
    var newSegments: [TranscriptSegment] {
        segments.filter { !overlapSegmentIDs.contains($0.id) }
    }

    /// First segment's start (relative seconds).
    var start: TimeInterval { segments.first?.start ?? 0 }
    /// Last segment's end (relative seconds).
    var end: TimeInterval { segments.last?.end ?? 0 }

    /// One line per segment, e.g.
    /// `"[3:05–3:12] You: …\n[3:13–3:30] Others: …"`.
    /// Uses `Speaker.displayName` and the same `m:ss` / `h:mm:ss` rule as
    /// `SummarizationPipeline.timestamp`.
    var plainText: String {
        segments
            .map { segment in
                let start = Self.timestamp(segment.start)
                let end = Self.timestamp(segment.end)
                return "[\(start)–\(end)] \(segment.speaker.displayName): \(segment.text)"
            }
            .joined(separator: "\n")
    }

    /// `m:ss` under one hour, `h:mm:ss` at or above (matches
    /// `SummarizationPipeline.timestamp`).
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

// MARK: - Incremental assembler

/// The incremental core. Feed final segments in timeline order; a chunk is
/// emitted the moment its boundary is decided, and `flush()` closes whatever
/// remains at end of session.
///
/// The boundary after a segment can only be judged once the *next* segment
/// arrives (that is when the inter-segment gap is known), so the close decision
/// is evaluated when ingesting the incoming segment, *before* it is appended.
struct ChunkAssembler: Sendable {
    private let config: ChunkingConfig
    private let estimator: any TokenEstimating

    /// Segments accumulated for the chunk currently under construction: the
    /// overlap head (if any) followed by new segments, in order.
    private var pending: [TranscriptSegment] = []
    /// The overlap-head IDs seeded into `pending` from the previous close.
    private var overlapIDs: Set<UUID> = []
    /// Running token sum over `pending` (overlap included).
    private var runningTokens: Int = 0
    /// Per-segment token estimates, cached so overlap re-selection is free.
    private var tokenCache: [UUID: Int] = [:]
    /// Next chunk index to emit.
    private var nextIndex: Int = 0

    init(config: ChunkingConfig = .init(), estimator: any TokenEstimating = HeuristicTokenEstimator()) {
        self.config = config
        self.estimator = estimator
    }

    /// Ingest the next segment in timeline order. Returns a chunk if the segment
    /// that arrived forced the previous chunk to close, otherwise nil.
    mutating func ingest(_ segment: TranscriptSegment) -> TranscriptChunk? {
        // Fresh chunk (first ever, or seeded with an empty overlap): just start it.
        guard let last = pending.last else {
            append(segment)
            return nil
        }

        // The chunk only closes on content it actually owns — never while it
        // still holds nothing but the repeated overlap head.
        let hasNewContent = pending.count > overlapIDs.count
        var shouldClose = false

        if hasNewContent {
            let gap = segment.start - last.end
            let speakerChanged = segment.speaker != last.speaker

            if runningTokens >= config.minChunkTokens && gap >= config.longGap {
                // 1. Long silence — the strongest natural boundary.
                shouldClose = true
            } else if runningTokens >= config.targetTokens
                && ((gap >= config.turnGap && speakerChanged) || gap >= config.longGap) {
                // 2. Past target and a turn/pause seam presents itself.
                shouldClose = true
            } else if runningTokens + tokens(for: segment) > config.hardMaxTokens {
                // 3. Last resort: adding this segment would blow the hard max.
                shouldClose = true
            }
        }

        if shouldClose {
            let chunk = closeChunk()
            append(segment)
            return chunk
        }

        append(segment)
        return nil
    }

    /// Close whatever remains, however small (parity with the pipeline's
    /// end-of-session flush). Returns nil when there is no new content pending.
    mutating func flush() -> TranscriptChunk? {
        guard pending.count > overlapIDs.count else {
            // Nothing pending, or nothing but a stale overlap head — no chunk.
            reset()
            return nil
        }
        let chunk = closeChunk()
        reset()
        return chunk
    }

    // MARK: Internals

    private func tokens(for segment: TranscriptSegment) -> Int {
        tokenCache[segment.id] ?? estimator.estimate(segment.text)
    }

    private mutating func append(_ segment: TranscriptSegment) {
        let count = tokenCache[segment.id] ?? estimator.estimate(segment.text)
        tokenCache[segment.id] = count
        pending.append(segment)
        runningTokens += count
    }

    /// Build the chunk from `pending`, then re-seed `pending` with the overlap
    /// head for the next chunk (tail of the just-closed chunk, newest→oldest,
    /// until `overlapTokens` is reached, never more than half its segments).
    private mutating func closeChunk() -> TranscriptChunk {
        let chunk = TranscriptChunk(
            index: nextIndex,
            segments: pending,
            overlapSegmentIDs: overlapIDs,
            tokenEstimate: runningTokens
        )
        nextIndex += 1

        let maxOverlapCount = pending.count / 2
        var seed: [TranscriptSegment] = []
        var seedTokens = 0
        if maxOverlapCount > 0 {
            for segment in pending.reversed() {
                if seed.count >= maxOverlapCount { break }
                seed.append(segment)
                seedTokens += tokens(for: segment)
                if seedTokens >= config.overlapTokens { break }
            }
            seed.reverse() // restore chronological order
        }

        pending = seed
        overlapIDs = Set(seed.map(\.id))
        runningTokens = seedTokens
        return chunk
    }

    private mutating func reset() {
        pending = []
        overlapIDs = []
        runningTokens = 0
    }
}

// MARK: - Batch convenience

/// Batch entry point. Internally a single `ChunkAssembler` pass, so its output
/// is guaranteed identical to feeding the same segments in one at a time and
/// calling `flush()`.
enum TranscriptChunker {
    static func chunks(
        from segments: [TranscriptSegment],
        config: ChunkingConfig = .init(),
        estimator: any TokenEstimating = HeuristicTokenEstimator()
    ) -> [TranscriptChunk] {
        var assembler = ChunkAssembler(config: config, estimator: estimator)
        var chunks: [TranscriptChunk] = []
        for segment in segments {
            if let chunk = assembler.ingest(segment) {
                chunks.append(chunk)
            }
        }
        if let last = assembler.flush() {
            chunks.append(last)
        }
        return chunks
    }
}
