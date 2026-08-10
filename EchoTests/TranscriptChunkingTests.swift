//
//  TranscriptChunkingTests.swift
//  EchoTests
//
//  SPEC-02: deterministic transcript chunking. Constructed text segments only
//  (TranscriptDedupTests precedent) — no audio fixtures.
//

import Testing
import Foundation
@testable import Echo

// MARK: - Token estimator

struct HeuristicTokenEstimatorTests {

    private let estimator = HeuristicTokenEstimator()

    /// ceil(unicodeScalars / 4), min 1 for non-empty, 0 for empty.
    @Test(arguments: [
        ("", 0),
        ("a", 1),
        ("abcd", 1),        // 4 scalars → ceil(4/4) = 1
        ("abcde", 2),       // 5 scalars → ceil(5/4) = 2
        ("café", 1),        // 4 precomposed scalars
        ("😀😀😀😀😀", 2),   // 5 scalars → 2
        (String(repeating: "x", count: 400), 100),
    ])
    func estimateMatchesHeuristic(text: String, expected: Int) {
        #expect(estimator.estimate(text) == expected)
    }
}

// MARK: - Chunking

struct TranscriptChunkingTests {

    // MARK: Segment builders

    /// A segment whose text is sized to `tokens` under the heuristic estimator
    /// (4 scalars per token), so token-driven boundaries are exact in tests.
    private func seg(
        _ speaker: Speaker,
        tokens: Int,
        start: Double,
        end: Double
    ) -> TranscriptSegment {
        let channel: AudioChannel = speaker == .me ? .microphone : .system
        return TranscriptSegment(
            channel: channel,
            speaker: speaker,
            text: String(repeating: "a", count: max(1, tokens) * 4),
            start: start,
            end: end
        )
    }

    // MARK: Boundary cases

    @Test func emptyTranscriptYieldsNoChunks() {
        #expect(TranscriptChunker.chunks(from: []).isEmpty)
    }

    @Test func singleSegmentIsOneChunkWithNoOverlap() {
        let only = seg(.me, tokens: 10, start: 0, end: 4)
        let chunks = TranscriptChunker.chunks(from: [only])

        #expect(chunks.count == 1)
        #expect(chunks[0].index == 0)
        #expect(chunks[0].overlapSegmentIDs.isEmpty)
        #expect(chunks[0].newSegments == [only])
        #expect(chunks[0].start == 0)
        #expect(chunks[0].end == 4)
        #expect(chunks[0].tokenEstimate == 10)
    }

    @Test func shortMeetingFitsInOneChunk() {
        let input = [
            seg(.me, tokens: 20, start: 0, end: 5),
            seg(.teammates, tokens: 20, start: 6, end: 11),
            seg(.me, tokens: 20, start: 12, end: 17),
        ]
        // Small contiguous gaps, well under target → a single chunk.
        let chunks = TranscriptChunker.chunks(from: input, config: .init(targetTokens: 1_000, hardMaxTokens: 1_000))

        #expect(chunks.count == 1)
        #expect(chunks[0].newSegments == input)
    }

    // MARK: Natural boundaries

    @Test func longGapClosesChunk() {
        let config = ChunkingConfig(
            targetTokens: 1_000, hardMaxTokens: 1_000,
            overlapTokens: 4, longGap: 20, turnGap: 8, minChunkTokens: 8
        )
        let a = seg(.me, tokens: 10, start: 0, end: 5)
        let b = seg(.me, tokens: 10, start: 5, end: 10)
        // 30 s of silence before c → long-gap boundary after b.
        let c = seg(.me, tokens: 10, start: 40, end: 45)
        let d = seg(.me, tokens: 10, start: 45, end: 50)

        let chunks = TranscriptChunker.chunks(from: [a, b, c, d], config: config)

        #expect(chunks.count == 2)
        #expect(chunks[0].newSegments.map(\.id) == [a.id, b.id])
        #expect(chunks[1].newSegments.map(\.id) == [c.id, d.id])
    }

    @Test func speakerChangeWithGapClosesChunkPastTarget() {
        let config = ChunkingConfig(
            targetTokens: 20, hardMaxTokens: 1_000,
            overlapTokens: 4, longGap: 20, turnGap: 8, minChunkTokens: 8
        )
        let a = seg(.me, tokens: 12, start: 0, end: 5)
        let b = seg(.me, tokens: 12, start: 5, end: 10) // running 24 ≥ target 20
        // speaker change + 10 s gap (≥ turnGap 8, < longGap 20) → close.
        let c = seg(.teammates, tokens: 12, start: 20, end: 25)

        let chunks = TranscriptChunker.chunks(from: [a, b, c], config: config)

        #expect(chunks.count == 2)
        #expect(chunks[0].newSegments.map(\.id) == [a.id, b.id])
    }

    @Test func sameSpeakerModerateGapPastTargetDoesNotClose() {
        let config = ChunkingConfig(
            targetTokens: 20, hardMaxTokens: 1_000,
            overlapTokens: 4, longGap: 20, turnGap: 8, minChunkTokens: 8
        )
        let a = seg(.me, tokens: 12, start: 0, end: 5)
        let b = seg(.me, tokens: 12, start: 5, end: 10)  // running 24 ≥ target
        // Same speaker, 10 s gap: neither turnGap+change nor longGap → keep going.
        let c = seg(.me, tokens: 12, start: 20, end: 25)

        let chunks = TranscriptChunker.chunks(from: [a, b, c], config: config)

        #expect(chunks.count == 1)
    }

    @Test func hardMaxForcesACut() {
        let config = ChunkingConfig(
            targetTokens: 1_000, hardMaxTokens: 30,
            overlapTokens: 4, longGap: 20, turnGap: 8, minChunkTokens: 8
        )
        // Contiguous, no gaps and no speaker changes: only the hard max can cut.
        let a = seg(.me, tokens: 10, start: 0, end: 5)
        let b = seg(.me, tokens: 10, start: 5, end: 10)
        let c = seg(.me, tokens: 10, start: 10, end: 15) // running would be 30 = max
        let d = seg(.me, tokens: 10, start: 15, end: 20) // 30 + 10 > 30 → cut before d

        let chunks = TranscriptChunker.chunks(from: [a, b, c, d], config: config)

        #expect(chunks.count == 2)
        #expect(chunks[0].newSegments.map(\.id) == [a.id, b.id, c.id])
        #expect(chunks[0].tokenEstimate <= config.hardMaxTokens)
    }

    @Test func oversizedSegmentFormsItsOwnChunk() {
        let config = ChunkingConfig(
            targetTokens: 1_000, hardMaxTokens: 30,
            overlapTokens: 4, longGap: 20, turnGap: 8, minChunkTokens: 8
        )
        let giant = seg(.me, tokens: 100, start: 0, end: 10) // alone exceeds hard max
        let after = seg(.me, tokens: 10, start: 11, end: 15)

        let chunks = TranscriptChunker.chunks(from: [giant, after], config: config)

        #expect(chunks.count == 2)
        #expect(chunks[0].newSegments == [giant])
        #expect(chunks[0].tokenEstimate == 100) // the exception: > hardMax, unsplittable
        #expect(chunks[1].newSegments == [after])
    }

    @Test func loneOversizedSegmentFlushesAsOneChunk() {
        let giant = seg(.me, tokens: 100, start: 0, end: 10)
        let chunks = TranscriptChunker.chunks(from: [giant], config: .init(hardMaxTokens: 30))

        #expect(chunks.count == 1)
        #expect(chunks[0].newSegments == [giant])
    }

    // MARK: Overlap

    @Test func overlapRepeatsPreviousTailAndIsExcludedFromNewSegments() {
        let config = ChunkingConfig(
            targetTokens: 1_000, hardMaxTokens: 1_000,
            overlapTokens: 8, longGap: 20, turnGap: 8, minChunkTokens: 8
        )
        // First chunk = [a, b, c, d] (long gap before e). Overlap for the next
        // chunk: tail newest→oldest until ≥ 8 tokens, capped at half of 4 = 2.
        let a = seg(.me, tokens: 10, start: 0, end: 5)
        let b = seg(.me, tokens: 10, start: 5, end: 10)
        let c = seg(.me, tokens: 10, start: 10, end: 15)
        let d = seg(.me, tokens: 10, start: 15, end: 20)
        let e = seg(.me, tokens: 10, start: 60, end: 65) // 40 s gap → close after d
        let f = seg(.me, tokens: 10, start: 65, end: 70)

        let chunks = TranscriptChunker.chunks(from: [a, b, c, d, e, f], config: config)

        #expect(chunks.count == 2)
        // One tail segment already meets overlapTokens (10 ≥ 8); half-cap allows ≤ 2.
        let overlap = chunks[1].overlapSegmentIDs
        #expect(overlap == [d.id])
        // Overlap segment is the head of chunk 1 and NOT counted as new.
        #expect(chunks[1].segments.first?.id == d.id)
        #expect(chunks[1].newSegments.map(\.id) == [e.id, f.id])
        // Its token estimate includes the overlap head.
        #expect(chunks[1].tokenEstimate == 30) // d + e + f
    }

    @Test func overlapNeverExceedsHalfTheClosedChunk() {
        let config = ChunkingConfig(
            targetTokens: 1_000, hardMaxTokens: 1_000,
            overlapTokens: 1_000, longGap: 20, turnGap: 8, minChunkTokens: 8
        )
        // overlapTokens is huge, so only the half-count cap limits it.
        let first = [
            seg(.me, tokens: 10, start: 0, end: 5),
            seg(.me, tokens: 10, start: 5, end: 10),
            seg(.me, tokens: 10, start: 10, end: 15),
            seg(.me, tokens: 10, start: 15, end: 20),
        ]
        let next = seg(.me, tokens: 10, start: 60, end: 65) // long gap closes first chunk

        let chunks = TranscriptChunker.chunks(from: first + [next], config: config)

        #expect(chunks.count == 2)
        #expect(chunks[1].overlapSegmentIDs.count == 2) // floor(4 / 2)
    }

    // MARK: plainText rendering

    @Test func plainTextRendersOneLinePerSegment() {
        let s1 = TranscriptSegment(channel: .microphone, speaker: .me,
                                   text: "Let's start the standup.", start: 185, end: 192)
        let s2 = TranscriptSegment(channel: .system, speaker: .teammates,
                                   text: "Backend deploy is done.", start: 193, end: 210)
        let chunks = TranscriptChunker.chunks(from: [s1, s2],
                                              config: .init(targetTokens: 1_000, hardMaxTokens: 1_000))

        #expect(chunks.count == 1)
        #expect(chunks[0].plainText ==
            "[3:05–3:12] You: Let's start the standup.\n[3:13–3:30] Others: Backend deploy is done.")
    }

    @Test func plainTextUsesHourFormatPastOneHour() {
        let s = TranscriptSegment(channel: .system, speaker: .teammates,
                                  text: "Wrapping up.", start: 3_661, end: 3_665)
        let chunks = TranscriptChunker.chunks(from: [s])

        #expect(chunks[0].plainText == "[1:01:01–1:01:05] Others: Wrapping up.")
    }

    // MARK: Properties over a long generated transcript

    /// Deterministic ~200-segment transcript: alternating speakers, size and gap
    /// driven by the index (no randomness), so the whole thing is reproducible.
    private func longTranscript(count: Int = 200) -> [TranscriptSegment] {
        var segments: [TranscriptSegment] = []
        var t = 0.0
        let gaps = [1.0, 3.0, 9.0, 25.0]
        for i in 0..<count {
            let speaker: Speaker = i.isMultiple(of: 2) ? .me : .teammates
            let tokens = 30 + (i * 7) % 50 // 30…79 tokens
            let duration = 3.0 + Double(tokens) / 20.0
            let start = t
            let end = start + duration
            segments.append(seg(speaker, tokens: tokens, start: start, end: end))
            t = end + gaps[i % gaps.count]
        }
        return segments
    }

    private let propertyConfig = ChunkingConfig(
        targetTokens: 200, hardMaxTokens: 300,
        overlapTokens: 20, longGap: 20, turnGap: 8, minChunkTokens: 40
    )

    @Test func longTranscriptHasNoLossAndNoDuplication() {
        let input = longTranscript()
        let chunks = TranscriptChunker.chunks(from: input, config: propertyConfig)

        #expect(chunks.count > 1) // the config forces several boundaries

        // Criterion 2: concatenating newSegments reproduces the input exactly.
        let rebuilt = chunks.flatMap(\.newSegments)
        #expect(rebuilt == input)

        // No id appears as "new" in more than one chunk.
        let newIDs = rebuilt.map(\.id)
        #expect(Set(newIDs).count == newIDs.count)

        // Indices are 0-based and contiguous.
        #expect(chunks.map(\.index) == Array(0..<chunks.count))

        for (i, chunk) in chunks.enumerated() {
            // Never split a segment / boundaries between segments is structural:
            // start/end line up with the member segments.
            #expect(chunk.start == chunk.segments.first?.start)
            #expect(chunk.end == chunk.segments.last?.end)
            // Token budget respected (no giants in this generator).
            #expect(chunk.tokenEstimate <= propertyConfig.hardMaxTokens)

            guard i > 0 else {
                #expect(chunk.overlapSegmentIDs.isEmpty)
                continue
            }
            let prev = chunks[i - 1]
            let k = chunk.overlapSegmentIDs.count
            // Overlap is a prefix of this chunk...
            let head = Array(chunk.segments.prefix(k))
            #expect(Set(head.map(\.id)) == chunk.overlapSegmentIDs)
            // ...equal to a suffix of the previous chunk...
            #expect(head == Array(prev.segments.suffix(k)))
            // ...and never more than half of the previous chunk.
            #expect(k <= prev.segments.count / 2)
        }
    }

    @Test func incrementalMatchesBatch() {
        let inputs: [[TranscriptSegment]] = [
            [],
            [seg(.me, tokens: 10, start: 0, end: 4)],
            longTranscript(count: 37),
            longTranscript(count: 200),
        ]

        for input in inputs {
            let batch = TranscriptChunker.chunks(from: input, config: propertyConfig)

            var assembler = ChunkAssembler(config: propertyConfig)
            var incremental: [TranscriptChunk] = []
            for segment in input {
                if let chunk = assembler.ingest(segment) { incremental.append(chunk) }
            }
            if let last = assembler.flush() { incremental.append(last) }

            #expect(incremental == batch)
        }
    }

    @Test func secondFlushReturnsNil() {
        var assembler = ChunkAssembler()
        _ = assembler.ingest(seg(.me, tokens: 10, start: 0, end: 4))
        #expect(assembler.flush() != nil)
        #expect(assembler.flush() == nil)
    }
}
