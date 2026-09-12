//
//  IslandMotionTests.swift
//  IslandTests
//
//  The part of the motion that is not SwiftUI's to run: the window around a
//  shell that is moving, which has to be big enough for the whole of it at
//  every instant and is not itself animated.
//

import CoreGraphics
import DesignSystem
import Testing

@testable import Island

@Suite("Island motion")
struct IslandMotionTests {

    static let metrics = IslandMetrics(IslandMetricsTests.macBookPro14)

    static func frame(_ face: IslandShellFace, isExpanded: Bool) -> CGRect {
        IslandShellGeometry(metrics: metrics, face: face, isExpanded: isExpanded)
            .panelFrame(on: metrics)
    }

    // MARK: The window around the spring

    @Test("opening takes the new window at once, so the shell has room to grow into")
    func openingTakesTheTargetImmediately() {
        let shut = Self.frame(.idle, isExpanded: false)
        let open = Self.frame(.idle, isExpanded: true)
        let now = IslandWindowTransition.now(from: shut, to: open, animated: true)
        #expect(now == open)
        #expect(!IslandWindowTransition.settles(now, to: open))
    }

    @Test("closing keeps the window it had until the shell has stopped")
    func closingKeepsTheRoomItHad() {
        let open = Self.frame(.idle, isExpanded: true)
        let shut = Self.frame(.idle, isExpanded: false)
        let now = IslandWindowTransition.now(from: open, to: shut, animated: true)
        // Cut to the smaller window at once and the closing animation is
        // clipped at the window's edge for the whole of the spring.
        #expect(now.contains(open))
        #expect(now.contains(shut))
        #expect(IslandWindowTransition.settles(now, to: shut), "nothing would trim it back")
    }

    @Test("the window is never smaller than either end of the move")
    func theWindowHoldsBothEnds() {
        for face in IslandShellFace.allCases {
            let open = Self.frame(face, isExpanded: true)
            let shut = Self.frame(face, isExpanded: false)
            for (from, to) in [(shut, open), (open, shut)] {
                let now = IslandWindowTransition.now(from: from, to: to, animated: true)
                #expect(now.contains(from), "\(face) would clip where it started")
                #expect(now.contains(to), "\(face) would clip where it is going")
            }
        }
    }

    @Test("a shell that is somewhere else entirely just goes there")
    func movingBetweenScreensDoesNotStretch() {
        // Two frames that do not touch have a union across the gap between
        // them, which as a window is a black bar over everything in between.
        let external = IslandMetrics(IslandMetricsTests.externalDisplay)
        let here = Self.frame(.idle, isExpanded: false)
        let there = IslandShellGeometry(metrics: external, face: .idle, isExpanded: false)
            .panelFrame(on: external)
        #expect(!here.intersects(there), "the fixture screens overlap; the case is not the case")
        #expect(IslandWindowTransition.now(from: here, to: there, animated: true) == there)
    }

    @Test("with nothing moving, the window is simply the target")
    func reduceMotionLeavesNoRoomBehind() {
        let open = Self.frame(.idle, isExpanded: true)
        let shut = Self.frame(.idle, isExpanded: false)
        let now = IslandWindowTransition.now(from: open, to: shut, animated: false)
        #expect(now == shut)
        #expect(!IslandWindowTransition.settles(now, to: shut))
    }

    // MARK: The spring itself

    @Test("width, height and radius are one spring, and the window knows how long it lasts")
    func theSpringIsOneAndItsLengthIsNotGuessed() {
        // The window's trim waits for this rather than for a duration written
        // down beside it, which could only ever disagree with it.
        #expect(EchoMotion.islandShellSpring.settlingDuration > 0)
        #expect(EchoMotion.islandShellSpring.settlingDuration < 5)
    }

    @Test("the open face waits for the shell; the ears do not wait for anything")
    func theContentArrivesAfterTheShell() {
        // The shell makes room, then the face arrives in it. Leaving at once
        // and arriving late is what keeps the two sets of content from
        // overlapping halfway through.
        #expect(EchoMotion.islandContentDelay > 0)
        #expect(EchoMotion.islandEarFade < EchoMotion.islandContentDelay + EchoMotion.islandContentFade)
    }

    @Test("a face on its way out has nothing to wait for")
    func closingTakesNoDelay() {
        #expect(EchoMotion.islandContent(opening: false) != EchoMotion.islandContent(opening: true))
    }
}
