//
//  PaletteChrome.swift
//  Workspace
//
//  What the window's two floating panels share, so they read as one family:
//  the ⌘K palette and the keyboard shortcuts panel sit over the dimmed window
//  on the same surface, and name their groups and part them the same way.
//

import DesignSystem
import SwiftUI

extension View {
    /// A floating panel's surface: its width, fill, corners, hairline and
    /// shadow.
    func paletteSurface() -> some View {
        frame(width: EchoLayout.paletteWidth)
            .background(EchoColor.paletteBackground)
            .clipShape(.rect(cornerRadius: EchoRadius.palette))
            .overlay {
                RoundedRectangle(cornerRadius: EchoRadius.palette)
                    .strokeBorder(EchoColor.paletteBorder, lineWidth: EchoLayout.hairline)
            }
            .shadow(
                color: EchoColor.paletteShadow, radius: EchoLayout.paletteShadowRadius,
                y: EchoLayout.paletteShadowOffset
            )
    }
}

/// A group's name over its rows, and how many there are when that is worth
/// saying.
struct PaletteGroupLabel: View {
    let title: String
    var count: Int?

    var body: some View {
        HStack(spacing: EchoSpacing.s) {
            Text(title)
                .font(EchoFont.paletteGroupLabel)
                .tracking(EchoFont.paletteGroupLabelTracking)
                .foregroundStyle(EchoColor.paletteGroupLabel)
            Spacer(minLength: EchoSpacing.s)
            if let count {
                Text("\(count)")
                    .font(EchoFont.mono(10.5))
                    .foregroundStyle(EchoColor.textFaint)
            }
        }
        .padding(.horizontal, EchoLayout.paletteRowInset)
        .frame(height: EchoLayout.paletteGroupLabelHeight)
    }
}

/// The rule between two groups.
struct PaletteRule: View {
    var body: some View {
        EchoColor.paletteDivider
            .frame(height: EchoLayout.hairline)
            .padding(.horizontal, EchoLayout.paletteRuleInset.width)
            .padding(.vertical, EchoLayout.paletteRuleInset.height)
    }
}
