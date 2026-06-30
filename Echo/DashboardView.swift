//
//  DashboardView.swift
//  Echo
//
//  The full window opened from "Open dashboard" (and shown automatically when a
//  recording stops). Two tabs: the live transcript and the (upcoming) summary.
//

import SwiftUI

struct DashboardView: View {
    @Environment(RecordingController.self) private var controller

    private enum Tab: Hashable { case transcript, summary }
    @State private var selectedTab: Tab = .transcript

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            TabView(selection: $selectedTab) {
                transcript
                    .tabItem { Label("Transcript", systemImage: "text.bubble") }
                    .tag(Tab.transcript)
                summary
                    .tabItem { Label("Summary", systemImage: "sparkles") }
                    .tag(Tab.summary)
            }
            .padding(.top, 8)
        }
        .frame(minWidth: 520, minHeight: 420)
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 12) {
            Image(systemName: "waveform")
                .foregroundStyle(.tint)
            Text("Echo")
                .font(.title3.bold())

            Spacer()

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

    // MARK: - Transcript

    @ViewBuilder
    private var transcript: some View {
        if transcriptRows.isEmpty {
            ContentUnavailableView(
                controller.state.isRecording ? "Listening…" : "No transcript yet",
                systemImage: "text.bubble",
                description: Text(controller.state.isRecording
                    ? "Text will appear here as people speak."
                    : "Start recording to generate the transcript.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(transcriptRows) { row in
                        SegmentRow(segment: row.segment, isPartial: row.isPartial)
                    }
                }
                .padding()
            }
        }
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

    // MARK: - Summary (placeholder — built in a later feature)

    private var summary: some View {
        ContentUnavailableView(
            "Summary coming soon",
            systemImage: "sparkles",
            description: Text("A meeting summary — short and detailed overviews, decisions, action items, open questions and risks — will be generated here from the transcript.")
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
