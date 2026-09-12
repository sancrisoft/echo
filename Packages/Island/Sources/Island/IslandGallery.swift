//
//  IslandGallery.swift
//  Island
//
//  Every face's silhouette, collapsed and expanded, on one sheet — the way the
//  shell is reviewed against what it should be, without a Mac, a call and a
//  meeting to put it into each state.
//
//  The same idea as `DesignGallery`, for the same reason: the island is a
//  window nobody can screenshot from outside, so the only way to look at it is
//  to draw it. A plain stack, never a scroll view — a renderer only draws a
//  scroll view's visible slice, and a gallery nobody can render in full is not
//  a review tool.
//

import DesignSystem
import SwiftUI

#if DEBUG
    /// The shell in every state, against a fixture screen.
    public struct IslandGallery: View {

        private let metrics: IslandMetrics

        /// - Parameter metrics: which screen to draw the shell for. The
        ///   notched and the pill cases are different shapes, so both are
        ///   worth a sheet.
        public init(metrics: IslandMetrics) {
            self.metrics = metrics
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
                leadingEar: {
                    Circle()
                        .fill(EchoColor.Island.recording)
                        .frame(width: EchoControl.recordingDotSize, height: EchoControl.recordingDotSize)
                },
                trailingEar: {
                    Text("00:00")
                        .font(EchoFont.mono(11.5, weight: .medium))
                        .foregroundStyle(EchoColor.Island.controlLabel)
                        // Never wrapped: an ear too narrow for its own words
                        // has to look too narrow, not two lines tall.
                        .lineLimit(1)
                        .fixedSize()
                },
                row: {
                    HStack(spacing: EchoControl.capsuleGap) {
                        Spacer(minLength: EchoSpacing.s)
                        Button("Primary") {}.buttonStyle(.islandPrimary)
                    }
                }
            )
            .frame(width: geometry.panelSize.width, height: geometry.panelSize.height)
            .background(EchoColor.surface)
        }
    }
#endif
