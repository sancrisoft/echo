//
//  TokenTests.swift
//  DesignSystemTests
//
//  The palette is checked the only way that means anything: every token is
//  resolved inside a real appearance and its sRGB channels are compared with
//  the hex the design draws. A token that silently keeps its light value in
//  dark mode passes any test that only reads it once.
//

import AppKit
import DesignSystem
import SwiftUI
import Testing

// MARK: - Resolving a token in one appearance

/// One appearance's worth of a token: the hex the design draws and the opacity
/// it draws it at.
nonisolated struct Appearance: Sendable {
    let name: NSAppearance.Name
    let hex: UInt32
    let opacity: Double
}

/// A token and what the design says it is in each appearance.
nonisolated struct Token: Sendable, CustomTestStringConvertible {
    let name: String
    let color: Color
    let light: UInt32
    let dark: UInt32
    let lightOpacity: Double
    let darkOpacity: Double

    init(
        _ name: String,
        _ color: Color,
        light: UInt32,
        dark: UInt32,
        lightOpacity: Double = 1,
        darkOpacity: Double = 1
    ) {
        self.name = name
        self.color = color
        self.light = light
        self.dark = dark
        self.lightOpacity = lightOpacity
        self.darkOpacity = darkOpacity
    }

    var appearances: [Appearance] {
        [
            Appearance(name: .aqua, hex: light, opacity: lightOpacity),
            Appearance(name: .darkAqua, hex: dark, opacity: darkOpacity),
        ]
    }

    var testDescription: String { name }
}

/// The channels a token resolves to. `NSColor(Color)` reads the dynamic
/// provider, so it has to be asked inside the appearance being tested.
nonisolated struct Channels {
    let red: Double
    let green: Double
    let blue: Double
    let alpha: Double
}

@MainActor
func resolve(_ color: Color, in name: NSAppearance.Name) throws -> Channels {
    let appearance = try #require(NSAppearance(named: name), "no such appearance: \(name.rawValue)")
    var resolved: NSColor?
    appearance.performAsCurrentDrawingAppearance {
        resolved = NSColor(color).usingColorSpace(.sRGB)
    }
    let color = try #require(resolved, "the token did not resolve to an sRGB color")
    return Channels(
        red: color.redComponent,
        green: color.greenComponent,
        blue: color.blueComponent,
        alpha: color.alphaComponent
    )
}

nonisolated func channels(of hex: UInt32, opacity: Double) -> Channels {
    Channels(
        red: Double((hex >> 16) & 0xFF) / 255,
        green: Double((hex >> 8) & 0xFF) / 255,
        blue: Double(hex & 0xFF) / 255,
        alpha: opacity
    )
}

/// sRGB is stored as floats; a round trip through `NSColor` costs less than a
/// step of an 8-bit channel.
nonisolated let tolerance = 0.001

// MARK: - The palette

/// Every token in `EchoColor` that names a value, with the value the design
/// draws for it in each appearance. Anything added to the palette belongs here
/// too — a token nothing pins can drift back to a guess.
nonisolated let palette: [Token] = [
    .init("windowBackground", EchoColor.windowBackground, light: 0xFFFFFF, dark: 0x0D0E11),
    .init("sidebarBackground", EchoColor.sidebarBackground, light: 0xF7F8FA, dark: 0x0B0C0E),
    .init("surface", EchoColor.surface, light: 0xF0F1F4, dark: 0x16171A),
    .init("surfaceRaised", EchoColor.surfaceRaised, light: 0xE8EAED, dark: 0x1F2024),
    .init("surfaceSelected", EchoColor.surfaceSelected, light: 0xFFFFFF, dark: 0x292B2F),
    .init("divider", EchoColor.divider, light: 0xECEDF0, dark: 0x1D1E21),
    .init("border", EchoColor.border, light: 0xE1E3E6, dark: 0x292B2F),
    .init("textPrimary", EchoColor.textPrimary, light: 0x18191C, dark: 0xF2F3F5),
    .init("textProse", EchoColor.textProse, light: 0x35383D, dark: 0xD2D4D8),
    .init("textValue", EchoColor.textValue, light: 0x2B2D31, dark: 0xE4E5E8),
    .init("textSecondary", EchoColor.textSecondary, light: 0x626569, dark: 0xA7A9AE),
    .init("textTertiary", EchoColor.textTertiary, light: 0x8A8D92, dark: 0x74767B),
    .init("textQuaternary", EchoColor.textQuaternary, light: 0xA2A5AA, dark: 0x54575B),
    .init("textFaint", EchoColor.textFaint, light: 0xB2B5BA, dark: 0x45484C),
    .init("accent", EchoColor.accent, light: 0x1673C0, dark: 0x3B9CF6),
    .init(
        "accentWash", EchoColor.accentWash, light: 0x1673C0, dark: 0x3B9CF6,
        lightOpacity: 0.13, darkOpacity: 0.15),
    .init("recording", EchoColor.recording, light: 0xD02B31, dark: 0xED4A49),
    .init("selection", EchoColor.selection, light: 0xE8EAED, dark: 0x1F2024),
]

@Suite("The palette")
struct PaletteTests {

    @Test("every token draws the design's value in both appearances", arguments: palette)
    func tokenMatchesTheDesign(token: Token) throws {
        for appearance in token.appearances {
            let drawn = try resolve(token.color, in: appearance.name)
            let expected = channels(of: appearance.hex, opacity: appearance.opacity)
            let context = "\(token.name) in \(appearance.name.rawValue)"
            #expect(abs(drawn.red - expected.red) < tolerance, "red channel of \(context)")
            #expect(abs(drawn.green - expected.green) < tolerance, "green channel of \(context)")
            #expect(abs(drawn.blue - expected.blue) < tolerance, "blue channel of \(context)")
            #expect(abs(drawn.alpha - expected.alpha) < tolerance, "opacity of \(context)")
        }
    }

    @Test("a token that follows the appearance is not the same color twice")
    func appearancesDiffer() throws {
        for token in palette {
            let light = try resolve(token.color, in: .aqua)
            let dark = try resolve(token.color, in: .darkAqua)
            let identical =
                abs(light.red - dark.red) < tolerance && abs(light.green - dark.green) < tolerance
                && abs(light.blue - dark.blue) < tolerance
            #expect(!identical || token.light == token.dark, "\(token.name) ignores the appearance")
        }
    }

    @Test("the two hairlines are two colors, in both appearances")
    func hairlinesAreDistinct() throws {
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let divider = try resolve(EchoColor.divider, in: appearance)
            let border = try resolve(EchoColor.border, in: appearance)
            #expect(
                abs(divider.red - border.red) > tolerance,
                "divider and border collapsed into one hairline in \(appearance.rawValue)")
        }
    }

    @Test("hex decodes channel by channel")
    func hexDecoding() throws {
        let color = try #require(NSColor(hex: 0x3B9CF6).usingColorSpace(.sRGB))
        #expect(abs(color.redComponent - 0x3B / 255.0) < tolerance)
        #expect(abs(color.greenComponent - 0x9C / 255.0) < tolerance)
        #expect(abs(color.blueComponent - 0xF6 / 255.0) < tolerance)
        #expect(abs(color.alphaComponent - 1) < tolerance)
    }
}

// MARK: - Metrics

@Suite("Layout and radii")
struct MetricTests {

    /// The numbers the workspace artboard draws. They change when the design
    /// changes, never because a view would rather have another value.
    @Test("the fixed dimensions are the artboard's")
    func dimensionsMatchTheArtboard() {
        #expect(EchoLayout.titleBarHeight == 44)
        #expect(EchoLayout.sidebarWidth == 256)
        #expect(EchoLayout.appRowHeight == 34)
        #expect(EchoLayout.sidebarRowHeight == 29)
        #expect(EchoLayout.sidebarRowInset == 9)
        #expect(EchoLayout.sectionLabelHeight == 30)
        #expect(EchoLayout.groupHeaderHeight == 22)
        #expect(EchoLayout.breadcrumbHeight == 40)
        #expect(EchoLayout.breadcrumbInset == 18)
        #expect(EchoLayout.toolbarButtonHeight == 26)
        #expect(EchoLayout.readingWidth == 720)
        #expect(EchoLayout.readingTopInset == 26)
        #expect(EchoLayout.propertyRowHeight == 30)
        #expect(EchoLayout.propertyLabelWidth == 104)
        #expect(EchoLayout.documentFadeHeight == 76)
    }

    @Test("the radii are the artboard's, largest to smallest")
    func radiiMatchTheArtboard() {
        #expect(EchoRadius.window == 11)
        #expect(EchoRadius.well == 8)
        #expect(EchoRadius.control == 7)
        #expect(EchoRadius.row == 6)
        #expect(EchoRadius.pill == 5)
        let ordered = [EchoRadius.window, EchoRadius.well, EchoRadius.control, EchoRadius.row, EchoRadius.pill]
        #expect(ordered == ordered.sorted().reversed())
    }

    @Test("the minimum window fits the sidebar and a reading column")
    func layoutFits() {
        #expect(EchoLayout.sidebarWidth + EchoLayout.readingWidth <= EchoLayout.defaultWindow.width)
        #expect(EchoLayout.sidebarWidth + 400 <= EchoLayout.minimumWindow.width)
        #expect(EchoLayout.defaultWindow.width >= EchoLayout.minimumWindow.width)
    }

    @Test("spacing steps grow monotonically")
    func spacingSteps() {
        let steps = [
            EchoSpacing.xxs, EchoSpacing.xs, EchoSpacing.s, EchoSpacing.m, EchoSpacing.l, EchoSpacing.xl,
            EchoSpacing.xxl,
        ]
        #expect(steps == steps.sorted())
        #expect(Set(steps).count == steps.count)
    }
}

// MARK: - The island

@Suite("The island's palette")
struct IslandPaletteTests {

    /// The island is black on every appearance, so these tokens are checked
    /// once per appearance and expected to be the same both times.
    @Test("the island does not follow the appearance")
    func islandIsAlwaysDark() throws {
        let tokens: [(String, Color)] = [
            ("shell", EchoColor.Island.shell),
            ("controlFill", EchoColor.Island.controlFill),
            ("chipFill", EchoColor.Island.chipFill),
            ("controlLabel", EchoColor.Island.controlLabel),
            ("quietLabel", EchoColor.Island.quietLabel),
            ("glyph", EchoColor.Island.glyph),
            ("title", EchoColor.Island.title),
            ("detail", EchoColor.Island.detail),
            ("gaugeTrack", EchoColor.Island.gaugeTrack),
            ("gaugeNeutral", EchoColor.Island.gaugeNeutral),
            ("gaugeNeutralLabel", EchoColor.Island.gaugeNeutralLabel),
        ]
        for (name, color) in tokens {
            let light = try resolve(color, in: .aqua)
            let dark = try resolve(color, in: .darkAqua)
            #expect(abs(light.red - dark.red) < tolerance, "\(name) changes with the appearance")
            #expect(abs(light.alpha - dark.alpha) < tolerance, "\(name) changes with the appearance")
        }
    }

    @Test("the opaque island tokens draw the design's value")
    func islandValues() throws {
        let tokens: [(String, Color, UInt32)] = [
            ("controlLabel", EchoColor.Island.controlLabel, 0xE4E5E8),
            ("quietLabel", EchoColor.Island.quietLabel, 0x83878D),
            ("glyph", EchoColor.Island.glyph, 0x9DA1A7),
            ("title", EchoColor.Island.title, 0xF2F3F5),
            ("detail", EchoColor.Island.detail, 0x7E8288),
            ("gaugeNeutral", EchoColor.Island.gaugeNeutral, 0x8A8D93),
            ("gaugeNeutralLabel", EchoColor.Island.gaugeNeutralLabel, 0x6E7176),
        ]
        for (name, color, hex) in tokens {
            let drawn = try resolve(color, in: .darkAqua)
            let expected = channels(of: hex, opacity: 1)
            #expect(abs(drawn.red - expected.red) < tolerance, "red channel of \(name)")
            #expect(abs(drawn.green - expected.green) < tolerance, "green channel of \(name)")
            #expect(abs(drawn.blue - expected.blue) < tolerance, "blue channel of \(name)")
        }
    }

    @Test("the island's fills are white at the percentage the design gives them")
    func islandFills() throws {
        let fills: [(String, Color, Double)] = [
            ("controlFill", EchoColor.Island.controlFill, 0.10),
            ("chipFill", EchoColor.Island.chipFill, 0.08),
            ("gaugeTrack", EchoColor.Island.gaugeTrack, 0.13),
        ]
        for (name, color, opacity) in fills {
            let drawn = try resolve(color, in: .darkAqua)
            #expect(abs(drawn.red - 1) < tolerance, "\(name) is not white")
            #expect(abs(drawn.green - 1) < tolerance, "\(name) is not white")
            #expect(abs(drawn.blue - 1) < tolerance, "\(name) is not white")
            #expect(abs(drawn.alpha - opacity) < tolerance, "\(name) is at the wrong percentage")
        }
        // A primary capsule is a step brighter than a chip, and the gauge's
        // track brighter still: the order is the design's, not an accident.
        #expect(
            try resolve(EchoColor.Island.chipFill, in: .darkAqua).alpha
                < resolve(EchoColor.Island.controlFill, in: .darkAqua).alpha)
        #expect(
            try resolve(EchoColor.Island.controlFill, in: .darkAqua).alpha
                < resolve(EchoColor.Island.gaugeTrack, in: .darkAqua).alpha)
    }

    @Test("the tab's shadow exists in light mode only")
    func tabShadowIsLightOnly() throws {
        #expect(try resolve(EchoColor.tabSelectionShadow, in: .aqua).alpha > 0)
        #expect(try resolve(EchoColor.tabSelectionShadow, in: .darkAqua).alpha == 0)
    }
}
