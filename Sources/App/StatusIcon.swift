import AppKit

/// The menu bar icon: a paddock fence, with the server's state as a mark to its right.
///
/// - off: the fence alone, dimmed
/// - starting or stopping: a ring
/// - on, started by Paddock: a filled dot
/// - on, but started outside Paddock: an exclamation mark
/// - ollama missing: the fence struck through, dimmed
@MainActor
enum StatusIcon {
    enum Kind {
        case off, on, transition, external, missing

        /// Shown dimmed, the way macOS shows an inactive status item.
        var isDimmed: Bool { self == .off || self == .missing }
    }

    static func image(for kind: Kind) -> NSImage {
        switch kind {
        case .off: off
        case .on: on
        case .transition: transition
        case .external: external
        case .missing: missing
        }
    }

    /// Three pointed posts and two rails. The rails stop at the outer posts, so at menu bar size the shape reads as
    /// a fence panel rather than a hash sign.
    private static func drawFence() {
        let half: CGFloat = 1.8
        for x in [2.5, 10.5, 18.5] as [CGFloat] {
            let post = NSBezierPath()
            post.move(to: NSPoint(x: x - half, y: 1))
            post.line(to: NSPoint(x: x + half, y: 1))
            post.line(to: NSPoint(x: x + half, y: 11.8))
            post.line(to: NSPoint(x: x, y: 14.8))
            post.line(to: NSPoint(x: x - half, y: 11.8))
            post.close()
            post.fill()
        }
        for y in [3.8, 8.4] as [CGFloat] {
            NSBezierPath(rect: NSRect(x: 2.5, y: y, width: 16, height: 2)).fill()
        }
    }

    private static let markFrame = NSRect(x: 22, y: 9.5, width: 5, height: 5)

    private static func make(_ drawMark: @escaping () -> Void) -> NSImage {
        let image = NSImage(size: NSSize(width: 27, height: 16), flipped: false) { _ in
            NSColor.black.setFill()
            NSColor.black.setStroke()
            drawFence()
            drawMark()
            return true
        }
        // A template image follows the menu bar's light and dark appearance.
        image.isTemplate = true
        return image
    }

    private static let off = make {}

    private static let transition = make {
        let ring = NSBezierPath(ovalIn: markFrame.insetBy(dx: 0.6, dy: 0.6))
        ring.lineWidth = 1.2
        ring.stroke()
    }

    private static let on = make {
        NSBezierPath(ovalIn: markFrame).fill()
    }

    private static let external = make {
        NSBezierPath(roundedRect: NSRect(x: 23.5, y: 6.5, width: 2, height: 8), xRadius: 1, yRadius: 1).fill()
        NSBezierPath(ovalIn: NSRect(x: 23.5, y: 2, width: 2, height: 2)).fill()
    }

    private static let missing = make {
        // Cut a gap into the fence along the slash, then draw the slash, so the two stay apart.
        NSGraphicsContext.current?.compositingOperation = .destinationOut
        let gap = NSBezierPath()
        gap.move(to: NSPoint(x: 0, y: 0.5))
        gap.line(to: NSPoint(x: 21, y: 15.5))
        gap.lineWidth = 3.2
        gap.stroke()
        NSGraphicsContext.current?.compositingOperation = .sourceOver
        let slash = NSBezierPath()
        slash.move(to: NSPoint(x: 1, y: 0.5))
        slash.line(to: NSPoint(x: 20, y: 15))
        slash.lineWidth = 1.4
        slash.lineCapStyle = .round
        slash.stroke()
    }
}
