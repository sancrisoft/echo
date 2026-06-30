//
//  SummarizationPipeline.swift
//  Echo
//
//  Generates a grounded meeting summary from final transcript segments only.
//  The local LLM is served by llama.cpp's OpenAI-compatible API and streamed
//  back as NDJSON (one JSON object per line) so the UI can fill in progressively.
//

import Foundation
import os

actor SummarizationPipeline {

    static let log = Logger(subsystem: "com.sancrisoft.Echo", category: "SummarizationPipeline")

    private let endpoint = URL(string: "http://127.0.0.1:8080/v1/chat/completions")!
    private let model = "echo-gemma-summary"
    private let timeout: TimeInterval = 600

    /// Streams progressively-more-complete summaries as the model emits NDJSON
    /// lines. Each element is a snapshot of everything parsed so far; the final
    /// element is the complete summary. Throws on transport/protocol failures.
    func generate(from segments: [TranscriptSegment]) -> AsyncThrowingStream<MeetingSummary, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await self.run(from: segments, into: continuation)
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
        into continuation: AsyncThrowingStream<MeetingSummary, Error>.Continuation
    ) async throws {
        guard !segments.isEmpty else { throw SummarizationError.emptyTranscript }

        var request = URLRequest(url: endpoint, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.httpBody = try chatRequestBody(for: segments)

        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await URLSession.shared.bytes(for: request)
        } catch {
            throw SummarizationError.requestFailed(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw SummarizationError.invalidResponse
        }

        guard 200..<300 ~= http.statusCode else {
            var body = ""
            for try await line in bytes.lines {
                body += line
                if body.count > 2000 { break }
            }
            Self.log.error("Summary request failed: HTTP \(http.statusCode, privacy: .public) \(body, privacy: .public)")
            throw SummarizationError.serverRejected(status: http.statusCode, body: body)
        }

        var accumulator = SummaryAccumulator()
        var buffer = ""

        for try await rawLine in bytes.lines {
            try Task.checkCancellation()
            guard let payload = Self.ssePayload(rawLine) else { continue }
            if payload == "[DONE]" { break }
            guard let delta = Self.deltaContent(payload), !delta.isEmpty else { continue }

            buffer += delta

            var changed = false
            while let newline = buffer.firstIndex(of: "\n") {
                let line = String(buffer[buffer.startIndex..<newline])
                buffer.removeSubrange(buffer.startIndex...newline)
                if accumulator.applyLine(line) { changed = true }
            }
            // Preview the in-progress prose line (short/detailed) char-by-char.
            if accumulator.applyPartialProse(buffer) { changed = true }

            if changed { continuation.yield(accumulator.snapshot) }
        }

        // The grammar terminates every entry with a newline, but flush a trailing
        // object just in case the stream ends without one.
        let tail = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty { _ = accumulator.applyLine(tail) }

        guard accumulator.hasContent else { throw SummarizationError.emptyModelResponse }
        continuation.yield(accumulator.snapshot)
    }

    // MARK: - Request

    private func chatRequestBody(for segments: [TranscriptSegment]) throws -> Data {
        let payload: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": Self.systemPrompt],
                ["role": "user", "content": Self.userPrompt(for: segments)],
            ],
            "temperature": 0.1,
            "top_p": 0.9,
            "max_tokens": 4096,
            "stream": true,
            // Constrain generation to our NDJSON shape so a small local model
            // cannot emit malformed lines. Ignored by servers that don't support
            // it, in which case the prompt + tolerant parser still apply.
            "grammar": Self.grammar,
        ]
        return try JSONSerialization.data(withJSONObject: payload)
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

    // MARK: - SSE parsing

    /// Returns the payload of an SSE `data:` line, or nil for other lines.
    private static func ssePayload(_ line: String) -> String? {
        guard line.hasPrefix("data:") else { return nil }
        return line.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
    }

    /// Extracts `choices[0].delta.content` from one streamed chunk.
    private static func deltaContent(_ payload: String) -> String? {
        guard
            let data = payload.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let choices = object["choices"] as? [[String: Any]],
            let first = choices.first,
            let delta = first["delta"] as? [String: Any],
            let content = delta["content"] as? String
        else {
            return nil
        }
        return content
    }

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
        // The grammar allows a real `null` or a quoted string; a constrained model
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

    // MARK: - NDJSON accumulator

    /// Builds a `MeetingSummary` incrementally from streamed NDJSON lines.
    private struct SummaryAccumulator {
        private var shortSummary = ""
        private var detailedSummary = ""
        private var decisions: [SummaryDecision] = []
        private var actionItems: [SummaryActionItem] = []
        private var openQuestions: [SummaryOpenQuestion] = []
        private var risks: [SummaryRisk] = []

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
                guard !title.isEmpty else { return false }
                decisions.append(SummaryDecision(
                    title: title,
                    details: string("details", in: object),
                    evidenceSegmentIDs: stringArray("evidence", in: object)
                ))
                return true
            case "action":
                let task = string("task", in: object)
                guard !task.isEmpty else { return false }
                actionItems.append(SummaryActionItem(
                    task: task,
                    owner: optionalString("owner", in: object),
                    dueDate: optionalString("due", in: object),
                    evidenceSegmentIDs: stringArray("evidence", in: object)
                ))
                return true
            case "question":
                let question = string("question", in: object)
                guard !question.isEmpty else { return false }
                openQuestions.append(SummaryOpenQuestion(
                    question: question,
                    context: optionalString("context", in: object),
                    evidenceSegmentIDs: stringArray("evidence", in: object)
                ))
                return true
            case "risk":
                let risk = string("risk", in: object)
                guard !risk.isEmpty else { return false }
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

    // MARK: - Grammar

    /// GBNF constraining the model to our NDJSON protocol: a sequence of
    /// newline-terminated, single-line JSON objects. String contents exclude
    /// raw control characters so newlines only ever delimit lines.
    private static let grammar = #"""
    root ::= entry+
    entry ::= ( short | detailed | decision | action | question | risk ) "\n"
    short ::= "{\"type\":\"short\",\"text\":" string "}"
    detailed ::= "{\"type\":\"detailed\",\"text\":" string "}"
    decision ::= "{\"type\":\"decision\",\"title\":" string ",\"details\":" nstring ",\"evidence\":" idarray "}"
    action ::= "{\"type\":\"action\",\"task\":" string ",\"owner\":" nstring ",\"due\":" nstring ",\"evidence\":" idarray "}"
    question ::= "{\"type\":\"question\",\"question\":" string ",\"context\":" nstring ",\"evidence\":" idarray "}"
    risk ::= "{\"type\":\"risk\",\"risk\":" string ",\"details\":" nstring ",\"evidence\":" idarray "}"
    idarray ::= "[" ( string ( "," string )* )? "]"
    nstring ::= string | "null"
    string ::= "\"" char* "\""
    char ::= [^"\\\x7F\x00-\x1F] | "\\" (["\\/bfnrt] | "u" [0-9a-fA-F] [0-9a-fA-F] [0-9a-fA-F] [0-9a-fA-F])
    """#
}

enum SummarizationError: LocalizedError {
    case emptyTranscript
    case requestFailed(String)
    case invalidResponse
    case serverRejected(status: Int, body: String)
    case emptyModelResponse

    var errorDescription: String? {
        switch self {
        case .emptyTranscript:
            return "No transcript was captured."
        case .requestFailed(let message):
            return "Could not reach local Gemma server: \(message)"
        case .invalidResponse:
            return "The local Gemma server returned an invalid response."
        case .serverRejected(let status, let body):
            return "The local Gemma server rejected the request (HTTP \(status)): \(body)"
        case .emptyModelResponse:
            return "Gemma returned an empty summary."
        }
    }
}
