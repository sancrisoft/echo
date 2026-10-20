//
//  LiveSessionFooterTests.swift
//  WorkspaceTests
//
//  The live footer's meter draws what it was handed and nothing else: a trail
//  that keeps the newest readings, bars whose height is the level, and a row
//  that is empty until there is something to draw.
//

import AppKit
import DesignSystem
import Foundation
import SwiftUI
import Testing

@testable import Workspace

@Suite("The live footer")
struct LiveSessionFooterTests {

    @Test("a trail keeps the newest readings, oldest first, up to what the meter shows")
    func theTrailKeepsTheNewest() {
        var trail = LevelTrail(capacity: 3)
        for level in [0.1, 0.2, 0.3, 0.4] { trail.record(level) }
        #expect(trail.levels == [0.2, 0.3, 0.4])
        #expect(LevelTrail().capacity == EchoControl.meterBarCount)
    }

    @Test("a reading outside 0…1 is clamped, never rescaled")
    func readingsAreClamped() {
        var trail = LevelTrail()
        trail.record(-0.5)
        trail.record(1.7)
        trail.record(0.42)
        #expect(trail.levels == [0, 1, 0.42])
    }

    @Test("a silent channel is a bar at rest, the loudest fills its row, and nothing in between is shaped")
    func barHeights() {
        #expect(LevelMeter.barHeight(0) == EchoControl.meterBarRest)
        #expect(LevelMeter.barHeight(1) == EchoControl.meterRowPitch)
        let half = LevelMeter.barHeight(0.5)
        #expect(abs(half - (EchoControl.meterBarRest + EchoControl.meterRowPitch) / 2) < 0.0001)
    }

    @Test("the meter is its bars and their gaps, two rows tall")
    func meterGeometry() throws {
        let renderer = ImageRenderer(content: LevelMeter(you: [0.5], others: [0.2]))
        let image = try #require(renderer.nsImage)
        #expect(abs(image.size.width - LevelMeter.width) <= 1)
        #expect(image.size.height == 2 * EchoControl.meterRowPitch)
    }

    @Test("with nothing read yet the meter draws nothing, not a row at rest")
    func emptyIsEmpty() throws {
        let empty = ImageRenderer(content: LevelMeter(you: [], others: []).background(EchoColor.windowBackground))
        let silent = ImageRenderer(
            content: LevelMeter(you: [0], others: [0]).background(EchoColor.windowBackground))
        empty.scale = 2
        silent.scale = 2
        let none = try #require(empty.cgImage)
        let rest = try #require(silent.cgImage)
        #expect(none.dataProvider?.data != rest.dataProvider?.data)
    }

    @Test("the footer renders in both appearances")
    func forTheEye() throws {
        EchoFont.registerBundledTypefaces()
        // A fixture for the eye: a wave of readings on each channel, so every
        // bar height is on the sheet. Never shown by the app.
        let you = (0..<EchoControl.meterBarCount).map { 0.5 + 0.45 * sin(Double($0) / 3) }
        let others = (0..<EchoControl.meterBarCount).map { 0.25 + 0.2 * cos(Double($0) / 4) }
        for (appearance, scheme) in [("light", ColorScheme.light), ("dark", .dark)] {
            let renderer = ImageRenderer(
                content: LiveFooterBar(you: you, others: others)
                    .frame(width: 900)
                    .environment(\.colorScheme, scheme))
            renderer.scale = 2
            let image = try #require(renderer.cgImage)
            #expect(image.height == Int(EchoLayout.liveFooterHeight * 2))
            Attachment.record(image, named: "live-footer-\(appearance).png")
        }
    }
}
