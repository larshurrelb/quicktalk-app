#!/usr/bin/env swift
//
// Generates AppIcon.icns from AppIcon.png.
//
// AppIcon.png is the artwork: a 1024x1024 rounded rectangle with transparency outside it,
// already shaped like a macOS icon. This script only sizes it — it deliberately adds no
// mask or corner rounding of its own, which would round the corners a second time.
//
// Run: swift make-icon.swift && iconutil -c icns AppIcon.iconset -o AppIcon.icns

import AppKit

let source = "AppIcon.png"
let iconset = "AppIcon.iconset"

guard let artwork = NSImage(contentsOfFile: source) else {
    fatalError("could not read \(source)")
}

try? FileManager.default.removeItem(atPath: iconset)
try! FileManager.default.createDirectory(atPath: iconset, withIntermediateDirectories: true)

func render(size: Int) -> Data {
    let dimension = CGFloat(size)
    let image = NSImage(size: NSSize(width: dimension, height: dimension))
    image.lockFocus()
    NSGraphicsContext.current!.imageInterpolation = .high

    // Drawn full-bleed, with no inset and no mask of our own.
    //
    // macOS 26 wraps an app icon in its own standard tile and insets the artwork into it.
    // Supplying artwork that is *already* inset gets inset a second time, which renders as
    // a small picture floating inside a grey rounded rectangle — verified by reading back
    // what NSWorkspace resolves for the installed bundle. Full-bleed lets the system apply
    // exactly one shape.
    //
    // The trade: on macOS 14–15, which apply no tile, the icon reaches the canvas edges and
    // sits marginally larger than its neighbours. That is far less wrong than the nested
    // version on current macOS.
    let inset: CGFloat = 0
    let rect = NSRect(x: inset, y: inset, width: dimension - inset * 2, height: dimension - inset * 2)
    artwork.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)

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
for size in Set(names.map(\.0)).sorted() { cache[size] = render(size: size) }
for (size, name) in names {
    try! cache[size]!.write(to: URL(fileURLWithPath: "\(iconset)/\(name)"))
}

print("wrote \(iconset) (\(names.count) images) from \(source)")
