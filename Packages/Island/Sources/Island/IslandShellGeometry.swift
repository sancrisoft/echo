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

    /// The margin between the shell and the edge of the window, on each side.
    ///
    /// Never zero: on a notched screen the flares sit outside the shell's own
    /// width, and on a screen without one the pill's shadow does. A window cut
    /// to the shell would clip whichever it has.
    public let shellInset: CGSize

    /// The bottom corners. The top two are square on a notched screen and have
    /// no meaning on the pill, which is round all the way.
    public let cornerRadius: CGFloat

    /// The concave corner at each end of the top edge.
    ///
    /// Zero on the pill, which floats clear of the bezel and so has nothing to
    /// be poured from — and zero on the idle shell hiding in the cutout, for
    /// the same reason: a flare is black drawn OUTSIDE the shell, and outside
    /// the hole there is only bezel. It grows in with the expansion, which is
    /// why `IslandShellShape` animates it.
    public let flare: CGFloat

    /// The cutout the ears split around, when the screen has one. A property
    /// of the screen and not of the state: the ears go on holding their places
    /// either side of it for as long as they are still on screen, and a hole
    /// that vanished the instant the shell began to open would take them with
    /// it.
    public let cutoutWidth: CGFloat?

    /// Whether the shell casts. Only the pill does.
    public let castsShadow: Bool

    /// Whether the shell hangs off the top of the screen rather than floating
    /// below the menu bar.
    ///
    /// It decides which outline is drawn, and it is a property of the SCREEN.
    /// Deriving it from the flare instead is the mistake that is easy to make
    /// and hard to see: the idle shell has no flares — it is the cutout — and
    /// a shell sent to the floating pill's rounded rectangle gets all four
    /// corners rounded, including the two that are flush with the top of the
    /// screen and that the design says are always square.
    public var hangsFromBezel: Bool { cutoutWidth != nil }

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
    /// Zero on a screen with no cutout, where there is nothing in the way.
    public let rowTopInset: CGFloat

    public init(metrics: IslandMetrics, face: IslandShellFace, isExpanded: Bool) {
        switch metrics.shell {
        case .notch(let cutout):
            // The idle shell IS the cutout, so it takes the cutout's own
            // outline: no flares, because a flare is black drawn OUTSIDE the
            // shell and there is nothing outside the hole to pour from.
            let hidesInCutout = !isExpanded && !face.announces
            flare = hidesInCutout ? 0 : EchoLayout.islandFlare
            shellSize = CGSize(
                width: isExpanded
                    ? face.width.expanded
                    : (hidesInCutout ? cutout.width : face.width.collapsed),
                height: isExpanded ? EchoLayout.islandExpandedHeight : metrics.collapsedHeight
            )
            // The flares widen the window and nothing heightens it: the top
            // edge is flush with the top of the screen, so there is no above
            // to reach into.
            shellInset = CGSize(width: flare, height: 0)
            cornerRadius = isExpanded ? EchoRadius.islandExpanded : EchoRadius.islandCollapsed
            cutoutWidth = cutout.width
            rowTopInset = cutout.height
            castsShadow = false

        case .pill:
            // The fallback is specified collapsed only: one fixed size,
            // whatever face is on it, because it has no cutout to be as wide
            // as. Expanded it takes the face's own width and the shared row
            // height — it is stated to wear the same faces — and keeps its own
            // radius, which is the nearest answer to a question nothing
            // settles. Flagged for #121, the issue that has the hardware this
            // branch has never run on.
            shellSize =
                isExpanded
                ? CGSize(width: face.width.expanded, height: EchoLayout.islandExpandedHeight)
                : EchoLayout.islandPillSize
            flare = 0
            // The shadow's furthest reach: straight down, where the blur and
            // the offset add up. Taken on every side so the shell stays
            // centred in its window, which is what keeps the placement one
            // subtraction rather than four.
            let reach = EchoLayout.islandPillShadowRadius + EchoLayout.islandPillShadowOffset
            shellInset = CGSize(width: reach, height: reach)
            cornerRadius = EchoRadius.islandPill
            cutoutWidth = nil
            rowTopInset = 0
            castsShadow = true
        }
    }

    /// What the window has to be: the shell plus its margins.
    public var panelSize: CGSize {
        CGSize(
            width: shellSize.width + 2 * shellInset.width,
            height: shellSize.height + 2 * shellInset.height
        )
    }

    /// Where the window goes on `metrics`' screen.
    ///
    /// `IslandMetrics` places a shell, not a window, so the window is dropped
    /// by its own top margin: what has to line up with the top of the screen
    /// (or sit below the menu bar) is the black, not the transparent room the
    /// shadow is given around it.
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
    /// is what the fallback pill needs: it is the one shell that meets 1x
    /// screens, where half a point is half a pixel and a soft edge shows.
    public func panelFrame(on metrics: IslandMetrics) -> CGRect {
        let exact = metrics.frame(for: panelSize).offsetBy(dx: 0, dy: shellInset.height)
        return CGRect(
            x: exact.minX.rounded(.down),
            y: exact.minY.rounded(.down),
            width: exact.width,
            height: exact.height
        )
    }
}
