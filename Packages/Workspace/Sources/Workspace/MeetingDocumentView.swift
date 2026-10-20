//
//  MeetingDocumentView.swift
//  Workspace
//
//  One meeting as a document, as `Main.dc.html` draws it: the breadcrumb bar
//  with Copy, Export and the "…" at its end, then a reading column — title,
//  the facts under it as property rows, a rule, the two tabs (Summary first,
//  because it is what the user opens a meeting for) and what the open tab
//  shows. The bar stays put; the column scrolls under it and fades out at the
//  foot of the pane. On the Transcript tab, find sits to the right of the
//  tabs (`TranscriptFind`).
//
//  A meeting with nothing to read — silent, failed, or unreadable — shows
//  why in place of the tabs, centred in what is left of the pane
//  (`MeetingCondition`).
//
//  A trashed meeting, opened from Trash to look at, is the same document
//  under "Trash": its bar offers Restore and Delete… instead, and Escape
//  goes back to the list. Looking never takes it out of Trash.
//

import DesignSystem
import EchoCore
import Meetings
import Recording
import SwiftUI

struct MeetingDocumentView: View {
    @Environment(MeetingLibrary.self) private var library
    @Environment(WorkspaceModel.self) private var workspace
    @Environment(RecordingSession.self) private var session

    let meta: MeetingMeta
    /// Where Show details points: the folder holding Echo's logs.
    let dataRoot: DataRoot

    @State private var record: MeetingRecord?
    @State private var loadFailed = false
    @State private var copied = false
    @State private var renameTarget: MeetingMeta?
    @State private var confirmDeleteForGood = false
    @State private var retranscribeTarget: MeetingMeta?
    @State private var deleteRecordingTarget: MeetingMeta?
    /// The transcript as turns, derived once per load: find searches them
    /// and the Transcript tab draws them.
    @State private var turns: [TranscriptUtterance] = []
    @State private var findQuery = ""
    @State private var currentMatch: Int?
    @FocusState private var findFocused: Bool
    /// The audio the meeting still holds, read with the record: whether its
    /// recording was kept, and whether a failed pass can run again.
    @State private var keepsRecording = false
    @State private var canRetry = false

    /// Reload when the files behind the document change: a new summary, a
    /// replaced transcript, a rename.
    private struct ReloadKey: Hashable {
        let id: UUID
        let hasSummary: Bool
        let segmentCount: Int
        let title: String
        let transcriptSource: TranscriptProvenance.Source?
    }

    var body: some View {
        // Find is the Transcript tab's: on Summary there is nothing to match.
        let matches = workspace.documentTab == .transcript ? TranscriptFind.matches(of: findQuery, in: turns) : []
        VStack(spacing: 0) {
            Breadcrumb(trail: meta.isTrashed ? "Trash" : "Meetings", current: meta.title) {
                if meta.isTrashed { trashedActions } else { actions }
            }
            GeometryReader { viewport in
                ScrollViewReader { proxy in
                    ScrollView {
                        column(matches)
                            .frame(maxWidth: EchoLayout.readingWidth, maxHeight: .infinity, alignment: .topLeading)
                            .padding(.horizontal, EchoSpacing.xl)
                            .padding(.top, EchoLayout.readingTopInset)
                            // Room for the last line to scroll clear of the fade.
                            .padding(.bottom, EchoLayout.documentFadeHeight)
                            // At least the pane's height, so a face with nothing
                            // to read centres in what the header leaves.
                            .frame(maxWidth: .infinity, minHeight: viewport.size.height, alignment: .top)
                    }
                    .overlay(alignment: .bottom) { DocumentFade() }
                    // A new query lands on its first match; ⌘G and Return move
                    // on from there. Either way the turn holding the match comes
                    // into view.
                    .onChange(of: findQuery) { _, _ in
                        currentMatch = matches.isEmpty ? nil : 0
                        reveal(currentMatch, in: matches, proxy)
                    }
                    .onChange(of: currentMatch) { _, index in reveal(index, in: matches, proxy) }
                }
            }
        }
        .background { findShortcuts(matches) }
        .renameMeetingAlert($renameTarget)
        .savedRecordingDialogs(retranscribe: $retranscribeTarget, deleteRecording: $deleteRecordingTarget)
        .confirmationDialog(
            "Delete “\(meta.title)” permanently?", isPresented: $confirmDeleteForGood, titleVisibility: .visible
        ) {
            Button("Delete Permanently", role: .destructive) {
                let id = meta.id
                workspace.closeTrashed()
                Task { await library.deletePermanently(id) }
            }
        } message: {
            Text("Its transcript, notes and any saved recording are removed from this Mac. This cannot be undone.")
        }
        .onChange(of: workspace.documentTab) { _, _ in copied = false }
        .task(
            id: ReloadKey(
                id: meta.id, hasSummary: meta.hasSummary, segmentCount: meta.segmentCount, title: meta.title,
                transcriptSource: meta.transcriptProvenance?.source)
        ) {
            loadFailed = false
            if let loaded = await library.loadRecord(meta.id) {
                record = loaded
                turns = TranscriptUtterance.derive(from: loaded.segments)
            } else {
                record = nil
                turns = []
                loadFailed = true
            }
            keepsRecording = await library.hasPreservedAudio(for: meta.id)
            canRetry = await library.canRetryTranscription(meta.id)
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
                SavedRecordingMenuItems(
                    meta: meta, retranscribe: $retranscribeTarget, deleteRecording: $deleteRecordingTarget)
                if library.keepsRecording(meta.id) { Divider() }
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

    /// What a trashed meeting's bar offers in place of Copy, Export and the
    /// "…" (product owner, 2026-10-20). Escape goes back to Trash's list,
    /// unless it is clearing a find first.
    private var trashedActions: some View {
        HStack(spacing: EchoControl.toolbarButtonGap) {
            Button("Restore") {
                let id = meta.id
                workspace.closeTrashed()
                Task { await library.restore(id) }
            }
            .buttonStyle(.echoQuiet)
            Button("Delete…") { confirmDeleteForGood = true }
                .buttonStyle(.echoQuiet)
        }
        .background {
            Button("") {
                if findFocused || !findQuery.isEmpty {
                    findQuery = ""
                    findFocused = false
                } else {
                    workspace.closeTrashed()
                }
            }
            .keyboardShortcut(.cancelAction)
            .frame(width: 0, height: 0)
            .opacity(0)
            .accessibilityHidden(true)
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

    private var condition: MeetingCondition {
        MeetingCondition.resolve(
            meta, loadFailed: loadFailed, segmentCount: record?.segments.count, keepsRecording: keepsRecording,
            canRetry: canRetry)
    }

    /// A pass for this meeting is queued or running: asking again would only
    /// queue it twice.
    private var isBeingTranscribed: Bool {
        session.queuedMeetingIDs.contains(meta.id) || session.phase.meetingID == meta.id
    }

    /// Each tab has its own facts under the title.
    private var properties: [MeetingProperty] {
        switch workspace.documentTab {
        case .summary: MeetingProperty.summaryRows(for: meta)
        case .transcript: MeetingProperty.transcriptRows(for: meta, segments: record?.segments ?? [])
        }
    }

    private func column(_ matches: [TranscriptMatch]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(meta.title)
                .font(EchoFont.documentTitle)
                .tracking(EchoFont.documentTitleTracking)
                .foregroundStyle(EchoColor.textPrimary)
                .textSelection(.enabled)
                .padding(.bottom, EchoLayout.titleBottomGap)

            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(properties.enumerated()), id: \.offset) { _, property in
                    PropertyView(property: property)
                }
            }

            EchoColor.divider
                .frame(height: EchoLayout.hairline)
                .padding(.top, EchoLayout.documentDividerTop)
                .padding(.bottom, EchoLayout.documentDividerBottom)

            if condition == .readable {
                HStack(spacing: EchoSpacing.m) {
                    tabs
                    Spacer(minLength: 0)
                    if workspace.documentTab == .transcript, !turns.isEmpty {
                        findField(matches)
                    }
                }

                content(matches)
            } else {
                conditionFace
            }
        }
    }

    /// The two tabs and no more, Summary first: the summary is what a past
    /// meeting is opened for, the transcript what is opened when the summary
    /// raised a question.
    private var tabs: some View {
        @Bindable var workspace = workspace
        return TabStrip(WorkspaceModel.DocumentTab.allCases, selection: $workspace.documentTab) { $0.title }
    }

    // MARK: Find

    /// Find in transcript: local to this document, and nothing to do with
    /// the sidebar's search across the library. The placeholder is drawn in
    /// the design's own ink rather than the field's; the field carries the
    /// name for VoiceOver.
    private func findField(_ matches: [TranscriptMatch]) -> some View {
        HStack(spacing: EchoControl.findFieldGap) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: EchoControl.findGlyphSize))
                .foregroundStyle(EchoColor.textQuaternary)
                .accessibilityHidden(true)
            ZStack(alignment: .leading) {
                if findQuery.isEmpty {
                    Text("Find in transcript")
                        .foregroundStyle(EchoColor.textQuaternary)
                        .accessibilityHidden(true)
                }
                TextField("", text: $findQuery)
                    .textFieldStyle(.plain)
                    .foregroundStyle(EchoColor.textPrimary)
                    .accessibilityLabel("Find in transcript")
                    .focused($findFocused)
                    .onSubmit { step(by: 1, count: matches.count) }
                    .onExitCommand {
                        findQuery = ""
                        findFocused = false
                    }
            }
            .font(EchoFont.control)
            .lineLimit(1)
            if !findQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(TranscriptFind.counter(current: currentMatch, count: matches.count))
                    .font(EchoFont.mono(11))
                    .foregroundStyle(EchoColor.textQuaternary)
                    .fixedSize()
            }
        }
        .padding(.horizontal, EchoControl.findFieldInset)
        .frame(width: EchoLayout.findFieldWidth, height: EchoControl.findFieldHeight)
        .overlay {
            RoundedRectangle(cornerRadius: EchoRadius.control)
                .strokeBorder(EchoColor.border, lineWidth: EchoLayout.hairline)
        }
        .contentShape(.rect)
        .onTapGesture { findFocused = true }
    }

    /// ⌘F opens find from either tab, ⌘G and ⇧⌘G step through the matches.
    /// Disabled when there is nothing to do, so the keys fall through.
    private func findShortcuts(_ matches: [TranscriptMatch]) -> some View {
        ZStack {
            Button("") {
                workspace.documentTab = .transcript
                // The field exists once the Transcript tab has drawn.
                Task { findFocused = true }
            }
            .keyboardShortcut("f", modifiers: .command)
            .disabled(turns.isEmpty)
            Button("") { step(by: 1, count: matches.count) }
                .keyboardShortcut("g", modifiers: .command)
                .disabled(matches.isEmpty)
            Button("") { step(by: -1, count: matches.count) }
                .keyboardShortcut("g", modifiers: [.command, .shift])
                .disabled(matches.isEmpty)
        }
        .frame(width: 0, height: 0)
        .opacity(0)
        .accessibilityHidden(true)
    }

    private func step(by offset: Int, count: Int) {
        currentMatch = TranscriptFind.step(from: currentMatch, by: offset, count: count)
    }

    private func reveal(_ index: Int?, in matches: [TranscriptMatch], _ proxy: ScrollViewProxy) {
        guard let index, matches.indices.contains(index) else { return }
        proxy.scrollTo(matches[index].turn, anchor: .center)
    }

    // MARK: Nothing to read

    /// The meeting-wide faces of the empty-states artboard, each with the one
    /// action that gets out of it.
    @ViewBuilder
    private var conditionFace: some View {
        switch condition {
        case .readable:
            EmptyView()
        case .silent(let duration, let canRetranscribe):
            EmptyState(
                glyph: .lines, title: "Nothing was said",
                message: MeetingCondition.silentMessage(duration: duration, canRetranscribe: canRetranscribe)
            ) {
                Button("Re-transcribe") { Task { await session.retranscribe(meta.id) } }
                    .buttonStyle(.echoControl)
                    .disabled(!canRetranscribe || isBeingTranscribed)
            }
        case .failed(let canRetry):
            EmptyState(
                glyph: .warning, title: "Transcription failed",
                message: MeetingCondition.failedMessage(canRetry: canRetry)
            ) {
                Button("Re-transcribe") { session.retryTranscription(meta.id) }
                    .buttonStyle(.echoControlProminent)
                    .disabled(!canRetry || isBeingTranscribed)
                // No reason is kept per meeting; the log is where one is
                // (product owner, 2026-10-20).
                Button("Show details") { MeetingActions.revealLogs(of: dataRoot) }
                    .buttonStyle(.echoControl)
            }
        case .unreadable:
            EmptyState(
                glyph: .missingFolder, title: "This meeting can't be opened",
                message:
                    "Its files are missing or unreadable. Nothing was uploaded anywhere, so the folder on this Mac is the only copy."
            ) {
                Button("Reveal in Finder") { MeetingActions.revealInFinder(library.directory(for: meta.id)) }
                    .buttonStyle(.echoControl)
            }
        }
    }

    // MARK: Content

    @ViewBuilder
    private func content(_ matches: [TranscriptMatch]) -> some View {
        if let record {
            switch workspace.documentTab {
            case .summary: summary(record).padding(.top, EchoLayout.summaryTopGap)
            case .transcript: transcript(record, matches: matches).padding(.top, EchoLayout.transcriptTopGap)
            }
        }
    }

    @ViewBuilder
    private func summary(_ record: MeetingRecord) -> some View {
        if let markdown = record.summaryMarkdown, !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            MarkdownView(markdown: markdown)
        } else {
            EmptyState(
                glyph: .lines,
                title: "No summary yet",
                message: status.isTranscriptReadable
                    ? "The transcript is in. Notes are written once the summary model is available."
                    : "Notes are written from the transcript, once there is one."
            )
        }
    }

    @ViewBuilder
    private func transcript(_ record: MeetingRecord, matches: [TranscriptMatch]) -> some View {
        if record.segments.isEmpty {
            EmptyState(
                glyph: .lines, title: "No transcript yet",
                message: "The transcript is written after the recording stops.")
        } else {
            TranscriptView(turns: turns, matches: matches, current: currentMatch)
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
        case .speakers(let split):
            PropertyRow(symbol: "waveform.path.ecg", label: "Speakers") {
                HStack(spacing: EchoControl.speakerSplitLabelGap) {
                    SpeakerSplitBar(youShare: split.youShare)
                        .frame(width: EchoLayout.speakerSplitWidth, height: EchoControl.speakerSplitHeight)
                        .accessibilityHidden(true)
                    Text("You \(split.youPercent)%")
                        .foregroundStyle(EchoColor.accent)
                    Text("Others \(split.othersPercent)%")
                        .foregroundStyle(EchoColor.textTertiary)
                }
                .font(EchoFont.control)
            }
        case .transcript(let transcript):
            PropertyRow(symbol: "checkmark.circle", label: "Status") {
                HStack(spacing: EchoControl.provenanceGap) {
                    StatusBadge(transcript.label, tone: transcript.tone)
                    if let model = transcript.model {
                        Text(model)
                            .font(EchoFont.provenance)
                            .foregroundStyle(EchoColor.textQuaternary)
                            .lineLimit(1)
                    }
                }
            }
        }
    }
}

/// You's share in the accent and Others' after it, a hairline gap between
/// them. A share of nothing is no segment at all, and takes no gap with it.
private struct SpeakerSplitBar: View {
    let youShare: Double

    var body: some View {
        GeometryReader { proxy in
            let both = youShare > 0 && youShare < 1
            let room = proxy.size.width - (both ? EchoControl.speakerSplitGap : 0)
            HStack(spacing: both ? EchoControl.speakerSplitGap : 0) {
                if youShare > 0 {
                    EchoColor.accent.frame(width: room * youShare)
                }
                if youShare < 1 {
                    EchoColor.speakerSplitOthers.frame(width: room * (1 - youShare))
                }
            }
        }
        .clipShape(.rect(cornerRadius: EchoRadius.speakerSplit))
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
