//
//  IslandRootView.swift
//  Island
//
//  What is inside the shell: the face the controller resolved, built from what
//  the detector, the session and the library say right now.
//
//  This is the one place that turns live sources into the values a face draws
//  (`IslandFaces.swift`) and its taps back into calls. Detection's taps go
//  straight to the machine that owns the decision; the two that are not
//  detection's — Record and Stop from the idle and recording faces — are the
//  same calls every other surface makes.
//

import Audio
import CallDetection
import DesignSystem
import Recording
import SwiftUI

struct IslandRootView: View {

    let controller: IslandController
    let detector: CallDetector
    let session: RecordingSession
    let capture: CaptureChoice
    let meetings: IslandMeetings
    let openMeeting: (UUID) -> Void

    /// Where the clock stopped and what was being captured, kept from the
    /// moment the session left `.recording`. The stopping phase carries
    /// neither, and the face still has to show a clock that has stopped
    /// rather than one that has vanished.
    @State private var stoppedAt = 0
    @State private var stoppedScope: CaptureScope = .everything

    var body: some View {
        if let metrics = controller.metrics {
            IslandShell(
                geometry: IslandShellGeometry(
                    metrics: metrics,
                    face: controller.face,
                    isExpanded: controller.isExpanded
                ),
                isExpanded: controller.isExpanded,
                progress: progress,
                leadingEar: { leadingEar },
                trailingEar: { trailingEar },
                row: { row }
            )
            // A different display is a different shell, not the same one
            // changing size. Without this the spring is handed a move from the
            // shell on one screen to the shell on another — a different
            // cutout, so a different width and height — while the window it
            // lives in has already teleported, and the two together read as a
            // blink. Giving the shell the screen's identity makes the crossing
            // a cut, which is the only honest way to draw it.
            .id(metrics.displayID)
            .onChange(of: session.phase) { old, new in
                if case .recording(let startedAt, let scope) = old, !new.isRecording {
                    stoppedAt = EchoClock.elapsedSeconds(since: startedAt, now: .now)
                    stoppedScope = scope
                }
            }
        }
    }

    // MARK: - What the sources say

    private var noticedCall: (app: String, scoped: Bool) { detector.noticedCall }

    private var savedMeeting: IslandMeeting? { session.savedMeeting(in: meetings) }

    private var recordingScope: CaptureScope {
        session.phase.captureScope ?? stoppedScope
    }

    /// The progress the shell draws along its bottom edge, only where there
    /// is a real one: the transcription pass reports its own clamped fraction.
    /// The summary reports none the island could read, so it gets no line
    /// rather than a guessed one.
    private var progress: Double? {
        guard controller.face == .summarizing, case .finalizing(_, let fraction) = session.phase else {
            return nil
        }
        return fraction
    }

    // MARK: - Collapsed

    @ViewBuilder
    private var leadingEar: some View {
        switch controller.face {
        case .idle: EmptyView()
        case .summarizing: SummarizingEars().leading
        case .callDetected: CallDetectedEars(app: noticedCall.app).leading
        case .recording: RecordingEars(startedAt: session.phase.startedAt, stoppedAt: stoppedAt).leading
        case .callEnded: CallEndedEars(deadline: detector.graceDeadline).leading
        case .saved: SavedEars().leading
        }
    }

    @ViewBuilder
    private var trailingEar: some View {
        switch controller.face {
        case .idle: EmptyView()
        case .summarizing: SummarizingEars().trailing
        case .callDetected: CallDetectedEars(app: noticedCall.app).trailing
        case .recording: RecordingEars(startedAt: session.phase.startedAt, stoppedAt: stoppedAt).trailing
        case .callEnded: CallEndedEars(deadline: detector.graceDeadline).trailing
        case .saved: SavedEars().trailing
        }
    }

    // MARK: - Expanded

    @ViewBuilder
    private var row: some View {
        switch controller.face {
        case .idle:
            IdleRow(
                lastMeeting: meetings.latest(),
                capture: CaptureChoice.label(for: capture.current),
                chooseCapture: chooseCapture,
                record: record,
                waitingFor: FaceText.waitingFor(session.readiness)
            )

        case .callDetected:
            CallDetectedRow(
                app: noticedCall.app,
                scoped: noticedCall.scoped,
                dismiss: { detector.dismissTapped() },
                record: { detector.startTapped() },
                waitingFor: FaceText.waitingFor(session.readiness)
            )

        case .recording:
            RecordingRow(
                startedAt: session.phase.startedAt,
                stoppedAt: stoppedAt,
                capture: ScopeSelection.label(for: recordingScope),
                levels: { session.levels },
                // In the order the session ranks them, which is the order
                // `RecordingNotice.Kind` declares.
                notices: session.notices.map(\.message),
                // Stop is offered while capture is live and not while the
                // session is being torn down: the phase that follows it is not
                // idle, and a second Stop must not start a second teardown.
                stop: session.phase.isRecording ? { Task { await session.stop() } } : nil
            )

        case .callEnded:
            CallEndedRow(
                app: detector.endedCallApp,
                deadline: detector.graceDeadline,
                // The countdown's two answers exist only while there is a
                // countdown. Between "Stop now" and the meeting reaching disk
                // the machine has already cancelled the deadline and the face
                // has not changed yet — it cannot, because "saved" must not
                // appear before the meeting is saved.
                answers: detector.graceDeadline == nil
                    ? nil
                    : (stopNow: { detector.stopNowTapped() }, keep: { detector.keepRecordingTapped() })
            )

        case .saved:
            SavedRow(
                meeting: savedMeeting,
                dismiss: { detector.dismissTapped() },
                open: { detector.openEchoTapped() }
            )

        case .summarizing:
            let meetingID = session.phase.meetingID
            SummarizingRow(
                pass: session.phase.afterStopPass,
                meeting: meetingID.flatMap(meetings.meeting),
                dismiss: { controller.foldUntilPointerLeaves() },
                open: meetingID.map { id in { openMeeting(id) } }
            )
        }
    }

    // MARK: - Taps

    private func chooseCapture() {
        if let picked = controller.chooseCapture(capture.options, selected: capture.current) {
            capture.pick(picked)
        }
    }

    /// The app's way into a recording that no call was noticed for. Everything
    /// — the menu bar, the window, the island — runs this same gated start,
    /// with the capture the chip and the menu share.
    private func record() {
        let scope = capture.current
        Task { await session.start(scope: scope) }
    }
}
