//
//  PrimitiveTests.swift
//  DesignSystemTests
//
//  The primitives are checked by rendering them, because a primitive is its
//  geometry: a capsule that is 24 points tall is the wrong capsule however
//  right its code reads. `ImageRenderer` runs without a window, so these are
//  ordinary package tests.
//
//  Colors are never read back from a pixel. Between the token, the renderer
//  and the PNG there is a color-managed pipeline that moves the numbers, so a
//  channel read off an image proves nothing about the value that went in —
//  that is what the palette tests are for. Pixels are only ever compared with
//  other pixels from the same run.
//

import AppKit
import DesignSystem
import SwiftUI
import Testing

// MARK: - Rendering

@MainActor
func size(of view: some View) -> CGSize {
    let renderer = ImageRenderer(content: view.fixedSize())
    renderer.scale = 2
    return renderer.nsImage?.size ?? .zero
}

@MainActor
func image(of view: some View) throws -> CGImage {
    let renderer = ImageRenderer(content: view.fixedSize())
    renderer.scale = 2
    return try #require(renderer.cgImage, "the view rendered nothing")
}

/// The raw BGRA bytes of a render, so two renders can be compared with each
/// other. Never with a value from the design.
@MainActor
func pixels(of view: some View) throws -> (bytes: [UInt8], width: Int, height: Int, stride: Int) {
    let cgImage = try image(of: view)
    let width = cgImage.width
    let height = cgImage.height
    let stride = width * 4
    var bytes = [UInt8](repeating: 0, count: stride * height)
    let context = try #require(
        CGContext(
            data: &bytes, width: width, height: height, bitsPerComponent: 8, bytesPerRow: stride,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
    return (bytes, width, height, stride)
}

/// A label long enough that a control's own insets, not its text, decide the
/// difference between two of them.
private let label = "Sample"

@Suite("Primitives")
struct PrimitiveTests {

    // MARK: The island's capsules

    @Test("every capsule is the same height, whatever its role")
    func capsuleHeight() {
        for style in [IslandButtonStyle(.primary), .init(.secondary), .init(.quiet)] {
            let drawn = size(of: Button(label) {}.buttonStyle(style))
            #expect(drawn.height == EchoControl.capsuleHeight)
        }
    }

    @Test("the roles differ by exactly the padding the design gives them")
    func capsuleInsets() {
        let primary = size(of: Button(label) {}.buttonStyle(.islandPrimary)).width
        let secondary = size(of: Button(label) {}.buttonStyle(.islandSecondary)).width
        let quiet = size(of: Button(label) {}.buttonStyle(.islandQuiet)).width

        // Primary and secondary carry the same label at different weights, so
        // their widths are not comparable to the point. Quiet is the same
        // weight as secondary, so that pair is: 12 a side against 6 a side.
        #expect(
            secondary - quiet
                == 2 * (EchoControl.capsuleInsetSecondary - EchoControl.capsuleInsetQuiet))
        #expect(primary > quiet)
    }

    @Test("an icon button is the square the design draws")
    func iconButton() {
        let drawn = size(
            of: Button {
            } label: {
                Image(systemName: "xmark")
            }.buttonStyle(.islandIcon))
        #expect(drawn.width == EchoControl.iconButtonSize)
        #expect(drawn.height == EchoControl.iconButtonSize)
    }

    @Test("a value chip is shorter than a capsule and wider than its word")
    func valueChip() {
        let chip = size(of: ValueChip("A value") {})
        #expect(chip.height == EchoControl.chipHeight)
        #expect(chip.height < EchoControl.capsuleHeight)

        let word = size(of: Text("A value").font(EchoFont.chip))
        let insets =
            EchoControl.chipLeadingInset + EchoControl.chipTrailingInset
            + EchoControl.chipGap + EchoControl.islandGlyphSize
        #expect(chip.width >= word.width + insets - 1)
    }

    // MARK: The level gauge

    @Test("the gauge fills to the fraction it is given, and does not interpolate")
    func gaugeDrawsWhatItIsGiven() throws {
        // The bar is what is left of the row after the label and its gap, so
        // the full render at 1.0 is what a fraction is a fraction of. Every
        // measurement below is one render against another from the same run.
        let full = try filledColumns(atLevel: 1)
        #expect(full > 300, "the bar rendered too small to measure")

        for level in [0.0, 0.25, 0.5, 0.75] {
            let drawn = try filledColumns(atLevel: level)
            let expected = Int((Double(full) * level).rounded())
            #expect(
                abs(drawn - expected) <= 3,
                "level \(level) filled \(drawn) columns of \(full), expected \(expected)")
        }
    }

    /// How many columns of the bar stop looking like the empty bar. A distance
    /// measured between two renders, never a colour read off one.
    @MainActor
    private func filledColumns(atLevel level: Double) throws -> Int {
        func bar(_ level: Double) -> some View {
            LevelGauge("", level: level, tone: .accent)
                .frame(width: 200, height: EchoControl.gaugeHeight)
        }
        let empty = try pixels(of: bar(0))
        let drawn = try pixels(of: bar(level))
        #expect(drawn.width == empty.width && drawn.height == empty.height)

        return (0..<drawn.width).count { x in
            (0..<drawn.height).contains { y in
                let offset = y * drawn.stride + x * 4
                return (0..<3).contains { channel in
                    abs(Int(drawn.bytes[offset + channel]) - Int(empty.bytes[offset + channel])) > 8
                }
            }
        }
    }

    @Test("a level outside 0…1 is clamped, never rescaled")
    func gaugeClamps() throws {
        let bar = { (level: Double) in
            LevelGauge("", level: level, tone: .accent).frame(width: 200, height: EchoControl.gaugeHeight)
        }
        #expect(try image(of: bar(1.4)).dataProvider?.data == image(of: bar(1.0)).dataProvider?.data)
        #expect(try image(of: bar(-0.3)).dataProvider?.data == image(of: bar(0.0)).dataProvider?.data)
    }

    @Test("the two gauges are not the same gauge")
    func gaugeTones() throws {
        let you = try image(of: LevelGauge("Level", level: 0.6, tone: .accent).frame(width: 120))
        let others = try image(of: LevelGauge("Level", level: 0.6, tone: .neutral).frame(width: 120))
        #expect(you.dataProvider?.data != others.dataProvider?.data)
    }

    // MARK: The window

    @Test("a property row is the artboard's height, whatever its label says")
    func propertyRowHeight() {
        let short = size(of: PropertyRow(symbol: "clock", label: "Date", "58 min"))
        let long = size(of: PropertyRow(symbol: "clock", label: "Duration of it", "58 min"))
        #expect(short.height == EchoLayout.propertyRowHeight)
        #expect(long.height == EchoLayout.propertyRowHeight)
        // The label column is fixed, so a longer label does not push the value
        // along: two rows with the same value are the same width.
        #expect(short.width == long.width)
    }

    @Test("a tab strip is its segments plus the well around them")
    func tabStripHeight() {
        var tab = "First"
        let binding = Binding(get: { tab }, set: { tab = $0 })
        let strip = size(of: TabStrip(["First", "Second"], selection: binding) { $0 })
        #expect(strip.height == EchoLayout.toolbarButtonHeight + 2 * EchoControl.tabStripInset)
    }

    @Test("the selected segment is drawn, and moves when the selection does")
    func tabStripSelection() throws {
        func strip(_ selected: String) -> some View {
            var value = selected
            return TabStrip(["First", "Second"], selection: Binding(get: { value }, set: { value = $0 })) { $0 }
        }
        #expect(try image(of: strip("First")).dataProvider?.data != image(of: strip("Second")).dataProvider?.data)
    }

    @Test("the window's buttons take the heights the design draws")
    func windowButtonHeights() {
        #expect(
            size(of: Button("New recording") {}.buttonStyle(.echoPrimary)).height
                == EchoControl.primaryButtonHeight)
        #expect(
            size(of: Button("Copy") {}.buttonStyle(.echoQuiet)).height
                == EchoLayout.toolbarButtonHeight)
    }

    @Test("the island's capsules and the window's buttons are two families")
    func theTwoFamiliesStayApart() {
        // DEC-4 is open: the island takes iOS capsules, the window keeps its
        // own rounded rects. Until that is decided they do not share a radius
        // or a height, and this test is what says so out loud.
        #expect(EchoRadius.capsule != EchoRadius.control)
        #expect(EchoRadius.capsule == EchoControl.capsuleHeight / 2)
        #expect(
            size(of: Button(label) {}.buttonStyle(.islandPrimary)).height
                != size(of: Button(label) {}.buttonStyle(.echoPrimary)).height)
    }

    // MARK: For the eye

    @Test("the gallery renders in both appearances")
    func galleryRenders() throws {
        EchoFont.registerBundledTypefaces()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("design-gallery-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        for (name, scheme) in [("light", ColorScheme.light), ("dark", .dark)] {
            let renderer = ImageRenderer(
                content: DesignGallery()
                    .frame(width: 900)
                    .background(EchoColor.windowBackground)
                    .environment(\.colorScheme, scheme))
            renderer.scale = 2
            let cgImage = try #require(renderer.cgImage, "the gallery rendered nothing in \(name)")
            #expect(cgImage.width == 1800)
            #expect(cgImage.height > 2000, "the gallery is the whole sheet, not a slice of it")

            // A flat field would satisfy every size assertion above, and that
            // is exactly what a scroll view hands a renderer. Count how many
            // distinct values the render holds: an empty background is one.
            let drawn = try pixels(
                of: DesignGallery().frame(width: 900).background(EchoColor.windowBackground)
                    .environment(\.colorScheme, scheme))
            var seen = Set<UInt32>()
            for offset in stride(from: 0, to: drawn.bytes.count - 4, by: 4) {
                seen.insert(
                    UInt32(drawn.bytes[offset]) << 16 | UInt32(drawn.bytes[offset + 1]) << 8
                        | UInt32(drawn.bytes[offset + 2]))
                if seen.count > 64 { break }
            }
            #expect(seen.count > 64, "the \(name) gallery drew \(seen.count) colours — it is blank")

            let bitmap = NSBitmapImageRep(cgImage: cgImage)
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: directory.appendingPathComponent("gallery-\(name).png"))
            Attachment.record(cgImage, named: "gallery-\(name).png")
        }
    }
}
