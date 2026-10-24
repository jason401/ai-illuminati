import Cocoa

// Deterministic animation frames, shared by the menu renderer and offline previews.
struct MenuMarkFrame: Equatable {
    var gazeX: CGFloat = 0
    var gazeY: CGFloat = 0
    var openness: CGFloat = 1
    var halo: CGFloat = 0
    var rotation: Double = 0
    var sparkle: CGFloat = 0

    static func at(_ time: TimeInterval, working: Bool, completionAge: TimeInterval? = nil) -> Self {
        let t = max(0, time)
        let blinkPhase = t.truncatingRemainder(dividingBy: working ? 5.7 : 8.3)
        let blink = blinkPhase < 0.4 ? abs(blinkPhase - 0.2) / 0.2 : 1
        let gazes: [(Double, Double)] = [(0, 0), (-1, 0), (0, 0.8), (1, 0), (0, -0.8), (0, 0)]
        let step = working ? 2.8 : 4.0
        let index = Int(t / step) % gazes.count
        let previous = gazes[(index + gazes.count - 1) % gazes.count]
        let target = gazes[index]
        let fraction = min(t.truncatingRemainder(dividingBy: step) / 0.5, 1)
        let ease = fraction * fraction * (3 - 2 * fraction)
        let idlePhase = t.truncatingRemainder(dividingBy: 12)
        let idleSparkle = idlePhase < 1.4 ? sin(idlePhase / 1.4 * .pi) : 0
        let finish = completionAge.map { $0 >= 0 && $0 < 1.4 ? sin($0 / 1.4 * .pi) : 0 } ?? 0
        return Self(gazeX: CGFloat(previous.0 + (target.0 - previous.0) * ease),
                    gazeY: CGFloat(previous.1 + (target.1 - previous.1) * ease),
                    openness: CGFloat(blink),
                    halo: working ? CGFloat(0.55 + 0.35 * sin(t * 2)) : CGFloat(0.12 * idleSparkle),
                    rotation: working ? t * 1.6 : 0,
                    sparkle: CGFloat(max(finish, working ? 0 : idleSparkle * 0.5)))
    }
}

// The menu bar mark: an eye inside a triangle, drawn in code (18 x 18 points).
// Monochrome uses a template image; color mode keeps the teal mark.
func illuminatiIcon(colored: Bool = false, frame: MenuMarkFrame? = nil) -> NSImage {
    if let frame { return animatedIlluminatiIcon(colored: colored, frame: frame) }
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

// The compact menu bar meter: one thin vertical bar per connected account, filled from the
// bottom by what is left. An account with no reading shows an empty outline. Optionally the mark first.
// Provider colors are optional; without them macOS adapts the template to the menu bar.
func meterIcon(levels: [Double?], mark: Bool, colors: [NSColor]? = nil, frame: MenuMarkFrame? = nil) -> NSImage {
    let barWidth: CGFloat = 4, gap: CGFloat = 1, height: CGFloat = 18
    let barsWidth = CGFloat(levels.count) * barWidth + CGFloat(max(levels.count - 1, 0)) * gap
    let markSize: CGFloat = frame == nil ? 18 : 22
    let markWidth: CGFloat = mark ? markSize + 2 : 0
    let size = NSSize(width: markWidth + barsWidth, height: height)
    let image = NSImage(size: size, flipped: false) { _ in
        if mark { illuminatiIcon(colored: colors != nil, frame: frame).draw(in: NSRect(x: 0, y: 0, width: markSize, height: 18)) }
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


// Clear rays, rather than blur alone, remain visible at native menu bar size in both color modes.
private func animatedIlluminatiIcon(colored: Bool, frame: MenuMarkFrame) -> NSImage {
    let image = NSImage(size: NSSize(width: 22, height: 18), flipped: false) { _ in
        let ink: NSColor = colored ? .systemTeal : .black
        let center = NSPoint(x: 11, y: 8.2)
        for index in 0..<8 {
            let angle = Double(index) * .pi / 4
            let wave = (cos(angle - frame.rotation) + 1) / 2
            let strength = min(1, Double(frame.halo) * (0.35 + 0.65 * wave) + Double(frame.sparkle) * 0.8)
            guard strength > 0.02 else { continue }
            let ray = NSBezierPath()
            ray.move(to: NSPoint(x: center.x + CGFloat(cos(angle)) * 8.3,
                                 y: center.y + CGFloat(sin(angle)) * 6.4))
            ray.line(to: NSPoint(x: center.x + CGFloat(cos(angle)) * (9.0 + 1.3 * strength),
                                 y: center.y + CGFloat(sin(angle)) * (7.0 + 0.8 * strength)))
            ray.lineWidth = 1.1
            ray.lineCapStyle = .round
            ink.withAlphaComponent(strength).setStroke()
            ray.stroke()
        }
        ink.setStroke(); ink.setFill()
        let triangle = NSBezierPath()
        triangle.move(to: NSPoint(x: 11, y: 15.2))
        triangle.line(to: NSPoint(x: 18, y: 2.7))
        triangle.line(to: NSPoint(x: 4, y: 2.7))
        triangle.close(); triangle.lineWidth = 1.25; triangle.lineJoinStyle = .round
        triangle.stroke()
        let eyeCenter = NSPoint(x: 11 + frame.gazeX * 0.25, y: 7.4 + frame.gazeY * 0.2)
        let eye = NSBezierPath()
        let bulge = 2.9 * max(0.04, frame.openness)
        eye.move(to: NSPoint(x: eyeCenter.x - 4, y: eyeCenter.y))
        eye.curve(to: NSPoint(x: eyeCenter.x + 4, y: eyeCenter.y),
                  controlPoint1: NSPoint(x: eyeCenter.x - 2, y: eyeCenter.y + bulge),
                  controlPoint2: NSPoint(x: eyeCenter.x + 2, y: eyeCenter.y + bulge))
        eye.curve(to: NSPoint(x: eyeCenter.x - 4, y: eyeCenter.y),
                  controlPoint1: NSPoint(x: eyeCenter.x + 2, y: eyeCenter.y - bulge),
                  controlPoint2: NSPoint(x: eyeCenter.x - 2, y: eyeCenter.y - bulge))
        eye.close(); eye.lineWidth = 1; eye.stroke()
        if frame.openness > 0.12 {
            NSGraphicsContext.saveGraphicsState()
            eye.addClip()
            NSBezierPath(ovalIn: NSRect(x: eyeCenter.x + frame.gazeX * 1.25 - 1.3,
                                       y: eyeCenter.y + frame.gazeY * 0.9 - 1.3,
                                       width: 2.6, height: 2.6)).fill()
            NSGraphicsContext.restoreGraphicsState()
        }
        // A four-point glint at the upper right accompanies the idle and completion shimmer.
        if frame.sparkle > 0.02 {
            ink.withAlphaComponent(min(1, frame.sparkle)).setStroke()
            let glint = NSBezierPath()
            let radius = 0.7 + 1.2 * frame.sparkle
            glint.move(to: NSPoint(x: 19.6 - radius, y: 14.7))
            glint.line(to: NSPoint(x: 19.6 + radius, y: 14.7))
            glint.move(to: NSPoint(x: 19.6, y: 14.7 - radius))
            glint.line(to: NSPoint(x: 19.6, y: 14.7 + radius))
            glint.lineWidth = 1; glint.stroke()
        }
        return true
    }
    image.isTemplate = !colored
    image.accessibilityDescription = "AI Illuminati"
    return image
}
