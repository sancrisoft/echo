//
//  IslandMetrics.swift
//  Island
//
//  Where the island's shell sits on a given screen, and how tall it is when
//  collapsed. Two shapes: hugging the cutout on a notched Mac, or a floating
//  pill below the menu bar on every other screen.
//
//  Measured on hardware on 2026-09-11 (spike #69), a 14" MacBook Pro M4 Pro
//  (Mac16,8), internal display only:
//
//      frame               1512 × 982 @2x
//      visibleFrame        1512 × 950
//      safeAreaInsets.top  32.0
//      auxiliaryTopLeft    (0, 950, 663 × 32)
//      auxiliaryTopRight   (848, 950, 664 × 32)
//      => cutout           (663, 950, 185 × 32)
//      NSStatusBar         22.0
//
//  The cutout is 185 pt wide there. The width differs between models, which
//  is why nothing below hardcodes one.
//
//  Run on a second display on 2026-09-11, an LG 4K as the primary with the
//  built-in to its left, which settles three of the four things the first
//  reading could not:
//
//      frame               3840 × 2160 @1x at the origin
//      visibleFrame        the same rect — it reserves nothing at the top
//      safeAreaInsets.top  0.0
//      auxiliary areas     none, so `Shell.pill`
//      => window           (1737, 2073, 366 × 80), centred, on whole points
//
//    - the no-notch fallback runs, on a real screen without a cutout, and
//      lands on whole points at 1x, where a half point would have been half a
//      pixel;
//    - the screen is chosen by the pointer, against a second display, in both
//      directions — including the case the first version got wrong, a pointer
//      resting on a screen's own top edge (see `ScreenGeometry.index(of:in:)`);
//    - the `NSStatusBar.thickness` fallback fires: a secondary display with no
//      menu bar of its own reserves nothing at the top, which is the same
//      branch an auto-hidden menu bar takes. The SETTING itself is still
//      untested, so what that branch does when the bar is hidden on the screen
//      that owns it remains #121's.
//
//  Still not verified, and not to be taken as working:
//    - the 16" cutout: a different machine, so a different number;
//    - the menu bar set to auto-hide, per above;
//    - full-screen apps and multiple Spaces.
//

import CoreGraphics
import DesignSystem

/// The island's placement on one screen.
public nonisolated struct IslandMetrics: Equatable, Sendable {

    /// Which of the two shapes this screen gets.
    public enum Shell: Equatable, Sendable {
        /// The screen has a cutout and the shell hugs it: top corners square,
        /// centred on the cutout rather than on the screen.
        case notch(cutout: CGRect)
        /// No cutout — the shell floats below the menu bar as a pill.
        case pill
    }

    public let shell: Shell

    /// The frame of the screen these metrics describe. Kept so that a caller
    /// holding metrics never has to go back to `NSScreen` to place anything.
    public let screenFrame: CGRect

    /// The strip the menu bar occupies at the top of this screen.
    public let menuBarHeight: CGFloat

    public init(_ geometry: ScreenGeometry) {
        screenFrame = geometry.frame
        // `visibleFrame` reserves nothing at the top when the menu bar is set
        // to auto-hide, and the pill would then float inside the strip it is
        // meant to hang below. Measured on the 14" M4 Pro (2026-09-11):
        // reserved 32.0 against a status bar thickness of 22.0 — 10 pt apart,
        // so this fallback is a different number, not a synonym.
        let reserved = geometry.frame.maxY - geometry.visibleFrame.maxY
        menuBarHeight = reserved > 0 ? reserved : geometry.statusBarThickness
        shell = Self.shell(for: geometry)
    }

    /// The cutout, on a screen that has one.
    public var cutout: CGRect? {
        if case .notch(let cutout) = shell { cutout } else { nil }
    }

    /// The x the shell centres on.
    ///
    /// The cutout's centre, not the screen's. Measured on the 14" M4 Pro: the
    /// ears are 663 and 664 pt wide, so the cutout spans x 663…848 and its
    /// centre is 755.5 where `frame.midX` is 756. Centring on the screen would
    /// hang the shell half a point off the thing it is supposed to hug.
    public var centerX: CGFloat {
        cutout?.midX ?? screenFrame.midX
    }

    /// The y of the shell's top edge.
    ///
    /// Hugging the cutout means flush with the top of the screen, which is why
    /// the shell's top corners are square. The pill instead floats below the
    /// menu bar.
    public var topEdge: CGFloat {
        switch shell {
        case .notch: screenFrame.maxY
        case .pill: screenFrame.maxY - menuBarHeight - EchoLayout.islandPillTopGap
        }
    }

    /// How tall the shell is when collapsed on this screen.
    ///
    /// Per screen, not a token: on a notched Mac it is the cutout's own height
    /// (measured 32.0 on the 14" M4 Pro), which the collapsed shell fills
    /// exactly. The pill's height is fixed.
    public var collapsedHeight: CGFloat {
        switch shell {
        case .notch(let cutout): cutout.height
        case .pill: EchoLayout.islandPillSize.height
        }
    }

    /// Where a shell of `size` sits on this screen.
    ///
    /// Exact, fractions and all: the cutout's centre falls on a half point on
    /// the 14", and this is the geometry, not the window.
    ///
    /// A window cannot hold the fraction. Measured on 2026-09-11 on the 14" M4
    /// Pro: `NSWindow.setFrame` given x −872.5 reports −873 back, before and
    /// after ordering front, on a 2x screen. Rounding is therefore the
    /// window's business and is done where the window is
    /// (`IslandShellGeometry.panelFrame(on:)`), deliberately rather than by
    /// whatever AppKit would have done on its own.
    public func frame(for size: CGSize) -> CGRect {
        CGRect(
            x: centerX - size.width / 2,
            y: topEdge - size.height,
            width: size.width,
            height: size.height
        )
    }

    /// The cutout lies between the two menu bar strips, so its width is what
    /// they leave between them — never a constant. A screen with no strips has
    /// no cutout; strips that meet leave nothing between them, which is the
    /// same answer by a different route.
    private static func shell(for geometry: ScreenGeometry) -> Shell {
        guard let left = geometry.auxiliaryTopLeft, let right = geometry.auxiliaryTopRight else {
            return .pill
        }
        let width = right.minX - left.maxX
        guard width > 0 else { return .pill }
        return .notch(cutout: CGRect(x: left.maxX, y: left.minY, width: width, height: left.height))
    }
}
