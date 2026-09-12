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

    /// The display this was read from.
    ///
    /// Identity, which a frame is not: unplug the external and the built-in's
    /// origin moves from (−1512, 514) to (0, 0), so "is the screen the island
    /// is on still attached?" cannot be asked of frames. `0` is
    /// `kCGNullDirectDisplay` and means unknown — the value a fixture that
    /// only cares about geometry gets, and one that matches no display.
    public let displayID: CGDirectDisplayID

    public init(
        frame: CGRect,
        visibleFrame: CGRect,
        safeAreaTop: CGFloat,
        auxiliaryTopLeft: CGRect?,
        auxiliaryTopRight: CGRect?,
        statusBarThickness: CGFloat,
        displayID: CGDirectDisplayID = 0
    ) {
        self.frame = frame
        self.visibleFrame = visibleFrame
        self.safeAreaTop = safeAreaTop
        self.auxiliaryTopLeft = auxiliaryTopLeft
        self.auxiliaryTopRight = auxiliaryTopRight
        self.statusBarThickness = statusBarThickness
        self.displayID = displayID
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
            statusBarThickness: statusBarThickness,
            displayID: screen.displayID
        )
    }

    /// The screen the shell belongs on, resolved against where it already is.
    ///
    /// The ACTIVE screen — the one whose window the user is working in — not
    /// the one under the pointer. #194 chose between them: the active screen
    /// changes as an event, so following it costs two notifications, where
    /// the pointer changes as a stream and following that would have cost an
    /// always-on system-wide mouse monitor in an app whose whole pitch is
    /// staying out of the way.
    ///
    /// `NSScreen.main` is the signal. Measured on 2026-09-11 with two
    /// displays (a 4K external as the primary, the 14" built-in to its left),
    /// from inside an accessory app holding a borderless `.statusBar` panel
    /// that never became key — `panel.isKeyWindow` and `NSApp.isActive` were
    /// false throughout, which is the island's own condition:
    ///
    ///   - **It follows the active window system-wide, not this app's.** It
    ///     read the built-in while another app's window there was frontmost
    ///     and the external otherwise, three rounds out of three. #69's note
    ///     that it "resolves to the primary" was taken on a machine with one
    ///     display, where the primary is the only answer there is; with two,
    ///     it tracks.
    ///   - **It lags an activation.** At the instant
    ///     `didActivateApplicationNotification` arrives it still reports the
    ///     screen being left, every time; it had caught up 16–80 ms later.
    ///     Whoever re-places on that notification has to let it settle — see
    ///     `IslandController`.
    ///   - **The menu bar's reserved strip is NOT a substitute.** `frame.maxY
    ///     − visibleFrame.maxY` read 32.0 on the built-in and 0.0 on the
    ///     external for the whole run, whichever screen was active: with the
    ///     menu bar set to auto-hide, as it is on that machine, the 32 is the
    ///     notch's own band and not the bar. A reading that says "the built-in
    ///     has the menu bar" when the bar is hidden everywhere is not a signal
    ///     about attention.
    @MainActor
    public static func forShell(current: CGDirectDisplayID?, hovered: Bool) -> ScreenGeometry? {
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return nil }
        // The active screen has to be one that exists: `NSScreen.main` is read
        // through the current list rather than trusted, so a display that has
        // just gone away cannot be chosen by the very call that is meant to
        // rescue the island from it.
        let active =
            NSScreen.main.flatMap { main in screens.first { $0.displayID == main.displayID } }
            ?? screens[0]
        let chosen = choice(
            active: active.displayID,
            current: current,
            attached: screens.map(\.displayID),
            hovered: hovered
        )
        return ScreenGeometry(screens.first { $0.displayID == chosen } ?? active)
    }

    /// Which display the shell should be on now. Three rules, in this order:
    ///
    ///   1. **A shell whose display is gone moves to the active one.** This is
    ///      the unplugged monitor, and a window left on a screen that is no
    ///      longer there is the one outcome that cannot be allowed — which is
    ///      why it outranks the rule below rather than politely waiting.
    ///   2. **A shell under the pointer stays where it is.** Moving the island
    ///      out from under a pointer that is on it takes away the thing the
    ///      user is reaching for, mid-reach. The move is not cancelled, only
    ///      deferred: hover always ends, and the placement that ends it asks
    ///      this question again.
    ///   3. Otherwise, the active screen.
    nonisolated static func choice(
        active: CGDirectDisplayID,
        current: CGDirectDisplayID?,
        attached: [CGDirectDisplayID],
        hovered: Bool
    ) -> CGDirectDisplayID {
        guard let current, attached.contains(current) else { return active }
        return hovered ? current : active
    }

    /// The screen under the pointer.
    ///
    /// Not how the island picks its screen — `forShell(current:hovered:)` is,
    /// and the reason the pointer is not the signal is written there. This is
    /// the hover bench's, which drives a pointer at a window on purpose and
    /// needs the window to be where the pointer can reach it.
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

extension NSScreen {

    /// The display's own id, which is what survives a reconfiguration. The key
    /// is AppKit's documented one; a screen without it compares as unknown
    /// rather than as some other screen.
    @MainActor
    var displayID: CGDirectDisplayID {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID ?? 0
    }
}
