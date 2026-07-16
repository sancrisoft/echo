//
//  MenuBarView.swift
//  Echo
//
//  The popover shown from the menu bar item. It has two faces that animate
//  between each other:
//
//    • Idle/Ready — a green status dot, the last meeting's stats, and an indigo
//      "Start Recording" button.
//    • Recording — a red status dot, a large running timer, the two live
//      waveforms (mic = indigo, system = gray), a live word count, and a red
//      "Stop" button.
//
//  The gear in the header opens the full dashboard. Capture-health problems
//  (mic lost, degraded echo handling, unusable input) temporarily replace the
//  info line under the waves; the default line returns once they clear.
//

import SwiftUI
import AppKit

struct MenuBarView: View {
    @Environment(RecordingController.self) private var controller
    @Environment(\.openWindow) private var openWindow

    /// Stats for the most recently saved meeting, shown on the idle face.
    /// Word count needs the transcript, so it is loaded lazily (the meta alone
    /// only carries a segment count) whenever the newest meeting changes.
    @State private var lastMeeting: LastMeetingStat?

    #if DEBUG
    @State private var fixtureRecorder = FixtureRecorder()
    #endif

    var body: some View {
        VStack(spacing: 16) {
            header

            Group {
                if controller.state.isRecording {
                    recordingBody
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                } else {
                    idleBody
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }

            #if DEBUG
            Divider()
            fixtureRecorderSection
            #endif
        }
        .padding(18)
        .frame(width: 300)
        // Drives the height/color crossfade between the two faces.
        .animation(.spring(response: 0.42, dampingFraction: 0.86), value: controller.state.isRecording)
        .task(id: controller.library.metas.first?.id) {
            await loadLastMeeting()
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            appGlyph
            Text("Echo")
                .font(.system(size: 17, weight: .bold))
            Spacer()
            Button(action: openDashboard) {
                Image(systemName: "gearshape")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Open dashboard")
        }
    }

    private var appGlyph: some View {
        RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [Color(red: 0.43, green: 0.41, blue: 0.99), .echoIndigo],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .frame(width: 34, height: 34)
            .overlay(
                Image(systemName: "waveform")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(.white)
            )
    }

    // MARK: - Recording face

    private var recordingBody: some View {
        VStack(spacing: 12) {
            HStack(spacing: 6) {
                Circle().fill(.red).frame(width: 8, height: 8)
                Text("Recording")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.red)
            }

            TimelineView(.periodic(from: .now, by: 1)) { _ in
                Text(Self.timerString(controller.state.elapsed))
                    .font(.system(size: 44, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(.primary)
            }

            DualWaveView(
                inputLevel: Self.amplitude(controller.state.inputLevels),
                outputLevel: Self.amplitude(controller.state.outputLevels)
            )
            .frame(height: 54)
            .padding(.vertical, 2)

            infoLine

            Button(action: stopAndOpenDashboard) {
                Label("Stop", systemImage: "stop.fill")
                    .font(.headline)
                    .padding(.horizontal, 12)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .clipShape(Capsule())
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Idle face

    private var idleBody: some View {
        VStack(spacing: 12) {
            HStack(spacing: 6) {
                Circle().fill(.green).frame(width: 8, height: 8)
                Text("Ready to record")
                    .font(.subheadline.weight(.semibold))
            }

            infoLine

            Button {
                Task { await controller.toggle() }
            } label: {
                Label("Start Recording", systemImage: "play.fill")
                    .font(.headline)
                    .padding(.horizontal, 12)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .tint(.echoIndigo)
            .clipShape(Capsule())
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Info line (default stats, or a temporary health warning)

    @ViewBuilder
    private var infoLine: some View {
        if let warning = activeWarning {
            Label(warning, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
        } else if let text = metaText {
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
        }
    }

    /// The most severe active capture-health notice, if any. Ordered so a
    /// device-lost notice is never masked by an input-health one (the same
    /// priority the stacked notices used before). All of these clear on stop.
    private var activeWarning: String? {
        let s = controller.state
        return s.inputNotice ?? s.micHealthNotice ?? s.systemHealthNotice ?? s.echoNotice
    }

    /// The default info line for the current face.
    private var metaText: String? {
        if controller.state.isRecording {
            return "Mic + system · \(liveWordCount.formatted()) words"
        }
        // Idle: surface any pending status (e.g. "Generating summary…") first,
        // otherwise the last meeting's stats.
        if !controller.state.status.isEmpty {
            return controller.state.status
        }
        if let last = lastMeeting {
            return "Last meeting · \(Self.minutesString(last.duration)) · \(last.words.formatted()) words"
        }
        return nil
    }

    private var liveWordCount: Int {
        Self.wordCount(of: controller.state.segments)
    }

    // MARK: - Actions

    private func openDashboard() {
        NSApp.activate(ignoringOtherApps: true)
        openWindow(id: EchoWindow.dashboard)
    }

    private func stopAndOpenDashboard() {
        Task {
            await controller.toggle()   // stop
            openDashboard()             // land the user on the transcript
        }
    }

    private func loadLastMeeting() async {
        guard let meta = controller.library.metas.first else {
            lastMeeting = nil
            return
        }
        guard let record = await controller.library.loadRecord(meta.id) else { return }
        lastMeeting = LastMeetingStat(
            duration: meta.duration,
            words: Self.wordCount(of: record.segments)
        )
    }

    // MARK: - Formatting helpers

    private struct LastMeetingStat {
        var duration: TimeInterval
        var words: Int
    }

    private static func wordCount(of segments: [TranscriptSegment]) -> Int {
        segments.reduce(0) { $0 + $1.text.split(whereSeparator: \.isWhitespace).count }
    }

    private static func timerString(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval))
        return String(format: "%02d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }

    private static func minutesString(_ duration: TimeInterval) -> String {
        let minutes = max(1, Int((duration / 60).rounded()))
        return "\(minutes) min"
    }

    /// A single display amplitude (0...1) from a channel's rolling levels: the
    /// mean of the most recent samples, lightly gained so ordinary speech reads
    /// as a visible wave. Still entirely real capture data.
    private static func amplitude(_ levels: [CGFloat]) -> CGFloat {
        guard !levels.isEmpty else { return 0 }
        let recent = levels.suffix(8)
        let mean = recent.reduce(0, +) / CGFloat(recent.count)
        return min(1, mean * 1.4)
    }

    #if DEBUG
    // MARK: - Fixture recording (SP-001 + SP-002 fixture suites, DEBUG builds only)

    private var fixtureRecorderSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Menu {
                // allCases keeps the menu complete by construction: new
                // scenarios appear here the moment they are declared.
                ForEach(FixtureScenario.allCases) { scenario in
                    Button(scenario.rawValue) { recordFixture(scenario) }
                }
            } label: {
                Label("Record Fixture…", systemImage: "record.circle.dashed")
            }
            .disabled(controller.state.isRecording || fixtureRecorder.isBusy)

            if let status = fixtureStatus {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
}
