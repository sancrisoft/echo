//
//  IslandMenuTests.swift
//  IslandTests
//
//  The island in words: what the menu bar item says beside the mark, and what
//  the menu offers, for every face — the table the product owner approved on
//  2026-10-02, in the faces' own words.
//

import Audio
import CallDetection
import Foundation
import Recording
import Testing

@testable import Island

@Suite("The island, in words")
struct IslandMenuTests {

    nonisolated static let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
    nonisolated static let zoom = ProcessSelector(displayName: "Zoom", bundlePrefix: "us.zoom.xos")
    nonisolated static let meeting = UUID()
    static let gocoinvest = IslandMeeting(title: "GoCoInvest onboarding", duration: 58 * 60, words: 5_512)

    /// Every command, counted.
    final class Calls {
        var made: [String] = []
        var recorded: [CaptureScope] = []
        var picked: [CaptureScope] = []
        var opened: [UUID] = []

        var actions: IslandMenuActions {
            IslandMenuActions(
                record: { self.recorded.append($0) },
                pickCapture: { self.picked.append($0) },
                stop: { self.made.append("stop") },
                recordCall: { self.made.append("recordCall") },
                dismiss: { self.made.append("dismiss") },
                stopNow: { self.made.append("stopNow") },
                keepRecording: { self.made.append("keep") },
                openSaved: { self.made.append("openSaved") },
                openMeeting: { self.opened.append($0) }
            )
        }
    }

    private func entries(_ reading: IslandReading, _ calls: Calls = Calls()) -> [IslandMenuEntry] {
        IslandMenuEntry.entries(for: reading, now: Self.now, actions: calls.actions)
    }

    private func titles(_ entries: [IslandMenuEntry]) -> [String] { entries.map(\.title) }

    private func perform(_ entry: IslandMenuEntry) {
        if case .action(let run) = entry.kind { run() }
    }

    private func isStatus(_ entry: IslandMenuEntry) -> Bool {
        if case .status = entry.kind { return true }
        return false
    }

    // MARK: The menu, face by face

    @Test("at rest: Record with the shortcut, and the capture choice")
    func atRest() throws {
        let calls = Calls()
        let reading = IslandReading(
            appsInCall: [Self.zoom], capture: .app(Self.zoom), captureOptions: [.app(Self.zoom), .everything])
        let menu = entries(reading, calls)
        #expect(titles(menu) == ["Record", "Zoom only"])
        #expect(menu[0].takesShortcut)

        perform(menu[0])
        #expect(calls.recorded == [.app(Self.zoom)])

        guard case .choice(let options) = menu[1].kind else {
            Issue.record("the capture choice is not a submenu")
            return
        }
        #expect(options.map(\.title) == ["Zoom only", "Everything"])
        #expect(options.map(\.isSelected) == [true, false])
        options[1].pick()
        #expect(calls.picked == [.everything])
    }

    @Test("a call noticed: the call named, then Record and Dismiss, which are detection's")
    func aCallNoticed() {
        let calls = Calls()
        let menu = entries(IslandReading(detection: .startPrompt(appName: "Zoom", scoped: true)), calls)
        #expect(titles(menu) == ["Zoom call detected", "Record", "Dismiss"])
        #expect(isStatus(menu[0]))
        #expect(menu.allSatisfy { !$0.takesShortcut }, "the approved table shows the shortcut on rest and live only")
        menu.dropFirst().forEach(perform)
        #expect(calls.made == ["recordCall", "dismiss"])
    }

    @Test("a live session: its clock and capture, then Stop with the shortcut")
    func aLiveSession() {
        let calls = Calls()
        let phase = RecordingPhase.recording(startedAt: Self.now.addingTimeInterval(-761), scope: .app(Self.zoom))
        let menu = entries(IslandReading(phase: phase), calls)
        #expect(titles(menu) == ["00:12:41 · Zoom only", "Stop"])
        #expect(isStatus(menu[0]))
        #expect(menu[1].takesShortcut)
        perform(menu[1])
        #expect(calls.made == ["stop"])
    }

    @Test("a live session's capture problems follow its clock, one line each, in the session's order")
    func aLiveSessionWithNotices() {
        let phase = RecordingPhase.recording(startedAt: Self.now.addingTimeInterval(-761), scope: .everything)
        let menu = entries(IslandReading(phase: phase, notices: ["Microphone unavailable", "Echo degraded"]))
        #expect(titles(menu) == ["00:12:41 · Everything", "Microphone unavailable", "Echo degraded", "Stop"])
        #expect(menu.prefix(3).allSatisfy(isStatus))
    }

    @Test("notices take the face's line most important first, so a cut never reaches the first")
    func noticesInOneLine() {
        #expect(FaceText.notices(["first", "second"]) == "first · second")
        #expect(FaceText.notices(["only"]) == "only")
    }

    @Test("a session being torn down offers no second Stop")
    func stoppingOffersNothing() {
        #expect(entries(IslandReading(phase: .stopping)).isEmpty)
    }

    @Test("the call ended: the countdown, then Stop now and Keep recording")
    func theCallEnded() {
        let calls = Calls()
        let reading = IslandReading(
            detection: .endGrace(appName: "Zoom"),
            graceDeadline: Self.now.addingTimeInterval(8),
            phase: .recording(startedAt: Self.now.addingTimeInterval(-761), scope: .everything))
        let menu = entries(reading, calls)
        #expect(titles(menu) == ["Zoom call ended · Auto-stop in 8 s", "Stop now", "Keep recording"])
        menu.dropFirst().forEach(perform)
        #expect(calls.made == ["stopNow", "keep"])
    }

    @Test("an answered countdown keeps its line and loses its answers")
    func anAnsweredCountdown() {
        let reading = IslandReading(detection: .endGrace(appName: "Zoom"), phase: .stopping)
        #expect(titles(entries(reading)) == ["Zoom call ended · Auto-stop in 0 s"])
    }

    @Test("saved: the meeting's title, then Open meeting")
    func saved() {
        let calls = Calls()
        let menu = entries(IslandReading(detection: .saved, savedMeeting: Self.gocoinvest), calls)
        #expect(titles(menu) == ["GoCoInvest onboarding", "Open meeting"])
        perform(menu[1])
        #expect(calls.made == ["openSaved"])
    }

    @Test("after the stop: the pass named as the face names it, then Open")
    func afterTheStop() {
        let calls = Calls()
        let summary = entries(IslandReading(phase: .summarizing(meetingID: Self.meeting)), calls)
        #expect(titles(summary) == ["Writing the summary", "Open"])
        perform(summary[1])
        #expect(calls.opened == [Self.meeting])

        let pass = entries(IslandReading(phase: .finalizing(meetingID: Self.meeting, progress: 0.4)))
        #expect(titles(pass) == ["Finalizing transcript…", "Open"])
    }

    // MARK: Beside the mark

    @Test(
        "the ears, face by face, in the design's full words",
        arguments: [
            (IslandReading(), nil),
            (IslandReading(detection: .startPrompt(appName: "Zoom", scoped: true)), "Zoom"),
            (IslandReading(detection: .compactPill, appsInCall: [zoom]), "Zoom"),
            (
                IslandReading(phase: .recording(startedAt: now.addingTimeInterval(-761), scope: .everything)),
                "12:41"
            ),
            (
                IslandReading(detection: .endGrace(appName: "Zoom"), graceDeadline: now.addingTimeInterval(8)),
                "stopping 8s"
            ),
            (IslandReading(detection: .saved), "Saved"),
            (IslandReading(phase: .summarizing(meetingID: meeting)), "Summarizing"),
            (IslandReading(phase: .finalizing(meetingID: meeting, progress: 0.2)), "Finalizing"),
        ] as [(IslandReading, String?)])
    func theEars(reading: IslandReading, expected: String?) {
        #expect(IslandEars(reading).text(now: Self.now) == expected)
    }

    @Test("only the live clock and the countdown to its stop are red")
    func whichEarsAreRed() {
        #expect(IslandEars.clock(startedAt: Self.now).isRecordingRed)
        #expect(IslandEars.countdown(deadline: Self.now).isRecordingRed)
        for ears in [IslandEars.none, .call(app: "Zoom"), .saved, .afterStop(.summary)] {
            #expect(!ears.isRecordingRed, "\(ears)")
        }
    }

    @Test("only a running clock or countdown ticks")
    func whichEarsTick() {
        #expect(IslandEars.clock(startedAt: Self.now).ticks)
        #expect(!IslandEars.clock(startedAt: nil).ticks)
        #expect(IslandEars.countdown(deadline: Self.now).ticks)
        #expect(!IslandEars.countdown(deadline: nil).ticks)
        #expect(!IslandEars.saved.ticks)
    }

    @Test("a call with no name says nothing beside the mark rather than an empty word")
    func aNamelessCall() {
        #expect(IslandEars.call(app: "").text(now: Self.now) == nil)
    }
}

@Suite("The capture choice")
struct CaptureChoiceTests {

    static let zoom = ProcessSelector(displayName: "Zoom", bundlePrefix: "us.zoom.xos")

    @Test("a pick made on one surface is what every surface records")
    func onePickForEverySurface() {
        var apps = [Self.zoom]
        let choice = CaptureChoice(appsInCall: { apps })
        #expect(choice.current == .app(Self.zoom))
        choice.pick(.everything)
        #expect(choice.current == .everything)

        // And it does not outlive the call that offered it.
        choice.pick(.app(Self.zoom))
        apps = []
        #expect(choice.current == .everything)
        #expect(choice.options == [.everything])
    }
}
