//
//  MeetingProperties.swift
//  Workspace
//
//  The facts under a meeting's title, as values, in the order the artboard
//  lists them. Which rows a meeting gets is a rule rather than a rendering
//  detail — a meeting saved before word counts were kept has no Words row,
//  one saved before the capture was recorded has no Capture row — so it is
//  decided here and tested without drawing.
//

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

    /// The rows the Summary tab shows, in order.
    static func rows(for meta: MeetingMeta) -> [MeetingProperty] {
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

    /// A meeting's length as the document writes it: "58 min", "1 h 12 min".
    /// Never "0 min": a meeting that stopped at once still ran.
    static func duration(_ seconds: TimeInterval) -> String {
        let minutes = max(1, Int((seconds / 60).rounded()))
        if minutes < 60 { return "\(minutes) min" }
        return "\(minutes / 60) h \(minutes % 60) min"
    }
}
