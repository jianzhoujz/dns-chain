import AppKit
import Foundation

let arguments = CommandLine.arguments
guard arguments.count == 2 else {
    fputs("Usage: make_app_icon.swift <output.iconset>\n", stderr)
    exit(2)
}

let outputURL = URL(fileURLWithPath: arguments[1])
let fileManager = FileManager.default

try? fileManager.removeItem(at: outputURL)
try fileManager.createDirectory(at: outputURL, withIntermediateDirectories: true)

let sizes: [(name: String, pixels: Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024)
]

func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(calibratedRed: red, green: green, blue: blue, alpha: alpha)
}

func drawIcon(pixels: Int) -> NSBitmapImageRep {
    let side = CGFloat(pixels)
    let rect = NSRect(x: 0, y: 0, width: side, height: side)
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixels,
        pixelsHigh: pixels,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else {
        fputs("Failed to allocate bitmap for \(pixels)x\(pixels)\n", stderr)
        exit(1)
    }
    bitmap.size = rect.size

    let context = NSGraphicsContext(bitmapImageRep: bitmap)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    defer { NSGraphicsContext.restoreGraphicsState() }
    NSGraphicsContext.current?.imageInterpolation = .high
    NSGraphicsContext.current?.shouldAntialias = true

    NSColor.clear.setFill()
    rect.fill()

    let tileRect = rect.insetBy(dx: side * 0.055, dy: side * 0.055)
    let tile = NSBezierPath(
        roundedRect: tileRect,
        xRadius: side * 0.215,
        yRadius: side * 0.215
    )

    NSGraphicsContext.saveGraphicsState()
    let tileShadow = NSShadow()
    tileShadow.shadowBlurRadius = side * 0.045
    tileShadow.shadowOffset = NSSize(width: 0, height: -side * 0.018)
    tileShadow.shadowColor = NSColor(calibratedWhite: 0, alpha: 0.24)
    tileShadow.set()

    color(0.88, 0.96, 0.87).setFill()
    tile.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.saveGraphicsState()
    tile.addClip()

    let fontSize = side * 0.62
    let font = NSFont(name: "Apple Color Emoji", size: fontSize) ?? NSFont.systemFont(ofSize: fontSize)
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .center
    let attributes: [NSAttributedString.Key: Any] = [
        .font: font,
        .paragraphStyle: paragraph
    ]
    let text = NSAttributedString(string: "🐝", attributes: attributes)
    let textRect = NSRect(
        x: tileRect.minX,
        y: tileRect.midY - fontSize * 0.52,
        width: tileRect.width,
        height: fontSize * 1.25
    )
    text.draw(in: textRect)

    NSGraphicsContext.restoreGraphicsState()

    let highlight = NSBezierPath(
        roundedRect: tileRect.insetBy(dx: side * 0.010, dy: side * 0.010),
        xRadius: side * 0.195,
        yRadius: side * 0.195
    )
    color(1, 1, 1, 0.22).setStroke()
    highlight.lineWidth = max(1, side * 0.010)
    highlight.stroke()

    return bitmap
}

for size in sizes {
    let bitmap = drawIcon(pixels: size.pixels)
    guard let png = bitmap.representation(using: .png, properties: [:]) else {
        fputs("Failed to render \(size.name)\n", stderr)
        exit(1)
    }

    try png.write(to: outputURL.appendingPathComponent(size.name))
}
