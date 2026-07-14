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

import Foundation
import os

actor SummarizationPipeline {

    static let log = Logger(subsystem: "com.sancrisoft.Echo", category: "SummarizationPipeline")

    /// Single-pass context parity with the retired server runtime (ctx 32768):
    /// past this estimate we log and continue — Gemma 4 holds 256K, and real
    /// scaling (chunking/map-reduce) is SPEC-05.
    private static let promptTokenBudget = 28_000

    /// Streams progressively-more-complete summaries as the model emits NDJSON
    /// lines. Each element is a snapshot of everything parsed so far; the final
    /// element is the complete summary. Throws on engine/protocol failures.
    /// The engine is injected per call so tests can drive the full streaming
    /// path with a scripted TextGenerating fake.
    func generate(
        from segments: [TranscriptSegment],
        using engine: any TextGenerating
    ) -> AsyncThrowingStream<MeetingSummary, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await self.run(from: segments, using: engine, into: continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func run(
        from segments: [TranscriptSegment],
        using engine: any TextGenerating,
        into continuation: AsyncThrowingStream<MeetingSummary, Error>.Continuation
    ) async throws {
        guard !segments.isEmpty else { throw SummarizationError.emptyTranscript }

        let system = Self.systemPrompt
        let user = Self.userPrompt(for: segments)

        let estimatedTokens = (system.count + user.count) / 4
        if estimatedTokens > Self.promptTokenBudget {
            Self.log.warning("""
            Prompt estimate \(estimatedTokens, privacy: .public) tokens exceeds the \
            \(Self.promptTokenBudget, privacy: .public) single-pass budget; continuing \
            (chunking arrives with SPEC-05)
            """)
        }

        // One full-generation retry: with constrained decoding gone, a stream
        // that ends without a single valid short/detailed line is a failed
        // generation, not a summary.
        for attempt in 0..<2 {
            var accumulator = SummaryAccumulator()
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
                        if Self.applyValidated(line, to: &accumulator) { changed = true }
                    }
                    // Preview the in-progress prose line (short/detailed) char-by-char.
                    if accumulator.applyPartialProse(buffer) { changed = true }

                    if changed { continuation.yield(accumulator.snapshot) }
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw SummarizationError.modelUnavailable(error.localizedDescription)
            }

            // Every entry is newline-terminated by protocol, but flush a
            // trailing object in case the stream ends without one.
            let tail = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
            if !tail.isEmpty { _ = Self.applyValidated(tail, to: &accumulator) }

            let snapshot = accumulator.snapshot
            if !snapshot.shortSummary.isEmpty || !snapshot.detailedSummary.isEmpty {
                continuation.yield(snapshot)
                return
            }
            if attempt == 0 {
                Self.log.warning("Generation produced no valid short/detailed line; retrying once")
            } else if accumulator.hasContent {
                // Items without prose after the retry: unusual, but grounded
                // content beats an error.
                continuation.yield(snapshot)
                return
            }
        }

        throw SummarizationError.emptyModelResponse
    }

    /// Gate + apply one completed NDJSON line. Invalid lines are dropped and
    /// logged, never shown — the UI-observable behavior matches the old
    /// grammar-constrained runtime.
    private static func applyValidated(_ line: String, to accumulator: inout SummaryAccumulator) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        guard NDJSONLineValidator.isValid(trimmed) else {
            log.warning("Dropping malformed NDJSON line: \(String(trimmed.prefix(200)), privacy: .public)")
            return false
        }
        return accumulator.applyLine(trimmed)
    }

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

    /// Normalize text for duplicate detection: lowercased, punctuation flattened
    /// to spaces, whitespace collapsed. So "…English?" and "…English" collide.
    private static func dedupKey(_ text: String) -> String {
        let flattened = text.lowercased().unicodeScalars.map { scalar in
            CharacterSet.alphanumerics.contains(scalar) ? Character(scalar) : " "
        }
        return String(flattened)
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
    }

    // MARK: - NDJSON accumulator

    /// Builds a `MeetingSummary` incrementally from streamed NDJSON lines.
    private struct SummaryAccumulator {
        /// Safety net so a runaway model can't grow a section without bound.
        private static let maxItemsPerSection = 20

        private var shortSummary = ""
        private var detailedSummary = ""
        private var decisions: [SummaryDecision] = []
        private var actionItems: [SummaryActionItem] = []
        private var openQuestions: [SummaryOpenQuestion] = []
        private var risks: [SummaryRisk] = []

        /// Normalized "type + primary text" keys already added, so the common
        /// small-model loop of repeating the same item is collapsed to one.
        private var seenKeys: Set<String> = []

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

        /// Apply one complete NDJSON line. Returns true if it changed the summary.
        mutating func applyLine(_ line: String) -> Bool {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard
                !trimmed.isEmpty,
                let data = trimmed.data(using: .utf8),
                let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let type = object["type"] as? String
            else {
                return false
            }

            switch type {
            case "short":
                shortSummary = string("text", in: object)
                return true
            case "detailed":
                detailedSummary = string("text", in: object)
                return true
            case "decision":
                let title = string("title", in: object)
                guard !title.isEmpty, accept("decision", title, count: decisions.count) else { return false }
                decisions.append(SummaryDecision(
                    title: title,
                    details: string("details", in: object),
                    evidenceSegmentIDs: stringArray("evidence", in: object)
                ))
                return true
            case "action":
                let task = string("task", in: object)
                guard !task.isEmpty, accept("action", task, count: actionItems.count) else { return false }
                actionItems.append(SummaryActionItem(
                    task: task,
                    owner: optionalString("owner", in: object),
                    dueDate: optionalString("due", in: object),
                    evidenceSegmentIDs: stringArray("evidence", in: object)
                ))
                return true
            case "question":
                let question = string("question", in: object)
                guard !question.isEmpty, accept("question", question, count: openQuestions.count) else { return false }
                openQuestions.append(SummaryOpenQuestion(
                    question: question,
                    context: optionalString("context", in: object),
                    evidenceSegmentIDs: stringArray("evidence", in: object)
                ))
                return true
            case "risk":
                let risk = string("risk", in: object)
                guard !risk.isEmpty, accept("risk", risk, count: risks.count) else { return false }
                risks.append(SummaryRisk(
                    risk: risk,
                    details: optionalString("details", in: object),
                    evidenceSegmentIDs: stringArray("evidence", in: object)
                ))
                return true
            default:
                return false
            }
        }

        /// Gate a list item: reject it if the section is full or if an item with
        /// the same normalized primary text was already added. Records the key.
        private mutating func accept(_ type: String, _ primaryText: String, count: Int) -> Bool {
            guard count < Self.maxItemsPerSection else { return false }
            let key = type + "\u{1}" + SummarizationPipeline.dedupKey(primaryText)
            return seenKeys.insert(key).inserted
        }

        /// Preview the in-progress prose line. Returns true if the visible text changed.
        mutating func applyPartialProse(_ fragment: String) -> Bool {
            guard let (type, text) = partialProse(fragment) else { return false }
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
