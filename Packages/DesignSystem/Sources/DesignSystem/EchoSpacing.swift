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
    /// The island's expanded shell. Its bottom corners only; the top two are
    /// always square, because the shell hangs off the bezel.
    public static let islandExpanded: CGFloat = 22
    /// The island's collapsed shell.
    public static let islandCollapsed: CGFloat = 12
    /// A capsule control on the island. Half its height: the island takes
    /// iOS-style capsules where the window keeps rounded rects (DEC-4 may
    /// unify them; until it does, these are two families).
    public static let capsule: CGFloat = 13
    /// A value chip or an icon button on the island.
    public static let chip: CGFloat = 12
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
    /// A level gauge, half its height.
    public static let gauge: CGFloat = 2
}

/// The geometry of the controls themselves, as the design draws them.
/// `EchoLayout` is where the window's parts go; this is what sits inside them.
public nonisolated enum EchoControl {

    // MARK: In the window

    /// The one filled button a screen gets — "New recording" in the title bar.
    public static let primaryButtonHeight: CGFloat = 29
    public static let primaryButtonInset: CGFloat = 14

    /// A quiet button in the breadcrumb bar: Copy, Export, the "…".
    public static let toolbarButtonInset: CGFloat = 9

    /// The well a segmented tab strip sits in, and the segments inside it.
    public static let tabStripInset: CGFloat = 3
    public static let tabGap: CGFloat = 2
    public static let tabInset: CGFloat = 13

    /// The shadow under a selected tab. The design states it as a CSS
    /// shadow — offset 1, blur 2 — and a CSS blur is twice a SwiftUI radius.
    public static let tabSelectionShadowRadius: CGFloat = 1
    public static let tabSelectionShadowOffset: CGFloat = 1

    /// A status pill's padding.
    public static let pillInset = CGSize(width: 8, height: 3)

    /// The glyph at the head of a sidebar row: the magnifier, the gear, the
    /// trash. The artboards draw their own glyphs and never size the SF
    /// Symbol standing in for them, so this is the size the window ships,
    /// centred in the row rather than measured off the canvas.
    public static let sidebarGlyphSize: CGFloat = 12

    /// A property row: the icon in its label column, and the gap between the
    /// column and the value.
    public static let propertyIconSize: CGFloat = 14
    public static let propertyGap: CGFloat = 10

    // MARK: On the island

    /// A capsule control. Primary and secondary differ only in weight and in
    /// how much room the label is given.
    public static let capsuleHeight: CGFloat = 26
    public static let capsuleInset: CGFloat = 13
    public static let capsuleInsetSecondary: CGFloat = 12
    public static let capsuleInsetQuiet: CGFloat = 6
    /// Between a capsule's glyph and its label.
    public static let capsuleGap: CGFloat = 6

    /// A value chip: wider where the label starts than where the chevron ends.
    public static let chipHeight: CGFloat = 24
    public static let chipLeadingInset: CGFloat = 10
    public static let chipTrailingInset: CGFloat = 7
    public static let chipGap: CGFloat = 5

    /// An icon button, square and fully rounded.
    public static let iconButtonSize: CGFloat = 24

    /// The glyph inside an icon button, and the chevron inside a value chip:
    /// the design draws both at the same size.
    public static let islandGlyphSize: CGFloat = 10

    /// A level gauge: the bar, and the gap after its label.
    public static let gaugeHeight: CGFloat = 4
    public static let gaugeLabelGap: CGFloat = 6
}

public nonisolated enum EchoLayout {

    // MARK: The window

    /// The design's hairline: the 1 px rule the artboards draw under the title
    /// bar, down the sidebar's edge and across the document. A point, not a
    /// pixel — a half-point line disappears on the artboards' scale.
    public static let hairline: CGFloat = 1

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
    /// The air above the section label, separating it from the rows above.
    public static let sectionLabelTopMargin: CGFloat = 14
    /// A date group's header: Today, Yesterday, Last week, Earlier.
    public static let groupHeaderHeight: CGFloat = 22
    /// The air above a date group, between it and the group before it. The
    /// first group under the section label takes none.
    public static let groupHeaderTopMargin: CGFloat = 6

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
