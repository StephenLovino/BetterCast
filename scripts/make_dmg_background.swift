// Generates assets/branding/dmg_background.png — the install background for BetterCast.dmg.
// Layout matches the Finder positions set in make_app.sh:
//   App icon       center: (160, 180)  (top-left origin, 96 px)
//   Applications   center: (440, 180)
// The arrow + copy are drawn between/above those positions.
//
// Usage:  swift scripts/make_dmg_background.swift assets/branding/dmg_background.png

import AppKit
import Foundation

let outPath: String
if CommandLine.arguments.count >= 2 {
    outPath = CommandLine.arguments[1]
} else {
    outPath = "assets/branding/dmg_background.png"
}

let width: CGFloat = 600
let height: CGFloat = 400

let image = NSImage(size: NSSize(width: width, height: height))
image.lockFocus()

guard let ctx = NSGraphicsContext.current?.cgContext else {
    print("Failed to acquire CGContext")
    exit(1)
}

// Subtle vertical gradient (dark, matches BetterCast UI)
if let gradient = CGGradient(
    colorsSpace: CGColorSpaceCreateDeviceRGB(),
    colors: [
        CGColor(red: 0.05, green: 0.05, blue: 0.07, alpha: 1.0),
        CGColor(red: 0.10, green: 0.10, blue: 0.13, alpha: 1.0)
    ] as CFArray,
    locations: [0, 1]
) {
    ctx.drawLinearGradient(
        gradient,
        start: CGPoint(x: 0, y: height),
        end: CGPoint(x: 0, y: 0),
        options: []
    )
}

// Title
let title = "Install BetterCast"
let titleAttrs: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 22, weight: .semibold),
    .foregroundColor: NSColor.white
]
let titleSize = title.size(withAttributes: titleAttrs)
title.draw(at: NSPoint(x: (width - titleSize.width) / 2, y: height - 70), withAttributes: titleAttrs)

// Subtitle
let sub = "Drag BetterCast to your Applications folder to install"
let subAttrs: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 13, weight: .regular),
    .foregroundColor: NSColor.white.withAlphaComponent(0.55)
]
let subSize = sub.size(withAttributes: subAttrs)
sub.draw(at: NSPoint(x: (width - subSize.width) / 2, y: height - 100), withAttributes: subAttrs)

// Arrow at the same y as the icon centers (180 from top → 220 from bottom in image coords)
let arrowY: CGFloat = height - 220
let arrowStartX: CGFloat = 230   // just right of app icon
let arrowEndX: CGFloat = 370     // just left of Applications symlink

ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.32).cgColor)
ctx.setLineWidth(2)
ctx.setLineCap(.round)

// Shaft
ctx.move(to: CGPoint(x: arrowStartX, y: arrowY))
ctx.addLine(to: CGPoint(x: arrowEndX - 10, y: arrowY))
ctx.strokePath()

// Arrowhead
ctx.move(to: CGPoint(x: arrowEndX, y: arrowY))
ctx.addLine(to: CGPoint(x: arrowEndX - 12, y: arrowY + 7))
ctx.strokePath()
ctx.move(to: CGPoint(x: arrowEndX, y: arrowY))
ctx.addLine(to: CGPoint(x: arrowEndX - 12, y: arrowY - 7))
ctx.strokePath()

// Footnote
let foot = "After install: System Settings → Privacy → Screen Recording + Accessibility"
let footAttrs: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 11, weight: .regular),
    .foregroundColor: NSColor.white.withAlphaComponent(0.35)
]
let footSize = foot.size(withAttributes: footAttrs)
foot.draw(at: NSPoint(x: (width - footSize.width) / 2, y: 28), withAttributes: footAttrs)

image.unlockFocus()

guard
    let tiff = image.tiffRepresentation,
    let bitmap = NSBitmapImageRep(data: tiff),
    let png = bitmap.representation(using: .png, properties: [:])
else {
    print("Failed to encode PNG")
    exit(1)
}

let url = URL(fileURLWithPath: outPath)
do {
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try png.write(to: url)
    print("Wrote \(url.path)")
} catch {
    print("Failed to write PNG: \(error)")
    exit(1)
}
