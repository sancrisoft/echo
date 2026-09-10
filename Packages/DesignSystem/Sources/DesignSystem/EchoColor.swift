//
//  EchoColor.swift
//  DesignSystem
//
//  The palette, as semantic tokens. Views name a role (`textSecondary`,
//  `surfaceRaised`, `accent`), never a value, so the two appearances are one
//  decision made here.
//
//  Values come from the internal design: a grey interface where the accent
//  (cobalt) marks only selection and links, and the recording red is the one
//  saturated thing on screen. Every pair below was read off the workspace
//  artboards in both appearances; where the brand sheet's ramp and a workspace
//  artboard disagreed the artboard won, because that is the surface being
//  built.
//
//  Platform trap, measured on macOS 26: the window background, List backgrounds
//  and the title bar are materials tinted by the user's wallpaper, not flat
//  colors. A flat color painted over one reads as a mismatched band in dark
//  mode. So the surfaces split in two kinds:
//
//  * `windowBackground` and `sidebarBackground` are *backdrops*. Over the
//    window they are the target look a tinted material has to reach, never a
//    fill painted on top of it. They are opaque only where there is no material
//    to preserve — a panel that must not let anything through, such as the
//    island or a popover body.
//  * `surface`, `surfaceRaised` and `surfaceSelected` are genuinely opaque and
//    are drawn as shapes on top: wells, rows, cards, the selected segment.
//

import AppKit
import SwiftUI

public nonisolated enum EchoColor {

    // MARK: Surfaces

    /// The window and the document behind it. A backdrop: see the note above
    /// before painting it over a material.
    public static let windowBackground = Color(light: 0xFFFFFF, dark: 0x0D0E11)

    /// The sidebar, a step darker than the window in dark and a step warmer in
    /// light. A backdrop, like `windowBackground`.
    public static let sidebarBackground = Color(light: 0xF7F8FA, dark: 0x0B0C0E)

    /// A quiet, opaque well: the tab strip's track, inset groups.
    public static let surface = Color(light: 0xF0F1F4, dark: 0x16171A)

    /// A raised, opaque surface: a selected row, inline code, a card.
    public static let surfaceRaised = Color(light: 0xE8EAED, dark: 0x1F2024)

    /// One step above raised: the selected segment of a tab strip. In light it
    /// is white and the design lifts it with a shadow the strip draws.
    public static let surfaceSelected = Color(light: 0xFFFFFF, dark: 0x292B2F)

    // MARK: Hairlines
    //
    // The design draws two, and they are not interchangeable: the quieter one
    // separates areas inside the window, the stronger one draws its outer edge
    // and the border of anything a pointer can type into.

    /// The hairline between areas: under the title bar, down the sidebar's
    /// edge, across the document above the tabs.
    public static let divider = Color(light: 0xECEDF0, dark: 0x1D1E21)

    /// The window's own border, and the border of an input or a bordered
    /// control.
    public static let border = Color(light: 0xE1E3E6, dark: 0x292B2F)

    // MARK: Text
    //
    // Seven steps, from the title down to the storage line in the sidebar's
    // footer. Prose sits one step under primary so a long summary does not
    // glare; a property value sits between the two.

    public static let textPrimary = Color(light: 0x18191C, dark: 0xF2F3F5)
    public static let textProse = Color(light: 0x35383D, dark: 0xD2D4D8)
    public static let textValue = Color(light: 0x2B2D31, dark: 0xE4E5E8)
    public static let textSecondary = Color(light: 0x626569, dark: 0xA7A9AE)
    public static let textTertiary = Color(light: 0x8A8D92, dark: 0x74767B)
    public static let textQuaternary = Color(light: 0xA2A5AA, dark: 0x54575B)
    public static let textFaint = Color(light: 0xB2B5BA, dark: 0x45484C)

    /// The "/" between the parts of a breadcrumb. Fainter than any word on
    /// screen: it separates rather than says anything, so it sits a step past
    /// the last of the text steps rather than among them.
    public static let breadcrumbSlash = Color(light: 0xC4C7CB, dark: 0x3A3D41)

    // MARK: Roles

    /// Cobalt: selection, links, the one primary action. Darker in light mode
    /// so it keeps contrast on white.
    public static let accent = Color(light: 0x1673C0, dark: 0x3B9CF6)

    /// The accent at a whisper, behind a status pill or a find match. The two
    /// appearances draw it at different opacities — light needs less of it to
    /// read on white.
    public static let accentWash = Color(
        light: 0x1673C0, dark: 0x3B9CF6, lightOpacity: 0.13, darkOpacity: 0.15)

    /// The recording red — the only saturated color while a session runs. It
    /// lifts in dark mode: the brand sheet's red is too heavy on near-black.
    public static let recording = Color(light: 0xD02B31, dark: 0xED4A49)

    public static let success = Color(nsColor: .systemGreen)
    public static let warning = Color(nsColor: .systemOrange)
    public static let danger = Color(nsColor: .systemRed)

    /// The fill behind a selected row. Neutral, not the accent: the design
    /// marks a selected row by raising it and weighting its title, and keeps
    /// the accent for what it actually distinguishes.
    public static let selection = surfaceRaised

    /// The shadow the design puts under a selected tab. It exists in light
    /// mode only: on white a raised segment needs the lift, on near-black it
    /// would be a smudge, so the dark side of this token is fully transparent.
    public static let tabSelectionShadow = Color(
        light: 0x17191E, dark: 0x000000, lightOpacity: 0.10, darkOpacity: 0)

    /// The fill behind a hovered row. The design does not draw a hover state;
    /// this is the platform's own whisper until it does.
    public static let hover = Color.primary.opacity(0.05)

    /// The island's own palette.
    ///
    /// The island is black on every appearance — the design has it poured from
    /// the bezel, and a bezel does not go light — so these do not follow the
    /// system. Its fills are white at a percentage rather than a grey, so they
    /// read the same over the shell and over the wallpaper the flares expose.
    public enum Island {

        /// The shell, and the ears either side of the cutout.
        public static let shell = Color.black

        /// The accent, as the island draws it: a gauge's fill and its label,
        /// the spinner, the hairline of progress along the bottom edge.
        ///
        /// Not `EchoColor.accent`. That one darkens in light mode to hold its
        /// contrast on white, and the island has no white to hold it against —
        /// on a light Mac it would put the paper-facing cobalt on black. This
        /// is the value the artboards draw over the shell, in both.
        public static let accent = Color(hex: 0x3B9CF6)

        /// The recording red, as the island draws it: the blinking dot, the
        /// glyph on the record capsule, the countdown ring. Pinned for the
        /// same reason as `accent` — `EchoColor.recording` follows the
        /// appearance because the sidebar's dot sits on a surface that does.
        public static let recording = Color(hex: 0xED4A49)

        /// Behind a primary or secondary capsule. Both share it: only the
        /// weight of the label separates them, so nothing on the island reads
        /// as a white button.
        public static let controlFill = Color.white.opacity(0.10)

        /// Behind a value chip or an icon button, a step quieter than a
        /// capsule.
        public static let chipFill = Color.white.opacity(0.08)

        /// The label of a primary, secondary or chip control.
        public static let controlLabel = Color(hex: 0xE4E5E8)

        /// The label of a quiet control, and the chevron of a value chip.
        public static let quietLabel = Color(hex: 0x83878D)

        /// The glyph inside an icon button.
        public static let glyph = Color(hex: 0x9DA1A7)

        /// A face's first line.
        public static let title = Color(hex: 0xF2F3F5)

        /// A face's second line.
        public static let detail = Color(hex: 0x7E8288)

        /// The unfilled part of a level gauge.
        public static let gaugeTrack = Color.white.opacity(0.13)

        /// The gauge that is not the accent one, fill and label.
        public static let gaugeNeutral = Color(hex: 0x8A8D93)
        public static let gaugeNeutralLabel = Color(hex: 0x6E7176)
    }
}

extension Color {

    /// One hex value, whatever the appearance. For the surfaces the design
    /// draws the same in both — the island, which is always black.
    public nonisolated init(hex: UInt32, opacity: Double = 1) {
        self.init(nsColor: NSColor(hex: hex, alpha: CGFloat(opacity)))
    }

    /// A color that follows the appearance, from two hex values and the opacity
    /// each appearance draws them at.
    public nonisolated init(
        light: UInt32,
        dark: UInt32,
        lightOpacity: Double = 1,
        darkOpacity: Double = 1
    ) {
        self.init(
            nsColor: NSColor(name: nil) { appearance in
                let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                return NSColor(
                    hex: isDark ? dark : light,
                    alpha: CGFloat(isDark ? darkOpacity : lightOpacity)
                )
            })
    }
}

extension NSColor {

    /// `0xRRGGBB` → an sRGB color.
    public nonisolated convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
    }
}
