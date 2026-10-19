#!/usr/bin/env swift
// Renders the README hero and the GitHub social preview from the committed screenshot + app icon.
//
//   swift docs/launch/make-hero.swift          # run from the repo root
//
// Inputs:  docs/screenshots/containers-dark.png (window capture, transparent corners), Resources/AppIcon.png
// Outputs: docs/launch/hero.png (2400×1350), docs/launch/social-preview.png (1280×640)
import AppKit
import CoreGraphics

let screenshot = load("docs/screenshots/containers-dark.png")
let icon = load("Resources/AppIcon.png")

func load(_ path: String) -> CGImage {
    guard let image = NSImage(contentsOfFile: path),
        let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
    else { fatalError("missing \(path) — run from the repo root") }
    return cg
}

struct Layout {
    var size: CGSize
    var iconSize: CGFloat
    var titleSize: CGFloat
    var taglineSize: CGFloat
    /// Top-left of the header block, measured from the top edge.
    var header: CGPoint
    var headerCentered: Bool
    /// Screenshot frame, measured from the top edge (it may bleed off the canvas).
    var shot: CGRect
}

func render(_ layout: Layout, to path: String) {
    let w = Int(layout.size.width), h = Int(layout.size.height)
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    guard
        let ctx = CGContext(
            data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { fatalError("no context") }
    let H = CGFloat(h)
    func flip(_ r: CGRect) -> CGRect { CGRect(x: r.minX, y: H - r.maxY, width: r.width, height: r.height) }

    // Background: deep blue-violet diagonal gradient plus two soft glows.
    let bg = CGGradient(
        colorsSpace: space,
        colors: [
            CGColor(srgbRed: 0.035, green: 0.055, blue: 0.13, alpha: 1),
            CGColor(srgbRed: 0.075, green: 0.09, blue: 0.24, alpha: 1),
            CGColor(srgbRed: 0.13, green: 0.07, blue: 0.24, alpha: 1),
        ] as CFArray, locations: [0, 0.55, 1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: 0, y: H), end: CGPoint(x: CGFloat(w), y: 0), options: [])
    for (center, radius, color) in [
        (CGPoint(x: CGFloat(w) * 0.18, y: H * 0.9), CGFloat(w) * 0.45, CGColor(srgbRed: 0.2, green: 0.45, blue: 1, alpha: 0.22)),
        (CGPoint(x: CGFloat(w) * 0.85, y: H * 0.15), CGFloat(w) * 0.4, CGColor(srgbRed: 0.6, green: 0.3, blue: 1, alpha: 0.16)),
    ] {
        let glow = CGGradient(
            colorsSpace: space, colors: [color, color.copy(alpha: 0)!] as CFArray, locations: [0, 1])!
        ctx.drawRadialGradient(
            glow, startCenter: center, startRadius: 0, endCenter: center, endRadius: radius, options: [])
    }

    // Screenshot with a soft drop shadow.
    ctx.saveGState()
    ctx.setShadow(
        offset: CGSize(width: 0, height: -layout.size.width * 0.008), blur: layout.size.width * 0.03,
        color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.6))
    ctx.interpolationQuality = .high
    ctx.draw(screenshot, in: flip(layout.shot))
    ctx.restoreGState()

    // Header: icon + name + one-line pitch.
    let ns = NSGraphicsContext(cgContext: ctx, flipped: false)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = ns
    let title = NSAttributedString(
        string: "Container Desktop",
        attributes: [
            .font: NSFont.systemFont(ofSize: layout.titleSize, weight: .bold), .foregroundColor: NSColor.white,
            .kern: -layout.titleSize * 0.01,
        ])
    let tagline = NSAttributedString(
        string: "The Docker Desktop experience for Apple’s native container runtime",
        attributes: [
            .font: NSFont.systemFont(ofSize: layout.taglineSize, weight: .medium),
            .foregroundColor: NSColor(white: 1, alpha: 0.72),
        ])
    let gap = layout.iconSize * 0.18
    let textWidth = max(title.size().width, tagline.size().width)
    let blockWidth = layout.iconSize + gap + textWidth
    let x0 = layout.headerCentered ? (layout.size.width - blockWidth) / 2 : layout.header.x
    let iconRect = CGRect(x: x0, y: layout.header.y, width: layout.iconSize, height: layout.iconSize)
    ctx.draw(icon, in: flip(iconRect))
    let textX = iconRect.maxX + gap
    let titleH = title.size().height, tagH = tagline.size().height
    let top = iconRect.midY - (titleH + tagH) / 2
    title.draw(at: CGPoint(x: textX, y: H - top - titleH))
    tagline.draw(at: CGPoint(x: textX, y: H - top - titleH - tagH))
    NSGraphicsContext.restoreGraphicsState()

    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
    print("wrote \(path) (\(w)×\(h))")
}

let aspect = CGFloat(screenshot.height) / CGFloat(screenshot.width)

// Hero 2400×1350: centered header, screenshot below bleeding off the bottom edge.
let heroShotW: CGFloat = 1960
render(
    Layout(
        size: CGSize(width: 2400, height: 1350), iconSize: 168, titleSize: 86, taglineSize: 38,
        header: CGPoint(x: 0, y: 70), headerCentered: true,
        shot: CGRect(x: (2400 - heroShotW) / 2, y: 300, width: heroShotW, height: heroShotW * aspect)),
    to: "docs/launch/hero.png")

// Social preview 1280×640 (GitHub crops nothing, but keep text inside a 40 px safe area).
let socialShotW: CGFloat = 1060
render(
    Layout(
        size: CGSize(width: 1280, height: 640), iconSize: 92, titleSize: 48, taglineSize: 21,
        header: CGPoint(x: 0, y: 44), headerCentered: true,
        shot: CGRect(x: (1280 - socialShotW) / 2, y: 182, width: socialShotW, height: socialShotW * aspect)),
    to: "docs/launch/social-preview.png")
