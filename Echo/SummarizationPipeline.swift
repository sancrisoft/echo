//
//  SummarizationPipeline.swift
//  Echo
//
//  Generates a grounded meeting summary from final transcript segments only.
//  The local LLM is expected to be served by llama.cpp's OpenAI-compatible API.
//

import Foundation
import os

actor SummarizationPipeline {

    static let log = Logger(subsystem: "com.sancrisoft.Echo", category: "SummarizationPipeline")

    private let endpoint = URL(string: "http://127.0.0.1:8080/v1/chat/completions")!
    private let model = "echo-gemma-summary"
    private let timeout: TimeInterval = 600

    func generate(from segments: [TranscriptSegment]) async throws -> MeetingSummary {
        guard !segments.isEmpty else { throw SummarizationError.emptyTranscript }

        var request = URLRequest(url: endpoint, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try chatRequestBody(for: segments)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw SummarizationError.requestFailed(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw SummarizationError.invalidResponse
        }

        guard 200..<300 ~= http.statusCode else {
            let body = String(data: data, encoding: .utf8) ?? "No response body"
            Self.log.error("Summary request failed: HTTP \(http.statusCode, privacy: .public) \(body, privacy: .public)")
            throw SummarizationError.serverRejected(status: http.statusCode, body: body)
        }

        do {
            let content = try Self.modelContent(from: data)
            guard !content.isEmpty else {
                throw SummarizationError.emptyModelResponse
            }
            return try Self.decodeSummary(from: content)
        } catch let error as SummarizationError {
            throw error
        } catch {
            let body = String(data: data, encoding: .utf8) ?? "Unreadable response"
            Self.log.error("Could not decode summary response: \(error.localizedDescription, privacy: .public) \(body, privacy: .public)")
            throw SummarizationError.invalidModelJSON
        }
    }

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
            "stream": false,
            "response_format": ["type": "json_object"],
        ]
        return try JSONSerialization.data(withJSONObject: payload)
    }

    private static let systemPrompt = """
    You summarize meeting transcripts for a local-first macOS app.
    Use only the transcript provided by the user.
    Do not invent decisions, action item owners, due dates, risks, or blockers.
    If an owner or due date is unclear, return null for that field.
    Do not infer calendar dates from relative wording.
    Keep the summary in the dominant language of the transcript.
    Return only valid JSON. Do not wrap it in Markdown.
    """

    private static func userPrompt(for segments: [TranscriptSegment]) -> String {
        """
        Create a grounded meeting summary from this final transcript.

        Required JSON shape:
        {
          "shortSummary": "string",
          "detailedSummary": "string",
          "decisions": [
            {
              "title": "string",
              "details": "string",
              "evidenceSegmentIDs": ["segment-id"]
            }
          ],
          "actionItems": [
            {
              "task": "string",
              "owner": "string or null",
              "dueDate": "string or null",
              "evidenceSegmentIDs": ["segment-id"]
            }
          ],
          "openQuestions": [
            {
              "question": "string",
              "context": "string or null",
              "evidenceSegmentIDs": ["segment-id"]
            }
          ],
          "risks": [
            {
              "risk": "string",
              "details": "string or null",
              "evidenceSegmentIDs": ["segment-id"]
            }
          ]
        }

        Rules:
        - Include all six top-level keys.
        - Use empty arrays when there are no decisions, action items, open questions, or risks.
        - Every decision, action item, open question, and risk must include evidenceSegmentIDs from the transcript.
        - If a claim cannot be supported by a transcript segment, omit it.
        - Preserve speaker roles: You means the current user; Team means teammates from system audio.

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

    private static func modelContent(from data: Data) throws -> String {
        guard
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let choices = object["choices"] as? [[String: Any]],
            let first = choices.first,
            let message = first["message"] as? [String: Any],
            let content = message["content"] as? String
        else {
            throw SummarizationError.invalidResponse
        }
        return content
    }

    private static func decodeSummary(from content: String) throws -> MeetingSummary {
        let candidates = [
            content,
            strippedMarkdownFence(content),
            firstJSONObject(in: content),
        ].compactMap { $0 }

        for candidate in candidates {
            guard let data = candidate.data(using: .utf8) else { continue }
            if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                return MeetingSummary(
                    shortSummary: string("shortSummary", in: object),
                    detailedSummary: string("detailedSummary", in: object),
                    decisions: decisions(from: object["decisions"]),
                    actionItems: actionItems(from: object["actionItems"]),
                    openQuestions: openQuestions(from: object["openQuestions"]),
                    risks: risks(from: object["risks"])
                )
            }
        }

        throw SummarizationError.invalidModelJSON
    }

    private static func decisions(from value: Any?) -> [SummaryDecision] {
        objects(from: value).compactMap { object in
            let title = string("title", in: object)
            guard !title.isEmpty else { return nil }
            return SummaryDecision(
                title: title,
                details: string("details", in: object),
                evidenceSegmentIDs: stringArray("evidenceSegmentIDs", in: object)
            )
        }
    }

    private static func actionItems(from value: Any?) -> [SummaryActionItem] {
        objects(from: value).compactMap { object in
            let task = string("task", in: object)
            guard !task.isEmpty else { return nil }
            return SummaryActionItem(
                task: task,
                owner: optionalString("owner", in: object),
                dueDate: optionalString("dueDate", in: object),
                evidenceSegmentIDs: stringArray("evidenceSegmentIDs", in: object)
            )
        }
    }

    private static func openQuestions(from value: Any?) -> [SummaryOpenQuestion] {
        objects(from: value).compactMap { object in
            let question = string("question", in: object)
            guard !question.isEmpty else { return nil }
            return SummaryOpenQuestion(
                question: question,
                context: optionalString("context", in: object),
                evidenceSegmentIDs: stringArray("evidenceSegmentIDs", in: object)
            )
        }
    }

    private static func risks(from value: Any?) -> [SummaryRisk] {
        objects(from: value).compactMap { object in
            let risk = string("risk", in: object)
            guard !risk.isEmpty else { return nil }
            return SummaryRisk(
                risk: risk,
                details: optionalString("details", in: object),
                evidenceSegmentIDs: stringArray("evidenceSegmentIDs", in: object)
            )
        }
    }

    private static func objects(from value: Any?) -> [[String: Any]] {
        value as? [[String: Any]] ?? []
    }

    private static func string(_ key: String, in object: [String: Any]) -> String {
        optionalString(key, in: object) ?? ""
    }

    private static func optionalString(_ key: String, in object: [String: Any]) -> String? {
        guard let value = object[key], !(value is NSNull) else { return nil }
        let string = value as? String ?? "\(value)"
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
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

    private static func strippedMarkdownFence(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("```") else { return nil }

        var lines = trimmed.components(separatedBy: .newlines)
        guard !lines.isEmpty else { return nil }
        lines.removeFirst()
        if lines.last?.trimmingCharacters(in: .whitespacesAndNewlines) == "```" {
            lines.removeLast()
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func firstJSONObject(in text: String) -> String? {
        var start: String.Index?
        var depth = 0
        var inString = false
        var escaping = false

        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]

            if inString {
                if escaping {
                    escaping = false
                } else if character == "\\" {
                    escaping = true
                } else if character == "\"" {
                    inString = false
                }
            } else if character == "\"" {
                inString = true
            } else if character == "{" {
                if depth == 0 { start = index }
                depth += 1
            } else if character == "}" {
                depth -= 1
                if depth == 0, let start {
                    return String(text[start...index])
                }
            }

            index = text.index(after: index)
        }

        return nil
    }
}

enum SummarizationError: LocalizedError {
    case emptyTranscript
    case requestFailed(String)
    case invalidResponse
    case serverRejected(status: Int, body: String)
    case emptyModelResponse
    case invalidModelJSON

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
        case .invalidModelJSON:
            return "Gemma did not return valid summary JSON."
        }
    }
}
