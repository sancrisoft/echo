//
//  TitleBar.swift
//  Workspace
//
//  The right end of the title bar: New recording at rest; the running clock
//  and Stop while a session records, as the recording artboard draws them —
//  DEC-5's answer (#65), so there is no REC pill. While the transcription
//  model is not on disk, New recording is held back and the reason sits
//  beside it, the way the welcome screen draws its own held-back button
//  (product owner, 2026-10-19): someone looking at the window has to read why
//  it will not record in the window. The sentence is the one the island and
//  the menu say (`RecordingReadiness.waitingFor`).
//
//  It lives in the window's toolbar, in the compact style. The artboard draws
//  a 44 pt title bar, and AppKit fixes a title bar's height per style —
//  measured on macOS 27.0.1: 32 bare, 40 compact, 52 unified, whatever the
//  items in it. Only a toolbar item is centred with the traffic lights by the
//  system; a taller bar drawn by hand would have to move the traffic lights,
//  which AppKit puts back on every resize and full-screen transition. Compact
//  is the nearest height that keeps the two on one line.
//
//  What New recording captures is not the window's to decide. The composition
//  root hands it the same start every surface runs, with the capture the
//  island's chip and the menu share; Workspace cannot see that choice, which
//  is the island's, and must not keep a second one.
//

import DesignSystem
import Foundation
import Recording
import SwiftUI

/// What the title bar offers, as a value: decided in one place and exercised
/// without a window.
enum TitleBarState: Equatable, Sendable {
    /// At rest, and the model is on disk: New recording.
    case newRecording
    /// At rest, and New recording is held back for this reason.
    case waiting(String)
    /// A session records: the clock since `startedAt`, and Stop.
    case recording(startedAt: Date)
    /// A session is being torn down. New recording is held back with nothing
    /// to say: a start now would race the stop, and the phase lasts as long
    /// as a save does.
    case stopping

    /// Capture wins over everything: whatever the model is doing, a live
    /// session is what the user is doing. The work after a stop never holds
    /// New recording back — the session preempts its own pass for a new
    /// recording, as the shortcut's press does.
    static func resolve(phase: RecordingPhase, readiness: RecordingReadiness) -> TitleBarState {
        switch phase {
        case .recording(let startedAt, _):
            return .recording(startedAt: startedAt)
        case .stopping:
            return .stopping
        case .idle, .finalizing, .summarizing:
            return readiness.waitingFor.map(TitleBarState.waiting) ?? .newRecording
        }
    }
}

/// The title bar's toolbar item, at the bar's trailing end. A window with no
/// split view lays its toolbar out from the leading edge, beside the traffic
/// lights, whatever the placement says — so a flexible space goes first. The
/// glass a toolbar item wears from macOS 26 is turned off: the design draws
/// the button on the bar itself.
struct TitleBarToolbar: ToolbarContent {
    let startRecording: () -> Void

    var body: some ToolbarContent {
        if #available(macOS 26.0, *) {
            ToolbarSpacer(.flexible)
            ToolbarItem(placement: .automatic) {
                TitleBarItem(startRecording: startRecording)
            }
            .sharedBackgroundVisibility(.hidden)
        } else {
            ToolbarItem(placement: .automatic) {
                Spacer()
            }
            ToolbarItem(placement: .automatic) {
                TitleBarItem(startRecording: startRecording)
            }
        }
    }
}

/// Reads the session and draws what it amounts to.
private struct TitleBarItem: View {
    @Environment(RecordingSession.self) private var session

    let startRecording: () -> Void

    var body: some View {
        TitleBarControls(
            state: TitleBarState.resolve(phase: session.phase, readiness: session.readiness),
            startRecording: startRecording,
            stop: { Task { await session.stop() } }
        )
    }
}

/// The controls for one state, drawn from values alone.
struct TitleBarControls: View {
    let state: TitleBarState
    let startRecording: () -> Void
    let stop: () -> Void

    var body: some View {
        switch state {
        case .newRecording:
            newRecording
        case .waiting(let reason):
            HStack(spacing: EchoSpacing.m) {
                Text(reason)
                    .font(EchoFont.control)
                    .foregroundStyle(EchoColor.textQuaternary)
                    .lineLimit(1)
                newRecording
                    .disabled(true)
            }
            // One element, so VoiceOver reads the reason with the button it
            // holds back rather than as a stray line beside it.
            .accessibilityElement(children: .combine)
        case .stopping:
            newRecording
                .disabled(true)
        case .recording(let startedAt):
            HStack(spacing: EchoSpacing.s) {
                RunningClock(startedAt: startedAt)
                Button(action: stop) {
                    PrimaryLabel("Stop", glyph: StopSquareGlyph())
                }
                .buttonStyle(.echoPrimary)
                .fixedSize()
            }
        }
    }

    /// Never narrower than its words: beside a long reason, it is the reason
    /// that gives way.
    private var newRecording: some View {
        Button(action: startRecording) {
            PrimaryLabel("New recording", glyph: RecordGlyph())
        }
        .buttonStyle(.echoPrimary)
        .fixedSize()
    }
}

/// A primary button's label with the glyph the design puts before it, in the
/// label's own ink — so a held-back button greys both.
private struct PrimaryLabel<Glyph: Shape>: View {
    let title: String
    let glyph: Glyph

    init(_ title: String, glyph: Glyph) {
        self.title = title
        self.glyph = glyph
    }

    var body: some View {
        HStack(spacing: EchoControl.primaryButtonGap) {
            glyph
                .fill(.foreground)
                .frame(width: EchoControl.primaryButtonGlyphSize, height: EchoControl.primaryButtonGlyphSize)
                .accessibilityHidden(true)
            Text(title)
        }
    }
}

/// The session's clock in its red pill. Whole seconds from the start, ticked
/// by the timeline rather than stored, so it is never a second ahead of the
/// meeting.
private struct RunningClock: View {
    let startedAt: Date

    var body: some View {
        TimelineView(.periodic(from: startedAt, by: 1)) { context in
            let clock = EchoClock.compact(EchoClock.elapsedSeconds(since: startedAt, now: context.date))
            HStack(spacing: EchoControl.timerPillGap) {
                Circle()
                    .fill(EchoColor.recording)
                    .frame(width: EchoControl.recordingDotSize, height: EchoControl.recordingDotSize)
                Text(clock)
                    .font(EchoFont.mono())
                    .foregroundStyle(EchoColor.recordingTimer)
            }
            .frame(height: EchoControl.primaryButtonHeight)
            .padding(.horizontal, EchoControl.timerPillInset)
            .background(EchoColor.recordingWash, in: .rect(cornerRadius: EchoRadius.control))
            .overlay {
                RoundedRectangle(cornerRadius: EchoRadius.control)
                    .strokeBorder(EchoColor.recordingWashEdge, lineWidth: 1)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Recording")
            .accessibilityValue(clock)
        }
    }
}

/// Stop's square, on the artboards' 16 × 16 grid. Larger than the island's
/// Stop square: the title bar's artboard draws it that way.
private nonisolated struct StopSquareGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        let grid = GlyphGrid(rect: rect)
        let origin = grid.point(2, 2)
        let side = grid.length(12)
        return Path(
            roundedRect: CGRect(x: origin.x, y: origin.y, width: side, height: side),
            cornerRadius: grid.length(2.4),
            style: .continuous
        )
    }
}
