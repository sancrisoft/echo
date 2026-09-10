//
//  Summarizer.swift
//  Summarization
//
//  Turns final transcript segments into a grounded Markdown document. The model
//  runs in-process behind the `TextGenerating` seam and streams, so a document
//  fills in as it is written.
//
//  Two routes, one output shape:
//
//  - At or below the single-pass budget, one generation over the whole
//    transcript. Grounding is the prompt plus the fact that the transcript is in
//    the same context.
//  - Above it, the transcript cannot be one prompt, so each chunk is mapped to
//    NDJSON facts (validated, evidence filtered against real segment ids) plus a
//    detailed part note, the facts are merged deterministically in Swift, and a
//    final reduce writes the same kind of document from the notes and the merged
//    facts. Memory stays bounded: one generation is ever in flight and the whole
//    transcript is never one prompt.
//
//  On the long route grounding is EXECUTABLE, not just prompted: every cited
//  evidence id is filtered against the real segment ids in scope, and an item
//  left with nothing real is dropped. On the short route it is prompted, plus
//  the product rule that a summary never invents an owner, a date, a decision or
//  a risk.
//
//  Nothing here logs transcript text, prompt text, completion text or fact text.
//  The sites that could — a malformed NDJSON line, a dropped fact — log a length
//  and a type instead. That is not discipline, it is the only shape available:
//  v1's equivalents interpolated 200 characters of model output at
//  `privacy: .public`.
//

import EchoCore
import Foundation
import os

public actor Summarizer {

    static let log = Logger(subsystem: AppIdentity.logSubsystem, category: "Summarizer")

    /// At or below this transcript-token estimate the summary stays single-pass;
    /// above it, it maps and reduces.
    ///
    /// Chosen to match chunking's `hardMaxTokens` (8 000): a transcript this
    /// small is a single chunk anyway, so a single pass adds no risk, while
    /// larger ones lose extraction quality in an over-full context ("lost in the
    /// middle"). On the 4B an 8K-token KV cache is comfortable headroom rather
    /// than the memory ceiling it was on the retired 12B — the budget stands on
    /// quality grounds alone, and retuning it needs a measurement.
    public static let singlePassBudget = 8_000

    /// The model behind the engine, as a person would read it. Carried into
    /// every document this summarizer produces so a caller can record what wrote
    /// a summary without asking a second object.
    let modelName: String

    public init(modelName: String) {
        self.modelName = modelName
    }

    // MARK: - Generate

    /// Streams progressively more complete documents as the model writes.
    ///
    /// Every element but the last is a draft — real Markdown, unfinished. The
    /// last carries `isFinal`, and it is the only one a caller may persist. A
    /// generation that is cancelled or that fails emits no final document at
    /// all: the stream throws, and there is nothing to mistake for a result.
    ///
    /// The engine is injected per call so a test can drive the whole streaming
    /// path with a fake. Cancelling is terminating the stream — the pipeline
    /// offers no other stop, and the engine's contract is to cancel the
    /// generation when its own stream is terminated.
    public func generate(
        from segments: [TranscriptSegment],
        using engine: any TextGenerating,
        onProgress: (@Sendable (SummaryPhase) -> Void)? = nil
    ) -> AsyncThrowingStream<SummaryDocument, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await self.run(
                        from: segments, using: engine, onProgress: onProgress, into: continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// The transcript's dominant language as an English language name, or nil
    /// when there is no confident answer. Exposed because it is the one input to
    /// the prompts that is derived rather than given.
    public static func detectedLanguage(of segments: [TranscriptSegment]) -> String? {
        SummaryLanguage.dominantName(of: segments)
    }

    /// The routing estimate, through the same estimator chunking uses — so the
    /// route boundary and the chunk boundary can never disagree about what a
    /// transcript costs.
    public static func estimatedTokens(
        of segments: [TranscriptSegment],
        estimator: any TokenEstimating = HeuristicTokenEstimator()
    ) -> Int {
        segments.reduce(0) { $0 + estimator.estimate($1.text) }
    }

    // MARK: - Routing

    private func run(
        from segments: [TranscriptSegment],
        using engine: any TextGenerating,
        onProgress: (@Sendable (SummaryPhase) -> Void)?,
        into continuation: AsyncThrowingStream<SummaryDocument, Error>.Continuation
    ) async throws {
        // Before any engine call, so an empty transcript never loads a model.
        guard !segments.isEmpty else { throw SummarizationError.emptyTranscript }

        // Detected ONCE over the whole transcript; both routes thread the same
        // answer, and nil keeps the prompts' generic wording.
        let language = Self.detectedLanguage(of: segments)

        // Route on the transcript size alone, independent of prompt overhead, so
        // the boundary is stable and matches chunking.
        if Self.estimatedTokens(of: segments) <= Self.singlePassBudget {
            try await runSinglePass(
                from: segments, using: engine, language: language, into: continuation)
        } else {
            try await runMapReduce(
                from: segments, using: engine, language: language,
                onProgress: onProgress, into: continuation)
        }
    }

    // MARK: - Single-pass route

    private func runSinglePass(
        from segments: [TranscriptSegment],
        using engine: any TextGenerating,
        language: String?,
        into continuation: AsyncThrowingStream<SummaryDocument, Error>.Continuation
    ) async throws {
        let document = try await generateMarkdown(
            system: SummaryPrompts.markdownSystem,
            user: SummaryPrompts.markdownUser(for: segments, language: language),
            engine: engine,
            onDraft: { markdown in
                continuation.yield(
                    SummaryDocument(
                        markdown: markdown, language: language,
                        modelName: self.modelName, isFinal: false))
            }
        )
        continuation.yield(
            SummaryDocument(
                markdown: document, language: language, modelName: modelName, isFinal: true))
    }

    // MARK: - Map-reduce route

    private func runMapReduce(
        from segments: [TranscriptSegment],
        using engine: any TextGenerating,
        language: String?,
        onProgress: (@Sendable (SummaryPhase) -> Void)?,
        into continuation: AsyncThrowingStream<SummaryDocument, Error>.Continuation
    ) async throws {
        let chunks = TranscriptChunker.chunks(from: segments)
        guard !chunks.isEmpty else { throw SummarizationError.emptyTranscript }

        // Map: one generation per chunk, in series — one engine, bounded memory.
        // Drafts grow as each chunk's facts merge in; their Markdown is the
        // facts rendered deterministically, which is what a reader saw in v1
        // while the reduce had not written anything yet.
        var mapResults: [ChunkMapResult] = []
        for chunk in chunks {
            try Task.checkCancellation()
            onProgress?(.mapping(part: chunk.index + 1, of: chunks.count))
            mapResults.append(try await mapChunk(chunk, engine: engine, language: language))
            let merged = mergeMapResults(mapResults)
            continuation.yield(
                SummaryDocument(
                    markdown: merged.markdown, facts: merged, language: language,
                    modelName: modelName, isFinal: false))
        }

        try Task.checkCancellation()
        onProgress?(.reducing)
        let merged = mergeMapResults(mapResults)
        do {
            let document = try await generateMarkdown(
                system: SummaryPrompts.reduceSystem,
                user: SummaryPrompts.reduceUser(
                    facts: merged,
                    notes: mapResults.sorted { $0.chunkIndex < $1.chunkIndex },
                    language: language),
                engine: engine,
                onDraft: { markdown in
                    continuation.yield(
                        SummaryDocument(
                            markdown: markdown, facts: merged, language: language,
                            modelName: self.modelName, isFinal: false))
                }
            )
            continuation.yield(
                SummaryDocument(
                    markdown: document, facts: merged, language: language,
                    modelName: modelName, isFinal: true))
        } catch SummarizationError.emptyModelResponse {
            // Both reduce attempts came back empty. The maps already earned
            // their grounded facts, and grounded content beats an error — finish
            // with the facts-only summary rather than throwing the meeting away.
            //
            // Unless there are no facts either, in which case there is nothing
            // grounded to keep and the error is the honest answer. A final
            // document is never blank: a caller may persist it unconditionally.
            guard !merged.isEmpty else { throw SummarizationError.emptyModelResponse }
            Self.log.warning("Reduce came back empty twice; keeping the facts-only summary")
            continuation.yield(
                SummaryDocument(
                    markdown: merged.markdown, facts: merged, language: language,
                    modelName: modelName, isFinal: true))
        }
        onProgress?(.finished)
    }

    // MARK: - Map, merge, reduce

    /// Map one chunk to structured facts.
    ///
    /// Holds no state between calls, so a caller may drive this per chunk as
    /// chunks close and cache the results. Evidence is validated against this
    /// chunk's real segment ids, overlap included — a fact may legitimately span
    /// the overlap, and the prompt is what tells the model not to re-report one
    /// that lies entirely inside it.
    public func mapChunk(
        _ chunk: TranscriptChunk,
        engine: any TextGenerating,
        language: String? = nil
    ) async throws -> ChunkMapResult {
        let accumulator = try await consume(
            system: SummaryPrompts.mapSystem,
            user: SummaryPrompts.mapUser(for: chunk, language: language),
            engine: engine,
            allowed: [.facts, .chunkNote],
            validEvidenceIDs: Self.evidenceIDs(of: chunk.segments)
        )
        let facts = accumulator.facts
        return ChunkMapResult(
            chunkIndex: chunk.index,
            decisions: facts.decisions,
            actionItems: facts.actionItems,
            openQuestions: facts.openQuestions,
            risks: facts.risks,
            chunkNote: accumulator.chunkNote,
            start: chunk.start,
            end: chunk.end
        )
    }

    /// The deterministic, engine-free merge. `nonisolated` so a caller can
    /// reduce precomputed results without entering the actor.
    public nonisolated func mergeMapResults(_ results: [ChunkMapResult]) -> MergedFacts {
        SummaryMerge.merge(results)
    }

    /// The final grounded pass over already-merged facts — the same document the
    /// single-pass route writes, grounded in part notes and merged facts instead
    /// of a transcript. Takes precomputed results so a caller can drive it from
    /// its own cache.
    public func reduceMarkdown(
        facts: MergedFacts,
        notes: [ChunkMapResult],
        engine: any TextGenerating,
        language: String? = nil
    ) async throws -> String {
        try await generateMarkdown(
            system: SummaryPrompts.reduceSystem,
            user: SummaryPrompts.reduceUser(
                facts: facts,
                notes: notes.sorted { $0.chunkIndex < $1.chunkIndex },
                language: language),
            engine: engine,
            onDraft: { _ in }
        )
    }

    // MARK: - Row caption

    /// One plain-text sentence describing the meeting, for the library row.
    ///
    /// Generated from the finished document — already concise and already
    /// grounded — rather than from the raw transcript, and deliberately not part
    /// of `SummaryDocument`: it is a headline for a row, not a section of the
    /// notes. Best effort: any failure, or an empty reply, returns nil and the
    /// row simply shows no caption. Nothing is invented to fill it.
    public func caption(for document: SummaryDocument, using engine: any TextGenerating) async -> String? {
        let source = SummaryText.captionSource(from: document.markdown)
        guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }

        var text = ""
        do {
            for try await delta in engine.stream(
                system: SummaryPrompts.captionSystem,
                user: SummaryPrompts.captionUser(source),
                params: .caption
            ) {
                try Task.checkCancellation()
                text += delta
                // One sentence never needs more, and a model that loops here
                // would otherwise spend its whole 64-token budget.
                if text.count > 400 { break }
            }
        } catch {
            // A caption is a subordinate side effect: it disables itself, traces
            // and lets the summary stand (architecture §7, tier 1).
            ErrorTrace.record("Summary caption generation failed", error: error, category: "Summarizer")
            return nil
        }
        return SummaryText.cleanCaption(text)
    }

    // MARK: - Generation primitives

    /// One Markdown generation: up to two attempts, where success is a sanitized
    /// document that is non-empty after trimming.
    ///
    /// The accumulated raw text is re-sanitized on every delta and a draft is
    /// reported whenever the visible document CHANGED — so a reader watches the
    /// notes fill in, and a wrapping code fence disappears the moment its closing
    /// line lands. Returns the finished Markdown; the caller decides what a final
    /// document looks like, which is why no draft is ever reported twice.
    ///
    /// Throws `emptyModelResponse` when both attempts stay empty.
    private func generateMarkdown(
        system: String,
        user: String,
        engine: any TextGenerating,
        onDraft: (String) -> Void
    ) async throws -> String {
        for attempt in 0..<2 {
            var accumulated = ""
            var visible = ""
            do {
                for try await delta in engine.stream(
                    system: system, user: user, params: .markdownSummary)
                {
                    try Task.checkCancellation()
                    guard !delta.isEmpty else { continue }
                    accumulated += delta
                    let sanitized = SummaryText.sanitizedMarkdown(accumulated)
                    if sanitized != visible {
                        visible = sanitized
                        onDraft(sanitized)
                    }
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw SummarizationError.modelUnavailable(error.localizedDescription)
            }

            // A cancelled stream ENDS, it does not throw: AsyncThrowingStream
            // terminates and its iterator returns nil, so the loop above exits
            // normally and `accumulated` looks like a document the model
            // finished. Without this check a cancelled generation returns a
            // truncated summary with no error — measured, not theorized.
            try Task.checkCancellation()

            let document = SummaryText.sanitizedMarkdown(accumulated)
            if !document.isEmpty { return document }
            if attempt == 0 {
                Self.log.warning("Markdown generation produced an empty document; retrying once")
            }
        }
        throw SummarizationError.emptyModelResponse
    }

    /// Stream one NDJSON generation and accumulate it.
    ///
    /// A single attempt — retrying is the caller's business, and no caller
    /// retries a map: a chunk that yields nothing costs its facts, not the
    /// meeting. Lines are split manually because the engine yields raw deltas
    /// that respect no line boundary.
    ///
    /// Returns the accumulator rather than taking it `inout`: exclusive access
    /// held across a suspension point is legal but fragile, and there is nothing
    /// to gain from it here.
    private func consume(
        system: String,
        user: String,
        engine: any TextGenerating,
        allowed: AllowedShapes,
        validEvidenceIDs: Set<String>
    ) async throws -> SummaryAccumulator {
        var accumulator = SummaryAccumulator(allowed: allowed, validEvidenceIDs: validEvidenceIDs)
        var buffer = ""
        do {
            for try await delta in engine.stream(system: system, user: user, params: GenerationParams()) {
                try Task.checkCancellation()
                guard !delta.isEmpty else { continue }

                buffer += delta
                while let newline = buffer.firstIndex(of: "\n") {
                    let line = String(buffer[buffer.startIndex..<newline])
                    buffer.removeSubrange(buffer.startIndex...newline)
                    accumulator.applyValidatedLine(line)
                }
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw SummarizationError.modelUnavailable(error.localizedDescription)
        }

        // Same reason as in `generateMarkdown`: a cancelled stream ends rather
        // than throwing, so without this a cancelled map returns the facts it
        // happened to have parsed as if the part were fully extracted.
        try Task.checkCancellation()

        // Every entry is newline-terminated by protocol, but flush a trailing
        // object in case the stream ends without one.
        let tail = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty { accumulator.applyValidatedLine(tail) }
        return accumulator
    }

    /// The lowercased segment ids a generation may cite as evidence.
    static func evidenceIDs(of segments: [TranscriptSegment]) -> Set<String> {
        Set(segments.map { $0.id.uuidString.lowercased() })
    }
}

// MARK: - Allowed shapes per phase

/// Which NDJSON line types a generation may contribute.
///
/// The validator gates well-formedness; this gates WHICH well-formed shapes a
/// phase accepts, so a stray line of another type — a leftover `short` from the
/// retired prose protocol — is ignored rather than corrupting the output.
struct AllowedShapes: OptionSet {
    let rawValue: Int
    /// decision / action / question / risk
    static let facts = AllowedShapes(rawValue: 1 << 0)
    static let chunkNote = AllowedShapes(rawValue: 1 << 1)
}

// MARK: - NDJSON accumulator

/// Builds facts incrementally from streamed NDJSON lines, gating each line by
/// the phase's allowed shapes and filtering its evidence against the real
/// segment ids in scope. Executable grounding lives here.
struct SummaryAccumulator {

    private let allowed: AllowedShapes
    /// Lowercased segment ids a cited evidence id must match to survive.
    private let validEvidenceIDs: Set<String>

    private var decisions: [SummaryDecision] = []
    private var actionItems: [SummaryActionItem] = []
    private var openQuestions: [SummaryOpenQuestion] = []
    private var risks: [SummaryRisk] = []

    /// The map phase's part note ("" until the model emits one).
    private(set) var chunkNote = ""

    /// Normalized "type + primary text" keys already added, so the common
    /// small-model loop of repeating an item collapses to one.
    private var seenKeys: Set<String> = []

    init(allowed: AllowedShapes, validEvidenceIDs: Set<String>) {
        self.allowed = allowed
        self.validEvidenceIDs = validEvidenceIDs
    }

    var facts: MergedFacts {
        MergedFacts(
            decisions: decisions,
            actionItems: actionItems,
            openQuestions: openQuestions,
            risks: risks
        )
    }

    /// Gate and apply one COMPLETED NDJSON line. Invalid lines are dropped and
    /// counted, never shown.
    @discardableResult
    mutating func applyValidatedLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        guard NDJSONLineValidator.isValid(trimmed) else {
            // A length, never the line. v1 logged 200 characters of raw model
            // output here at `privacy: .public`, and a malformed line is very
            // often verbatim transcript-derived prose.
            Summarizer.log.warning(
                "Dropping a malformed NDJSON line (\(trimmed.count, privacy: .public) chars)")
            return false
        }
        return applyLine(trimmed)
    }

    /// Apply one complete, well-formed line. True when it changed the facts.
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
            let text = Self.string("text", in: object)
            guard !text.isEmpty else { return false }
            // Last write wins: a second note replaces the first rather than
            // concatenating two accounts of the same part.
            chunkNote = text
            return true
        case "decision":
            guard allowed.contains(.facts) else { return false }
            let title = Self.string("title", in: object)
            guard !title.isEmpty else { return false }
            guard let evidence = groundedEvidence(type, in: object) else { return false }
            guard accept("decision", title, count: decisions.count) else { return false }
            decisions.append(
                SummaryDecision(
                    title: title,
                    details: Self.string("details", in: object),
                    evidenceSegmentIDs: evidence
                ))
            return true
        case "action":
            guard allowed.contains(.facts) else { return false }
            let task = Self.string("task", in: object)
            guard !task.isEmpty else { return false }
            guard let evidence = groundedEvidence(type, in: object) else { return false }
            guard accept("action", task, count: actionItems.count) else { return false }
            actionItems.append(
                SummaryActionItem(
                    task: task,
                    owner: Self.optionalString("owner", in: object),
                    dueDate: Self.optionalString("due", in: object),
                    evidenceSegmentIDs: evidence
                ))
            return true
        case "question":
            guard allowed.contains(.facts) else { return false }
            let question = Self.string("question", in: object)
            guard !question.isEmpty else { return false }
            guard let evidence = groundedEvidence(type, in: object) else { return false }
            guard accept("question", question, count: openQuestions.count) else { return false }
            openQuestions.append(
                SummaryOpenQuestion(
                    question: question,
                    context: Self.optionalString("context", in: object),
                    evidenceSegmentIDs: evidence
                ))
            return true
        case "risk":
            guard allowed.contains(.facts) else { return false }
            let risk = Self.string("risk", in: object)
            guard !risk.isEmpty else { return false }
            guard let evidence = groundedEvidence(type, in: object) else { return false }
            guard accept("risk", risk, count: risks.count) else { return false }
            risks.append(
                SummaryRisk(
                    risk: risk,
                    details: Self.optionalString("details", in: object),
                    evidenceSegmentIDs: evidence
                ))
            return true
        default:
            return false
        }
    }

    /// Filter a line's evidence down to the real segment ids in scope. Nil —
    /// drop the item — when nothing survives.
    ///
    /// "Real" is an exact, case-insensitive match against a segment id of the
    /// chunk. No prefixes, no fuzzy matching: an id the model invented or
    /// mangled is not evidence.
    private func groundedEvidence(_ type: String, in object: [String: Any]) -> [String]? {
        let cited = Self.stringArray("evidence", in: object)
        let real = cited.filter { validEvidenceIDs.contains($0.lowercased()) }
        guard !real.isEmpty else {
            Summarizer.log.warning(
                "Dropping a \(type, privacy: .public) with no valid evidence after filtering")
            return nil
        }
        return real
    }

    /// Gate a list item: reject it when the section is full, or when an item
    /// with the same normalized primary text was already added.
    private mutating func accept(_ type: String, _ primaryText: String, count: Int) -> Bool {
        guard count < SummaryLimits.maxItemsPerSection else { return false }
        return seenKeys.insert(SummaryDedup.key(type, primaryText)).inserted
    }

    // MARK: Field helpers

    private static func string(_ key: String, in object: [String: Any]) -> String {
        optionalString(key, in: object) ?? ""
    }

    private static func optionalString(_ key: String, in object: [String: Any]) -> String? {
        guard let value = object[key], !(value is NSNull) else { return nil }
        let string = value as? String ?? "\(value)"
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        // The protocol allows a real null or a quoted string, and a small model
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
}
