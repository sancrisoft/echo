//
//  IslandFaces.swift
//  Island
//
//  What each face says: the one open row and the two ears it collapses into.
//
//  Every view here is drawn from values — a name, a deadline, a meeting — and
//  hands its taps back as closures. None of them reads the detector or the
//  session, so the gallery can put every face on one sheet with fixtures, and
//  what a face shows is decided by whoever builds it (`IslandRootView`), in
//  one place.
//
//  The row follows the artboards' one shape: a glyph, two lines, and the
//  controls at the end, quiet then secondary then primary.
//

import Audio
import CallDetection
import DesignSystem
import Recording
import SwiftUI

// MARK: - The shape every open face shares

/// A glyph, two lines, and the controls at the end.
struct FaceRow<Icon: View, First: View, Second: View, Controls: View>: View {

    private let lineGap: CGFloat
    private let icon: Icon
    private let first: First
    private let second: Second
    private let controls: Controls

    init(
        lineGap: CGFloat = EchoLayout.islandLineGap,
        @ViewBuilder icon: () -> Icon,
        @ViewBuilder first: () -> First,
        @ViewBuilder second: () -> Second,
        @ViewBuilder controls: () -> Controls
    ) {
        self.lineGap = lineGap
        self.icon = icon()
        self.first = first()
        self.second = second()
        self.controls = controls()
    }

    var body: some View {
        HStack(spacing: EchoLayout.islandRowGap) {
            icon
            VStack(alignment: .leading, spacing: lineGap) {
                first
                second
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: EchoControl.capsuleGap) { controls }
                .fixedSize()
        }
    }
}

extension Text {

    /// A face's first line.
    fileprivate func faceTitle() -> some View {
        font(EchoFont.islandTitle)
            .tracking(EchoFont.islandTitleTracking)
            .foregroundStyle(EchoColor.Island.title)
            .lineLimit(1)
    }

    /// A face's second line, or the qualifier at the end of its first. It
    /// gives way first when a line is too long for its face.
    fileprivate func faceDetail() -> some View {
        font(EchoFont.islandDetail)
            .foregroundStyle(EchoColor.Island.detail)
            .lineLimit(1)
            .truncationMode(.tail)
    }
}

/// A glyph at the head of an open face, or in an ear.
private func glyph<S: Shape>(_ shape: S, _ ink: Color, size: CGFloat) -> some View {
    shape.fill(ink).frame(width: size, height: size)
}

/// The capsule every face that offers a recording ends with.
private func recordCapsule(_ action: @escaping () -> Void) -> some View {
    Button(action: action) {
        CapsuleLabel(title: "Record", glyph: RecordGlyph(), ink: EchoColor.Island.recording)
    }
    .buttonStyle(.islandPrimary)
}

/// The ✕ that dismisses a face.
private func dismissButton(_ action: @escaping () -> Void) -> some View {
    Button(action: action) {
        Image(systemName: "xmark")
    }
    .buttonStyle(.islandIcon)
    .accessibilityLabel("Dismiss")
}

// MARK: - Idle

/// Nothing is happening. Open only under the pointer: the app's way into a
/// recording that no call was noticed for. Its ears are empty — the shell is
/// the cutout.
struct IdleRow: View {

    let lastMeeting: IslandMeeting?
    let capture: String
    let chooseCapture: () -> Void
    let record: () -> Void

    var body: some View {
        // The one face whose second line is a control, and the tallest for it:
        // tight first line, compact gap, so it fits the band under a cutout.
        FaceRow(lineGap: EchoLayout.islandCompactLineGap) {
            EchoMark(size: EchoControl.islandIconSize, ink: EchoColor.Island.accent)
        } first: {
            HStack(alignment: .firstTextBaseline, spacing: EchoLayout.islandTitleGap) {
                Text("Echo").faceTitle()
                if let lastMeeting {
                    Text(FaceText.lastMeeting(lastMeeting)).faceDetail()
                }
            }
            .frame(height: EchoFont.islandTitleLineHeight)
        } second: {
            ValueChip(capture, action: chooseCapture)
        } controls: {
            recordCapsule(record)
        }
    }
}

// MARK: - Call detected

/// A call was noticed and a recording is offered. The button says Record and
/// nothing more: the line above it already names the call.
struct CallDetectedRow: View {

    let app: String
    let scoped: Bool
    let dismiss: () -> Void
    let record: () -> Void

    var body: some View {
        FaceRow {
            glyph(CameraGlyph(), EchoColor.Island.earStatus, size: EchoControl.islandIconSize)
        } first: {
            Text(FaceText.callNoticed(app)).faceTitle()
        } second: {
            Text(FaceText.callDetail(app: app, scoped: scoped)).faceDetail()
        } controls: {
            dismissButton(dismiss)
            recordCapsule(record)
        }
    }
}

struct CallDetectedEars {

    let app: String

    var leading: some View {
        glyph(CameraGlyph(), EchoColor.Island.earStatus, size: EchoControl.earGlyphSize)
    }

    var trailing: some View {
        Text(app)
            .font(EchoFont.islandEarName)
            .foregroundStyle(EchoColor.Island.title)
            .lineLimit(1)
    }
}

// MARK: - Recording

/// A session is live: the clock, what is being captured, and the two levels,
/// measured. While the session is stopping the clock holds where it stopped
/// and the levels rest, because nothing is being captured any more.
struct RecordingRow: View {

    /// When the live session began; `nil` once it is stopping.
    let startedAt: Date?
    /// What the clock reads once the session has stopped running.
    let stoppedAt: Int
    let capture: String
    let levels: () -> CaptureLevels
    /// `nil` while the session is stopping: a second Stop must not start a
    /// second teardown.
    let stop: (() -> Void)?

    var body: some View {
        FaceRow {
            RecordingDot(blinks: startedAt != nil)
        } first: {
            TimelineView(.periodic(from: startedAt ?? .now, by: 1)) { context in
                HStack(alignment: .firstTextBaseline, spacing: EchoLayout.islandTitleGap) {
                    Text(EchoClock.full(elapsed(at: context.date)))
                        .font(EchoFont.islandTimer)
                        .tracking(EchoFont.islandTimerTracking)
                        .foregroundStyle(EchoColor.Island.title)
                        .lineLimit(1)
                        .fixedSize()
                        .frame(height: EchoFont.islandTimerLineHeight)
                    Spacer(minLength: 0)
                    Text(capture).faceDetail()
                }
            }
        } second: {
            // Redrawn as often as a level can change on screen, and only while
            // there is something to measure.
            TimelineView(.animation(minimumInterval: 1.0 / 30, paused: startedAt == nil)) { _ in
                let now = startedAt == nil ? .silent : levels()
                HStack(spacing: EchoLayout.islandGaugeGap) {
                    LevelGauge("You", level: now.you, tone: .accent)
                    LevelGauge("Others", level: now.others, tone: .neutral)
                }
            }
        } controls: {
            if let stop {
                Button(action: stop) {
                    CapsuleLabel(title: "Stop", glyph: StopGlyph(), ink: EchoColor.Island.controlLabel)
                }
                .buttonStyle(.islandPrimary)
            }
        }
    }

    private func elapsed(at date: Date) -> Int {
        guard let startedAt else { return stoppedAt }
        return EchoClock.elapsedSeconds(since: startedAt, now: date)
    }
}

struct RecordingEars {

    let startedAt: Date?
    let stoppedAt: Int

    var leading: some View {
        HStack(spacing: EchoControl.earGroupGap) {
            RecordingDot(blinks: false)
            LevelBarsGlyph()
        }
    }

    var trailing: some View {
        TimelineView(.periodic(from: startedAt ?? .now, by: 1)) { context in
            Text(
                EchoClock.compact(startedAt.map { EchoClock.elapsedSeconds(since: $0, now: context.date) } ?? stoppedAt)
            )
            .font(EchoFont.islandEarNumber)
            .foregroundStyle(EchoColor.Island.title)
            .lineLimit(1)
            .fixedSize()
        }
    }
}

/// The red dot that says a session is live. On the open face it blinks;
/// with Reduce Motion, or once the session has stopped, it holds still.
struct RecordingDot: View {

    let blinks: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dim = false

    var body: some View {
        Circle()
            .fill(EchoColor.Island.recording)
            .frame(width: EchoControl.recordingDotSize, height: EchoControl.recordingDotSize)
            .opacity(blinks && !reduceMotion && dim ? EchoMotion.recordingBlinkDim : 1)
            .animation(
                blinks && !reduceMotion ? EchoMotion.recordingBlink : nil,
                value: dim
            )
            .onAppear { dim = true }
            .accessibilityHidden(true)
    }
}

// MARK: - Call ended

/// The call ended under a live recording and the stop is counting down. Two
/// answers, and the countdown read from the detector's own deadline.
struct CallEndedRow: View {

    let app: String
    let deadline: Date?
    /// `nil` once the countdown has been answered and the stop is under way:
    /// a question that has been answered keeps no answers on screen.
    let answers: (stopNow: () -> Void, keep: () -> Void)?

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20, paused: deadline == nil)) { context in
            FaceRow {
                CountdownRing(
                    size: EchoControl.islandIconSize,
                    remaining: FaceText.graceLeft(
                        until: deadline, now: context.date, grace: CallDetectionTiming.endGrace)
                )
            } first: {
                Text(FaceText.callEnded(app)).faceTitle()
            } second: {
                Text("Auto-stop in \(FaceText.secondsLeft(until: deadline, now: context.date)) s").faceDetail()
            } controls: {
                if let answers {
                    Button("Stop now", action: answers.stopNow).buttonStyle(.islandQuiet)
                    Button("Keep recording", action: answers.keep).buttonStyle(.islandPrimary)
                }
            }
        }
    }
}

struct CallEndedEars {

    let deadline: Date?

    var leading: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20, paused: deadline == nil)) { context in
            CountdownRing(
                size: EchoControl.earGlyphSize,
                remaining: FaceText.graceLeft(until: deadline, now: context.date, grace: CallDetectionTiming.endGrace)
            )
        }
    }

    /// The seconds alone. The artboard writes "stopping 8s", which is
    /// wider than the ear beside a real cutout; the ring before it already
    /// says what is counting down.
    var trailing: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { context in
            Text("\(FaceText.secondsLeft(until: deadline, now: context.date))s")
                .font(EchoFont.islandEarNumber)
                .foregroundStyle(EchoColor.Island.recording)
                .lineLimit(1)
                .fixedSize()
        }
    }
}

// MARK: - Saved

/// The meeting is on disk. Shown once, then it retracts.
struct SavedRow: View {

    let meeting: IslandMeeting?
    let dismiss: () -> Void
    let open: () -> Void

    var body: some View {
        FaceRow {
            glyph(CheckGlyph(), EchoColor.Island.accent, size: EchoControl.islandCheckSize)
        } first: {
            Text(meeting?.title ?? "Meeting").faceTitle()
        } second: {
            Text(FaceText.saved(meeting)).faceDetail()
        } controls: {
            dismissButton(dismiss)
            Button("Open meeting", action: open).buttonStyle(.islandPrimary)
        }
    }
}

struct SavedEars {

    var leading: some View {
        glyph(CheckGlyph(), EchoColor.Island.accent, size: EchoControl.earGlyphSize)
    }

    var trailing: some View {
        Text("Saved")
            .font(EchoFont.islandEarStatus)
            .foregroundStyle(EchoColor.Island.earStatus)
            .lineLimit(1)
    }
}

// MARK: - After the stop

/// The work after a stop: the transcription pass, then the summary. One face
/// for both, because the design draws one, with each pass named for what it
/// is — the pass in the words the window's own "finalizing" state uses — and
/// nothing to decide, so no primary.
struct SummarizingRow: View {

    /// Which of the two passes is running.
    let pass: AfterStopPass
    let meeting: IslandMeeting?
    let dismiss: () -> Void
    let open: (() -> Void)?

    var body: some View {
        FaceRow {
            Spinner(size: EchoControl.islandSpinnerSize)
        } first: {
            HStack(alignment: .firstTextBaseline, spacing: EchoLayout.islandTitleGap) {
                Text(FaceText.afterStopTitle(pass)).faceTitle()
                Spacer(minLength: 0)
                Text("on device").faceDetail()
            }
        } second: {
            Text(FaceText.afterStopDetail(meeting)).faceDetail()
        } controls: {
            dismissButton(dismiss)
            if let open {
                Button("Open", action: open).buttonStyle(.islandSecondary)
            }
        }
    }
}

/// The spinner, and no word. The artboard's "Summarizing" is wider than the
/// ear beside a real cutout, and an ear with half a word in it says less than
/// one with none.
struct SummarizingEars {

    var leading: some View {
        Spinner(size: EchoControl.earGlyphSize)
    }

    var trailing: some View {
        EmptyView()
    }
}

/// The two passes that run after a stop.
enum AfterStopPass: Equatable {
    case transcript
    case summary
}
