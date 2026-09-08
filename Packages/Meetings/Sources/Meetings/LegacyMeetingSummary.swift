//
//  LegacyMeetingSummary.swift
//  Meetings
//
//  The pre-Markdown summary payload (`summary.json`). Nothing writes it any
//  more: `summary.md` is the summary. This decoder exists so every folder v1
//  ever wrote keeps loading, and so the launch-time fold into `summary.md`
//  knows what to write. Kept forever (ADR-005).
//

import Foundation

public struct LegacyMeetingSummary: Codable, Hashable, Sendable {

    public struct Decision: Codable, Hashable, Sendable {
        public var title: String
        public var details: String
        public var evidenceSegmentIDs: [String]

        public init(title: String, details: String, evidenceSegmentIDs: [String] = []) {
            self.title = title
            self.details = details
            self.evidenceSegmentIDs = evidenceSegmentIDs
        }
    }

    public struct ActionItem: Codable, Hashable, Sendable {
        public var task: String
        public var owner: String?
        public var dueDate: String?
        public var evidenceSegmentIDs: [String]

        public init(task: String, owner: String? = nil, dueDate: String? = nil, evidenceSegmentIDs: [String] = []) {
            self.task = task
            self.owner = owner
            self.dueDate = dueDate
            self.evidenceSegmentIDs = evidenceSegmentIDs
        }
    }

    public struct OpenQuestion: Codable, Hashable, Sendable {
        public var question: String
        public var context: String?
        public var evidenceSegmentIDs: [String]

        public init(question: String, context: String? = nil, evidenceSegmentIDs: [String] = []) {
            self.question = question
            self.context = context
            self.evidenceSegmentIDs = evidenceSegmentIDs
        }
    }

    public struct Risk: Codable, Hashable, Sendable {
        public var risk: String
        public var details: String?
        public var evidenceSegmentIDs: [String]

        public init(risk: String, details: String? = nil, evidenceSegmentIDs: [String] = []) {
            self.risk = risk
            self.details = details
            self.evidenceSegmentIDs = evidenceSegmentIDs
        }
    }

    /// The adaptive Markdown document, when the summary was written after that
    /// field existed. Empty on older files.
    public var markdown: String
    public var shortSummary: String
    public var detailedSummary: String
    public var decisions: [Decision]
    public var actionItems: [ActionItem]
    public var openQuestions: [OpenQuestion]
    public var risks: [Risk]

    public init(
        markdown: String = "",
        shortSummary: String = "",
        detailedSummary: String = "",
        decisions: [Decision] = [],
        actionItems: [ActionItem] = [],
        openQuestions: [OpenQuestion] = [],
        risks: [Risk] = []
    ) {
        self.markdown = markdown
        self.shortSummary = shortSummary
        self.detailedSummary = detailedSummary
        self.decisions = decisions
        self.actionItems = actionItems
        self.openQuestions = openQuestions
        self.risks = risks
    }

    private enum CodingKeys: String, CodingKey {
        case markdown, shortSummary, detailedSummary
        case decisions, actionItems, openQuestions, risks
    }

    // Hand-written so a file written before `markdown` existed decodes with it
    // empty rather than failing.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        markdown = try container.decodeIfPresent(String.self, forKey: .markdown) ?? ""
        shortSummary = try container.decode(String.self, forKey: .shortSummary)
        detailedSummary = try container.decode(String.self, forKey: .detailedSummary)
        decisions = try container.decode([Decision].self, forKey: .decisions)
        actionItems = try container.decode([ActionItem].self, forKey: .actionItems)
        openQuestions = try container.decode([OpenQuestion].self, forKey: .openQuestions)
        risks = try container.decode([Risk].self, forKey: .risks)
    }

    /// The one Markdown string this summary stands for: the document verbatim
    /// when there is one, otherwise a faithful serialization of the fixed
    /// fields — the summary paragraphs, then a `###` section per populated
    /// list. Empty sections are omitted (never a bare heading) and unknown
    /// owners or dates simply do not appear (never invented). An entirely
    /// empty summary is "".
    public var resolvedMarkdown: String {
        if !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return markdown
        }
        var lines: [String] = []
        if !shortSummary.isEmpty {
            lines.append(shortSummary)
            lines.append("")
        }
        if !detailedSummary.isEmpty {
            lines.append(detailedSummary)
            lines.append("")
        }
        appendSection("Decisions", decisions.map { Self.dashed("**\($0.title)**", $0.details) }, into: &lines)
        appendSection(
            "Action Items",
            actionItems.map { item in
                var parts = [item.task]
                if let owner = item.owner, !owner.isEmpty { parts.append("Owner: \(owner)") }
                if let due = item.dueDate, !due.isEmpty { parts.append("Due: \(due)") }
                return parts.joined(separator: " · ")
            }, into: &lines)
        appendSection("Open Questions", openQuestions.map { Self.dashed($0.question, $0.context) }, into: &lines)
        appendSection("Risks or Blockers", risks.map { Self.dashed($0.risk, $0.details) }, into: &lines)
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func appendSection(_ title: String, _ items: [String], into lines: inout [String]) {
        guard !items.isEmpty else { return }
        lines.append("### \(title)")
        lines.append("")
        for item in items { lines.append("- \(item)") }
        lines.append("")
    }

    private static func dashed(_ lead: String, _ detail: String?) -> String {
        if let detail, !detail.isEmpty { return "\(lead) — \(detail)" }
        return lead
    }
}
