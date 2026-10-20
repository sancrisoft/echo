//
//  LiveSessionDocument.swift
//  Workspace
//
//  The session being recorded, in the document's place: what the recording
//  artboard draws once its live row is selected. It is the session, not a
//  stored meeting — a meeting exists on disk only after the stop — so it has
//  no title yet, and none of the facts that come from a transcript: no words,
//  no duration, no summary. Nothing is transcribed while the call runs, and
//  the document says so instead of showing anything that would look like it.
//
//  Tabs as everywhere, Summary first (product owner, 2026-10-02): the
//  artboard draws Transcript first, and that order is not the window's.
//

import DesignSystem
import SwiftUI

struct LiveSessionDocument: View {
    @Environment(WorkspaceModel.self) private var workspace

    let session: LiveSession

    var body: some View {
        @Bindable var workspace = workspace
        VStack(spacing: 0) {
            Breadcrumb(trail: "Meetings", current: "Recording")
            VStack(alignment: .leading, spacing: 0) {
                Text("Untitled meeting")
                    .font(EchoFont.documentTitle)
                    .tracking(EchoFont.documentTitleTracking)
                    .foregroundStyle(EchoColor.textQuaternary)
                    .padding(.bottom, EchoLayout.titleBottomGap)

                properties

                EchoColor.divider
                    .frame(height: EchoLayout.hairline)
                    .padding(.top, EchoLayout.documentDividerTop)
                    .padding(.bottom, EchoLayout.documentDividerBottom)

                TabStrip(WorkspaceModel.DocumentTab.allCases, selection: $workspace.documentTab) { $0.title }

                // The same on both tabs: neither has anything to show yet.
                CapturingPlaceholder()
            }
            .frame(maxWidth: EchoLayout.readingWidth, maxHeight: .infinity, alignment: .top)
            .padding(.top, EchoLayout.readingTopInset)
            .frame(maxWidth: .infinity)
            LiveSessionFooter()
        }
    }

    private var properties: some View {
        VStack(alignment: .leading, spacing: 0) {
            PropertyRow(symbol: "calendar", label: "Started") {
                Text(
                    "\(session.startedAt.formatted(date: .abbreviated, time: .omitted)) · \(Text(session.startedAt.formatted(date: .omitted, time: .shortened)).font(EchoFont.mono()))"
                )
            }
            PropertyRow(symbol: "clock", label: "Elapsed") {
                TimelineView(.periodic(from: session.startedAt, by: 1)) { context in
                    Text(EchoClock.compact(EchoClock.elapsedSeconds(since: session.startedAt, now: context.date)))
                        .font(EchoFont.mono())
                        .foregroundStyle(EchoColor.accent)
                }
            }
            PropertyRow(symbol: "display", label: "Capture") {
                HStack(spacing: EchoControl.propertyQualifierGap) {
                    Text(session.capture)
                    // Both channels, always, and never mixed: You and Others
                    // are the two tracks, which is how a transcript knows who
                    // spoke.
                    Text("· mic + system, kept apart")
                        .font(EchoFont.propertyQualifier)
                        .foregroundStyle(EchoColor.textTertiary)
                }
            }
            PropertyRow(symbol: "checkmark.circle", label: "Status") {
                StatusBadge("Recording", tone: .recording)
            }
        }
    }
}

/// Where the document sits, above it: the library, then the document itself.
struct Breadcrumb: View {
    let trail: String
    let current: String

    var body: some View {
        HStack(spacing: 0) {
            Text(trail)
                .foregroundStyle(EchoColor.textQuaternary)
            Text("/")
                .foregroundStyle(EchoColor.breadcrumbSlash)
                .padding(.horizontal, EchoLayout.breadcrumbSlashGap)
                .accessibilityHidden(true)
            Text(current)
                .foregroundStyle(EchoColor.textSecondary)
            Spacer(minLength: 0)
        }
        .font(EchoFont.control)
        .lineLimit(1)
        .padding(.horizontal, EchoLayout.breadcrumbInset)
        .frame(height: EchoLayout.breadcrumbHeight)
    }
}

/// What the document says while the call runs, in place of anything to read.
private struct CapturingPlaceholder: View {
    var body: some View {
        VStack(spacing: EchoLayout.placeholderGap) {
            WaveGlyph()
                .stroke(
                    EchoColor.placeholderGlyph,
                    style: StrokeStyle(
                        lineWidth: WaveGlyph.lineWidth(at: EchoControl.placeholderGlyphSize), lineCap: .round)
                )
                .frame(width: EchoControl.placeholderGlyphSize, height: EchoControl.placeholderGlyphSize)
                .accessibilityHidden(true)
            Text("Capturing this meeting")
                .font(EchoFont.placeholderTitle)
                .tracking(EchoFont.placeholderTitleTracking)
                .foregroundStyle(EchoColor.textSecondary)
            Text(
                "Nothing is transcribed while the call runs. Echo writes the transcript when you stop, then the notes right after."
            )
            .font(EchoFont.placeholderMessage)
            .lineSpacing(EchoFont.placeholderLineSpacing)
            .foregroundStyle(EchoColor.textTertiary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: EchoLayout.placeholderWidth)
        }
        .padding(.bottom, EchoLayout.placeholderBottomInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Five strokes, tallest in the middle: the artboard's glyph for audio being
/// taken in, on its 24 × 24 grid.
private nonisolated struct WaveGlyph: Shape {

    /// The stroke the artboard draws, scaled with the glyph.
    static func lineWidth(at size: CGFloat) -> CGFloat { 1.4 * size / 24 }

    func path(in rect: CGRect) -> Path {
        let unit = min(rect.width, rect.height) / 24
        let origin = CGPoint(x: rect.midX - 12 * unit, y: rect.midY - 12 * unit)
        var path = Path()
        // (x, top, bottom) on the grid.
        for (x, top, bottom) in [(3.0, 11.0, 13.0), (7, 8, 16), (11, 4.5, 19.5), (15, 8, 16), (19, 11, 13)] {
            path.move(to: CGPoint(x: origin.x + x * unit, y: origin.y + top * unit))
            path.addLine(to: CGPoint(x: origin.x + x * unit, y: origin.y + bottom * unit))
        }
        return path
    }
}
