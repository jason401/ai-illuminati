import Cocoa

// The usage panel's open and close rules (app/macos/UsagePanelRules.swift), with a pretend pointer and clock.
@main
struct UsagePanelRulesCheck {
    static func expect(_ ok: Bool, _ what: String) {
        guard ok else { print("FAIL: usage panel: \(what)"); exit(1) }
    }

    static func main() {
        typealias R = UsagePanelRules
        expect(R.openDelay == 0.15 && R.closeDelay == 0.35 && R.switchDelay == 0.06, "open after 0.15 s, close after 0.35 s, change rows after 0.06 s")
        expect(!R.due(nil, 10, R.openDelay) && !R.due(10, 10.14, R.openDelay) && R.due(10, 10.15, R.openDelay), "the wait counts from when it began")
        expect(R.stale(lastRead: nil, now: 5) && !R.stale(lastRead: 100, now: 129) && R.stale(lastRead: 100, now: 130), "reads again after 30 s")

        let icon = NSRect(x: 1000, y: 870, width: 24, height: 24)
        let screen = NSRect(x: 0, y: 0, width: 1440, height: 870)
        let panel = R.panelFrame(size: NSSize(width: 420, height: 300), icon: icon, screen: screen)
        expect(panel.maxY == icon.minY - R.drop && abs(panel.midX - icon.midX) < 0.5, "the panel hangs centered under the icon")
        let edge = R.panelFrame(size: NSSize(width: 420, height: 300), icon: NSRect(x: 1420, y: 870, width: 20, height: 24), screen: screen)
        expect(edge.maxX == screen.maxX - R.margin, "the panel stays on screen at the right edge")
        let row = NSRect(x: panel.minX, y: panel.maxY - 80, width: panel.width, height: 60)
        let detail = R.detailFrame(size: NSSize(width: 260, height: 120), panel: panel, row: row, screen: screen)
        expect(detail.maxX == panel.minX - R.gap && detail.maxY == row.maxY, "the side panel is left of the panel, level with its row")
        let leftEdge = R.panelFrame(size: NSSize(width: 420, height: 300), icon: NSRect(x: 100, y: 870, width: 24, height: 24), screen: screen)
        let right = R.detailFrame(size: NSSize(width: 260, height: 120), panel: leftEdge, row: leftEdge, screen: screen)
        expect(right.minX == leftEdge.maxX + R.gap, "no room on the left: the side panel goes right")
        expect(R.near(NSPoint(x: panel.midX, y: panel.maxY + 5), icon: icon, panels: [panel]), "the gap under the icon counts as near")

        let on = NSPoint(x: icon.midX, y: icon.midY), away = NSPoint(x: 200, y: 200)
        var hover = UsagePanelHover()
        func tick(_ t: TimeInterval, _ mouse: NSPoint, blocked: Bool = false) -> UsagePanelHover.Step {
            hover.tick(now: t, mouse: mouse, icon: icon, panels: hover.shown ? [panel] : [], blocked: blocked)
        }
        expect(tick(0, away) == .stop, "pointer off the icon: the check stops")
        expect(tick(1, on) == .wait && tick(1.1, on) == .wait && tick(1.15, on) == .open, "a rest of 0.15 s opens it")
        hover = UsagePanelHover()
        expect(tick(1.5, on) == .wait && tick(1.6, away) == .stop && tick(1.7, on) == .wait, "passing over does not open it")
        hover = UsagePanelHover()
        expect(tick(2, on, blocked: true) == .wait && tick(2.3, on, blocked: true) == .wait, "a held button or ⌘ does not open it")
        expect(tick(2.4, on) == .wait && tick(2.55, on) == .open, "the rest counts from when the block ended")
        hover.opened()
        let inside = NSPoint(x: panel.midX, y: panel.midY)
        expect(tick(3, inside) == .wait && tick(10, inside) == .wait, "on the panel it stays")
        expect(tick(11, away) == .wait && tick(11.3, away) == .wait && tick(11.35, away) == .close, "away 0.35 s closes it")
        hover.closed(pointerOnIcon: false)
        hover.opened()
        expect(tick(20, away) == .wait && tick(20.2, inside) == .wait && tick(20.5, away) == .wait && tick(20.8, away) == .wait,
               "coming back in time keeps it")
        hover.closed(pointerOnIcon: true)
        expect(tick(30, on) == .wait && tick(31, on) == .wait, "closed on the icon: no new open until the pointer leaves")
        expect(tick(31.1, away) == .stop && tick(32, on) == .wait && tick(32.15, on) == .open, "after leaving, a rest opens it again")
        hover.opened(pinned: true)
        expect(tick(40, away) == .wait && tick(50, away) == .wait, "the Settings preview stays until a click elsewhere")
        hover.closed(pointerOnIcon: false)
        expect(!hover.shown && !hover.pinned, "closing forgets the preview")
        print("ok: usage panel rules")
    }
}
