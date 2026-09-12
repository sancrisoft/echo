//
//  IslandShell.swift
//  Island
//
//  The chrome every face is worn inside: the black shape, the size it is for
//  the face and the state it is in, and the two places content can go.
//
//  Collapsed, a face has no middle — the cutout is physically in the way — so
//  its content lives in the ears either side of it, and the shell is the only
//  thing that knows how far apart they are. Expanded, the cutout is above the
//  row and the face is one line across the whole width. That difference is
//  chrome, not content, which is why it is here and not in six faces that
//  would each have to remember it.
//

import DesignSystem
import SwiftUI

/// The island's shell, hosting one face.
public struct IslandShell<Leading: View, Trailing: View, Row: View>: View {

    private let geometry: IslandShellGeometry
    private let isExpanded: Bool
    private let leadingEar: () -> Leading
    private let trailingEar: () -> Trailing
    private let row: () -> Row

    /// - Parameters:
    ///   - leadingEar: what the collapsed shell shows left of the cutout.
    ///   - trailingEar: what it shows right of it.
    ///   - row: the single line the expanded shell shows instead.
    public init(
        geometry: IslandShellGeometry,
        isExpanded: Bool,
        @ViewBuilder leadingEar: @escaping () -> Leading,
        @ViewBuilder trailingEar: @escaping () -> Trailing,
        @ViewBuilder row: @escaping () -> Row
    ) {
        self.geometry = geometry
        self.isExpanded = isExpanded
        self.leadingEar = leadingEar
        self.trailingEar = trailingEar
        self.row = row
    }

    public var body: some View {
        ZStack {
            shell
            content
        }
        // The window is the shell plus its margins, and the shell is centred
        // in it: the flares live in that margin on one screen, the pill's
        // shadow lives in it on the other, and either would be cut off by a
        // window the size of the black.
        .frame(width: geometry.panelSize.width, height: geometry.panelSize.height)
    }

    @ViewBuilder
    private var shell: some View {
        if geometry.flare > 0 {
            // The flares are drawn outside the shape's own rect, which is why
            // this is framed to the shell and not to the window.
            IslandShellShape(cornerRadius: geometry.cornerRadius, flare: geometry.flare)
                .fill(EchoColor.Island.shell)
                .frame(width: geometry.shellSize.width, height: geometry.shellSize.height)
        } else {
            RoundedRectangle(cornerRadius: geometry.cornerRadius, style: .continuous)
                .fill(EchoColor.Island.shell)
                .frame(width: geometry.shellSize.width, height: geometry.shellSize.height)
                .shadow(
                    color: geometry.castsShadow ? EchoColor.Island.pillShadow : .clear,
                    radius: EchoLayout.islandPillShadowRadius,
                    y: EchoLayout.islandPillShadowOffset
                )
        }
    }

    @ViewBuilder
    private var content: some View {
        if isExpanded {
            row()
                .padding(.leading, EchoLayout.islandRowLeadingInset)
                .padding(.trailing, EchoLayout.islandRowTrailingInset)
                .frame(width: geometry.shellSize.width, height: geometry.shellSize.height)
        } else {
            HStack(spacing: 0) {
                leadingEar().frame(maxWidth: .infinity, alignment: .leading)
                gap
                trailingEar().frame(maxWidth: .infinity, alignment: .trailing)
            }
            .padding(.horizontal, EchoLayout.islandEarInset)
            .frame(width: geometry.shellSize.width, height: geometry.shellSize.height)
        }
    }

    /// The hole between the ears.
    ///
    /// A fixed width on a notched screen — the cutout's own, read from that
    /// screen — and the shell is centred on the cutout, so a centred gap of
    /// exactly that width lands over it. The fallback pill has no hole, so the
    /// two ears simply take the ends of one row.
    @ViewBuilder
    private var gap: some View {
        if let cutoutWidth = geometry.cutoutWidth {
            Color.clear.frame(width: cutoutWidth)
        } else {
            Spacer(minLength: EchoSpacing.s)
        }
    }
}
