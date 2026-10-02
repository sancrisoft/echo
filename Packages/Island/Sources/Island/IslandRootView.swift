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
    let meetings: IslandMeetings

    /// The capture the user picked from the idle face's chip. Transient, and
    /// the view's own: it does not outlive the call that offered it
    /// (`ScopeSelection.effective`), and it means nothing once Record is
    /// pressed.
    @State private var pickedScope: CaptureScope?

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
                leadingEar: { leadingEar },
                trailingEar: { trailingEar },
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
            .onChange(of: session.phase) { old, new in
                if case .recording(let startedAt, let scope) = old, !new.isRecording {
                    stoppedAt = EchoClock.elapsedSeconds(since: startedAt, now: .now)
                    stoppedScope = scope
                }
            }
        }
    }

    // MARK: - What the sources say

    /// What Record will capture right now.
    private var capture: CaptureScope {
        ScopeSelection.effective(picked: pickedScope, appsInCall: detector.appsInCall)
    }

    /// The call the detector noticed: the name its offer carries, or — once
    /// the offer has shrunk to its pill, which carries none — the app the
    /// detector attributes the call to. Both come from the one list, so they
    /// cannot disagree.
    private var noticedCall: (app: String, scoped: Bool) {
        if case .startPrompt(let app, let scoped) = detector.face { return (app, scoped) }
        if let first = detector.appsInCall.first { return (first.displayName, first.scopeable) }
        return ("", false)
    }

    private var endedCallApp: String {
        if case .endGrace(let app) = detector.face { return app }
        return detector.appsInCall.first?.displayName ?? ""
    }

    /// The meeting the saved face is about: the one the session is carrying
    /// through its passes, or — once those are done — the newest one.
    private var savedMeeting: IslandMeeting? {
        session.currentMeetingID.flatMap(meetings.meeting) ?? meetings.latest()
    }

    private var recordingScope: CaptureScope {
        session.phase.captureScope ?? stoppedScope
    }

    // MARK: - Collapsed

    @ViewBuilder
    private var leadingEar: some View {
        switch controller.face {
        case .idle, .summarizing: EmptyView()
        case .callDetected: CallDetectedEars(app: noticedCall.app).leading
        case .recording: RecordingEars(startedAt: session.phase.startedAt, stoppedAt: stoppedAt).leading
        case .callEnded: CallEndedEars(deadline: detector.graceDeadline).leading
        case .saved: SavedEars().leading
        }
    }

    @ViewBuilder
    private var trailingEar: some View {
        switch controller.face {
        case .idle, .summarizing: EmptyView()
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
                capture: ScopeSelection.label(for: capture),
                chooseCapture: chooseCapture,
                record: record
            )

        case .callDetected:
            CallDetectedRow(
                app: noticedCall.app,
                scoped: noticedCall.scoped,
                dismiss: { detector.dismissTapped() },
                record: { detector.startTapped() }
            )

        case .recording:
            RecordingRow(
                startedAt: session.phase.startedAt,
                stoppedAt: stoppedAt,
                capture: ScopeSelection.label(for: recordingScope),
                levels: { session.levels },
                // Stop is offered while capture is live and not while the
                // session is being torn down: the phase that follows it is not
                // idle, and a second Stop must not start a second teardown.
                stop: session.phase.isRecording ? { Task { await session.stop() } } : nil
            )

        case .callEnded:
            CallEndedRow(
                app: endedCallApp,
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
            // The summarizing face is its own work (#112).
            EmptyView()
        }
    }

    // MARK: - Taps

    private func chooseCapture() {
        let options = ScopeSelection.options(appsInCall: detector.appsInCall)
        if let picked = controller.chooseCapture(options, selected: capture) {
            pickedScope = picked
        }
    }

    /// The app's way into a recording that no call was noticed for. Everything
    /// — the menu bar, the window, the island — runs this same gated start;
    /// the island alone passes the capture its chip shows.
    private func record() {
        let scope = capture
        Task { await session.start(scope: scope) }
    }
}
