//
//  IslandHoverView.swift
//  Island
//
//  The one mechanism by which the island learns about the pointer.
//
//  Spike #69 measured both candidates on this hardware and they are not
//  equivalent. An `NSTrackingArea` with `.activeAlways` delivered 14 entries
//  and 14 exits over two runs, always paired, under every condition tried —
//  a slow approach, a fast pass, another app frontmost. `acceptsMouseMovedEvents`
//  delivered ZERO events of any kind on a clean run: setting the flag does not
//  rescue a window that never becomes key, and the island must never become
//  key. So this is not the better of two options, it is the only one.
//
//  `.mouseMoved` is deliberately absent from the options. It arrived in one of
//  eight condition-runs and not in the other seven, even when asked for. Hover
//  here is CROSSINGS ONLY: whether the pointer is on the island or not. Where
//  it is inside the island is not knowable, and nothing may be built on it.
//
//  A locked screen reports nothing at all — `loginwindow` owns the event
//  stream — which is worth knowing before believing that hover has broken.
//

import AppKit

/// Reports the pointer entering and leaving the island.
final class IslandHoverView: NSView {

    /// Called with `true` when the pointer arrives, `false` when it leaves.
    /// Never called with where it is.
    var onCrossing: (Bool) -> Void = { _ in }

    init(hosting content: NSView) {
        super.init(frame: .zero)
        content.autoresizingMask = [.width, .height]
        addSubview(content)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        subviews.first?.frame = bounds
    }

    /// Rebuilt on every layout, which is what keeps the area in step with a
    /// shell that changes size as it opens and closes.
    ///
    /// The area is the whole window, which is slightly more than the black:
    /// the flares' margin at the top corners, and on a screen with no cutout
    /// the room the pill's shadow needs. Narrowing it to the shape would cost
    /// the one property the spike actually verified, `.inVisibleRect`, and buy
    /// a precision that crossings do not have anyway.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(
            NSTrackingArea(
                rect: .zero,
                options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                owner: self,
                userInfo: nil
            )
        )
    }

    override func mouseEntered(with event: NSEvent) { onCrossing(true) }
    override func mouseExited(with event: NSEvent) { onCrossing(false) }
}
