//
//  SummaryMapReduceTests.swift
//  EchoTests
//
//  SPEC-05: the map-reduce scaling path. Drives routing, per-chunk mapping,
//  the deterministic merge, streaming, and cancellation through the
//  TextGenerating seam with scripted fake engines — no model. Constructed
//  *text* transcript segments are the sanctioned fixture style for LLM tests
//  (workflow §0.5); no audio involved.
//

import Foundation
import Testing
@testable import Echo

// MARK: - Fakes

/// Scripted engine: each `stream` call pops the next script (an array of raw
/// deltas) and replays it. Call order matches the pipeline's phase order — one
/// map per chunk in chunk order, then one prose reduce.
private final class ScriptedEngine: TextGenerating, @unchecked Sendable {
    private let lock = NSLock()
    private var scripts: [[String]]
    private var count = 0

    init(scripts: [[String]]) { self.scripts = scripts }

    func stream(system: String, user: String, params: GenerationParams)
        -> AsyncThrowingStream<String, Error>
    {
        lock.lock()
        count += 1
        let chunks = scripts.isEmpty ? [] : scripts.removeFirst()
        lock.unlock()
        return AsyncThrowingStream { continuation in
            for chunk in chunks { continuation.yield(chunk) }
            continuation.finish()
        }
    }

    var calls: Int { lock.lock(); defer { lock.unlock() }; return count }
}

/// First `stream` call replays its script; every later call hangs (yields
/// nothing, never finishes on its own). Used to park the pipeline mid-maps so a
/// cancellation is observable rather than racing a fast fake.
private final class BlockAfterFirstEngine: TextGenerating, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private let firstScript: [String]

    init(firstScript: [String]) { self.firstScript = firstScript }

    func stream(system: String, user: String, params: GenerationParams)
        -> AsyncThrowingStream<String, Error>
    {
        lock.lock(); count += 1; let n = count; lock.unlock()
        let script = firstScript
        return AsyncThrowingStream { continuation in
            if n == 1 {
                for chunk in script { continuation.yield(chunk) }
                continuation.finish()
            }
            // n > 1: never yields, never finishes — only task cancellation ends
            // the pipeline's await on it.
        }
    }

    var calls: Int { lock.lock(); defer { lock.unlock() }; return count }
}

// MARK: - Fixtures

private func segment(
    _ text: String, id: UUID = UUID(), speaker: Speaker = .me,
    start: TimeInterval, end: TimeInterval
) -> TranscriptSegment {
    TranscriptSegment(
        id: id,
        channel: speaker == .me ? .microphone : .system,
        speaker: speaker, text: text, start: start, end: end)
}

/// A transcript big enough to exceed `singlePassBudget` and split into multiple
/// chunks. Each segment is ~250 tokens of filler; contiguous timing means chunks
/// close at the hard-max boundary.
private func longTranscript(segmentCount: Int) -> [TranscriptSegment] {
    (0..<segmentCount).map { index in
        let filler = String(repeating: "word ", count: 200)   // ~1000 scalars ≈ 250 tokens
        return segment(
            "Part \(index): \(filler)",
            speaker: index.isMultiple(of: 2) ? .me : .teammates,
            start: TimeInterval(index * 5),
            end: TimeInterval(index * 5 + 4))
    }
}

private func chunkNote(_ text: String) -> String {
    "{\"type\":\"chunknote\",\"text\":\"\(text)\"}\n"
}

private func decisionLine(_ title: String, evidence: String) -> String {
    "{\"type\":\"decision\",\"title\":\"\(title)\",\"details\":null,\"evidence\":[\"\(evidence)\"]}\n"
}

private func proseScript() -> [String] {
    ["{\"type\":\"short\",\"text\":\"Overall summary.\"}\n"
        + "{\"type\":\"detailed\",\"text\":\"A thorough paragraph.\"}\n"]
}

// MARK: - Merge (pure, no engine)

@Suite("SummaryMerge (deterministic reduce)")
struct SummaryMergeTests {

    private func result(
        index: Int,
        decisions: [SummaryDecision] = [],
        actions: [SummaryActionItem] = [],
        questions: [SummaryOpenQuestion] = [],
        risks: [SummaryRisk] = [],
        note: String = ""
    ) -> ChunkMapResult {
        ChunkMapResult(
            chunkIndex: index, decisions: decisions, actionItems: actions,
            openQuestions: questions, risks: risks, chunkNote: note,
            start: TimeInterval(index * 60), end: TimeInterval(index * 60 + 60))
    }

    @Test("a fact reported by two chunks collapses to one, evidence unioned")
    func dedupAcrossChunks() {
        // The overlap guarantee: even if two adjacent chunks both report the
        // same decision (overlap region), the merge keeps exactly one.
        let a = result(index: 0, decisions: [
            SummaryDecision(title: "Ship on Friday", details: "d", evidenceSegmentIDs: ["A"])
        ])
        let b = result(index: 1, decisions: [
            // Rephrased/repunctuated → same normalized key.
            SummaryDecision(title: "ship on friday!", details: "d2", evidenceSegmentIDs: ["B", "A"])
        ])

        let merged = SummaryMerge.merge([b, a])   // out of order on purpose
        #expect(merged.decisions.count == 1)
        #expect(merged.decisions.first?.title == "Ship on Friday")   // first (chunk 0) wins
        #expect(merged.decisions.first?.evidenceSegmentIDs == ["A", "B"])   // unioned, deduped
    }

    @Test("a duplicate action fills a null owner/due but never overwrites a value")
    func ownerAndDueFill() {
        let a = result(index: 0, actions: [
            SummaryActionItem(task: "Write notes", owner: nil, dueDate: "Thursday", evidenceSegmentIDs: ["A"])
        ])
        let b = result(index: 1, actions: [
            SummaryActionItem(task: "write notes", owner: "Alice", dueDate: "Friday", evidenceSegmentIDs: ["B"])
        ])

        let merged = SummaryMerge.merge([a, b])
        #expect(merged.actionItems.count == 1)
        let action = try? #require(merged.actionItems.first)
        #expect(action?.owner == "Alice")     // null → filled
        #expect(action?.dueDate == "Thursday") // value → kept (null does not overwrite)
        #expect(action?.evidenceSegmentIDs == ["A", "B"])
    }

    @Test("distinct facts across chunks are all kept, in chunk order")
    func distinctKept() {
        let a = result(index: 0, decisions: [
            SummaryDecision(title: "D0", details: "", evidenceSegmentIDs: ["A"])])
        let b = result(index: 1, decisions: [
            SummaryDecision(title: "D1", details: "", evidenceSegmentIDs: ["B"])])
        let merged = SummaryMerge.merge([a, b])
        #expect(merged.decisions.map(\.title) == ["D0", "D1"])
    }

    @Test("each section is capped at 20 distinct items after merge")
    func caps() {
        let many = (0..<30).map {
            SummaryDecision(title: "D\($0)", details: "", evidenceSegmentIDs: ["\($0)"])
        }
        let merged = SummaryMerge.merge([result(index: 0, decisions: many)])
        #expect(merged.decisions.count == 20)
        #expect(merged.decisions.first?.title == "D0")
        #expect(merged.decisions.last?.title == "D19")
    }
}

// MARK: - Codable contract (SPEC-07)

@Suite("ChunkMapResult Codable roundtrip")
struct ChunkMapResultCodableTests {

    @Test("encodes and decodes losslessly")
    func roundtrip() throws {
        let original = ChunkMapResult(
            chunkIndex: 3,
            decisions: [SummaryDecision(title: "T", details: "D", evidenceSegmentIDs: ["a", "b"])],
            actionItems: [SummaryActionItem(task: "Do", owner: "Al", dueDate: nil, evidenceSegmentIDs: ["c"])],
            openQuestions: [SummaryOpenQuestion(question: "Q?", context: nil, evidenceSegmentIDs: ["d"])],
            risks: [SummaryRisk(risk: "R", details: "why", evidenceSegmentIDs: ["e"])],
            chunkNote: "A gist.",
            start: 12, end: 34)

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ChunkMapResult.self, from: data)
        #expect(decoded == original)
    }
}

// MARK: - Routing + orchestration (through the seam)

@Suite("Map-reduce routing and streaming")
struct MapReduceRoutingTests {

    @Test("a short transcript takes the single-pass path (one generation)")
    func shortRoutesSinglePass() async throws {
        let id = UUID()
        let engine = ScriptedEngine(scripts: [[
            "{\"type\":\"short\",\"text\":\"S\"}\n{\"type\":\"detailed\",\"text\":\"D\"}\n"
        ]])
        let pipeline = SummarizationPipeline()

        var final: MeetingSummary?
        for try await snapshot in await pipeline.generate(
            from: [segment("brief chat", id: id, start: 0, end: 4)], using: engine) {
            final = snapshot
        }

        #expect(engine.calls == 1)                    // single-pass: one call only
        #expect(final?.shortSummary == "S")
        #expect(final?.detailedSummary == "D")
    }

    @Test("a long transcript maps each chunk then reduces prose")
    func longRoutesMapReduce() async throws {
        let segments = longTranscript(segmentCount: 40)
        let chunks = TranscriptChunker.chunks(from: segments)
        #expect(chunks.count >= 2)   // fixture actually splits

        // One map script per chunk (each cites a real segment ID from that
        // chunk, and contributes a distinct decision), then a prose reduce.
        var scripts: [[String]] = chunks.map { chunk in
            let realID = chunk.segments.first!.id.uuidString
            return [chunkNote("gist \(chunk.index)") + decisionLine("Decision \(chunk.index)", evidence: realID)]
        }
        scripts.append(proseScript())
        let engine = ScriptedEngine(scripts: scripts)
        let pipeline = SummarizationPipeline()

        var phases: [String] = []
        var final: MeetingSummary?
        for try await snapshot in await pipeline.generate(
            from: segments, using: engine, progress: { phases.append($0) }) {
            final = snapshot
        }

        // Route was map-reduce: N maps + 1 prose.
        #expect(engine.calls == chunks.count + 1)
        // Progress surfaced per-part text and cleared at the end.
        #expect(phases.contains("Summarizing part 1/\(chunks.count)…"))
        #expect(phases.contains("Summarizing part \(chunks.count)/\(chunks.count)…"))
        #expect(phases.last == "")

        let summary = try #require(final)
        #expect(summary.shortSummary == "Overall summary.")
        #expect(summary.detailedSummary == "A thorough paragraph.")
        // Each chunk contributed one distinct decision; all survive the merge.
        #expect(summary.decisions.count == chunks.count)
    }

    @Test("streaming snapshots grow monotonically until the final prose")
    func snapshotsGrowMonotonically() async throws {
        let segments = longTranscript(segmentCount: 40)
        let chunks = TranscriptChunker.chunks(from: segments)
        var scripts: [[String]] = chunks.map { chunk in
            let realID = chunk.segments.first!.id.uuidString
            return [chunkNote("g\(chunk.index)") + decisionLine("Decision \(chunk.index)", evidence: realID)]
        }
        scripts.append(proseScript())
        let engine = ScriptedEngine(scripts: scripts)
        let pipeline = SummarizationPipeline()

        var snapshots: [MeetingSummary] = []
        for try await snapshot in await pipeline.generate(from: segments, using: engine) {
            snapshots.append(snapshot)
        }

        #expect(snapshots.count >= chunks.count)
        // Decisions never shrink across the stream (sections only fill in).
        var previous = 0
        for snapshot in snapshots {
            #expect(snapshot.decisions.count >= previous)
            previous = snapshot.decisions.count
        }
        // Prose only appears in (at least) the last snapshot; the merged facts
        // are still present alongside it.
        #expect(snapshots.last?.shortSummary == "Overall summary.")
        #expect(snapshots.last?.decisions.count == chunks.count)
    }

    @Test("cancelling mid-maps stops the pipeline before prose")
    func cancellationMidMaps() async throws {
        let segments = longTranscript(segmentCount: 40)
        let chunks = TranscriptChunker.chunks(from: segments)
        #expect(chunks.count >= 2)

        let firstID = chunks[0].segments.first!.id.uuidString
        let engine = BlockAfterFirstEngine(
            firstScript: [chunkNote("g0") + decisionLine("Decision 0", evidence: firstID)])
        let pipeline = SummarizationPipeline()

        var snapshots: [MeetingSummary] = []
        for try await snapshot in await pipeline.generate(from: segments, using: engine) {
            snapshots.append(snapshot)
            break   // stop mid-maps → terminates the stream → cancels the producer
        }

        // Let the cancelled producer unwind.
        try? await Task.sleep(nanoseconds: 200_000_000)

        #expect(snapshots.count == 1)
        // No prose ever reached us, and the merged facts had only chunk 0.
        #expect(snapshots.allSatisfy { $0.shortSummary.isEmpty && $0.detailedSummary.isEmpty })
        // Prose is call `chunks.count + 1`; it must never have run.
        #expect(engine.calls <= chunks.count)
    }
}

// MARK: - mapChunk grounding + reduceProse contract

@Suite("mapChunk and reduceProse")
struct MapChunkTests {

    private func makeChunk(index: Int, segments: [TranscriptSegment], overlap: Set<UUID> = []) -> TranscriptChunk {
        TranscriptChunk(index: index, segments: segments, overlapSegmentIDs: overlap, tokenEstimate: 0)
    }

    @Test("mapChunk keeps only facts whose evidence cites a real chunk segment")
    func mapChunkEvidenceGrounding() async throws {
        let real = segment("real content", start: 0, end: 4)
        let chunk = makeChunk(index: 0, segments: [real])
        let realID = real.id.uuidString
        let fakeID = UUID().uuidString

        let engine = ScriptedEngine(scripts: [[
            chunkNote("what this part covered")
                + decisionLine("Grounded", evidence: realID)
                + decisionLine("Hallucinated", evidence: fakeID)
        ]])
        let pipeline = SummarizationPipeline()

        let result = try await pipeline.mapChunk(chunk, engine: engine)
        #expect(result.chunkNote == "what this part covered")
        #expect(result.decisions.count == 1)
        #expect(result.decisions.first?.title == "Grounded")
        #expect(result.decisions.first?.evidenceSegmentIDs == [realID])
        #expect(result.start == 0)
    }

    @Test("reduceProse returns short/detailed from precomputed facts")
    func reduceProseContract() async throws {
        let facts = MergedFacts(decisions: [
            SummaryDecision(title: "Ship it", details: "", evidenceSegmentIDs: ["A"])])
        let notes = [ChunkMapResult(
            chunkIndex: 0, decisions: facts.decisions, actionItems: [], openQuestions: [],
            risks: [], chunkNote: "we agreed to ship", start: 0, end: 60)]
        let engine = ScriptedEngine(scripts: [proseScript()])
        let pipeline = SummarizationPipeline()

        let prose = try await pipeline.reduceProse(facts: facts, notes: notes, engine: engine)
        #expect(prose.short == "Overall summary.")
        #expect(prose.detailed == "A thorough paragraph.")
        #expect(engine.calls == 1)
    }
}
