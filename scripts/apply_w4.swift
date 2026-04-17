#!/usr/bin/env swift
// Applies W4: off-white gradient tile + artwork at 1.25x, across all 10 sizes.
// Reads from AppIcon.appiconset/, writes to Resources/AppIcon.iconset/.

import AppKit

let artScale: CGFloat = 1.25
let inDir   = "Design/AppIcon.appiconset"
let outDir  = "Resources/AppIcon.iconset"

let files: [(String, Int)] = [
    ("icon_16x16.png",      16),
    ("icon_16x16@2x.png",   32),
    ("icon_32x32.png",      32),
    ("icon_32x32@2x.png",   64),
    ("icon_128x128.png",    128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png",    256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png",    512),
    ("icon_512x512@2x.png", 1024),
]

try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

let gradient = [
    NSColor(white: 0.98, alpha: 1),
    NSColor(white: 0.88, alpha: 1),
]

for (name, px) in files {
    guard let src = NSImage(contentsOfFile: "\(inDir)/\(name)") else {
        print("  SKIP missing \(name)"); continue
    }
    let canvas = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                               pixelsWide: px, pixelsHigh: px,
                               bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    let g = NSGraphicsContext(bitmapImageRep: rep)!
    g.imageInterpolation = .high
    NSGraphicsContext.current = g

    // Off-white gradient tile
    let inset: CGFloat = canvas * 0.04
    let tileRect = NSRect(x: inset, y: inset,
                          width: canvas - inset * 2,
                          height: canvas - inset * 2)
    let corner = canvas * 0.22
    let path = NSBezierPath(roundedRect: tileRect, xRadius: corner, yRadius: corner)
    NSGraphicsContext.current?.saveGraphicsState()
    path.addClip()
    NSGradient(colors: gradient)?.draw(in: tileRect, angle: 270)
    NSGraphicsContext.current?.restoreGraphicsState()
    NSColor(white: 0, alpha: 0.10).setStroke()
    path.lineWidth = max(1, canvas / 512 * 2)
    path.stroke()

    // Artwork at 1.25x, centered
    let drawSize = canvas * artScale
    let origin = (canvas - drawSize) / 2
    src.draw(in: NSRect(x: origin, y: origin, width: drawSize, height: drawSize),
             from: .zero, operation: .sourceOver, fraction: 1.0)

    NSGraphicsContext.restoreGraphicsState()
    let png = rep.representation(using: .png, properties: [:])!
    try! png.write(to: URL(fileURLWithPath: "\(outDir)/\(name)"))
    print("  \(name)  (\(px)×\(px))")
}
print("Done.")
