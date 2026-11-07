import Cocoa
import SwiftUI

// Empty header areas move the window with macOS's own drag (performDrag), so edge tiling and
// Mission Control work like other apps. The chat title bar must NOT be transparent: with
// titlebarAppearsTransparent, macOS (27) makes a dragged window jump hundreds of points as the
// pointer crosses to another display (measured 2026-11-06 with test windows; opaque title bars do not jump).
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

// A non-interactive SwiftUI background installs a transparent drag strip in the native title bar.
// It excludes the traffic lights and outer resize edges, without changing the content or title-bar style.
struct WindowTitlebarDragBridge: NSViewRepresentable {
    func makeNSView(context: Context) -> TitlebarDragBridgeView { TitlebarDragBridgeView() }
    func updateNSView(_ nsView: TitlebarDragBridgeView, context: Context) { nsView.positionStrip() }
    static func dismantleNSView(_ nsView: TitlebarDragBridgeView, coordinator: ()) { nsView.detach() }
}

final class TitlebarDragBridgeView: NSView {
    private var strip: WindowDragView?
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        detach()
        if let frameView = window?.contentView?.superview {
            let drag = WindowDragView()
            drag.autoresizingMask = [.width, .minYMargin]
            frameView.addSubview(drag, positioned: .above, relativeTo: nil)
            strip = drag
            positionStrip()
            DispatchQueue.main.async { [weak self] in self?.positionStrip() }
        }
    }
    override func layout() { super.layout(); positionStrip() }
    override func setFrameSize(_ newSize: NSSize) { super.setFrameSize(newSize); positionStrip() }
    func detach() { strip?.removeFromSuperview(); strip = nil }
    func positionStrip() {
        guard let strip, let window, let frameView = strip.superview else { return }
        strip.isHidden = window.styleMask.contains(.fullScreen)
        var left: CGFloat = 80
        for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            if let button = window.standardWindowButton(kind) { left = max(left, button.convert(button.bounds, to: frameView).maxX + 8) }
        }
        let topOfContent = window.contentLayoutRect.maxY
        strip.frame = NSRect(x: left, y: topOfContent, width: max(0, frameView.bounds.width - left - 6),
                             height: max(0, frameView.bounds.maxY - topOfContent - 4))
    }
}
