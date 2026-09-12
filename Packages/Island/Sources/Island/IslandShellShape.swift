//
//  IslandShellShape.swift
//  Island
//
//  The shell's outline: square at the top, rounded at the bottom, with a
//  concave flare at each top corner.
//
//  The flares are the whole reason this is a shape and not a rounded
//  rectangle. Without them the island is a black tab stuck onto the bezel;
//  with them the black of the shell runs into the black around the cutout with
//  no corner between the two, and the shell reads as poured out of the bezel
//  rather than laid over it. They cost a custom path because the curve bends
//  the wrong way for any corner radius — it is the corner's complement, the
//  square minus the disc, not the disc.
//
//  One continuous outline rather than a body with two subpaths bolted on: a
//  flare shares its whole inner edge with the shell, and two filled regions
//  that merely touch along an edge leave an antialiased seam down it.
//

import DesignSystem
import SwiftUI

/// The shell as it hangs off a cutout.
///
/// The rect it is given is the shell itself. The flares are drawn OUTSIDE it,
/// one at each end of the top edge, so a view hosting this shape has to leave
/// a flare's width of room on both sides — `IslandShellGeometry.shellInset`
/// is that room.
///
/// The top edge runs the full width, flares included: it is flush with the top
/// of the screen, which is why the top corners are square and why nothing here
/// rounds them.
public struct IslandShellShape: Shape {

    /// The bottom corners. The top two are always square.
    public var cornerRadius: CGFloat

    /// The concave corner at each end of the top edge. Zero draws the shell
    /// with none — what a screen with no cutout asks for, and what the idle
    /// shell hiding inside the cutout asks for too.
    public var flare: CGFloat

    public init(cornerRadius: CGFloat, flare: CGFloat = EchoLayout.islandFlare) {
        self.cornerRadius = cornerRadius
        self.flare = flare
    }

    /// The radius and the flare, so both travel with the width and the height
    /// instead of stepping between them.
    ///
    /// The flare has to move because the idle shell has none: it is the
    /// cutout, and a flare is black drawn outside the shell, which outside the
    /// hole means on the bezel. So expanding grows two flares that were not
    /// there, and a flare that stepped would paint 16 pt of black at each end
    /// in a single frame — at exactly the moment the shell is still small
    /// enough for that to be most of it.
    public var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(cornerRadius, flare) }
        set {
            cornerRadius = newValue.first
            flare = newValue.second
        }
    }

    public func path(in rect: CGRect) -> Path {
        // Both curves are clamped to what the shell can hold. A face narrower
        // or shorter than its own corners is not a shape anybody drew, but it
        // is a shape somebody can pass, and a path that folds through itself
        // is worse than a blunt one.
        let flare = max(0, min(flare, rect.height))
        let radius = max(0, min(cornerRadius, rect.height - flare, rect.width / 2))

        var path = Path()

        // The left flare: an arc tangent to the top edge and to the shell's
        // left edge, which puts its centre out beyond the shell and bends the
        // curve away from it — the complement of a rounded corner, not a
        // rounded corner.
        path.move(to: CGPoint(x: rect.minX - flare, y: rect.minY))
        if flare > 0 {
            path.addArc(
                tangent1End: CGPoint(x: rect.minX, y: rect.minY),
                tangent2End: CGPoint(x: rect.minX, y: rect.minY + flare),
                radius: flare
            )
        }

        // Down the left edge and around the two bottom corners.
        path.addArc(
            tangent1End: CGPoint(x: rect.minX, y: rect.maxY),
            tangent2End: CGPoint(x: rect.maxX, y: rect.maxY),
            radius: radius
        )
        path.addArc(
            tangent1End: CGPoint(x: rect.maxX, y: rect.maxY),
            tangent2End: CGPoint(x: rect.maxX, y: rect.minY),
            radius: radius
        )

        // Up the right edge into the mirrored flare.
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + flare))
        if flare > 0 {
            path.addArc(
                tangent1End: CGPoint(x: rect.maxX, y: rect.minY),
                tangent2End: CGPoint(x: rect.maxX + flare, y: rect.minY),
                radius: flare
            )
        } else {
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        }

        // Closing runs the top edge back across the full width, flares
        // included.
        path.closeSubpath()
        return path
    }
}
