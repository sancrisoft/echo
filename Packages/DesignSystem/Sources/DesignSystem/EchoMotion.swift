//
//  EchoMotion.swift
//  DesignSystem
//
//  How long the design gives things to happen in. Like the spacing scale, these
//  are values the design states rather than a rhythm anybody invented, and a
//  duration written into a view is a token that is missing from here.
//

import Foundation

public nonisolated enum EchoMotion {

    /// How long the island stays open after the pointer leaves it.
    ///
    /// The island sits across the top of the screen, where a pointer is
    /// usually on its way somewhere else. Without this every trip to the menu
    /// bar would open and shut it. It is also what absorbs the crossings a
    /// resize can synthesise under a stationary pointer.
    public static let islandHoverGrace: TimeInterval = 0.25
}
