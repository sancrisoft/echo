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

/// A noticed call's camera, outlined.
nonisolated struct CameraGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        let grid = GlyphGrid(rect: rect)
        var outline = Path()
        let body = grid.point(1.4, 4.4)
        outline.addRoundedRect(
            in: CGRect(x: body.x, y: body.y, width: grid.length(9), height: grid.length(7.4)),
            cornerSize: CGSize(width: grid.length(2.2), height: grid.length(2.2))
        )
        outline.move(to: grid.point(10.8, 8.1))
        outline.addLine(to: grid.point(14.6, 5.6))
        outline.addLine(to: grid.point(14.6, 10.5))
        outline.closeSubpath()
        return outline.strokedPath(
            StrokeStyle(lineWidth: grid.length(1.6), lineCap: .round, lineJoin: .round))
    }
}

/// The saved face's check.
nonisolated struct CheckGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        let grid = GlyphGrid(rect: rect)
        var stroke = Path()
        stroke.move(to: grid.point(3.2, 8.5))
        stroke.addLine(to: grid.point(6.3, 11.5))
        stroke.addLine(to: grid.point(12.8, 4.8))
        return stroke.strokedPath(StrokeStyle(lineWidth: grid.length(2), lineCap: .round, lineJoin: .round))
    }
}

/// The end-of-call countdown: a faint track and, over it, the red arc of the
/// time that is left, ending at the top. Drawn from the detector's real
/// deadline by whoever holds this, never from a clock of its own.
struct CountdownRing: View {

    /// The glyph's box, in points.
    let size: CGFloat

    /// The part of the grace still to run, 1 when it has just begun.
    let remaining: Double

    var body: some View {
        let line = StrokeStyle(lineWidth: size * 1.9 / 16, lineCap: .round)
        let inset = size * (8 - 5.7) / 16
        ZStack {
            Circle()
                .inset(by: inset)
                .stroke(EchoColor.Island.ringTrack, style: line)
            Circle()
                .inset(by: inset)
                .trim(from: 1 - min(max(remaining, 0), 1), to: 1)
                .stroke(EchoColor.Island.recording, style: line)
                .rotationEffect(.degrees(-90))
        }
        .frame(width: size, height: size)
    }
}

/// The recording ear's three bars.
///
/// A pictogram, not a meter: its bars do not move. The ear is a glance —
/// "something is being recorded, on both sides" — and the levels themselves
/// are on the open face, measured. A meter here would be a second reading of
/// the same signal at a size where nobody could tell it from a fake one.
struct LevelBarsGlyph: View {

    var body: some View {
        let box = EchoControl.earLevelBars
        let unit = box.height / 11
        Canvas { context, _ in
            let bars: [(x: CGFloat, y: CGFloat, height: CGFloat, color: Color)] = [
                (0, 1, 9, EchoColor.Island.accent),
                (6, 3.5, 6, EchoColor.Island.gaugeNeutral),
                (12, 5, 5, EchoColor.Island.gaugeNeutral.opacity(0.6)),
            ]
            for bar in bars {
                let rect = CGRect(x: bar.x * unit, y: bar.y * unit, width: 3 * unit, height: bar.height * unit)
                context.fill(Path(roundedRect: rect, cornerRadius: 1.5 * unit), with: .color(bar.color))
            }
        }
        .frame(width: box.width, height: box.height)
    }
}
