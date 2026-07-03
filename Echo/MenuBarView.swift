//
//  MenuBarView.swift
//  Echo
//
//  The popover shown from the menu bar item. When recording, it shows live
//  input/output waveforms; otherwise a prompt to start. Always offers a way
//  into the full dashboard.
//

import SwiftUI
import AppKit

struct MenuBarView: View {
    @Environment(RecordingController.self) private var controller
    @Environment(\.openWindow) private var openWindow

    #if DEBUG
    @State private var fixtureRecorder = FixtureRecorder()
    #endif

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            if controller.state.isRecording {
                recordingBody
            } else {
                idleBody
            }

            Divider()
            footer

            #if DEBUG
            Divider()
            fixtureRecorderSection
            #endif
        }
        .padding(16)
        .frame(width: 320)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "waveform")
                .foregroundStyle(.tint)
            Text("Echo")
                .font(.headline)
            Spacer()
            if controller.state.isRecording {
                recordingBadge
            }
        }
    }

    private var recordingBadge: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            HStack(spacing: 6) {
                Circle()
                    .fill(.red)
                    .frame(width: 8, height: 8)
                Text(Self.elapsedFormatter.string(from: controller.state.elapsed) ?? "0:00")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Recording state

    private var recordingBody: some View {
        VStack(alignment: .leading, spacing: 12) {
            ChannelMeter(
                title: "You · microphone",
                systemImage: "mic.fill",
                levels: controller.state.inputLevels,
                color: .blue
            )
            ChannelMeter(
                title: "Team · system",
                systemImage: "speaker.wave.2.fill",
                levels: controller.state.outputLevels,
                color: .purple
            )

            if let notice = controller.state.echoNotice {
                Label(notice, systemImage: "waveform.badge.exclamationmark")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button(role: .destructive) {
                Task {
                    await controller.toggle()   // stop
                    // Surface the dashboard so the user lands on the transcript.
                    NSApp.activate(ignoringOtherApps: true)
                    openWindow(id: EchoWindow.dashboard)
                }
            } label: {
                Label("Stop recording", systemImage: "stop.fill")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .tint(.red)
        }
    }

    // MARK: - Idle state

    private var idleBody: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(controller.state.status.isEmpty ? "Ready to record your meeting." : controller.state.status)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Button {
                Task { await controller.toggle() }
            } label: {
                Label("Start recording", systemImage: "record.circle")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Spacer()
            Button {
                NSApp.activate(ignoringOtherApps: true)
                openWindow(id: EchoWindow.dashboard)
            } label: {
                Label("Open dashboard", systemImage: "rectangle.on.rectangle")
            }
            .buttonStyle(.bordered)
        }
    }

    #if DEBUG
    // MARK: - AEC fixture recording (SP-001 fixture suite, DEBUG builds only)

    private var fixtureRecorderSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Menu {
                ForEach(FixtureScenario.allCases) { scenario in
                    Button(scenario.rawValue) { recordFixture(scenario) }
                }
            } label: {
                Label("Record AEC Fixture…", systemImage: "record.circle.dashed")
            }
            .disabled(controller.state.isRecording || fixtureRecorder.isBusy)

            if let status = fixtureStatus {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var fixtureStatus: String? {
        switch fixtureRecorder.phase {
        case .idle:
            return nil
        case .countingDown(let seconds):
            return "Recording starts in \(seconds)…"
        case .recording(let remaining):
            return "Recording fixture… \(remaining)s left"
        case .finished(let folder):
            return "Fixture saved to \(folder.path)"
        case .failed(let message):
            return "Fixture recording failed: \(message)"
        }
    }

    private func recordFixture(_ scenario: FixtureScenario) {
        let panel = NSOpenPanel()
        panel.title = "Choose the fixtures folder"
        panel.message = "The take is written to {folder}/\(scenario.rawValue)/ — pick EchoTests/Fixtures to install it directly."
        panel.prompt = "Record"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false

        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await fixtureRecorder.record(scenario: scenario, into: url) }
    }
    #endif

    private static let elapsedFormatter: DateComponentsFormatter = {
        let f = DateComponentsFormatter()
        f.allowedUnits = [.minute, .second]
        f.zeroFormattingBehavior = .pad
        return f
    }()
}
