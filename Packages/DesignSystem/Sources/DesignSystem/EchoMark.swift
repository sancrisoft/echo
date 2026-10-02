//
//  EchoMark.swift
//  DesignSystem
//
//  The mark as a view: one ink, the far half at a fraction of it, and the two
//  rules the brand sheet states — a clear space of the seam × 4 and a minimum
//  of 16 points — built into the view, so a caller cannot crowd it or shrink
//  it by accident. Drawn from `EchoMarkGeometry`, never from an image, so it is
//  the same mark at 16 points and at 1024.
//

import AppKit
import SwiftUI

/// One half of the mark, as a shape. `EchoMark` is what a surface draws; this
/// is for the rare host that needs the halves apart.
///
/// `nonisolated` because `Shape` asks for its path off the main actor, and this
/// package's main-actor default would otherwise make the conformance an error.
public nonisolated struct EchoMarkHalf: Shape {

    public let half: EchoMarkGeometry.Half

    /// The narrowest the seam may be, in points: one device pixel.
    public let minimumSeam: CGFloat

    public init(_ half: EchoMarkGeometry.Half, minimumSeam: CGFloat = 0) {
        self.half = half
        self.minimumSeam = minimumSeam
    }

    public func path(in rect: CGRect) -> Path {
        Path(EchoMarkGeometry.path(half, in: rect, minimumSeam: minimumSeam))
    }
}

/// The mark, with its clear space and its minimum size.
///
/// `size` is the edge of the 16 × 16 grid, the box every artboard sizes the
/// mark by. The view is a little larger than that box: the grid holds part of
/// the clear space around the mark already, and the view pads by the rest, so
/// whatever is placed beside it is never closer than the brand allows.
public struct EchoMark: View {

    @Environment(\.displayScale) private var displayScale

    private let size: CGFloat
    private let ink: Color

    /// - Parameters:
    ///   - size: the grid's edge, in points. Never less than
    ///     `EchoMarkGeometry.minimumSize`; a smaller value is drawn at it.
    ///   - ink: the one colour. The far half takes
    ///     `EchoMarkGeometry.farOpacity` of it.
    public init(size: CGFloat = EchoMarkGeometry.minimumSize, ink: Color) {
        self.size = Self.drawnSize(for: size)
        self.ink = ink
    }

    public var body: some View {
        let inset = Self.clearSpaceInset(for: size)
        ZStack {
            EchoMarkHalf(.near, minimumSeam: 1 / displayScale)
                .fill(ink)
            EchoMarkHalf(.far, minimumSeam: 1 / displayScale)
                .fill(ink.opacity(EchoMarkGeometry.farOpacity))
        }
        .frame(width: size, height: size)
        .padding(.horizontal, inset.width)
        .padding(.vertical, inset.height)
        // It stands beside the word "Echo" wherever it appears; a reader would
        // hear the name twice.
        .accessibilityHidden(true)
    }

    // MARK: Layout

    /// The grid edge a requested size is drawn at.
    public nonisolated static func drawnSize(for size: CGFloat) -> CGFloat {
        max(size, EchoMarkGeometry.minimumSize)
    }

    /// The padding the view adds outside the grid: what is left of the clear
    /// space once the grid's own margin around the mark is counted.
    public nonisolated static func clearSpaceInset(for size: CGFloat) -> CGSize {
        let unit = drawnSize(for: size) / EchoMarkGeometry.grid
        let bounds = EchoMarkGeometry.bounds
        return CGSize(
            width: max(0, EchoMarkGeometry.clearSpace - bounds.minX) * unit,
            height: max(0, EchoMarkGeometry.clearSpace - bounds.minY) * unit
        )
    }

    /// The space the view takes for a requested size, clear space included.
    public nonisolated static func frameSize(for size: CGFloat) -> CGSize {
        let edge = drawnSize(for: size)
        let inset = clearSpaceInset(for: size)
        return CGSize(width: edge + 2 * inset.width, height: edge + 2 * inset.height)
    }
}

/// The mark as an image, for the AppKit hosts that take one rather than a
/// view: the menu bar item.
public nonisolated enum EchoMarkImage {

    /// The grid alone, without the view's clear space: a host that takes an
    /// image puts its own room around it — the menu bar does.
    ///
    /// - Parameters:
    ///   - size: the grid's edge, in points, never under the mark's minimum.
    ///   - ink: the one colour. A dynamic colour resolves against the
    ///     appearance it is drawn in, so one image serves a light and a dark
    ///     menu bar.
    ///   - isTemplate: whether macOS chooses the ink instead. A template
    ///     image keeps only the coverage — the far half's fraction included —
    ///     and the bar draws it in its own colour, inverting with it.
    public static func make(
        size: CGFloat = EchoMarkGeometry.minimumSize,
        ink: NSColor = .black,
        isTemplate: Bool = false
    ) -> NSImage {
        let edge = EchoMark.drawnSize(for: size)
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            draw(in: rect, context: context, ink: ink)
            return true
        }
        image.isTemplate = isTemplate
        image.accessibilityDescription = "Echo"
        return image
    }

    /// Draws the two halves into `rect`, with the seam held to one device
    /// pixel at whatever scale the context is.
    public static func draw(in rect: CGRect, context: CGContext, ink: NSColor) {
        let scale = max(1, abs(context.userSpaceToDeviceSpaceTransform.a))
        context.addPath(EchoMarkGeometry.path(.near, in: rect, minimumSeam: 1 / scale))
        context.setFillColor(ink.cgColor)
        context.fillPath()
        context.addPath(EchoMarkGeometry.path(.far, in: rect, minimumSeam: 1 / scale))
        context.setFillColor(ink.withAlphaComponent(EchoMarkGeometry.farOpacity).cgColor)
        context.fillPath()
    }
}
