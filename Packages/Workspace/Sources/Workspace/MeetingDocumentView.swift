//
//  MeetingDocumentView.swift
//  Workspace
//
//  One meeting as a document: title and meta strip at the top, Copy and Export
//  to the right, two tabs — Summary first, because it is what the user opens a
//  meeting for — and a reading column below.
//

import DesignSystem
import EchoCore
import Meetings
import SwiftUI

struct MeetingDocumentView: View {
    @Environment(MeetingLibrary.self) private var library
    @Environment(WorkspaceModel.self) private var workspace

    let meta: MeetingMeta

    @State private var record: MeetingRecord?
    @State private var loadFailed = false
    @State private var copied = false

    /// Reload when the files behind the document change: a new summary, a
    /// replaced transcript, a rename.
    private struct ReloadKey: Hashable {
        let id: UUID
        let hasSummary: Bool
        let segmentCount: Int
        let title: String
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
        }
        .task(
            id: ReloadKey(id: meta.id, hasSummary: meta.hasSummary, segmentCount: meta.segmentCount, title: meta.title)
        ) {
            loadFailed = false
            if let loaded = await library.loadRecord(meta.id) {
                record = loaded
            } else {
                record = nil
                loadFailed = true
            }
        }
    }

    // MARK: Header

    private var status: MeetingStatus { MeetingStatus.resolve(meta) }

    /// A meeting's length, rounded to the minute the design shows.
    /// Lives here because the document is the only place that says it: the
    /// sidebar row is the title and nothing else.
    static func duration(_ seconds: TimeInterval) -> String {
        let minutes = max(1, Int((seconds / 60).rounded()))
        if minutes < 60 { return "\(minutes) min" }
        return "\(minutes / 60) h \(minutes % 60) min"
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: EchoSpacing.m) {
            HStack(alignment: .firstTextBaseline) {
                Text("Meetings")
                    .font(EchoFont.micro)
                    .foregroundStyle(EchoColor.textTertiary)
                Spacer()
                Button {
                    guard MeetingActions.copySummary(record?.summaryMarkdown, meta: meta) else { return }
                    copied = true
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(.echoQuiet)
                .disabled(record?.summaryMarkdown == nil)
                .help("Copy the summary as Markdown")
                .task(id: copied) {
                    guard copied else { return }
                    try? await Task.sleep(for: .seconds(2))
                    copied = false
                }
                Menu {
                    ForEach(MeetingExportFormat.allCases) { format in
                        Button(format.menuTitle) {
                            if let record { MeetingActions.export(record, as: format) }
                        }
                    }
                    Divider()
                    Button("Reveal in Finder") { MeetingActions.revealInFinder(library.directory(for: meta.id)) }
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .disabled(record == nil)
            }

            Text(meta.title)
                .font(EchoFont.documentTitle)
                .foregroundStyle(EchoColor.textPrimary)
                .lineLimit(2)
                .textSelection(.enabled)

            MetaStrip(metaItems)

            tabs
        }
        .padding(.horizontal, EchoSpacing.xl)
        .padding(.top, EchoSpacing.l)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var metaItems: [MetaItem] {
        var items = [
            MetaItem("calendar", Self.dateRange(meta)),
            MetaItem("clock", Self.duration(meta.duration)),
        ]
        if let words = meta.wordCount, words > 0 {
            items.append(MetaItem("text.word.spacing", "\(words.formatted()) words"))
        }
        if let scope = meta.captureScope?.scopedDisplayLabel {
            items.append(MetaItem("waveform", "\(scope) · mic + system"))
        }
        items.append(MetaItem(status == .summarized ? "checkmark.seal" : "circle.dotted", status.label))
        return items
    }

    private var tabs: some View {
        HStack(spacing: EchoSpacing.l) {
            ForEach(WorkspaceModel.DocumentTab.allCases, id: \.self) { tab in
                Button {
                    workspace.documentTab = tab
                } label: {
                    Text(tab.title)
                        .font(EchoFont.row)
                        .foregroundStyle(workspace.documentTab == tab ? EchoColor.textPrimary : EchoColor.textSecondary)
                        .padding(.vertical, EchoSpacing.s)
                        .overlay(alignment: .bottom) {
                            Rectangle()
                                .fill(workspace.documentTab == tab ? EchoColor.accent : .clear)
                                .frame(height: 2)
                        }
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(.top, EchoSpacing.xs)
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if loadFailed {
            EmptyState(
                symbol: "exclamationmark.triangle",
                title: "This meeting can't be opened",
                message: "Its files are missing or unreadable. Reveal the folder in Finder to inspect them."
            ) {
                Button("Reveal in Finder") { MeetingActions.revealInFinder(library.directory(for: meta.id)) }
                    .buttonStyle(.echoSecondary)
            }
        } else if let record {
            ScrollView {
                Group {
                    switch workspace.documentTab {
                    case .summary: summary(record)
                    case .transcript: transcript(record)
                    }
                }
                .frame(maxWidth: EchoLayout.readingWidth, alignment: .leading)
                .padding(.horizontal, EchoSpacing.xl)
                .padding(.vertical, EchoSpacing.xl)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            Spacer()
        }
    }

    @ViewBuilder
    private func summary(_ record: MeetingRecord) -> some View {
        if let markdown = record.summaryMarkdown, !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            MarkdownView(markdown: markdown)
        } else {
            EmptyState(
                symbol: "text.badge.checkmark",
                title: "No summary yet",
                message: status.isTranscriptReadable
                    ? "The transcript is in. Notes are written once the summary model is available."
                    : "Notes are written from the transcript, once there is one."
            )
        }
    }

    @ViewBuilder
    private func transcript(_ record: MeetingRecord) -> some View {
        if record.segments.isEmpty {
            EmptyState(
                symbol: "text.quote",
                title: status == .failed ? "Transcription failed" : "No transcript yet",
                message: status == .failed
                    ? "The transcription pass did not produce words for this meeting."
                    : "The transcript is written after the recording stops."
            )
        } else {
            TranscriptView(segments: record.segments)
        }
    }

    // MARK: Formatting

    /// "Aug 27, 2026 · 10:04 – 11:02".
    static func dateRange(_ meta: MeetingMeta) -> String {
        let day = meta.startedAt.formatted(date: .abbreviated, time: .omitted)
        let start = meta.startedAt.formatted(date: .omitted, time: .shortened)
        let end = meta.endedAt.formatted(date: .omitted, time: .shortened)
        return "\(day) · \(start) – \(end)"
    }
}

/// The transcript as turns: speaker and timestamp on one line, the paragraph
/// below. You in the accent, Others in grey — the two labels there are.
struct TranscriptView: View {
    let segments: [TranscriptSegment]

    var body: some View {
        let utterances = TranscriptUtterance.derive(from: segments)
        LazyVStack(alignment: .leading, spacing: EchoSpacing.l) {
            ForEach(utterances) { utterance in
                VStack(alignment: .leading, spacing: EchoSpacing.xs) {
                    HStack(spacing: EchoSpacing.s) {
                        Text(utterance.speaker.displayName)
                            .font(EchoFont.row)
                            .foregroundStyle(utterance.speaker == .me ? EchoColor.accent : EchoColor.textSecondary)
                        Text(MeetingExport.timestamp(utterance.start))
                            .font(EchoFont.mono(11.5))
                            .foregroundStyle(EchoColor.textTertiary)
                    }
                    Text(utterance.text)
                        .font(EchoFont.body)
                        .lineSpacing(EchoFont.bodyLineSpacing)
                        .foregroundStyle(EchoColor.textPrimary)
                        .textSelection(.enabled)
                }
            }
        }
    }
}
