//
//  EchoSpacing.swift
//  DesignSystem
//
//  Spacing, radii and the fixed dimensions the layout shares. A view reaches
//  for a named step, never a literal.
//
//  The radii and the dimensions are not a scale anyone invented: each one is a
//  number the workspace artboard draws, and the name says which part of the
//  window it belongs to.
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
    /// The window's own corner.
    public static let window: CGFloat = 11
    /// A well a segmented control sits in.
    public static let well: CGFloat = 8
    /// Controls inside the window: buttons, input fields.
    public static let control: CGFloat = 7
    /// A row, a segment of a tab strip, a toolbar button.
    public static let row: CGFloat = 6
    /// A status pill.
    public static let pill: CGFloat = 5
}

public nonisolated enum EchoLayout {

    // MARK: The window

    /// The title bar, with a hairline under it.
    public static let titleBarHeight: CGFloat = 44
    /// The window's smallest size at which nothing clips. Not drawn: the
    /// artboard shows one window size, and this is the floor the layout keeps.
    public static let minimumWindow = CGSize(width: 900, height: 560)
    /// The window's default size. Not drawn either — the artboard's 1440 × 900
    /// is a canvas, not a launch size.
    public static let defaultWindow = CGSize(width: 1100, height: 720)

    // MARK: The sidebar

    /// The sidebar's fixed width.
    public static let sidebarWidth: CGFloat = 256
    /// The app row at the very top, with the mark and the chevron.
    public static let appRowHeight: CGFloat = 34
    /// A row in the sidebar: a meeting, Search, Settings, Trash.
    public static let sidebarRowHeight: CGFloat = 29
    /// The horizontal inset inside a sidebar row.
    public static let sidebarRowInset: CGFloat = 9
    /// The "Meetings" section label and its count.
    public static let sectionLabelHeight: CGFloat = 30
    /// A date group's header: Today, Yesterday, Last week, Earlier.
    public static let groupHeaderHeight: CGFloat = 22

    // MARK: The document

    /// The breadcrumb bar above the document.
    public static let breadcrumbHeight: CGFloat = 40
    /// The horizontal inset of the breadcrumb bar.
    public static let breadcrumbInset: CGFloat = 18
    /// A button in the breadcrumb bar: Copy, Export, the "…" icon button.
    public static let toolbarButtonHeight: CGFloat = 26
    /// The widest a reading column gets.
    public static let readingWidth: CGFloat = 720
    /// The gap between the breadcrumb bar and the document title.
    public static let readingTopInset: CGFloat = 26
    /// A property row under the title.
    public static let propertyRowHeight: CGFloat = 30
    /// The label column of a property row: icon plus its word.
    public static let propertyLabelWidth: CGFloat = 104
    /// The fade to the background at the foot of a scrolling document.
    public static let documentFadeHeight: CGFloat = 76
}
