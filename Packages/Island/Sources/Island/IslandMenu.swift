//
//  IslandMenu.swift
//  Island
//
//  The island in words, for the two surfaces that cannot draw it: the menu bar
//  item, which says beside the mark what the collapsed island says in its
//  ears, and the item's menu, which holds what the open face offers.
//
//  Both read the same sources the faces read and say it in the faces' own
//  words (`FaceText`), so the bar, the menu and the island cannot disagree.
//  The island's switch decides only whether the PANEL is up: the menu is the
//  same with the island on or off, because it is also the keyboard's and
//  VoiceOver's way to everything the island does (#119). What the item shows
//  beside the mark is the switch's business, and the item's (DEC-1, product
//  owner 2026-10-02).
//
//  Values, not `NSMenuItem`s: the menu is built where the item lives, and what
//  it holds is settled here, in one place, where a test can read it.
//

import Audio
import CallDetection
import DesignSystem
import Foundation
import Recording

/// What the collapsed island says in its ears, as the menu bar item says it.
public nonisolated enum IslandEars: Equatable, Sendable {

    /// Nothing to say: the mark alone.
    case none
    /// A call was noticed: the name of its app.
    case call(app: String)
    /// A session is live: its clock. `nil` while the session is stopping and
    /// the clock has stopped with it.
    case clock(startedAt: Date?)
    /// The call ended and the stop is counting down. `nil` once the countdown
    /// has been answered and the stop is under way.
    case countdown(deadline: Date?)
    /// The meeting is on disk.
    case saved
    /// The work after a stop.
    case afterStop(AfterStopPass)

    /// The words, at `now`. `nil` for the mark alone — and for a clock that
    /// has stopped, whose last reading is the item's to keep.
    public func text(now: Date) -> String? {
        switch self {
        case .none: nil
        case .call(let app): app.isEmpty ? nil : app
        case .clock(let startedAt): startedAt.map { EchoClock.compact(EchoClock.elapsedSeconds(since: $0, now: now)) }
        case .countdown(let deadline): FaceText.stopping(FaceText.secondsLeft(until: deadline, now: now))
        case .saved: FaceText.savedEar
        case .afterStop(let pass): FaceText.afterStopEar(pass)
        }
    }

    /// Whether the words are the recording red: the live clock, and the
    /// countdown to its stop. Everything else is the bar's own ink.
    public var isRecordingRed: Bool {
        switch self {
        case .clock, .countdown: true
        case .none, .call, .saved, .afterStop: false
        }
    }

    /// Whether the words change on their own, second by second.
    public var ticks: Bool {
        switch self {
        case .clock(let startedAt): startedAt != nil
        case .countdown(let deadline): deadline != nil
        case .none, .call, .saved, .afterStop: false
        }
    }
}

/// One line of the island's part of the menu.
public struct IslandMenuEntry {

    public enum Kind {
        /// A line that says what is happening and does nothing.
        case status
        /// A command.
        case action(() -> Void)
        /// The capture choice, as a submenu of its options.
        case choice([Option])
    }

    /// One option of a choice.
    public struct Option {
        public let title: String
        public let isSelected: Bool
        public let pick: () -> Void

        public init(title: String, isSelected: Bool, pick: @escaping () -> Void) {
            self.title = title
            self.isSelected = isSelected
            self.pick = pick
        }
    }

    public let title: String
    public let kind: Kind
    public let isEnabled: Bool
    /// Whether this is the command the global shortcut runs right now — Record
    /// at rest, Stop while recording — so the menu can show the shortcut
    /// beside it.
    public let takesShortcut: Bool

    public init(title: String, kind: Kind, isEnabled: Bool = true, takesShortcut: Bool = false) {
        self.title = title
        self.kind = kind
        self.isEnabled = isEnabled
        self.takesShortcut = takesShortcut
    }
}

/// What the island's sources say at one instant: everything the ears and the
/// menu are decided from, as values a test can write down.
nonisolated struct IslandReading: Sendable {
    var detection: IslandFace?
    var appsInCall: [ProcessSelector] = []
    var graceDeadline: Date?
    var phase: RecordingPhase = .idle
    var capture: CaptureScope = .everything
    var captureOptions: [CaptureScope] = [.everything]
    var savedMeeting: IslandMeeting?
    /// The session's notices, in its order.
    var notices: [String] = []
    /// Whether a recording can start.
    var readiness: RecordingReadiness = .ready

    var face: IslandShellFace {
        IslandShellFace.resolve(detection: detection, phase: phase)
    }

    var noticedCall: (app: String, scoped: Bool) {
        IslandReading.noticedCall(detection: detection, appsInCall: appsInCall)
    }

    var endedCallApp: String {
        IslandReading.endedCallApp(detection: detection, appsInCall: appsInCall)
    }

    /// The call the detector noticed: the name its offer carries, or — once
    /// the offer has shrunk to its pill, which carries none — the app the
    /// detector attributes the call to. Both come from the one list, so they
    /// cannot disagree.
    static func noticedCall(detection: IslandFace?, appsInCall: [ProcessSelector]) -> (app: String, scoped: Bool) {
        if case .startPrompt(let app, let scoped) = detection { return (app, scoped) }
        if let first = appsInCall.first { return (first.displayName, first.scopeable) }
        return ("", false)
    }

    /// The app whose call ended under the countdown.
    static func endedCallApp(detection: IslandFace?, appsInCall: [ProcessSelector]) -> String {
        if case .endGrace(let app) = detection { return app }
        return appsInCall.first?.displayName ?? ""
    }
}

/// Everything the menu can ask for: the same calls the faces make.
struct IslandMenuActions {
    var record: (CaptureScope) -> Void
    var pickCapture: (CaptureScope) -> Void
    var stop: () -> Void
    var recordCall: () -> Void
    var dismiss: () -> Void
    var stopNow: () -> Void
    var keepRecording: () -> Void
    var openSaved: () -> Void
    var openMeeting: (UUID) -> Void
    var retryModel: () -> Void
}

extension IslandEars {

    /// What the collapsed island says in its ears, for this reading.
    nonisolated init(_ reading: IslandReading) {
        switch reading.face {
        case .idle: self = .none
        case .callDetected: self = .call(app: reading.noticedCall.app)
        case .recording: self = .clock(startedAt: reading.phase.startedAt)
        case .callEnded: self = .countdown(deadline: reading.graceDeadline)
        case .saved: self = .saved
        case .summarizing: self = .afterStop(reading.phase.afterStopPass)
        }
    }
}

extension IslandMenuEntry {

    /// The open face's line and commands for this reading, at `now`.
    static func entries(for reading: IslandReading, now: Date, actions: IslandMenuActions) -> [IslandMenuEntry] {
        // Why a recording cannot start, for the two faces that offer one: the
        // reason as a line, Record held back, and the artboard's Retry once
        // the fetch has failed — the one way to run it again short of a
        // relaunch.
        let waiting = reading.readiness.waitingFor
        var waitingEntries: [IslandMenuEntry] {
            guard let waiting else { return [] }
            var entries = [IslandMenuEntry(title: waiting, kind: .status)]
            if case .downloadFailed = reading.readiness {
                entries.append(IslandMenuEntry(title: "Retry", kind: .action(actions.retryModel)))
            }
            return entries
        }

        switch reading.face {
        case .idle:
            let current = reading.capture
            let record = IslandMenuEntry(
                title: "Record", kind: .action({ actions.record(current) }), isEnabled: waiting == nil,
                takesShortcut: true)
            // Nothing to choose while there is nothing to record with, as on
            // the face.
            guard waiting == nil else { return waitingEntries + [record] }
            return [
                record,
                IslandMenuEntry(
                    title: ScopeSelection.label(for: current),
                    kind: .choice(
                        reading.captureOptions.map { option in
                            Option(
                                title: ScopeSelection.label(for: option),
                                isSelected: option == current,
                                pick: { actions.pickCapture(option) })
                        })),
            ]

        case .callDetected:
            return [IslandMenuEntry(title: FaceText.callNoticed(reading.noticedCall.app), kind: .status)]
                + waitingEntries
                + [
                    IslandMenuEntry(title: "Record", kind: .action(actions.recordCall), isEnabled: waiting == nil),
                    IslandMenuEntry(title: "Dismiss", kind: .action(actions.dismiss)),
                ]

        case .recording:
            // The phase that follows Stop is not idle, so a second Stop has
            // to be impossible, not merely harmless: while the session is
            // being torn down there is no clock and no command, as on the
            // face.
            guard case .recording(let startedAt, let scope) = reading.phase else { return [] }
            let clock = EchoClock.full(EchoClock.elapsedSeconds(since: startedAt, now: now))
            // The capture's problems, as the face shows them in place of its
            // levels: a menu has room for each on its own line.
            return [IslandMenuEntry(title: "\(clock) · \(ScopeSelection.label(for: scope))", kind: .status)]
                + reading.notices.map { IslandMenuEntry(title: $0, kind: .status) }
                + [IslandMenuEntry(title: "Stop", kind: .action(actions.stop), takesShortcut: true)]

        case .callEnded:
            let deadline = reading.graceDeadline
            let status = IslandMenuEntry(
                title: "\(FaceText.callEnded(reading.endedCallApp)) · "
                    + FaceText.autoStop(FaceText.secondsLeft(until: deadline, now: now)),
                kind: .status)
            // The countdown's two answers exist only while there is a
            // countdown, as on the face.
            guard deadline != nil else { return [status] }
            return [
                status,
                IslandMenuEntry(title: "Stop now", kind: .action(actions.stopNow)),
                IslandMenuEntry(title: "Keep recording", kind: .action(actions.keepRecording)),
            ]

        case .saved:
            return [
                IslandMenuEntry(title: reading.savedMeeting?.title ?? "Meeting", kind: .status),
                IslandMenuEntry(title: "Open meeting", kind: .action(actions.openSaved)),
            ]

        case .summarizing:
            let status = IslandMenuEntry(title: FaceText.afterStopTitle(reading.phase.afterStopPass), kind: .status)
            guard let meetingID = reading.phase.meetingID else { return [status] }
            return [status, IslandMenuEntry(title: "Open", kind: .action({ actions.openMeeting(meetingID) }))]
        }
    }
}

/// The island's sources, read for the menu bar.
@MainActor
public struct IslandMenu {

    private let detector: CallDetector
    private let session: RecordingSession
    private let meetings: IslandMeetings
    private let capture: CaptureChoice
    private let openMeeting: (UUID) -> Void

    /// The same sources the island's faces read, and the same `openMeeting`
    /// the island's post-stop face uses.
    public init(
        detector: CallDetector,
        session: RecordingSession,
        meetings: IslandMeetings,
        capture: CaptureChoice,
        openMeeting: @escaping (UUID) -> Void
    ) {
        self.detector = detector
        self.session = session
        self.meetings = meetings
        self.capture = capture
        self.openMeeting = openMeeting
    }

    /// What the collapsed island would say in its ears.
    public var ears: IslandEars {
        IslandEars(reading)
    }

    /// The open face's line and commands, at `now`, as the menu lists them.
    public func entries(now: Date) -> [IslandMenuEntry] {
        IslandMenuEntry.entries(for: reading, now: now, actions: actions)
    }

    /// Read where it is used, so whoever asks inside an observation tracks
    /// exactly the sources it depends on.
    private var reading: IslandReading {
        IslandReading(
            detection: detector.face,
            appsInCall: detector.appsInCall,
            graceDeadline: detector.graceDeadline,
            phase: session.phase,
            capture: capture.current,
            captureOptions: capture.options,
            savedMeeting: session.savedMeeting(in: meetings),
            notices: session.notices.map(\.message),
            readiness: session.readiness
        )
    }

    private var actions: IslandMenuActions {
        IslandMenuActions(
            record: { [session] scope in Task { await session.start(scope: scope) } },
            pickCapture: { [capture] scope in capture.pick(scope) },
            stop: { [session] in Task { await session.stop() } },
            recordCall: { [detector] in detector.startTapped() },
            dismiss: { [detector] in detector.dismissTapped() },
            stopNow: { [detector] in detector.stopNowTapped() },
            keepRecording: { [detector] in detector.keepRecordingTapped() },
            openSaved: { [detector] in detector.openEchoTapped() },
            openMeeting: openMeeting,
            retryModel: { [session] in session.retryTranscriptionModel() }
        )
    }
}

// MARK: - What the sources say, once for every surface

extension CallDetector {

    /// See `IslandReading.noticedCall(detection:appsInCall:)`.
    var noticedCall: (app: String, scoped: Bool) {
        IslandReading.noticedCall(detection: face, appsInCall: appsInCall)
    }

    /// See `IslandReading.endedCallApp(detection:appsInCall:)`.
    var endedCallApp: String {
        IslandReading.endedCallApp(detection: face, appsInCall: appsInCall)
    }
}

extension RecordingSession {

    /// The meeting the saved face is about: the one the session is carrying
    /// through its passes, or — once those are done — the newest one.
    func savedMeeting(in meetings: IslandMeetings) -> IslandMeeting? {
        currentMeetingID.flatMap(meetings.meeting) ?? meetings.latest()
    }
}

extension RecordingPhase {

    /// Which pass the post-stop face reports.
    nonisolated var afterStopPass: AfterStopPass {
        if case .finalizing = self { return .transcript }
        return .summary
    }
}
