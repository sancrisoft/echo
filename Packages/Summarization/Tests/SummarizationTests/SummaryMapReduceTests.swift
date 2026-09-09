//
//  SummaryMapReduceTests.swift
//  SummarizationTests
//
//  The map-reduce scaling route. Drives routing, per-chunk mapping, the
//  deterministic merge, the fixed-schema fact renderer, streaming and
//  cancellation through the `TextGenerating` seam with scripted fake engines —
//  no model, no MLX, no download. Constructed TEXT segments only: the whole
//  route is pure past the seam, so it needs no audio.
//

import EchoCore
import Foundation
import Synchronization
import Testing

@testable import Summarization

// MARK: - Fakes

/// Scripted engine: each `stream` call pops the next script (an array of raw
/// deltas) and replays it, recording what the summarizer asked for (system,
/// user, params) so tests can assert on the real prompts in flight. Call order
/// matches the route's phase order — one map per chunk in chunk order, then the
/// markdown reduce.
private final class ScriptedEngine: TextGenerating {

    struct RecordedCall {
        let system: String
        let user: String
        let params: GenerationParams
    }

    private struct State {
        var scripts: [[String]]
        var recorded: [RecordedCall] = []
    }

    private let state: Mutex<State>

    init(scripts: [[String]]) {
        state = Mutex(State(scripts: scripts))
    }

    func stream(system: String, user: String, params: GenerationParams) -> AsyncThrowingStream<String, Error> {
        let deltas = state.withLock { state -> [String] in
            state.recorded.append(RecordedCall(system: system, user: user, params: params))
            return state.scripts.isEmpty ? [] : state.scripts.removeFirst()
        }
        return AsyncThrowingStream { continuation in
            for delta in deltas { continuation.yield(delta) }
            continuation.finish()
        }
    }

    var calls: Int { state.withLock { $0.recorded.count } }

    var recordedCalls: [RecordedCall] { state.withLock { $0.recorded } }
}

/// First `stream` call replays its script; every later call PARKS — it yields
/// nothing and never finishes, so only the consumer's cancellation can end the
/// summarizer's await on it. Both moments are latched, so a test observes the
/// cancellation by construction instead of sleeping and hoping.
private final class BlockAfterFirstEngine: TextGenerating {

    /// Signalled when the parked (second) generation is in flight.
    let parkedCallStarted = Latch()
    /// Signalled when that parked generation's stream is terminated — which
    /// only cancellation can do.
    let parkedCallTerminated = Latch()

    private let count = Mutex(0)
    private let firstScript: [String]

    init(firstScript: [String]) {
        self.firstScript = firstScript
    }

    func stream(system: String, user: String, params: GenerationParams) -> AsyncThrowingStream<String, Error> {
        let ordinal = count.withLock { value -> Int in
            value += 1
            return value
        }
        let script = firstScript
        return AsyncThrowingStream { continuation in
            guard ordinal == 1 else {
                continuation.onTermination = { _ in self.parkedCallTerminated.signal() }
                self.parkedCallStarted.signal()
                return
            }
            for delta in script { continuation.yield(delta) }
            continuation.finish()
        }
    }

    var calls: Int { count.withLock { $0 } }
}

/// A one-shot latch: `signal()` releases every `wait()`, whichever comes first.
/// The same shape `ModelDelivery`'s suites use, and for the same reason — the
/// waiter is resumed by the event itself, so nothing depends on a clock.
private final class Latch: Sendable {

    private struct State {
        var isSignalled = false
        var waiters: [CheckedContinuation<Void, Never>] = []
    }

    private let state = Mutex(State())

    func signal() {
        let waiters: [CheckedContinuation<Void, Never>] = state.withLock {
            guard !$0.isSignalled else { return [] }
            $0.isSignalled = true
            let pending = $0.waiters
            $0.waiters = []
            return pending
        }
        for waiter in waiters { waiter.resume() }
    }

    func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let alreadySignalled: Bool = state.withLock {
                guard !$0.isSignalled else { return true }
                $0.waiters.append(continuation)
                return false
            }
            if alreadySignalled { continuation.resume() }
        }
    }
}

// MARK: - Fixtures

private func segment(
    _ text: String,
    id: UUID = UUID(),
    speaker: Speaker = .me,
    start: TimeInterval,
    end: TimeInterval
) -> TranscriptSegment {
    TranscriptSegment(
        id: id,
        channel: speaker == .me ? .microphone : .system,
        speaker: speaker,
        text: text,
        start: start,
        end: end
    )
}

/// A transcript big enough to exceed `singlePassBudget` and split into several
/// chunks. Each segment is ~250 tokens of filler; contiguous timing means the
/// chunks close at the hard-max boundary.
private func longTranscript(segmentCount: Int) -> [TranscriptSegment] {
    (0..<segmentCount).map { index in
        // ~1 000 scalars ≈ 250 tokens under the heuristic estimator.
        let filler = String(repeating: "word ", count: 200)
        return segment(
            "Part \(index): \(filler)",
            speaker: index.isMultiple(of: 2) ? .me : .teammates,
            start: TimeInterval(index * 5),
            end: TimeInterval(index * 5 + 4)
        )
    }
}

private func chunkNote(_ text: String) -> String {
    "{\"type\":\"chunknote\",\"text\":\"\(text)\"}\n"
}

private func decisionLine(_ title: String, evidence: String) -> String {
    "{\"type\":\"decision\",\"title\":\"\(title)\",\"details\":null,\"evidence\":[\"\(evidence)\"]}\n"
}

/// One map script per chunk: a note plus a distinct decision citing a real
/// segment id of that chunk, so nothing is dropped by the evidence filter.
private func mapScripts(for chunks: [TranscriptChunk]) throws -> [[String]] {
    try chunks.map { chunk in
        let realID = try #require(chunk.segments.first).id.uuidString
        return [chunkNote("gist \(chunk.index)") + decisionLine("Decision \(chunk.index)", evidence: realID)]
    }
}

/// Map scripts that yield a note and NO facts, so the merge comes back empty.
private func noteOnlyMapScripts(for chunks: [TranscriptChunk]) -> [[String]] {
    chunks.map { [chunkNote("gist \($0.index)")] }
}

/// The reduce is a markdown generation (the same document contract as the
/// single-pass route), so its script is one adaptive document, not NDJSON.
private let reduceDocument = """
    ### Action Items
    - [ ] You to ship the release

    ### Release Review
    The team agreed the build is ready.
    """

private func makeSummarizer() -> Summarizer {
    Summarizer(modelName: "Test Model")
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
            chunkIndex: index,
            decisions: decisions,
            actionItems: actions,
            openQuestions: questions,
            risks: risks,
            chunkNote: note,
            start: TimeInterval(index * 60),
            end: TimeInterval(index * 60 + 60)
        )
    }

    @Test("a fact reported by two chunks collapses to one, evidence unioned")
    func dedupAcrossChunks() {
        // The overlap guarantee: even if two adjacent chunks both report the
        // same decision (the overlap region), the merge keeps exactly one.
        let a = result(
            index: 0,
            decisions: [SummaryDecision(title: "Ship on Friday", details: "d", evidenceSegmentIDs: ["A"])]
        )
        let b = result(
            index: 1,
            // Rephrased / repunctuated → the same normalized key.
            decisions: [SummaryDecision(title: "ship on friday!", details: "d2", evidenceSegmentIDs: ["B", "A"])]
        )

        // Out of order on purpose: the merge sorts by chunk index.
        let merged = SummaryMerge.merge([b, a])

        #expect(merged.decisions.count == 1)
        // The first occurrence (chunk 0) wins its position AND its text.
        #expect(merged.decisions.first?.title == "Ship on Friday")
        #expect(merged.decisions.first?.evidenceSegmentIDs == ["A", "B"])
    }

    @Test("a duplicate action fills a null owner/due but never overwrites a value")
    func ownerAndDueFill() throws {
        let a = result(
            index: 0,
            actions: [
                SummaryActionItem(task: "Write notes", owner: nil, dueDate: "Thursday", evidenceSegmentIDs: ["A"])
            ]
        )
        let b = result(
            index: 1,
            actions: [
                SummaryActionItem(task: "write notes", owner: "Alice", dueDate: "Friday", evidenceSegmentIDs: ["B"])
            ]
        )

        let merged = SummaryMerge.merge([a, b])

        #expect(merged.actionItems.count == 1)
        let action = try #require(merged.actionItems.first)
        // Null → filled; a value → kept (null never overwrites).
        #expect(action.owner == "Alice")
        #expect(action.dueDate == "Thursday")
        #expect(action.evidenceSegmentIDs == ["A", "B"])
    }

    @Test("distinct facts across chunks are all kept, in chunk order")
    func distinctKept() {
        let a = result(index: 0, decisions: [SummaryDecision(title: "D0", details: "", evidenceSegmentIDs: ["A"])])
        let b = result(index: 1, decisions: [SummaryDecision(title: "D1", details: "", evidenceSegmentIDs: ["B"])])

        let merged = SummaryMerge.merge([a, b])

        #expect(merged.decisions.map(\.title) == ["D0", "D1"])
    }

    @Test("each section is capped at 20 distinct items after merge")
    func caps() {
        let many = (0..<30).map {
            SummaryDecision(title: "D\($0)", details: "", evidenceSegmentIDs: ["\($0)"])
        }

        let merged = SummaryMerge.merge([result(index: 0, decisions: many)])

        #expect(SummaryLimits.maxItemsPerSection == 20)
        #expect(merged.decisions.count == 20)
        #expect(merged.decisions.first?.title == "D0")
        #expect(merged.decisions.last?.title == "D19")
    }
}

// MARK: - The fixed-schema fact renderer

/// `MergedFacts.markdown` is the degraded route's document: what a reader gets
/// when both reduce attempts came back empty. The schema is fixed (the model
/// writes the adaptive one), so it is asserted by value — section titles,
/// separators and omissions included.
@Suite("MergedFacts.markdown")
struct MergedFactsMarkdownTests {

    @Test("wholly empty facts render as nothing at all")
    func emptyRendersEmpty() {
        #expect(MergedFacts().isEmpty)
        #expect(MergedFacts().markdown == "")
    }

    @Test("every section carries its title, and an empty section is never written")
    func sectionTitles() {
        let facts = MergedFacts(
            decisions: [SummaryDecision(title: "Ship v2", details: "", evidenceSegmentIDs: ["a"])],
            actionItems: [SummaryActionItem(task: "Write docs", evidenceSegmentIDs: ["b"])],
            openQuestions: [SummaryOpenQuestion(question: "Which region?", evidenceSegmentIDs: ["c"])],
            risks: [SummaryRisk(risk: "Vendor delay", evidenceSegmentIDs: ["d"])]
        )

        #expect(
            facts.markdown == """
                ### Decisions

                - **Ship v2**

                ### Action Items

                - Write docs

                ### Open Questions

                - Which region?

                ### Risks or Blockers

                - Vendor delay
                """
        )

        // Only the populated section appears; the other three leave no trace.
        let decisionsOnly = MergedFacts(decisions: facts.decisions)
        #expect(decisionsOnly.markdown == "### Decisions\n\n- **Ship v2**")
        #expect(!decisionsOnly.markdown.contains("### Action Items"))
        #expect(!decisionsOnly.markdown.contains("### Open Questions"))
        #expect(!decisionsOnly.markdown.contains("### Risks or Blockers"))
    }

    @Test("a decision renders as a bold title with its details, or without them")
    func decisionRendering() {
        let withDetails = MergedFacts(
            decisions: [SummaryDecision(title: "Ship v2", details: "After QA", evidenceSegmentIDs: ["a"])]
        )
        #expect(withDetails.markdown == "### Decisions\n\n- **Ship v2** — After QA")

        let withoutDetails = MergedFacts(
            decisions: [SummaryDecision(title: "Ship v2", details: "", evidenceSegmentIDs: ["a"])]
        )
        #expect(withoutDetails.markdown == "### Decisions\n\n- **Ship v2**")
    }

    @Test("an action renders its owner and due date only when it has them")
    func actionRendering() {
        let full = MergedFacts(
            actionItems: [
                SummaryActionItem(
                    task: "Prepare release notes", owner: "You", dueDate: "Thursday",
                    evidenceSegmentIDs: ["a"])
            ]
        )
        #expect(full.markdown == "### Action Items\n\n- Prepare release notes · Owner: You · Due: Thursday")

        let ownerOnly = MergedFacts(
            actionItems: [SummaryActionItem(task: "Prepare release notes", owner: "You", evidenceSegmentIDs: ["a"])]
        )
        #expect(ownerOnly.markdown == "### Action Items\n\n- Prepare release notes · Owner: You")

        let dueOnly = MergedFacts(
            actionItems: [
                SummaryActionItem(task: "Prepare release notes", dueDate: "Thursday", evidenceSegmentIDs: ["a"])
            ]
        )
        #expect(dueOnly.markdown == "### Action Items\n\n- Prepare release notes · Due: Thursday")

        let bare = MergedFacts(
            actionItems: [SummaryActionItem(task: "Prepare release notes", evidenceSegmentIDs: ["a"])]
        )
        #expect(bare.markdown == "### Action Items\n\n- Prepare release notes")
    }

    @Test("questions and risks render their context or details after a dash")
    func questionAndRiskRendering() {
        let questions = MergedFacts(
            openQuestions: [
                SummaryOpenQuestion(question: "Which region?", context: "Beta only", evidenceSegmentIDs: ["a"])
            ]
        )
        #expect(questions.markdown == "### Open Questions\n\n- Which region? — Beta only")

        let risks = MergedFacts(
            risks: [SummaryRisk(risk: "Vendor delay", details: "Contract unsigned", evidenceSegmentIDs: ["a"])]
        )
        #expect(risks.markdown == "### Risks or Blockers\n\n- Vendor delay — Contract unsigned")
    }
}

// MARK: - Codable contract

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
            start: 12,
            end: 34
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ChunkMapResult.self, from: data)

        #expect(decoded == original)
    }
}

// MARK: - Routing + orchestration (through the seam)

@Suite("Map-reduce routing and streaming")
struct MapReduceRoutingTests {

    /// The route boundary and the chunk boundary read the same estimator, so
    /// they can never disagree about what a transcript costs. v1 inlined its own
    /// copy of the sum; this equality is why the copy is gone.
    @Test("the routing estimate is the chunker's estimator, summed over segments")
    func estimateAgreesWithTheChunkersEstimator() {
        let estimator = HeuristicTokenEstimator()
        let segments = longTranscript(segmentCount: 12)

        #expect(Summarizer.estimatedTokens(of: []) == 0)
        #expect(Summarizer.estimatedTokens(of: segments) == segments.reduce(0) { $0 + estimator.estimate($1.text) })
        // The measured boundary: the single-pass budget is chunking's hard max.
        #expect(Summarizer.singlePassBudget == 8_000)
        #expect(Summarizer.singlePassBudget == ChunkingConfig().hardMaxTokens)
        #expect(Summarizer.estimatedTokens(of: longTranscript(segmentCount: 40)) > Summarizer.singlePassBudget)
    }

    @Test("a short transcript takes the single-pass path (one markdown generation)")
    func shortRoutesSinglePass() async throws {
        let engine = ScriptedEngine(scripts: [["### Quick Sync\nA brief chat, nothing decided.\n"]])
        let summarizer = makeSummarizer()

        var documents: [SummaryDocument] = []
        for try await document in await summarizer.generate(
            from: [segment("brief chat", start: 0, end: 4)], using: engine)
        {
            documents.append(document)
        }

        // Single-pass: one call only.
        #expect(engine.calls == 1)
        let final = try #require(documents.last)
        #expect(final.markdown == "### Quick Sync\nA brief chat, nothing decided.")
        #expect(final.isFinal)
        #expect(final.modelName == "Test Model")
        // The single-pass route extracts no facts; its grounding is the prompt.
        #expect(final.facts.isEmpty)
        #expect(documents.filter(\.isFinal).count == 1)
    }

    @Test("a long transcript maps each chunk then reduces to one markdown document")
    func longRoutesMapReduce() async throws {
        let segments = longTranscript(segmentCount: 40)
        let chunks = TranscriptChunker.chunks(from: segments)
        // The fixture actually splits.
        #expect(chunks.count >= 2)

        var scripts = try mapScripts(for: chunks)
        scripts.append([reduceDocument])
        let engine = ScriptedEngine(scripts: scripts)
        let summarizer = makeSummarizer()

        let phases = Mutex<[SummaryPhase]>([])
        var documents: [SummaryDocument] = []
        for try await document in await summarizer.generate(
            from: segments, using: engine,
            onProgress: { phase in phases.withLock { $0.append(phase) } })
        {
            documents.append(document)
        }

        // Route was map-reduce: N maps + 1 markdown reduce.
        #expect(engine.calls == chunks.count + 1)
        // Progress reported every part, the reduce, and then nothing left.
        let observed = phases.withLock { $0 }
        #expect(observed.contains(.mapping(part: 1, of: chunks.count)))
        #expect(observed.contains(.mapping(part: chunks.count, of: chunks.count)))
        #expect(observed.contains(.reducing))
        #expect(observed.last == .finished)

        // The final document carries the Markdown AND the merged facts
        // together: a caller mirrors `summary.md` from the Markdown while fact
        // consumers (evidence UI, later retrieval) read the sections — neither
        // may lose out.
        let final = try #require(documents.last)
        #expect(final.isFinal)
        #expect(final.markdown == reduceDocument)
        #expect(final.facts.decisions.count == chunks.count)
        // Exactly one final document per successful generation.
        #expect(documents.filter(\.isFinal).count == 1)
        #expect(documents.dropLast().allSatisfy { !$0.isFinal })
    }

    @Test("drafts carry growing facts during maps, then a growing document")
    func draftsGrowMonotonically() async throws {
        let segments = longTranscript(segmentCount: 40)
        let chunks = TranscriptChunker.chunks(from: segments)
        var scripts = try mapScripts(for: chunks)
        // The reduce streams in pieces so document growth is observable.
        scripts.append(["### Notes\nFirst ", "half, ", "then the rest."])
        let engine = ScriptedEngine(scripts: scripts)
        let summarizer = makeSummarizer()

        var documents: [SummaryDocument] = []
        for try await document in await summarizer.generate(from: segments, using: engine) {
            documents.append(document)
        }

        #expect(documents.count >= chunks.count + 2)

        // Facts never shrink across the whole stream.
        var previousDecisions = 0
        for document in documents {
            #expect(document.facts.decisions.count >= previousDecisions)
            previousDecisions = document.facts.decisions.count
        }

        // Mid-map drafts are the merged facts rendered in the fixed schema —
        // not "" as in v1, so a reader watches the grounded facts arrive.
        let firstReduceDraft = try #require(documents.firstIndex { $0.markdown.hasPrefix("### Notes") })
        #expect(firstReduceDraft == chunks.count)
        for (offset, document) in documents[..<firstReduceDraft].enumerated() {
            #expect(document.facts.decisions.count == offset + 1)
            #expect(document.markdown == document.facts.markdown)
            #expect(!document.markdown.isEmpty)
            #expect(!document.isFinal)
        }

        // Growth is monotonic within each phase: the rendered facts grow as
        // chunks merge in, then the document grows as the reduce writes it.
        assertMarkdownGrows(documents[..<firstReduceDraft])
        assertMarkdownGrows(documents[firstReduceDraft...])

        // Every reduce draft carries the full merged facts alongside the
        // in-progress document.
        for document in documents[firstReduceDraft...] {
            #expect(document.facts.decisions.count == chunks.count)
        }
        #expect(documents.last?.markdown == "### Notes\nFirst half, then the rest.")
        #expect(documents.last?.isFinal == true)
        #expect(documents.filter(\.isFinal).count == 1)
    }

    private func assertMarkdownGrows(_ documents: ArraySlice<SummaryDocument>) {
        var previousLength = 0
        for document in documents {
            #expect(document.markdown.count >= previousLength)
            previousLength = document.markdown.count
        }
    }

    /// The long route's standing principle: grounded content beats an error. If
    /// the markdown reduce comes back empty twice, the route must not throw away
    /// N successful map generations — it degrades to the facts-only document.
    /// v2 goes one step further than v1: the degraded document is FINAL and its
    /// Markdown is the facts rendered, never blank, so a caller may persist a
    /// final document unconditionally.
    @Test("an empty reduce degrades to the facts-only document instead of erroring")
    func emptyReduceDegradesToFacts() async throws {
        let segments = longTranscript(segmentCount: 40)
        let chunks = TranscriptChunker.chunks(from: segments)
        var scripts = try mapScripts(for: chunks)
        // Reduce attempt 1: whitespace only. Attempt 2 (the retry): still nothing.
        scripts.append(["   \n"])
        scripts.append(["\t\n\n"])
        let engine = ScriptedEngine(scripts: scripts)
        let summarizer = makeSummarizer()

        var documents: [SummaryDocument] = []
        for try await document in await summarizer.generate(from: segments, using: engine) {
            documents.append(document)
        }

        // Both reduce attempts ran (maps + 2), and nothing threw.
        #expect(engine.calls == chunks.count + 2)
        let final = try #require(documents.last)
        #expect(final.isFinal)
        #expect(documents.filter(\.isFinal).count == 1)
        // The grounded facts survive, and they are what the document shows.
        #expect(final.facts.decisions.count == chunks.count)
        #expect(!final.markdown.isEmpty)
        #expect(final.markdown == final.facts.markdown)
        #expect(final.markdown.hasPrefix("### Decisions"))
    }

    /// The guard on that degradation: with no facts either there is nothing
    /// grounded to keep, so the honest answer is the error rather than a blank
    /// final document.
    @Test("an empty reduce with no facts propagates emptyModelResponse")
    func emptyReduceWithNoFactsThrows() async throws {
        let segments = longTranscript(segmentCount: 40)
        let chunks = TranscriptChunker.chunks(from: segments)
        var scripts = noteOnlyMapScripts(for: chunks)
        scripts.append(["   \n"])
        scripts.append(["\t\n\n"])
        let engine = ScriptedEngine(scripts: scripts)
        let summarizer = makeSummarizer()

        var documents: [SummaryDocument] = []
        var thrown: Error?
        do {
            for try await document in await summarizer.generate(from: segments, using: engine) {
                documents.append(document)
            }
        } catch {
            thrown = error
        }

        #expect(engine.calls == chunks.count + 2)
        #expect(thrown as? SummarizationError == .emptyModelResponse)
        // The maps yielded drafts, but a failed generation emits no final.
        #expect(documents.allSatisfy { !$0.isFinal })
        #expect(documents.allSatisfy { $0.facts.isEmpty })
    }

    @Test("cancelling mid-maps stops the route before the reduce, with no final document")
    func cancellationMidMaps() async throws {
        let segments = longTranscript(segmentCount: 40)
        let chunks = TranscriptChunker.chunks(from: segments)
        #expect(chunks.count >= 2)

        let firstID = try #require(chunks[0].segments.first).id.uuidString
        let engine = BlockAfterFirstEngine(
            firstScript: [chunkNote("g0") + decisionLine("Decision 0", evidence: firstID)])
        let summarizer = makeSummarizer()

        var documents: [SummaryDocument] = []
        for try await document in await summarizer.generate(from: segments, using: engine) {
            documents.append(document)
            // The second map is provably in flight and parked, so leaving the
            // loop here cancels a generation rather than racing a fast fake.
            await engine.parkedCallStarted.wait()
            // Terminates the stream → cancels the producer.
            break
        }
        // The parked generation reports its own termination, so the
        // cancellation is observed by construction — no sleep, no clock.
        await engine.parkedCallTerminated.wait()

        #expect(documents.count == 1)
        // A cancelled generation never emits a final document.
        #expect(documents.allSatisfy { !$0.isFinal })
        // No reduce document ever reached us: every draft is the rendered facts.
        #expect(documents.allSatisfy { $0.markdown == $0.facts.markdown })
        // Only chunk 0's facts made it into the merge.
        #expect(documents.first?.facts.decisions.count == 1)
        // The reduce is call `chunks.count + 1`; it must never have run.
        #expect(engine.calls <= chunks.count)
        #expect(engine.calls == 2)
    }
}

// MARK: - mapChunk grounding + reduceMarkdown contract

@Suite("mapChunk and reduceMarkdown")
struct MapChunkTests {

    private func makeChunk(
        index: Int, segments: [TranscriptSegment], overlap: Set<UUID> = []
    ) -> TranscriptChunk {
        TranscriptChunk(index: index, segments: segments, overlapSegmentIDs: overlap, tokenEstimate: 0)
    }

    @Test("mapChunk keeps only facts whose evidence cites a real chunk segment")
    func mapChunkEvidenceGrounding() async throws {
        let real = segment("real content", start: 0, end: 4)
        let chunk = makeChunk(index: 0, segments: [real])
        let realID = real.id.uuidString
        let fakeID = UUID().uuidString

        let engine = ScriptedEngine(scripts: [
            [
                chunkNote("what this part covered")
                    + decisionLine("Grounded", evidence: realID)
                    + decisionLine("Hallucinated", evidence: fakeID)
            ]
        ])
        let summarizer = makeSummarizer()

        let result = try await summarizer.mapChunk(chunk, engine: engine)

        #expect(result.chunkNote == "what this part covered")
        #expect(result.decisions.count == 1)
        #expect(result.decisions.first?.title == "Grounded")
        #expect(result.decisions.first?.evidenceSegmentIDs == [realID])
        #expect(result.start == 0)
    }

    /// The reduce can only be as specific as the chunk notes — a thin "gist"
    /// starves it of the numbers and names long meetings are judged on. The
    /// invariants (not the full text, wording may be tuned): the note is 4-8
    /// sentences, names the topics, and demands the concrete specifics.
    @Test("the map prompt demands a detailed, specific chunk note")
    func mapPromptDemandsDetailedChunkNote() async throws {
        let real = segment("real content", start: 0, end: 4)
        let chunk = makeChunk(index: 0, segments: [real])
        let engine = ScriptedEngine(scripts: [[chunkNote("a note")]])
        let summarizer = makeSummarizer()

        _ = try await summarizer.mapChunk(chunk, engine: engine)

        let system = try #require(engine.recordedCalls.first).system
        #expect(system.contains("4-8 sentences"))
        #expect(system.localizedCaseInsensitiveContains("topics"))
        #expect(system.localizedCaseInsensitiveContains("numbers"))
        #expect(system.localizedCaseInsensitiveContains("root causes"))
        // The thin gist contract is gone.
        #expect(!system.contains("2-4 sentence"))
    }

    /// On the long route the reduce writes from the chunk notes, so the notes'
    /// language decides the document's language. A detected transcript language
    /// must reach the map USER prompt as an explicit chunknote instruction; with
    /// no confident detection the prompt stays generic.
    @Test("the map prompt carries the explicit chunknote language when detected")
    func mapPromptCarriesExplicitLanguage() async throws {
        let real = segment("contenido real", start: 0, end: 4)
        let chunk = makeChunk(index: 0, segments: [real])
        let engine = ScriptedEngine(scripts: [[chunkNote("una nota")], [chunkNote("a note")]])
        let summarizer = makeSummarizer()

        _ = try await summarizer.mapChunk(chunk, engine: engine, language: "Spanish")
        _ = try await summarizer.mapChunk(chunk, engine: engine)

        let withLanguage = try #require(engine.recordedCalls.first).user
        #expect(withLanguage.contains("Write the chunknote in Spanish."))
        let without = try #require(engine.recordedCalls.last).user
        #expect(!without.contains("Write the chunknote in"))
    }

    /// The reduce is the seam a live-summary cache would drive: precomputed
    /// facts + notes in, one adaptive markdown document out. It writes markdown
    /// prose, so it must sample with the markdown preset — the NDJSON default's
    /// penalties would degrade a checkbox-heavy document.
    @Test("reduceMarkdown returns the document from precomputed facts")
    func reduceMarkdownContract() async throws {
        let facts = MergedFacts(
            decisions: [SummaryDecision(title: "Ship it", details: "", evidenceSegmentIDs: ["A"])])
        let notes = [
            ChunkMapResult(
                chunkIndex: 0, decisions: facts.decisions, actionItems: [], openQuestions: [],
                risks: [], chunkNote: "we agreed to ship", start: 0, end: 60)
        ]
        let engine = ScriptedEngine(scripts: [["### Notes\nWe agreed to ship."]])
        let summarizer = makeSummarizer()

        let document = try await summarizer.reduceMarkdown(facts: facts, notes: notes, engine: engine)

        #expect(document == "### Notes\nWe agreed to ship.")
        #expect(engine.calls == 1)

        let params = try #require(engine.recordedCalls.first).params
        let expected = GenerationParams.markdownSummary
        #expect(params.temperature == expected.temperature)
        #expect(params.maxTokens == expected.maxTokens)
        #expect(params.frequencyPenalty == expected.frequencyPenalty)
        #expect(params.presencePenalty == expected.presencePenalty)
    }

    /// The reduce reads notes + facts, not the transcript — the user prompt is
    /// all the grounding it has. Notes must arrive chronologically with their
    /// time ranges; a fact section with nothing in it must be omitted ENTIRELY
    /// (a "(none)" line would tempt the model into writing an empty section);
    /// and owner/due decorations appear only when the merge actually has them.
    @Test("the reduce user prompt carries time-ranged notes and only non-empty fact sections")
    func reduceUserPromptShape() async throws {
        let facts = MergedFacts(
            decisions: [],
            actionItems: [
                SummaryActionItem(
                    task: "Prepare release notes", owner: "You", dueDate: "Thursday",
                    evidenceSegmentIDs: ["A"]),
                SummaryActionItem(
                    task: "Update the onboarding guide", owner: nil, dueDate: nil,
                    evidenceSegmentIDs: ["B"]),
            ],
            openQuestions: [
                SummaryOpenQuestion(
                    question: "Which regions get the beta first?", context: nil,
                    evidenceSegmentIDs: ["C"])
            ],
            risks: []
        )
        // Notes handed over out of order on purpose — the prompt must sort.
        let notes = [
            ChunkMapResult(
                chunkIndex: 1, decisions: [], actionItems: [], openQuestions: [],
                risks: [], chunkNote: "Second part note.", start: 60, end: 120),
            ChunkMapResult(
                chunkIndex: 0, decisions: [], actionItems: [], openQuestions: [],
                risks: [], chunkNote: "First part note.", start: 0, end: 60),
        ]
        let engine = ScriptedEngine(scripts: [["### Notes\nBody."]])
        let summarizer = makeSummarizer()

        _ = try await summarizer.reduceMarkdown(facts: facts, notes: notes, engine: engine)
        let user = try #require(engine.recordedCalls.first).user

        // Chronological, time-ranged part notes.
        let first = try #require(user.range(of: "[0:00-1:00] First part note."))
        let second = try #require(user.range(of: "[1:00-2:00] Second part note."))
        #expect(first.lowerBound < second.lowerBound)

        // Owner/due only when present — never "unspecified" filler.
        #expect(user.contains("Prepare release notes (owner: You, due: Thursday)"))
        #expect(user.contains("- Update the onboarding guide"))
        #expect(!user.contains("Update the onboarding guide ("))
        #expect(!user.contains("unspecified"))

        // Populated sections are present; empty ones are gone without a trace.
        #expect(user.contains("Action items:"))
        #expect(user.contains("Open questions:"))
        #expect(!user.contains("Decisions:"))
        #expect(!user.contains("Risks:"))
        #expect(!user.contains("(none)"))

        // The recency reinforcement: the material CLOSES with the work-notes
        // reminder (chunk notes are the reduce's small-talk leak channel),
        // which carries both probabilistic traps — small talk and ownership.
        let reminder = try #require(user.range(of: "Reminder: these are WORK notes."))
        #expect(second.lowerBound < reminder.lowerBound)
        #expect(user.localizedCaseInsensitiveContains("leave out all social and personal conversation"))
        #expect(user.localizedCaseInsensitiveContains("no section, no mention"))
        // No language handed in → generic prompts, the ownership recap stays
        // the closer.
        #expect(!user.contains("Write the notes in"))
        #expect(user.hasSuffix("checkbox with NO name."))
    }

    /// A detected language reaches the reduce user prompt explicitly — as an
    /// opening instruction and as the reminder's final sentence (the closing
    /// slot dominates, measured). Zero-sum guard: the small-talk and ownership
    /// recaps survive alongside the appended language sentence.
    @Test("the reduce user prompt carries the explicit language when detected")
    func reducePromptCarriesExplicitLanguage() async throws {
        let facts = MergedFacts(
            decisions: [SummaryDecision(title: "Lanzar", details: "", evidenceSegmentIDs: ["A"])])
        let notes = [
            ChunkMapResult(
                chunkIndex: 0, decisions: facts.decisions, actionItems: [], openQuestions: [],
                risks: [], chunkNote: "acordamos lanzar", start: 0, end: 60)
        ]
        let engine = ScriptedEngine(scripts: [["### Notas\nCuerpo."]])
        let summarizer = makeSummarizer()

        _ = try await summarizer.reduceMarkdown(
            facts: facts, notes: notes, engine: engine, language: "Spanish")
        let user = try #require(engine.recordedCalls.first).user

        #expect(user.contains("Write the notes in Spanish."))
        #expect(user.hasSuffix("Write the notes in Spanish."))
        #expect(user.localizedCaseInsensitiveContains("no section, no mention"))
        #expect(user.localizedCaseInsensitiveContains("checkbox with NO name"))
    }

    /// The reduce writes the SAME kind of adaptive document as the single-pass
    /// route, so the five pinned ruleset phrases must survive in its system
    /// prompt too — plus the re-anchored grounding rule: the material (notes +
    /// merged facts) is the whole world, nothing new may be introduced.
    @Test("the reduce system prompt keeps the adaptive ruleset and re-anchors grounding")
    func reduceSystemPromptInvariants() async throws {
        let facts = MergedFacts(
            decisions: [SummaryDecision(title: "Ship it", details: "", evidenceSegmentIDs: ["A"])])
        let notes = [
            ChunkMapResult(
                chunkIndex: 0, decisions: facts.decisions, actionItems: [], openQuestions: [],
                risks: [], chunkNote: "we agreed to ship", start: 0, end: 60)
        ]
        let engine = ScriptedEngine(scripts: [["### Notes\nBody."]])
        let summarizer = makeSummarizer()

        _ = try await summarizer.reduceMarkdown(facts: facts, notes: notes, engine: engine)
        let system = try #require(engine.recordedCalls.first).system

        // The five pinned adaptive-ruleset phrases (shared with single-pass).
        #expect(system.contains("### Action Items"))
        #expect(system.localizedCaseInsensitiveContains("never invent an owner or a due date"))
        #expect(system.contains("dominant language of the transcript"))
        #expect(system.localizedCaseInsensitiveContains("no code fences"))
        #expect(system.localizedCaseInsensitiveContains("never write an empty section"))
        // The no-new-items grounding rule, re-anchored to the material.
        #expect(
            system.localizedCaseInsensitiveContains(
                "do not introduce any decision, action, owner, due date, question, or risk"))
        // The hard small-talk omission rides the shared block into the reduce
        // prompt too.
        #expect(system.localizedCaseInsensitiveContains("no section, no mention"))
    }
}
