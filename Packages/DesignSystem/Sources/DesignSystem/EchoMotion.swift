//
//  EchoMotion.swift
//  DesignSystem
//
//  How long the design gives things to happen in, and on what curve. Like the
//  spacing scale, these are values the design states rather than a rhythm
//  anybody invented, and a duration written into a view is a token that is
//  missing from here.
//

import SwiftUI

public nonisolated enum EchoMotion {

    // MARK: The island

    /// How long the island stays open after the pointer leaves it.
    ///
    /// The island sits across the top of the screen, where a pointer is
    /// usually on its way somewhere else. Without this every trip to the menu
    /// bar would open and shut it. It is also what absorbs the crossings a
    /// resize can synthesise under a stationary pointer.
    public static let islandHoverGrace: TimeInterval = 0.25

    /// The one spring the shell moves on.
    ///
    /// Width, height and corner radius all take it, together. The design is
    /// explicit that they are not three animations: a shape whose parts arrive
    /// at their new sizes at different moments does not read as one shape
    /// growing, it reads as a shape coming apart.
    ///
    /// Held as a `Spring` and not only as an `Animation` because the window
    /// around the shell has to know how long the motion lasts, and
    /// `settlingDuration` is the honest answer to that — a second number
    /// written down beside this one could only ever disagree with it.
    /// Written in the design's own terms — it states a response and a damping
    /// fraction — rather than converted to the duration-and-bounce spelling of
    /// the same spring, where a slip would be silent.
    public static let islandShellSpring = Spring(response: 0.38, dampingRatio: 0.86)

    public static var islandShell: Animation { .spring(islandShellSpring) }

    /// The ears leave as the shell opens, and come back as it closes.
    public static let islandEarFade: TimeInterval = 0.14

    public static var islandEars: Animation { .easeOut(duration: islandEarFade) }

    /// The open face arrives a moment after the shell does, rising the last
    /// few points into place, so the shell reads as making room for it rather
    /// than carrying it.
    public static let islandContentFade: TimeInterval = 0.24
    public static let islandContentDelay: TimeInterval = 0.09
    public static let islandContentRise: CGFloat = 5

    /// Only the opening is specified. Closing takes the same curve without the
    /// delay: a face on its way out has nothing to wait for.
    public static func islandContent(opening: Bool) -> Animation {
        .easeOut(duration: islandContentFade).delay(opening ? islandContentDelay : 0)
    }
}
