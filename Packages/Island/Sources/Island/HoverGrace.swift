//
//  HoverGrace.swift
//  Island
//
//  Turns crossings into presence.
//
//  Two things make a raw exit the wrong moment to close the island. The first
//  is the design's: the island lies across the top of the screen, where a
//  pointer is usually on its way to the menu bar, and shutting on every trip
//  past would make it flicker. The second is the mechanism's: opening the
//  shell resizes its window under a pointer that has not moved, and AppKit can
//  answer that with an exit followed immediately by an entry. A grace absorbs
//  both, and it is the same grace, because they are the same mistake — reading
//  one crossing as a decision.
//
//  Entry is immediate. Only leaving waits.
//

import DesignSystem
import Foundation

/// Arms a one-shot timer and returns the way to cancel it. A seam so the tests
/// can prove what was armed and what firing it does, without sleeping.
typealias HoverGraceArming =
    @MainActor (_ seconds: TimeInterval, _ fire: @escaping @MainActor () -> Void) ->
    @MainActor () -> Void

@MainActor
final class HoverGrace {

    /// Whether the island should be treated as under the pointer. True from
    /// the moment it is entered until the grace after it is left.
    private(set) var isInside = false

    private let grace: TimeInterval
    private let arm: HoverGraceArming
    private let onChange: @MainActor (Bool) -> Void
    private var cancel: (@MainActor () -> Void)?

    /// Which departure the armed timer belongs to. Cancelling a timer is a
    /// request, not a guarantee — a fire already on its way cannot be recalled
    /// — so a timer that belongs to a departure the pointer has since undone
    /// is ignored on arrival rather than trusted to have been stopped.
    private var departure = 0

    init(
        grace: TimeInterval = EchoMotion.islandHoverGrace,
        arm: @escaping HoverGraceArming = HoverGrace.liveTimer,
        onChange: @escaping @MainActor (Bool) -> Void
    ) {
        self.grace = grace
        self.arm = arm
        self.onChange = onChange
    }

    static let liveTimer: HoverGraceArming = { seconds, fire in
        let task = Task { @MainActor in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            fire()
        }
        return { task.cancel() }
    }

    /// The pointer arrived. Any pending departure is forgotten: coming back
    /// inside the grace means it never left.
    func entered() {
        cancel?()
        cancel = nil
        departure += 1
        guard !isInside else { return }
        isInside = true
        onChange(true)
    }

    /// The pointer left — provisionally. Nothing changes until the grace runs
    /// out.
    func exited() {
        guard isInside, cancel == nil else { return }
        departure += 1
        let departure = departure
        cancel = arm(grace) { [weak self] in
            guard let self, departure == self.departure else { return }
            cancel = nil
            guard isInside else { return }
            isInside = false
            onChange(false)
        }
    }

    /// Forgets the pointer at once, grace and all. For teardown, where waiting
    /// to close a window that is already going away is worse than not.
    func forget() {
        cancel?()
        cancel = nil
        departure += 1
        guard isInside else { return }
        isInside = false
        onChange(false)
    }
}
