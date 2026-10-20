//
//  MeetingDocumentView.swift
//  Workspace
//
//  One meeting as a document, as `Main.dc.html` draws it: the breadcrumb bar
//  with Copy, Export and the "…" at its end, then a reading column — title,
//  the facts under it as property rows, a rule, the two tabs (Summary first,
//  because it is what the user opens a meeting for) and what the open tab
//  shows. The bar stays put; the column scrolls under it and fades out at the
//  foot of the pane.
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
    @State private var renameTarget: MeetingMeta?

    /// Reload when the files behind the document change: a new summary, a
    /// replaced transcript, a rename.
    private struct ReloadKey: Hashable {
        let id: UUID
        let hasSummary: Bool
        let segmentCount: Int
        let title: String
    }

    var body: some View {
        VStack(spacing: 0) {
            Breadcrumb(trail: "Meetings", current: meta.title) { actions }
            ScrollView {
                column
                    .frame(maxWidth: EchoLayout.readingWidth, alignment: .leading)
                    .padding(.horizontal, EchoSpacing.xl)
                    .padding(.top, EchoLayout.readingTopInset)
                    // Room for the last line to scroll clear of the fade.
                    .padding(.bottom, EchoLayout.documentFadeHeight)
                    .frame(maxWidth: .infinity)
            }
            .overlay(alignment: .bottom) { DocumentFade() }
        }
        .renameMeetingAlert($renameTarget)
        .onChange(of: workspace.documentTab) { _, _ in copied = false }
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

    // MARK: The bar

    private var actions: some View {
        HStack(spacing: EchoControl.toolbarButtonGap) {
            Button(copied ? "Copied" : "Copy") {
                guard copy() else { return }
                copied = true
            }
            .buttonStyle(.echoQuiet)
            .disabled(!canCopy)
            .help(
                workspace.documentTab == .summary ? "Copy the summary as Markdown" : "Copy the transcript as Markdown"
            )
            .task(id: copied) {
                guard copied else { return }
                try? await Task.sleep(for: .seconds(2))
                copied = false
            }

            Menu("Export") {
                ForEach(MeetingExportFormat.allCases) { format in
                    Button(format.menuTitle) {
                        if let record { MeetingActions.export(record, as: format) }
                    }
                }
            }
            .menuStyle(.button)
            .buttonStyle(.echoQuiet)
            .menuIndicator(.hidden)
            .disabled(record == nil)

            // The row's own actions that Copy and Export do not already hold
            // (product owner, 2026-10-20): the artboard draws the button and
            // not what it opens.
            Menu {
                Button("Rename…") { renameTarget = meta }
                Button("Reveal in Finder") { MeetingActions.revealInFinder(library.directory(for: meta.id)) }
                Divider()
                Button("Move to Trash", role: .destructive) { trash() }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: EchoControl.toolbarGlyphSize))
            }
            .menuStyle(.button)
            .buttonStyle(.echoQuietIcon)
            .menuIndicator(.hidden)
            .accessibilityLabel("More")
        }
    }

    /// Copy copies what the open tab shows (product owner, 2026-10-20).
    private var canCopy: Bool {
        guard let record else { return false }
        switch workspace.documentTab {
        case .summary:
            return record.summaryMarkdown?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        case .transcript:
            return !record.segments.isEmpty
        }
    }

    private func copy() -> Bool {
        guard let record else { return false }
        switch workspace.documentTab {
        case .summary: return MeetingActions.copySummary(record.summaryMarkdown, meta: meta)
        case .transcript: return MeetingActions.copyTranscript(record)
        }
    }

    private func trash() {
        // Re-home the selection before the meeting leaves, as the sidebar
        // does, so the window opens on its neighbour rather than on nothing.
        workspace.selectionAfterRemoving(meta.id, in: library.metas)
        Task { await library.trash(meta.id) }
    }

    // MARK: The column

    private var status: MeetingStatus { MeetingStatus.resolve(meta) }

    private var column: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(meta.title)
                .font(EchoFont.documentTitle)
                .tracking(EchoFont.documentTitleTracking)
                .foregroundStyle(EchoColor.textPrimary)
                .textSelection(.enabled)
                .padding(.bottom, EchoLayout.titleBottomGap)

            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(MeetingProperty.rows(for: meta).enumerated()), id: \.offset) { _, property in
                    PropertyView(property: property)
                }
            }

            EchoColor.divider
                .frame(height: EchoLayout.hairline)
                .padding(.top, EchoLayout.documentDividerTop)
                .padding(.bottom, EchoLayout.documentDividerBottom)

            tabs

            content
        }
    }

    /// The two tabs and no more, Summary first: the summary is what a past
    /// meeting is opened for, the transcript what is opened when the summary
    /// raised a question.
    private var tabs: some View {
        @Bindable var workspace = workspace
        return TabStrip(WorkspaceModel.DocumentTab.allCases, selection: $workspace.documentTab) { $0.title }
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
            switch workspace.documentTab {
            case .summary: summary(record).padding(.top, EchoLayout.summaryTopGap)
            case .transcript: transcript(record).padding(.top, EchoLayout.transcriptTopGap)
            }
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
}

/// One fact under the title, drawn as the artboard draws it: numbers in the
/// monospaced face, the capture with its quieter qualifier, the status as a
/// pill.
private struct PropertyView: View {
    let property: MeetingProperty

    var body: some View {
        switch property {
        case .date(let start, let end):
            PropertyRow(symbol: "calendar", label: "Date") {
                let day = start.formatted(date: .abbreviated, time: .omitted)
                let span =
                    "\(start.formatted(date: .omitted, time: .shortened)) – \(end.formatted(date: .omitted, time: .shortened))"
                Text("\(day) · \(Text(span).font(EchoFont.mono()))")
            }
        case .duration(let seconds):
            PropertyRow(symbol: "clock", label: "Duration", MeetingProperty.duration(seconds))
        case .words(let words):
            PropertyRow(symbol: "text.alignleft", label: "Words") {
                Text(words.formatted()).font(EchoFont.mono())
            }
        case .capture(let capture):
            PropertyRow(symbol: "display", label: "Capture") {
                HStack(spacing: EchoControl.propertyQualifierGap) {
                    Text(capture)
                    // Both channels, always, kept apart: that is how the
                    // transcript knows who spoke.
                    Text("· mic + system")
                        .font(EchoFont.propertyQualifier)
                        .foregroundStyle(EchoColor.textTertiary)
                }
            }
        case .status(let status):
            PropertyRow(symbol: "checkmark.circle", label: "Status") {
                StatusBadge(status.label, tone: status.tone)
            }
        }
    }
}

/// The fade at the foot of a scrolling document: the pane's own background
/// coming up over the text, so the column ends softly instead of at a cut.
private struct DocumentFade: View {
    var body: some View {
        LinearGradient(
            colors: [EchoColor.windowBackground.opacity(0), EchoColor.windowBackground],
            startPoint: .top, endPoint: .bottom
        )
        .frame(height: EchoLayout.documentFadeHeight)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
