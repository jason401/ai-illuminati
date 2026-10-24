import Cocoa

// The menu bar mark: an eye inside a triangle, drawn in code (18 x 18 points).
// Monochrome uses a template image; color mode keeps the teal mark.
func illuminatiIcon(colored: Bool = false) -> NSImage {
    let size = NSSize(width: 18, height: 18)
    let image = NSImage(size: size, flipped: false) { _ in
        let ink: NSColor = colored ? .systemTeal : .black
        ink.setStroke()
        ink.setFill()

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
    image.isTemplate = !colored
    image.accessibilityDescription = "AI Illuminati"
    return image
}

// The compact menu bar meter: one thin vertical bar per AI (Claude, ChatGPT, Gemini), filled from the
// bottom by what is left. An AI with no reading shows an empty outline. Optionally the mark first.
// Provider colors are optional; without them macOS adapts the template to the menu bar.
func meterIcon(levels: [Double?], mark: Bool, colors: [NSColor]? = nil) -> NSImage {
    let barWidth: CGFloat = 4, gap: CGFloat = 1, height: CGFloat = 18
    let barsWidth = CGFloat(levels.count) * barWidth + CGFloat(max(levels.count - 1, 0)) * gap
    let markWidth: CGFloat = mark ? 18 + 2 : 0
    let size = NSSize(width: markWidth + barsWidth, height: height)
    let image = NSImage(size: size, flipped: false) { _ in
        if mark { illuminatiIcon(colored: colors != nil).draw(in: NSRect(x: 0, y: 0, width: 18, height: 18)) }
        for (i, level) in levels.enumerated() {
            let x = markWidth + CGFloat(i) * (barWidth + gap)
            let frame = NSRect(x: x + 0.5, y: 2.5, width: barWidth - 1, height: 13)
            let outline = NSBezierPath(roundedRect: frame, xRadius: 1.5, yRadius: 1.5)
            let ink: NSColor = colors.flatMap { i < $0.count ? $0[i] : nil } ?? .black
            ink.withAlphaComponent(0.45).setStroke()
            outline.lineWidth = 1
            outline.stroke()
            if let level, level > 0 {
                let fillHeight = max(1.5, 13 * CGFloat(min(level, 100)) / 100)
                ink.setFill()
                NSBezierPath(roundedRect: NSRect(x: x + 0.5, y: 2.5, width: barWidth - 1, height: fillHeight), xRadius: 1.5, yRadius: 1.5).fill()
            }
        }
        return true
    }
    image.isTemplate = colors == nil
    image.accessibilityDescription = "AI Illuminati"
    return image
}

