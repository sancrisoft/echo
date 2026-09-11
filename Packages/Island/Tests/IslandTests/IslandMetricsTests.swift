//
//  IslandMetricsTests.swift
//  IslandTests
//
//  The notched case is pinned to the readings spike #69 took on this machine.
//  Everything else is a fixture written by hand and marked as such: it says
//  what the code does, not that hardware agrees. Issue #121 is the hardware.
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
        statusBarThickness: 22
    )

    /// UNVERIFIED (#121): invented, not measured. No second display exists on
    /// the machine the spike ran on.
    static let externalDisplay = ScreenGeometry(
        frame: CGRect(x: 1512, y: 0, width: 2560, height: 1440),
        visibleFrame: CGRect(x: 1512, y: 0, width: 2560, height: 1415),
        safeAreaTop: 0,
        auxiliaryTopLeft: nil,
        auxiliaryTopRight: nil,
        statusBarThickness: 22
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
        #expect(IslandMetrics(Self.macBookPro14).cutout?.width == 185)
    }

    @Test("the cutout's height is the band safeAreaInsets.top also reports")
    func cutoutHeightAgreesWithSafeArea() {
        let metrics = IslandMetrics(Self.macBookPro14)
        #expect(metrics.cutout?.height == Self.macBookPro14.safeAreaTop)
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

    // MARK: The no-notch fallback — UNVERIFIED (#121)

    @Test("a screen with no auxiliary areas falls back to the pill")
    func noAuxiliaryAreasMeansPill() {
        #expect(IslandMetrics(Self.externalDisplay).shell == .pill)
        #expect(IslandMetrics(Self.externalDisplay).cutout == nil)
    }

    @Test("the pill floats below the menu bar rather than against it")
    func pillFloatsBelowTheMenuBar() {
        let metrics = IslandMetrics(Self.externalDisplay)
        #expect(metrics.menuBarHeight == 25)
        #expect(metrics.topEdge == 1440 - 25 - EchoLayout.islandPillTopGap)
    }

    @Test("the pill centres on the screen and takes its fixed height")
    func pillCentresOnTheScreen() {
        let metrics = IslandMetrics(Self.externalDisplay)
        #expect(metrics.centerX == 2792)
        #expect(metrics.collapsedHeight == EchoLayout.islandPillSize.height)
    }

    @Test("auxiliary areas that meet leave no cutout, so the pill wins")
    func touchingAuxiliaryAreasMeanPill() {
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
        #expect(IslandMetrics(geometry).shell == .pill)
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
        #expect(metrics.topEdge == 1440 - 22 - EchoLayout.islandPillTopGap)
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
    }

    // MARK: Per screen — UNVERIFIED (#121)

    @Test("metrics are read per screen, origin included")
    func metricsAreRelativeToTheScreenTheyDescribe() {
        // A second screen sits at a non-zero origin in the global space, and
        // every number the island places by has to come from that screen.
        let metrics = IslandMetrics(Self.externalDisplay)
        #expect(metrics.screenFrame == Self.externalDisplay.frame)
        let frame = metrics.frame(for: EchoLayout.islandPillSize)
        #expect(frame.midX == 2792)
        #expect(frame.minX > Self.macBookPro14.frame.maxX)
    }
}
