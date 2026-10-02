//
//  IslandGlyphs.swift
//  Island
//
//  The small drawings the island's faces carry, as shapes on the 16 × 16 grid
//  the artboards draw them on — not SF Symbols standing in for them. They are
//  a handful of circles and strokes, and drawn as geometry they land exactly
//  where the design puts them at whatever size a face asks for.
//
//  All `nonisolated`, because `Shape` asks for its path off the main actor and
//  this package defaults to it.
//

import DesignSystem
import SwiftUI

/// Maps the artboards' 16 × 16 grid onto a rect.
nonisolated struct GlyphGrid {

    let rect: CGRect

    var unit: CGFloat { min(rect.width, rect.height) / 16 }

    func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
        CGPoint(x: rect.midX + (x - 8) * unit, y: rect.midY + (y - 8) * unit)
    }

    func length(_ value: CGFloat) -> CGFloat { value * unit }
}

/// The dot on the Record capsule.
nonisolated struct RecordGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        let grid = GlyphGrid(rect: rect)
        let radius = grid.length(6.6)
        let centre = grid.point(8, 8)
        return Path(
            ellipseIn: CGRect(x: centre.x - radius, y: centre.y - radius, width: 2 * radius, height: 2 * radius))
    }
}

/// The square on the Stop capsule.
nonisolated struct StopGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        let grid = GlyphGrid(rect: rect)
        let origin = grid.point(2.6, 2.6)
        let side = grid.length(10.8)
        return Path(
            roundedRect: CGRect(x: origin.x, y: origin.y, width: side, height: side),
            cornerRadius: grid.length(2.4),
            style: .continuous
        )
    }
}

/// A capsule's label with the glyph the design puts before it.
struct CapsuleLabel<Glyph: Shape>: View {

    let title: String
    let glyph: Glyph
    let ink: Color

    var body: some View {
        HStack(spacing: EchoControl.capsuleGap) {
            glyph
                .fill(ink)
                .frame(width: EchoControl.capsuleGlyphSize, height: EchoControl.capsuleGlyphSize)
            Text(title)
        }
    }
}
