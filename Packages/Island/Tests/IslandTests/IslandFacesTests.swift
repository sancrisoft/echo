//
//  IslandFacesTests.swift
//  IslandTests
//
//  What the faces say, and whether it fits. The sentences are pure functions
//  of what they report, so they are settled here rather than read off a
//  screen; the fit is measured by rendering each open row with the artboards'
//  own fixtures, the way a face's width is a measurement and not a choice.
//

import CallDetection
import DesignSystem
import Foundation
import Recording
import SwiftUI
import Testing

@testable import Island

private let meeting = IslandMeeting(title: "GoCoInvest onboarding", duration: 58 * 60, words: 5_512)

@Suite("What the faces say")
struct FaceTextTests {

    @Test(
        "a meeting's length rounds to the minute, the window's own rule",
        arguments: [(20.0, "1 min"), (89.0, "1 min"), (3_480.0, "58 min"), (4_320.0, "1 h 12 min")]
    )
    func duration(seconds: TimeInterval, expected: String) {
        #expect(FaceText.duration(seconds) == expected)
    }

    @Test("the idle face names the last meeting's length")
    func lastMeeting() {
        #expect(FaceText.lastMeeting(meeting) == "Last meeting · 58 min")
    }

    @Test("the saved line says what is known, and words only once they are")
    func saved() {
        let words = 5_512.formatted()
        #expect(FaceText.saved(meeting) == "Saved · 58 min · \(words) words")
        let untranscribed = IslandMeeting(title: "Meeting", duration: 58 * 60, words: nil)
        #expect(FaceText.saved(untranscribed) == "Saved · 58 min")
        #expect(FaceText.saved(IslandMeeting(title: "Meeting", duration: 600, words: 0)) == "Saved · 10 min")
        #expect(FaceText.saved(nil) == "Saved")
    }

    @Test("a call reads as a sentence, named or not")
    func callTitles() {
        #expect(FaceText.callNoticed("Zoom") == "Zoom call detected")
        #expect(FaceText.callNoticed("") == "Call detected")
        #expect(FaceText.callEnded("Zoom") == "Zoom call ended")
        #expect(FaceText.callEnded("") == "Call ended")
    }

    /// An unscopeable call is recorded as Everything, and the offer must not
    /// promise less than the recording will capture.
    @Test("the offer never promises less than it records")
    func callDetail() {
        #expect(FaceText.callDetail(app: "Zoom", scoped: true) == "Mic and Zoom audio, kept apart")
        #expect(FaceText.callDetail(app: "FaceTime", scoped: false) == "Mic and system audio, kept apart")
    }

    @Test("the countdown rounds up, and a cleared deadline is zero")
    func secondsLeft() {
        let now = Date(timeIntervalSinceReferenceDate: 1_000)
        #expect(FaceText.secondsLeft(until: now.addingTimeInterval(8), now: now) == 8)
        #expect(FaceText.secondsLeft(until: now.addingTimeInterval(7.2), now: now) == 8)
        #expect(FaceText.secondsLeft(until: now.addingTimeInterval(0.1), now: now) == 1)
        #expect(FaceText.secondsLeft(until: now.addingTimeInterval(-3), now: now) == 0)
        #expect(FaceText.secondsLeft(until: nil, now: now) == 0)
    }

    @Test("the ring is the part of the grace still to run, clamped")
    func graceLeft() {
        let now = Date(timeIntervalSinceReferenceDate: 1_000)
        let grace = CallDetectionTiming.endGrace
        #expect(FaceText.graceLeft(until: now.addingTimeInterval(grace), now: now, grace: grace) == 1)
        #expect(FaceText.graceLeft(until: now.addingTimeInterval(grace / 2), now: now, grace: grace) == 0.5)
        #expect(FaceText.graceLeft(until: now.addingTimeInterval(grace * 2), now: now, grace: grace) == 1)
        #expect(FaceText.graceLeft(until: now.addingTimeInterval(-1), now: now, grace: grace) == 0)
        #expect(FaceText.graceLeft(until: nil, now: now, grace: grace) == 0)
    }
}

/// Each open row, measured at its ideal size.
@MainActor
private func measure(_ row: some View) -> CGSize {
    _ = EchoFont.registerBundledTypefaces()
    let renderer = ImageRenderer(content: row.fixedSize())
    renderer.scale = 1
    return renderer.nsImage?.size ?? .zero
}

/// The room a face's open row has: its expanded width less the row's insets,
/// and the band the 14" cutout leaves under it.
private func room(for width: IslandWidth) -> CGSize {
    let band = EchoLayout.islandExpandedHeight - IslandMetrics(IslandMetricsTests.macBookPro14).collapsedHeight
    return CGSize(
        width: width.expanded - EchoLayout.islandRowLeadingInset - EchoLayout.islandRowTrailingInset,
        height: band
    )
}

@Suite("Whether the faces fit")
struct FaceFitTests {

    private let start = Date.now.addingTimeInterval(-761)

    /// The artboards' fixtures, which are the longest lines each face was
    /// sized for: a face whose words outgrow its width is a measurement to
    /// retake in `IslandWidth`, not a frame to widen here.
    @Test("every open face fits its width and the band under a cutout")
    func everyFaceFits() {
        let rows: [(String, IslandWidth, CGSize)] = [
            (
                "idle", .idle,
                measure(IdleRow(lastMeeting: meeting, capture: "Everything", chooseCapture: {}, record: {}))
            ),
            (
                "call detected", .callDetected,
                measure(CallDetectedRow(app: "Zoom", scoped: true, dismiss: {}, record: {}))
            ),
            (
                "recording", .recording,
                measure(
                    RecordingRow(
                        startedAt: start, stoppedAt: 0, capture: "Zoom only", levels: { .silent }, stop: {}))
            ),
            (
                "call ended", .callEnded,
                measure(
                    CallEndedRow(
                        app: "Zoom", deadline: .now.addingTimeInterval(8), answers: (stopNow: {}, keep: {})))
            ),
            ("saved", .saved, measure(SavedRow(meeting: meeting, dismiss: {}, open: {}))),
        ]
        for (name, width, drawn) in rows {
            let available = room(for: width)
            #expect(drawn.width <= available.width, "\(name) is \(drawn.width) wide, room for \(available.width)")
            #expect(drawn.height <= available.height, "\(name) is \(drawn.height) tall, room for \(available.height)")
        }
    }
}
