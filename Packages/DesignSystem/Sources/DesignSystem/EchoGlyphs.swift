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

/// Maps the artboards' 16 × 16 grid onto a rect.
public nonisolated struct GlyphGrid {

    public let rect: CGRect

    public init(rect: CGRect) {
        self.rect = rect
    }

    public var unit: CGFloat { min(rect.width, rect.height) / 16 }

    public func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
        CGPoint(x: rect.midX + (x - 8) * unit, y: rect.midY + (y - 8) * unit)
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
