//
//  ActiveScreenTests.swift
//  IslandTests
//
//  Which display the shell belongs on, as a table. The rule has to hold for
//  three things at once — the user moving to another screen, the pointer
//  resting on the island, and a display being unplugged out from under it —
//  and only the first of those is easy to try by hand.
//
//  The ids below are arbitrary: a display id is identity and nothing else,
//  which is the whole reason the choice is made on them rather than on frames.
//  Unplug the external and the built-in's origin moves, so a frame cannot
//  answer "is the screen I am on still there?".
//

import CoreGraphics
import Testing

@testable import Island

@Suite("The active screen")
struct ActiveScreenTests {

    static let builtIn: CGDirectDisplayID = 1
    static let external: CGDirectDisplayID = 2
    static let both = [external, builtIn]

    @Test("the first placement has nowhere to stay, so it goes where the user is")
    func theFirstPlacement() {
        #expect(
            ScreenGeometry.choice(active: Self.external, current: nil, attached: Self.both, hovered: false)
                == Self.external)
        #expect(
            ScreenGeometry.choice(active: Self.builtIn, current: nil, attached: Self.both, hovered: false)
                == Self.builtIn)
    }

    @Test("the island follows the active screen, in both directions")
    func itFollowsTheActiveScreen() {
        #expect(
            ScreenGeometry.choice(
                active: Self.builtIn, current: Self.external, attached: Self.both, hovered: false)
                == Self.builtIn)
        #expect(
            ScreenGeometry.choice(
                active: Self.external, current: Self.builtIn, attached: Self.both, hovered: false)
                == Self.external)
    }

    @Test("an island already on the active screen stays put")
    func nothingToDo() {
        #expect(
            ScreenGeometry.choice(
                active: Self.builtIn, current: Self.builtIn, attached: Self.both, hovered: false)
                == Self.builtIn)
    }

    @Test("the island is never moved out from under a pointer that is on it")
    func hoverDefersTheMove() {
        // Crossing screens mid-hover would take the thing the user is reaching
        // for away mid-reach. The move is deferred, not cancelled.
        #expect(
            ScreenGeometry.choice(
                active: Self.builtIn, current: Self.external, attached: Self.both, hovered: true)
                == Self.external)
    }

    @Test("and it makes the move as soon as the pointer leaves")
    func andThenItMoves() {
        var current = Self.external
        current = ScreenGeometry.choice(
            active: Self.builtIn, current: current, attached: Self.both, hovered: true)
        #expect(current == Self.external)

        current = ScreenGeometry.choice(
            active: Self.builtIn, current: current, attached: Self.both, hovered: false)
        #expect(current == Self.builtIn)
    }

    @Test("a display that is unplugged takes the island with it, hover or not")
    func theUnpluggedDisplay() {
        // The one outcome that cannot be allowed is a window left on a screen
        // that is no longer there — so this outranks the hover rule above
        // rather than politely waiting for the pointer to leave.
        for hovered in [true, false] {
            #expect(
                ScreenGeometry.choice(
                    active: Self.builtIn,
                    current: Self.external,
                    attached: [Self.builtIn],
                    hovered: hovered
                ) == Self.builtIn,
                "left behind on a display that is gone (hovered: \(hovered))")
        }
    }

    @Test("a display that was never known is treated as gone")
    func anUnknownDisplay() {
        // `0` is what a screen with no id reads as, and it matches nothing.
        #expect(
            ScreenGeometry.choice(active: Self.builtIn, current: 0, attached: Self.both, hovered: true)
                == Self.builtIn)
    }

    @Test("one display is the answer to every question")
    func theLaptopOnItsOwn() {
        for current in [nil, Self.builtIn] as [CGDirectDisplayID?] {
            for hovered in [true, false] {
                #expect(
                    ScreenGeometry.choice(
                        active: Self.builtIn, current: current, attached: [Self.builtIn], hovered: hovered
                    ) == Self.builtIn)
            }
        }
    }
}
