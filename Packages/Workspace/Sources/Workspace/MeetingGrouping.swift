//
//  MeetingGrouping.swift
//  Workspace
//
//  How the sidebar orders, filters and groups the library. Pure functions over
//  `MeetingMeta`, kept out of the views so they are testable and so the two
//  lists that show meetings (library, trash) cannot drift.
//

import Foundation
import Meetings

/// The sidebar's sort orders. Only the two chronological orders group by date;
/// a list sorted by name or length reads as one section.
public enum MeetingSortOrder: String, CaseIterable, Identifiable, Sendable {
    case recent
    case oldest
    case name
    case longest

    public var id: String { rawValue }

    public var menuTitle: String {
        switch self {
        case .recent: return "Most Recent"
        case .oldest: return "Oldest First"
        case .name: return "Name"
        case .longest: return "Longest"
        }
    }

    public var groupsByDate: Bool {
        switch self {
        case .recent, .oldest: return true
        case .name, .longest: return false
        }
    }
}

public enum MeetingFilter {

    /// Filters by title, caption and formatted date (case-insensitive), then
    /// sorts. Transcript and summary text are not searched here; that is a
    /// content index's job.
    public static func apply(to metas: [MeetingMeta], search: String, sort: MeetingSortOrder) -> [MeetingMeta] {
        let needle = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered =
            needle.isEmpty
            ? metas
            : metas.filter { meta in
                meta.title.localizedCaseInsensitiveContains(needle)
                    || (meta.oneLineDescription?.localizedCaseInsensitiveContains(needle) ?? false)
                    || meta.startedAt.formatted(date: .abbreviated, time: .omitted)
                        .localizedCaseInsensitiveContains(needle)
            }
        switch sort {
        case .recent: return filtered.sorted { $0.startedAt > $1.startedAt }
        case .oldest: return filtered.sorted { $0.startedAt < $1.startedAt }
        case .name: return filtered.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        case .longest: return filtered.sorted { $0.duration > $1.duration }
        }
    }
}

/// A date bucket in the sidebar: Today, Yesterday, the last seven days, then
/// one group per month.
public struct MeetingDateGroup: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let meetings: [MeetingMeta]

    /// Buckets `metas` (already in display order) by `startedAt`, preserving
    /// order inside each bucket. When the order is not chronological, one
    /// untitled group holds everything.
    public static func groups(
        for metas: [MeetingMeta],
        sort: MeetingSortOrder,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [MeetingDateGroup] {
        guard sort.groupsByDate else {
            return metas.isEmpty ? [] : [MeetingDateGroup(id: "all", title: "", meetings: metas)]
        }
        var ordered: [(key: String, title: String, meetings: [MeetingMeta])] = []
        var index: [String: Int] = [:]
        for meta in metas {
            let (key, title) = bucket(for: meta.startedAt, now: now, calendar: calendar)
            if let position = index[key] {
                ordered[position].meetings.append(meta)
            } else {
                index[key] = ordered.count
                ordered.append((key, title, [meta]))
            }
        }
        return ordered.map { MeetingDateGroup(id: $0.key, title: $0.title, meetings: $0.meetings) }
    }

    private static func bucket(for date: Date, now: Date, calendar: Calendar) -> (key: String, title: String) {
        if calendar.isDate(date, inSameDayAs: now) { return ("today", "Today") }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
            calendar.isDate(date, inSameDayAs: yesterday)
        {
            return ("yesterday", "Yesterday")
        }
        if let weekAgo = calendar.date(byAdding: .day, value: -7, to: calendar.startOfDay(for: now)), date >= weekAgo,
            date < now
        {
            return ("week", "Last 7 days")
        }
        let components = calendar.dateComponents([.year, .month], from: date)
        let key = "\(components.year ?? 0)-\(components.month ?? 0)"
        let title = date.formatted(.dateTime.month(.wide).year())
        return (key, title)
    }
}
