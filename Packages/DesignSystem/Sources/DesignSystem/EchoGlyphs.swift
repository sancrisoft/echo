//
//  EchoGlyphs.swift
//  DesignSystem
//
//  The small drawings more than one surface carries, as shapes on the 16 × 16
//  grid the artboards draw them on — not SF Symbols standing in for them. The
//  island's Record capsule and the window's New recording put the same dot
//  before their label; drawn once, it is the same dot at whatever size each
//  one asks for.
//
//  `nonisolated`, because `Shape` asks for its path off the main actor and
//  this package defaults to it.
//

import SwiftUI

/// Maps an artboard's square grid onto a rect: the 16 × 16 most glyphs are
/// drawn on, or the 24 × 24 the models artboard draws its own on.
public nonisolated struct GlyphGrid {

    public let rect: CGRect

    /// How many grid units the glyph's side is.
    public let side: CGFloat

    public init(rect: CGRect, side: CGFloat = 16) {
        self.rect = rect
        self.side = side
    }

    public var unit: CGFloat { min(rect.width, rect.height) / side }

    public func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
        CGPoint(x: rect.midX + (x - side / 2) * unit, y: rect.midY + (y - side / 2) * unit)
    }

    public func length(_ value: CGFloat) -> CGFloat { value * unit }
}

/// The dot that starts a recording: on the island's Record capsule, and on
/// the window's New recording.
public nonisolated struct RecordGlyph: Shape {

    public init() {}

    public func path(in rect: CGRect) -> Path {
        let grid = GlyphGrid(rect: rect)
        let radius = grid.length(6.6)
        let centre = grid.point(8, 8)
        return Path(
            ellipseIn: CGRect(x: centre.x - radius, y: centre.y - radius, width: 2 * radius, height: 2 * radius))
    }
}

/// The check inside a "Ready" pill.
public nonisolated struct ReadyCheckGlyph: Shape {

    public init() {}

    public func path(in rect: CGRect) -> Path {
        let grid = GlyphGrid(rect: rect)
        var stroke = Path()
        stroke.move(to: grid.point(3.4, 8.4))
        stroke.addLine(to: grid.point(6.5, 11.5))
        stroke.addLine(to: grid.point(12.6, 4.9))
        return stroke.strokedPath(StrokeStyle(lineWidth: grid.length(2), lineCap: .round, lineJoin: .round))
    }
}
