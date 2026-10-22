//
//  WelcomeScreen.swift
//  Workspace
//
//  The design's welcome screen, in the main window in place of
//  the workspace: the mark, what Echo does, the three things to set up once
//  — the microphone, System Audio Recording and the two models — each with
//  its reason beside it, and the way on.
//
//  Permissions are asked here, each when its row's Allow is pressed. The
//  microphone is read again whenever Echo comes back to the front, so a
//  change in System Settings shows at once. System Audio Recording is read
//  from TCC's record once a run, and its answer to Allow shows after Quit &
//  Reopen, which reopens Echo on this screen (see
//  `RecordingSession.refreshCaptureAccess`).
//

import AppKit
import DesignSystem
import EchoCore
import Recording
import SwiftUI

struct WelcomeScreen: View {
    @Environment(RecordingSession.self) private var session
    @Environment(\.openURL) private var openURL

    let dataRoot: DataRoot
    /// Start using Echo and Record without notes: the window's, which
    /// records that the user left and shows the workspace.
    let leave: () -> Void
    /// Quit & Reopen: the app's, since only the app can end its own process.
    /// It reopens Echo on this screen.
    let relaunch: () -> Void

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                WelcomeColumn(
                    steps: WelcomeSteps(
                        microphone: session.microphoneAccess,
                        systemAudio: session.systemAudioAccess,
                        transcription: session.readiness,
                        summary: session.summaryReadiness,
                        systemAudioAwaitsRelaunch: session.systemAudioAwaitsRelaunch),
                    dataFolder: Self.abbreviated(dataRoot.url),
                    perform: perform
                )
                .frame(width: EchoLayout.welcomeColumnWidth)
                .frame(maxWidth: .infinity, minHeight: proxy.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .task { await session.refreshCaptureAccess() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await session.refreshCaptureAccess() }
        }
    }

    private func perform(_ action: WelcomeAction) {
        switch action {
        case .allowMicrophone:
            Task { await session.requestMicrophoneAccess() }
        case .allowSystemAudio:
            Task { await session.requestSystemAudioAccess() }
        case .openMicrophoneSettings:
            open(PrivacySettingsPage.microphone)
        case .openSystemAudioSettings:
            open(PrivacySettingsPage.systemAudio)
        case .model(let action, let model):
            switch ModelsPanel.verb(for: action, on: model) {
            case .retryTranscription: session.retryTranscriptionModel()
            case .pauseSummary: session.pauseSummaryModelDownload()
            case .resumeSummary: session.resumeSummaryModelDownload()
            case nil: break
            }
        case .relaunch:
            relaunch()
        case .start, .recordWithoutNotes:
            leave()
        }
    }

    private func open(_ page: String) {
        guard let url = URL(string: page) else {
            ErrorTrace.record("A System Settings page did not parse as a URL", category: "Welcome")
            return
        }
        openURL(url)
    }

    /// The data folder as the footer writes it: under the home folder, with
    /// a tilde.
    static func abbreviated(_ folder: URL) -> String {
        var path = (folder.path(percentEncoded: false) as NSString).abbreviatingWithTildeInPath
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        return path
    }
}

/// What the welcome screen's controls ask for.
enum WelcomeAction: Equatable {
    case allowMicrophone
    case allowSystemAudio
    case openMicrophoneSettings
    case openSystemAudioSettings
    case relaunch
    case model(ModelRow.Action, ModelRow.Model)
    case start
    case recordWithoutNotes
}

/// System Settings' pages for the two permissions, by the anchors measured to
/// land on them (macOS 27.0.1, 2026-10-19): `Privacy_Microphone` opens
/// Microphone, and `Privacy_ScreenCapture` opens Screen & System Audio
/// Recording, whose second list is "System Audio Recording Only".
/// `Privacy_AudioCapture` opens nothing.
enum PrivacySettingsPage {
    static let microphone = "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
    static let systemAudio = "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
}

// MARK: - The column

/// The welcome screen's column, drawn from values: what the screen shows,
/// and what a test renders without a session.
struct WelcomeColumn: View {
    let steps: WelcomeSteps
    let dataFolder: String
    let perform: (WelcomeAction) -> Void

    var body: some View {
        // The mark carries its clear space; the artboard measures from the
        // grid, so the clear space comes out of the gaps around it.
        let clear = EchoMark.clearSpaceInset(for: EchoControl.welcomeMarkSize)
        VStack(alignment: .leading, spacing: 0) {
            EchoMark(size: EchoControl.welcomeMarkSize, ink: EchoColor.accent)
                .padding(.leading, -clear.width)
                .padding(.top, -clear.height)
                .padding(.bottom, EchoLayout.welcomeMarkGap - clear.height)
            Text(verbatim: "Echo turns your meetings into notes.")
                .font(EchoFont.welcomeTitle)
                .tracking(EchoFont.welcomeTitleTracking)
                .foregroundStyle(EchoColor.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, EchoLayout.welcomeTitleGap)
            Text(
                verbatim:
                    "It records your microphone and the call's audio on two separate tracks, transcribes them here on this Mac, and writes up what was decided. Nothing leaves the machine and there is no account."
            )
            .font(EchoFont.welcomeIntro)
            .lineSpacing(EchoFont.welcomeIntroLineSpacing)
            .foregroundStyle(EchoColor.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.bottom, EchoLayout.welcomeIntroGap)
            Text(verbatim: "Three things to set up, once")
                .font(EchoFont.sectionLabel)
                .tracking(EchoFont.sectionLabelTracking)
                .foregroundStyle(EchoColor.textTertiary)
                .padding(.bottom, EchoLayout.welcomeSectionGap)
            permissionStep(
                title: "Microphone", reason: "Your side of the conversation.",
                progress: steps.microphoneProgress, control: WelcomeSteps.control(for: steps.microphone),
                allow: .allowMicrophone, openSettings: .openMicrophoneSettings)
            permissionStep(
                title: "System Audio Recording",
                reason:
                    "macOS files system audio under this permission. Echo captures the sound only — never the picture.",
                progress: steps.systemAudioProgress, control: steps.systemAudioControl,
                allow: .allowSystemAudio, openSettings: .openSystemAudioSettings)
            modelsStep
            EchoColor.divider
                .frame(height: EchoLayout.hairline)
                .padding(.top, EchoLayout.welcomeStepsBottomGap)
            actions
                .padding(.top, EchoLayout.welcomeActionsTopGap)
            footer
                .padding(.top, EchoLayout.welcomeFooterTopGap)
        }
    }

    // MARK: The steps

    private func permissionStep(
        title: String, reason: String, progress: WelcomeSteps.Progress, control: WelcomeSteps.PermissionControl,
        allow: WelcomeAction, openSettings: WelcomeAction
    ) -> some View {
        HStack(spacing: EchoLayout.welcomeStepGap) {
            StepGlyph(progress: progress)
            VStack(alignment: .leading, spacing: 0) {
                Text(verbatim: title)
                    .font(EchoFont.rowTitle)
                    .foregroundStyle(EchoColor.textValue)
                Text(verbatim: reason)
                    .font(EchoFont.rowDescription)
                    .lineSpacing(EchoFont.rowDescriptionLineSpacing)
                    .foregroundStyle(EchoColor.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            switch control {
            case .allowed:
                Text(verbatim: "Allowed")
                    .font(EchoFont.controlSelected)
                    .foregroundStyle(EchoColor.accent)
            case .allow:
                Button("Allow") { perform(allow) }
                    .buttonStyle(.echoControlProminent)
                    .fixedSize()
            case .openSettings:
                Button("Open System Settings") { perform(openSettings) }
                    .buttonStyle(.echoControlProminent)
                    .fixedSize()
            case .requested:
                HStack(spacing: EchoLayout.welcomeActionsGap) {
                    Text(verbatim: "Requested")
                        .font(EchoFont.controlSelected)
                        .foregroundStyle(EchoColor.textTertiary)
                    Button("Quit & Reopen") { perform(.relaunch) }
                        .buttonStyle(.echoControlProminent)
                }
                .fixedSize()
            }
        }
        .frame(minHeight: EchoLayout.welcomeStepHeight)
        .overlay(alignment: .top) {
            EchoColor.divider.frame(height: EchoLayout.hairline)
        }
    }

    private var modelsStep: some View {
        HStack(alignment: .top, spacing: EchoLayout.welcomeStepGap) {
            StepGlyph(progress: steps.modelsProgress)
                .padding(.top, EchoLayout.welcomeModelsGlyphDrop)
            VStack(alignment: .leading, spacing: EchoLayout.welcomeModelsGap) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(verbatim: "The two on-device models")
                        .font(EchoFont.rowTitle)
                        .foregroundStyle(EchoColor.textValue)
                    Text(verbatim: "Downloaded once, then they work offline forever.")
                        .font(EchoFont.rowDescription)
                        .lineSpacing(EchoFont.rowDescriptionLineSpacing)
                        .foregroundStyle(EchoColor.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                VStack(alignment: .leading, spacing: EchoLayout.welcomeModelLineGap) {
                    modelLine(.transcription, slot: steps.transcriptionSlot)
                    modelLine(.summary, slot: steps.summarySlot)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, EchoLayout.welcomeModelsInset)
        .overlay(alignment: .top) {
            EchoColor.divider.frame(height: EchoLayout.hairline)
        }
    }

    private func modelLine(_ model: ModelRow.Model, slot: WelcomeSteps.ModelSlot) -> some View {
        let identity: OnDeviceModel = model == .transcription ? .transcription : .summary
        return HStack(spacing: EchoLayout.welcomeModelItemGap) {
            Text(verbatim: identity.name)
                .font(EchoFont.control)
                .foregroundStyle(EchoColor.textSecondary)
                .lineLimit(1)
                .frame(width: EchoControl.welcomeModelNameWidth, alignment: .leading)
            switch slot {
            case .downloading(let percent):
                DownloadBar(percent: percent)
                modelFigure("\(percent)%", color: EchoColor.textTertiary)
            case .onDisk(let size):
                DownloadBar(percent: 100)
                modelFigure(size, color: EchoColor.accent)
            case .panel(let row):
                panelWords(row)
            }
        }
    }

    private func modelFigure(_ text: String, color: Color) -> some View {
        Text(verbatim: text)
            .font(EchoFont.welcomeModelValue)
            .foregroundStyle(color)
            .lineLimit(1)
            .frame(width: EchoControl.welcomeModelValueWidth, alignment: .trailing)
    }

    /// The models panel's words and button, in the bar's place.
    @ViewBuilder
    private func panelWords(_ row: ModelRow) -> some View {
        HStack(spacing: EchoControl.modelTrailingGap) {
            switch row.status {
            case .words(let words):
                Text(verbatim: words)
                    .font(EchoFont.control)
                    .foregroundStyle(EchoColor.textTertiary)
                    .lineLimit(1)
            case .loading:
                HStack(spacing: EchoControl.modelLoadingGap) {
                    LoadingSpinner(size: EchoControl.modelSpinnerSize)
                    Text(verbatim: "Loading…")
                        .font(EchoFont.control)
                        .foregroundStyle(EchoColor.textSecondary)
                }
            case .actionOnly:
                // A failure: its reason, wrapping to a second line rather
                // than cut short.
                WrapsWithinItsWidth {
                    Text(verbatim: row.detail)
                        .font(EchoFont.rowDescription)
                        .lineSpacing(EchoFont.rowDescriptionLineSpacing)
                        .foregroundStyle(EchoColor.failureText)
                }
            case .progress, .ready:
                // Never handed here: those states have a bar of their own.
                EmptyView()
            }
            Spacer(minLength: 0)
            if let action = row.action {
                Button(action.title) { perform(.model(action, row.model)) }
                    .buttonStyle(.echoControl)
                    .fixedSize()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: The way on

    private var actions: some View {
        HStack(spacing: EchoLayout.welcomeActionsGap) {
            // Never held back: the welcome can always be left (`WelcomeSteps`).
            Button("Start using Echo") { perform(.start) }
                .buttonStyle(.echoProminent)
                .fixedSize()
            Spacer(minLength: 0)
            Button {
                perform(.recordWithoutNotes)
            } label: {
                // Undrawn while it cannot be used: it takes the held-back
                // label's grey, the one the screen already uses for "not
                // yet".
                Text(verbatim: "Record without notes")
                    .font(EchoFont.control)
                    .foregroundStyle(steps.canRecordWithoutNotes ? EchoColor.textTertiary : EchoColor.textQuaternary)
            }
            .buttonStyle(.plain)
            .disabled(!steps.canRecordWithoutNotes)
            .fixedSize()
        }
    }

    private var footer: some View {
        HStack(spacing: EchoLayout.welcomeFooterGap) {
            ShieldGlyph()
                .foregroundStyle(EchoColor.textFaint)
                .frame(width: EchoControl.welcomeShieldSize, height: EchoControl.welcomeShieldSize)
                .accessibilityHidden(true)
            Text(verbatim: "Everything lands in \(dataFolder)")
                .font(EchoFont.welcomeFooter)
                .foregroundStyle(EchoColor.textFaint)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}

// MARK: - The drawn parts

/// A step's glyph, on the artboard's 20 grid: a check on the accent's wash
/// once done, an empty ring while pending, and a turning arc on a track
/// while something happens on its own — which says "working", never how far.
struct StepGlyph: View {
    let progress: WelcomeSteps.Progress

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var turning = false

    /// The artboard's arc: from the top round to about four o'clock.
    private static let sweep: CGFloat = 126 / 360

    var body: some View {
        let size = EchoControl.stepGlyphSize
        let unit = size / 20
        Group {
            switch progress {
            case .done:
                ZStack {
                    Circle()
                        .inset(by: 1 * unit)
                        .fill(EchoColor.accentWash)
                    StepCheckGlyph()
                        .foregroundStyle(EchoColor.accent)
                }
            case .pending:
                Circle()
                    .inset(by: 1.8 * unit)
                    .stroke(EchoColor.stepPending, lineWidth: 1.6 * unit)
            case .working:
                ZStack {
                    Circle()
                        .inset(by: 1.8 * unit)
                        .stroke(EchoColor.stepRingTrack, lineWidth: 1.8 * unit)
                    Circle()
                        .inset(by: 1.8 * unit)
                        .trim(from: 0, to: Self.sweep)
                        .stroke(EchoColor.accent, style: StrokeStyle(lineWidth: 1.8 * unit, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .rotationEffect(.degrees(turning && !reduceMotion ? 360 : 0))
                        .animation(
                            reduceMotion
                                ? nil
                                : .linear(duration: EchoMotion.spinnerPeriod).repeatForever(autoreverses: false),
                            value: turning
                        )
                        .onAppear { turning = true }
                }
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// The check inside a done step, on the 20 grid.
nonisolated struct StepCheckGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        let grid = GlyphGrid(rect: rect, side: 20)
        var check = Path()
        check.addLines([grid.point(6.2, 10.3), grid.point(8.8, 12.9), grid.point(13.9, 7.3)])
        return check.strokedPath(StrokeStyle(lineWidth: grid.length(1.9), lineCap: .round, lineJoin: .round))
    }
}

/// The shield before the footer line, on the 16 grid.
nonisolated struct ShieldGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        let grid = GlyphGrid(rect: rect)
        var shield = Path()
        shield.move(to: grid.point(8, 1.8))
        shield.addLine(to: grid.point(13, 3.6))
        shield.addLine(to: grid.point(13, 7.7))
        shield.addCurve(to: grid.point(8, 14.2), control1: grid.point(13, 10.8), control2: grid.point(11, 13.1))
        shield.addCurve(to: grid.point(3, 7.7), control1: grid.point(5, 13.1), control2: grid.point(3, 10.8))
        shield.addLine(to: grid.point(3, 3.6))
        shield.closeSubpath()
        return shield.strokedPath(StrokeStyle(lineWidth: grid.length(1.4), lineJoin: .round))
    }
}
