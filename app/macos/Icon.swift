import Cocoa

// Warm gold stays readable on both light and dark menu bars.
private let illuminatiGold = NSColor(name: nil) { appearance in
    appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        ? NSColor(srgbRed: 1, green: 0.9, blue: 0.6, alpha: 1)
        : NSColor(srgbRed: 0.64, green: 0.35, blue: 0.04, alpha: 1)
}
private let illuminatiLight = NSColor(srgbRed: 1, green: 0.67, blue: 0.12, alpha: 1)

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
        // A complete dark hold, then a smooth rise to full light and back to zero.
        let period = working ? 3.0 : 5.0
        let darkHold = working ? 0.4 : 1.0
        let phase = t.truncatingRemainder(dividingBy: period)
        let pulse = phase > darkHold && phase < period - darkHold
            ? pow(sin((phase - darkHold) / (period - darkHold * 2) * .pi), 2) : 0
        let finish = completionAge.map { $0 >= 0 && $0 < 1.4 ? sin($0 / 1.4 * .pi) : 0 } ?? 0
        return Self(gazeX: CGFloat(previous.0 + (target.0 - previous.0) * ease),
                    gazeY: CGFloat(previous.1 + (target.1 - previous.1) * ease),
                    openness: CGFloat(blink),
                    halo: CGFloat(pulse),
                    rotation: working ? t * 1.6 : 0,
                    sparkle: CGFloat(finish))
    }
}

// The menu bar mark: an eye inside a triangle, drawn in code (18 x 18 points).
// Monochrome uses a template image; color mode keeps the warm gold mark.
func illuminatiIcon(colored: Bool = false, frame: MenuMarkFrame? = nil) -> NSImage {
    if let frame { return animatedIlluminatiIcon(colored: colored, frame: frame) }
    let size = NSSize(width: 18, height: 18)
    let image = NSImage(size: size, flipped: false) { _ in
        let ink: NSColor = colored ? illuminatiGold : .black
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


// A soft radial fan shines from behind the triangle; the eye itself remains unobscured.
private func animatedIlluminatiIcon(colored: Bool, frame: MenuMarkFrame) -> NSImage {
    let image = NSImage(size: NSSize(width: 22, height: 18), flipped: false) { _ in
        let ink: NSColor = colored ? illuminatiGold : .black
        let center = NSPoint(x: 11, y: 8.2)
        let triangleMask = NSBezierPath()
        triangleMask.move(to: NSPoint(x: 11, y: 15.2))
        triangleMask.line(to: NSPoint(x: 18, y: 2.7))
        triangleMask.line(to: NSPoint(x: 4, y: 2.7))
        triangleMask.close()
        let strength = min(1, frame.halo + frame.sparkle * 0.8)
        if strength > 0.02 {
            NSGraphicsContext.saveGraphicsState()
            let outside = NSBezierPath(rect: NSRect(x: 0, y: 0, width: 22, height: 18))
            outside.append(triangleMask)
            outside.windingRule = .evenOdd
            outside.addClip()
            let light: NSColor = colored ? illuminatiLight : .black
            let haze = NSBezierPath(ovalIn: NSRect(x: 0.4, y: 0.2, width: 21.2, height: 17.4))
            NSGradient(starting: light.withAlphaComponent(strength * 0.65),
                       ending: light.withAlphaComponent(0))?.draw(in: haze, relativeCenterPosition: .zero)
            // Many tapered rays, fading outward. Positions stay fixed; only their light shimmers.
            for index in 0..<28 {
                let angle = Double(index) * 2 * .pi / 28
                let shimmer = 0.75 + 0.25 * cos(angle * 3 - frame.rotation)
                for segment in 0..<7 {
                    let near = Double(segment) / 7, far = Double(segment + 1) / 7
                    let ray = NSBezierPath()
                    ray.move(to: NSPoint(x: center.x + CGFloat(cos(angle) * (2.5 + near * 8)),
                                         y: center.y + CGFloat(sin(angle) * (2 + near * 6.6))))
                    ray.line(to: NSPoint(x: center.x + CGFloat(cos(angle) * (2.5 + far * 8)),
                                         y: center.y + CGFloat(sin(angle) * (2 + far * 6.6))))
                    ray.lineWidth = CGFloat(1.05 - near * 0.35)
                    light.withAlphaComponent(min(1, Double(strength) * 1.25 * shimmer * pow(1 - near, 0.45))).setStroke()
                    ray.stroke()
                }
            }
            NSGraphicsContext.restoreGraphicsState()
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
        return true
    }
    image.isTemplate = !colored
    image.accessibilityDescription = "AI Illuminati"
    return image
}
