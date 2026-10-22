//
//  ModelsPanelTests.swift
//  WorkspaceTests
//
//  The models panel says, per model, what the design draws for each
//  state — its sentence, its state on the right and the one action the state
//  offers — and is gone once both models are ready. Each action reaches the
//  verb its model's owner has, and the transcription model, which has no
//  pause, never offers one.
//

import AppKit
import DesignSystem
import Recording
import SwiftUI
import Testing

@testable import Workspace

@Suite("The models panel")
struct ModelsPanelTests {

    @Test("once both models are ready the panel is gone")
    func goneWhenBothAreReady() {
        #expect(ModelRow.rows(transcription: .ready, summary: .ready).isEmpty)
        #expect(
            ModelRow.rows(transcription: .ready, summary: .downloading(0.4)).map(\.model) == [.transcription, .summary])
        #expect(
            ModelRow.rows(transcription: .waitingToDownload, summary: .ready).map(\.model) == [
                .transcription, .summary,
            ])
    }

    @Test(
        "the transcription model's states, as drawn, with no Pause",
        arguments: [
            (RecordingReadiness.waitingToDownload, ModelRow.Status.words("Waiting to download"), ModelRow.Action?.none),
            (.downloading(0.414), .progress(percent: 41), nil),
            (.downloadFailed("No network."), .actionOnly, .retry),
            (.ready, .ready, nil),
        ])
    func transcriptionStates(readiness: RecordingReadiness, status: ModelRow.Status, action: ModelRow.Action?) {
        let row = ModelRow.transcription(readiness)
        #expect(row.status == status)
        #expect(row.action == action)
        #expect(row.isFailure == (action == .retry))
    }

    @Test(
        "the summary model's states, as drawn",
        arguments: [
            (SummaryReadiness.waitingToDownload, ModelRow.Status.words("Waiting to download"), ModelRow.Action?.none),
            (.downloading(0.41), .progress(percent: 41), .pause),
            (.paused, .words("Paused"), .resume),
            (.incomplete, .words("Download incomplete"), .resumeDownload),
            (.loading, .loading, nil),
            (.ready, .ready, nil),
            (.failed("Not enough space"), .actionOnly, .retry),
        ])
    func summaryStates(readiness: SummaryReadiness, status: ModelRow.Status, action: ModelRow.Action?) {
        let row = ModelRow.summary(readiness)
        #expect(row.status == status)
        #expect(row.action == action)
        #expect(row.isFailure == (action == .retry))
    }

    @Test("each row says one honest sentence about what its model is doing")
    func sentences() {
        let transcription = ModelRow.transcription(.downloading(0.2))
        #expect(transcription.detail.hasPrefix("Transcribes each meeting after it ends"))
        // The licence's credit travels with the model's name.
        #expect(transcription.detail.hasSuffix(OnDeviceModel.transcription.attribution ?? "missing"))
        #expect(ModelRow.summary(.ready).detail == "Writes the meeting notes after each recording")
        #expect(ModelRow.summary(.paused).detail == "Paused by you. Resuming skips what is already on disk.")
        #expect(
            ModelRow.summary(.loading).detail
                == "On disk. Coming into memory for this meeting, and released again when it goes idle.")
        // A failure's sentence is its reason, and nothing else.
        #expect(ModelRow.summary(.failed("Not enough space on this Mac.")).detail == "Not enough space on this Mac.")
        #expect(ModelRow.transcription(.downloadFailed("No network.")).detail == "No network.")
    }

    @Test("an interrupted download shows no percentage, because nothing could honestly say one")
    func noPercentageWhenIncomplete() {
        let row = ModelRow.summary(.incomplete)
        guard case .words = row.status else {
            Issue.record("an interrupted download drew a figure")
            return
        }
    }

    @Test("every button reaches its model owner's own verb")
    func verbs() {
        #expect(ModelsPanel.verb(for: .retry, on: .transcription) == .retryTranscription)
        #expect(ModelsPanel.verb(for: .pause, on: .summary) == .pauseSummary)
        #expect(ModelsPanel.verb(for: .resume, on: .summary) == .resumeSummary)
        #expect(ModelsPanel.verb(for: .resumeDownload, on: .summary) == .resumeSummary)
        #expect(ModelsPanel.verb(for: .retry, on: .summary) == .resumeSummary)
        // The transcription model has no pause, so nothing could reach one.
        #expect(ModelsPanel.verb(for: .pause, on: .transcription) == nil)
        #expect(ModelsPanel.verb(for: .resume, on: .transcription) == nil)
    }

    @Test("a card is as tall as the artboard's, whatever its state says on the right")
    func cardHeight() throws {
        EchoFont.registerBundledTypefaces()
        let heights = try [
            ModelRow.summary(.waitingToDownload), .summary(.downloading(0.41)), .summary(.paused), .summary(.ready),
        ].map { row in
            let renderer = ImageRenderer(content: ModelCard(row: row) { _ in }.frame(width: 1_200))
            return try #require(renderer.nsImage).size.height
        }
        // At 1 200 pt nothing wraps: one line of title and one of
        // description, taller than any button on the right, between the
        // card's insets.
        #expect(Set(heights).count == 1, "card heights: \(heights)")
        #expect(heights[0] > 2 * EchoLayout.modelCardInset.height + EchoControl.controlButtonHeight)
    }

    @Test("the panel renders every state in both appearances")
    func forTheEye() throws {
        EchoFont.registerBundledTypefaces()
        // A fixture for the eye: every state the artboard draws, stacked in
        // its order. Never shown by the app, which draws two rows at most.
        let sheet: [ModelRow] = [
            .transcription(.waitingToDownload),
            .summary(.downloading(0.41)),
            .summary(.paused),
            .summary(.incomplete),
            .summary(.loading),
            .transcription(.ready),
            .summary(.failed("Not enough space on this Mac — 1.4 GB free, 3.3 GB needed.")),
            .transcription(.downloading(0.73)),
        ]
        for (appearance, scheme) in [("light", ColorScheme.light), ("dark", .dark)] {
            let renderer = ImageRenderer(
                content: VStack(spacing: EchoLayout.modelPanelGap) {
                    ForEach(Array(sheet.enumerated()), id: \.offset) { _, row in
                        ModelCard(row: row) { _ in }
                    }
                }
                .padding(EchoLayout.modelPanelGap)
                .frame(width: 900)
                .background(EchoColor.windowBackground)
                .environment(\.colorScheme, scheme))
            renderer.scale = 2
            let image = try #require(renderer.cgImage)
            Attachment.record(image, named: "models-panel-\(appearance).png")
        }
    }
}
