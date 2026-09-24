import AppKit

// Draws the app icon and writes the PNG files of an .iconset.
// The motif is the menu bar icon: a toggle switch, here switched on.

func draw(_ pixels: Int) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    let size = CGFloat(pixels)
    let inset = size * 0.098
    let plate = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)

    // Background: the rounded plate of a macOS app icon.
    let background = NSBezierPath(
        roundedRect: plate, xRadius: plate.width * 0.2237, yRadius: plate.width * 0.2237)
    NSGradient(colors: [
        NSColor(srgbRed: 0.22, green: 0.25, blue: 0.24, alpha: 1),
        NSColor(srgbRed: 0.07, green: 0.09, blue: 0.08, alpha: 1),
    ])!.draw(in: background, angle: -90)

    // The switch track, on.
    let trackHeight = plate.height * 0.34
    let track = CGRect(
        x: plate.minX + plate.width * 0.14, y: plate.midY - trackHeight / 2,
        width: plate.width * 0.72, height: trackHeight)
    NSColor(srgbRed: 0.20, green: 0.78, blue: 0.40, alpha: 1).setFill()
    NSBezierPath(roundedRect: track, xRadius: trackHeight / 2, yRadius: trackHeight / 2).fill()

    // The knob, on the right.
    let knobInset = trackHeight * 0.1
    let knobSize = trackHeight - knobInset * 2
    let knob = CGRect(
        x: track.maxX - knobInset - knobSize, y: track.minY + knobInset, width: knobSize, height: knobSize)
    let shadow = NSShadow()
    shadow.shadowColor = NSColor(white: 0, alpha: 0.35)
    shadow.shadowBlurRadius = size * 0.012
    shadow.shadowOffset = NSSize(width: 0, height: -size * 0.006)
    shadow.set()
    NSColor(white: 0.98, alpha: 1).setFill()
    NSBezierPath(ovalIn: knob).fill()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let outputDirectory = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset"
try FileManager.default.createDirectory(atPath: outputDirectory, withIntermediateDirectories: true)

// Every size an .icns needs.
let plan: [(Int, String)] = [
    (16, "icon_16x16.png"), (32, "icon_16x16@2x.png"),
    (32, "icon_32x32.png"), (64, "icon_32x32@2x.png"),
    (128, "icon_128x128.png"), (256, "icon_128x128@2x.png"),
    (256, "icon_256x256.png"), (512, "icon_256x256@2x.png"),
    (512, "icon_512x512.png"), (1024, "icon_512x512@2x.png"),
]
for (pixels, name) in plan {
    try draw(pixels).write(to: URL(fileURLWithPath: "\(outputDirectory)/\(name)"))
}
print("  wrote \(plan.count) images to \(outputDirectory)")
