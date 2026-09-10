//
//  SummaryFacts.swift
//  Summarization
//
//  The pure, engine-free half of the long route: the fact vocabulary the map
//  phase extracts, and the deterministic merge that unions it across chunks.
//  No model, no clock, no I/O — same input, same output, always.
//
//  Why the long route has a fact model at all: past the single-pass budget the
//  transcript cannot be one prompt, so each chunk is mapped to structured facts
//  independently and merged in Swift rather than by a second model call. Doing
//  the union in code is what makes it deterministic, and what makes evidence
//  grounding executable — every fact carries the segment ids it came from, and
//  a fact that cites nothing real is dropped before it ever reaches here.
//
//  These types are `Codable` because they are a cache contract: a live-summary
//  feature can persist each chunk's result as chunks close and replay them into
//  the final reduce. Nothing in this package writes them to disk.
//

import Foundation

// MARK: - Leaf facts

/// A decision the meeting actually made. `details` is non-optional because the
/// map protocol always supplies a string for it (empty when the model had
/// nothing to add); the other three sections use optionals. The asymmetry is
/// carried from v1 on purpose — these field names and shapes are what an
/// existing `summary.json` decodes into.
public struct SummaryDecision: Codable, Hashable, Sendable {
    public var title: String
    public var details: String
    /// Segment ids this fact was grounded in. Never empty on a fact that
    /// survived the evidence filter.
    public var evidenceSegmentIDs: [String]

    public init(title: String, details: String, evidenceSegmentIDs: [String] = []) {
        self.title = title
        self.details = details
        self.evidenceSegmentIDs = evidenceSegmentIDs
    }
}

/// Something someone committed to. `owner` is nil unless a person actually took
/// the task — a confidently wrong owner is worse than a blank one, and the merge
/// below can only ever fill a nil, never overwrite a name.
public struct SummaryActionItem: Codable, Hashable, Sendable {
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

public struct SummaryOpenQuestion: Codable, Hashable, Sendable {
    public var question: String
    public var context: String?
    public var evidenceSegmentIDs: [String]

    public init(question: String, context: String? = nil, evidenceSegmentIDs: [String] = []) {
        self.question = question
        self.context = context
        self.evidenceSegmentIDs = evidenceSegmentIDs
    }
}

public struct SummaryRisk: Codable, Hashable, Sendable {
    public var risk: String
    public var details: String?
    public var evidenceSegmentIDs: [String]

    public init(risk: String, details: String? = nil, evidenceSegmentIDs: [String] = []) {
        self.risk = risk
        self.details = details
        self.evidenceSegmentIDs = evidenceSegmentIDs
    }
}

// MARK: - Shared limits and dedup

/// Section caps, shared by the streaming accumulator and the merge, so a
/// runaway model cannot grow a section without bound on either path.
public enum SummaryLimits {
    /// Max distinct items retained per section.
    public static let maxItemsPerSection = 20
}

/// How two extracted items are decided to be "the same". Shared by the
/// accumulator (within one generation) and the merge (across chunks), so a fact
/// rephrased inside a chunk's overlap collapses to one item on either path.
public enum SummaryDedup {

    /// A dedup key scoped by item type plus the normalized primary text, so a
    /// decision and a risk that happen to share wording never collide. The
    /// separator is a control character precisely because no model output
    /// contains one.
    public static func key(_ type: String, _ primaryText: String) -> String {
        type + "\u{1}" + normalize(primaryText)
    }

    /// Lowercased, punctuation flattened to spaces, whitespace collapsed — so
    /// "…English?" and "…English" collide.
    public static func normalize(_ text: String) -> String {
        let flattened = text.lowercased().unicodeScalars.map { scalar in
            CharacterSet.alphanumerics.contains(scalar) ? Character(scalar) : " "
        }
        return String(flattened)
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
    }
}

// MARK: - Map result

/// The facts one chunk yielded, plus its note and time range.
public struct ChunkMapResult: Codable, Hashable, Sendable {
    public let chunkIndex: Int
    public var decisions: [SummaryDecision]
    public var actionItems: [SummaryActionItem]
    public var openQuestions: [SummaryOpenQuestion]
    public var risks: [SummaryRisk]
    /// This part's note — a detailed, specifics-preserving account ("" when the
    /// model omitted it). The reduce writes the document from these notes, so it
    /// can only be as specific as they are; that is why the map prompt demands
    /// the numbers, names and root causes rather than a gist.
    public var chunkNote: String
    /// Chunk time range, so the reduce can order the meeting's arc.
    public let start: TimeInterval
    public let end: TimeInterval

    public init(
        chunkIndex: Int,
        decisions: [SummaryDecision],
        actionItems: [SummaryActionItem],
        openQuestions: [SummaryOpenQuestion],
        risks: [SummaryRisk],
        chunkNote: String,
        start: TimeInterval,
        end: TimeInterval
    ) {
        self.chunkIndex = chunkIndex
        self.decisions = decisions
        self.actionItems = actionItems
        self.openQuestions = openQuestions
        self.risks = risks
        self.chunkNote = chunkNote
        self.start = start
        self.end = end
    }
}

/// The de-duplicated union of every chunk's facts, capped per section.
public struct MergedFacts: Codable, Hashable, Sendable {
    public var decisions: [SummaryDecision]
    public var actionItems: [SummaryActionItem]
    public var openQuestions: [SummaryOpenQuestion]
    public var risks: [SummaryRisk]

    public init(
        decisions: [SummaryDecision] = [],
        actionItems: [SummaryActionItem] = [],
        openQuestions: [SummaryOpenQuestion] = [],
        risks: [SummaryRisk] = []
    ) {
        self.decisions = decisions
        self.actionItems = actionItems
        self.openQuestions = openQuestions
        self.risks = risks
    }

    public var isEmpty: Bool {
        decisions.isEmpty && actionItems.isEmpty && openQuestions.isEmpty && risks.isEmpty
    }

    /// These facts as a fixed-schema Markdown document.
    ///
    /// Not what a summary normally looks like — the model writes the document,
    /// adaptively, and this schema is the opposite of adaptive. It exists for
    /// exactly one case: both reduce attempts came back empty, and the grounded
    /// facts the maps already earned must still reach the user rather than being
    /// thrown away with an error. The section titles and the `—` separator match
    /// what v1 rendered for the same case, so a degraded summary looks the same
    /// as it always did.
    ///
    /// An empty section is never written, which is the same rule the prompts
    /// state; a wholly empty set of facts renders as "".
    public var markdown: String {
        var lines: [String] = []
        appendSection("Decisions", decisions.map { Self.dashed("**\($0.title)**", $0.details) }, into: &lines)
        appendSection(
            "Action Items",
            actionItems.map { item in
                var parts = [item.task]
                if let owner = item.owner, !owner.isEmpty { parts.append("Owner: \(owner)") }
                if let due = item.dueDate, !due.isEmpty { parts.append("Due: \(due)") }
                return parts.joined(separator: " · ")
            },
            into: &lines
        )
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

// MARK: - Deterministic merge

/// The reduce step for structured facts: pure, deterministic Swift.
///
/// Merge rules:
/// - Items are visited in chunk order; the first occurrence of a dedup key wins
///   its position AND its text.
/// - A later duplicate contributes its evidence, unioned onto the first in
///   order and de-duplicated case-insensitively.
/// - For actions only, a duplicate fills in `owner`/`dueDate` when the first
///   left them nil — never the reverse. Null never overwrites a value.
/// - Each section caps at `SummaryLimits.maxItemsPerSection` DISTINCT items;
///   a duplicate of an already-kept item still merges its evidence past the cap.
public enum SummaryMerge {

    public static func merge(_ results: [ChunkMapResult]) -> MergedFacts {
        // Sorted, not assumed: a caller replaying a cache may hand these over
        // out of order, and the merge's determinism is stated in chunk order.
        let ordered = results.sorted { $0.chunkIndex < $1.chunkIndex }

        var decisions: [SummaryDecision] = []
        var decisionIndex: [String: Int] = [:]
        var actions: [SummaryActionItem] = []
        var actionIndex: [String: Int] = [:]
        var questions: [SummaryOpenQuestion] = []
        var questionIndex: [String: Int] = [:]
        var risks: [SummaryRisk] = []
        var riskIndex: [String: Int] = [:]

        for result in ordered {
            for decision in result.decisions {
                let key = SummaryDedup.key("decision", decision.title)
                if let existing = decisionIndex[key] {
                    decisions[existing].evidenceSegmentIDs = unionEvidence(
                        decisions[existing].evidenceSegmentIDs, decision.evidenceSegmentIDs)
                } else if decisions.count < SummaryLimits.maxItemsPerSection {
                    decisionIndex[key] = decisions.count
                    decisions.append(decision)
                }
            }

            for action in result.actionItems {
                let key = SummaryDedup.key("action", action.task)
                if let existing = actionIndex[key] {
                    actions[existing].evidenceSegmentIDs = unionEvidence(
                        actions[existing].evidenceSegmentIDs, action.evidenceSegmentIDs)
                    // Null never overwrites a value; a duplicate only fills gaps.
                    if actions[existing].owner == nil, let owner = action.owner {
                        actions[existing].owner = owner
                    }
                    if actions[existing].dueDate == nil, let due = action.dueDate {
                        actions[existing].dueDate = due
                    }
                } else if actions.count < SummaryLimits.maxItemsPerSection {
                    actionIndex[key] = actions.count
                    actions.append(action)
                }
            }

            for question in result.openQuestions {
                let key = SummaryDedup.key("question", question.question)
                if let existing = questionIndex[key] {
                    questions[existing].evidenceSegmentIDs = unionEvidence(
                        questions[existing].evidenceSegmentIDs, question.evidenceSegmentIDs)
                } else if questions.count < SummaryLimits.maxItemsPerSection {
                    questionIndex[key] = questions.count
                    questions.append(question)
                }
            }

            for risk in result.risks {
                let key = SummaryDedup.key("risk", risk.risk)
                if let existing = riskIndex[key] {
                    risks[existing].evidenceSegmentIDs = unionEvidence(
                        risks[existing].evidenceSegmentIDs, risk.evidenceSegmentIDs)
                } else if risks.count < SummaryLimits.maxItemsPerSection {
                    riskIndex[key] = risks.count
                    risks.append(risk)
                }
            }
        }

        return MergedFacts(
            decisions: decisions,
            actionItems: actions,
            openQuestions: questions,
            risks: risks
        )
    }

    /// Append `extra` onto `base`, preserving `base`'s order and dropping any id
    /// already present. Case-insensitive to match how evidence ids are resolved,
    /// but the first-seen spelling is the one kept.
    private static func unionEvidence(_ base: [String], _ extra: [String]) -> [String] {
        var seen = Set(base.map { $0.lowercased() })
        var merged = base
        for id in extra where seen.insert(id.lowercased()).inserted {
            merged.append(id)
        }
        return merged
    }
}
