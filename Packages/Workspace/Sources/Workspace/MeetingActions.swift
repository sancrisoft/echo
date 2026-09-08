//
//  MeetingActions.swift
//  Workspace
//
//  The actions that leave the app: export through a save panel, copy to the
//  pasteboard, reveal in Finder. The text they write comes from `MeetingExport`
//  in the Meetings package; this file owns only the AppKit side effects.
//

import AppKit
import EchoCore
import Meetings
import UniformTypeIdentifiers

enum MeetingActions {

    /// Presents a save panel and writes the record in the chosen format. The
    /// suggested filename is the sanitized meeting title. A no-op if the user
    /// cancels; a failed write is traced.
    static func export(_ record: MeetingRecord, as format: MeetingExportFormat) {
        let panel = NSSavePanel()
        panel.title = "Export Meeting"
        panel.nameFieldStringValue = "\(MeetingExport.safeFilename(record.meta.title)).\(format.fileExtension)"
        panel.allowedContentTypes = [contentType(for: format)]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false

        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try Data(MeetingExport.text(for: record, as: format).utf8).write(to: url, options: .atomic)
        } catch {
            ErrorTrace.record(
                "Exporting meeting failed",
                error: error,
                category: "MeetingActions",
                metadata: ["meetingID": record.meta.id.uuidString, "format": format.rawValue]
            )
        }
    }

    /// Copies the summary as a standalone Markdown document. Returns `false`
    /// when there is nothing to copy.
    @discardableResult
    static func copySummary(_ markdown: String?, meta: MeetingMeta?) -> Bool {
        guard let markdown, !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(MeetingExport.summaryMarkdown(markdown, meta: meta), forType: .string)
        return true
    }

    static func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private static func contentType(for format: MeetingExportFormat) -> UTType {
        switch format {
        case .markdown: return UTType(filenameExtension: "md") ?? .plainText
        case .plainText: return .plainText
        }
    }
}
