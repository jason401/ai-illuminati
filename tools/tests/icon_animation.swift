import Cocoa

@main
struct IconAnimationCheck {
    static func main() throws {
        precondition(MenuMarkFrame.at(0.2, working: false).openness < 0.05)
        precondition(MenuMarkFrame.at(1, working: false).openness == 1)
        precondition(MenuMarkFrame.at(4.7, working: false).gazeX < -0.9)
        precondition(MenuMarkFrame.at(8.7, working: false).gazeY > 0.7)
        precondition(MenuMarkFrame.at(12.7, working: false).gazeX > 0.9)
        precondition(MenuMarkFrame.at(16.7, working: false).gazeY < -0.7)
        precondition(MenuMarkFrame.at(2, working: true).halo > 0)
        precondition(MenuMarkFrame.at(2, working: true).rotation != MenuMarkFrame.at(3, working: true).rotation)
        precondition(MenuMarkFrame.at(20, working: false, completionAge: 0.7).sparkle > 0.99)
        precondition(MenuMarkFrame.at(20, working: false, completionAge: 2).sparkle == 0)
        // Idle frames in a quiet hold are identical, so the ticker can skip redraws.
        precondition(MenuMarkFrame.at(5.2, working: false) == MenuMarkFrame.at(5.3, working: false))
        for working in [false, true] {
            let period = working ? 3.0 : 5.0
            for t in [0.0, 0.2, period - 0.2, period, period + 0.2] {
                let dark = MenuMarkFrame.at(t, working: working)
                precondition(dark.halo == 0 && dark.sparkle == 0, "Halo must fully disappear")
            }
            precondition(MenuMarkFrame.at(period / 2, working: working).halo > 0.99)
        }
        let levels: [Double?] = [0, 99, 60, 100, nil]
        let colors: [NSColor] = [.systemOrange, .systemOrange, .systemGreen, .systemGreen, .systemBlue]
        let frames = [MenuMarkFrame(), MenuMarkFrame(gazeX: -1), MenuMarkFrame(gazeY: 0.8),
                      MenuMarkFrame(gazeX: 1), MenuMarkFrame(gazeY: -0.8),
                      MenuMarkFrame(openness: 0), MenuMarkFrame.at(3, working: true),
                      MenuMarkFrame.at(20, working: false, completionAge: 0.7)]
        for frame in frames {
            let mono = illuminatiIcon(frame: frame), color = illuminatiIcon(colored: true, frame: frame)
            precondition(mono.isTemplate && !color.isTemplate)
            precondition(mono.size == NSSize(width: 22, height: 18))
            precondition(meterIcon(levels: levels, mark: true, frame: frame).size.width == 38)
            precondition(meterIcon(levels: levels, mark: false, colors: colors, frame: frame).size.width == 17)
            precondition(mono.tiffRepresentation != nil && color.tiffRepresentation != nil)
        }
        precondition(illuminatiIcon().size.width == 18)
        // Optional offline contact sheet: no windows, input events, accounts or AI calls.
        if CommandLine.arguments.count > 1 {
            let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 640, pixelsHigh: 160,
                                      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                      isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            NSColor.white.setFill(); NSRect(x: 0, y: 0, width: 640, height: 160).fill()
            for (i, frame) in frames.enumerated() {
                illuminatiIcon(frame: frame).draw(in: NSRect(x: i * 80 + 7, y: 86, width: 66, height: 54))
                illuminatiIcon(colored: true, frame: frame).draw(in: NSRect(x: i * 80 + 7, y: 16, width: 66, height: 54))
            }
            try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
        }
        print("PASS: eye blink, four gaze directions, working halo, completion shimmer, idle holds, template colors and stable icon/bar geometry")
    }
}
