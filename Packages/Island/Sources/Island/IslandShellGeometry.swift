//
//  IslandShellGeometry.swift
//  Island
//
//  How big the shell is right now, how round, and how much room the window
//  around it needs.
//
//  Its own value rather than something the view works out inside `body`,
//  because two things need the same answer and must not derive it twice: the
//  SwiftUI view that draws the shape, and the panel around it, which is AppKit
//  and has to be resized from outside SwiftUI. A window one size and a shape
//  another is the defect this shuts out.
//

import CoreGraphics
import DesignSystem

/// The shell's measurements for one face in one state, on one screen.
public nonisolated struct IslandShellGeometry: Equatable, Sendable {

    /// The black shape itself.
    public let shellSize: CGSize

    /// The margin between the shell and each side edge of the window: room
    /// for the flares, which sit outside the shell's own width. A window cut
    /// to the shell would clip them. Nothing heightens the window — its top
    /// edge is flush with the top of the screen, so there is no above to reach
    /// into.
    public let shellInset: CGFloat

    /// The bottom corners. The top two are always square: the shell hangs off
    /// the top of the screen.
    public let cornerRadius: CGFloat

    /// The concave corner at each end of the top edge.
    ///
    /// Zero on the idle shell, which is the cutout: a flare is black drawn
    /// OUTSIDE the shell, and outside a real hole there is only bezel — and
    /// outside a drawn one only the menu bar, which a drawn notch has to leave
    /// alone exactly as the real one does. It grows in with the expansion,
    /// which is why `IslandShellShape` animates it.
    public let flare: CGFloat

    /// The cutout the ears split around. A property of the screen and not of
    /// the state: the ears go on holding their places either side of it for
    /// as long as they are still on screen, and a hole that vanished the
    /// instant the shell began to open would take them with it.
    public let cutoutWidth: CGFloat

    /// The band at the top of the shell the expanded row has to stay out of.
    ///
    /// The cutout is not a dark area of screen, it is an absence of screen:
    /// nothing drawn behind it is drawn at all. Collapsed, that is what the
    /// ears are for. Expanded, the cutout is ABOVE the row — the row is the
    /// part of the shell that hangs below the hole — and a row centred in the
    /// whole height instead puts its tallest content behind the camera.
    /// Reported from a 14" M4 Pro: the Record button's top corner was cut off
    /// by the notch, because the shell's widest face leaves only ~70 pt clear
    /// of the cutout at each end and a right-aligned control is wider than
    /// that.
    ///
    /// A drawn cutout is screen, and the row could draw on it; it keeps the
    /// same band anyway, because the island is meant to be the same object on
    /// every screen, and an open face that sat higher on one display than on
    /// the other would not be.
    public let rowTopInset: CGFloat

    public init(metrics: IslandMetrics, face: IslandShellFace, isExpanded: Bool) {
        let cutout = metrics.cutout
        // The idle shell IS the cutout, so it takes the cutout's own outline:
        // no flares, because a flare is black drawn OUTSIDE the shell and there
        // is nothing outside the hole to pour from.
        let hidesInCutout = !isExpanded && !face.announces
        flare = hidesInCutout ? 0 : EchoLayout.islandFlare
        shellSize = CGSize(
            width: isExpanded
                ? face.width.expanded
                : (hidesInCutout ? cutout.width : face.width.collapsed),
            height: isExpanded ? EchoLayout.islandExpandedHeight : metrics.collapsedHeight
        )
        shellInset = flare
        cornerRadius = isExpanded ? EchoRadius.islandExpanded : EchoRadius.islandCollapsed
        cutoutWidth = cutout.width
        rowTopInset = cutout.height
    }

    /// What the window has to be: the shell plus its margins.
    public var panelSize: CGSize {
        CGSize(width: shellSize.width + 2 * shellInset, height: shellSize.height)
    }

    /// Where the window goes on `metrics`' screen.
    ///
    /// The origin is rounded, and that is a measurement rather than a taste. A
    /// window origin is whole points: `setFrame` given x −872.5 reported −873
    /// back on the 14" M4 Pro (2026-09-11), on a 2x screen, before and after
    /// ordering front. Since the platform rounds either way, it is done here
    /// where it can be reasoned about — and DOWNWARD, which is the direction
    /// that reading shows AppKit taking, so this states what happens rather
    /// than asking for something a window would overrule.
    ///
    /// The shell then sits at most half a point off the cutout's centre, which
    /// on a shell that already overhangs the cutout by several points is
    /// nothing, and every edge it draws lands on a whole point. That last part
    /// is what a drawn cutout needs: it is the one shell that meets 1x
    /// screens, where half a point is half a pixel and a soft edge shows.
    public func panelFrame(on metrics: IslandMetrics) -> CGRect {
        let exact = metrics.frame(for: panelSize)
        return CGRect(
            x: exact.minX.rounded(.down),
            y: exact.minY.rounded(.down),
            width: exact.width,
            height: exact.height
        )
    }
}
