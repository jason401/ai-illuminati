import Cocoa

// The menu bar mark: an eye inside a triangle, drawn in code (18 x 18 points).
// It is a template image, so macOS draws it white or black to match the menu bar.
func illuminatiIcon() -> NSImage {
    let size = NSSize(width: 18, height: 18)
    let image = NSImage(size: size, flipped: false) { _ in
        NSColor.black.setStroke()
        NSColor.black.setFill()

        // Triangle, point up.
        let triangle = NSBezierPath()
        triangle.move(to: NSPoint(x: 9, y: 16.6))
        triangle.line(to: NSPoint(x: 16.8, y: 2.4))
        triangle.line(to: NSPoint(x: 1.2, y: 2.4))
        triangle.close()
        triangle.lineWidth = 1.4
        triangle.lineJoinStyle = .round
        triangle.stroke()

        // Eye: two arcs meeting at the corners, centered in the lower part of the triangle.
        let center = NSPoint(x: 9, y: 7.4)
        let halfWidth: CGFloat = 4.4, bulge: CGFloat = 2.6
        let eye = NSBezierPath()
        eye.move(to: NSPoint(x: center.x - halfWidth, y: center.y))
        eye.curve(to: NSPoint(x: center.x + halfWidth, y: center.y),
                  controlPoint1: NSPoint(x: center.x - halfWidth / 2, y: center.y + bulge),
                  controlPoint2: NSPoint(x: center.x + halfWidth / 2, y: center.y + bulge))
        eye.curve(to: NSPoint(x: center.x - halfWidth, y: center.y),
                  controlPoint1: NSPoint(x: center.x + halfWidth / 2, y: center.y - bulge),
                  controlPoint2: NSPoint(x: center.x - halfWidth / 2, y: center.y - bulge))
        eye.close()
        eye.lineWidth = 1.1
        eye.stroke()

        // Pupil.
        NSBezierPath(ovalIn: NSRect(x: center.x - 1.4, y: center.y - 1.4, width: 2.8, height: 2.8)).fill()
        return true
    }
    image.isTemplate = true
    image.accessibilityDescription = "AI Illuminati"
    return image
}
