//
//  EchoMarkGeometry.swift
//  DesignSystem
//
//  The mark as numbers: two half-discs on a 16 × 16 grid with a seam between
//  them. Echo keeps the microphone and the system audio apart for the whole of
//  its pipeline, so the mark is a circle that was never quite one circle — the
//  near half is you, the far half everyone else.
//
//  CoreGraphics and nothing else, and no reference to anything else in this
//  package: the app icon script compiles this one file beside its own
//  (`make app-icon`). The icon, the menu bar and every view then draw one
//  outline from one set of numbers; a second copy of them would be a brand
//  that can drift.
//

import CoreGraphics

/// The mark's geometry on its 16 × 16 grid, as the brand sheet draws it.
public nonisolated enum EchoMarkGeometry {

    /// The two halves. The near one is drawn in the full ink; the far one at
    /// `farOpacity` of the same ink — one colour, never two.
    public enum Half: CaseIterable, Sendable {
        case near
        case far
    }

    /// The grid every other number here is measured on.
    public static let grid: CGFloat = 16

    /// Each half-disc's radius.
    public static let radius: CGFloat = 6

    /// The gap between the two halves.
    public static let seam: CGFloat = 0.70

    /// How much of the ink the far half takes.
    public static let farOpacity: CGFloat = 0.42

    /// How close anything may come to the mark's edge: the seam × 4.
    public static let clearSpace: CGFloat = seam * 4

    /// The smallest the grid is ever drawn, in points. Below it the seam stops
    /// being a seam.
    public static let minimumSize: CGFloat = 16

    /// The mark's own extent on the grid — both halves and the seam — centred
    /// on it. Narrower than the grid, so the grid already holds part of the
    /// clear space.
    public static let bounds = CGRect(
        x: grid / 2 - seam / 2 - radius,
        y: grid / 2 - radius,
        width: 2 * radius + seam,
        height: 2 * radius
    )

    /// One half's outline, with the grid drawn into the largest square that
    /// fits `rect`, centred in it.
    ///
    /// The halves are mirror images about both axes of the grid, so the
    /// outline is the same in a flipped and an unflipped coordinate space.
    ///
    /// - Parameter minimumSeam: the narrowest the seam may be, in `rect`'s
    ///   units. A host passes one device pixel: at the smallest sizes the
    ///   design's 0.7 of a unit is less than that, and a seam the rasterizer
    ///   fills in is a plain disc.
    public static func path(_ half: Half, in rect: CGRect, minimumSeam: CGFloat = 0) -> CGPath {
        let side = min(rect.width, rect.height)
        let unit = side / grid
        let gap = max(seam * unit, minimumSeam)
        let centre = CGPoint(
            x: rect.midX + (half == .near ? -gap / 2 : gap / 2),
            y: rect.midY
        )
        // Angles rather than points, so the shape does not depend on which way
        // the y axis runs: the near half sweeps through π (its leftmost
        // point), the far half through 0.
        let start: CGFloat = half == .near ? .pi / 2 : -.pi / 2
        let path = CGMutablePath()
        path.addArc(
            center: centre,
            radius: radius * unit,
            startAngle: start,
            endAngle: start + .pi,
            clockwise: false
        )
        path.closeSubpath()
        return path
    }
}
