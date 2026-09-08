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
//  saturated thing on screen.
//
//  On macOS 26 the window, its sidebar and its title bar are materials tinted
//  by the wallpaper. A flat color painted over one reads as a mismatched band,
//  so most surfaces let the material through and only `surfaceRaised` and
//  `windowBackground` are opaque — use them for cards and panels, never as a
//  window backdrop.
//

import AppKit
import SwiftUI

public nonisolated enum EchoColor {

    // MARK: Surfaces

    /// An opaque backdrop, for panels that must not let the material through
    /// (the island, a popover body). Not for the window itself.
    public static let windowBackground = Color(light: 0xFAFBFC, dark: 0x0D0E11)

    /// A quiet surface one step above the backdrop: sidebar footers, inset
    /// groups.
    public static let surface = Color(light: 0xF3F4F6, dark: 0x16171A)

    /// A raised, opaque surface: cards, menus, the document page.
    public static let surfaceRaised = Color(light: 0xFFFFFF, dark: 0x1F2024)

    /// Hairlines and borders.
    public static let separator = Color(light: 0xE1E3E6, dark: 0x292B2F)

    // MARK: Text

    public static let textPrimary = Color(light: 0x18191C, dark: 0xF2F3F5)
    public static let textSecondary = Color(light: 0x626569, dark: 0xA7A9AE)
    public static let textTertiary = Color(light: 0x8E9196, dark: 0x74767B)

    // MARK: Roles

    /// Cobalt: selection, links, the one primary action. Darker in light mode
    /// so it keeps contrast on white.
    public static let accent = Color(light: 0x1673C0, dark: 0x3B9CF6)

    /// The recording red — the only saturated color while a session runs.
    public static let recording = Color(light: 0xD02B31, dark: 0xD02B31)

    public static let success = Color(nsColor: .systemGreen)
    public static let warning = Color(nsColor: .systemOrange)
    public static let danger = Color(nsColor: .systemRed)

    /// The fill behind a selected row: the accent at a whisper.
    public static let selection = accent.opacity(0.14)

    /// The fill behind a hovered row.
    public static let hover = Color.primary.opacity(0.05)
}

extension Color {

    /// A color that follows the appearance, from two hex values.
    public nonisolated init(light: UInt32, dark: UInt32) {
        self.init(
            nsColor: NSColor(name: nil) { appearance in
                let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                return NSColor(hex: isDark ? dark : light)
            })
    }
}

extension NSColor {

    /// `0xRRGGBB` → an sRGB color.
    public nonisolated convenience init(hex: UInt32) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}
