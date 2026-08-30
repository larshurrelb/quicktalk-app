#!/usr/bin/env swift
//
// Generates AppIcon.icns: the same `waveform` symbol used in the menu bar, white on a
// blue squircle. Rendering the real SF Symbol rather than redrawing it by hand keeps the
// app icon and the menu-bar icon identical.
//
// Run: swift make-icon.swift

import AppKit

let sizes = [16, 32, 64, 128, 256, 512, 1024]
let iconset = "AppIcon.iconset"

try? FileManager.default.removeItem(atPath: iconset)
try! FileManager.default.createDirectory(atPath: iconset, withIntermediateDirectories: true)

func render(size: Int) -> Data {
    let dimension = CGFloat(size)
    let image = NSImage(size: NSSize(width: dimension, height: dimension))
    image.lockFocus()

    let context = NSGraphicsContext.current!
    context.imageInterpolation = .high

    // macOS icons sit inset inside their canvas rather than filling it edge to edge.
    let inset = dimension * 0.085
    let rect = NSRect(x: inset, y: inset, width: dimension - inset * 2, height: dimension - inset * 2)
    let squircle = NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.225, yRadius: rect.width * 0.225)

    // Vertical gradient, brighter at the top — reads as lit from above like system icons.
    let gradient = NSGradient(
        colors: [
            NSColor(srgbRed: 0.29, green: 0.60, blue: 1.00, alpha: 1),
            NSColor(srgbRed: 0.09, green: 0.36, blue: 0.92, alpha: 1),
        ]
    )!
    gradient.draw(in: squircle, angle: -90)

    // The glyph, in white, at a weight that stays legible when scaled to 16pt.
    let configuration = NSImage.SymbolConfiguration(pointSize: dimension * 0.46, weight: .semibold)
        .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))

    if let symbol = NSImage(systemSymbolName: "waveform", accessibilityDescription: nil)?
        .withSymbolConfiguration(configuration) {
        let symbolSize = symbol.size
        let origin = NSPoint(
            x: (dimension - symbolSize.width) / 2,
            y: (dimension - symbolSize.height) / 2
        )
        symbol.draw(at: origin, from: .zero, operation: .sourceOver, fraction: 1)
    }

    image.unlockFocus()

    guard let tiff = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiff),
          let png = bitmap.representation(using: .png, properties: [:])
    else { fatalError("could not render \(size)px") }
    return png
}

// Apple's required iconset names: each logical size at 1x and 2x.
let names: [(Int, String)] = [
    (16, "icon_16x16.png"), (32, "icon_16x16@2x.png"),
    (32, "icon_32x32.png"), (64, "icon_32x32@2x.png"),
    (128, "icon_128x128.png"), (256, "icon_128x128@2x.png"),
    (256, "icon_256x256.png"), (512, "icon_256x256@2x.png"),
    (512, "icon_512x512.png"), (1024, "icon_512x512@2x.png"),
]

var cache: [Int: Data] = [:]
for size in sizes { cache[size] = render(size: size) }

for (size, name) in names {
    try! cache[size]!.write(to: URL(fileURLWithPath: "\(iconset)/\(name)"))
}

print("wrote \(iconset) (\(names.count) images)")
