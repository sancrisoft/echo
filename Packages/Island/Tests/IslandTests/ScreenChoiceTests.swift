//
//  ScreenChoiceTests.swift
//  IslandTests
//
//  Which screen the island belongs on, as a pure function over frames. The
//  layout below is the one this machine actually reports — a 4K primary at the
//  origin with a 14" built-in to its left, measured 2026-09-11 — so the edge
//  the island lives on is a real edge and not an invented one.
//

import CoreGraphics
import Testing

@testable import Island

@Suite("Screen choice")
struct ScreenChoiceTests {

    /// The primary, at the origin, with no cutout.
    static let external = CGRect(x: 0, y: 0, width: 3840, height: 2160)
    /// The built-in, to its left and higher up.
    static let builtIn = CGRect(x: -1512, y: 514, width: 1512, height: 982)
    static let frames = [external, builtIn]

    @Test("a pointer in the middle of a screen is on that screen")
    func theObviousCase() {
        #expect(ScreenGeometry.index(of: CGPoint(x: -756, y: 1000), in: Self.frames) == 1)
        #expect(ScreenGeometry.index(of: CGPoint(x: 1920, y: 1000), in: Self.frames) == 0)
    }

    @Test("a pointer on a screen's top edge is on that screen")
    func theEdgeTheIslandLivesOn() {
        // Measured: `CGRect.contains` says no here, the pointer matched no
        // screen at all, and the island moved to the other display while the
        // user was pointing at it. The top edge is where the island IS.
        let top = CGPoint(x: -558.75, y: Self.builtIn.maxY)
        #expect(!Self.builtIn.contains(top), "the case stopped being the case CGRect refuses")
        #expect(ScreenGeometry.index(of: top, in: Self.frames) == 1)
    }

    @Test("every corner of a screen belongs to it")
    func theCorners() {
        for x in [Self.builtIn.minX, Self.builtIn.maxX] {
            for y in [Self.builtIn.minY, Self.builtIn.maxY] {
                #expect(ScreenGeometry.index(of: CGPoint(x: x, y: y), in: Self.frames) != nil)
            }
        }
    }

    @Test("a shared edge goes to the first screen that claims it, and never to nothing")
    func aSharedEdgeIsNotNobodys() {
        // The two frames meet at x = 0. Both contain the point; the answer has
        // to be one of them and the same one every time, because the island
        // moving between displays as the pointer rests on the seam is worse
        // than either choice.
        let seam = CGPoint(x: 0, y: 1000)
        #expect(ScreenGeometry.index(of: seam, in: Self.frames) == 0)
        #expect(ScreenGeometry.index(of: seam, in: Self.frames.reversed()) == 0)
    }

    @Test("a pointer on no screen is nobody's, and the caller falls back")
    func offEveryScreen() {
        #expect(ScreenGeometry.index(of: CGPoint(x: -4000, y: 4000), in: Self.frames) == nil)
    }

    @Test("no screens at all is not a crash")
    func noScreens() {
        #expect(ScreenGeometry.index(of: .zero, in: []) == nil)
    }
}
