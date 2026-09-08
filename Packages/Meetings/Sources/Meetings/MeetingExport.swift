//
//  MeetingExport.swift
//  Meetings
//
//  The text a meeting becomes when it leaves the app: a Markdown or plain-text
//  file, or a standalone Markdown summary for the pasteboard. Pure formatting —
//  the save panel, the pasteboard and Finder live in the UI package that owns
//  those side effects.
//

import EchoCore
import Foundation

public enum MeetingExportFormat: String, CaseIterable, Identifiable, Sendable {
    case markdown
    case plainText

    public var id: String { rawValue }

    public var menuTitle: String {
        switch self {
        case .markdown: return "Markdown (.md)"
        case .plainText: return "Plain Text (.txt)"
        }
    }

    public var fileExtension: String {
        switch self {
        case .markdown: return "md"
        case .plainText: return "txt"
        }
    }
}

public enum MeetingExport {

    /// The record in the chosen format.
    public static func text(for record: MeetingRecord, as format: MeetingExportFormat) -> String {
        switch format {
        case .markdown: return markdown(for: record)
        case .plainText: return plainText(for: record)
        }
    }

    /// A Markdown document: title, meta line, the summary document nested under
    /// "## Summary" (the model's own `###` sections nest naturally), then the
    /// transcript, one bold-prefixed line per segment.
    public static func markdown(for record: MeetingRecord) -> String {
        var lines: [String] = []
        lines.append("# \(record.meta.title)")
        lines.append("")
        lines.append("_\(header(for: record.meta))_")
        lines.append("")

        if let summary = document(record.summaryMarkdown) {
            lines.append("## Summary")
            lines.append("")
            lines.append(summary)
            lines.append("")
        }

        lines.append("## Transcript")
        lines.append("")
        for segment in record.segments {
            lines.append("**\(timestamp(segment.start)) · \(segment.speaker.displayName):** \(segment.text)")
        }
        return lines.joined(separator: "\n")
    }

    /// Plain text: uppercase section names, and the summary as its raw
    /// Markdown — a plain-text "rendering" would just strip structure a text
    /// file shows fine anyway.
    public static func plainText(for record: MeetingRecord) -> String {
        var lines: [String] = []
        lines.append(record.meta.title)
        lines.append(header(for: record.meta))
        lines.append("")

        if let summary = document(record.summaryMarkdown) {
            lines.append("SUMMARY")
            lines.append(summary)
            lines.append("")
        }

        lines.append("TRANSCRIPT")
        for segment in record.segments {
            lines.append("[\(timestamp(segment.start))] \(segment.speaker.displayName): \(segment.text)")
        }
        return lines.joined(separator: "\n")
    }

    /// A standalone, shareable Markdown document for one summary — the share
    /// format: a title heading, the meta line, and the summary document
    /// verbatim, so the paste lands formatted in Slack, Notion, Linear or a PR
    /// description. `meta` is optional because a session that hasn't persisted
    /// yet has none; the Markdown then starts at the summary itself. No
    /// trailing newline: one pasted into a chat box is an empty line the
    /// sender has to delete.
    public static func summaryMarkdown(_ summary: String, meta: MeetingMeta?) -> String {
        var lines: [String] = []
        if let meta {
            lines.append("# \(meta.title)")
            lines.append("")
            lines.append("_\(header(for: meta))_")
            lines.append("")
        }
        if let summary = document(summary) {
            lines.append(summary)
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The meta line: "Aug 26, 2026 at 12:03 · 58 min · 5,512 words".
    public static func header(for meta: MeetingMeta) -> String {
        let date = meta.startedAt.formatted(date: .abbreviated, time: .shortened)
        let minutes = max(1, Int((meta.duration / 60).rounded()))
        var parts = [date, "\(minutes) min"]
        if let words = meta.wordCount { parts.append("\(words) words") }
        return parts.joined(separator: " · ")
    }

    /// "m:ss" for a recording-relative time.
    public static func timestamp(_ value: TimeInterval) -> String {
        let total = max(0, Int(value))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    /// Strips path separators so the title is a safe default filename.
    public static func safeFilename(_ title: String) -> String {
        let cleaned = title.replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Meeting" : cleaned
    }

    private static func document(_ markdown: String?) -> String? {
        guard let markdown else { return nil }
        let trimmed = markdown.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
