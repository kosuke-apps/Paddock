import AppKit

// Draws the app icon and writes the PNG files of an .iconset.
// The motif is the name: a white paddock fence on a dark plate, with a green lamp for a server that is on.

func draw(_ pixels: Int) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    let size = CGFloat(pixels)
    let inset = size * 0.098
    let plate = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    func x(_ fraction: CGFloat) -> CGFloat { plate.minX + plate.width * fraction }
    func y(_ fraction: CGFloat) -> CGFloat { plate.minY + plate.height * fraction }

    // Background: the rounded plate of a macOS app icon.
    let background = NSBezierPath(
        roundedRect: plate, xRadius: plate.width * 0.2237, yRadius: plate.width * 0.2237)
    NSGradient(colors: [
        NSColor(srgbRed: 0.20, green: 0.26, blue: 0.22, alpha: 1),
        NSColor(srgbRed: 0.06, green: 0.09, blue: 0.07, alpha: 1),
    ])!.draw(in: background, angle: -90)

    // The ground the fence stands on.
    NSColor(white: 1, alpha: 0.12).setFill()
    NSBezierPath(rect: CGRect(x: x(0.06), y: y(0.20), width: plate.width * 0.88, height: plate.height * 0.012)).fill()

    // The fence: four pointed posts and two rails.
    NSColor(white: 0.96, alpha: 1).setFill()
    let half = plate.width * 0.045
    for fraction in [0.16, 0.39, 0.62, 0.85] as [CGFloat] {
        let post = NSBezierPath()
        post.move(to: NSPoint(x: x(fraction) - half, y: y(0.21)))
        post.line(to: NSPoint(x: x(fraction) + half, y: y(0.21)))
        post.line(to: NSPoint(x: x(fraction) + half, y: y(0.56)))
        post.line(to: NSPoint(x: x(fraction), y: y(0.64)))
        post.line(to: NSPoint(x: x(fraction) - half, y: y(0.56)))
        post.close()
        post.fill()
    }
    for fraction in [0.29, 0.45] as [CGFloat] {
        NSBezierPath(rect: CGRect(x: x(0.16), y: y(fraction), width: x(0.85) - x(0.16), height: plate.height * 0.055))
            .fill()
    }

    // The lamp, on.
    let lamp = CGRect(x: x(0.70), y: y(0.72), width: plate.width * 0.14, height: plate.width * 0.14)
    let glow = NSShadow()
    glow.shadowColor = NSColor(srgbRed: 0.3, green: 0.95, blue: 0.5, alpha: 0.8)
    glow.shadowBlurRadius = size * 0.04
    glow.set()
    NSColor(srgbRed: 0.25, green: 0.85, blue: 0.45, alpha: 1).setFill()
    NSBezierPath(ovalIn: lamp).fill()

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
