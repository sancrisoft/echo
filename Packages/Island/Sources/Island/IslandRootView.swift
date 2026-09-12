//
//  IslandRootView.swift
//  Island
//
//  What is inside the shell, for now.
//
//  The six faces the design draws — their icons, their two lines of copy, the
//  timer, the gauges, the countdown ring — are their own work. What is here is
//  the minimum that makes the shell a real surface rather than a black shape:
//  every control the state machine below has a verb for, wired to that verb,
//  plus the one mark that tells a collapsed recording apart from a collapsed
//  nothing. Anything that would need a number, a name or a second line waits
//  for the faces.
//
//  It is presentation only. Detection's taps go straight to the machine that
//  owns the decision, and the two that are not detection's — record and stop
//  from the idle and recording faces — are the same calls every other surface
//  makes.
//

import CallDetection
import DesignSystem
import Recording
import SwiftUI

struct IslandRootView: View {

    let controller: IslandController
    let detector: CallDetector
    let session: RecordingSession

    var body: some View {
        if let metrics = controller.metrics {
            IslandShell(
                geometry: IslandShellGeometry(
                    metrics: metrics,
                    face: controller.face,
                    isExpanded: controller.isExpanded
                ),
                isExpanded: controller.isExpanded,
                leadingEar: { leadingEar },
                trailingEar: { EmptyView() },
                row: { row }
            )
            // A different display is a different shell, not the same one
            // changing size. Without this the spring is handed a move from a
            // notched shell on one screen to a pill on another — different
            // width, height, radius, flares and shadow — while the window it
            // lives in has already teleported, and the two together read as a
            // blink. Giving the shell the screen's identity makes the crossing
            // a cut, which is the only honest way to draw it.
            .id(metrics.displayID)
        }
    }

    // MARK: - Collapsed

    /// The one thing a collapsed shell says in this layer: a session is live.
    /// Everything else it will say — the timer, the level glyph, the app a
    /// call was noticed in — is a face.
    @ViewBuilder
    private var leadingEar: some View {
        if controller.face == .recording {
            Circle()
                .fill(EchoColor.Island.recording)
                .frame(width: EchoControl.recordingDotSize, height: EchoControl.recordingDotSize)
        }
    }

    // MARK: - Expanded

    /// The controls of the face that is open, right-aligned, in the design's
    /// order: quiet, then secondary, then primary, at most one primary each.
    private var row: some View {
        HStack(spacing: EchoControl.capsuleGap) {
            Spacer(minLength: EchoSpacing.s)
            controls
        }
    }

    @ViewBuilder
    private var controls: some View {
        switch controller.face {
        case .idle:
            recordButton

        case .callDetected:
            Button {
                detector.dismissTapped()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.islandIcon)
            Button("Record") { detector.startTapped() }
                .buttonStyle(.islandPrimary)

        case .recording:
            // Stop is offered while capture is live and not while the session
            // is being torn down: the phase that follows it is not idle, and a
            // second Stop must not start a second teardown.
            if session.phase.isRecording {
                Button("Stop") { Task { await session.stop() } }
                    .buttonStyle(.islandPrimary)
            }

        case .callEnded:
            // The countdown's two answers exist only while there is a
            // countdown. Between "Stop now" and the meeting reaching disk the
            // machine has already cancelled the deadline and the face has not
            // changed yet — it cannot, the stop has to finish first, because
            // "saved" must not appear before the meeting is saved. Offering
            // two answers to a question that has been answered is what that
            // gap would otherwise look like.
            if detector.graceDeadline != nil {
                Button("Stop now") { detector.stopNowTapped() }
                    .buttonStyle(.islandQuiet)
                Button("Keep recording") { detector.keepRecordingTapped() }
                    .buttonStyle(.islandPrimary)
            }

        case .saved:
            Button("Open meeting") { detector.openEchoTapped() }
                .buttonStyle(.islandPrimary)

        case .summarizing:
            // Nothing to decide, so no control: the design gives this face no
            // primary either.
            EmptyView()
        }
    }

    /// The app's way into a recording that no call was noticed for. Everything
    /// — the menu bar, the window, the island — runs this same gated start.
    private var recordButton: some View {
        Button("Record") { Task { await session.start() } }
            .buttonStyle(.islandPrimary)
    }
}
