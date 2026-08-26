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
/// deltas) and replays it, recording what the pipeline asked for (system,
/// user, params) so tests can assert on the real prompts in flight. Call
/// order matches the pipeline's phase order — one map per chunk in chunk
/// order, then one markdown reduce.
private final class ScriptedEngine: TextGenerating, @unchecked Sendable {

    struct RecordedCall {
        let system: String
        let user: String
        let params: GenerationParams
    }

    private let lock = NSLock()
    private var scripts: [[String]]
    private var recorded: [RecordedCall] = []

    init(scripts: [[String]]) { self.scripts = scripts }

    func stream(system: String, user: String, params: GenerationParams)
        -> AsyncThrowingStream<String, Error>
    {
        lock.lock()
        recorded.append(RecordedCall(system: system, user: user, params: params))
        let chunks = scripts.isEmpty ? [] : scripts.removeFirst()
        lock.unlock()
        return AsyncThrowingStream { continuation in
            for chunk in chunks { continuation.yield(chunk) }
            continuation.finish()
        }
    }

    var calls: Int { lock.lock(); defer { lock.unlock() }; return recorded.count }

    var recordedCalls: [RecordedCall] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }
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

/// The reduce is a markdown generation now (same document contract as the
/// single-pass route), so its script is one adaptive document, not NDJSON.
private let reduceDocument = """
### Action Items
- [ ] You to ship the release

### Release Review
The team agreed the build is ready.
"""

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

    @Test("a short transcript takes the single-pass path (one markdown generation)")
    func shortRoutesSinglePass() async throws {
        let id = UUID()
        let engine = ScriptedEngine(scripts: [[
            "### Quick Sync\nA brief chat, nothing decided.\n"
        ]])
        let pipeline = SummarizationPipeline()

        var final: MeetingSummary?
        for try await snapshot in await pipeline.generate(
            from: [segment("brief chat", id: id, start: 0, end: 4)], using: engine) {
            final = snapshot
        }

        #expect(engine.calls == 1)                    // single-pass: one call only
        #expect(final?.markdown == "### Quick Sync\nA brief chat, nothing decided.")
        #expect(final?.shortSummary.isEmpty == true)  // markdown route fills no legacy fields
    }

    @Test("a long transcript maps each chunk then reduces to one markdown document")
    func longRoutesMapReduce() async throws {
        let segments = longTranscript(segmentCount: 40)
        let chunks = TranscriptChunker.chunks(from: segments)
        #expect(chunks.count >= 2)   // fixture actually splits

        // One map script per chunk (each cites a real segment ID from that
        // chunk, and contributes a distinct decision), then a markdown reduce.
        var scripts: [[String]] = chunks.map { chunk in
            let realID = chunk.segments.first!.id.uuidString
            return [chunkNote("gist \(chunk.index)") + decisionLine("Decision \(chunk.index)", evidence: realID)]
        }
        scripts.append([reduceDocument])
        let engine = ScriptedEngine(scripts: scripts)
        let pipeline = SummarizationPipeline()

        var phases: [String] = []
        var final: MeetingSummary?
        for try await snapshot in await pipeline.generate(
            from: segments, using: engine, progress: { phases.append($0) }) {
            final = snapshot
        }

        // Route was map-reduce: N maps + 1 markdown reduce.
        #expect(engine.calls == chunks.count + 1)
        // Progress surfaced per-part text and cleared at the end.
        #expect(phases.contains("Summarizing part 1/\(chunks.count)…"))
        #expect(phases.contains("Summarizing part \(chunks.count)/\(chunks.count)…"))
        #expect(phases.last == "")

        // The final summary carries the document AND the merged facts together:
        // the store's summary.md mirror reads the markdown, fact consumers
        // (RAG, evidence UI) read the sections — neither may lose out.
        let summary = try #require(final)
        #expect(summary.markdown == reduceDocument)
        #expect(summary.decisions.count == chunks.count)
        // The legacy prose fields stay empty — the document replaced them.
        #expect(summary.shortSummary.isEmpty)
        #expect(summary.detailedSummary.isEmpty)
    }

    @Test("snapshots carry growing facts during maps, then a growing document")
    func snapshotsGrowMonotonically() async throws {
        let segments = longTranscript(segmentCount: 40)
        let chunks = TranscriptChunker.chunks(from: segments)
        var scripts: [[String]] = chunks.map { chunk in
            let realID = chunk.segments.first!.id.uuidString
            return [chunkNote("g\(chunk.index)") + decisionLine("Decision \(chunk.index)", evidence: realID)]
        }
        // The reduce streams in pieces so document growth is observable.
        scripts.append(["### Notes\nFirst ", "half, ", "then the rest."])
        let engine = ScriptedEngine(scripts: scripts)
        let pipeline = SummarizationPipeline()

        var snapshots: [MeetingSummary] = []
        for try await snapshot in await pipeline.generate(from: segments, using: engine) {
            snapshots.append(snapshot)
        }

        #expect(snapshots.count >= chunks.count + 2)
        // Facts never shrink and the document never shrinks (sections and the
        // document only fill in).
        var previousDecisions = 0
        var previousMarkdown = 0
        for snapshot in snapshots {
            #expect(snapshot.decisions.count >= previousDecisions)
            #expect(snapshot.markdown.count >= previousMarkdown)
            previousDecisions = snapshot.decisions.count
            previousMarkdown = snapshot.markdown.count
        }
        // Mid-map snapshots are facts-only (markdown stays "" — the UI's
        // resolvedMarkdown shim renders the growing facts, by design)…
        let firstWithDocument = try #require(
            snapshots.firstIndex { !$0.markdown.isEmpty })
        for snapshot in snapshots[..<firstWithDocument] {
            #expect(snapshot.markdown.isEmpty)
        }
        // …and every reduce snapshot carries the full merged facts alongside
        // the in-progress document.
        for snapshot in snapshots[firstWithDocument...] {
            #expect(snapshot.decisions.count == chunks.count)
        }
        #expect(snapshots.last?.markdown == "### Notes\nFirst half, then the rest.")
    }

    /// The long route's standing principle: grounded content beats an error.
    /// If the markdown reduce comes back empty twice, the pipeline must not
    /// throw away N successful map generations — it degrades to the facts-only
    /// summary (markdown stays "", the resolvedMarkdown shim renders the facts).
    @Test("an empty reduce degrades to the facts-only summary instead of erroring")
    func emptyReduceDegradesToFacts() async throws {
        let segments = longTranscript(segmentCount: 40)
        let chunks = TranscriptChunker.chunks(from: segments)
        var scripts: [[String]] = chunks.map { chunk in
            let realID = chunk.segments.first!.id.uuidString
            return [chunkNote("g\(chunk.index)") + decisionLine("Decision \(chunk.index)", evidence: realID)]
        }
        scripts.append(["   \n"])    // reduce attempt 1: whitespace only
        scripts.append(["\t\n\n"])   // reduce attempt 2 (the retry): still nothing
        let engine = ScriptedEngine(scripts: scripts)
        let pipeline = SummarizationPipeline()

        var final: MeetingSummary?
        for try await snapshot in await pipeline.generate(from: segments, using: engine) {
            final = snapshot
        }

        // Both reduce attempts ran (maps + 2), and nothing threw.
        #expect(engine.calls == chunks.count + 2)
        let summary = try #require(final)
        #expect(summary.markdown.isEmpty)
        #expect(summary.decisions.count == chunks.count)   // the grounded facts survive
    }

    @Test("cancelling mid-maps stops the pipeline before the reduce")
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
        // No document ever reached us, and the merged facts had only chunk 0.
        #expect(snapshots.allSatisfy { $0.markdown.isEmpty })
        // The reduce is call `chunks.count + 1`; it must never have run.
        #expect(engine.calls <= chunks.count)
    }
}

// MARK: - mapChunk grounding + reduceMarkdown contract

@Suite("mapChunk and reduceMarkdown")
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

    /// The reduce can only be as specific as the chunk notes — a thin "gist"
    /// starves it of the numbers and names long meetings are judged on. The
    /// invariants (not full text, wording may be tuned): the note is 4-8
    /// sentences, names the topics, and demands the concrete specifics.
    @Test("the map prompt demands a detailed, specific chunk note")
    func mapPromptDemandsDetailedChunkNote() async throws {
        let real = segment("real content", start: 0, end: 4)
        let chunk = makeChunk(index: 0, segments: [real])
        let engine = ScriptedEngine(scripts: [[chunkNote("a note")]])
        let pipeline = SummarizationPipeline()

        _ = try await pipeline.mapChunk(chunk, engine: engine)

        let system = try #require(engine.recordedCalls.first).system
        #expect(system.contains("4-8 sentences"))
        #expect(system.localizedCaseInsensitiveContains("topics"))
        #expect(system.localizedCaseInsensitiveContains("numbers"))
        #expect(system.localizedCaseInsensitiveContains("root causes"))
        #expect(!system.contains("2-4 sentence"))   // the thin gist contract is gone
    }

    /// S10: on the long route the reduce writes from chunk notes, so the
    /// notes' language decides the document's language. A detected transcript
    /// language must reach the map USER prompt as an explicit chunknote
    /// instruction; with no confident detection the prompt stays generic.
    @Test("the map prompt carries the explicit chunknote language when detected")
    func mapPromptCarriesExplicitLanguage() async throws {
        let real = segment("contenido real", start: 0, end: 4)
        let chunk = makeChunk(index: 0, segments: [real])
        let engine = ScriptedEngine(scripts: [[chunkNote("una nota")], [chunkNote("a note")]])
        let pipeline = SummarizationPipeline()

        _ = try await pipeline.mapChunk(chunk, engine: engine, language: "Spanish")
        _ = try await pipeline.mapChunk(chunk, engine: engine)

        let withLanguage = try #require(engine.recordedCalls.first).user
        #expect(withLanguage.contains("Write the chunknote in Spanish."))
        let without = try #require(engine.recordedCalls.last).user
        #expect(!without.contains("Write the chunknote in"))
    }

    /// The reduce is the same seam SPEC-07 will drive from its live cache:
    /// precomputed facts + notes in, one adaptive markdown document out. It
    /// writes markdown prose, so it must sample with the markdown preset —
    /// the NDJSON default's penalties would degrade a checkbox-heavy document.
    @Test("reduceMarkdown returns the document from precomputed facts")
    func reduceMarkdownContract() async throws {
        let facts = MergedFacts(decisions: [
            SummaryDecision(title: "Ship it", details: "", evidenceSegmentIDs: ["A"])])
        let notes = [ChunkMapResult(
            chunkIndex: 0, decisions: facts.decisions, actionItems: [], openQuestions: [],
            risks: [], chunkNote: "we agreed to ship", start: 0, end: 60)]
        let engine = ScriptedEngine(scripts: [["### Notes\nWe agreed to ship."]])
        let pipeline = SummarizationPipeline()

        let document = try await pipeline.reduceMarkdown(facts: facts, notes: notes, engine: engine)
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
            openQuestions: [SummaryOpenQuestion(
                question: "Which regions get the beta first?", context: nil,
                evidenceSegmentIDs: ["C"])],
            risks: [])
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
        let pipeline = SummarizationPipeline()

        _ = try await pipeline.reduceMarkdown(facts: facts, notes: notes, engine: engine)
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

        // S9 recency reinforcement: the material CLOSES with the work-notes
        // reminder (chunk notes are the reduce's small-talk leak channel),
        // which carries both probabilistic traps — small talk and ownership.
        let reminder = try #require(user.range(of: "Reminder: these are WORK notes."))
        #expect(second.lowerBound < reminder.lowerBound)
        #expect(user.localizedCaseInsensitiveContains("leave out all social and personal conversation"))
        #expect(user.localizedCaseInsensitiveContains("no section, no mention"))
        // S10: no language handed in -> generic prompts, ownership recap
        // stays the closer.
        #expect(!user.contains("Write the notes in"))
        #expect(user.hasSuffix("checkbox with NO name."))
    }

    /// S10: a detected language reaches the reduce user prompt explicitly —
    /// as an opening instruction and as the reminder's final sentence (the
    /// closing slot dominates, measured in S9). Zero-sum guard: the small-talk
    /// and ownership recaps survive alongside the appended language sentence.
    @Test("the reduce user prompt carries the explicit language when detected")
    func reducePromptCarriesExplicitLanguage() async throws {
        let facts = MergedFacts(decisions: [
            SummaryDecision(title: "Lanzar", details: "", evidenceSegmentIDs: ["A"])])
        let notes = [ChunkMapResult(
            chunkIndex: 0, decisions: facts.decisions, actionItems: [], openQuestions: [],
            risks: [], chunkNote: "acordamos lanzar", start: 0, end: 60)]
        let engine = ScriptedEngine(scripts: [["### Notas\nCuerpo."]])
        let pipeline = SummarizationPipeline()

        _ = try await pipeline.reduceMarkdown(
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
        let facts = MergedFacts(decisions: [
            SummaryDecision(title: "Ship it", details: "", evidenceSegmentIDs: ["A"])])
        let notes = [ChunkMapResult(
            chunkIndex: 0, decisions: facts.decisions, actionItems: [], openQuestions: [],
            risks: [], chunkNote: "we agreed to ship", start: 0, end: 60)]
        let engine = ScriptedEngine(scripts: [["### Notes\nBody."]])
        let pipeline = SummarizationPipeline()

        _ = try await pipeline.reduceMarkdown(facts: facts, notes: notes, engine: engine)
        let system = try #require(engine.recordedCalls.first).system

        // The five pinned adaptive-ruleset phrases (shared with single-pass).
        #expect(system.contains("### Action Items"))
        #expect(system.localizedCaseInsensitiveContains("never invent an owner or a due date"))
        #expect(system.contains("dominant language of the transcript"))
        #expect(system.localizedCaseInsensitiveContains("no code fences"))
        #expect(system.localizedCaseInsensitiveContains("never write an empty section"))
        // The no-new-items grounding rule, re-anchored to the material.
        #expect(system.localizedCaseInsensitiveContains(
            "do not introduce any decision, action, owner, due date, question, or risk"))
        // S8: the hard small-talk omission rides the shared block into the
        // reduce prompt too.
        #expect(system.localizedCaseInsensitiveContains("no section, no mention"))
    }
}
