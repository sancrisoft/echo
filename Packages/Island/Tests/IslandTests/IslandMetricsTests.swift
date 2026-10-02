//
//  IslandMetricsTests.swift
//  IslandTests
//
//  The notched case is pinned to the readings spike #69 took on this machine.
//  Everything else is a fixture written by hand and marked as such: it says
//  what the code does, not that hardware agrees. Issue #121 is the hardware.
//
//  A screen with no cutout gets one drawn (DEC-1, product owner 2026-10-02):
//  as wide as the built-in display's, as tall as that screen's menu bar.
//

import CoreGraphics
import DesignSystem
import Testing

@testable import Island

@Suite("Island metrics")
struct IslandMetricsTests {

    /// Exactly what spike #69 read on 2026-09-11: a 14" MacBook Pro M4 Pro
    /// (Mac16,8), internal display, menu bar shown.
    static let macBookPro14 = ScreenGeometry(
        frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
        visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 950),
        safeAreaTop: 32,
        auxiliaryTopLeft: CGRect(x: 0, y: 950, width: 663, height: 32),
        auxiliaryTopRight: CGRect(x: 848, y: 950, width: 664, height: 32),
        statusBarThickness: 22,
        displayID: 1
    )

    /// UNVERIFIED (#121): invented, not measured. No second display exists on
    /// the machine the spike ran on.
    static let externalDisplay = ScreenGeometry(
        frame: CGRect(x: 1512, y: 0, width: 2560, height: 1440),
        visibleFrame: CGRect(x: 1512, y: 0, width: 2560, height: 1415),
        safeAreaTop: 0,
        auxiliaryTopLeft: nil,
        auxiliaryTopRight: nil,
        statusBarThickness: 22,
        // Two fixtures are two displays: the shell is keyed on this, so a
        // pair that shared an id would hide the very thing it is keyed for.
        displayID: 2
    )

    // MARK: The cutout, as measured

    @Test("the 14\" reports the cutout its auxiliary areas leave between them")
    func cutoutFromAuxiliaryAreas() {
        let metrics = IslandMetrics(Self.macBookPro14)
        #expect(metrics.shell == .notch(cutout: CGRect(x: 663, y: 950, width: 185, height: 32)))
    }

    @Test("the cutout is 185 pt on this 14\", so the width is never a constant")
    func cutoutWidthIsNotTheQuotedConstant() {
        // The reason the width is derived and never written down: it varies
        // between models, and this 14" reports 185.
        #expect(IslandMetrics(Self.macBookPro14).cutout.width == 185)
    }

    @Test("the cutout's height is the band safeAreaInsets.top also reports")
    func cutoutHeightAgreesWithSafeArea() {
        let metrics = IslandMetrics(Self.macBookPro14)
        #expect(metrics.cutout.height == Self.macBookPro14.safeAreaTop)
        #expect(metrics.collapsedHeight == 32)
    }

    // MARK: Placement on a notched screen

    @Test("the shell centres on the cutout, which is not where the screen centres")
    func centresOnTheCutoutNotTheScreen() {
        let metrics = IslandMetrics(Self.macBookPro14)
        #expect(metrics.centerX == 755.5)
        #expect(metrics.centerX != metrics.screenFrame.midX)
    }

    @Test("a notched shell hangs from the top edge of the screen")
    func notchedShellHangsFromTheTop() {
        #expect(IslandMetrics(Self.macBookPro14).topEdge == 982)
    }

    @Test("a collapsed shell fills the cutout's band and sits over it")
    func collapsedFrameCoversTheCutout() {
        let metrics = IslandMetrics(Self.macBookPro14)
        let frame = metrics.frame(for: CGSize(width: 320, height: metrics.collapsedHeight))
        #expect(frame == CGRect(x: 595.5, y: 950, width: 320, height: 32))
        // Wide enough to leave an ear either side of the 185 pt cutout.
        #expect(frame.minX < 663)
        #expect(frame.maxX > 848)
    }

    @Test("only the width moves when a face grows; the top edge does not")
    func expandingKeepsTheTopEdge() {
        let metrics = IslandMetrics(Self.macBookPro14)
        let collapsed = metrics.frame(for: CGSize(width: 320, height: 32))
        let expanded = metrics.frame(for: CGSize(width: 360, height: 74))
        #expect(collapsed.maxY == expanded.maxY)
        #expect(collapsed.midX == expanded.midX)
    }

    @Test("a screen with a cutout of its own never takes a drawn one")
    func aRealCutoutIgnoresTheDrawnWidth() {
        let metrics = IslandMetrics(Self.macBookPro14, drawnCutoutWidth: 240)
        #expect(!metrics.drawsCutout)
        #expect(metrics.cutout.width == 185)
    }

    // MARK: The drawn cutout — UNVERIFIED (#121)

    @Test("a screen with no auxiliary areas gets a cutout drawn on it")
    func noAuxiliaryAreasMeansADrawnCutout() {
        let metrics = IslandMetrics(Self.externalDisplay)
        #expect(metrics.drawsCutout)
        #expect(
            metrics.shell
                == .drawn(cutout: CGRect(x: 2792 - 92.5, y: 1415, width: 185, height: 25)))
    }

    @Test("with no notched screen attached, the drawn cutout is the 14\"'s measured width")
    func theDrawnWidthDefaultsToTheMeasuredOne() {
        // The product owner's number, and the one spike #69 read: a Mac with
        // no notch of its own to measure draws the 14" M4 Pro's.
        #expect(EchoLayout.islandDrawnCutoutWidth == 185)
        #expect(IslandMetrics(Self.externalDisplay).cutout.width == 185)
    }

    @Test("beside a notched screen, the drawn cutout is that screen's real width")
    func theDrawnWidthFollowsTheBuiltIn() {
        // A 16" is not a 14", and the drawn notch has to match whichever one
        // the user also has in front of them.
        let metrics = IslandMetrics(Self.externalDisplay, drawnCutoutWidth: 190)
        #expect(metrics.cutout.width == 190)
        #expect(metrics.cutout.midX == metrics.screenFrame.midX)
    }

    @Test("the drawn cutout is as tall as the menu bar, so it sits flush with it")
    func theDrawnCutoutIsTheMenuBarsHeight() {
        let metrics = IslandMetrics(Self.externalDisplay)
        #expect(metrics.menuBarHeight == 25)
        #expect(metrics.collapsedHeight == 25)
        #expect(metrics.cutout.maxY == metrics.screenFrame.maxY)
    }

    @Test("the drawn cutout hangs from the middle of the top edge")
    func theDrawnCutoutHangsFromTheTop() {
        let metrics = IslandMetrics(Self.externalDisplay)
        #expect(metrics.centerX == 2792)
        #expect(metrics.topEdge == 1440)
    }

    @Test("auxiliary areas that meet leave no cutout, so one is drawn")
    func touchingAuxiliaryAreasMeanADrawnCutout() {
        // Defensive: a screen reporting both strips with nothing between them
        // is not a notched screen, whatever else it says.
        var geometry = Self.macBookPro14
        geometry = ScreenGeometry(
            frame: geometry.frame,
            visibleFrame: geometry.visibleFrame,
            safeAreaTop: geometry.safeAreaTop,
            auxiliaryTopLeft: CGRect(x: 0, y: 950, width: 756, height: 32),
            auxiliaryTopRight: CGRect(x: 756, y: 950, width: 756, height: 32),
            statusBarThickness: geometry.statusBarThickness
        )
        #expect(IslandMetrics(geometry).drawsCutout)
    }

    @Test("a full-screen app is carried into the metrics, as read")
    func fullScreenIsCarried() {
        let geometry = ScreenGeometry(
            frame: Self.externalDisplay.frame,
            visibleFrame: Self.externalDisplay.visibleFrame,
            safeAreaTop: 0,
            auxiliaryTopLeft: nil,
            auxiliaryTopRight: nil,
            statusBarThickness: 22,
            displayID: 2,
            isFullScreen: true
        )
        #expect(IslandMetrics(geometry).isFullScreen)
        #expect(!IslandMetrics(Self.externalDisplay).isFullScreen)
    }

    // MARK: The auto-hidden menu bar — UNVERIFIED (#121)

    @Test("an auto-hidden menu bar reserves nothing, so the status bar's thickness stands in")
    func autoHiddenMenuBarFallsBackToStatusBarThickness() {
        let hidden = ScreenGeometry(
            frame: Self.externalDisplay.frame,
            visibleFrame: Self.externalDisplay.frame,
            safeAreaTop: 0,
            auxiliaryTopLeft: nil,
            auxiliaryTopRight: nil,
            statusBarThickness: 22
        )
        let metrics = IslandMetrics(hidden)
        #expect(metrics.menuBarHeight == 22)
        #expect(metrics.cutout.height == 22)
    }

    @Test("hiding the menu bar does not move a shell that hugs the cutout")
    func autoHiddenMenuBarLeavesTheNotchedShellAlone() {
        let hidden = ScreenGeometry(
            frame: Self.macBookPro14.frame,
            visibleFrame: Self.macBookPro14.frame,
            safeAreaTop: Self.macBookPro14.safeAreaTop,
            auxiliaryTopLeft: Self.macBookPro14.auxiliaryTopLeft,
            auxiliaryTopRight: Self.macBookPro14.auxiliaryTopRight,
            statusBarThickness: 22
        )
        #expect(IslandMetrics(hidden).topEdge == IslandMetrics(Self.macBookPro14).topEdge)
        #expect(IslandMetrics(hidden).cutout == IslandMetrics(Self.macBookPro14).cutout)
    }

    // MARK: Per screen — UNVERIFIED (#121)

    @Test("metrics are read per screen, origin included")
    func metricsAreRelativeToTheScreenTheyDescribe() {
        // A second screen sits at a non-zero origin in the global space, and
        // every number the island places by has to come from that screen.
        let metrics = IslandMetrics(Self.externalDisplay)
        #expect(metrics.screenFrame == Self.externalDisplay.frame)
        let frame = metrics.frame(for: CGSize(width: 320, height: 25))
        #expect(frame.midX == 2792)
        #expect(frame.minX > Self.macBookPro14.frame.maxX)
    }
}
