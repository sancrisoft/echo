//
//  IslandGallery.swift
//  Island
//
//  Every face, collapsed and expanded, on one sheet — the way the island is
//  reviewed against the artboards without a Mac, a call and a meeting to put
//  it into each state.
//
//  The same idea as `DesignGallery`, for the same reason: the island is a
//  window nobody can screenshot from outside, so the only way to look at it is
//  to draw it. A plain stack, never a scroll view — a renderer only draws a
//  scroll view's visible slice, and a gallery nobody can render in full is not
//  a review tool.
//
//  The faces are the real ones, given the artboards' own fixtures: a Zoom call,
//  twelve minutes in, a meeting of fifty-eight minutes.
//

import Audio
import DesignSystem
import Recording
import SwiftUI

#if DEBUG
    /// The island in every state, against a fixture screen.
    public struct IslandGallery: View {

        private let metrics: IslandMetrics

        /// The instant the fixtures are measured back from. The faces' clocks
        /// read the real time, as they do on screen, so the fixtures sit that
        /// far behind it: twelve minutes forty-one in, eight seconds left.
        private let now: Date

        /// - Parameter metrics: which screen to draw the shell for. The
        ///   notched and the pill cases are different shapes, so both are
        ///   worth a sheet.
        public init(metrics: IslandMetrics, now: Date = .now) {
            self.metrics = metrics
            self.now = now
        }

        public var body: some View {
            VStack(alignment: .leading, spacing: EchoSpacing.xl) {
                ForEach(IslandShellFace.allCases, id: \.self) { face in
                    VStack(alignment: .leading, spacing: EchoSpacing.s) {
                        Text(String(describing: face))
                            .font(EchoFont.sectionLabel)
                            .foregroundStyle(EchoColor.textTertiary)
                        HStack(alignment: .top, spacing: EchoSpacing.xl) {
                            shell(face, isExpanded: false)
                            shell(face, isExpanded: true)
                        }
                    }
                }
            }
            .padding(EchoSpacing.xl)
        }

        // MARK: Fixtures

        private var meeting: IslandMeeting {
            IslandMeeting(title: "GoCoInvest onboarding", duration: 58 * 60, words: 5_512)
        }

        private var startedAt: Date { now.addingTimeInterval(-761) }
        private var deadline: Date { now.addingTimeInterval(8) }

        // MARK: Drawing

        /// Drawn over a ground that is not the shell's own black, so the
        /// flares are visible as flares: what they expose is whatever is
        /// behind the island, and against black they expose nothing.
        ///
        /// The cell is the window's size, because the shell fills its window
        /// rather than asserting a size of its own — the gallery stands in for
        /// the window here and has to be as big as one.
        private func shell(_ face: IslandShellFace, isExpanded: Bool) -> some View {
            let geometry = IslandShellGeometry(metrics: metrics, face: face, isExpanded: isExpanded)
            return IslandShell(
                geometry: geometry,
                isExpanded: isExpanded,
                leadingEar: { leadingEar(face) },
                trailingEar: { trailingEar(face) },
                row: { row(face) }
            )
            .frame(width: geometry.panelSize.width, height: geometry.panelSize.height)
            .background(EchoColor.surface)
        }

        @ViewBuilder
        private func leadingEar(_ face: IslandShellFace) -> some View {
            switch face {
            case .idle, .summarizing: EmptyView()
            case .callDetected: CallDetectedEars(app: "Zoom").leading
            case .recording: RecordingEars(startedAt: startedAt, stoppedAt: 0).leading
            case .callEnded: CallEndedEars(deadline: deadline).leading
            case .saved: SavedEars().leading
            }
        }

        @ViewBuilder
        private func trailingEar(_ face: IslandShellFace) -> some View {
            switch face {
            case .idle, .summarizing: EmptyView()
            case .callDetected: CallDetectedEars(app: "Zoom").trailing
            case .recording: RecordingEars(startedAt: startedAt, stoppedAt: 0).trailing
            case .callEnded: CallEndedEars(deadline: deadline).trailing
            case .saved: SavedEars().trailing
            }
        }

        @ViewBuilder
        private func row(_ face: IslandShellFace) -> some View {
            switch face {
            case .idle:
                IdleRow(lastMeeting: meeting, capture: "Everything", chooseCapture: {}, record: {})
            case .callDetected:
                CallDetectedRow(app: "Zoom", scoped: true, dismiss: {}, record: {})
            case .recording:
                RecordingRow(
                    startedAt: startedAt,
                    stoppedAt: 0,
                    capture: "Zoom only",
                    levels: { CaptureLevels(you: 0.64, others: 0.27) },
                    stop: {}
                )
            case .callEnded:
                CallEndedRow(app: "Zoom", deadline: deadline, answers: (stopNow: {}, keep: {}))
            case .saved:
                SavedRow(meeting: meeting, dismiss: {}, open: {})
            case .summarizing:
                EmptyView()
            }
        }
    }
#endif
