//
//  HoverGraceTests.swift
//  IslandTests
//
//  The grace, driven by a timer the test owns. Nothing here sleeps: what is
//  under test is which timer was armed, for how long, and what firing it does.
//
//  The mechanism that produces the crossings is not testable without a real
//  panel and a real pointer, and is not tested here — spike #69 measured it on
//  hardware and `HoverBench` is how it is measured again.
//

import DesignSystem
import Foundation
import Testing

@testable import Island

@MainActor
@Suite("Hover grace")
struct HoverGraceTests {

    /// A timer that never fires unless the test fires it, and remembers what
    /// it was asked for.
    final class Timer {
        var armed: [TimeInterval] = []
        var fire: (@MainActor () -> Void)?
        var cancellations = 0

        var arming: HoverGraceArming {
            { [self] seconds, fire in
                armed.append(seconds)
                self.fire = fire
                return { self.cancellations += 1 }
            }
        }

        @MainActor func fireNow() {
            let pending = fire
            fire = nil
            pending?()
        }
    }

    @Test("the pointer arriving is immediate")
    func enteringDoesNotWait() {
        let timer = Timer()
        var changes: [Bool] = []
        let grace = HoverGrace(grace: 1, arm: timer.arming) { changes.append($0) }

        grace.entered()
        #expect(grace.isInside)
        #expect(changes == [true])
        #expect(timer.armed.isEmpty, "arriving armed a timer; only leaving waits")
    }

    @Test("the pointer leaving waits out the grace")
    func leavingWaits() {
        let timer = Timer()
        var changes: [Bool] = []
        let grace = HoverGrace(grace: 1, arm: timer.arming) { changes.append($0) }

        grace.entered()
        grace.exited()
        #expect(grace.isInside, "the island closed the instant the pointer left it")
        #expect(changes == [true])

        timer.fireNow()
        #expect(!grace.isInside)
        #expect(changes == [true, false])
    }

    @Test("coming back inside the grace means it never left")
    func returningInsideTheGraceCancelsIt() {
        let timer = Timer()
        var changes: [Bool] = []
        let grace = HoverGrace(grace: 1, arm: timer.arming) { changes.append($0) }

        grace.entered()
        grace.exited()
        grace.entered()
        #expect(timer.cancellations == 1)
        #expect(grace.isInside)
        // One change, not three: nothing on screen should have moved.
        #expect(changes == [true])

        // And the cancelled timer, were it to fire anyway, must not close it.
        timer.fireNow()
        #expect(grace.isInside)
    }

    @Test("a second departure does not arm a second timer")
    func repeatedExitsArmOnce() {
        let timer = Timer()
        let grace = HoverGrace(grace: 1, arm: timer.arming) { _ in }

        grace.entered()
        grace.exited()
        grace.exited()
        grace.exited()
        #expect(timer.armed.count == 1)
    }

    @Test("a departure with nothing to depart from does nothing")
    func exitingWhileOutsideIsInert() {
        let timer = Timer()
        var changes: [Bool] = []
        let grace = HoverGrace(grace: 1, arm: timer.arming) { changes.append($0) }

        grace.exited()
        #expect(timer.armed.isEmpty)
        #expect(changes.isEmpty)
    }

    @Test("the grace is the design's, not a number chosen here")
    func theGraceComesFromTheDesign() {
        let timer = Timer()
        let grace = HoverGrace(arm: timer.arming) { _ in }
        grace.entered()
        grace.exited()
        #expect(timer.armed == [EchoMotion.islandHoverGrace])
    }

    @Test("teardown does not wait")
    func forgettingIsImmediate() {
        let timer = Timer()
        var changes: [Bool] = []
        let grace = HoverGrace(grace: 1, arm: timer.arming) { changes.append($0) }

        grace.entered()
        grace.forget()
        #expect(!grace.isInside)
        #expect(changes == [true, false])
    }

    @Test("a pending departure is dropped by teardown rather than fired later")
    func forgettingCancelsAPendingDeparture() {
        let timer = Timer()
        let grace = HoverGrace(grace: 1, arm: timer.arming) { _ in }

        grace.entered()
        grace.exited()
        grace.forget()
        #expect(timer.cancellations == 1)
        #expect(!grace.isInside)
    }
}
