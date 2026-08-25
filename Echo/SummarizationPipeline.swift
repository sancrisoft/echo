//
//  SummarizationPipeline.swift
//  Echo
//
//  Generates a grounded meeting summary from final transcript segments only.
//  The local LLM runs in-process (MLX, behind the TextGenerating seam) and
//  streams so the UI can fill in progressively.
//
//  Two routes, one output: an adaptive Markdown document (Notion-style notes,
//  `MeetingSummary.markdown`) — the model structures the notes freely instead
//  of filling a fixed schema, and the only post-processing is
//  `sanitizedMarkdown` (trim + unwrap one outer code fence).
//  - Short transcripts take the single-pass path: one markdown generation over
//    the whole transcript.
//  - Long transcripts route through NDJSON map-reduce (SPEC-05): each SPEC-02
//    chunk is mapped to structured facts (validated by NDJSONLineValidator,
//    evidence checked against real segment IDs) plus a detailed chunk note,
//    the facts merged deterministically in Swift (SummaryMerge), and a final
//    markdown reduce writes the same kind of adaptive document, grounded in
//    the part notes + merged facts. Memory stays bounded — one generation is
//    ever in flight and the full transcript is never one prompt.
//
//  Grounding on the long route stays executable, not just prompted (SPEC-05
//  §3): every evidence ID is filtered against the real segment IDs in scope,
//  and an item left with no valid evidence is dropped and logged. The markdown
//  documents are grounded by prompt (and by the product rule that summaries
//  never invent owners, dates, decisions, or risks).
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

    /// Streams progressively-more-complete summaries as the model writes.
    /// Each element is a snapshot of everything produced so far (facts during
    /// the long route's maps, then the growing markdown document); the final
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
        // Snapshots grow as each chunk's facts are merged in; markdown stays ""
        // until the reduce — the UI's `resolvedMarkdown` shim renders the
        // growing facts in the meantime, by design.
        var mapResults: [ChunkMapResult] = []
        for chunk in chunks {
            try Task.checkCancellation()
            progress?("Summarizing part \(chunk.index + 1)/\(chunks.count)…")
            let result = try await mapChunk(chunk, engine: engine)
            mapResults.append(result)
            let merged = mergeMapResults(mapResults)
            continuation.yield(Self.snapshot(facts: merged))
        }

        // Reduce (markdown): one adaptive document over the merged facts +
        // part notes. Snapshots carry the merged facts alongside the growing
        // document so the final summary keeps both — the store's summary.md
        // mirror reads the markdown, fact consumers read the sections.
        try Task.checkCancellation()
        progress?("Writing summary…")
        let merged = mergeMapResults(mapResults)
        do {
            _ = try await generateMarkdown(
                system: Self.reduceSystemPrompt,
                user: Self.reduceUserPrompt(facts: merged, notes: mapResults.sorted { $0.chunkIndex < $1.chunkIndex }),
                engine: engine,
                seed: merged,
                onSnapshot: { continuation.yield($0) }
            )
        } catch SummarizationError.emptyModelResponse {
            // Both reduce attempts came back empty. The maps already earned
            // their grounded facts, and grounded content beats an error (the
            // long route's standing principle) — finish with the facts-only
            // summary rather than throwing the whole meeting away.
            Self.log.warning("Markdown reduce empty after retry; keeping the facts-only summary")
            continuation.yield(Self.snapshot(facts: merged))
        }
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
            allowed: [.facts, .chunkNote], validEvidenceIDs: validIDs)
        try await consume(
            system: Self.mapSystemPrompt,
            user: Self.mapUserPrompt(for: chunk),
            engine: engine,
            into: &accumulator
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

    /// The final grounded markdown pass over already-merged facts: the same
    /// adaptive document the single-pass route writes, grounded in the part
    /// notes + merged facts instead of the transcript. Accepts precomputed
    /// results so SPEC-07 can drive it from its live cache.
    func reduceMarkdown(
        facts: MergedFacts,
        notes: [ChunkMapResult],
        engine: any TextGenerating
    ) async throws -> String {
        let summary = try await generateMarkdown(
            system: Self.reduceSystemPrompt,
            user: Self.reduceUserPrompt(facts: facts, notes: notes.sorted { $0.chunkIndex < $1.chunkIndex }),
            engine: engine,
            seed: facts,
            onSnapshot: { _ in }
        )
        return summary.markdown
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
        // legacy route wrote one, else the adaptive markdown document — stripped
        // of its markup and capped by `captionSource`, so the caption model
        // reads the opening as prose — else the detailed prose.
        let source: String
        if !summary.shortSummary.isEmpty {
            source = summary.shortSummary
        } else if !summary.markdown.isEmpty {
            source = Self.captionSource(from: summary.markdown)
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

    /// The head of a markdown document, stripped to prose for the caption
    /// generation. The caption model reads the opening of the notes; fed raw
    /// markdown it parrots the markup ("### Action Items - [ ] ..."), so this
    /// removes heading markers, checkbox/bullet prefixes, and emphasis/code
    /// delimiters, and drops the lines that carry no prose at all (table rows,
    /// horizontal rules). Stripping happens BEFORE the ~1200-char cap so the
    /// budget buys prose, not asterisks. Internal (not private) so the
    /// stripping rules are table-tested.
    static func captionSource(from markdown: String) -> String {
        let lines = markdown.components(separatedBy: "\n").compactMap { rawLine -> String? in
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { return nil }

            // Table rows (including separator rows) and horizontal rules carry
            // no prose — drop the whole line.
            if line.hasPrefix("|") { return nil }
            if line.count >= 3, line.allSatisfy({ $0 == "-" || $0 == "*" || $0 == "_" }) { return nil }

            // Heading markers, then the checkbox prefix (it embeds a bullet,
            // so it goes first), then plain bullet prefixes.
            while line.hasPrefix("#") { line.removeFirst() }
            line = line.trimmingCharacters(in: .whitespaces)
            for prefix in ["- [ ] ", "- [x] ", "- [X] "] where line.hasPrefix(prefix) {
                line.removeFirst(prefix.count)
            }
            for prefix in ["- ", "* ", "+ "] where line.hasPrefix(prefix) {
                line.removeFirst(prefix.count)
            }

            // Inline delimiters: bold before italic so "**" never survives as
            // two orphaned "*" strips.
            line = line.replacingOccurrences(of: "**", with: "")
            line = line.replacingOccurrences(of: "*", with: "")
            line = line.replacingOccurrences(of: "`", with: "")

            line = line.trimmingCharacters(in: .whitespaces)
            return line.isEmpty ? nil : line
        }
        return String(lines.joined(separator: "\n").prefix(1200))
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

    /// One markdown-document generation: up to two attempts; success is a
    /// sanitized document that is non-empty after trimming. The accumulated
    /// raw text is re-sanitized on every delta and a snapshot streams whenever
    /// the visible document changed — so the UI fills in as the model writes,
    /// and a wrapping code fence disappears the moment its closing line lands.
    /// `seed` (the long route) puts the merged facts into every snapshot, so
    /// the document and the facts travel together into the final summary.
    /// Throws `emptyModelResponse` if both attempts stay empty.
    private func generateMarkdown(
        system: String,
        user: String,
        engine: any TextGenerating,
        seed: MergedFacts? = nil,
        onSnapshot: @escaping (MeetingSummary) -> Void
    ) async throws -> MeetingSummary {
        for attempt in 0..<2 {
            var accumulated = ""
            var visible = ""
            do {
                // The markdown preset, not the NDJSON default: zeroed
                // frequency/presence penalties (checkbox prefixes and entity
                // names repeat legitimately here) and room for a dense document.
                for try await delta in engine.stream(system: system, user: user, params: .markdownSummary) {
                    try Task.checkCancellation()
                    guard !delta.isEmpty else { continue }
                    accumulated += delta
                    let sanitized = Self.sanitizedMarkdown(accumulated)
                    if sanitized != visible {
                        visible = sanitized
                        onSnapshot(Self.markdownSnapshot(sanitized, facts: seed))
                    }
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw SummarizationError.modelUnavailable(error.localizedDescription)
            }

            let document = Self.sanitizedMarkdown(accumulated)
            if !document.isEmpty {
                let snapshot = Self.markdownSnapshot(document, facts: seed)
                onSnapshot(snapshot)
                return snapshot
            }
            if attempt == 0 {
                Self.log.warning("Markdown generation produced an empty document; retrying once")
            }
        }
        throw SummarizationError.emptyModelResponse
    }

    /// Stream one NDJSON generation (the map phase): split the engine's deltas
    /// into lines and validate + apply each into `accumulator`. A single
    /// attempt — retry/routing is the caller's job.
    private func consume(
        system: String,
        user: String,
        engine: any TextGenerating,
        into accumulator: inout SummaryAccumulator
    ) async throws {
        var buffer = ""
        do {
            for try await delta in engine.stream(system: system, user: user, params: GenerationParams()) {
                try Task.checkCancellation()
                guard !delta.isEmpty else { continue }

                buffer += delta
                while let newline = buffer.firstIndex(of: "\n") {
                    let line = String(buffer[buffer.startIndex..<newline])
                    buffer.removeSubrange(buffer.startIndex...newline)
                    _ = accumulator.applyValidatedLine(line)
                }
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

    /// A facts-only snapshot (mid-map progress, and the degraded final when
    /// the reduce comes back empty): markdown stays "" so the UI's
    /// `resolvedMarkdown` shim renders the growing facts as a fixed-schema
    /// document until the reduce writes the real one.
    private static func snapshot(facts: MergedFacts) -> MeetingSummary {
        MeetingSummary(
            shortSummary: "",
            detailedSummary: "",
            decisions: facts.decisions,
            actionItems: facts.actionItems,
            openQuestions: facts.openQuestions,
            risks: facts.risks
        )
    }

    /// A markdown snapshot: the document is the summary. The legacy prose
    /// fields stay empty on both routes; the long route also carries its
    /// merged `facts` so the document and the sections that ground it land in
    /// the final `MeetingSummary` together (nil on the single-pass route,
    /// which extracts no facts).
    private static func markdownSnapshot(_ markdown: String, facts: MergedFacts?) -> MeetingSummary {
        MeetingSummary(
            markdown: markdown,
            shortSummary: "",
            detailedSummary: "",
            decisions: facts?.decisions ?? [],
            actionItems: facts?.actionItems ?? [],
            openQuestions: facts?.openQuestions ?? [],
            risks: facts?.risks ?? []
        )
    }

    // MARK: - Prompts: the adaptive document (Notion ruleset, shared blocks)

    /// The route-independent half of the adaptive ruleset (distilled from five
    /// real Notion AI meeting summaries, the product owner's calibration
    /// target): adaptivity, content specificity, hedging, formatting,
    /// language, and speaker naming. Shared VERBATIM by the single-pass prompt
    /// and the map-reduce reduce prompt — one constant, so the two routes'
    /// documents can never drift apart in these rules. Wording is short and
    /// imperative on purpose: a small model follows rules it can quote, not
    /// meta-discussion.
    private static let adaptiveSharedRules = """
    Adapt the amount to the meeting:
    - The number of sections and bullets follows the meeting's information
      density. A short or thin meeting gets short notes; a dense meeting gets
      many sections. Never pad. Never compress distinct topics into one line.

    Content:
    - Preserve specifics exactly as discussed: numbers, quantities, thresholds,
      versions, model and product names, amounts of money, and root-cause chains
      (symptom, cause, fix). These details are the value of the notes.
    - Omit social small talk entirely — personal stories, trips, jokes:
      no section, no mention, however long it took. An outside event earns a
      brief contextual section only when it changed the work — a plan, a
      decision, or a deadline.
    - The transcript is machine-transcribed and may be garbled. When a passage
      is unclear, hedge ("likely", "apparently", "unclear whether...") instead
      of inventing details or silently dropping the topic.

    Formatting:
    - Bullets are full, informative sentences.
    - Bold key terms sparingly, with **bold**.
    - Nest sub-bullets only for real hierarchy.
    - Use a table only when the content is truly tabular (a comparison, an
      option matrix).
    - "---" is allowed as a divider after a long Action Items list.

    Language: write the notes in the dominant language of the transcript.

    Speakers: "You" is the current user (microphone); "Team" are the other
    participants (system audio). Use real names when the transcript makes them
    clear; otherwise keep "You" and "the team".
    """

    /// The single-pass prompt: role + output contract first, document shape
    /// next (both anchored to the transcript), then the shared blocks above.
    /// Load-bearing phrases ("### Action Items",
    /// "never invent an owner or a due date", "dominant language of the
    /// transcript", "no code fences", "never write an empty section") are
    /// pinned by SummarizationPipelineStreamTests (and again on the reduce
    /// prompt by SummaryMapReduceTests) — reword freely around them, keep the
    /// invariants. S8 added three more pins for the measured quality gaps:
    /// "sweep the whole transcript for commitments" and "naming someone who
    /// did not take the task is an error" (single-pass only), and
    /// "no section, no mention" (shared rules, pinned on both routes).
    private static let markdownSystemPrompt = """
    You are an expert meeting note-taker. Write the notes a colleague who missed
    the meeting would need. Output ONE Markdown document and nothing else — no
    preamble, no closing remarks, no code fences.

    Document shape:
    - Sweep the WHOLE transcript for commitments first — a commitment made in
      passing, mid-topic, still counts. If any were made, START the document
      with a "### Action Items" section: a checkbox list with one
      "- [ ] Name to <verb> ..." item per commitment actually made in the
      transcript; a commitment discussed inside a topic gets BOTH its checkbox
      here and its topic coverage. Name an owner ONLY when that person took
      the task — said they would do it, or accepted it when asked. Whoever
      merely mentioned or requested a task is NOT its owner: write that item
      with no name, like "- [ ] Fix the login bug" —
      naming someone who did not take the task is an error.
      NEVER invent an owner or a due date; include a due date only when
      someone said it. If no commitments were made, do not write an Action
      Items section.
    - After that, write one "###" section per distinct work topic actually
      discussed. Make every title SPECIFIC to the content, like "Audio Bug:
      Wireless Headphone Frequency Issue" — never a generic bucket like
      "Discussion", "Updates", or "Miscellaneous". Use a generic category
      section only when the meeting earns it: "Key Decisions" only if explicit
      decisions were made; a context section only if outside events shaped the
      meeting. NEVER write an empty section, a "(none)" placeholder, or a
      section for a category with nothing in it.

    \(adaptiveSharedRules)
    """

    private static func markdownUserPrompt(for segments: [TranscriptSegment]) -> String {
        // Deliberately thin: the ruleset lives in the system prompt, and the
        // transcript line format explains itself — one legend line is enough.
        """
        Write the meeting notes for this transcript.

        Each transcript line is "[start-end] Speaker: text".

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
    {"type":"chunknote","text":"a detailed 4-8 sentence note on this part"}
    {"type":"decision","title":"...","details":"...","evidence":["segment-id"]}
    {"type":"action","task":"...","owner":"... or null","due":"... or null","evidence":["segment-id"]}
    {"type":"question","question":"...","context":"... or null","evidence":["segment-id"]}
    {"type":"risk","risk":"...","details":"... or null","evidence":["segment-id"]}

    Rules:
    - Emit exactly one "chunknote" line first. Write a detailed note of 4-8 sentences
      in the dominant language of the transcript: name the topics discussed in
      this part AND the concrete specifics mentioned — numbers, amounts, names,
      versions, thresholds, root causes. The final summary is written from
      these notes, so it can only be as specific as they are.
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

    // MARK: - Prompts: markdown reduce phase

    /// The reduce prompt: the SAME adaptive document as the single-pass route
    /// (the shared blocks are interpolated verbatim), but grounded in the map
    /// phase's material instead of a transcript — per-part notes
    /// (chronological, time-ranged) plus the merged, de-duplicated facts. The
    /// action items in that material are the only candidates for the checkbox
    /// list, and the no-new-items rule ("Do NOT introduce any decision,
    /// action, owner, due date, question, or risk") is pinned by
    /// SummaryMapReduceTests alongside the five shared ruleset phrases.
    private static let reduceSystemPrompt = """
    You are an expert meeting note-taker. The meeting was too long for one
    pass, so it was processed in parts: the user gives you each part's note in
    chronological order with its time range, plus the merged, de-duplicated
    facts extracted from the whole meeting. Write the notes a colleague who
    missed the meeting would need, grounded ONLY in that material.
    Do NOT introduce any decision, action, owner, due date, question, or risk
    that is not present in the material provided. Do not invent details.
    Output ONE Markdown document and nothing else — no preamble, no closing
    remarks, no code fences.

    Document shape:
    - If the material lists action items, START the document with a
      "### Action Items" section: a checkbox list with one
      "- [ ] Name to <verb> ..." item per action item in the material — those
      are the only candidates. If an action item has no owner, write the item
      without a name. NEVER invent an owner or a due date; include a due date
      only when the material carries one. If the material lists no action
      items, do not write an Action Items section.
    - After that, write one "###" section per distinct work topic in the part
      notes. Make every title SPECIFIC to the content, like "Audio Bug:
      Wireless Headphone Frequency Issue" — never a generic bucket like
      "Discussion", "Updates", or "Miscellaneous". Use a generic category
      section only when the meeting earns it: "Key Decisions" only if the
      material lists decisions; a context section only if outside events
      shaped the meeting. NEVER write an empty section, a "(none)" placeholder,
      or a section for a category with nothing in it.
    - Cover the whole meeting, using the ordered part notes for the arc.

    \(adaptiveSharedRules)
    """

    /// The reduce's material: part notes first (chronological, time-ranged —
    /// the meeting's arc), then ONLY the fact sections that have content.
    /// Empty sections are omitted entirely — a "(none)" line here would tempt
    /// the model into writing an empty section in the document, exactly what
    /// the ruleset forbids. Owner/due decorate an action item only when the
    /// merge actually carries them (never "unspecified" filler, which reads
    /// like material to preserve).
    private static func reduceUserPrompt(facts: MergedFacts, notes: [ChunkMapResult]) -> String {
        var lines: [String] = [
            "Write the meeting notes from this material. Use ONLY the material",
            "below and add nothing new.",
        ]

        let partNotes = notes.compactMap { note -> String? in
            let gist = note.chunkNote.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !gist.isEmpty else { return nil }
            return "[\(timestamp(note.start))-\(timestamp(note.end))] \(gist)"
        }
        if !partNotes.isEmpty {
            lines.append("")
            lines.append("Part notes (in chronological order):")
            lines.append(contentsOf: partNotes)
        }

        if !facts.decisions.isEmpty {
            lines.append("")
            lines.append("Decisions:")
            lines.append(contentsOf: facts.decisions.map { decision in
                let details = decision.details.trimmingCharacters(in: .whitespacesAndNewlines)
                return details.isEmpty ? "- \(decision.title)" : "- \(decision.title): \(details)"
            })
        }

        if !facts.actionItems.isEmpty {
            lines.append("")
            lines.append("Action items:")
            lines.append(contentsOf: facts.actionItems.map { action in
                var decorations: [String] = []
                if let owner = action.owner { decorations.append("owner: \(owner)") }
                if let due = action.dueDate { decorations.append("due: \(due)") }
                return decorations.isEmpty
                    ? "- \(action.task)"
                    : "- \(action.task) (\(decorations.joined(separator: ", ")))"
            })
        }

        if !facts.openQuestions.isEmpty {
            lines.append("")
            lines.append("Open questions:")
            lines.append(contentsOf: facts.openQuestions.map { "- \($0.question)" })
        }

        if !facts.risks.isEmpty {
            lines.append("")
            lines.append("Risks:")
            lines.append(contentsOf: facts.risks.map { "- \($0.risk)" })
        }

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
    /// well-formedness; this gates *which* well-formed shapes a phase accepts,
    /// so a stray line of another type (say, a leftover "short" from the
    /// retired prose protocol) is silently ignored rather than corrupting the
    /// phase output.
    private struct AllowedShapes: OptionSet {
        let rawValue: Int
        static let facts = AllowedShapes(rawValue: 1 << 0)      // decision/action/question/risk
        static let chunkNote = AllowedShapes(rawValue: 1 << 1)  // chunknote
    }

    // MARK: - NDJSON accumulator

    /// Builds a `MeetingSummary` incrementally from streamed NDJSON lines, gating
    /// each line by the phase's allowed shapes and filtering evidence against the
    /// real segment IDs in scope (executable grounding, SPEC-05 §3).
    private struct SummaryAccumulator {
        private let allowed: AllowedShapes
        /// Lowercased segment IDs a cited evidence ID must match to survive.
        private let validEvidenceIDs: Set<String>

        private var decisions: [SummaryDecision] = []
        private var actionItems: [SummaryActionItem] = []
        private var openQuestions: [SummaryOpenQuestion] = []
        private var risks: [SummaryRisk] = []
        /// The map phase's chunk gist ("" until the model emits it).
        private(set) var chunkNote = ""

        /// Normalized "type + primary text" keys already added, so the common
        /// small-model loop of repeating the same item is collapsed to one.
        private var seenKeys: Set<String> = []

        init(allowed: AllowedShapes, validEvidenceIDs: Set<String>) {
            self.allowed = allowed
            self.validEvidenceIDs = validEvidenceIDs
        }

        var snapshot: MeetingSummary {
            MeetingSummary(
                shortSummary: "",
                detailedSummary: "",
                decisions: decisions,
                actionItems: actionItems,
                openQuestions: openQuestions,
                risks: risks
            )
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
