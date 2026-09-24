import AppKit

/// The menu bar icon: a toggle switch, so the state reads at a glance like any other on/off control.
///
/// - off: an outlined track with the knob on the left
/// - on: a filled track with the knob on the right
/// - starting or stopping: an outlined track with the knob in the middle
/// - on, but started outside Paddock: the "on" switch followed by an exclamation mark
/// - ollama missing: an outlined track with no knob, struck through
@MainActor
enum StatusIcon {
    enum Kind {
        case off, on, transition, external, missing
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

    private static let track = NSRect(x: 1, y: 3, width: 20, height: 10)
    private static let knobRadius: CGFloat = 3.4

    private static func knob(atX x: CGFloat) -> NSBezierPath {
        NSBezierPath(
            ovalIn: NSRect(
                x: x - knobRadius, y: track.midY - knobRadius, width: knobRadius * 2, height: knobRadius * 2))
    }

    private static func outlinedTrack() -> NSBezierPath {
        let path = NSBezierPath(roundedRect: track.insetBy(dx: 0.75, dy: 0.75), xRadius: 4.25, yRadius: 4.25)
        path.lineWidth = 1.5
        return path
    }

    private static func make(width: CGFloat = 22, _ draw: @escaping () -> Void) -> NSImage {
        let image = NSImage(size: NSSize(width: width, height: 16), flipped: false) { _ in
            NSColor.black.setFill()
            NSColor.black.setStroke()
            draw()
            return true
        }
        // A template image follows the menu bar's light and dark appearance.
        image.isTemplate = true
        return image
    }

    private static let off = make {
        outlinedTrack().stroke()
        knob(atX: track.minX + 5).fill()
    }

    private static let transition = make {
        outlinedTrack().stroke()
        knob(atX: track.midX).fill()
    }

    private static func drawOnSwitch() {
        NSBezierPath(roundedRect: track, xRadius: 5, yRadius: 5).fill()
        // Punch the knob out of the filled track.
        NSGraphicsContext.current?.compositingOperation = .destinationOut
        knob(atX: track.maxX - 5).fill()
        NSGraphicsContext.current?.compositingOperation = .sourceOver
    }

    private static let on = make { drawOnSwitch() }

    private static let external = make(width: 27) {
        drawOnSwitch()
        NSBezierPath(roundedRect: NSRect(x: 23.5, y: 6.5, width: 2, height: 7.5), xRadius: 1, yRadius: 1).fill()
        NSBezierPath(ovalIn: NSRect(x: 23.5, y: 2.5, width: 2, height: 2)).fill()
    }

    private static let missing = make {
        outlinedTrack().stroke()
        let slash = NSBezierPath()
        slash.move(to: NSPoint(x: 3, y: 1.5))
        slash.line(to: NSPoint(x: 19, y: 14.5))
        slash.lineWidth = 1.5
        slash.lineCapStyle = .round
        slash.stroke()
    }
}
