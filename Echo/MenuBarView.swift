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
                title: "Tú · micrófono",
                systemImage: "mic.fill",
                levels: controller.state.inputLevels,
                color: .blue
            )
            ChannelMeter(
                title: "Equipo · sistema",
                systemImage: "speaker.wave.2.fill",
                levels: controller.state.outputLevels,
                color: .purple
            )

            Button(role: .destructive) {
                Task { await controller.toggle() }
            } label: {
                Label("Detener grabación", systemImage: "stop.fill")
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
            Text(controller.state.status.isEmpty ? "Listo para grabar tu reunión." : controller.state.status)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Button {
                Task { await controller.toggle() }
            } label: {
                Label("Empezar a grabar", systemImage: "record.circle")
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
                Label("Abrir dashboard", systemImage: "rectangle.on.rectangle")
            }
            .buttonStyle(.bordered)
        }
    }

    private static let elapsedFormatter: DateComponentsFormatter = {
        let f = DateComponentsFormatter()
        f.allowedUnits = [.minute, .second]
        f.zeroFormattingBehavior = .pad
        return f
    }()
}
