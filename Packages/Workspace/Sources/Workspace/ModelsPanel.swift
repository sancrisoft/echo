//
//  ModelsPanel.swift
//  Workspace
//
//  The models panel of `Models.dc.html`: one card per model while either is
//  not ready, gone entirely once both are. It sits at the top of the document
//  pane, at the pane's full width, with the cards exactly as drawn — the
//  sidebar the artboard calls "the meetings list" is too narrow for a drawn
//  row, glyph, two lines, bar, percentage and button side by side (product
//  owner, 2026-10-19).
//
//  Every button calls its model owner's own verb through the session; a state
//  whose engine has no verb shows none.
//

import DesignSystem
import Recording
import SwiftUI

struct ModelsPanel: View {
    @Environment(RecordingSession.self) private var session

    var body: some View {
        ModelCards(rows: ModelRow.rows(transcription: session.readiness, summary: session.summaryReadiness)) {
            action, model in
            switch Self.verb(for: action, on: model) {
            case .retryTranscription: session.retryTranscriptionModel()
            case .pauseSummary: session.pauseSummaryModelDownload()
            case .resumeSummary: session.resumeSummaryModelDownload()
            case nil: break
            }
        }
    }

    /// The session's verbs the panel's buttons reach.
    enum Verb: Equatable {
        case retryTranscription
        case pauseSummary
        case resumeSummary
    }

    /// Which verb a row's action is. The summary model's Resume, Resume
    /// download and Retry are one verb, because the model treats all three
    /// as the user acting on a stopped download. `nil` for an action a model
    /// does not have, which no row offers.
    static func verb(for action: ModelRow.Action, on model: ModelRow.Model) -> Verb? {
        switch (model, action) {
        case (.transcription, .retry): return .retryTranscription
        case (.transcription, _): return nil
        case (.summary, .pause): return .pauseSummary
        case (.summary, .resume), (.summary, .resumeDownload), (.summary, .retry): return .resumeSummary
        }
    }
}

/// The cards, drawn from rows: what the panel shows, and what a test renders
/// without a session.
struct ModelCards: View {
    let rows: [ModelRow]
    let act: (ModelRow.Action, ModelRow.Model) -> Void

    var body: some View {
        if !rows.isEmpty {
            VStack(spacing: EchoLayout.modelPanelGap) {
                ForEach(rows) { row in
                    ModelCard(row: row) { act($0, row.model) }
                }
            }
            // Where the panel sits in the pane is not drawn: the document's
            // own side inset, and the cards' gap above and below them.
            .padding(.horizontal, EchoLayout.breadcrumbInset)
            .padding(.vertical, EchoLayout.modelPanelGap)
        }
    }
}

/// One model's card.
struct ModelCard: View {
    let row: ModelRow
    let act: (ModelRow.Action) -> Void

    var body: some View {
        HStack(spacing: EchoControl.modelGlyphGap) {
            glyph
                .frame(width: EchoControl.modelGlyphSize, height: EchoControl.modelGlyphSize)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    Text(verbatim: "\(row.role) · \(row.identity.name) · ")
                        .font(EchoFont.modelName)
                        .foregroundStyle(EchoColor.textValue)
                    Text(verbatim: row.identity.size)
                        .font(EchoFont.modelSize)
                        .foregroundStyle(EchoColor.textTertiary)
                }
                .lineLimit(1)
                WrapsWithinItsWidth {
                    Text(verbatim: row.detail)
                        .font(EchoFont.rowDescription)
                        .lineSpacing(EchoFont.rowDescriptionLineSpacing)
                        .foregroundStyle(row.isFailure ? EchoColor.failureText : EchoColor.textTertiary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            trailing
                .fixedSize()
        }
        .padding(.horizontal, EchoLayout.modelCardInset.width)
        .padding(.vertical, EchoLayout.modelCardInset.height)
        .background(EchoColor.card, in: .rect(cornerRadius: EchoRadius.card))
        .overlay {
            RoundedRectangle(cornerRadius: EchoRadius.card)
                .strokeBorder(row.isFailure ? EchoColor.failureEdge : EchoColor.divider, lineWidth: EchoLayout.hairline)
        }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var glyph: some View {
        if row.isFailure {
            ModelFailureGlyph().foregroundStyle(EchoColor.recording)
        } else {
            switch row.model {
            case .transcription: TranscriptionGlyph().foregroundStyle(EchoColor.accent)
            case .summary: SummaryGlyph().foregroundStyle(EchoColor.accent)
            }
        }
    }

    @ViewBuilder
    private var trailing: some View {
        switch row.status {
        case .words(let words):
            HStack(spacing: EchoControl.modelTrailingGap) {
                Text(verbatim: words)
                    .font(EchoFont.control)
                    .foregroundStyle(EchoColor.textTertiary)
                actionButton
            }
        case .progress(let percent):
            HStack(spacing: EchoControl.modelTrailingGap) {
                DownloadBar(percent: percent)
                    .frame(width: EchoControl.modelBarWidth)
                Text(verbatim: "\(percent)%")
                    .font(EchoFont.modelPercent)
                    .foregroundStyle(EchoColor.textSecondary)
                    .frame(width: EchoControl.modelPercentWidth, alignment: .trailing)
                actionButton
            }
        case .loading:
            HStack(spacing: EchoControl.modelLoadingGap) {
                LoadingSpinner(size: EchoControl.modelSpinnerSize)
                Text(verbatim: "Loading…")
                    .font(EchoFont.control)
                    .foregroundStyle(EchoColor.textSecondary)
            }
        case .ready:
            StatusBadge("Ready", tone: .accent, showsCheck: true)
        case .actionOnly:
            actionButton
        }
    }

    @ViewBuilder
    private var actionButton: some View {
        if let action = row.action {
            Button(action.title) { act(action) }
                .buttonStyle(.echoControl)
        }
    }
}

// MARK: - The drawn parts

/// Lays a sentence out at the width it is offered, wrapping inside it, and
/// asks for no width of its own when offered none — so a long reason widens
/// neither its card nor the window, and the card takes the pane's width.
struct WrapsWithinItsWidth: Layout {

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let sentence = subviews.first else { return .zero }
        let height = sentence.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil)).height
        return CGSize(width: proposal.width ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(
            at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(width: bounds.width, height: nil))
    }
}

/// A download's bar: the accent over a raised track, filled to the percent
/// the row reads — never animated towards a number it has not reached.
struct DownloadBar: View {
    let percent: Int

    var body: some View {
        Rectangle()
            .fill(EchoColor.surfaceRaised)
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(EchoColor.accent)
                    .scaleEffect(x: CGFloat(percent) / 100, y: 1, anchor: .leading)
            }
            .frame(height: EchoControl.modelBarHeight)
            .clipShape(.rect(cornerRadius: EchoRadius.gauge))
            .accessibilityHidden(true)
    }
}

/// The loading spinner: an open arc of the accent, turning. With Reduce
/// Motion it holds still — an arc that does not turn still says "working".
struct LoadingSpinner: View {
    let size: CGFloat

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var turning = false

    /// The artboard's arc: radius 9 on its 24 grid, from the top round to the
    /// upper left.
    private static let sweep: CGFloat = 294.3 / 360

    var body: some View {
        Circle()
            .inset(by: size * 3 / 24)
            .trim(from: 0, to: Self.sweep)
            .stroke(EchoColor.accent, style: StrokeStyle(lineWidth: size * 2 / 24, lineCap: .round))
            .rotationEffect(.degrees(-90))
            .rotationEffect(.degrees(turning && !reduceMotion ? 360 : 0))
            .animation(
                reduceMotion
                    ? nil
                    : .linear(duration: EchoMotion.spinnerPeriod).repeatForever(autoreverses: false),
                value: turning
            )
            .frame(width: size, height: size)
            .onAppear { turning = true }
            .accessibilityHidden(true)
    }
}

/// The transcription model's glyph: five bars of a waveform, on the
/// artboard's 24 grid.
nonisolated struct TranscriptionGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        let grid = GlyphGrid(rect: rect, side: 24)
        var bars = Path()
        for (x, top, bottom) in [(3.0, 11.0, 13.0), (7.5, 8, 16), (12, 4, 20), (16.5, 8, 16), (21, 11, 13)] {
            bars.move(to: grid.point(x, top))
            bars.addLine(to: grid.point(x, bottom))
        }
        return bars.strokedPath(StrokeStyle(lineWidth: grid.length(1.5), lineCap: .round))
    }
}

/// The summary model's glyph: a four-pointed spark and a small one below it.
nonisolated struct SummaryGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        let grid = GlyphGrid(rect: rect, side: 24)
        var spark = Path()
        let large: [(CGFloat, CGFloat)] = [
            (12, 3.4), (13.6, 8), (18.2, 9.6), (13.6, 11.2), (12, 15.8), (10.4, 11.2), (5.8, 9.6), (10.4, 8),
        ]
        let small: [(CGFloat, CGFloat)] = [
            (18, 15.4), (18.7, 17.4), (20.7, 18.1), (18.7, 18.8), (18, 20.8), (17.3, 18.8), (15.3, 18.1), (17.3, 17.4),
        ]
        for outline in [large, small] {
            spark.addLines(outline.map { grid.point($0.0, $0.1) })
            spark.closeSubpath()
        }
        return spark.strokedPath(StrokeStyle(lineWidth: grid.length(1.5), lineCap: .round, lineJoin: .round))
    }
}

/// A failed model's glyph: a warning triangle.
nonisolated struct ModelFailureGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        let grid = GlyphGrid(rect: rect, side: 24)
        var warning = Path()
        warning.addLines([grid.point(12, 4.2), grid.point(21, 19.2), grid.point(3, 19.2)])
        warning.closeSubpath()
        warning.move(to: grid.point(12, 10))
        warning.addLine(to: grid.point(12, 14))
        warning.move(to: grid.point(12, 16.6))
        warning.addLine(to: grid.point(12, 16.7))
        return warning.strokedPath(StrokeStyle(lineWidth: grid.length(1.5), lineCap: .round, lineJoin: .round))
    }
}
