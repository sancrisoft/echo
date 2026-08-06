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
//      waveforms (mic = indigo, system = gray), and a red "Stop" button.
//      No transcript-derived numbers while recording (SP-007 final-only UX);
//      word counts reappear once the meeting resolves.
//
//  The gear in the header opens the full dashboard. Capture-health problems
//  (mic lost, degraded echo handling, unusable input) temporarily replace the
//  info line under the waves; the default line returns once they clear.
//

import SwiftUI
import AppKit

struct MenuBarView: View {
    @Environment(RecordingController.self) private var controller
    @Environment(AppSettings.self) private var settings
    @Environment(CallDetectionController.self) private var callDetection
    @Environment(\.openWindow) private var openWindow

    /// Stats for the most recently saved meeting, shown on the idle face.
    /// Word count needs the transcript, so it is loaded lazily (the meta alone
    /// only carries a segment count) whenever the newest meeting changes.
    @State private var lastMeeting: LastMeetingStat?

    /// The idle face's chosen capture scope (SP-008). Reseeded to the detected
    /// app whenever `appsInCall` changes — so a popup opened mid-call
    /// preselects the app the island names, and a call ending while the popup
    /// is open degrades to `nil` (no selector row, Start records Everything).
    @State private var scopeSelection: CaptureScope?

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
            // So internal testers can see at a glance which build they run.
            Text(AppVersion.display)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .padding(.top, 3)
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
                inputLevel: DualWaveView.amplitude(controller.state.inputLevels),
                outputLevel: DualWaveView.amplitude(controller.state.outputLevels)
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

            // SP-008: with a call detected, offer to scope the recording to it.
            // Derived from the same `appsInCall` the island attributes from —
            // no call (or only unscopeable apps) means no row at all, so the
            // popup is byte-for-byte today's outside a call.
            if !scopeOptions.isEmpty {
                HStack(spacing: 6) {
                    Text("Record:")
                        .foregroundStyle(.secondary)
                    Picker("Record:", selection: $scopeSelection) {
                        ForEach(scopeOptions, id: \.self) { option in
                            Text(option.scopedApp?.displayName ?? "Everything")
                                .tag(Optional(option))
                        }
                    }
                    .labelsHidden()
                    .controlSize(.small)
                    .fixedSize()
                }
                .font(.caption)
            }

            Button {
                Task {
                    // Idle face, so this is always a start; the recording
                    // face's Stop keeps using `toggle()`. `nil` selection
                    // (no call detected) records everything — today's start.
                    await controller.start(scope: scopeSelection ?? .everything)
                    // Blocked on a not-ready speech model — downloading,
                    // preparing, or a failed download/load (ADR-009): never a
                    // false recording face here. Open + focus the dashboard,
                    // which raises the explanatory dialog (a menu-bar popover
                    // would dismiss an alert as it closes) and shows the live
                    // download status behind it.
                }
            } label: {
                Label("Start Recording", systemImage: "play.fill")
                    .font(.headline)
                    .padding(.horizontal, 12)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .tint(.echoIndigo)
            .clipShape(Capsule())

            // SP-006: the call-detection island's on/off switch. Lives on the
            // idle face because that is where "should Echo notice my next
            // call?" is a question the user might have.
            Toggle("Suggest recording when a call starts", isOn: Binding(
                get: { settings.callDetectionEnabled },
                set: { settings.setCallDetection(enabled: $0) }
            ))
            .font(.caption)
            .toggleStyle(.switch)
            .controlSize(.mini)
        }
        .frame(maxWidth: .infinity)
        // `initial: true` covers a popup opened mid-call; later changes cover
        // a call starting/ending while it is open. Reseeding (rather than
        // preserving a manual pick) keeps the selection honest: it always
        // names an app that is verifiably still on a call.
        .onChange(of: callDetection.appsInCall, initial: true) {
            scopeSelection = ScopeSelection.defaultSelection(appsInCall: callDetection.appsInCall)
        }
    }

    /// The "Record:" dropdown's options — empty means "no selector row"
    /// (see `ScopeSelection`).
    private var scopeOptions: [CaptureScope] {
        ScopeSelection.options(appsInCall: callDetection.appsInCall)
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
        // While recording, no transcript-derived numbers: nothing is
        // transcribed until the meeting stops, and the word count appears
        // once its pass resolves.
        if controller.state.isRecording {
            // SP-008: a scoped session says so ("Zoom only") — `captureScope`
            // already reflects the effective scope after any fallback, so this
            // line never overstates the narrowing. A global session keeps
            // today's line: "Mic + system" already tells the whole truth.
            if let scope = controller.state.captureScope, scope.scopedApp != nil {
                return scope.indicatorLabel
            }
            return "Mic + system"
        }
        // Idle: surface any pending status (e.g. "Generating summary…") first,
        // otherwise the last meeting's stats.
        if !controller.state.status.isEmpty {
            return controller.state.status
        }
        if let last = lastMeeting {
            let stats = "Last meeting · \(Self.minutesString(last.duration))"
            guard let words = last.words else { return stats }
            return "\(stats) · \(words.formatted()) words"
        }
        return nil
    }

    // MARK: - Actions

    private func openDashboard() {
        // Shared with SP-006's island (which has no `openWindow` of its own).
        DashboardOpening.open(using: openWindow)
    }

    private func stopAndOpenDashboard() {
        Task {
            await controller.toggle()   // stop — returns once the meeting is saved
            // Land the user inside the just-stopped meeting: the transcript is
            // there immediately, and the detail switches itself to AI Summary
            // when the (background) generation completes.
            controller.pendingLiveDetailOpen = true
            openDashboard()
        }
    }

    /// The last meeting's stats, straight off its meta — the word count is
    /// denormalized there and re-derived whenever a pass writes the transcript,
    /// so this never has to load (or wait for) a transcript that may not exist
    /// yet. A meeting still being transcribed simply shows no word count.
    private func loadLastMeeting() async {
        await controller.library.refresh()
        guard let meta = controller.library.metas.first else {
            lastMeeting = nil
            return
        }
        lastMeeting = LastMeetingStat(duration: meta.duration, words: meta.wordCount)
    }

    // MARK: - Formatting helpers

    private struct LastMeetingStat {
        var duration: TimeInterval
        var words: Int?
    }

    private static func timerString(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval))
        return String(format: "%02d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }

    private static func minutesString(_ duration: TimeInterval) -> String {
        let minutes = max(1, Int((duration / 60).rounded()))
        return "\(minutes) min"
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
