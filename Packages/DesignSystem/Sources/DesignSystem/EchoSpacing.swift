//
//  EchoSpacing.swift
//  DesignSystem
//
//  Spacing, radii and the few fixed dimensions the layout shares. A view
//  reaches for a named step, never a literal.
//

import SwiftUI

public nonisolated enum EchoSpacing {
    public static let xxs: CGFloat = 2
    public static let xs: CGFloat = 4
    public static let s: CGFloat = 8
    public static let m: CGFloat = 12
    public static let l: CGFloat = 16
    public static let xl: CGFloat = 24
    public static let xxl: CGFloat = 32
}

public nonisolated enum EchoRadius {
    /// Controls inside the window (the design's 6–7 pt rounded rects).
    public static let control: CGFloat = 7
    /// Rows and chips.
    public static let row: CGFloat = 8
    /// Cards and panels.
    public static let card: CGFloat = 12
}

public nonisolated enum EchoLayout {
    /// The sidebar's fixed width.
    public static let sidebarWidth: CGFloat = 260
    /// The widest a reading column gets.
    public static let readingWidth: CGFloat = 720
    /// The window's smallest size at which nothing clips.
    public static let minimumWindow = CGSize(width: 900, height: 560)
    /// The window's default size.
    public static let defaultWindow = CGSize(width: 1100, height: 720)
}
