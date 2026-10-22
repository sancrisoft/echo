//
//  IslandWindowTransition.swift
//  Island
//
//  What the window has to be while the shell inside it is moving.
//
//  The shell animates in SwiftUI; the window around it is AppKit and does not
//  take part. That leaves one thing to get right — the window can never be
//  smaller than the shell it is drawing, or the animation is cut off at the
//  window's edge — and one way to get it right that needs no second animation
//  and no per-frame work:
//
//    · Opening, the window takes its new size at once. It is transparent, so
//      an early window shows nothing, and the shell then has room to grow into.
//    · Closing, the window keeps the size it had and is trimmed when the spring
//      has settled. The shell shrinks inside the room it already occupied.
//
//  Both are the same rule: the window is the union of where the shell is and
//  where it is going. The cost is that a closing island keeps a transparent
//  window slightly larger than its black for the length of the spring — which
//  is the better of the two ways to be wrong, since the alternative is visible.
//

import CoreGraphics

enum IslandWindowTransition {

    /// The frame the window must take right now.
    ///
    /// `animated` is false when nothing will move — Reduce Motion, or the
    /// first placement, where there is no "from" to keep room for — and then
    /// the target is simply it.
    static func now(from current: CGRect, to target: CGRect, animated: Bool) -> CGRect {
        guard animated else { return target }
        // A shell that is not where it was is not growing or shrinking, it is
        // somewhere else: another display, or the same one after the screens
        // were rearranged. The union of two frames that do not touch is a
        // window across the gap between them.
        guard current.intersects(target) else { return target }
        return current.union(target)
    }

    /// Whether the window still has to be trimmed once the shell has settled.
    static func settles(_ now: CGRect, to target: CGRect) -> Bool {
        now != target
    }
}
