//
//  MeetingProperties.swift
//  Workspace
//
//  The facts under a meeting's title, as values, in the order the artboards
//  list them. Each tab has its own: the Summary tab says how long the meeting
//  ran and whether its notes are in, the Transcript tab who spoke how much and
//  what wrote the words. Which rows a meeting gets is a rule rather than a
//  rendering detail — a meeting saved before word counts were kept has no
//  Words row, one saved before the capture was recorded has no Capture row —
//  so it is decided here and tested without drawing.
//

import DesignSystem
import EchoCore
import Foundation
import Meetings

enum MeetingProperty: Equatable, Sendable {
    /// The day, and the span of the clock the meeting ran over.
    case date(start: Date, end: Date)
    /// Rounded to the minute.
    case duration(TimeInterval)
    case words(Int)
    /// What was captured: "Zoom only", or "Everything".
    case capture(String)
    case status(MeetingStatus)
    /// You and Others, by speaking time.
    case speakers(SpeakerSplit)
    /// Whether the transcript is final, and the model that wrote it.
    case transcript(TranscriptStatus)

    /// The rows the Summary tab shows, in order.
    static func summaryRows(for meta: MeetingMeta) -> [MeetingProperty] {
        var rows: [MeetingProperty] = [.date(start: meta.startedAt, end: meta.endedAt), .duration(meta.duration)]
        if let words = meta.wordCount, words > 0 {
            rows.append(.words(words))
        }
        if let capture = meta.captureScope {
            rows.append(.capture(capture.scopedDisplayLabel ?? "Everything"))
        }
        rows.append(.status(MeetingStatus.resolve(meta)))
        return rows
    }

    /// The rows the Transcript tab shows, in order: the speaker split and the
    /// transcript's own status take the place of the duration and the
    /// summary's, which belong to the Summary tab.
    static func transcriptRows(for meta: MeetingMeta, segments: [TranscriptSegment]) -> [MeetingProperty] {
        var rows: [MeetingProperty] = [.date(start: meta.startedAt, end: meta.endedAt)]
        if let split = SpeakerSplit.measure(segments) {
            rows.append(.speakers(split))
        }
        if let words = meta.wordCount, words > 0 {
            rows.append(.words(words))
        }
        rows.append(.transcript(TranscriptStatus.resolve(meta)))
        return rows
    }

    /// A meeting's length as the document writes it: "58 min", "1 h 12 min".
    /// Never "0 min": a meeting that stopped at once still ran.
    static func duration(_ seconds: TimeInterval) -> String {
        let minutes = max(1, Int((seconds / 60).rounded()))
        if minutes < 60 { return "\(minutes) min" }
        return "\(minutes / 60) h \(minutes % 60) min"
    }
}

/// What the Transcript tab says about the transcript itself. A transcript the
/// final pass wrote is Final, with the model that wrote it; a legacy draft
/// keeps its word and its model; a failed or pending one has no words to have
/// come from anywhere, so it names no model.
struct TranscriptStatus: Equatable, Sendable {
    let label: String
    let tone: StatusBadge.Tone
    let model: String?

    static func resolve(_ meta: MeetingMeta) -> TranscriptStatus {
        let status = MeetingStatus.resolve(meta)
        // A meeting saved before provenance was kept has no model to name.
        let model = meta.transcriptProvenance.map(\.modelName).flatMap { $0.isEmpty ? nil : $0 }
        switch status {
        case .summarized, .transcribed:
            // The design draws this one: the accent pill.
            return TranscriptStatus(label: "Final", tone: .accent, model: model)
        case .draft:
            return TranscriptStatus(label: status.label, tone: status.tone, model: model)
        case .failed, .pending:
            return TranscriptStatus(label: status.label, tone: status.tone, model: nil)
        }
    }
}
