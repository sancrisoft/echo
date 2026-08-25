//
//  SummarizationPipeline.swift
//  Echo
//
//  Generates a grounded meeting summary from final transcript segments only.
//  The local LLM runs in-process (MLX, behind the TextGenerating seam) and
//  streams so the UI can fill in progressively.
//
//  Two routes:
//  - Short transcripts take the single-pass path, which now writes an adaptive
//    Markdown document (Notion-style notes, `MeetingSummary.markdown`): the
//    model structures the notes freely instead of filling a fixed schema, and
//    the only post-processing is `sanitizedMarkdown` (trim + unwrap one outer
//    code fence).
//  - Long transcripts still route through NDJSON map-reduce (SPEC-05): each
//    SPEC-02 chunk is mapped to structured facts (validated by
//    NDJSONLineValidator, evidence checked against real segment IDs), the facts
//    merged deterministically in Swift (SummaryMerge), and a final grounded
//    prose pass writes short/detailed. Memory stays bounded — one generation is
//    ever in flight and the full transcript is never one prompt. Migrating this
//    route to markdown is a later slice.
//
//  Grounding on the long route stays executable, not just prompted (SPEC-05
//  §3): every evidence ID is filtered against the real segment IDs in scope,
//  and an item left with no valid evidence is dropped and logged. The markdown
//  route is grounded by prompt (and by the product rule that summaries never
//  invent owners, dates, decisions, or risks).
//

import Foundation
import os

actor SummarizationPipeline {

    static let log = Logger(subsystem: "com.sancrisoft.Echo", category: "SummarizationPipeline")

    /// At or below this transcript-token estimate we stay single-pass; above it
    /// we map-reduce. Chosen to match SPEC-02's default `hardMaxTokens` (8_000):
    /// a transcript this small is a single chunk anyway, so single-pass adds no
    /// risk, while larger ones lose extraction quality in an over-full context
    /// ("lost in the middle", SPEC-05 §2). On the 4B model an 8K-token KV cache
    /// is comfortable headroom rather than the memory ceiling it was on the
    /// retired 12B — the budget stands on quality grounds alone; retuning it is
    /// a separate, measured decision deferred past SP-004 (out of scope there).
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

    // MARK: - Single-pass route (adaptive markdown)

    private func runSinglePass(
        from segments: [TranscriptSegment],
        using engine: any TextGenerating,
        into continuation: AsyncThrowingStream<MeetingSummary, Error>.Continuation
    ) async throws {
        _ = try await generateMarkdown(
            system: Self.markdownSystemPrompt,
            user: Self.markdownUserPrompt(for: segments),
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

    // MARK: - Row caption (library one-liner)

    /// A single plain-text sentence describing the meeting, shown under the
    /// title in the library list. Generated from the finished summary — concise
    /// and already grounded in the transcript — rather than the raw transcript,
    /// and deliberately kept out of `MeetingSummary`: it is a headline for the
    /// row, not a summary section. Best-effort: any failure (or an empty reply)
    /// returns `nil` and the row simply shows no caption.
    func oneLineDescription(for summary: MeetingSummary, using engine: any TextGenerating) async -> String? {
        // Source preference mirrors the summary's own: the short prose when the
        // legacy route wrote one, else the adaptive markdown document (capped —
        // a headline needs the opening, not the whole notes), else the detailed
        // prose. A full caption rework for markdown is a later slice.
        let source: String
        if !summary.shortSummary.isEmpty {
            source = summary.shortSummary
        } else if !summary.markdown.isEmpty {
            source = String(summary.markdown.prefix(1200))
        } else {
            source = String(summary.detailedSummary.prefix(1200))
        }
        guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }

        var params = GenerationParams()
        params.maxTokens = 64
        params.temperature = 0.2

        var text = ""
        do {
            for try await delta in engine.stream(
                system: Self.captionSystemPrompt,
                user: Self.captionUserPrompt(source),
                params: params
            ) {
                try Task.checkCancellation()
                text += delta
                if text.count > 400 { break }   // one sentence never needs more
            }
        } catch {
            Self.log.warning("One-line description generation failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        return Self.cleanCaption(text)
    }

    private static let captionSystemPrompt = """
    You write a single, concise sentence that captures what a meeting was about, \
    in plain English. Output ONLY that one sentence: no preamble, no quotation \
    marks, no bullet points, no more than 16 words. Ground it strictly in the \
    notes provided; never invent specifics.
    """

    private static func captionUserPrompt(_ notes: String) -> String {
        """
        Meeting notes:

        \(notes)

        One sentence describing this meeting:
        """
    }

    /// First sentence, unwrapped from any quotes/label the model prepends,
    /// trimmed and length-capped.
    private static func cleanCaption(_ raw: String) -> String? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = text.range(of: "sentence:", options: .caseInsensitive) {
            text = String(text[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let newline = text.firstIndex(where: \.isNewline) {
            text = String(text[..<newline])
        }
        if let end = text.firstIndex(where: { $0 == "." || $0 == "!" || $0 == "?" }) {
            text = String(text[...end])
        }
        text = text.trimmingCharacters(in: CharacterSet(charactersIn: " \t\"'“”‘’"))
        guard !text.isEmpty else { return nil }
        if text.count > 160 {
            text = String(text.prefix(157)).trimmingCharacters(in: .whitespaces) + "…"
        }
        return text
    }

    // MARK: - Generation primitives

    /// One markdown-document generation with the same retry contract as
    /// `generateProse`: up to two attempts; success is a sanitized document
    /// that is non-empty after trimming. The accumulated raw text is
    /// re-sanitized on every delta and a snapshot streams whenever the visible
    /// document changed — so the UI fills in as the model writes, and a
    /// wrapping code fence disappears the moment its closing line lands.
    /// Throws `emptyModelResponse` if both attempts stay empty.
    private func generateMarkdown(
        system: String,
        user: String,
        engine: any TextGenerating,
        onSnapshot: @escaping (MeetingSummary) -> Void
    ) async throws -> MeetingSummary {
        for attempt in 0..<2 {
            var accumulated = ""
            var visible = ""
            do {
                for try await delta in engine.stream(system: system, user: user, params: GenerationParams()) {
                    try Task.checkCancellation()
                    guard !delta.isEmpty else { continue }
                    accumulated += delta
                    let sanitized = Self.sanitizedMarkdown(accumulated)
                    if sanitized != visible {
                        visible = sanitized
                        onSnapshot(Self.markdownSnapshot(sanitized))
                    }
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw SummarizationError.modelUnavailable(error.localizedDescription)
            }

            let document = Self.sanitizedMarkdown(accumulated)
            if !document.isEmpty {
                let snapshot = Self.markdownSnapshot(document)
                onSnapshot(snapshot)
                return snapshot
            }
            if attempt == 0 {
                Self.log.warning("Markdown generation produced an empty document; retrying once")
            }
        }
        throw SummarizationError.emptyModelResponse
    }

    /// One prose-bearing NDJSON generation (the map-reduce prose pass): up to
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

    // MARK: - Markdown sanitation (single-pass route)

    /// The single cleanup the markdown route applies to raw model output: trim
    /// surrounding whitespace, and unwrap ONE outer code fence — a small model's
    /// favorite way to disobey "no code fences" is to wrap the whole document in
    /// ``` or ```markdown. Only a true wrapper is unwrapped (first line opens a
    /// fence AND the last line closes one); a document that merely starts with a
    /// code block keeps its fences. Anything subtler — stray HTML, broken
    /// tables — is the renderer's job (later slice), not sanitation's.
    /// Internal (not private) so the table tests pin the behavior.
    static func sanitizedMarkdown(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.hasPrefix("```") else { return text }

        var lines = text.components(separatedBy: "\n")
        guard lines.count >= 2,
              lines.last?.trimmingCharacters(in: .whitespaces) == "```"
        else { return text }

        lines.removeFirst()
        lines.removeLast()
        text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return text
    }

    // MARK: - Snapshot helpers

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

    /// A markdown-route snapshot: the document is the whole summary, every
    /// legacy field stays empty (consumers branch on `markdown` being present).
    private static func markdownSnapshot(_ markdown: String) -> MeetingSummary {
        MeetingSummary(
            markdown: markdown,
            shortSummary: "",
            detailedSummary: "",
            decisions: [],
            actionItems: [],
            openQuestions: [],
            risks: []
        )
    }

    // MARK: - Prompts: single-pass (adaptive markdown, v1)

    /// The v1 ruleset — deliberately short. A later slice installs the full
    /// Notion-style ruleset; what must hold from day one is the grounding
    /// contract (nothing invented, owners/dates only when stated) and the
    /// document shape (Action Items first, then topic-specific sections).
    private static let markdownSystemPrompt = """
    You are a professional meeting note-taker for a local-first macOS app.
    Write the notes for the meeting transcript the user provides.

    Output: ONE Markdown document and nothing else — no code fences around it,
    no preamble, no closing remarks.

    Structure:
    - Begin with a "### Action Items" section: a "- [ ] " checkbox list of the
      real commitments people made in the meeting. If no commitments were made,
      omit this section entirely. Never invent owners or due dates — name them
      only when the transcript states them.
    - Then write "###" sections whose titles name the specific topics that were
      actually discussed. Never use generic titles like "Discussion", "Summary",
      or "Notes".

    Rules:
    - Ground every statement strictly in the transcript; if the transcript does
      not support a claim, leave it out.
    - Write in the dominant language of the transcript.
    - "You" is the current user speaking on the microphone; "Team" are the
      teammates heard through system audio.
    """

    private static func markdownUserPrompt(for segments: [TranscriptSegment]) -> String {
        """
        Write the meeting notes for this transcript as one Markdown document.

        Each transcript line is formatted as:
        [start-end] Speaker: text

        Transcript:
        \(plainTranscriptText(from: segments))
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

    /// Renders the merged, backchannel-filtered derivation (ADR-021) so the
    /// model reads conversation paragraphs, not decoder chunks. Each line
    /// carries the utterance's first-constituent segment ID — always a subset
    /// of `evidenceIDs(of:)` (which stays ALL segment IDs), so citation
    /// validation and the detail view's segment lookup keep resolving.
    /// Internal (not private) so the line format is table-tested (SP-007 S7).
    static func transcriptText(from segments: [TranscriptSegment]) -> String {
        TranscriptUtterance.derive(from: segments)
            .map { utterance in
                let start = timestamp(utterance.start)
                let end = timestamp(utterance.end)
                return "[\(start)-\(end)][\(speakerName(utterance.speaker))][\(utterance.channel.rawValue)][id=\(utterance.id.uuidString)]: \(utterance.text)"
            }
            .joined(separator: "\n")
    }

    /// The markdown route's rendering: the same derived utterances as
    /// `transcriptText` (so the two routes can never disagree about merging or
    /// backchannel filtering), minus the channel tag and segment IDs — the
    /// markdown prompt has no evidence protocol, and IDs only invite the model
    /// to quote them into the notes. Internal so the format is table-tested.
    static func plainTranscriptText(from segments: [TranscriptSegment]) -> String {
        TranscriptUtterance.derive(from: segments)
            .map { utterance in
                let start = timestamp(utterance.start)
                let end = timestamp(utterance.end)
                return "[\(start)-\(end)] \(speakerName(utterance.speaker)): \(utterance.text)"
            }
            .joined(separator: "\n")
    }

    /// Like `transcriptText`, but derives utterances within the chunk's own
    /// segments and marks a line `(overlap)` only when EVERY constituent is
    /// in the chunk's overlap head — an utterance mixing overlap and new
    /// segments is new content the model must not skip.
    static func chunkTranscriptText(for chunk: TranscriptChunk) -> String {
        TranscriptUtterance.derive(from: chunk.segments)
            .map { utterance in
                let isOverlap = utterance.segmentIDs
                    .allSatisfy { chunk.overlapSegmentIDs.contains($0) }
                let overlap = isOverlap ? "(overlap) " : ""
                let start = timestamp(utterance.start)
                let end = timestamp(utterance.end)
                return "\(overlap)[\(start)-\(end)][\(speakerName(utterance.speaker))][\(utterance.channel.rawValue)][id=\(utterance.id.uuidString)]: \(utterance.text)"
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
            return "The summary model returned an empty summary."
        }
    }
}
