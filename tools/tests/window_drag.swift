import Cocoa

private final class DragProbeWindow: ChatDragWindow {
    var zooms = 0, minimizes = 0
    override func performZoom(_ sender: Any?) { zooms += 1 }
    override func performMiniaturize(_ sender: Any?) { minimizes += 1 }
}

func testWindowDrag() {
    _ = NSApplication.shared
    let window = DragProbeWindow(contentRect: NSRect(x: 200, y: 200, width: 820, height: 520),
                                 styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                 backing: .buffered, defer: false)
    window.isMovable = false
    window.titlebarAppearsTransparent = true
    window.titleVisibility = .hidden
    let content = NSView(frame: NSRect(x: 0, y: 0, width: 820, height: 520))
    window.contentView = content
    let drag = WindowDragView(frame: NSRect(x: 100, y: 300, width: 200, height: 30))
    content.addSubview(drag)
    var pointer = NSPoint(x: 1850, y: 600)
    drag.mousePosition = { pointer }
    func event(_ kind: NSEvent.EventType, _ clicks: Int = 1, local: NSPoint = .zero) -> NSEvent {
        NSEvent.mouseEvent(with: kind, location: local, modifierFlags: [], timestamp: 0,
                          windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: clicks, pressure: 1)!
    }
    let initial = window.frame.origin
    drag.mouseDown(with: event(.leftMouseDown, local: NSPoint(x: 800, y: 500)))
    pointer = NSPoint(x: 1950, y: 610)
    drag.mouseDragged(with: event(.leftMouseDragged, local: NSPoint(x: 2, y: 5)))
    expect(window.frame.origin == NSPoint(x: initial.x + 100, y: initial.y + 10), "manual drag follows global pointer delta, not changing per-window event coordinates")
    pointer = NSPoint(x: -300, y: -120)
    drag.mouseDragged(with: event(.leftMouseDragged))
    expect(window.frame.origin == NSPoint(x: initial.x - 2150, y: initial.y - 720), "manual drag remains anchored across negative display coordinates")
    drag.mouseUp(with: event(.leftMouseUp))
    let released = window.frame.origin
    pointer = .zero; drag.mouseDragged(with: event(.leftMouseDragged))
    expect(window.frame.origin == released, "mouse-up ends the drag")
    window.setFrameOrigin(initial)
    drag.doubleClickAction = { .zoom }; drag.mouseDown(with: event(.leftMouseDown, 2))
    drag.doubleClickAction = { .minimize }; drag.mouseDown(with: event(.leftMouseDown, 2))
    drag.doubleClickAction = { .none }; drag.mouseDown(with: event(.leftMouseDown, 2))
    expect(window.zooms == 1 && window.minimizes == 1 && window.frame.origin == initial, "empty-area double-click respects zoom/minimize/no-action without starting a drag")
    expect(WindowDoubleClickAction.resolve("Maximize") == .zoom && WindowDoubleClickAction.resolve("Minimize") == .minimize && WindowDoubleClickAction.resolve("None") == .none && WindowDoubleClickAction.resolve("Fill") == .fill && WindowDoubleClickAction.resolve(nil, legacyMinimize: true) == .minimize, "system preference values and legacy fallback")
    expect(drag.acceptsFirstMouse(for: nil) && !drag.mouseDownCanMoveWindow, "manual drag accepts inactive-window clicks and never invokes native dragging")
    let bridge = TitlebarDragBridgeView(frame: content.bounds)
    content.addSubview(bridge, positioned: .below, relativeTo: nil)
    bridge.positionStrip()
    let frame = window.contentView!.superview!
    let strip = frame.subviews.compactMap { $0 as? WindowDragView }.first!
    expect(strip.frame.height > 0 && strip.frame.maxX <= frame.bounds.maxX - 5, "native title-bar strip leaves outer resize edge free")
    for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
        let button = window.standardWindowButton(kind)!
        let rect = button.convert(button.bounds, to: frame)
        expect(!strip.frame.intersects(rect), "title-bar drag strip never covers a traffic-light button")
        let hit = frame.hitTest(NSPoint(x: rect.midX, y: rect.midY))
        expect(hit === button || hit?.isDescendant(of: button) == true, "traffic-light hit testing remains native")
    }
    let hit = frame.hitTest(NSPoint(x: strip.frame.midX, y: strip.frame.midY))
    expect(hit === strip, "native title-bar blank space reaches the manual drag view")
    expect(bridge.hitTest(NSPoint(x: 120, y: 200)) == nil, "SwiftUI background bridge cannot consume content-button clicks")
    expect(window.styleMask.contains(.resizable) && !window.isMovable, "resize remains enabled while native movement is disabled")
    bridge.detach()
    expect(!frame.subviews.contains { $0 === strip }, "title-bar strip removed when bridge is dismantled")
    print("PASS: manual window drag (global coordinates, release, double-click preferences, native traffic lights and resize edges)")
}
