//
//  MarkTests.swift
//  DesignSystemTests
//
//  The mark is its geometry, so most of this is arithmetic on the outline; the
//  rest renders it and compares pixels with pixels from the same run, as the
//  primitives' tests do. No channel is ever held up against a value from the
//  design: alpha is, because nothing between the view and the bitmap manages
//  it.
//

import AppKit
import DesignSystem
import SwiftUI
import Testing

private let markTolerance: CGFloat = 0.0001

private func approximately(_ a: CGFloat, _ b: CGFloat, within limit: CGFloat = markTolerance) -> Bool {
    abs(a - b) <= limit
}

private func box(_ half: EchoMarkGeometry.Half, edge: CGFloat, minimumSeam: CGFloat = 0) -> CGRect {
    EchoMarkGeometry.path(half, in: CGRect(x: 0, y: 0, width: edge, height: edge), minimumSeam: minimumSeam)
        .boundingBoxOfPath
}

@Suite("The mark")
struct MarkTests {

    // MARK: Geometry

    @Test("the numbers are the brand sheet's")
    func brandNumbers() {
        #expect(EchoMarkGeometry.grid == 16)
        #expect(EchoMarkGeometry.radius == 6)
        #expect(EchoMarkGeometry.seam == 0.70)
        #expect(EchoMarkGeometry.farOpacity == 0.42)
        #expect(approximately(EchoMarkGeometry.clearSpace, 2.8))
        #expect(EchoMarkGeometry.minimumSize == 16)
    }

    @Test("the mark is centred on its grid, and narrower than it")
    func boundsOnTheGrid() {
        let bounds = EchoMarkGeometry.bounds
        #expect(approximately(bounds.minX, 1.65))
        #expect(approximately(bounds.minY, 2))
        #expect(approximately(bounds.width, 12.7))
        #expect(approximately(bounds.height, 12))
        #expect(approximately(bounds.midX, EchoMarkGeometry.grid / 2))
        #expect(approximately(bounds.midY, EchoMarkGeometry.grid / 2))
    }

    @Test("each half is a half-disc, and the seam between them is the sheet's")
    func halvesAndSeam() {
        let near = box(.near, edge: 16)
        let far = box(.far, edge: 16)
        for half in [near, far] {
            #expect(approximately(half.width, 6))
            #expect(approximately(half.height, 12))
        }
        #expect(approximately(near.minX, 1.65))
        #expect(approximately(far.minX - near.maxX, 0.70))
        // Mirror images across the seam.
        #expect(approximately(near.minX + far.maxX, 16))
    }

    /// Symmetric top to bottom, which is what makes one outline serve a
    /// flipped SwiftUI rect and an unflipped bitmap context alike.
    @Test("the outline does not care which way the y axis runs")
    func verticalSymmetry() {
        for half in EchoMarkGeometry.Half.allCases {
            let drawn = box(half, edge: 16)
            #expect(approximately(drawn.minY + drawn.maxY, 16))
        }
    }

    @Test("it scales with the grid", arguments: [32, 128, 1024] as [CGFloat])
    func scales(edge: CGFloat) {
        let unit = edge / 16
        let near = box(.near, edge: edge)
        let far = box(.far, edge: edge)
        #expect(approximately(near.minX, 1.65 * unit, within: 0.001))
        #expect(approximately(near.height, 12 * unit, within: 0.001))
        #expect(approximately(far.minX - near.maxX, 0.70 * unit, within: 0.001))
    }

    @Test("a seam thinner than a device pixel is widened, never left to close")
    func seamFloor() {
        // 0.7 of a unit at 16 points is 0.7 of a point: under one pixel on a
        // 1× display.
        let widened = box(.far, edge: 16, minimumSeam: 1).minX - box(.near, edge: 16, minimumSeam: 1).maxX
        #expect(approximately(widened, 1))
        // A floor below the design's own seam changes nothing.
        let kept = box(.far, edge: 16, minimumSeam: 0.5).minX - box(.near, edge: 16, minimumSeam: 0.5).maxX
        #expect(approximately(kept, 0.70))
    }

    // MARK: Size and clear space

    @Test("the grid is never drawn under 16 points", arguments: [1, 8, 15.9] as [CGFloat])
    func minimumSize(requested: CGFloat) {
        #expect(EchoMark.drawnSize(for: requested) == 16)
        #expect(EchoMark.frameSize(for: requested) == EchoMark.frameSize(for: 16))
    }

    @Test("nothing beside it comes closer than the seam × 4", arguments: [16, 32, 128] as [CGFloat])
    func clearSpace(size: CGFloat) {
        let unit = size / 16
        let inset = EchoMark.clearSpaceInset(for: size)
        let bounds = EchoMarkGeometry.bounds
        // From the view's edge to the mark's edge, both ways.
        #expect(approximately(inset.width + bounds.minX * unit, 2.8 * unit, within: 0.001))
        #expect(approximately(inset.height + bounds.minY * unit, 2.8 * unit, within: 0.001))
    }

    @Test("the view takes the grid plus the rest of its clear space")
    func renderedFrame() {
        let drawn = size(of: EchoMark(size: 16, ink: .black))
        let expected = EchoMark.frameSize(for: 16)
        #expect(approximately(drawn.width, expected.width, within: 0.5))
        #expect(approximately(drawn.height, expected.height, within: 0.5))
        #expect(approximately(expected.width, 16 + 2 * 1.15, within: 0.001))
        #expect(approximately(expected.height, 16 + 2 * 0.8, within: 0.001))
    }

    // MARK: One ink

    /// The issue's own bar: correct at 16, 32, 128 and 1024 points, in one ink.
    /// "One ink" is two claims that pixels can settle without a palette: the
    /// two halves are the same colour, and the far one carries the sheet's
    /// fraction of the near one's coverage.
    @Test("one ink at every size the issue names", arguments: [16, 32, 128, 1024] as [CGFloat])
    func oneInk(size: CGFloat) throws {
        let render = try pixels(of: EchoMark(size: size, ink: Color(red: 0.2, green: 0.5, blue: 0.9)))
        let scale = CGFloat(render.width) / EchoMark.frameSize(for: size).width
        let inset = EchoMark.clearSpaceInset(for: size)
        let unit = EchoMark.drawnSize(for: size) / 16

        func sample(x units: CGFloat, y yUnits: CGFloat) -> (r: Double, g: Double, b: Double, a: Double) {
            let x = Int(((inset.width + units * unit) * scale).rounded(.down))
            let y = Int(((inset.height + yUnits * unit) * scale).rounded(.down))
            let i = y * render.stride + x * 4
            let a = Double(render.bytes[i + 3]) / 255
            guard a > 0 else { return (0, 0, 0, 0) }
            return (
                Double(render.bytes[i]) / 255 / a,
                Double(render.bytes[i + 1]) / 255 / a,
                Double(render.bytes[i + 2]) / 255 / a,
                a
            )
        }

        // Deep inside each half, well clear of an antialiased edge.
        let near = sample(x: 4.65, y: 8)
        let far = sample(x: 11.35, y: 8)
        #expect(near.a > 0.99)
        #expect(abs(far.a / near.a - 0.42) < 0.02)
        #expect(abs(near.r - far.r) < 0.02)
        #expect(abs(near.g - far.g) < 0.02)
        #expect(abs(near.b - far.b) < 0.02)

        // The clear space is empty.
        #expect(render.bytes[3] == 0)

        // The seam is open wherever it is wide enough to hold a whole pixel.
        if 0.70 * unit * scale >= 2 {
            #expect(sample(x: 8, y: 8).a == 0)
        }
    }

    // MARK: As an image

    @Test("the image is the grid alone, at the mark's minimum or more")
    func imageSize() {
        #expect(EchoMarkImage.make(size: 16).size == NSSize(width: 16, height: 16))
        #expect(EchoMarkImage.make(size: 8).size == NSSize(width: 16, height: 16))
        #expect(EchoMarkImage.make(size: 22).size == NSSize(width: 22, height: 22))
    }

    @Test("a template keeps only the coverage, and the bar chooses the ink")
    func template() {
        #expect(EchoMarkImage.make(isTemplate: true).isTemplate)
        #expect(!EchoMarkImage.make(ink: .red).isTemplate)
    }

    @Test("the image carries the same fraction on its far half as the view")
    func imageInk() throws {
        let image = EchoMarkImage.make(size: 32, ink: .black)
        let rect = CGRect(x: 0, y: 0, width: 64, height: 64)
        let rep = try #require(
            NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 64, bitsPerSample: 8,
                samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                bytesPerRow: 0, bitsPerPixel: 0))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: rect)
        NSGraphicsContext.restoreGraphicsState()

        // Grid units to pixels: 64 px for 16 units.
        func alpha(x: CGFloat, y: CGFloat) -> CGFloat {
            rep.colorAt(x: Int(x * 4), y: Int(y * 4))?.alphaComponent ?? 0
        }
        let near = alpha(x: 4.65, y: 8)
        let far = alpha(x: 11.35, y: 8)
        #expect(near > 0.99)
        #expect(abs(far / near - 0.42) < 0.02)
        #expect(alpha(x: 8, y: 8) == 0)
        #expect(alpha(x: 0.5, y: 0.5) == 0)
    }
}
