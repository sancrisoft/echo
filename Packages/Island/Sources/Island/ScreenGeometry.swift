//
//  ScreenGeometry.swift
//  Island
//
//  What the island needs to know about one screen, read off `NSScreen` once so
//  that everything downstream is a pure function of values a test can write
//  down. `NSScreen` cannot be constructed, and placement is the part of the
//  island most likely to be wrong on hardware nobody has to hand.
//

import AppKit
import CoreGraphics

/// One screen's geometry, as the island reads it.
public nonisolated struct ScreenGeometry: Equatable, Sendable {

    /// The screen's full frame, in the global space whose origin is the
    /// bottom-left of the primary display.
    public let frame: CGRect

    /// What is left of it after the menu bar and the Dock.
    public let visibleFrame: CGRect

    /// `safeAreaInsets.top`. On a notched screen this is the band the cutout
    /// occupies: it gives the height and says nothing about the width, which
    /// is why the cutout is derived from the auxiliary areas below and not
    /// from this.
    public let safeAreaTop: CGFloat

    /// The menu bar strip to the left of the cutout; `nil` on a screen that
    /// has no cutout.
    public let auxiliaryTopLeft: CGRect?

    /// The strip to its right.
    public let auxiliaryTopRight: CGRect?

    /// `NSStatusBar.system.thickness`, carried along rather than read at the
    /// point of use: the auto-hidden menu bar falls back to it, and a test has
    /// to be able to state it.
    public let statusBarThickness: CGFloat

    public init(
        frame: CGRect,
        visibleFrame: CGRect,
        safeAreaTop: CGFloat,
        auxiliaryTopLeft: CGRect?,
        auxiliaryTopRight: CGRect?,
        statusBarThickness: CGFloat
    ) {
        self.frame = frame
        self.visibleFrame = visibleFrame
        self.safeAreaTop = safeAreaTop
        self.auxiliaryTopLeft = auxiliaryTopLeft
        self.auxiliaryTopRight = auxiliaryTopRight
        self.statusBarThickness = statusBarThickness
    }
}

extension ScreenGeometry {

    @MainActor
    public init(_ screen: NSScreen, statusBarThickness: CGFloat = NSStatusBar.system.thickness) {
        self.init(
            frame: screen.frame,
            visibleFrame: screen.visibleFrame,
            safeAreaTop: screen.safeAreaInsets.top,
            auxiliaryTopLeft: screen.auxiliaryTopLeftArea,
            auxiliaryTopRight: screen.auxiliaryTopRightArea,
            statusBarThickness: statusBarThickness
        )
    }

    /// The screen the user is most likely looking at.
    ///
    /// `NSScreen.main` alone is not enough: it means "the screen with the key
    /// window", and Echo is an accessory app whose island never takes key — the
    /// spike confirmed `panel.isKeyWindow` stays false through every hover — so
    /// it resolves to the primary display. In v1 that put the island on a
    /// screen the user was not using: a real call detected, an island shown,
    /// and nobody saw it. The pointer is the better signal for "here".
    ///
    /// Verified against a second display on 2026-09-11, which is also how the
    /// edge case below was found.
    @MainActor
    public static func underPointer() -> ScreenGeometry? {
        let screens = NSScreen.screens
        let pointer = NSEvent.mouseLocation
        let screen =
            index(of: pointer, in: screens.map(\.frame)).map { screens[$0] }
            ?? NSScreen.main
            ?? screens.first
        return screen.map { ScreenGeometry($0) }
    }

    /// Which of these frames the pointer is on, edges included.
    ///
    /// `CGRect.contains` excludes a rect's maximum edges, and the island lives
    /// ON the top edge — hovering it is the ordinary way to reach it. Measured
    /// on 2026-09-11 with two displays attached: a pointer resting at exactly
    /// `frame.maxY` of the built-in matched no screen at all, fell through to
    /// `NSScreen.main`, and moved the island to the other display while the
    /// user was pointing at it. So containment here includes every edge.
    ///
    /// Adjacent screens share an edge, so a pointer on one belongs to both and
    /// the first match wins: the order `NSScreen.screens` gives, which is
    /// stable, and either answer is the screen the pointer is touching.
    nonisolated static func index(of point: CGPoint, in frames: [CGRect]) -> Int? {
        frames.firstIndex {
            point.x >= $0.minX && point.x <= $0.maxX && point.y >= $0.minY && point.y <= $0.maxY
        }
    }
}
