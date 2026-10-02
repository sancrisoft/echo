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
    public static func drawnSize(for size: CGFloat) -> CGFloat {
        max(size, EchoMarkGeometry.minimumSize)
    }

    /// The padding the view adds outside the grid: what is left of the clear
    /// space once the grid's own margin around the mark is counted.
    public static func clearSpaceInset(for size: CGFloat) -> CGSize {
        let unit = drawnSize(for: size) / EchoMarkGeometry.grid
        let bounds = EchoMarkGeometry.bounds
        return CGSize(
            width: max(0, EchoMarkGeometry.clearSpace - bounds.minX) * unit,
            height: max(0, EchoMarkGeometry.clearSpace - bounds.minY) * unit
        )
    }

    /// The space the view takes for a requested size, clear space included.
    public static func frameSize(for size: CGFloat) -> CGSize {
        let edge = drawnSize(for: size)
        let inset = clearSpaceInset(for: size)
        return CGSize(width: edge + 2 * inset.width, height: edge + 2 * inset.height)
    }
}
