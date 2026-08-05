//
//  CallIslandView.swift
//  Echo
//
//  The island's four faces (SP-006 §4.7). Presentation only: every tap goes
//  straight to `CallDetectionController`, which forwards it to the pure machine
//  — the view holds no suppression logic and no authority over the countdown
//  (it renders the controller's real deadline).
//
//  Copy is English, app-named and honest: the countdown shows real remaining
//  seconds, and "Meeting saved" appears only once the stop path has actually
//  persisted the meeting.
//

import SwiftUI

struct CallIslandView: View {

    let controller: CallDetectionController

    private static let cornerRadius: CGFloat = 22

    var body: some View {
        ZStack {
            if let face = controller.face {
                content(for: face)
                    .frame(width: Self.width(for: face))
                    .background(
                        RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                            .fill(Color.black.opacity(0.92))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
                    )
                    .shadow(color: .black.opacity(0.35), radius: 14, y: 5)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        // Room for the shadow, which would otherwise be clipped by the panel.
        .padding(10)
        .animation(.spring(response: 0.38, dampingFraction: 0.86), value: controller.face)
    }

    /// Sized per face so nothing wraps: the countdown carries two buttons, the
    /// confirmation only one, and the pill is a glance.
    private static func width(for face: IslandFace) -> CGFloat {
        switch face {
        case .startPrompt: return 380
        case .compactPill: return 120
        case .endGrace: return 430
        case .saved: return 300
        }
    }

    @ViewBuilder
    private func content(for face: IslandFace) -> some View {
        switch face {
        case .startPrompt(let appName):
            startPrompt(appName: appName)
        case .compactPill:
            compactPill
        case .endGrace:
            endGrace
        case .saved:
            saved
        }
    }

    // MARK: - Start prompt

    private func startPrompt(appName: String) -> some View {
        HStack(spacing: 10) {
            Circle()
                .fill(.red)
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 2) {
                Text(Self.detectedTitle(appName: appName))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                Text("Record this meeting?")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.65))
            }
            .lineLimit(1)

            Spacer(minLength: 4)

            Button("Start recording") { controller.startTapped() }
                .buttonStyle(IslandButtonStyle(kind: .filled(.echoIndigo)))

            Button {
                controller.dismissTapped()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.55))
                    .frame(width: 18, height: 18)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help("Dismiss for this call")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
    }

    /// "Zoom call detected" — or an honest, app-less title when the capturing
    /// process reported no name we can attribute.
    private static func detectedTitle(appName: String) -> String {
        appName.isEmpty ? "Call detected" : "\(appName) call detected"
    }

    // MARK: - Compact pill

    private var compactPill: some View {
        Button {
            controller.pillTapped()
        } label: {
            HStack(spacing: 6) {
                Circle()
                    .fill(.red)
                    .frame(width: 6, height: 6)
                Text("Call")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.white.opacity(0.9))
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help("A call is in progress — click to record it")
    }

    // MARK: - End-of-call countdown

    private var endGrace: some View {
        HStack(spacing: 10) {
            Image(systemName: "phone.down.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.7))

            VStack(alignment: .leading, spacing: 2) {
                Text("Call ended")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    Text("Stopping recording in \(remainingSeconds)s")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.white.opacity(0.65))
                }
            }
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)

            Spacer(minLength: 4)

            Button("Stop now") { controller.stopNowTapped() }
                .buttonStyle(IslandButtonStyle(kind: .filled(.red)))

            Button("Keep recording") { controller.keepRecordingTapped() }
                .buttonStyle(IslandButtonStyle(kind: .outlined))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
    }

    /// Seconds left on the controller's real deadline — never a second clock.
    private var remainingSeconds: Int {
        guard let deadline = controller.graceDeadline else { return 0 }
        return max(0, Int(deadline.timeIntervalSinceNow.rounded(.up)))
    }

    // MARK: - Saved

    private var saved: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.green)

            Text("Meeting saved")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .lineLimit(1)

            Spacer(minLength: 4)

            Button("Open Echo") { controller.openEchoTapped() }
                .buttonStyle(IslandButtonStyle(kind: .outlined))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
    }
}

/// The island paints its own buttons.
///
/// Its panel is deliberately never the key window (it must not take focus from
/// the meeting app — ADR-018), and macOS renders `.borderedProminent` with a
/// `.tint` almost invisibly in a non-key window: the accent fill is dropped and
/// the label greys out. Explicit capsules keep the primary action readable
/// whatever the app's activation state.
private struct IslandButtonStyle: ButtonStyle {

    enum Kind {
        /// The face's primary action.
        case filled(Color)
        /// The secondary answer next to it.
        case outlined
    }

    let kind: Kind

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.caption.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background {
                switch kind {
                case .filled(let color):
                    Capsule().fill(color.opacity(configuration.isPressed ? 0.75 : 1))
                case .outlined:
                    Capsule()
                        .fill(.white.opacity(configuration.isPressed ? 0.28 : 0.14))
                        .overlay(Capsule().strokeBorder(.white.opacity(0.18), lineWidth: 1))
                }
            }
            .contentShape(.capsule)
    }
}
