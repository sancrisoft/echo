// Renders Echo's app icon — the in-app glyph (indigo gradient rounded rect
// with a white bold SF "waveform") on the standard macOS icon grid — at every
// size the AppIcon.appiconset needs. Usage:
//   swift generate_app_icon.swift /path/to/AppIcon.appiconset

import AppKit

let outDir = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)

// (filename, pixels) — one file per appiconset slot.
let slots: [(String, Int)] = [
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

func render(_ px: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    rep.size = NSSize(width: px, height: px)   // 72 dpi → 1 point == 1 pixel

    NSGraphicsContext.saveGraphicsState()
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = ctx
    ctx.imageInterpolation = .high

    let size = CGFloat(px)
    let s = size / 1024

    // macOS icon grid: 824×824 body centered on a 1024 canvas, transparent
    // margins. Same proportions at every size.
    let inset = 100 * s
    let body = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let path = NSBezierPath(roundedRect: body, xRadius: 185 * s, yRadius: 185 * s)

    // The glyph's gradient: top-leading (0.43, 0.41, 0.99) → bottom-trailing
    // echoIndigo (0.36, 0.37, 0.96).
    let gradient = NSGradient(
        starting: NSColor(srgbRed: 0.43, green: 0.41, blue: 0.99, alpha: 1),
        ending: NSColor(srgbRed: 0.36, green: 0.37, blue: 0.96, alpha: 1)
    )!
    gradient.draw(in: path, angle: -45)

    // White bold waveform, half the body size — the glyph's proportions.
    let config = NSImage.SymbolConfiguration(pointSize: 412 * s, weight: .bold)
    if let symbol = NSImage(systemSymbolName: "waveform", accessibilityDescription: nil)?
        .withSymbolConfiguration(config) {
        let symbolSize = symbol.size
        let tinted = NSImage(size: symbolSize, flipped: false) { rect in
            NSColor.white.set()
            rect.fill()
            symbol.draw(in: rect, from: .zero, operation: .destinationIn, fraction: 1)
            return true
        }
        let origin = NSPoint(x: (size - symbolSize.width) / 2, y: (size - symbolSize.height) / 2)
        tinted.draw(in: NSRect(origin: origin, size: symbolSize))
    } else {
        fatalError("SF Symbol 'waveform' unavailable")
    }

    ctx.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

for (filename, px) in slots {
    let rep = render(px)
    guard let data = rep.representation(using: .png, properties: [:]) else {
        fatalError("PNG encode failed for \(filename)")
    }
    try! data.write(to: outDir.appendingPathComponent(filename))
    print("wrote \(filename) (\(px)px)")
}
