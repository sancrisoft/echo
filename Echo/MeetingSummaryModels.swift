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
    case ready(MeetingSummary)
    case unavailable(String)
    case failed(String)
}

struct MeetingSummary: Codable, Hashable, Sendable {
    var shortSummary: String
    var detailedSummary: String
    var decisions: [SummaryDecision]
    var actionItems: [SummaryActionItem]
    var openQuestions: [SummaryOpenQuestion]
    var risks: [SummaryRisk]

    nonisolated init(
        shortSummary: String,
        detailedSummary: String,
        decisions: [SummaryDecision],
        actionItems: [SummaryActionItem],
        openQuestions: [SummaryOpenQuestion],
        risks: [SummaryRisk]
    ) {
        self.shortSummary = shortSummary
        self.detailedSummary = detailedSummary
        self.decisions = decisions
        self.actionItems = actionItems
        self.openQuestions = openQuestions
        self.risks = risks
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
