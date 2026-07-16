//
//  MeetingActions.swift
//  Echo
//
//  The row quick actions that leave the app boundary: Export (a save panel that
//  writes Markdown or plain text), Copy summary (to the pasteboard), and Reveal
//  in Finder. Kept out of the view so the list stays about layout, and grouped
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

    /// Copies the meeting's summary as plain text. Returns `false` when there is
    /// no summary to copy (the caller can keep the action disabled).
    @discardableResult
    static func copySummary(_ record: MeetingRecord) -> Bool {
        guard let summary = record.summary else { return false }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(summaryText(summary), forType: .string)
        return true
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
            if !summary.shortSummary.isEmpty { lines.append(summary.shortSummary); lines.append("") }
            if !summary.detailedSummary.isEmpty { lines.append(summary.detailedSummary); lines.append("") }
            appendMarkdownSection("Decisions", summary.decisions.map { bullet($0.title, $0.details) }, into: &lines)
            appendMarkdownSection("Action Items", summary.actionItems.map { actionItemLine($0) }, into: &lines)
            appendMarkdownSection("Open Questions", summary.openQuestions.map { bullet($0.question, $0.context) }, into: &lines)
            appendMarkdownSection("Risks or Blockers", summary.risks.map { bullet($0.risk, $0.details) }, into: &lines)
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

    private static func appendMarkdownSection(_ title: String, _ items: [String], into lines: inout [String]) {
        guard !items.isEmpty else { return }
        lines.append("### \(title)")
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
