//
//  FontTests.swift
//  DesignSystemTests
//
//  A `Font` is opaque, so asking it what size and weight it is proves nothing.
//  These tests render each token and compare the result with an independently
//  built reference — Onest positioned on its weight axis by hand — and then
//  render the same size at another weight to show the comparison can tell them
//  apart. A token that quietly fell back to the system face fails the first
//  check; a token that ignored its weight fails the second.
//

import AppKit
import CoreText
import DesignSystem
import SwiftUI
import Testing

@testable import DesignSystem

// MARK: - Rendering

/// Long enough that a weight's difference in advance accumulates past the
/// point where the renderer rounds it away, and mixed so both the letters and
/// the digits count.
private let sample = "Handgloves and the meeting at 10:04 — 5,512 words · 00:12:41"

@MainActor
func renderedSize(_ font: Font, text: String = sample) -> CGSize {
    let renderer = ImageRenderer(content: Text(text).font(font).fixedSize())
    renderer.scale = 2
    return renderer.nsImage?.size ?? .zero
}

/// Onest at an exact axis position, built without going through `EchoFont`, so
/// a mistake in the token cannot be mirrored by the reference.
@MainActor
func onestReference(_ size: CGFloat, weight: Double) throws -> Font {
    let descriptor = NSFontDescriptor(fontAttributes: [
        .family: "Onest",
        NSFontDescriptor.AttributeName.variation: [0x7767_6874: weight],
    ])
    return Font(try #require(NSFont(descriptor: descriptor, size: size)))
}

// MARK: - The scale

/// One row of the design's type table: the token, and the size and weight the
/// design sets it at.
nonisolated struct ScaleEntry: Sendable, CustomTestStringConvertible {
    let name: String
    let font: @Sendable () -> Font
    let size: CGFloat
    let weight: Double

    var testDescription: String { "\(name) \(size)/\(Int(weight))" }
}

nonisolated let scale: [ScaleEntry] = [
    .init(name: "documentTitle", font: { EchoFont.documentTitle }, size: 30, weight: 650),
    .init(name: "sectionTitle", font: { EchoFont.sectionTitle }, size: 17, weight: 650),
    .init(name: "body", font: { EchoFont.body }, size: 14.5, weight: 400),
    .init(name: "bodyBold", font: { EchoFont.bodyBold }, size: 14.5, weight: 600),
    .init(name: "propertyValue", font: { EchoFont.propertyValue }, size: 13.5, weight: 400),
    .init(name: "propertyLabel", font: { EchoFont.propertyLabel }, size: 12.5, weight: 400),
    .init(name: "row", font: { EchoFont.row }, size: 13, weight: 400),
    .init(name: "rowSelected", font: { EchoFont.rowSelected }, size: 13, weight: 500),
    .init(name: "appName", font: { EchoFont.appName }, size: 13.5, weight: 600),
    .init(name: "sectionLabel", font: { EchoFont.sectionLabel }, size: 11.5, weight: 600),
    .init(name: "groupHeader", font: { EchoFont.groupHeader }, size: 11, weight: 400),
    .init(name: "control", font: { EchoFont.control }, size: 12.5, weight: 400),
    .init(name: "controlSelected", font: { EchoFont.controlSelected }, size: 12.5, weight: 500),
    .init(name: "statusPill", font: { EchoFont.statusPill }, size: 12, weight: 500),
    .init(name: "micro", font: { EchoFont.micro }, size: 11.5, weight: 400),
]

@Suite("Typography")
struct FontTests {

    @Test("both typefaces register, and registering again is not a failure")
    func registration() {
        let first = EchoFont.registerBundledTypefaces()
        #expect(first.isComplete, "\(first.failures)")
        #expect(first.registered.count == 4)

        let second = EchoFont.registerBundledTypefaces()
        #expect(second.isComplete)
        #expect(second.registered == first.registered)
    }

    @Test("the design's two families are the ones the process resolves")
    func familiesResolve() throws {
        EchoFont.registerBundledTypefaces()
        let onest = try #require(NSFont(name: "Onest-Regular", size: 13))
        #expect(onest.familyName == EchoFont.interfaceFamily)
        for weight in ["DMMono-Light", "DMMono-Regular", "DMMono-Medium"] {
            let mono = try #require(NSFont(name: weight, size: 13), "\(weight) is not registered")
            #expect(CTFontGetSymbolicTraits(mono as CTFont).contains(.traitMonoSpace))
        }
    }

    @Test("every token is Onest at the design's size and weight", arguments: scale)
    func tokenMatchesTheScale(entry: ScaleEntry) throws {
        EchoFont.registerBundledTypefaces()
        let drawn = renderedSize(entry.font())

        let reference = try renderedSize(onestReference(entry.size, weight: entry.weight))
        #expect(drawn == reference, "\(entry.name) is not Onest \(entry.size)/\(Int(entry.weight))")

        // The comparison has to be able to fail: the same size at a weight the
        // design did not ask for must render differently, and so must the same
        // weight two points larger.
        let otherWeight = entry.weight < 500 ? entry.weight + 300 : entry.weight - 300
        #expect(
            try drawn != renderedSize(onestReference(entry.size, weight: otherWeight)),
            "\(entry.name) renders the same at \(Int(otherWeight)) — the weight is being ignored")
        #expect(
            try drawn != renderedSize(onestReference(entry.size + 2, weight: entry.weight)),
            "\(entry.name) renders the same two points larger — the size is being ignored")
    }

    @Test("Onest is not the system face")
    func onestIsNotTheSystemFace() {
        EchoFont.registerBundledTypefaces()
        #expect(renderedSize(EchoFont.body) != renderedSize(.system(size: 14.5)))
        #expect(renderedSize(EchoFont.documentTitle) != renderedSize(.system(size: 30, weight: .semibold)))
    }

    // MARK: Numbers

    @Test("mono is DM Mono at the weight asked for")
    func monoMatchesTheFamily() throws {
        EchoFont.registerBundledTypefaces()
        let cases: [(Font.Weight, String)] = [
            (.light, "DMMono-Light"), (.regular, "DMMono-Regular"), (.medium, "DMMono-Medium"),
        ]
        for (weight, postScriptName) in cases {
            let reference = Font(try #require(NSFont(name: postScriptName, size: 11)))
            #expect(
                renderedSize(EchoFont.mono(11, weight: weight)) == renderedSize(reference),
                "mono(11, .\(weight)) is not \(postScriptName)")
        }
    }

    @Test("every digit takes the same width, so a timer does not dance")
    func digitsAreTabular() {
        EchoFont.registerBundledTypefaces()
        let widths = (0...9).map { digit in
            renderedSize(EchoFont.mono(19, weight: .medium), text: String(repeating: "\(digit)", count: 8)).width
        }
        #expect(Set(widths).count == 1, "digit widths: \(widths)")

        // And the check discriminates: the interface face is proportional, so
        // its digits are not all the same width.
        let proportional = (0...9).map { digit in
            renderedSize(EchoFont.body, text: String(repeating: "\(digit)", count: 8)).width
        }
        #expect(Set(proportional).count > 1)
    }

    // MARK: Leading, tracking and the fallback

    @Test("leading and tracking are the design's, in points")
    func leadingAndTracking() {
        #expect(abs(EchoFont.bodyLineSpacing - (14.5 * 1.62 - 14.5 - 3)) < 0.001)
        #expect(abs(EchoFont.transcriptLineSpacing - (14.5 * 1.70 - 14.5 - 3)) < 0.001)
        #expect(EchoFont.transcriptLineSpacing > EchoFont.bodyLineSpacing)
        #expect(abs(EchoFont.documentTitleTracking - (30 * -0.028)) < 0.001)
        #expect(abs(EchoFont.sectionTitleTracking - (17 * -0.014)) < 0.001)
        #expect(abs(EchoFont.appNameTracking - (13.5 * -0.008)) < 0.001)
        #expect(abs(EchoFont.sectionLabelTracking - (11.5 * 0.01)) < 0.001)
        #expect(EchoFont.sectionLabelTracking > 0, "the section label is the one that opens up")
    }

    @Test("without Onest the scale falls back to the weights SF Pro ships")
    func fallbackWeights() {
        // The design's 650 has no equivalent in the system face; semibold is
        // the nearest it ships, and that is the one the fallback picks.
        #expect(EchoFont.systemWeight(nearest: 650) == .semibold)
        #expect(EchoFont.systemWeight(nearest: 400) == .regular)
        #expect(EchoFont.systemWeight(nearest: 500) == .medium)
        #expect(EchoFont.systemWeight(nearest: 600) == .semibold)
        #expect(EchoFont.systemWeight(nearest: 300) == .light)
    }

    @Test("a weight the family ships is reached by name, so a view can re-weight it")
    func namedWeights() {
        #expect(EchoFont.namedWeight(400) == .regular)
        #expect(EchoFont.namedWeight(500) == .medium)
        #expect(EchoFont.namedWeight(600) == .semibold)
        #expect(EchoFont.namedWeight(650) == nil, "650 sits between two instances")
    }
}
