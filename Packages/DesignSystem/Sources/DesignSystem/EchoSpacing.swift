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
    /// The fallback shell on a screen with no cutout: fully rounded, so half
    /// of `EchoLayout.islandPillSize.height` rather than a corner of its own.
    public static let islandPill: CGFloat = 17
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

    /// The red dot that says a session is live: on the expanded recording
    /// face, and in the ear it collapses into.
    public static let recordingDotSize: CGFloat = 7
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

    // MARK: The island

    /// The shell's height when it is expanded. One row, on every face: only
    /// the width changes between them. Its collapsed height is not a token —
    /// it is the cutout's own height, read per screen (`IslandMetrics`).
    public static let islandExpandedHeight: CGFloat = 74

    /// The concave flare at each of the shell's top corners, square. It sits
    /// OUTSIDE the shell's width, one at each end, so a face's silhouette is
    /// its width plus two of these.
    public static let islandFlare: CGFloat = 16

    /// The inset of an ear's content from the shell's outer edge, while it is
    /// collapsed around the cutout.
    public static let islandEarInset: CGFloat = 13

    /// The expanded row's insets. It is wider on the side the icon is on than
    /// on the side the controls are.
    public static let islandRowLeadingInset: CGFloat = 14
    public static let islandRowTrailingInset: CGFloat = 12

    /// Between the parts of the expanded row.
    public static let islandRowGap: CGFloat = 11

    /// The fallback shell, on a screen with no cutout: fixed, where the notched
    /// shell is only as wide as its words need.
    public static let islandPillSize = CGSize(width: 320, height: 34)

    /// The air between the menu bar and the fallback pill. The notched shell
    /// takes none — it hangs off the top edge of the screen.
    public static let islandPillTopGap: CGFloat = 8

    /// The pill's shadow, which the notched shell does not have: it floats
    /// clear of the bezel, so it casts. The design states it as a CSS shadow —
    /// offset 10, blur 26 — and a CSS blur is twice a SwiftUI radius.
    public static let islandPillShadowRadius: CGFloat = 13
    public static let islandPillShadowOffset: CGFloat = 10

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

/// How wide one island face is, collapsed and expanded.
///
/// Width is the only thing that separates the faces: every expanded one is
/// `EchoLayout.islandExpandedHeight` tall, and every collapsed one is as tall
/// as the screen's cutout. The numbers are what the design draws, and they
/// barely move — the whole swing between the narrowest and the widest expanded
/// face is a fraction of the shell — because a capsule that changed shape as
/// it changed state would read as a different object each time.
///
/// The design sets a width by the longest line of copy a face carries, so
/// these are measurements of drawn faces rather than choices. A face whose
/// words no longer fit its width is a measurement to retake here, not a
/// `minWidth` to add at the point of use.
public nonisolated struct IslandWidth: Equatable, Sendable {

    public let collapsed: CGFloat
    public let expanded: CGFloat

    public init(collapsed: CGFloat, expanded: CGFloat) {
        self.collapsed = collapsed
        self.expanded = expanded
    }

    /// Nothing is happening: the app's permanent presence, with empty ears.
    public static let idle = IslandWidth(collapsed: 200, expanded: 324)
    /// A call was noticed and a recording is offered.
    public static let callDetected = IslandWidth(collapsed: 272, expanded: 344)
    /// A session is live: the timer and the two levels.
    public static let recording = IslandWidth(collapsed: 320, expanded: 360)
    /// The call ended under a live recording, and the stop is counting down.
    public static let callEnded = IslandWidth(collapsed: 312, expanded: 360)
    /// The meeting is on disk.
    public static let saved = IslandWidth(collapsed: 296, expanded: 352)
    /// The summary is being written.
    public static let summarizing = IslandWidth(collapsed: 300, expanded: 340)
}
