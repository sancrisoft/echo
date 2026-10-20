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
    /// A card in the models panel.
    public static let card: CGFloat = 10
    /// A well a segmented control sits in.
    public static let well: CGFloat = 8
    /// Controls inside the window: buttons, input fields.
    public static let control: CGFloat = 7
    /// A row, a segment of a tab strip, a toolbar button.
    public static let row: CGFloat = 6
    /// A status pill.
    public static let pill: CGFloat = 5
    /// Code inside a summary's prose.
    public static let inlineCode: CGFloat = 4
    /// A find match in a transcript.
    public static let findMatch: CGFloat = 3
    /// A row in Trash's list.
    public static let listRow: CGFloat = 8
    /// A key drawn in a footer's hints: ↑↓, ↵, ⌫.
    public static let keycap: CGFloat = 4
    /// The ⌘K palette, and the row the keyboard is on inside it.
    public static let palette: CGFloat = 12
    public static let paletteRow: CGFloat = 7
    /// The transcript's speaker split, half its height.
    public static let speakerSplit: CGFloat = 2
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

    /// The glyph a primary button carries before its label — New recording's
    /// dot, Stop's square — and the gap between the two.
    public static let primaryButtonGlyphSize: CGFloat = 9
    public static let primaryButtonGap: CGFloat = 8

    /// The pill the title bar's running clock sits in, beside Stop: as tall as
    /// the button, a little tighter at the sides, and the gap between its red
    /// dot (`recordingDotSize`) and the digits.
    public static let timerPillInset: CGFloat = 11
    public static let timerPillGap: CGFloat = 7

    /// A quiet button in the breadcrumb bar: Copy, Export, the "…".
    public static let toolbarButtonInset: CGFloat = 9
    /// Between two buttons in the breadcrumb bar, and the glyph the "…" one
    /// carries.
    public static let toolbarButtonGap: CGFloat = 3
    public static let toolbarGlyphSize: CGFloat = 15

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
    /// Between a property's value and the quieter qualifier after it.
    public static let propertyQualifierGap: CGFloat = 7

    /// A summary's list markers: the bullet's dot and a task's checkbox.
    public static let bulletSize: CGFloat = 4.5
    public static let checkboxSize: CGFloat = 15
    /// The room code inside prose takes beyond its letters, on its fill: at
    /// each side, and above and below.
    public static let inlineCodeInset = CGSize(width: 5, height: 1.5)

    /// The transcript's find field: its height, its side inset, the gap
    /// between its parts, and the magnifier at its head.
    public static let findFieldHeight: CGFloat = 28
    public static let findFieldInset: CGFloat = 11
    public static let findFieldGap: CGFloat = 8
    public static let findGlyphSize: CGFloat = 13
    /// How far a find match's fill reaches past its letters: at each side,
    /// and above and below.
    public static let findMatchInset = CGSize(width: 3, height: 1)

    /// The speaker split under a transcript's title: the bar's height, the
    /// gap between You's share and Others', and the gap between the bar and
    /// each share's words.
    public static let speakerSplitHeight: CGFloat = 4
    public static let speakerSplitGap: CGFloat = 2
    public static let speakerSplitLabelGap: CGFloat = 12
    /// Between a transcript's status and the model that wrote it.
    public static let provenanceGap: CGFloat = 8

    /// The dot inside the live status pill, and the gap between it and the
    /// word.
    public static let pillDotSize: CGFloat = 6
    public static let pillGap: CGFloat = 6

    /// The mark in the sidebar's app row.
    public static let appMarkSize: CGFloat = 17

    /// The glyph above a document's placeholder, while there is nothing yet
    /// to read.
    public static let placeholderGlyphSize: CGFloat = 34

    /// The count beside a list's title, in its capsule, and the room inside
    /// a key drawn in a footer's hints.
    public static let listCountInset = CGSize(width: 8, height: 2)
    public static let keycapInset = CGSize(width: 5, height: 1)
    /// The room inside a key drawn on its own rather than in a row of hints:
    /// the palette's `esc`, `⌘R` and `↵`.
    public static let keycapInsetStandalone = CGSize(width: 6, height: 2)
    /// The glyph at the head of a Trash row, and the gap between a row's two
    /// buttons.
    public static let listRowGlyphSize: CGFloat = 16
    public static let listRowActionGap: CGFloat = 6

    /// The glyph above an empty or broken screen.
    public static let emptyGlyphSize: CGFloat = 30

    /// The ⌘K palette's glyphs: the magnifier in the query's row, and the
    /// one at the head of each result and action; the stroke they are drawn
    /// with, on their 16-point grid; and the room around the words a match
    /// fills.
    public static let paletteSearchGlyphSize: CGFloat = 17
    public static let paletteRowGlyphSize: CGFloat = 15
    public static let paletteGlyphStroke: CGFloat = 1.4
    public static let paletteMatchInset = CGSize(width: 2, height: 0)

    /// The window's level meter: a row of bars per channel, the newest at the
    /// right. A bar's width, the gap between two, how many a row holds, the
    /// height of a bar at rest, and the pitch between the two rows — which is
    /// also the tallest a bar gets, so You and Others never touch. The
    /// artboard draws a sample whose loudest bars run past the meter's edge;
    /// a measured level never does.
    public static let meterBarWidth: CGFloat = 2
    public static let meterBarGap: CGFloat = 1.4
    public static let meterBarCount = 40
    public static let meterBarRest: CGFloat = 3
    public static let meterRowPitch: CGFloat = 16
    /// Between the two channel names beside the meter.
    public static let meterLabelGap: CGFloat = 3

    /// The glyph before the live footer's note, and the gap after it.
    public static let footerGlyphSize: CGFloat = 14
    public static let footerGlyphGap: CGFloat = 6

    /// The control button the models panel and the welcome screen draw for a
    /// row's action — Pause, Resume, Retry: a step smaller than the title
    /// bar's button, with a tighter inset.
    public static let controlButtonHeight: CGFloat = 28
    public static let controlButtonInset: CGFloat = 12

    /// A model's row in the models panel: its glyph and the gap after it.
    public static let modelGlyphSize: CGFloat = 19
    public static let modelGlyphGap: CGFloat = 13
    /// A download's bar, its percentage's column, and the gap between the
    /// parts on the row's right.
    public static let modelBarWidth: CGFloat = 150
    public static let modelBarHeight: CGFloat = 4
    public static let modelPercentWidth: CGFloat = 34
    public static let modelTrailingGap: CGFloat = 11
    /// The loading spinner and the gap before its word.
    public static let modelSpinnerSize: CGFloat = 14
    public static let modelLoadingGap: CGFloat = 9
    /// The check inside the Ready pill.
    public static let readyCheckSize: CGFloat = 11

    /// The welcome screen's one large button, Start using Echo: taller and
    /// wider-set than the title bar's.
    public static let prominentButtonHeight: CGFloat = 34
    public static let prominentButtonInset: CGFloat = 18

    /// The mark above the welcome screen's title.
    public static let welcomeMarkSize: CGFloat = 38
    /// A welcome-screen step's glyph: a ring, a check, or a turning arc.
    public static let stepGlyphSize: CGFloat = 19
    /// A model's line in the welcome screen's third step: its name's column
    /// and the column of its figure after the bar.
    public static let welcomeModelNameWidth: CGFloat = 132
    public static let welcomeModelValueWidth: CGFloat = 62
    /// The shield before the welcome screen's footer line.
    public static let welcomeShieldSize: CGFloat = 13

    // MARK: On the island

    /// A capsule control. Primary and secondary differ only in weight and in
    /// how much room the label is given.
    public static let capsuleHeight: CGFloat = 26
    public static let capsuleInset: CGFloat = 13
    public static let capsuleInsetSecondary: CGFloat = 12
    public static let capsuleInsetQuiet: CGFloat = 6
    /// Between a capsule's glyph and its label.
    public static let capsuleGap: CGFloat = 6
    /// The box a capsule's glyph is drawn in: Record's dot, Stop's square.
    public static let capsuleGlyphSize: CGFloat = 8

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
    /// face, in the ear it collapses into, and in the window's title bar
    /// beside the clock.
    public static let recordingDotSize: CGFloat = 7

    /// The glyph at the head of an open face: the mark, the camera, the
    /// countdown ring. The saved face's check is a size smaller.
    public static let islandIconSize: CGFloat = 15
    public static let islandCheckSize: CGFloat = 14
    public static let islandSpinnerSize: CGFloat = 13

    /// The glyph in an ear, either side of the cutout.
    public static let earGlyphSize: CGFloat = 12

    /// The recording ear's level pictogram, and the gap between it and the
    /// dot beside it.
    public static let earLevelBars = CGSize(width: 15, height: 11)
    public static let earGroupGap: CGFloat = 7

    // MARK: In the menu bar

    /// The mark's grid in the menu bar: the brand sheet's 16 pt template.
    public static let menuBarMarkSize: CGFloat = 16
    /// Between the mark and the timer beside it while a session runs.
    public static let menuBarTimerGap: CGFloat = 7
    /// The timer's size, in the monospaced face. With the island switched off
    /// it is the size of every word the item carries beside the mark too —
    /// the countdown in the same face, a name or a status in the interface
    /// one — so the item has one size, the one the design draws for it.
    public static let menuBarTimerSize: CGFloat = 11
}

public nonisolated enum EchoLayout {

    // MARK: The window

    /// The design's hairline: the 1 px rule the artboards draw under the title
    /// bar, down the sidebar's edge and across the document. A point, not a
    /// pixel — a half-point line disappears on the artboards' scale.
    public static let hairline: CGFloat = 1

    // The title bar has no token. The artboard draws it 44 pt, and AppKit
    // fixes a title bar's height per style — measured on macOS 27.0.1: 32 bare,
    // 40 with a compact toolbar, 52 with a unified one, whatever the items in
    // it. The window takes the compact toolbar, the nearest, because that is
    // the one height at which the system centres the traffic lights and the
    // title bar's button together (`TitleBar` in Workspace).

    /// The window's smallest size at which nothing clips. Not drawn: the
    /// artboard shows one window size, and this is the floor the layout keeps.
    public static let minimumWindow = CGSize(width: 900, height: 560)
    /// The window's default size. Not drawn either — the artboard's 1440 × 900
    /// is a canvas, not a launch size.
    public static let defaultWindow = CGSize(width: 1100, height: 720)

    // MARK: The sidebar

    /// The sidebar's fixed width.
    public static let sidebarWidth: CGFloat = 256
    /// The app row at the very top, with the mark and the chevron, and its
    /// inset — a point tighter than every other row's, as drawn.
    public static let appRowHeight: CGFloat = 34
    public static let appRowInset: CGFloat = 8
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

    /// Between a face's two lines, and between the words of its first.
    public static let islandLineGap: CGFloat = 5
    public static let islandTitleGap: CGFloat = 8

    /// Between the idle face's two lines. Not the design's: its second line
    /// is a 24 pt chip, and the artboards set the open row in the whole 74 pt
    /// of the shell, where on a Mac the top of it is the camera's cutout. The
    /// row hangs below the cutout instead (`IslandShell`), and below a 32 pt
    /// cutout two lines at the design's gap overflow the band that is left.
    public static let islandCompactLineGap: CGFloat = 2

    /// Between the recording face's two level gauges.
    public static let islandGaugeGap: CGFloat = 12

    /// The progress hairline along the open shell's bottom edge.
    public static let islandProgressHeight: CGFloat = 2

    /// The cutout Echo draws on a screen that has none, when no screen with
    /// one is attached to read it from: the 14" M4 Pro's, as measured on
    /// 2026-09-11 (spike #69). With a notched screen attached, the drawn one
    /// takes that screen's real width instead. Its height is never a token —
    /// it is the menu bar's, read per screen (DEC-1, product owner 2026-10-02).
    public static let islandDrawnCutoutWidth: CGFloat = 185

    // MARK: The document

    /// The breadcrumb bar above the document.
    public static let breadcrumbHeight: CGFloat = 40
    /// The horizontal inset of the breadcrumb bar, and the room either side
    /// of the "/" between its parts.
    public static let breadcrumbInset: CGFloat = 18
    public static let breadcrumbSlashGap: CGFloat = 7
    /// A button in the breadcrumb bar: Copy, Export, the "…" icon button.
    public static let toolbarButtonHeight: CGFloat = 26
    /// The widest a reading column gets.
    public static let readingWidth: CGFloat = 720
    /// The gap between the breadcrumb bar and the document title.
    public static let readingTopInset: CGFloat = 26
    /// Between the title and the first property row under it.
    public static let titleBottomGap: CGFloat = 18
    /// The rule between the property rows and the tabs, and the air above
    /// and below it.
    public static let documentDividerTop: CGFloat = 26
    public static let documentDividerBottom: CGFloat = 20
    /// A placeholder in the document — glyph, line, sentence — the gap
    /// between its parts, how wide the sentence may run, and how far above
    /// the centre it sits.
    public static let placeholderGap: CGFloat = 14
    public static let placeholderWidth: CGFloat = 380
    public static let placeholderBottomInset: CGFloat = 40
    /// An empty or broken screen: the gap between its glyph, title, sentence
    /// and buttons, how wide the sentence may run, the gap between two
    /// buttons, and the room kept around it all.
    public static let emptyStateGap: CGFloat = 13
    public static let emptyStateMessageWidth: CGFloat = 280
    public static let emptyStateActionGap: CGFloat = 8
    public static let emptyStateInset: CGFloat = 24
    /// A list that takes the document's place, as Trash does: its header's
    /// height, insets and gap; the note under it; the list's inset and the
    /// gap between rows; a row's height, inset and the gap between its parts;
    /// the columns of its days left and of its buttons, kept on every row so
    /// the columns line up; and the footer of key hints.
    public static let listHeaderHeight: CGFloat = 62
    public static let listHeaderLeadingInset: CGFloat = 24
    public static let listHeaderTrailingInset: CGFloat = 20
    public static let listHeaderGap: CGFloat = 11
    public static let listNoteBottom: CGFloat = 14
    public static let listInset: CGFloat = 12
    public static let listRowSpacing: CGFloat = 3
    public static let listRowHeight: CGFloat = 58
    public static let listRowInset: CGFloat = 13
    public static let listRowGap: CGFloat = 13
    public static let listDaysWidth: CGFloat = 108
    public static let listActionsWidth: CGFloat = 176
    public static let listFooterHeight: CGFloat = 44
    public static let listFooterGap: CGFloat = 16
    public static let keyHintGap: CGFloat = 6
    /// The ⌘K palette (`Search.dc.html`): its width, and how far below the
    /// title bar it floats — the artboard's 122 from the window's top, less
    /// its 44-point title bar; the query's row, its inset and gap; the room
    /// around the lists; a group's label; a result's and an action's height,
    /// their inset and gap; the rule between the groups; the strip of hints
    /// and its gap; and the shadow — the artboard's 80-point blur, which
    /// SwiftUI takes as a radius of half that.
    public static let paletteWidth: CGFloat = 620
    public static let paletteTopInset: CGFloat = 78
    public static let paletteFieldHeight: CGFloat = 52
    public static let paletteFieldInset: CGFloat = 16
    public static let paletteFieldGap: CGFloat = 11
    public static let paletteListInset: CGFloat = 8
    public static let paletteGroupLabelHeight: CGFloat = 26
    public static let paletteResultHeight: CGFloat = 44
    public static let paletteActionHeight: CGFloat = 38
    public static let paletteRowInset: CGFloat = 10
    public static let paletteRowGap: CGFloat = 11
    public static let paletteRuleInset = CGSize(width: 10, height: 8)
    public static let paletteFooterHeight: CGFloat = 38
    public static let paletteFooterGap: CGFloat = 16
    public static let paletteShadowRadius: CGFloat = 40
    public static let paletteShadowOffset: CGFloat = 32
    /// The footer under a live session's document — the meter, what is
    /// happening, where it happens — its height, its side insets and the gap
    /// between its parts.
    public static let liveFooterHeight: CGFloat = 56
    public static let liveFooterInset: CGFloat = 20
    public static let liveFooterGap: CGFloat = 16
    /// A property row under the title.
    public static let propertyRowHeight: CGFloat = 30
    /// The label column of a property row: icon plus its word.
    public static let propertyLabelWidth: CGFloat = 104
    /// The fade to the background at the foot of a scrolling document.
    public static let documentFadeHeight: CGFloat = 76
    /// A summary under the tabs: the air above its first block, above and
    /// below a section heading, between two blocks or two list items, and
    /// between a list item's marker and its words.
    public static let summaryTopGap: CGFloat = 24
    public static let summaryHeadingTop: CGFloat = 26
    public static let summaryHeadingBottom: CGFloat = 9
    public static let summaryBlockGap: CGFloat = 9
    public static let listMarkerGap: CGFloat = 11
    /// A transcript under the tabs: the air above its first turn, between
    /// two turns, between a turn's speaker and its time, and between that
    /// line and the words.
    public static let transcriptTopGap: CGFloat = 26
    public static let turnGap: CGFloat = 21
    public static let turnLabelGap: CGFloat = 9
    public static let turnTextGap: CGFloat = 5
    /// The find field to the right of the transcript's tabs.
    public static let findFieldWidth: CGFloat = 208
    /// The speaker split's bar.
    public static let speakerSplitWidth: CGFloat = 180
    /// A card's inset in the models panel, and the gap between two cards.
    public static let modelCardInset = CGSize(width: 16, height: 14)
    public static let modelPanelGap: CGFloat = 12

    // The welcome screen (`FirstRun.dc.html`): one column, centred.

    public static let welcomeColumnWidth: CGFloat = 560
    /// Under the mark, under the title, and under the paragraph.
    public static let welcomeMarkGap: CGFloat = 26
    public static let welcomeTitleGap: CGFloat = 12
    public static let welcomeIntroGap: CGFloat = 34
    /// Between "Three things to set up, once" and the first step.
    public static let welcomeSectionGap: CGFloat = 10
    /// A step's least height, and the gap between its glyph and its words.
    public static let welcomeStepHeight: CGFloat = 52
    public static let welcomeStepGap: CGFloat = 14
    /// The models step: its vertical inset, how far its glyph drops to meet
    /// the first line, the gap under its words, between its model lines, and
    /// inside one.
    public static let welcomeModelsInset: CGFloat = 14
    public static let welcomeModelsGlyphDrop: CGFloat = 2
    public static let welcomeModelsGap: CGFloat = 10
    public static let welcomeModelLineGap: CGFloat = 9
    public static let welcomeModelItemGap: CGFloat = 10
    /// Above the hairline that closes the steps.
    public static let welcomeStepsBottomGap: CGFloat = 4
    /// Above the buttons, and between them.
    public static let welcomeActionsTopGap: CGFloat = 26
    public static let welcomeActionsGap: CGFloat = 12
    /// Above the footer line, and between its shield and its words.
    public static let welcomeFooterTopGap: CGFloat = 30
    public static let welcomeFooterGap: CGFloat = 7
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
    ///
    /// Collapsed, retaken: the artboard's 272 leaves its ears off-centre
    /// around the cutout, and the island hangs centred on it, so each ear gets
    /// half of what is left. On the 14" cutout the design's own fixture —
    /// "Zoom" in the trailing ear — needs 274.
    public static let callDetected = IslandWidth(collapsed: 274, expanded: 344)
    /// A session is live: the timer and the two levels.
    public static let recording = IslandWidth(collapsed: 320, expanded: 360)
    /// The call ended under a live recording, and the stop is counting down.
    public static let callEnded = IslandWidth(collapsed: 312, expanded: 360)
    /// The meeting is on disk.
    public static let saved = IslandWidth(collapsed: 296, expanded: 352)
    /// The summary is being written.
    public static let summarizing = IslandWidth(collapsed: 300, expanded: 340)
}
