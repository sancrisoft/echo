//
//  IslandMetrics.swift
//  Island
//
//  Where the island's shell sits on a given screen, and how tall it is when
//  collapsed. One shape on every screen: hugging a cutout. On a notched Mac it
//  is the camera's; on every other screen it is one Echo draws, so the island
//  looks and behaves the same wherever it is (DEC-1, product owner
//  2026-10-02, replacing the floating pill the design first drew).
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
//      auxiliary areas     none, so no cutout of its own
//
//    - the no-notch fallback runs, on a real screen without a cutout (it was
//      the pill then), and lands on whole points at 1x, where a half point
//      would have been half a pixel — the drawn cutout's centre is a half
//      point there too, and takes the same rounding;
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
//    - a person watching the drawn cutout on an external display, and over a
//      full-screen app there (#121). The full-screen READING itself was
//      measured — see `ScreenGeometry.showsFullScreenSpace(in:on:)`.
//

import CoreGraphics
import DesignSystem

/// The island's placement on one screen.
public nonisolated struct IslandMetrics: Equatable, Sendable {

    /// The cutout the shell hugs on this screen.
    public enum Shell: Equatable, Sendable {
        /// The screen has a cutout and the shell hugs it: top corners square,
        /// centred on the cutout rather than on the screen.
        case notch(cutout: CGRect)
        /// No cutout, so Echo draws one: as wide as the real one, as tall as
        /// this screen's menu bar, hanging from the middle of the top edge.
        /// Everything else — the shell, the ears, the flares, the faces, hover
        /// and motion — is the notch's, unchanged.
        case drawn(cutout: CGRect)
    }

    public let shell: Shell

    /// Which display these are. Carried so that a view can tell one screen's
    /// shell from another's without going back to `NSScreen`: moving to
    /// another display is not a shell changing size, it is a different shell,
    /// and the spring must not be asked to travel between them.
    public let displayID: CGDirectDisplayID

    /// The frame of the screen these metrics describe. Kept so that a caller
    /// holding metrics never has to go back to `NSScreen` to place anything.
    public let screenFrame: CGRect

    /// The strip the menu bar occupies at the top of this screen.
    public let menuBarHeight: CGFloat

    /// Whether a full-screen app has the screen, and with it the menu bar.
    public let isFullScreen: Bool

    /// - Parameter drawnCutoutWidth: how wide a drawn cutout is — the real
    ///   cutout of the built-in display when one is attached
    ///   (`ScreenGeometry.attachedCutoutWidth()`), and otherwise the one it
    ///   was measured to be. A screen with a cutout of its own ignores it.
    public init(
        _ geometry: ScreenGeometry,
        drawnCutoutWidth: CGFloat = EchoLayout.islandDrawnCutoutWidth
    ) {
        displayID = geometry.displayID
        screenFrame = geometry.frame
        isFullScreen = geometry.isFullScreen
        // `visibleFrame` reserves nothing at the top when the menu bar is set
        // to auto-hide, and a drawn cutout would then be no height at all.
        // Measured on the 14" M4 Pro (2026-09-11): reserved 32.0 against a
        // status bar thickness of 22.0 — 10 pt apart, so this fallback is a
        // different number, not a synonym.
        let reserved = geometry.frame.maxY - geometry.visibleFrame.maxY
        menuBarHeight = reserved > 0 ? reserved : geometry.statusBarThickness
        shell = Self.shell(for: geometry, menuBarHeight: menuBarHeight, drawnWidth: drawnCutoutWidth)
    }

    /// The cutout the shell hugs: the camera's, or the one Echo draws.
    public var cutout: CGRect {
        switch shell {
        case .notch(let cutout), .drawn(let cutout): cutout
        }
    }

    /// Whether Echo paints the cutout itself. A real one is black by hardware
    /// and the idle shell hides inside it; a drawn one is the idle shell.
    public var drawsCutout: Bool {
        if case .drawn = shell { true } else { false }
    }

    /// The x the shell centres on.
    ///
    /// The cutout's centre, not the screen's. Measured on the 14" M4 Pro: the
    /// ears are 663 and 664 pt wide, so the cutout spans x 663…848 and its
    /// centre is 755.5 where `frame.midX` is 756. Centring on the screen would
    /// hang the shell half a point off the thing it is supposed to hug.
    public var centerX: CGFloat {
        cutout.midX
    }

    /// The y of the shell's top edge: flush with the top of the screen, which
    /// is why the shell's top corners are square.
    public var topEdge: CGFloat {
        screenFrame.maxY
    }

    /// How tall the shell is when collapsed on this screen.
    ///
    /// Per screen, not a token: the cutout's own height (measured 32.0 on the
    /// 14" M4 Pro), which the collapsed shell fills exactly — or, for a drawn
    /// cutout, the menu bar's, so it sits flush with the bar.
    public var collapsedHeight: CGFloat {
        cutout.height
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
    /// they leave between them — never a constant. A screen with no strips,
    /// or strips that meet, has none of its own and gets one drawn.
    private static func shell(
        for geometry: ScreenGeometry, menuBarHeight: CGFloat, drawnWidth: CGFloat
    ) -> Shell {
        if let width = geometry.cutoutWidth, let left = geometry.auxiliaryTopLeft {
            return .notch(cutout: CGRect(x: left.maxX, y: left.minY, width: width, height: left.height))
        }
        let frame = geometry.frame
        return .drawn(
            cutout: CGRect(
                x: frame.midX - drawnWidth / 2,
                y: frame.maxY - menuBarHeight,
                width: drawnWidth,
                height: menuBarHeight
            ))
    }
}
