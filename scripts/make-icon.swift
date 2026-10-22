#!/usr/bin/env swift
// Renders the app icon as vectors at every size macOS needs, so each size is
// drawn at its native pixel grid instead of being downscaled from one bitmap.
// Usage: swift scripts/make-icon.swift <output-dir>   (writes AppIcon.iconset/*.png and AppIcon-1024.png)
import AppKit

let outDir = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "Resources")
let iconset = outDir.appendingPathComponent("AppIcon.iconset", isDirectory: true)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

/// Speech bubble: an ellipse plus a tail, kept as separate paths so the
/// overlap is never cancelled out by winding. 1024 grid, top-left origin.
struct Bubble {
    let oval: NSBezierPath
    let tail: NSBezierPath
    var parts: [NSBezierPath] { [oval, tail] }

    func fill(_ color: NSColor) {
        color.setFill()
        parts.forEach { $0.fill() }
    }

    func fill(_ gradient: NSGradient, angle: CGFloat, in context: CGContext) {
        for part in parts {
            context.saveGState()
            part.addClip()
            gradient.draw(in: oval.bounds.union(tail.bounds), angle: angle)
            context.restoreGState()
        }
    }

    func stroke(_ color: NSColor, width: CGFloat) {
        color.setStroke()
        for part in parts {
            part.lineWidth = width
            part.stroke()
        }
    }
}

func bubble(_ rect: NSRect, tailTip: NSPoint, tailBase: (NSPoint, NSPoint)) -> Bubble {
    let tail = NSBezierPath()
    tail.move(to: tailBase.0)
    tail.curve(to: tailTip, controlPoint1: NSPoint(x: tailBase.0.x, y: (tailBase.0.y + tailTip.y) / 2),
               controlPoint2: tailTip)
    tail.curve(to: tailBase.1, controlPoint1: tailTip,
               controlPoint2: NSPoint(x: (tailBase.1.x + tailTip.x) / 2, y: tailBase.1.y))
    tail.close()
    return Bubble(oval: NSBezierPath(ovalIn: rect), tail: tail)
}

func drawGlyph(_ text: String, font: NSFont, color: NSColor, center: NSPoint) {
    let attributed = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
    let line = CTLineCreateWithAttributedString(attributed)
    let bounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
    let origin = NSPoint(x: center.x - bounds.midX, y: center.y + bounds.midY)
    guard let context = NSGraphicsContext.current?.cgContext else { return }
    context.saveGState()
    // The canvas is flipped (top-left origin); text needs a local un-flip.
    context.translateBy(x: origin.x, y: origin.y)
    context.scaleBy(x: 1, y: -1)
    context.textPosition = .zero
    CTLineDraw(line, context)
    context.restoreGState()
}

func roundedFont(size: CGFloat, weight: NSFont.Weight) -> NSFont {
    let base = NSFont.systemFont(ofSize: size, weight: weight)
    guard let descriptor = base.fontDescriptor.withDesign(.rounded) else { return base }
    return NSFont(descriptor: descriptor, size: size) ?? base
}

func render(pixels: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: pixels, height: pixels)
    let small = pixels <= 64
    NSGraphicsContext.saveGraphicsState()
    let graphics = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = graphics
    let context = graphics.cgContext
    context.setShouldAntialias(true)
    context.interpolationQuality = .high
    // 1024-unit grid, top-left origin.
    let scale = CGFloat(pixels) / 1024
    context.translateBy(x: 0, y: CGFloat(pixels))
    context.scaleBy(x: scale, y: -scale)

    // Body: macOS icon grid, 824 pt square with continuous-looking corners.
    let body = NSRect(x: 100, y: 100, width: 824, height: 824)
    let shape = NSBezierPath(roundedRect: body, xRadius: 186, yRadius: 186)
    if !small {
        context.saveGState()
        // Shadow offsets and blur are in device pixels, so scale them with the canvas.
        context.setShadow(offset: CGSize(width: 0, height: -10 * scale), blur: 28 * scale,
                          color: color(0x000000, 0.28).cgColor)
        color(0x2A2486).setFill()
        shape.fill()
        context.restoreGState()
    }
    context.saveGState()
    shape.addClip()
    let gradient = NSGradient(colors: [color(0x231C75), color(0x3A3BD0), color(0x6E4AF2)],
                              atLocations: [0, 0.55, 1], colorSpace: .sRGB)!
    gradient.draw(in: body, angle: 45)   // flipped grid: top-left dark → bottom-right violet
    context.restoreGState()

    // White bubble with 译.
    let white = bubble(NSRect(x: 196, y: 196, width: 452, height: 402),
                       tailTip: NSPoint(x: 236, y: 640), tailBase: (NSPoint(x: 268, y: 520), NSPoint(x: 360, y: 578)))
    white.fill(color(0xFFFFFF))
    drawGlyph("译", font: NSFont(name: "PingFangSC-Semibold", size: small ? 300 : 272)
                ?? .systemFont(ofSize: 272, weight: .heavy),
              color: color(0x161B6E), center: NSPoint(x: 422, y: 392))

    // Orange bubble with A, slightly in front.
    let orange = bubble(NSRect(x: 430, y: 424, width: 412, height: 372),
                        tailTip: NSPoint(x: 806, y: 828), tailBase: (NSPoint(x: 700, y: 774), NSPoint(x: 790, y: 712)))
    if !small {
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: -12 * scale), blur: 24 * scale,
                          color: color(0x10093F, 0.35).cgColor)
        orange.fill(color(0xFF7A55))
        context.restoreGState()
        orange.fill(NSGradient(starting: color(0xFF9070), ending: color(0xFF5E3A))!, angle: 90, in: context)
    } else {
        // Without shadows, a dark ring keeps the two bubbles apart at tiny sizes.
        orange.stroke(color(0x2B2490), width: 22)
        orange.fill(color(0xFF6A45))
    }
    drawGlyph("A", font: roundedFont(size: small ? 300 : 280, weight: .heavy),
              color: .white, center: NSPoint(x: 636, y: 610))

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

func write(_ rep: NSBitmapImageRep, to url: URL) throws {
    guard let png = rep.representation(using: .png, properties: [:]) else {
        throw CocoaError(.fileWriteUnknown)
    }
    try png.write(to: url)
}

for base in [16, 32, 128, 256, 512] {
    try write(render(pixels: base), to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try write(render(pixels: base * 2), to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
try write(render(pixels: 1024), to: outDir.appendingPathComponent("AppIcon-1024.png"))
print("Wrote \(iconset.path)")
