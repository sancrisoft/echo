//
//  DashboardView.swift
//  Echo
//
//  The full window opened from "Abrir dashboard". Shows the live, aligned
//  transcript across both channels and the session controls.
//

import SwiftUI

struct DashboardView: View {
    @Environment(RecordingController.self) private var controller

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            transcript
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
        if controller.state.segments.isEmpty {
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
                    ForEach(controller.state.segments) { segment in
                        SegmentRow(segment: segment)
                    }
                }
                .padding()
            }
        }
    }
}

private struct SegmentRow: View {
    let segment: TranscriptSegment

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(accent)
                .frame(width: 8, height: 8)
                .padding(.top, 6)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(segment.speaker.displayName)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(accent)
                    Text(timestamp)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Text(segment.text)
                    .font(.body)
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
