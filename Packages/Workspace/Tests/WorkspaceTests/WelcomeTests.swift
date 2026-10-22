//
//  WelcomeTests.swift
//  WorkspaceTests
//
//  The welcome screen: when it shows at launch, what each of its three steps
//  says and offers, when the user can go on and why not yet — the product
//  owner's answers of 2026-10-19 for everything the design does not
//  draw — and the screen itself, rendered for the eye in both appearances.
//

import AppKit
import DesignSystem
import Foundation
import Recording
import SwiftUI
import Testing

@testable import Workspace

@Suite("The welcome screen")
struct WelcomeTests {

    // MARK: When it shows

    @Test(
        "it shows the first time, and again while it has not been left and the models are not both on disk",
        arguments: [
            (firstLaunch: true, left: false, onDisk: true, shows: true),
            (firstLaunch: true, left: false, onDisk: false, shows: true),
            (firstLaunch: false, left: false, onDisk: false, shows: true),
            (firstLaunch: false, left: false, onDisk: true, shows: false),
            (firstLaunch: false, left: true, onDisk: false, shows: false),
            (firstLaunch: true, left: true, onDisk: false, shows: false),
        ] as [(firstLaunch: Bool, left: Bool, onDisk: Bool, shows: Bool)])
    func gate(firstLaunch: Bool, left: Bool, onDisk: Bool, shows: Bool) {
        #expect(
            WelcomeGate.showsAtLaunch(firstLaunch: firstLaunch, hasLeftWelcome: left, modelsOnDisk: onDisk) == shows)
    }

    @Test @MainActor func theWindowPresentsAndLeavesIt() {
        let workspace = WorkspaceModel()
        #expect(!workspace.showsWelcome)
        workspace.presentWelcome()
        #expect(workspace.showsWelcome)
        workspace.leaveWelcome()
        #expect(!workspace.showsWelcome)
    }

    // MARK: The steps

    private func steps(
        microphone: CaptureAccess = .granted, systemAudio: CaptureAccess = .granted,
        transcription: RecordingReadiness = .ready, summary: SummaryReadiness = .ready
    ) -> WelcomeSteps {
        WelcomeSteps(microphone: microphone, systemAudio: systemAudio, transcription: transcription, summary: summary)
    }

    @Test("never asked offers Allow, denied offers System Settings, granted says Allowed")
    func permissionControls() {
        #expect(WelcomeSteps.control(for: .undecided) == .allow)
        #expect(WelcomeSteps.control(for: .denied) == .openSettings)
        #expect(WelcomeSteps.control(for: .granted) == .allowed)
    }

    @Test("Start waits for everything; Record without notes for all but the summary model")
    func theWayOn() {
        #expect(steps().canStart)
        #expect(steps().canRecordWithoutNotes)
        #expect(steps().waitingOn == nil)

        let noNotesYet = steps(summary: .downloading(0.41))
        #expect(!noNotesYet.canStart)
        #expect(noNotesYet.canRecordWithoutNotes)

        for blocked in [
            steps(microphone: .undecided), steps(systemAudio: .denied), steps(transcription: .downloading(0.2)),
        ] {
            #expect(!blocked.canStart)
            #expect(!blocked.canRecordWithoutNotes)
        }
    }

    @Test("the reason names the first step missing, in the rows' order")
    func waitingOn() {
        #expect(
            steps(microphone: .undecided, systemAudio: .undecided, summary: .waitingToDownload).waitingOn
                == "Waiting on the microphone.")
        #expect(steps(systemAudio: .denied, summary: .paused).waitingOn == "Waiting on System Audio Recording.")
        #expect(steps(transcription: .downloading(0.4)).waitingOn == "Waiting on the models.")
        #expect(steps(summary: .failed("x")).waitingOn == "Waiting on the models.")
    }

    @Test("each step's glyph: done, pending, or working while a model comes down or into memory")
    func progress() {
        #expect(steps().microphoneProgress == .done)
        #expect(steps(microphone: .denied).microphoneProgress == .pending)
        #expect(steps(systemAudio: .undecided).systemAudioProgress == .pending)
        #expect(steps().modelsProgress == .done)
        #expect(steps(transcription: .downloading(0.1)).modelsProgress == .working)
        #expect(steps(summary: .downloading(0.1)).modelsProgress == .working)
        #expect(steps(summary: .loading).modelsProgress == .working)
        #expect(steps(summary: .paused).modelsProgress == .pending)
        #expect(steps(transcription: .downloadFailed("x")).modelsProgress == .pending)
    }

    @Test("a model line holds its bar while it comes down or once in, and the panel's words otherwise")
    func modelSlots() {
        #expect(steps(transcription: .downloading(0.734)).transcriptionSlot == .downloading(percent: 73))
        #expect(steps().transcriptionSlot == .onDisk(size: OnDeviceModel.transcription.size))
        #expect(steps().summarySlot == .onDisk(size: OnDeviceModel.summary.size))
        #expect(steps(summary: .paused).summarySlot == .panel(.summary(.paused)))
        #expect(steps(summary: .incomplete).summarySlot == .panel(.summary(.incomplete)))
        #expect(
            steps(summary: .failed("Not enough space")).summarySlot == .panel(.summary(.failed("Not enough space"))))
        #expect(
            steps(transcription: .waitingToDownload).transcriptionSlot == .panel(.transcription(.waitingToDownload)))
    }

    @Test("the footer writes the data folder under the home folder with a tilde")
    func footerPath() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let echo = home.appending(path: "Library/Application Support/Echo", directoryHint: .isDirectory)
        #expect(WelcomeScreen.abbreviated(echo) == "~/Library/Application Support/Echo")
        let elsewhere = URL(filePath: "/private/tmp/echo-root/", directoryHint: .isDirectory)
        #expect(WelcomeScreen.abbreviated(elsewhere) == "/private/tmp/echo-root")
    }

    // MARK: For the eye

    @Test @MainActor func theScreenRendersInBothAppearances() throws {
        EchoFont.registerBundledTypefaces()
        // Fixtures for the eye, never shown together by the app: the
        // artboard's own moment, the very first one, the last one, and the
        // undrawn states of a model line.
        let sheets: [(String, WelcomeSteps)] = [
            ("as-drawn", steps(systemAudio: .denied, summary: .downloading(0.41))),
            (
                "first-moment",
                steps(
                    microphone: .undecided, systemAudio: .undecided, transcription: .downloading(0.12),
                    summary: .waitingToDownload)
            ),
            ("done", steps()),
            (
                "undrawn",
                steps(
                    transcription: .downloadFailed("The network connection was lost."),
                    summary: .failed("Not enough space on this Mac — 1.4 GB free, 3.3 GB needed."))
            ),
            ("paused", steps(summary: .paused)),
        ]
        for (name, sheet) in sheets {
            for (appearance, scheme) in [("light", ColorScheme.light), ("dark", .dark)] {
                let renderer = ImageRenderer(
                    content: WelcomeColumn(steps: sheet, dataFolder: "~/Library/Application Support/Echo") { _ in }
                        .frame(width: EchoLayout.welcomeColumnWidth)
                        .padding(40)
                        .background(EchoColor.windowBackground)
                        .environment(\.colorScheme, scheme))
                renderer.scale = 2
                let image = try #require(renderer.cgImage)
                #expect(image.width == Int((EchoLayout.welcomeColumnWidth + 80) * 2))
                Attachment.record(image, named: "welcome-\(name)-\(appearance).png")
            }
        }
    }
}
