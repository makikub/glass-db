import AppKit
import Foundation

struct IconImage {
    let fileName: String
    let pixels: Int
}

let arguments = CommandLine.arguments
guard arguments.count == 3 else {
    FileHandle.standardError.write(Data("Usage: render-iconset.swift <source-png> <iconset-dir>\n".utf8))
    exit(64)
}

let sourceURL = URL(fileURLWithPath: arguments[1])
let iconsetURL = URL(fileURLWithPath: arguments[2], isDirectory: true)

guard let sourceImage = NSImage(contentsOf: sourceURL) else {
    FileHandle.standardError.write(Data("Could not read source image: \(sourceURL.path)\n".utf8))
    exit(66)
}

let images = [
    IconImage(fileName: "icon_16x16.png", pixels: 16),
    IconImage(fileName: "icon_16x16@2x.png", pixels: 32),
    IconImage(fileName: "icon_32x32.png", pixels: 32),
    IconImage(fileName: "icon_32x32@2x.png", pixels: 64),
    IconImage(fileName: "icon_128x128.png", pixels: 128),
    IconImage(fileName: "icon_128x128@2x.png", pixels: 256),
    IconImage(fileName: "icon_256x256.png", pixels: 256),
    IconImage(fileName: "icon_256x256@2x.png", pixels: 512),
    IconImage(fileName: "icon_512x512.png", pixels: 512),
    IconImage(fileName: "icon_512x512@2x.png", pixels: 1024)
]

for image in images {
    let size = NSSize(width: image.pixels, height: image.pixels)
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: image.pixels,
        pixelsHigh: image.pixels,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else {
        FileHandle.standardError.write(Data("Could not allocate bitmap for \(image.fileName)\n".utf8))
        exit(1)
    }

    bitmap.size = size
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    NSColor.clear.setFill()
    NSRect(origin: .zero, size: size).fill()
    sourceImage.draw(
        in: NSRect(origin: .zero, size: size),
        from: NSRect(origin: .zero, size: sourceImage.size),
        operation: .sourceOver,
        fraction: 1.0
    )
    NSGraphicsContext.restoreGraphicsState()

    guard let pngData = bitmap.representation(using: .png, properties: [:]) else {
        FileHandle.standardError.write(Data("Could not encode \(image.fileName)\n".utf8))
        exit(1)
    }

    try pngData.write(to: iconsetURL.appendingPathComponent(image.fileName), options: .atomic)
}
