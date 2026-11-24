import AppKit

/// The menu bar icon: the app icon in miniature, a dish with four fingertips in the lopsided arc
/// of a resting hand. A template image, so macOS tints it for light and dark menu bars and for
/// the highlighted button; while paused, the button's own dimmed look (`appearsDisabled`) is used.
/// When something needs attention (a permission, macOS's four-finger gestures), a small dot sits
/// in the dish's top-right corner, cut clear of the outline.
enum MenuBarIcon {
    static let size = NSSize(width: 18, height: 18)

    /// The app icon's hand: fingertip centers on its 1024 grid (y down) and their lean in degrees.
    private static let hand: [(x: CGFloat, y: CGFloat, lean: CGFloat)] = [
        (272, 512, -3.5), (432, 446, -1), (592, 478, 1.5), (752, 576, 4.5),
    ]

    static func image(alert: Bool) -> NSImage {
        let image = NSImage(size: size, flipped: false) { _ in
            NSColor.black.set()
            let dish = NSBezierPath(roundedRect: NSRect(x: 1.25, y: 2.75, width: 15.5, height: 12.5), xRadius: 3.6, yRadius: 3.6)
            dish.lineWidth = 1.3
            dish.stroke()
            // The hand, scaled so its fingertips are 2.95 pt apart and centered in the dish.
            let k: CGFloat = 2.95 / 160
            for tip in hand {
                fingertip(at: CGPoint(x: 9 + (tip.x - 512) * k, y: 9.3 - (tip.y - 509) * k), lean: tip.lean).fill()
            }
            if alert {
                let badge = NSRect(x: 12.5, y: 11.5, width: 5.5, height: 5.5)
                // Clear a ring around the dot, so it stands apart from the outline under it.
                NSGraphicsContext.current?.compositingOperation = .clear
                NSBezierPath(ovalIn: badge.insetBy(dx: -1.2, dy: -1.2)).fill()
                NSGraphicsContext.current?.compositingOperation = .sourceOver
                NSBezierPath(ovalIn: badge).fill()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = alert ? "Tutamak, needs attention" : "Tutamak"
        return image
    }

    private static func fingertip(at centre: CGPoint, lean: CGFloat) -> NSBezierPath {
        let path = NSBezierPath(ovalIn: NSRect(x: -1.1, y: -1.65, width: 2.2, height: 3.3))
        var transform = AffineTransform(rotationByDegrees: -lean)
        transform.append(AffineTransform(translationByX: centre.x, byY: centre.y))
        path.transform(using: transform)
        return path
    }
}
