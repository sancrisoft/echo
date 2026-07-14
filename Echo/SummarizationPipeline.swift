//
//  SummarizationPipeline.swift
//  Echo
//
//  Generates a grounded meeting summary from final transcript segments only.
//  The local LLM runs in-process (MLX, behind the TextGenerating seam) and
//  streams NDJSON (one JSON object per line) so the UI can fill in
//  progressively. Every completed line passes NDJSONLineValidator before
//  touching the accumulator — the structured-output guarantee the retired
//  GBNF grammar used to provide at the sampler.
//
//  Two routes (SPEC-05):
//  - Short transcripts take the original single-pass path unchanged: one
//    generation streams the whole summary.
//  - Long transcripts route through map-reduce: each SPEC-02 chunk is mapped to
//    structured facts (NDJSON, evidence validated against real segment IDs),
//    the facts merged deterministically in Swift (SummaryMerge), and a final
//    grounded prose pass writes short/detailed. Memory stays bounded — one
//    generation is ever in flight and the full transcript is never one prompt.
//
//  Grounding is executable, not just prompted (SPEC-05 §3): on BOTH routes every
//  evidence ID is filtered against the real segment IDs in scope, and an item
//  left with no valid evidence is dropped and logged.
//

import Foundation
import os

actor SummarizationPipeline {

    static let log = Logger(subsystem: "com.sancrisoft.Echo", category: "SummarizationPipeline")

    /// At or below this transcript-token estimate we stay single-pass; above it
    /// we map-reduce. Chosen to match SPEC-02's default `hardMaxTokens` (8_000):
    /// a transcript this small is a single chunk anyway, so single-pass adds no
    /// risk, while larger ones both blow the KV-cache memory budget on a 12B
    /// model and lose extraction quality in an over-full context (SPEC-05 §2).
    /// Uses SPEC-02's heuristic estimator (a real tokenizer is a later seam).
    nonisolated static let singlePassBudget = 8_000

    /// Streams progressively-more-complete summaries as the model emits NDJSON
    /// lines. Each element is a snapshot of everything parsed so far; the final
    /// element is the complete summary. Throws on engine/protocol failures.
    ///
    /// The engine is injected per call so tests can drive the full streaming
    /// path with a scripted TextGenerating fake. `progress` (optional) reports
    /// human-readable phase text on the long route ("Summarizing part 3/7…");
    /// the short route emits none. Existing callers pass nothing and are
    /// unaffected.
    func generate(
        from segments: [TranscriptSegment],
        using engine: any TextGenerating,
        progress: (@Sendable (String) -> Void)? = nil
    ) -> AsyncThrowingStream<MeetingSummary, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await self.run(from: segments, using: engine, progress: progress, into: continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Routing

    private func run(
        from segments: [TranscriptSegment],
        using engine: any TextGenerating,
        progress: (@Sendable (String) -> Void)?,
        into continuation: AsyncThrowingStream<MeetingSummary, Error>.Continuation
    ) async throws {
        guard !segments.isEmpty else { throw SummarizationError.emptyTranscript }

        // Route on the transcript size alone, independent of prompt overhead, so
        // the boundary is stable and matches chunking.
        if Self.estimatedTokens(of: segments) <= Self.singlePassBudget {
            try await runSinglePass(from: segments, using: engine, into: continuation)
        } else {
            try await runMapReduce(from: segments, using: engine, progress: progress, into: continuation)
        }
    }

    /// SPEC-02's heuristic (ceil(scalars/4), min 1 per non-empty segment),
    /// inlined so routing runs on this actor without hopping to the
    /// main-actor-isolated `HeuristicTokenEstimator`. Kept identical on purpose.
    private nonisolated static func estimatedTokens(of segments: [TranscriptSegment]) -> Int {
        segments.reduce(0) { total, segment in
            let scalars = segment.text.unicodeScalars.count
            return total + (scalars > 0 ? max(1, (scalars + 3) / 4) : 0)
        }
    }

    // MARK: - Single-pass route (parity with pre-SPEC-05 behavior)

    private func runSinglePass(
        from segments: [TranscriptSegment],
        using engine: any TextGenerating,
        into continuation: AsyncThrowingStream<MeetingSummary, Error>.Continuation
    ) async throws {
        let validIDs = Self.evidenceIDs(of: segments)
        _ = try await generateProse(
            system: Self.systemPrompt,
            user: Self.userPrompt(for: segments),
            allowed: [.prose, .facts],
            validEvidenceIDs: validIDs,
            seed: nil,
            engine: engine,
            onSnapshot: { continuation.yield($0) }
        )
    }

    // MARK: - Map-reduce route

    private func runMapReduce(
        from segments: [TranscriptSegment],
        using engine: any TextGenerating,
        progress: (@Sendable (String) -> Void)?,
        into continuation: AsyncThrowingStream<MeetingSummary, Error>.Continuation
    ) async throws {
        // TranscriptChunker is main-actor-isolated (SPEC-02); its chunking pass
        // is pure O(segments) Swift, so run it once on the main actor rather
        // than materializing the full transcript anywhere on the long path.
        let chunks = await MainActor.run { TranscriptChunker.chunks(from: segments) }
        guard !chunks.isEmpty else { throw SummarizationError.emptyTranscript }

        // Map: one generation per chunk, in series (one engine, bounded memory).
        // Snapshots grow as each chunk's facts are merged in.
        var mapResults: [ChunkMapResult] = []
        for chunk in chunks {
            try Task.checkCancellation()
            progress?("Summarizing part \(chunk.index + 1)/\(chunks.count)…")
            let result = try await mapChunk(chunk, engine: engine)
            mapResults.append(result)
            let merged = mergeMapResults(mapResults)
            continuation.yield(Self.snapshot(facts: merged, short: "", detailed: ""))
        }

        // Reduce (prose): one grounded generation over the merged facts + notes.
        try Task.checkCancellation()
        progress?("Writing summary…")
        let merged = mergeMapResults(mapResults)
        _ = try await generateProse(
            system: Self.proseSystemPrompt,
            user: Self.proseUserPrompt(facts: merged, notes: mapResults.sorted { $0.chunkIndex < $1.chunkIndex }),
            allowed: [.prose],
            validEvidenceIDs: [],
            seed: merged,
            engine: engine,
            onSnapshot: { continuation.yield($0) }
        )
        progress?("")
    }

    // MARK: - Map / merge / reduce (SPEC-05 §4 contract; reused by SPEC-07)

    /// Map one chunk to structured facts. Pure w.r.t. the engine seam: no state
    /// is retained between calls, so SPEC-07 can call this live as chunks close
    /// and cache the results. Evidence is validated against this chunk's real
    /// segment IDs (overlap included, since a fact may legitimately span it).
    func mapChunk(_ chunk: TranscriptChunk, engine: any TextGenerating) async throws -> ChunkMapResult {
        let validIDs = Self.evidenceIDs(of: chunk.segments)
        var accumulator = SummaryAccumulator(
            allowed: [.facts, .chunkNote], validEvidenceIDs: validIDs, seed: nil)
        try await consume(
            system: Self.mapSystemPrompt,
            user: Self.mapUserPrompt(for: chunk),
            engine: engine,
            into: &accumulator,
            onProgress: nil
        )
        let snapshot = accumulator.snapshot
        return ChunkMapResult(
            chunkIndex: chunk.index,
            decisions: snapshot.decisions,
            actionItems: snapshot.actionItems,
            openQuestions: snapshot.openQuestions,
            risks: snapshot.risks,
            chunkNote: accumulator.chunkNote,
            start: chunk.start,
            end: chunk.end
        )
    }

    /// Deterministic, engine-free merge (SummaryMerge). Nonisolated so SPEC-07
    /// and tests can reduce precomputed results without entering the actor.
    nonisolated func mergeMapResults(_ results: [ChunkMapResult]) -> MergedFacts {
        SummaryMerge.merge(results)
    }

    /// The final grounded prose pass over already-merged facts. Accepts
    /// precomputed results so SPEC-07 can drive it from its live cache.
    func reduceProse(
        facts: MergedFacts,
        notes: [ChunkMapResult],
        engine: any TextGenerating
    ) async throws -> (short: String, detailed: String) {
        let summary = try await generateProse(
            system: Self.proseSystemPrompt,
            user: Self.proseUserPrompt(facts: facts, notes: notes.sorted { $0.chunkIndex < $1.chunkIndex }),
            allowed: [.prose],
            validEvidenceIDs: [],
            seed: facts,
            engine: engine,
            onSnapshot: { _ in }
        )
        return (summary.shortSummary, summary.detailedSummary)
    }

    // MARK: - Generation primitives

    /// One prose-bearing generation with the single-pass retry contract: up to
    /// two attempts (fresh accumulator, re-seeded each time); success is a
    /// short/detailed line, or — only after the retry — any grounded content
    /// (facts). Snapshots stream via `onSnapshot` throughout. Throws
    /// `emptyModelResponse` if both attempts yield nothing usable.
    private func generateProse(
        system: String,
        user: String,
        allowed: AllowedShapes,
        validEvidenceIDs: Set<String>,
        seed: MergedFacts?,
        engine: any TextGenerating,
        onSnapshot: @escaping (MeetingSummary) -> Void
    ) async throws -> MeetingSummary {
        for attempt in 0..<2 {
            var accumulator = SummaryAccumulator(
                allowed: allowed, validEvidenceIDs: validEvidenceIDs, seed: seed)
            try await consume(
                system: system, user: user, engine: engine,
                into: &accumulator, onProgress: onSnapshot)

            let snapshot = accumulator.snapshot
            if !snapshot.shortSummary.isEmpty || !snapshot.detailedSummary.isEmpty {
                onSnapshot(snapshot)
                return snapshot
            }
            if attempt == 0 {
                Self.log.warning("Generation produced no valid short/detailed line; retrying once")
            } else if accumulator.hasContent {
                // Items without prose after the retry: unusual, but grounded
                // content beats an error (also the map-reduce facts-only path).
                onSnapshot(snapshot)
                return snapshot
            }
        }
        throw SummarizationError.emptyModelResponse
    }

    /// Stream one generation: split the engine's deltas into NDJSON lines,
    /// validate + apply each into `accumulator`, and preview the in-progress
    /// prose line char-by-char. Calls `onProgress` after any delta that changed
    /// the visible summary. A single attempt — retry/routing is the caller's job.
    private func consume(
        system: String,
        user: String,
        engine: any TextGenerating,
        into accumulator: inout SummaryAccumulator,
        onProgress: ((MeetingSummary) -> Void)?
    ) async throws {
        var buffer = ""
        do {
            for try await delta in engine.stream(system: system, user: user, params: GenerationParams()) {
                try Task.checkCancellation()
                guard !delta.isEmpty else { continue }

                buffer += delta

                var changed = false
                while let newline = buffer.firstIndex(of: "\n") {
                    let line = String(buffer[buffer.startIndex..<newline])
                    buffer.removeSubrange(buffer.startIndex...newline)
                    if accumulator.applyValidatedLine(line) { changed = true }
                }
                // Preview the in-progress prose line (short/detailed) char-by-char.
                if accumulator.applyPartialProse(buffer) { changed = true }

                if changed { onProgress?(accumulator.snapshot) }
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw SummarizationError.modelUnavailable(error.localizedDescription)
        }

        // Every entry is newline-terminated by protocol, but flush a trailing
        // object in case the stream ends without one.
        let tail = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty { _ = accumulator.applyValidatedLine(tail) }
    }

    // MARK: - Snapshot helper

    private static func snapshot(facts: MergedFacts, short: String, detailed: String) -> MeetingSummary {
        MeetingSummary(
            shortSummary: short,
            detailedSummary: detailed,
            decisions: facts.decisions,
            actionItems: facts.actionItems,
            openQuestions: facts.openQuestions,
            risks: facts.risks
        )
    }

    // MARK: - Prompts: single-pass (unchanged for parity)

    private static let systemPrompt = """
    You summarize meeting transcripts for a local-first macOS app.
    Use only the transcript provided by the user.
    Do not invent decisions, action item owners, due dates, risks, or blockers.
    If an owner or due date is unclear, use null.
    Do not infer calendar dates from relative wording.
    Keep the summary in the dominant language of the transcript.

    Output format: NDJSON. Emit ONE JSON object per line and nothing else —
    no prose, no Markdown, no code fences. Each line is one complete JSON object.

    Allowed line shapes:
    {"type":"short","text":"one or two sentences"}
    {"type":"detailed","text":"a thorough paragraph"}
    {"type":"decision","title":"...","details":"...","evidence":["segment-id"]}
    {"type":"action","task":"...","owner":"... or null","due":"... or null","evidence":["segment-id"]}
    {"type":"question","question":"...","context":"... or null","evidence":["segment-id"]}
    {"type":"risk","risk":"...","details":"... or null","evidence":["segment-id"]}

    Rules:
    - Emit exactly one "short" line, then one "detailed" line, first.
    - Then emit zero or more decision, action, question, and risk lines.
    - Every decision, action, question, and risk line must include at least one
      evidence segment-id copied verbatim from the transcript.
    - If a claim cannot be supported by a transcript segment, omit it.
    - List each distinct decision, action item, question, and risk only once.
      Never repeat or rephrase the same point across multiple lines.
    - "You" means the current user; "Team" means teammates from system audio.
    """

    private static func userPrompt(for segments: [TranscriptSegment]) -> String {
        """
        Summarize this final meeting transcript as NDJSON.

        Each transcript line is formatted as:
        [start-end][speaker][channel][id=SEGMENT_ID]: text
        Copy the SEGMENT_ID values into "evidence".

        Transcript:
        \(transcriptText(from: segments))
        """
    }

    // MARK: - Prompts: map phase

    private static let mapSystemPrompt = """
    You extract structured facts from ONE part of a longer meeting transcript for
    a local-first macOS app. You are given only this part; other parts are handled
    separately, so summarize only what this part supports.
    Use only the transcript text provided by the user.
    Do not invent decisions, action item owners, due dates, risks, or blockers.
    If an owner or due date is unclear, use null.
    Do not infer calendar dates from relative wording.

    Output format: NDJSON. Emit ONE JSON object per line and nothing else —
    no prose, no Markdown, no code fences. Each line is one complete JSON object.

    Allowed line shapes:
    {"type":"chunknote","text":"a 2-4 sentence gist of what this part covered"}
    {"type":"decision","title":"...","details":"...","evidence":["segment-id"]}
    {"type":"action","task":"...","owner":"... or null","due":"... or null","evidence":["segment-id"]}
    {"type":"question","question":"...","context":"... or null","evidence":["segment-id"]}
    {"type":"risk","risk":"...","details":"... or null","evidence":["segment-id"]}

    Rules:
    - Emit exactly one "chunknote" line first. Write the gist (2-4 sentences) in
      the dominant language of the transcript.
    - Then emit zero or more decision, action, question, and risk lines. A part
      may contain none — that is fine; still emit the chunknote.
    - Every decision, action, question, and risk line must include at least one
      evidence segment-id copied verbatim from the transcript below.
    - If a claim cannot be supported by a transcript segment, omit it.
    - Some lines at the start are marked (overlap): they were already covered by
      the previous part. Do NOT report a fact whose evidence is entirely from
      (overlap) lines. If a fact spans an (overlap) line and a new one, report it
      and cite both.
    - List each distinct decision, action item, question, and risk only once.
    - "You" means the current user; "Team" means teammates from system audio.
    """

    private static func mapUserPrompt(for chunk: TranscriptChunk) -> String {
        """
        Extract structured facts from this PART of a meeting transcript as NDJSON.

        Each transcript line is formatted as:
        [start-end][speaker][channel][id=SEGMENT_ID]: text
        Lines marked (overlap) were already covered by the previous part.
        Copy the SEGMENT_ID values into "evidence".

        Transcript part:
        \(chunkTranscriptText(for: chunk))
        """
    }

    // MARK: - Prompts: prose reduce phase

    private static let proseSystemPrompt = """
    You write the final summary of a meeting for a local-first macOS app, based
    ONLY on the extracted notes and facts the user provides. The meeting was
    processed in parts; you are given a per-part gist plus the merged,
    de-duplicated facts.
    Do NOT introduce any decision, action, owner, due date, question, or risk that
    is not present in the material provided. Do not invent details.
    Keep the summary in the dominant language of the material.

    Output format: NDJSON. Emit ONE JSON object per line and nothing else —
    no prose, no Markdown, no code fences. Each line is one complete JSON object.

    Allowed line shapes (emit EXACTLY these two, in this order, and nothing else):
    {"type":"short","text":"one or two sentences covering the whole meeting"}
    {"type":"detailed","text":"a thorough paragraph covering the whole meeting"}

    Rules:
    - Emit exactly one "short" line, then one "detailed" line.
    - Ground every statement in the notes and facts below; add nothing new.
    - Cover the whole meeting, using the ordered part notes for the arc.
    - "You" means the current user; "Team" means teammates from system audio.
    """

    private static func proseUserPrompt(facts: MergedFacts, notes: [ChunkMapResult]) -> String {
        var lines: [String] = [
            "Write the meeting summary as NDJSON: one \"short\" line, then one",
            "\"detailed\" line. Use ONLY the material below and add nothing new.",
            "",
            "Part notes (in chronological order):",
        ]
        let partNotes = notes
            .map { note -> String in
                let gist = note.chunkNote.trimmingCharacters(in: .whitespacesAndNewlines)
                let range = "[\(timestamp(note.start))-\(timestamp(note.end))]"
                return gist.isEmpty ? "\(range) (no notable content)" : "\(range) \(gist)"
            }
        lines.append(contentsOf: partNotes.isEmpty ? ["(none)"] : partNotes)

        lines.append("")
        lines.append("Decisions:")
        lines.append(contentsOf: facts.decisions.isEmpty
            ? ["(none)"]
            : facts.decisions.map { decision in
                let details = decision.details.trimmingCharacters(in: .whitespacesAndNewlines)
                return details.isEmpty ? "- \(decision.title)" : "- \(decision.title): \(details)"
            })

        lines.append("")
        lines.append("Action items:")
        lines.append(contentsOf: facts.actionItems.isEmpty
            ? ["(none)"]
            : facts.actionItems.map { action in
                "- \(action.task) (owner: \(action.owner ?? "unspecified"), due: \(action.dueDate ?? "unspecified"))"
            })

        lines.append("")
        lines.append("Open questions:")
        lines.append(contentsOf: facts.openQuestions.isEmpty
            ? ["(none)"]
            : facts.openQuestions.map { "- \($0.question)" })

        lines.append("")
        lines.append("Risks:")
        lines.append(contentsOf: facts.risks.isEmpty
            ? ["(none)"]
            : facts.risks.map { "- \($0.risk)" })

        return lines.joined(separator: "\n")
    }

    // MARK: - Transcript rendering

    private static func transcriptText(from segments: [TranscriptSegment]) -> String {
        segments
            .sorted { $0.start < $1.start }
            .map { segment in
                let start = timestamp(segment.start)
                let end = timestamp(segment.end)
                return "[\(start)-\(end)][\(speakerName(segment.speaker))][\(segment.channel.rawValue)][id=\(segment.id.uuidString)]: \(segment.text)"
            }
            .joined(separator: "\n")
    }

    /// Like `transcriptText`, but marks the overlap head (repeated from the
    /// previous chunk) so the model can skip facts it already reported. The
    /// chunk owns its segment order; we keep it as-is.
    private static func chunkTranscriptText(for chunk: TranscriptChunk) -> String {
        chunk.segments
            .map { segment in
                let overlap = chunk.overlapSegmentIDs.contains(segment.id) ? "(overlap) " : ""
                let start = timestamp(segment.start)
                let end = timestamp(segment.end)
                return "\(overlap)[\(start)-\(end)][\(speakerName(segment.speaker))][\(segment.channel.rawValue)][id=\(segment.id.uuidString)]: \(segment.text)"
            }
            .joined(separator: "\n")
    }

    private static func speakerName(_ speaker: Speaker) -> String {
        switch speaker {
        case .me: return "You"
        case .teammates: return "Team"
        }
    }

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

    /// The lowercased set of segment IDs a generation may cite as evidence.
    private static func evidenceIDs(of segments: [TranscriptSegment]) -> Set<String> {
        Set(segments.map { $0.id.uuidString.lowercased() })
    }

    // MARK: - Partial-line preview

    /// Best-effort decode of the in-progress prose line so short/detailed text
    /// can grow on screen before the line is terminated. Returns nil for line
    /// types whose partial content we don't preview (lists) or unparseable heads.
    private static func partialProse(_ fragment: String) -> (type: String, text: String)? {
        guard let typeMarker = fragment.range(of: "\"type\":\"") else { return nil }
        let afterType = fragment[typeMarker.upperBound...]
        guard let typeEnd = afterType.firstIndex(of: "\"") else { return nil }
        let type = String(afterType[..<typeEnd])
        guard type == "short" || type == "detailed" else { return nil }

        guard let textMarker = fragment.range(of: "\"text\":\"") else { return nil }

        var text = ""
        var escaped = false
        for character in fragment[textMarker.upperBound...] {
            if escaped {
                switch character {
                case "n": text.append("\n")
                case "t": text.append("\t")
                case "r": text.append("\r")
                default: text.append(character)
                }
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "\"" {
                break // unescaped quote → end of the value
            } else {
                text.append(character)
            }
        }
        return (type, text)
    }

    // MARK: - Field helpers

    private static func string(_ key: String, in object: [String: Any]) -> String {
        optionalString(key, in: object) ?? ""
    }

    private static func optionalString(_ key: String, in object: [String: Any]) -> String? {
        guard let value = object[key], !(value is NSNull) else { return nil }
        let string = value as? String ?? "\(value)"
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        // The protocol allows a real `null` or a quoted string; a small model
        // often picks the string and writes "null". Treat that as absent.
        guard !trimmed.isEmpty, trimmed.lowercased() != "null" else { return nil }
        return trimmed
    }

    private static func stringArray(_ key: String, in object: [String: Any]) -> [String] {
        guard let values = object[key] as? [Any] else { return [] }
        return values.compactMap { value in
            if value is NSNull { return nil }
            let string = value as? String ?? "\(value)"
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
    }

    // MARK: - Allowed shapes per phase

    /// Which NDJSON line types a generation may contribute. The validator gates
    /// well-formedness; this gates *which* well-formed shapes a phase accepts, so
    /// a stray prose line in the map phase (or a stray fact in the prose phase)
    /// is silently ignored rather than corrupting the phase output.
    private struct AllowedShapes: OptionSet {
        let rawValue: Int
        static let prose = AllowedShapes(rawValue: 1 << 0)      // short, detailed
        static let facts = AllowedShapes(rawValue: 1 << 1)      // decision/action/question/risk
        static let chunkNote = AllowedShapes(rawValue: 1 << 2)  // chunknote
    }

    // MARK: - NDJSON accumulator

    /// Builds a `MeetingSummary` incrementally from streamed NDJSON lines, gating
    /// each line by the phase's allowed shapes and filtering evidence against the
    /// real segment IDs in scope (executable grounding, SPEC-05 §3).
    private struct SummaryAccumulator {
        private let allowed: AllowedShapes
        /// Lowercased segment IDs a cited evidence ID must match to survive.
        private let validEvidenceIDs: Set<String>

        private var shortSummary = ""
        private var detailedSummary = ""
        private var decisions: [SummaryDecision] = []
        private var actionItems: [SummaryActionItem] = []
        private var openQuestions: [SummaryOpenQuestion] = []
        private var risks: [SummaryRisk] = []
        /// The map phase's chunk gist; unused (stays "") on other phases.
        private(set) var chunkNote = ""

        /// Normalized "type + primary text" keys already added, so the common
        /// small-model loop of repeating the same item is collapsed to one.
        private var seenKeys: Set<String> = []

        init(allowed: AllowedShapes, validEvidenceIDs: Set<String>, seed: MergedFacts?) {
            self.allowed = allowed
            self.validEvidenceIDs = validEvidenceIDs
            if let seed {
                // Seed the prose reduce with the merged facts so its snapshots
                // carry the full summary while prose streams in. Prose phase
                // never re-adds facts (they are not in `allowed`), so no dedup
                // seeding is needed.
                decisions = seed.decisions
                actionItems = seed.actionItems
                openQuestions = seed.openQuestions
                risks = seed.risks
            }
        }

        var snapshot: MeetingSummary {
            MeetingSummary(
                shortSummary: shortSummary,
                detailedSummary: detailedSummary,
                decisions: decisions,
                actionItems: actionItems,
                openQuestions: openQuestions,
                risks: risks
            )
        }

        var hasContent: Bool {
            !shortSummary.isEmpty || !detailedSummary.isEmpty || !decisions.isEmpty
                || !actionItems.isEmpty || !openQuestions.isEmpty || !risks.isEmpty
        }

        /// Gate + apply one completed NDJSON line. Invalid lines are dropped and
        /// logged, never shown — the UI-observable behavior matches the old
        /// grammar-constrained runtime.
        mutating func applyValidatedLine(_ line: String) -> Bool {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return false }
            guard NDJSONLineValidator.isValid(trimmed) else {
                SummarizationPipeline.log.warning(
                    "Dropping malformed NDJSON line: \(String(trimmed.prefix(200)), privacy: .public)")
                return false
            }
            return applyLine(trimmed)
        }

        /// Apply one complete, well-formed NDJSON line. Returns true if it
        /// changed the summary.
        private mutating func applyLine(_ line: String) -> Bool {
            guard
                let data = line.data(using: .utf8),
                let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let type = object["type"] as? String
            else {
                return false
            }

            switch type {
            case "short":
                guard allowed.contains(.prose) else { return false }
                shortSummary = SummarizationPipeline.string("text", in: object)
                return true
            case "detailed":
                guard allowed.contains(.prose) else { return false }
                detailedSummary = SummarizationPipeline.string("text", in: object)
                return true
            case "chunknote":
                guard allowed.contains(.chunkNote) else { return false }
                let text = SummarizationPipeline.string("text", in: object)
                guard !text.isEmpty else { return false }
                chunkNote = text
                return true
            case "decision":
                guard allowed.contains(.facts) else { return false }
                let title = SummarizationPipeline.string("title", in: object)
                guard !title.isEmpty else { return false }
                guard let evidence = groundedEvidence(type, in: object) else { return false }
                guard accept("decision", title, count: decisions.count) else { return false }
                decisions.append(SummaryDecision(
                    title: title,
                    details: SummarizationPipeline.string("details", in: object),
                    evidenceSegmentIDs: evidence
                ))
                return true
            case "action":
                guard allowed.contains(.facts) else { return false }
                let task = SummarizationPipeline.string("task", in: object)
                guard !task.isEmpty else { return false }
                guard let evidence = groundedEvidence(type, in: object) else { return false }
                guard accept("action", task, count: actionItems.count) else { return false }
                actionItems.append(SummaryActionItem(
                    task: task,
                    owner: SummarizationPipeline.optionalString("owner", in: object),
                    dueDate: SummarizationPipeline.optionalString("due", in: object),
                    evidenceSegmentIDs: evidence
                ))
                return true
            case "question":
                guard allowed.contains(.facts) else { return false }
                let question = SummarizationPipeline.string("question", in: object)
                guard !question.isEmpty else { return false }
                guard let evidence = groundedEvidence(type, in: object) else { return false }
                guard accept("question", question, count: openQuestions.count) else { return false }
                openQuestions.append(SummaryOpenQuestion(
                    question: question,
                    context: SummarizationPipeline.optionalString("context", in: object),
                    evidenceSegmentIDs: evidence
                ))
                return true
            case "risk":
                guard allowed.contains(.facts) else { return false }
                let risk = SummarizationPipeline.string("risk", in: object)
                guard !risk.isEmpty else { return false }
                guard let evidence = groundedEvidence(type, in: object) else { return false }
                guard accept("risk", risk, count: risks.count) else { return false }
                risks.append(SummaryRisk(
                    risk: risk,
                    details: SummarizationPipeline.optionalString("details", in: object),
                    evidenceSegmentIDs: evidence
                ))
                return true
            default:
                return false
            }
        }

        /// Filter a line's evidence to the real segment IDs in scope. Returns nil
        /// (drop the item, and log) when nothing survives — executable grounding.
        private func groundedEvidence(_ type: String, in object: [String: Any]) -> [String]? {
            let cited = SummarizationPipeline.stringArray("evidence", in: object)
            let real = cited.filter { validEvidenceIDs.contains($0.lowercased()) }
            guard !real.isEmpty else {
                SummarizationPipeline.log.warning(
                    "Dropping \(type, privacy: .public) with no valid evidence after filtering")
                return nil
            }
            return real
        }

        /// Gate a list item: reject it if the section is full or if an item with
        /// the same normalized primary text was already added. Records the key.
        private mutating func accept(_ type: String, _ primaryText: String, count: Int) -> Bool {
            guard count < SummaryLimits.maxItemsPerSection else { return false }
            let key = SummaryDedup.key(type, primaryText)
            return seenKeys.insert(key).inserted
        }

        /// Preview the in-progress prose line. Returns true if the visible text
        /// changed. No-op unless the phase accepts prose.
        mutating func applyPartialProse(_ fragment: String) -> Bool {
            guard allowed.contains(.prose),
                  let (type, text) = SummarizationPipeline.partialProse(fragment) else { return false }
            switch type {
            case "short":
                guard text != shortSummary else { return false }
                shortSummary = text
                return true
            case "detailed":
                guard text != detailedSummary else { return false }
                detailedSummary = text
                return true
            default:
                return false
            }
        }
    }

}

enum SummarizationError: LocalizedError {
    case emptyTranscript
    case modelUnavailable(String)
    case emptyModelResponse

    var errorDescription: String? {
        switch self {
        case .emptyTranscript:
            return "No transcript was captured."
        case .modelUnavailable(let message):
            return "The summary model is unavailable: \(message)"
        case .emptyModelResponse:
            return "Gemma returned an empty summary."
        }
    }
}
