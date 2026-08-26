//
//  MeetingSummaryModels.swift
//  Echo
//
//  Structured output generated from the final transcript after recording stops.
//

import Foundation

enum SummaryState: Hashable, Sendable {
    case idle
    case generating
    case streaming(MeetingSummary)
    case ready(MeetingSummary)
    case unavailable(String)
    case failed(String)
}

struct MeetingSummary: Codable, Hashable, Sendable {
    /// The adaptive Markdown document the model writes freely (Notion-style
    /// notes) — the summary's new primary form. Empty on every summary written
    /// before this field existed and on the legacy NDJSON route; consumers fall
    /// back to the fixed fields below when it is empty.
    var markdown: String
    var shortSummary: String
    var detailedSummary: String
    var decisions: [SummaryDecision]
    var actionItems: [SummaryActionItem]
    var openQuestions: [SummaryOpenQuestion]
    var risks: [SummaryRisk]

    /// `markdown` defaults to "" (and sits first, before the legacy fields) so
    /// every pre-existing call site compiles unchanged.
    nonisolated init(
        markdown: String = "",
        shortSummary: String,
        detailedSummary: String,
        decisions: [SummaryDecision],
        actionItems: [SummaryActionItem],
        openQuestions: [SummaryOpenQuestion],
        risks: [SummaryRisk]
    ) {
        self.markdown = markdown
        self.shortSummary = shortSummary
        self.detailedSummary = detailedSummary
        self.decisions = decisions
        self.actionItems = actionItems
        self.openQuestions = openQuestions
        self.risks = risks
    }

    /// The one string the summary UI renders for both eras: a markdown-bearing
    /// summary IS its document (verbatim — the renderer owns presentation), and
    /// a legacy fixed-schema summary resolves to a faithful markdown
    /// serialization of the fields the fixed UI used to show. `nonisolated` so
    /// the renderer and formatting code can read it from any context.
    nonisolated var resolvedMarkdown: String {
        if !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return markdown
        }
        return legacyMarkdown
    }

    /// The fixed fields as one markdown document — what the pre-adaptive UI
    /// showed, serialized: the summary paragraphs, then a `###` section per
    /// populated list. Empty sections are omitted (the adaptive principle:
    /// never render a bare heading), and unknown owners/dates simply don't
    /// appear (AGENTS.md — never invented). An entirely empty summary is "".
    private nonisolated var legacyMarkdown: String {
        var lines: [String] = []
        if !shortSummary.isEmpty { lines.append(shortSummary); lines.append("") }
        if !detailedSummary.isEmpty { lines.append(detailedSummary); lines.append("") }
        appendSection("Decisions", decisions.map {
            Self.dashed("**\($0.title)**", $0.details)
        }, into: &lines)
        appendSection("Action Items", actionItems.map { item in
            var parts = [item.task]
            if let owner = item.owner, !owner.isEmpty { parts.append("Owner: \(owner)") }
            if let due = item.dueDate, !due.isEmpty { parts.append("Due: \(due)") }
            return parts.joined(separator: " · ")
        }, into: &lines)
        appendSection("Open Questions", openQuestions.map {
            Self.dashed($0.question, $0.context)
        }, into: &lines)
        appendSection("Risks or Blockers", risks.map {
            Self.dashed($0.risk, $0.details)
        }, into: &lines)
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private nonisolated func appendSection(_ title: String, _ items: [String], into lines: inout [String]) {
        guard !items.isEmpty else { return }
        lines.append("### \(title)")
        lines.append("")
        for item in items { lines.append("- \(item)") }
        lines.append("")
    }

    private nonisolated static func dashed(_ lead: String, _ detail: String?) -> String {
        if let detail, !detail.isEmpty { return "\(lead) — \(detail)" }
        return lead
    }

    // Hand-written Codable (ADR-023 pattern): the schema evolves additively, so
    // a `summary.json` written before `markdown` existed must keep decoding —
    // `decodeIfPresent` fills it with "". Encode stays symmetric (the key is
    // always written) so a round trip is lossless. Isolation matches the old
    // synthesized conformance: the nested value types' Codable is main-actor-
    // isolated, so these run on the main actor too (MeetingStore already hops).

    private enum CodingKeys: String, CodingKey {
        case markdown, shortSummary, detailedSummary
        case decisions, actionItems, openQuestions, risks
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        markdown = try container.decodeIfPresent(String.self, forKey: .markdown) ?? ""
        shortSummary = try container.decode(String.self, forKey: .shortSummary)
        detailedSummary = try container.decode(String.self, forKey: .detailedSummary)
        decisions = try container.decode([SummaryDecision].self, forKey: .decisions)
        actionItems = try container.decode([SummaryActionItem].self, forKey: .actionItems)
        openQuestions = try container.decode([SummaryOpenQuestion].self, forKey: .openQuestions)
        risks = try container.decode([SummaryRisk].self, forKey: .risks)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(markdown, forKey: .markdown)
        try container.encode(shortSummary, forKey: .shortSummary)
        try container.encode(detailedSummary, forKey: .detailedSummary)
        try container.encode(decisions, forKey: .decisions)
        try container.encode(actionItems, forKey: .actionItems)
        try container.encode(openQuestions, forKey: .openQuestions)
        try container.encode(risks, forKey: .risks)
    }
}

struct SummaryDecision: Codable, Hashable, Sendable {
    var title: String
    var details: String
    var evidenceSegmentIDs: [String]

    nonisolated init(title: String, details: String, evidenceSegmentIDs: [String]) {
        self.title = title
        self.details = details
        self.evidenceSegmentIDs = evidenceSegmentIDs
    }
}

struct SummaryActionItem: Codable, Hashable, Sendable {
    var task: String
    var owner: String?
    var dueDate: String?
    var evidenceSegmentIDs: [String]

    nonisolated init(task: String, owner: String?, dueDate: String?, evidenceSegmentIDs: [String]) {
        self.task = task
        self.owner = owner
        self.dueDate = dueDate
        self.evidenceSegmentIDs = evidenceSegmentIDs
    }
}

struct SummaryOpenQuestion: Codable, Hashable, Sendable {
    var question: String
    var context: String?
    var evidenceSegmentIDs: [String]

    nonisolated init(question: String, context: String?, evidenceSegmentIDs: [String]) {
        self.question = question
        self.context = context
        self.evidenceSegmentIDs = evidenceSegmentIDs
    }
}

struct SummaryRisk: Codable, Hashable, Sendable {
    var risk: String
    var details: String?
    var evidenceSegmentIDs: [String]

    nonisolated init(risk: String, details: String?, evidenceSegmentIDs: [String]) {
        self.risk = risk
        self.details = details
        self.evidenceSegmentIDs = evidenceSegmentIDs
    }
}
