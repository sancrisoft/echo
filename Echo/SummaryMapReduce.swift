//
//  SummaryMapReduce.swift
//  Echo
//
//  The map-reduce scaling layer for meeting-notes generation (SPEC-05).
//
//  Why this exists
//  ---------------
//  The single-pass summarizer sends the whole transcript in one prompt. That
//  does not scale: a one-hour meeting is ~12-15K tokens, three hours >40K, and
//  extraction quality degrades ("lost in the middle") well before Qwen3.5 4B's
//  262K context is full — and a 40K-token KV cache still costs a GB or more on
//  top of the ~3.3 GB of weights (SP-004's summarizing budget: ≤ ~4.5 GB). So
//  long transcripts are cut into bounded chunks (SPEC-02), each mapped to
//  structured facts independently, the facts merged deterministically in Swift,
//  and a final grounded prose pass writes the short/detailed summaries.
//
//  This file holds the *pure, engine-free* half of that pipeline: the value
//  contracts and the deterministic merge. The LLM orchestration lives in
//  SummarizationPipeline.swift.
//
//  SPEC-07 (live summary) caches `ChunkMapResult`s as chunks close during a
//  recording and replays them into the final reduce, so these types are the
//  binding contract for that feature — keep them pure and serializable.
//

import Foundation

// MARK: - Shared limits & dedup

/// Section caps shared by the streaming accumulator and the deterministic merge,
/// so a runaway model can never grow a section without bound on either path.
nonisolated enum SummaryLimits {
    /// Max items retained per section (decisions/actions/questions/risks).
    static let maxItemsPerSection = 20
}

/// Normalization used to decide when two extracted items are "the same". Shared
/// by the single-pass accumulator (within one generation) and the map-reduce
/// merge (across chunks) so a fact rephrased in an overlap region collapses to
/// one item on either path.
nonisolated enum SummaryDedup {
    /// A dedup key scoped by item type plus the normalized primary text, so a
    /// decision and a risk that happen to share wording never collide.
    static func key(_ type: String, _ primaryText: String) -> String {
        type + "\u{1}" + normalize(primaryText)
    }

    /// Lowercased, punctuation flattened to spaces, whitespace collapsed. So
    /// "…English?" and "…English" collide.
    static func normalize(_ text: String) -> String {
        let flattened = text.lowercased().unicodeScalars.map { scalar in
            CharacterSet.alphanumerics.contains(scalar) ? Character(scalar) : " "
        }
        return String(flattened)
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
    }
}

// MARK: - Map result (SPEC-07 cache contract)

/// Structured facts extracted from one chunk. Pure value; SPEC-07 caches these
/// across a live session and replays them into the final reduce. Serializable so
/// a session can survive an app relaunch.
nonisolated struct ChunkMapResult: Codable, Hashable, Sendable {
    let chunkIndex: Int
    var decisions: [SummaryDecision]
    var actionItems: [SummaryActionItem]
    var openQuestions: [SummaryOpenQuestion]
    var risks: [SummaryRisk]
    /// The "chunknote" gist ("" if the model omitted it).
    var chunkNote: String
    /// Chunk time range, for ordered prose context.
    let start: TimeInterval
    let end: TimeInterval

    nonisolated init(
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

/// The de-duplicated union of every chunk's facts, capped per section. Feeds the
/// final prose pass and the streaming snapshots.
nonisolated struct MergedFacts: Codable, Hashable, Sendable {
    var decisions: [SummaryDecision]
    var actionItems: [SummaryActionItem]
    var openQuestions: [SummaryOpenQuestion]
    var risks: [SummaryRisk]

    nonisolated init(
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

    var isEmpty: Bool {
        decisions.isEmpty && actionItems.isEmpty && openQuestions.isEmpty && risks.isEmpty
    }
}

// MARK: - Deterministic merge (no LLM)

/// The reduce step for structured facts: pure, deterministic Swift. Given the
/// per-chunk map results, it produces one de-duplicated, capped set of facts.
///
/// Merge rules (SPEC-05 §4):
/// - Items are visited in chunk order; the first occurrence of a dedup key wins
///   its position and text.
/// - A later duplicate contributes its evidence (unioned onto the first, in
///   order, case-insensitively de-duplicated).
/// - For actions only, a duplicate fills in `owner`/`due` when the first left
///   them null — never the reverse (null never overwrites a concrete value).
/// - Each section is capped at `SummaryLimits.maxItemsPerSection` distinct items;
///   duplicates of an already-kept item still merge their evidence even past the
///   cap.
nonisolated enum SummaryMerge {
    static func merge(_ results: [ChunkMapResult]) -> MergedFacts {
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

    /// Append `extra` onto `base`, preserving `base`'s order and dropping any ID
    /// already present (case-insensitive, matching evidence-ID resolution).
    private static func unionEvidence(_ base: [String], _ extra: [String]) -> [String] {
        var seen = Set(base.map { $0.lowercased() })
        var merged = base
        for id in extra where seen.insert(id.lowercased()).inserted {
            merged.append(id)
        }
        return merged
    }
}
