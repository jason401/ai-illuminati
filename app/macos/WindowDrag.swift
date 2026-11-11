import Cocoa
import SwiftUI

// Empty header areas move the window with macOS's own drag (performDrag), so edge tiling and
// Mission Control work like other apps. The chat title bar must NOT be transparent: with
// titlebarAppearsTransparent, macOS (27) makes a dragged window jump hundreds of points as the
// pointer crosses to another display (measured 2026-11-06 with test windows; opaque title bars do not jump).
// Never put a drag view of ours inside the title bar (the window's frame view): performDrag started there
// jumps the same way. The title bar drags natively; WindowDragRegion is only for empty spots below it.
enum WindowDoubleClickAction {
    case zoom, minimize, none, fill
    static func resolve(_ preference: String?, legacyMinimize: Bool = false) -> Self {
        switch preference?.lowercased() {
        case "minimize": return .minimize
        case "none", "nothing": return .none
        case "fill": return .fill
        case "maximize", "zoom": return .zoom
        default: return legacyMinimize ? .minimize : .zoom
        }
    }
    static var system: Self {
        resolve(UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick"),
                legacyMinimize: UserDefaults.standard.bool(forKey: "AppleMiniaturizeOnDoubleClick"))
    }
}

class ChatDragWindow: NSWindow {
    private var beforeFill: NSRect?
    // NSHostingView with sizingOptions = [] writes its (zero) minimum here on every constraint pass,
    // which let the chat shrink without limit. Never go below this floor.
    var minimumContentSize = NSSize.zero { didSet { contentMinSize = super.contentMinSize } }
    override var contentMinSize: NSSize {
        get { super.contentMinSize }
        set { super.contentMinSize = NSSize(width: max(newValue.width, minimumContentSize.width),
                                            height: max(newValue.height, minimumContentSize.height)) }
    }
    func performTitlebarAction(_ action: WindowDoubleClickAction) {
        switch action {
        case .none: break
        case .minimize: performMiniaturize(nil)
        case .zoom: performZoom(nil)
        case .fill:
            guard let area = screen?.visibleFrame else { return }
            if let previous = beforeFill, frame.equalTo(area) {
                beforeFill = nil; setFrame(previous, display: true)
            } else {
                beforeFill = frame; setFrame(area, display: true)
            }
        }
    }
}

final class WindowDragView: NSView {
    var doubleClickAction: () -> WindowDoubleClickAction = { .system }
    var startDrag: (NSWindow, NSEvent) -> Void = { $0.performDrag(with: $1) }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        guard let window, !window.styleMask.contains(.fullScreen) else { return }
        if event.clickCount == 2 {
            if let chat = window as? ChatDragWindow { chat.performTitlebarAction(doubleClickAction()) }
            else {
                switch doubleClickAction() {
                case .minimize: window.performMiniaturize(nil)
                case .zoom, .fill: window.performZoom(nil)
                case .none: break
                }
            }
        } else {
            startDrag(window, event)
        }
    }
}

// Only insert this in dedicated empty slots. Never place it behind a whole SwiftUI header with buttons.
struct WindowDragRegion: NSViewRepresentable {
    func makeNSView(context: Context) -> WindowDragView { WindowDragView() }
    func updateNSView(_ nsView: WindowDragView, context: Context) {}
}
