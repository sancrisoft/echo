//
//  SummaryFaceView.swift
//  Workspace
//
//  Draws a `SummaryFace` where the notes will be: bare and centred in what
//  the pane leaves, as every empty state in the window is (product owner,
//  2026-10-20) — the artboard's cards are the sheet's frames. The faces with
//  a glyph are empty states; the final pass shows its percentage and its bar
//  in the glyph's place, and the model loading turns the models panel's own
//  spinner. The notes, streaming in or settling, are the document itself.
//

import DesignSystem
import Recording
import SwiftUI

struct SummaryFaceView: View {
    let face: SummaryFace
    /// Generate summary: the session's own request, the one trigger allowed
    /// to fetch a model that is not on disk.
    let generate: () -> Void
    /// Copy transcript: `true` once the transcript is on the pasteboard.
    let copyTranscript: () -> Bool

    @State private var copied = false

    var body: some View {
        switch face {
        case .summary:
            EmptyView()
        case .finalizing(let percent):
            FinalizingFace(percent: percent)
        case .waitingToFinalize(let behind):
            EmptyState(
                glyph: .clock, title: SummaryFace.waitingTitle, message: SummaryFace.waitingMessage(behind: behind))
        case .loadingModel:
            LoadingModelFace()
        case .generating:
            EmptyState(glyph: .sparkle, title: SummaryFace.generatingTitle, message: SummaryFace.generatingMessage)
        case .writing(let markdown):
            MarkdownView(markdown: markdown, showsCursor: true)
        case .settling(let markdown):
            if let markdown { MarkdownView(markdown: markdown) }
        case .failed(let reason):
            EmptyState(
                glyph: .warning, title: SummaryFace.failedTitle, message: SummaryFace.failedMessage(reason: reason)
            ) {
                Button("Generate summary", action: generate)
                    .buttonStyle(.echoControlProminent)
                Button(copied ? "Copied" : "Copy transcript") { copied = copyTranscript() }
                    .buttonStyle(.echoControl)
            }
        case .notYet(let transcriptReadable):
            EmptyState(
                glyph: .lines,
                title: SummaryFace.notYetTitle,
                message: transcriptReadable
                    ? "The transcript is in. Notes are written once the summary model is available."
                    : "Notes are written from the transcript, once there is one."
            )
        case .canGenerate:
            EmptyState(glyph: .lines, title: SummaryFace.notYetTitle, message: SummaryFace.canGenerateMessage) {
                Button("Generate summary", action: generate)
                    .buttonStyle(.echoControlProminent)
            }
        }
    }
}

/// The final pass under way: its real percentage in the title, its bar in
/// the glyph's place, and what happens after it.
private struct FinalizingFace: View {
    let percent: Int

    var body: some View {
        VStack(spacing: EchoLayout.emptyStateGap) {
            Text(
                "\(SummaryFace.finalizingTitle) \(Text("\(percent)%").font(EchoFont.emptyTitleFigure).foregroundStyle(EchoColor.accent))"
            )
            .font(EchoFont.emptyTitle)
            .foregroundStyle(EchoColor.textValue)
            .multilineTextAlignment(.center)
            DownloadBar(percent: percent)
                .frame(width: EchoLayout.processingBarWidth)
            Text(SummaryFace.finalizingMessage)
                .font(EchoFont.emptyMessage)
                .lineSpacing(EchoFont.emptyMessageLineSpacing)
                .foregroundStyle(EchoColor.textTertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: EchoLayout.emptyStateMessageWidth)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(EchoLayout.emptyStateInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }
}

/// The summary model coming into memory: the models panel's spinner in the
/// glyph's place, at the glyph's size.
private struct LoadingModelFace: View {
    var body: some View {
        VStack(spacing: EchoLayout.emptyStateGap) {
            LoadingSpinner(size: EchoControl.emptyGlyphSize)
            Text(SummaryFace.loadingTitle)
                .font(EchoFont.emptyTitle)
                .foregroundStyle(EchoColor.textValue)
            Text(SummaryFace.loadingMessage(modelName: OnDeviceModel.summary.name))
                .font(EchoFont.emptyMessage)
                .lineSpacing(EchoFont.emptyMessageLineSpacing)
                .foregroundStyle(EchoColor.textTertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: EchoLayout.emptyStateMessageWidth)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(EchoLayout.emptyStateInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }
}
