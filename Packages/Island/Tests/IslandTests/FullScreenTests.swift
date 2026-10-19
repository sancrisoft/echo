//
//  FullScreenTests.swift
//  IslandTests
//
//  Whether a full-screen app has a screen, from the window list alone. The
//  fixtures are what this machine's list read on 2026-10-04 — one 4K display,
//  menu bar set to auto-hide — in an ordinary Space, in a full-screen one, and
//  in an ordinary one again after the window manager had rearranged it.
//

import CoreGraphics
import Testing

@testable import Island

@Suite("Full screen")
struct FullScreenTests {

    static let screen = CGRect(x: 0, y: 0, width: 3840, height: 2160)

    private static func entry(_ layer: Int, _ owner: String, _ bounds: CGRect = screen) -> WindowListing.Entry {
        WindowListing.Entry(layer: layer, owner: owner, bounds: bounds)
    }

    /// Below the desktop level in every Space: the Window Server's backstop
    /// and its strip, and the window manager's wallpaper layer.
    static let backstops = [
        entry(-2_147_483_602, "Window Server", CGRect(x: 0, y: 0, width: 3840, height: 183)),
        entry(-2_147_483_624, "WindowManager"),
        entry(-2_147_483_626, "Window Server"),
    ]

    /// The desktop picture's own windows, which only an ordinary Space has.
    static let wallpaper = [
        entry(-2_147_483_624, "BackdropWallpaper"),
        entry(-2_147_483_625, "Wallpaper"),
    ]

    static let finderDesktop = entry(-2_147_483_603, "Finder")
    static let apps = [
        entry(0, "Code", CGRect(x: 440, y: 535, width: 1281, height: 1615)),
        entry(0, "Warp", CGRect(x: 1414, y: 346, width: 1298, height: 1165)),
    ]

    @Test("an ordinary Space shows its desktop, so nothing is in full screen")
    func anOrdinarySpaceIsNotFullScreen() {
        let windows = Self.backstops + Self.wallpaper + [Self.finderDesktop] + Self.apps
        #expect(!ScreenGeometry.showsFullScreenSpace(in: windows, on: Self.screen))
    }

    @Test("a full-screen Space: a window over the whole screen, and no desktop picture under it")
    func aFullScreenSpace() {
        // As read: the app's window, the strip its title bar slides down
        // from, the window manager's full-screen backdrop, and the backstops.
        let windows =
            [
                Self.entry(0, "fsprobe"),
                Self.entry(0, "fsprobe", CGRect(x: 0, y: -32, width: 3840, height: 32)),
                Self.entry(-2_147_483_622, "WindowManager"),
            ] + Self.backstops
        #expect(ScreenGeometry.showsFullScreenSpace(in: windows, on: Self.screen))
    }

    @Test("a window zoomed to the whole screen is not full screen while the desktop picture shows")
    func aZoomedWindowIsNotFullScreen() {
        // With the menu bar and the Dock set to auto-hide, `visibleFrame` is
        // the whole screen and a zoomed window fills it — the same bounds a
        // full-screen window has.
        let windows = Self.backstops + Self.wallpaper + [Self.entry(0, "Code")]
        #expect(!ScreenGeometry.showsFullScreenSpace(in: windows, on: Self.screen))
    }

    @Test("Finder's desktop is no signal: an ordinary Space can be without it")
    func finderIsNotTheDesktop() {
        // Read after the window manager rearranged the Space: Finder's
        // desktop window gone, the wallpaper's still there.
        let windows = Self.backstops + Self.wallpaper + [Self.entry(0, "Code")]
        #expect(!windows.contains(Self.finderDesktop))
        #expect(!ScreenGeometry.showsFullScreenSpace(in: windows, on: Self.screen))
    }

    @Test("it is a question about one screen: another display's full screen is not this one's")
    func fullScreenIsPerScreen() {
        let other = CGRect(x: 3840, y: 0, width: 1512, height: 982)
        let windows = Self.backstops + Self.wallpaper + [Self.entry(0, "Keynote", other)]
        #expect(!ScreenGeometry.showsFullScreenSpace(in: windows, on: Self.screen))
        #expect(ScreenGeometry.showsFullScreenSpace(in: windows, on: other))
    }

    @Test("the strip reads the cutout, and only a gap is a cutout")
    func theCutoutIsTheGapBetweenTheStrips() {
        #expect(IslandMetricsTests.macBookPro14.cutoutWidth == 185)
        #expect(IslandMetricsTests.externalDisplay.cutoutWidth == nil)
        #expect(
            ScreenGeometry.cutoutWidth(
                left: CGRect(x: 0, y: 950, width: 756, height: 32),
                right: CGRect(x: 756, y: 950, width: 756, height: 32)) == nil)
    }
}
