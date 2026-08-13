//
//  MeetingActions.swift
//  Echo
//
//  The quick actions that leave the app boundary: Export (a save panel that
//  writes Markdown or plain text), Copy summary (Markdown, to the pasteboard —
//  the share path, offered on the row and in the detail), and Reveal in
//  Finder. Kept out of the view so the list stays about layout, and grouped
//  here because they all turn a loaded `MeetingRecord` (or its folder) into
//  something the rest of the system consumes.
//

import AppKit
import Foundation
import UniformTypeIdentifiers

enum MeetingExportFormat: String, CaseIterable, Identifiable {
    case markdown
    case plainText

    var id: String { rawValue }

    var menuTitle: String {
        switch self {
        case .markdown: return "Markdown (.md)"
        case .plainText: return "Plain Text (.txt)"
        }
    }

    var fileExtension: String {
        switch self {
        case .markdown: return "md"
        case .plainText: return "txt"
        }
    }

    var contentType: UTType {
        switch self {
        case .markdown: return UTType(filenameExtension: "md") ?? .plainText
        case .plainText: return .plainText
        }
    }
}

@MainActor
enum MeetingActions {

    // MARK: - Export

    /// Presents a save panel and writes the record in the chosen format. The
    /// suggested filename is the (sanitized) meeting title. A no-op if the user
    /// cancels.
    static func export(_ record: MeetingRecord, as format: MeetingExportFormat) {
        let panel = NSSavePanel()
        panel.title = "Export Meeting"
        panel.nameFieldStringValue = "\(safeFilename(record.meta.title)).\(format.fileExtension)"
        panel.allowedContentTypes = [format.contentType]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false

        guard panel.runModal() == .OK, let url = panel.url else { return }
        let text = format == .markdown ? markdown(for: record) : plainText(for: record)
        try? Data(text.utf8).write(to: url, options: .atomic)
    }

    // MARK: - Copy summary

    /// Copies the meeting's summary as Markdown — the share format: a title
    /// heading, the meta line, and the same sections the export writes, so the
    /// paste lands formatted in Slack, Notion, Linear or a PR description.
    /// Returns `false` when there is no summary to copy (the caller can keep
    /// the action disabled).
    @discardableResult
    static func copySummary(_ record: MeetingRecord) -> Bool {
        guard let summary = record.summary else { return false }
        copySummary(summary, meta: record.meta)
        return true
    }

    /// The same copy from a summary that is not (yet) a record loaded off disk
    /// — the live detail holds the just-generated one in memory. `meta` is
    /// optional because a session that hasn't persisted yet has none; the
    /// Markdown then simply starts at the summary itself.
    static func copySummary(_ summary: MeetingSummary, meta: MeetingMeta?) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(summaryMarkdown(summary, meta: meta), forType: .string)
    }

    /// A standalone, shareable Markdown document for one summary.
    static func summaryMarkdown(_ summary: MeetingSummary, meta: MeetingMeta?) -> String {
        var lines: [String] = []
        if let meta {
            lines.append("# \(meta.title)")
            lines.append("")
            lines.append("_\(header(for: meta))_")
            lines.append("")
        }
        // Top-level document, so its sections sit one rung higher than the
        // export's (where they nest under "## Summary").
        appendSummary(summary, headingLevel: 2, into: &lines)
        // No trailing newline: this goes to the pasteboard, and one pasted into
        // a chat box is an empty line the sender has to delete.
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Reveal

    static func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    // MARK: - Formatting

    static func markdown(for record: MeetingRecord) -> String {
        var lines: [String] = []
        lines.append("# \(record.meta.title)")
        lines.append("")
        lines.append("_\(header(for: record.meta))_")
        lines.append("")

        if let summary = record.summary {
            lines.append("## Summary")
            lines.append("")
            appendSummary(summary, headingLevel: 3, into: &lines)
        }

        lines.append("## Transcript")
        lines.append("")
        for segment in record.segments {
            lines.append("**\(timestamp(segment.start)) · \(segment.speaker.displayName):** \(segment.text)")
        }
        return lines.joined(separator: "\n")
    }

    static func plainText(for record: MeetingRecord) -> String {
        var lines: [String] = []
        lines.append(record.meta.title)
        lines.append(header(for: record.meta))
        lines.append("")

        if let summary = record.summary {
            lines.append("SUMMARY")
            lines.append(summaryText(summary))
            lines.append("")
        }

        lines.append("TRANSCRIPT")
        for segment in record.segments {
            lines.append("[\(timestamp(segment.start))] \(segment.speaker.displayName): \(segment.text)")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Private helpers

    private static func summaryText(_ summary: MeetingSummary) -> String {
        var lines: [String] = []
        if !summary.shortSummary.isEmpty { lines.append(summary.shortSummary); lines.append("") }
        if !summary.detailedSummary.isEmpty { lines.append(summary.detailedSummary); lines.append("") }
        appendPlainSection("Decisions", summary.decisions.map { bullet($0.title, $0.details) }, into: &lines)
        appendPlainSection("Action Items", summary.actionItems.map { actionItemLine($0) }, into: &lines)
        appendPlainSection("Open Questions", summary.openQuestions.map { bullet($0.question, $0.context) }, into: &lines)
        appendPlainSection("Risks or Blockers", summary.risks.map { bullet($0.risk, $0.details) }, into: &lines)
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The one Markdown rendering of a summary, shared by the export (nested
    /// under "## Summary") and the copy action (a document of its own) — they
    /// differ only in heading depth, never in content.
    private static func appendSummary(_ summary: MeetingSummary, headingLevel: Int, into lines: inout [String]) {
        if !summary.shortSummary.isEmpty { lines.append(summary.shortSummary); lines.append("") }
        if !summary.detailedSummary.isEmpty { lines.append(summary.detailedSummary); lines.append("") }
        let hashes = String(repeating: "#", count: headingLevel)
        appendMarkdownSection(hashes, "Decisions", summary.decisions.map { bullet($0.title, $0.details) }, into: &lines)
        appendMarkdownSection(hashes, "Action Items", summary.actionItems.map { actionItemLine($0) }, into: &lines)
        appendMarkdownSection(hashes, "Open Questions", summary.openQuestions.map { bullet($0.question, $0.context) }, into: &lines)
        appendMarkdownSection(hashes, "Risks or Blockers", summary.risks.map { bullet($0.risk, $0.details) }, into: &lines)
    }

    private static func appendMarkdownSection(_ hashes: String, _ title: String, _ items: [String], into lines: inout [String]) {
        guard !items.isEmpty else { return }
        lines.append("\(hashes) \(title)")
        lines.append("")
        for item in items { lines.append("- \(item)") }
        lines.append("")
    }

    private static func appendPlainSection(_ title: String, _ items: [String], into lines: inout [String]) {
        guard !items.isEmpty else { return }
        lines.append(title.uppercased())
        for item in items { lines.append("• \(item)") }
        lines.append("")
    }

    private static func bullet(_ title: String, _ detail: String?) -> String {
        if let detail, !detail.isEmpty { return "\(title) — \(detail)" }
        return title
    }

    private static func actionItemLine(_ item: SummaryActionItem) -> String {
        var parts = [item.task]
        if let owner = item.owner, !owner.isEmpty { parts.append("Owner: \(owner)") }
        if let due = item.dueDate, !due.isEmpty { parts.append("Due: \(due)") }
        return parts.joined(separator: " · ")
    }

    private static func header(for meta: MeetingMeta) -> String {
        let date = meta.startedAt.formatted(date: .abbreviated, time: .shortened)
        let minutes = max(1, Int((meta.duration / 60).rounded()))
        var parts = [date, "\(minutes) min"]
        if let words = meta.wordCount { parts.append("\(words) words") }
        return parts.joined(separator: " · ")
    }

    private static func timestamp(_ value: TimeInterval) -> String {
        let total = max(0, Int(value))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    /// Strips path separators so the title is a safe default filename.
    private static func safeFilename(_ title: String) -> String {
        let cleaned = title.replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Meeting" : cleaned
    }
}
