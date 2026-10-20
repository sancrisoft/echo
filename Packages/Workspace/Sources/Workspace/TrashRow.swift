//
//  TrashRow.swift
//  Workspace
//
//  What one Trash row says, as values: the line under its title, and the
//  days it has left of the thirty before it is removed for good, the last
//  few in red. Tested without drawing.
//

import Foundation
import Meetings

enum TrashRow {

    /// The line under a trashed meeting's title: its day, how long it ran,
    /// and its words — or that it has no summary, which is the first thing
    /// someone deciding whether to keep it wants to know.
    struct Caption: Equatable, Sendable {
        let day: String
        let duration: String
        let detail: Detail?

        enum Detail: Equatable, Sendable {
            case words(Int)
            case noSummary
        }
    }

    static func caption(_ meta: MeetingMeta) -> Caption {
        let detail: Caption.Detail? =
            if !meta.hasSummary {
                .noSummary
            } else if let words = meta.wordCount, words > 0 {
                .words(words)
            } else {
                nil
            }
        return Caption(
            day: meta.startedAt.formatted(date: .abbreviated, time: .omitted),
            duration: MeetingProperty.duration(meta.duration),
            detail: detail)
    }

    /// Whole days until the meeting is removed for good, counting a part of
    /// a day as a day — "1 day left" until the moment it goes. Never below 0.
    static func daysLeft(trashedAt: Date, now: Date = .now) -> Int {
        let remaining = trashedAt.addingTimeInterval(MeetingLibrary.trashRetention).timeIntervalSince(now)
        return max(0, Int((remaining / 86_400).rounded(.up)))
    }

    static func daysLeftText(_ days: Int) -> String {
        days == 1 ? "1 day left" : "\(days) days left"
    }

    /// The last days, which the row writes in red (product owner,
    /// 2026-10-20: three or fewer).
    static func isExpiring(_ days: Int) -> Bool { days <= 3 }
}
