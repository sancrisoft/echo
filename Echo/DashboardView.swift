//
//  DashboardView.swift
//  Echo
//
//  The full window opened from "Open dashboard" (and shown automatically when a
//  recording stops). A NavigationSplitView (SPEC-03): a sidebar with the "Live"
//  session (while recording) and the persistent meeting history, and a detail
//  pane with the Transcript/Summary tabs. The live session shows `controller.state`
//  directly; a past meeting loads its saved `MeetingRecord` read-only.
//

import SwiftUI

private enum DetailTab: Hashable { case transcript, summary, ask }

struct DashboardView: View {
    @Environment(RecordingController.self) private var controller

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            NavigationSplitView {
                MeetingSidebar()
            } detail: {
                MeetingDetailContainer()
            }
        }
        .frame(minWidth: 720, minHeight: 460)
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 12) {
            Image(systemName: "waveform")
                .foregroundStyle(.tint)
            Text("Echo")
                .font(.title3.bold())

            Spacer()

            if let notice = controller.state.echoNotice {
                Label(notice, systemImage: "waveform.badge.exclamationmark")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let notice = controller.state.inputNotice {
                Label(notice, systemImage: "mic.slash")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Input-health notices (SP-002 "no silent dropout"), rendered
            // alongside — never replacing — the device-lost notice.
            if let notice = controller.state.micHealthNotice {
                Label(notice, systemImage: "waveform.badge.exclamationmark")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let notice = controller.state.systemHealthNotice {
                Label(notice, systemImage: "speaker.badge.exclamationmark")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if controller.state.isRecording {
                Label("Recording", systemImage: "circle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .labelStyle(.titleAndIcon)
            }

            Button {
                Task { await controller.toggle() }
            } label: {
                Label(
                    controller.state.isRecording ? "Stop" : "Start recording",
                    systemImage: controller.state.isRecording ? "stop.fill" : "record.circle"
                )
            }
            .buttonStyle(.borderedProminent)
            .tint(controller.state.isRecording ? .red : .accentColor)
        }
        .padding()
    }

}

// MARK: - Sidebar

private struct MeetingSidebar: View {
    @Environment(RecordingController.self) private var controller
    @State private var pendingDelete: MeetingMeta?

    var body: some View {
        @Bindable var library = controller.library

        List(selection: $library.selection) {
            if controller.state.isRecording {
                LiveSidebarRow()
                    .tag(MeetingSelection.live)
            }

            Section("History") {
                if library.metas.isEmpty {
                    Text("No saved meetings yet.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(library.metas) { meta in
                        MeetingSidebarRow(meta: meta)
                            .tag(MeetingSelection.meeting(meta.id))
                            .contextMenu {
                                Button(role: .destructive) {
                                    pendingDelete = meta
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                    }
                }
            }
        }
        .navigationTitle("Meetings")
        .frame(minWidth: 220)
        .confirmationDialog(
            "Delete this meeting?",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            presenting: pendingDelete
        ) { meta in
            Button("Delete", role: .destructive) {
                Task { await controller.library.delete(meta.id) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { meta in
            Text("“\(meta.title)” and its transcript and summary will be permanently deleted.")
        }
    }
}

private struct LiveSidebarRow: View {
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "record.circle")
                .foregroundStyle(.red)
            VStack(alignment: .leading, spacing: 2) {
                Text("Live")
                    .font(.body.weight(.semibold))
                Text("Recording in progress")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

private struct MeetingSidebarRow: View {
    let meta: MeetingMeta

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(meta.title)
                .font(.body.weight(.medium))
                .lineLimit(1)
            HStack(spacing: 6) {
                Text(Self.durationText(meta.duration))
                if meta.hasSummary {
                    Image(systemName: "sparkles")
                }
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    private static func durationText(_ duration: TimeInterval) -> String {
        let total = max(0, Int(duration.rounded()))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
            : String(format: "%d:%02d", minutes, seconds)
    }
}

// MARK: - Detail

/// Routes the detail pane between the live session and a saved meeting. The
/// just-stopped meeting keeps showing the live state (so its summary streams in
/// without a jump) until the next recording clears `activeMeetingID`.
private struct MeetingDetailContainer: View {
    @Environment(RecordingController.self) private var controller
    @State private var selectedTab: DetailTab = .transcript

    var body: some View {
        let library = controller.library
        switch library.selection {
        case .live, nil:
            LiveMeetingDetail(selectedTab: $selectedTab)
        case .meeting(let id):
            if id == library.activeMeetingID {
                LiveMeetingDetail(selectedTab: $selectedTab)
            } else {
                PastMeetingDetail(id: id, selectedTab: $selectedTab)
                    .id(id)
            }
        }
    }
}

/// The current session (or empty idle state): transcript with live partials and
/// the streaming/regenerable summary over `controller.state`.
private struct LiveMeetingDetail: View {
    @Environment(RecordingController.self) private var controller
    @Binding var selectedTab: DetailTab

    var body: some View {
        TabView(selection: $selectedTab) {
            TranscriptScroll(rows: transcriptRows, isRecording: controller.state.isRecording)
                .tabItem { Label("Transcript", systemImage: "text.bubble") }
                .tag(DetailTab.transcript)
            summary
                .tabItem { Label("Summary", systemImage: "sparkles") }
                .tag(DetailTab.summary)
            AskUnavailableView(
                message: controller.state.isRecording
                    ? "Available when the recording ends."
                    : "Ask is available for saved meetings."
            )
            .tabItem { Label("Ask", systemImage: "questionmark.bubble") }
            .tag(DetailTab.ask)
        }
        .padding(.top, 8)
    }

    private var transcriptRows: [TranscriptDisplayRow] {
        let finalRows = controller.state.segments.map {
            TranscriptDisplayRow(segment: $0, isPartial: false)
        }
        let partialRows = controller.state.partialSegments.values.map {
            TranscriptDisplayRow(segment: $0, isPartial: true)
        }

        return (finalRows + partialRows).sorted {
            if $0.segment.start == $1.segment.start {
                return !$0.isPartial && $1.isPartial
            }
            return $0.segment.start < $1.segment.start
        }
    }

    @ViewBuilder
    private var summary: some View {
        switch controller.state.summaryState {
        case .idle:
            VStack(spacing: 18) {
                ContentUnavailableView(
                    controller.state.isRecording ? "Summary after recording" : "No summary yet",
                    systemImage: "sparkles",
                    description: Text(controller.state.isRecording
                        ? "Echo will generate this once the recording stops."
                        : "Start and stop a recording to generate meeting notes.")
                )
                summaryModelControl
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .generating:
            VStack(spacing: 12) {
                ProgressView()
                    .controlSize(.large)
                Text("Generating summary…")
                    .font(.headline)
                Text("Gemma is reading the final transcript locally.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .streaming(let meetingSummary):
            SummaryContentView(summary: meetingSummary, segments: controller.state.segments, isStreaming: true)

        case .ready(let meetingSummary):
            SummaryContentView(summary: meetingSummary, segments: controller.state.segments)

        case .unavailable(let message):
            ContentUnavailableView(
                message,
                systemImage: "text.badge.xmark",
                description: Text("There is no final transcript to summarize.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .failed(let message):
            VStack(spacing: 18) {
                ContentUnavailableView(
                    "Summary failed",
                    systemImage: "exclamationmark.triangle",
                    description: Text(message)
                )
                summaryModelControl
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var summaryModelControl: some View {
        HStack(spacing: 10) {
            Image(systemName: "cpu")
                .foregroundStyle(.secondary)
            Text(summaryModelDescription)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 300, alignment: .leading)

            if showsDownloadButton {
                Button {
                    Task { await controller.downloadSummaryModel() }
                } label: {
                    Label("Download model", systemImage: "arrow.down.circle")
                }
                .buttonStyle(.bordered)
                .disabled(controller.summaryModelState.isBusy)
            }

            if canRetrySummary {
                Button {
                    Task { await controller.retrySummary() }
                } label: {
                    Label("Retry", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderedProminent)
                .disabled(controller.summaryModelState.isBusy)
            }
        }
        .padding(.horizontal)
    }

    private var summaryModelDescription: String {
        switch controller.summaryModelState {
        case .notDownloaded:
            return "Summary model not downloaded"
        case .downloading(let fraction):
            return "Downloading summary model… \(Int(fraction * 100))%"
        case .loading:
            return "Loading summary model…"
        case .ready:
            return "Summary model ready · \(SummaryModelManager.modelDisplaySize)"
        case .failed(let message):
            return message
        }
    }

    private var showsDownloadButton: Bool {
        switch controller.summaryModelState {
        case .notDownloaded, .failed, .downloading:
            return true
        case .loading, .ready:
            return false
        }
    }

    private var canRetrySummary: Bool {
        !controller.state.isRecording && !controller.state.segments.isEmpty
    }
}

/// A saved meeting, read-only. Loads its `MeetingRecord` off the main thread
/// (the actor decodes) and shows the same transcript/summary views — no live
/// partials, and a fixed summary (or an "unavailable" state).
private struct PastMeetingDetail: View {
    let id: UUID
    @Binding var selectedTab: DetailTab
    @Environment(RecordingController.self) private var controller

    @State private var record: MeetingRecord?
    @State private var isLoading = true

    var body: some View {
        Group {
            if let record {
                TabView(selection: $selectedTab) {
                    TranscriptScroll(rows: rows(for: record), isRecording: false)
                        .tabItem { Label("Transcript", systemImage: "text.bubble") }
                        .tag(DetailTab.transcript)
                    summary(for: record)
                        .tabItem { Label("Summary", systemImage: "sparkles") }
                        .tag(DetailTab.summary)
                    AskView(meetingID: id)
                        .tabItem { Label("Ask", systemImage: "questionmark.bubble") }
                        .tag(DetailTab.ask)
                }
                .padding(.top, 8)
            } else if isLoading {
                ProgressView()
                    .controlSize(.large)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView(
                    "Couldn't open this meeting",
                    systemImage: "exclamationmark.triangle",
                    description: Text("Its files may be missing or corrupted.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: id) {
            isLoading = true
            record = await controller.library.loadRecord(id)
            isLoading = false
        }
    }

    private func rows(for record: MeetingRecord) -> [TranscriptDisplayRow] {
        record.segments.map { TranscriptDisplayRow(segment: $0, isPartial: false) }
    }

    @ViewBuilder
    private func summary(for record: MeetingRecord) -> some View {
        if let summary = record.summary {
            SummaryContentView(summary: summary, segments: record.segments)
        } else {
            ContentUnavailableView(
                "No summary",
                systemImage: "sparkles",
                description: Text("No summary was generated for this meeting.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: - Shared transcript list

private struct TranscriptScroll: View {
    let rows: [TranscriptDisplayRow]
    let isRecording: Bool

    var body: some View {
        if rows.isEmpty {
            ContentUnavailableView(
                isRecording ? "Listening…" : "No transcript",
                systemImage: "text.bubble",
                description: Text(isRecording
                    ? "Text will appear here as people speak."
                    : "This meeting has no transcript.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(rows) { row in
                        SegmentRow(segment: row.segment, isPartial: row.isPartial)
                    }
                }
                .padding()
            }
        }
    }
}

private struct TranscriptDisplayRow: Identifiable {
    let segment: TranscriptSegment
    let isPartial: Bool

    var id: String {
        isPartial ? "partial-\(segment.channel.rawValue)" : segment.id.uuidString
    }
}

private struct SegmentRow: View {
    let segment: TranscriptSegment
    var isPartial = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(isPartial ? accent.opacity(0.45) : accent)
                .frame(width: 8, height: 8)
                .padding(.top, 6)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(segment.speaker.displayName)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(accent)
                    Text(isPartial ? "Live" : timestamp)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Text(segment.text)
                    .font(.body)
                    .foregroundStyle(isPartial ? .secondary : .primary)
                    .opacity(isPartial ? 0.78 : 1)
                    .textSelection(.enabled)
            }
        }
    }

    private var accent: Color {
        segment.channel == .microphone ? .blue : .purple
    }

    private var timestamp: String {
        let total = Int(segment.start)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

private struct SummaryContentView: View {
    let summary: MeetingSummary
    let segments: [TranscriptSegment]
    var isStreaming: Bool = false

    private var segmentByID: [String: TranscriptSegment] {
        Dictionary(uniqueKeysWithValues: segments.map { ($0.id.uuidString.lowercased(), $0) })
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if isStreaming {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Generating summary…")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }

                // While streaming, only reveal blocks once they have content so
                // the layout fills in instead of flashing placeholders.
                if !isStreaming || !summary.shortSummary.isEmpty {
                    SummaryTextBlock(
                        title: "Short summary",
                        systemImage: "text.line.first.and.arrowtriangle.forward",
                        text: summary.shortSummary
                    )
                }

                if !isStreaming || !summary.detailedSummary.isEmpty {
                    SummaryTextBlock(
                        title: "Detailed summary",
                        systemImage: "doc.text",
                        text: summary.detailedSummary
                    )
                }

                if !isStreaming || !summary.decisions.isEmpty { decisionsSection }
                if !isStreaming || !summary.actionItems.isEmpty { actionItemsSection }
                if !isStreaming || !summary.openQuestions.isEmpty { openQuestionsSection }
                if !isStreaming || !summary.risks.isEmpty { risksSection }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var decisionsSection: some View {
        SummarySection(title: "Decisions", systemImage: "checkmark.seal") {
            if summary.decisions.isEmpty {
                EmptySummaryRow(text: "No decisions captured.")
            } else {
                ForEach(summary.decisions.indices, id: \.self) { index in
                    let decision = summary.decisions[index]
                    SummaryItemRow(
                        title: decision.title,
                        detail: decision.details,
                        metadata: evidenceText(decision.evidenceSegmentIDs)
                    )
                }
            }
        }
    }

    private var actionItemsSection: some View {
        SummarySection(title: "Action items", systemImage: "checklist") {
            if summary.actionItems.isEmpty {
                EmptySummaryRow(text: "No action items captured.")
            } else {
                ForEach(summary.actionItems.indices, id: \.self) { index in
                    let item = summary.actionItems[index]
                    SummaryItemRow(
                        title: item.task,
                        detail: actionItemDetail(item),
                        metadata: evidenceText(item.evidenceSegmentIDs)
                    )
                }
            }
        }
    }

    private var openQuestionsSection: some View {
        SummarySection(title: "Open questions", systemImage: "questionmark.circle") {
            if summary.openQuestions.isEmpty {
                EmptySummaryRow(text: "No open questions captured.")
            } else {
                ForEach(summary.openQuestions.indices, id: \.self) { index in
                    let question = summary.openQuestions[index]
                    SummaryItemRow(
                        title: question.question,
                        detail: question.context,
                        metadata: evidenceText(question.evidenceSegmentIDs)
                    )
                }
            }
        }
    }

    private var risksSection: some View {
        SummarySection(title: "Risks or blockers", systemImage: "exclamationmark.triangle") {
            if summary.risks.isEmpty {
                EmptySummaryRow(text: "No risks or blockers captured.")
            } else {
                ForEach(summary.risks.indices, id: \.self) { index in
                    let risk = summary.risks[index]
                    SummaryItemRow(
                        title: risk.risk,
                        detail: risk.details,
                        metadata: evidenceText(risk.evidenceSegmentIDs)
                    )
                }
            }
        }
    }

    private func actionItemDetail(_ item: SummaryActionItem) -> String? {
        var parts: [String] = []
        if let owner = item.owner, !owner.isEmpty {
            parts.append("Owner: \(owner)")
        }
        if let dueDate = item.dueDate, !dueDate.isEmpty {
            parts.append("Due: \(dueDate)")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func evidenceText(_ ids: [String]) -> String? {
        let times = ids
            .compactMap { segmentByID[$0.lowercased()]?.start }
            .map(Self.timestamp)
        guard !times.isEmpty else { return nil }
        return "Evidence: " + times.joined(separator: ", ")
    }

    nonisolated private static func timestamp(_ value: TimeInterval) -> String {
        let total = Int(value)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

private struct SummaryTextBlock: View {
    let title: String
    let systemImage: String
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: systemImage)
                .font(.headline)
            Text(text.isEmpty ? "Not available." : text)
                .font(.body)
                .textSelection(.enabled)
        }
    }
}

private struct SummarySection<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: systemImage)
                .font(.headline)
            VStack(alignment: .leading, spacing: 10) {
                content
            }
        }
    }
}

private struct SummaryItemRow: View {
    let title: String
    let detail: String?
    let metadata: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.body.weight(.medium))
                .textSelection(.enabled)
            if let detail, !detail.isEmpty {
                Text(detail)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            if let metadata {
                Text(metadata)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.leading, 4)
    }
}

private struct EmptySummaryRow: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.body)
            .foregroundStyle(.secondary)
    }
}
