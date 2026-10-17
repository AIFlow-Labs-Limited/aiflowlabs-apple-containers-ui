// Renders the Container Desktop app icon (1024×1024 PNG) with CoreGraphics.
//
// Usage: swift scripts/make-icon.swift out.png
//
// Design: macOS-style continuous-corner squircle on the standard 824 pt grid (100 pt margin, soft drop shadow),
// deep-blue → teal gradient, and an isometric white shipping container with corrugated side and door end.
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let size = 1024
let canvas = CGFloat(size)

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: swift make-icon.swift out.png\n".utf8))
    exit(64)
}
let outURL = URL(fileURLWithPath: CommandLine.arguments[1])

let space = CGColorSpace(name: CGColorSpace.displayP3)!
guard
    let ctx = CGContext(
        data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: space,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
else { fatalError("could not create context") }

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(
        colorSpace: space,
        components: [
            CGFloat((hex >> 16) & 0xFF) / 255, CGFloat((hex >> 8) & 0xFF) / 255, CGFloat(hex & 0xFF) / 255, alpha,
        ])!
}

func gradient(_ colors: [CGColor], _ locations: [CGFloat]) -> CGGradient {
    CGGradient(colorsSpace: space, colors: colors as CFArray, locations: locations)!
}

// MARK: - Squircle (superellipse, n = 5 — close to Apple's continuous corners)

func squircle(in rect: CGRect, exponent n: CGFloat = 5) -> CGPath {
    let path = CGMutablePath()
    let a = rect.width / 2, b = rect.height / 2
    let cx = rect.midX, cy = rect.midY
    let steps = 720
    for i in 0...steps {
        let t = CGFloat(i) / CGFloat(steps) * 2 * .pi
        let c = cos(t), s = sin(t)
        let x = cx + a * (c >= 0 ? 1 : -1) * pow(abs(c), 2 / n)
        let y = cy + b * (s >= 0 ? 1 : -1) * pow(abs(s), 2 / n)
        if i == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
    }
    path.closeSubpath()
    return path
}

let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
let tilePath = squircle(in: tile)

// Drop shadow under the tile (macOS icons float slightly above the Dock).
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 28, color: rgb(0x000000, 0.35))
ctx.addPath(tilePath)
ctx.setFillColor(rgb(0x0B2A6B))
ctx.fillPath()
ctx.restoreGState()

// MARK: - Background gradient

ctx.saveGState()
ctx.addPath(tilePath)
ctx.clip()
ctx.drawLinearGradient(
    gradient([rgb(0x0A1E5E), rgb(0x1150A8), rgb(0x0C93B0), rgb(0x2BD2B6)], [0, 0.4, 0.78, 1]),
    start: CGPoint(x: tile.minX, y: tile.maxY), end: CGPoint(x: tile.maxX, y: tile.minY), options: [])
// Soft top-left glow for depth.
ctx.drawRadialGradient(
    gradient([rgb(0x8CC4FF, 0.30), rgb(0x8CC4FF, 0)], [0, 1]),
    startCenter: CGPoint(x: tile.minX + 230, y: tile.maxY - 170), startRadius: 0,
    endCenter: CGPoint(x: tile.minX + 230, y: tile.maxY - 170), endRadius: 620, options: [])
// Gentle vignette at the bottom.
ctx.drawLinearGradient(
    gradient([rgb(0x000000, 0), rgb(0x000000, 0.18)], [0, 1]),
    start: CGPoint(x: 0, y: tile.midY), end: CGPoint(x: 0, y: tile.minY), options: [])
ctx.restoreGState()

// Inner rim highlight.
ctx.saveGState()
ctx.addPath(tilePath)
ctx.clip()
ctx.addPath(squircle(in: tile.insetBy(dx: 1.5, dy: 1.5)))
ctx.setStrokeColor(rgb(0xFFFFFF, 0.18))
ctx.setLineWidth(3)
ctx.strokePath()
ctx.restoreGState()

// MARK: - Isometric container

// World units: x = length (len), y = depth (dep), z = height (hgt). Visible faces: top, long side, door end.
let len: CGFloat = 1.0, dep: CGFloat = 0.43, hgt: CGFloat = 0.43
let scale: CGFloat = 445
let cos30 = cos(CGFloat.pi / 6), sin30 = sin(CGFloat.pi / 6)
let glyphWidth = (len + dep) * cos30 * scale
let glyphHeight = (hgt + (len + dep) * sin30) * scale
let origin = CGPoint(
    x: canvas / 2 - glyphWidth / 2 + dep * cos30 * scale,
    y: canvas / 2 + glyphHeight / 2 - hgt * scale - 6)

func p(_ x: CGFloat, _ y: CGFloat, _ z: CGFloat) -> CGPoint {
    CGPoint(x: origin.x + (x - y) * cos30 * scale, y: origin.y + (z - (x + y) * sin30) * scale)
}

func poly(_ pts: [CGPoint]) -> CGPath {
    let path = CGMutablePath()
    path.addLines(between: pts)
    path.closeSubpath()
    return path
}

func fill(_ path: CGPath, _ g: CGGradient, from: CGPoint, to: CGPoint) {
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    ctx.drawLinearGradient(g, start: from, end: to, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    ctx.restoreGState()
}

let top = poly([p(0, 0, hgt), p(len, 0, hgt), p(len, dep, hgt), p(0, dep, hgt)])
let side = poly([p(0, dep, 0), p(len, dep, 0), p(len, dep, hgt), p(0, dep, hgt)])
let door = poly([p(len, 0, 0), p(len, dep, 0), p(len, dep, hgt), p(len, 0, hgt)])
let silhouette = poly([p(0, 0, hgt), p(len, 0, hgt), p(len, 0, 0), p(len, dep, 0), p(0, dep, 0), p(0, dep, hgt)])

// Contact shadow on the "floor".
ctx.saveGState()
ctx.addPath(tilePath)
ctx.clip()
ctx.setShadow(offset: CGSize(width: 0, height: -26), blur: 46, color: rgb(0x031033, 0.55))
ctx.addPath(silhouette)
ctx.setFillColor(rgb(0x0A2A66))
ctx.fillPath()
ctx.restoreGState()

// Faces.
fill(top, gradient([rgb(0xFFFFFF), rgb(0xF1F7FD)], [0, 1]), from: p(0, 0, hgt), to: p(len, dep, hgt))
fill(side, gradient([rgb(0xF6FAFF), rgb(0xD9E8F7)], [0, 1]), from: p(0, dep, hgt), to: p(len, dep, 0))
fill(door, gradient([rgb(0xBCD3EE), rgb(0x95B4DC)], [0, 1]), from: p(len, 0, hgt), to: p(len, dep, 0))

// Corrugation on the long side: alternating recessed strips with a light lip.
let rail: CGFloat = 0.045  // top/bottom frame rail height (world units)
let ribs = 9
let inset: CGFloat = 0.05
let span = (len - 2 * inset) / CGFloat(ribs)
for i in 0..<ribs {
    let x0 = inset + CGFloat(i) * span + span * 0.18
    let x1 = x0 + span * 0.5
    let groove = poly([p(x0, dep, rail), p(x1, dep, rail), p(x1, dep, hgt - rail), p(x0, dep, hgt - rail)])
    fill(
        groove, gradient([rgb(0x9DB8D9, 0.55), rgb(0x86A6CF, 0.6)], [0, 1]), from: p(x0, dep, hgt), to: p(x1, dep, 0))
    // Highlight edge on the right of each groove.
    ctx.saveGState()
    ctx.setStrokeColor(rgb(0xFFFFFF, 0.9))
    ctx.setLineWidth(2.5)
    ctx.move(to: p(x1, dep, rail))
    ctx.addLine(to: p(x1, dep, hgt - rail))
    ctx.strokePath()
    ctx.restoreGState()
}

// Door end: two leaves, a centre seam and four locking rods.
let doorInset: CGFloat = 0.035
let leafGap = dep / 2
ctx.saveGState()
ctx.setStrokeColor(rgb(0x6A8BBA, 0.95))
ctx.setLineWidth(3.5)
ctx.addPath(
    poly([
        p(len, doorInset, doorInset), p(len, dep - doorInset, doorInset), p(len, dep - doorInset, hgt - doorInset),
        p(len, doorInset, hgt - doorInset),
    ]))
ctx.strokePath()
ctx.move(to: p(len, leafGap, doorInset))
ctx.addLine(to: p(len, leafGap, hgt - doorInset))
ctx.strokePath()
ctx.restoreGState()

for frac in [0.22, 0.38, 0.62, 0.78] as [CGFloat] {
    let y = dep * frac
    ctx.saveGState()
    ctx.setLineCap(.round)
    ctx.setStrokeColor(rgb(0xFFFFFF, 0.95))
    ctx.setLineWidth(5)
    ctx.move(to: p(len, y, doorInset + 0.03))
    ctx.addLine(to: p(len, y, hgt - doorInset - 0.03))
    ctx.strokePath()
    // Handle.
    ctx.setStrokeColor(rgb(0x6F8FBC))
    ctx.setLineWidth(4)
    let hz = hgt * 0.42
    ctx.move(to: p(len, y, hz))
    ctx.addLine(to: p(len, y + dep * 0.07, hz))
    ctx.strokePath()
    ctx.restoreGState()
}

// Crisp edges: bright highlight on the top-front edges, subtle outline around the silhouette.
ctx.saveGState()
ctx.setLineJoin(.round)
ctx.setStrokeColor(rgb(0xFFFFFF))
ctx.setLineWidth(3)
ctx.move(to: p(0, dep, hgt))
ctx.addLine(to: p(len, dep, hgt))
ctx.addLine(to: p(len, 0, hgt))
ctx.move(to: p(len, dep, hgt))
ctx.addLine(to: p(len, dep, 0))
ctx.strokePath()
ctx.setStrokeColor(rgb(0x0A2A66, 0.25))
ctx.setLineWidth(2)
ctx.addPath(silhouette)
ctx.strokePath()
ctx.restoreGState()

// Bottom frame rail on the long side and door end grounds the box.
for face in [
    poly([p(0, dep, 0), p(len, dep, 0), p(len, dep, rail), p(0, dep, rail)]),
    poly([p(len, 0, 0), p(len, dep, 0), p(len, dep, rail), p(len, 0, rail)]),
] {
    ctx.addPath(face)
    ctx.setFillColor(rgb(0x7896C2, 0.55))
    ctx.fillPath()
}

// MARK: - Write PNG

guard let image = ctx.makeImage(),
    let dest = CGImageDestinationCreateWithURL(outURL as CFURL, UTType.png.identifier as CFString, 1, nil)
else { fatalError("could not create image destination") }
CGImageDestinationAddImage(dest, image, nil)
guard CGImageDestinationFinalize(dest) else { fatalError("could not write \(outURL.path)") }
print("wrote \(outURL.path)")
