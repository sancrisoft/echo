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

/// The glyph above a screen that has nothing to show, one per reason, as the
/// empty-states artboard draws them on its 24 × 24 grid: the waveform of a
/// library with nothing recorded (and of a session still being captured), the
/// magnifier of a search that found nothing, the trash, the lines of a
/// transcript with no words, the warning of a pass that failed, and the
/// folder of a meeting whose files are gone — and, from the processing
/// artboard, the clock of a meeting waiting its turn and the sparkle of a
/// summary being generated.
public nonisolated enum EmptyGlyph: Sendable, CaseIterable {
    case waveform
    case magnifier
    case trash
    case lines
    case warning
    case missingFolder
    case clock
    case sparkle

    /// The stroke the artboard draws, scaled with the glyph.
    public static func lineWidth(at size: CGFloat) -> CGFloat { 1.4 * size / 24 }
}

/// An `EmptyGlyph` as a path to stroke.
public nonisolated struct EmptyGlyphShape: Shape {

    private let glyph: EmptyGlyph

    public init(_ glyph: EmptyGlyph) {
        self.glyph = glyph
    }

    public func path(in rect: CGRect) -> Path {
        let grid = GlyphGrid(rect: rect, side: 24)
        var path = Path()
        func line(_ x1: CGFloat, _ y1: CGFloat, _ x2: CGFloat, _ y2: CGFloat) {
            path.move(to: grid.point(x1, y1))
            path.addLine(to: grid.point(x2, y2))
        }
        /// A rounded corner at the grid point (x, y), between the current
        /// point and (nextX, nextY).
        func corner(_ x: CGFloat, _ y: CGFloat, toward nextX: CGFloat, _ nextY: CGFloat, radius: CGFloat) {
            path.addArc(
                tangent1End: grid.point(x, y), tangent2End: grid.point(nextX, nextY), radius: grid.length(radius))
        }

        switch glyph {
        case .waveform:
            for (x, top, bottom) in [(3.0, 11.0, 13.0), (7, 8, 16), (11, 4.5, 19.5), (15, 8, 16), (19, 11, 13)] {
                line(x, top, x, bottom)
            }

        case .magnifier:
            let centre = grid.point(10.8, 10.8)
            let radius = grid.length(6.6)
            path.addEllipse(
                in: CGRect(x: centre.x - radius, y: centre.y - radius, width: 2 * radius, height: 2 * radius))
            line(15.7, 15.7, 20.7, 20.7)

        case .trash:
            line(4.6, 6.4, 19.4, 6.4)
            // The handle.
            path.move(to: grid.point(9.4, 6.4))
            corner(9.4, 3.4, toward: 14.6, 3.4, radius: 1.3)
            corner(14.6, 3.4, toward: 14.6, 6.4, radius: 1.3)
            path.addLine(to: grid.point(14.6, 6.4))
            // The can, its sides leaning in to a rounded foot.
            path.move(to: grid.point(6.6, 6.4))
            corner(7.593, 20.3, toward: 16.407, 20.3, radius: 1.4)
            corner(16.407, 20.3, toward: 17.4, 6.4, radius: 1.4)
            path.addLine(to: grid.point(17.4, 6.4))

        case .lines:
            line(5, 6.6, 19, 6.6)
            line(5, 12, 19, 12)
            line(5, 17.4, 12, 17.4)

        case .warning:
            path.move(to: grid.point(12, 4.2))
            path.addLine(to: grid.point(21, 19.2))
            path.addLine(to: grid.point(3, 19.2))
            path.closeSubpath()
            line(12, 10, 12, 14)
            line(12, 16.6, 12, 16.7)

        case .missingFolder:
            path.move(to: grid.point(3.2, 6.4))
            corner(3.2, 5, toward: 8.7, 5, radius: 1.4)
            path.addLine(to: grid.point(8.7, 5))
            path.addLine(to: grid.point(10.7, 7.4))
            corner(19.8, 7.4, toward: 19.8, 19.6, radius: 1.4)
            corner(19.8, 19.6, toward: 3.2, 19.6, radius: 1.4)
            corner(3.2, 19.6, toward: 3.2, 5, radius: 1.4)
            path.closeSubpath()
            line(9.4, 11.4, 14.6, 16.6)
            line(14.6, 11.4, 9.4, 16.6)

        case .clock:
            let centre = grid.point(12, 12)
            let radius = grid.length(9)
            path.addEllipse(
                in: CGRect(x: centre.x - radius, y: centre.y - radius, width: 2 * radius, height: 2 * radius))
            path.move(to: grid.point(12, 7))
            path.addLine(to: grid.point(12, 12))
            path.addLine(to: grid.point(15.4, 14.2))

        case .sparkle:
            for star in [
                [(12.0, 3.4), (13.6, 8), (18.2, 9.6), (13.6, 11.2), (12, 15.8), (10.4, 11.2), (5.8, 9.6), (10.4, 8)],
                [
                    (18.0, 15.4), (18.7, 17.4), (20.7, 18.1), (18.7, 18.8), (18, 20.8), (17.3, 18.8), (15.3, 18.1),
                    (17.3, 17.4),
                ],
            ] {
                guard let first = star.first else { continue }
                path.move(to: grid.point(first.0, first.1))
                for point in star.dropFirst() { path.addLine(to: grid.point(point.0, point.1)) }
                path.closeSubpath()
            }
        }
        return path
    }
}
