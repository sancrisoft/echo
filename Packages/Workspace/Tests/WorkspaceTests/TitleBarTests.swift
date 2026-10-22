//
//  TitleBarTests.swift
//  WorkspaceTests
//
//  What the title bar offers is a rule over the session — capture wins, a
//  teardown holds New recording back, and the model's readiness says why —
//  so the rule is checked as a value, and the controls by rendering them: a
//  title bar that changes height between states is a title bar that jumps.
//

import AppKit
import DesignSystem
import Foundation
import Recording
import SwiftUI
import Testing

@testable import Workspace

@Suite("The title bar")
struct TitleBarTests {

    private static let startedAt = Date(timeIntervalSince1970: 1_756_900_000)

    // MARK: The rule

    @Test("at rest with the model on disk, New recording")
    func atRest() {
        #expect(TitleBarState.resolve(phase: .idle, readiness: .ready) == .newRecording)
    }

    @Test(
        "at rest without the model, New recording is held back with the reason the island gives",
        arguments: [
            RecordingReadiness.waitingToDownload, .downloading(0.41), .downloadFailed("The download stalled."),
        ])
    func waitingForTheModel(readiness: RecordingReadiness) throws {
        let reason = try #require(readiness.waitingFor)
        #expect(TitleBarState.resolve(phase: .idle, readiness: readiness) == .waiting(reason))
    }

    @Test("the work after a stop never holds New recording back")
    func postStopWorkDoesNotBlock() {
        let meeting = UUID()
        #expect(
            TitleBarState.resolve(phase: .finalizing(meetingID: meeting, progress: 0.3), readiness: .ready)
                == .newRecording)
        #expect(TitleBarState.resolve(phase: .summarizing(meetingID: meeting), readiness: .ready) == .newRecording)
    }

    @Test("a live session wins over whatever the model is doing")
    func captureWins() {
        let phase = RecordingPhase.recording(startedAt: Self.startedAt, scope: .everything)
        #expect(TitleBarState.resolve(phase: phase, readiness: .ready) == .recording(startedAt: Self.startedAt))
        #expect(
            TitleBarState.resolve(phase: phase, readiness: .downloadFailed("No network."))
                == .recording(startedAt: Self.startedAt))
    }

    @Test("a teardown offers no second start and no second stop")
    func stopping() {
        #expect(TitleBarState.resolve(phase: .stopping, readiness: .ready) == .stopping)
    }

    // MARK: The controls

    private func render(_ state: TitleBarState, _ scheme: ColorScheme = .dark) throws -> CGImage {
        let renderer = ImageRenderer(
            content: TitleBarControls(state: state, startRecording: {}, stop: {})
                .fixedSize()
                .background(EchoColor.windowBackground)
                .environment(\.colorScheme, scheme))
        renderer.scale = 2
        return try #require(renderer.cgImage, "the title bar rendered nothing for \(state)")
    }

    @Test("every state is the height of the button the design draws")
    func oneHeight() throws {
        let states: [TitleBarState] = [
            .newRecording, .waiting("Transcription · 41%"), .stopping, .recording(startedAt: Self.startedAt),
        ]
        for state in states {
            #expect(try render(state).height == Int(EchoControl.primaryButtonHeight * 2), "\(state)")
        }
    }

    @Test("held back, New recording keeps its size and changes what it is drawn in")
    func heldBackKeepsItsShape() throws {
        let ready = try render(.newRecording)
        let heldBack = try render(.stopping)
        #expect(ready.width == heldBack.width)
        #expect(ready.dataProvider?.data != heldBack.dataProvider?.data)
    }

    @Test("the reason is drawn beside the button, not instead of it")
    func theReasonSitsBeside() throws {
        let button = try render(.stopping)
        let withReason = try render(.waiting("Transcription · Waiting to download"))
        #expect(withReason.width > button.width + Int(EchoSpacing.m * 2))
    }

    @Test("beside a reason with too little room, the reason gives way and the button keeps its words")
    func theButtonNeverShrinks() throws {
        // The held-back button on its own, and the same button at the right
        // end of a bar too narrow for its reason. If the button gave way, its
        // pixels at the end of the bar would differ from its pixels alone.
        let alone = try render(.stopping)
        let renderer = ImageRenderer(
            content: TitleBarControls(
                state: .waiting("Transcription · Not enough space on this Mac — 1.4 GB free, 3.3 GB needed."),
                startRecording: {}, stop: {}
            )
            // Trailing, as the toolbar puts it: the button at the bar's end.
            .frame(width: 260, alignment: .trailing)
            .background(EchoColor.windowBackground)
            .environment(\.colorScheme, .dark))
        renderer.scale = 2
        let squeezed = try #require(renderer.cgImage)
        #expect(squeezed.width == 520)
        #expect(alone.width + Int(EchoSpacing.m * 2) < squeezed.width, "the fixture leaves the reason no room")

        let end = try #require(
            squeezed.cropping(
                to: CGRect(x: squeezed.width - alone.width, y: 0, width: alone.width, height: alone.height)))
        // Not byte for byte: the button lands on a half point at the bar's
        // end, and the renderer's rounding moves a channel by up to 2 there
        // (measured). A button that gave way differs in whole glyphs — most
        // of its bytes, by far more than this.
        let pairs = zip(try rgba(end), try rgba(alone))
        #expect(pairs.allSatisfy { abs(Int($0) - Int($1)) <= 8 }, "the button gave way to its reason")
    }

    /// A render's pixels as bytes, so two renders from the same run can be
    /// compared with each other. Never with a value from the design.
    private func rgba(_ image: CGImage) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = try #require(
            CGContext(
                data: &bytes, width: image.width, height: image.height, bitsPerComponent: 8,
                bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return bytes
    }

    // MARK: For the eye

    @Test("every state renders in both appearances")
    func forTheEye() throws {
        EchoFont.registerBundledTypefaces()
        let states: [(String, TitleBarState)] = [
            ("new-recording", .newRecording),
            ("waiting", .waiting("Transcription · 41%")),
            ("failed", .waiting("Transcription · The download stalled.")),
            ("stopping", .stopping),
            ("recording", .recording(startedAt: Date.now.addingTimeInterval(-761))),
        ]
        for (name, state) in states {
            for (appearance, scheme) in [("light", ColorScheme.light), ("dark", .dark)] {
                let image = try render(state, scheme)
                Attachment.record(image, named: "title-bar-\(name)-\(appearance).png")
            }
        }
    }
}
