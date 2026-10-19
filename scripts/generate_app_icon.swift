// Renders Echo's app icon — the mark on the brand sheet's dark tile, on the
// standard macOS icon grid — into every slot AppIcon.appiconset has.
//
//   make app-icon
//
// The mark's outline is not in this file. `make app-icon` compiles it together
// with Packages/DesignSystem/Sources/DesignSystem/EchoMarkGeometry.swift, the
// one file every surface draws the mark from, so the icon cannot drift from
// the menu bar or the window. To revisit the brand, change that file and run
// this again; nothing here is a picture of the mark.
//
// One appearance: the dark tile. The brand sheet also draws a light one, and
// macOS shows a single bundle icon; the dark tile is the app's own surface.

import AppKit

@main
struct GenerateAppIcon {

    /// (file name, pixels) — one file per slot of the icon set.
    static let slots: [(String, Int)] = [
        ("icon_16x16.png", 16),
        ("icon_16x16@2x.png", 32),
        ("icon_32x32.png", 32),
        ("icon_32x32@2x.png", 64),
        ("icon_128x128.png", 128),
        ("icon_128x128@2x.png", 256),
        ("icon_256x256.png", 256),
        ("icon_256x256@2x.png", 512),
        ("icon_512x512.png", 512),
        ("icon_512x512@2x.png", 1024),
    ]

    // The tile, as the brand sheet draws it. The colours are DesignSystem's
    // dark `surface`, `border` and `textPrimary`; this file cannot import that
    // package, so they are restated here and named after the tokens they are.
    static let surface = NSColor(srgbRed: 0x16 / 255, green: 0x17 / 255, blue: 0x1A / 255, alpha: 1)
    static let border = NSColor(srgbRed: 0x29 / 255, green: 0x2B / 255, blue: 0x2F / 255, alpha: 1)
    static let textPrimary = NSColor(srgbRed: 0xF2 / 255, green: 0xF3 / 255, blue: 0xF5 / 255, alpha: 1)

    /// The sheet draws the tile 88 wide with a 1-wide border and the mark's
    /// grid 46 wide inside it. Kept as that ratio so the icon is the sheet's
    /// drawing at any size.
    static let sheetTile: CGFloat = 88
    static let sheetBorder: CGFloat = 1
    static let sheetMark: CGFloat = 46

    /// The macOS icon grid: an 824-wide body centred on a 1024 canvas, with
    /// the platform's corner, and transparent margins around it.
    static let canvas: CGFloat = 1024
    static let body: CGFloat = 824
    static let corner: CGFloat = 185.4

    static func main() throws {
        guard CommandLine.arguments.count == 2 else {
            FileHandle.standardError.write(Data("usage: generate_app_icon <AppIcon.appiconset>\n".utf8))
            exit(2)
        }
        let outDir = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        for (file, pixels) in slots {
            let png = try render(pixels)
            try png.write(to: outDir.appendingPathComponent(file), options: .atomic)
            print("wrote \(file) (\(pixels) px)")
        }
    }

    static func render(_ pixels: Int) throws -> Data {
        guard
            let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
            ),
            let context = NSGraphicsContext(bitmapImageRep: rep)
        else { throw RenderError.noContext(pixels) }
        // 72 dpi, so one point is one pixel.
        rep.size = NSSize(width: pixels, height: pixels)

        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = context
        let cg = context.cgContext

        let scale = CGFloat(pixels) / canvas
        let side = body * scale
        let tile = CGRect(
            x: (CGFloat(pixels) - side) / 2, y: (CGFloat(pixels) - side) / 2, width: side, height: side)
        let tilePath = CGPath(
            roundedRect: tile, cornerWidth: corner * scale, cornerHeight: corner * scale, transform: nil)

        cg.addPath(tilePath)
        cg.setFillColor(surface.cgColor)
        cg.fillPath()

        // The border sits inside the tile's edge, as a CSS border does.
        let borderWidth = side * sheetBorder / sheetTile
        cg.saveGState()
        cg.addPath(tilePath)
        cg.clip()
        cg.addPath(tilePath)
        cg.setStrokeColor(border.cgColor)
        cg.setLineWidth(borderWidth * 2)
        cg.strokePath()
        cg.restoreGState()

        // The mark's grid, centred on the tile. One pixel is the narrowest the
        // seam may be: at 16 px the sheet's seam is a fraction of one, and a
        // seam the rasterizer fills in is a plain disc.
        let markSide = side * sheetMark / sheetTile
        let grid = CGRect(x: tile.midX - markSide / 2, y: tile.midY - markSide / 2, width: markSide, height: markSide)
        cg.addPath(EchoMarkGeometry.path(.near, in: grid, minimumSeam: 1))
        cg.setFillColor(textPrimary.cgColor)
        cg.fillPath()
        cg.addPath(EchoMarkGeometry.path(.far, in: grid, minimumSeam: 1))
        cg.setFillColor(textPrimary.withAlphaComponent(EchoMarkGeometry.farOpacity).cgColor)
        cg.fillPath()

        context.flushGraphics()
        guard let png = rep.representation(using: .png, properties: [:]) else {
            throw RenderError.noPNG(pixels)
        }
        return png
    }

    enum RenderError: Error {
        case noContext(Int)
        case noPNG(Int)
    }
}
