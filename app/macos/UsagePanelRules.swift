import Cocoa

// When the usage panel under the menu bar icon opens and closes (UsagePanel.swift shows it), as plain values so
// the icon check (tools/tests/usage_panel_rules.swift) can run them with its own pointer and clock.
// The same rules as Cats in Menubar's panel (DashboardPanel.swift there): resting on the icon opens it, being away
// from the icon and the panels for a moment closes it. A click on the icon opens it at once and does not keep it.

enum UsagePanelRules {
    /// Resting this long on the icon opens the panel; passing over it on the way across the menu bar does not.
    static let openDelay: TimeInterval = 0.15
    /// Away from the icon and the panels this long closes the panel.
    static let closeDelay: TimeInterval = 0.35
    /// On another row this long changes the side panel, so crossing rows on the way to it does not.
    static let switchDelay: TimeInterval = 0.06
    /// How far around the icon and the panels still counts as being on them; it also bridges the gaps between them.
    static let iconSlack: CGFloat = 2, panelSlack: CGFloat = 12
    /// The panel hangs this far below the icon, the side panel this far from it, both this far from screen edges.
    static let drop: CGFloat = 6, gap: CGFloat = 6, margin: CGFloat = 8
    /// Opening the panel reads usage again only when the last reading started this long ago (the 60 s timer keeps it fresh).
    static let staleAfter: TimeInterval = 30

    static func near(_ mouse: NSPoint, icon: NSRect, panels: [NSRect]) -> Bool {
        icon.insetBy(dx: -iconSlack, dy: -iconSlack).contains(mouse) || panels.contains { $0.insetBy(dx: -panelSlack, dy: -panelSlack).contains(mouse) }
    }

    static func due(_ since: TimeInterval?, _ now: TimeInterval, _ delay: TimeInterval) -> Bool {
        guard let since else { return false }
        return now - since >= delay - 1e-6   // clock steps are not exact in binary
    }

    static func stale(lastRead: TimeInterval?, now: TimeInterval) -> Bool {
        guard let lastRead else { return true }
        return now - lastRead >= staleAfter
    }

    /// Centered under the icon, kept on screen.
    static func panelFrame(size: NSSize, icon: NSRect, screen: NSRect) -> NSRect {
        let x = max(screen.minX + margin, min(icon.midX - size.width / 2, screen.maxX - margin - size.width))
        return NSRect(x: x, y: icon.minY - drop - size.height, width: size.width, height: size.height)
    }

    /// Level with its row, on the left where status icons usually leave room, else on the right.
    static func detailFrame(size: NSSize, panel: NSRect, row: NSRect, screen: NSRect) -> NSRect {
        let left = panel.minX - gap - size.width, right = panel.maxX + gap
        let x = left >= screen.minX + margin || right + size.width > screen.maxX - margin ? max(screen.minX + margin, left) : right
        let top = min(row.maxY, panel.maxY, screen.maxY)
        return NSRect(x: x, y: max(screen.minY + margin, top - size.height), width: size.width, height: size.height)
    }
}

/// The pointer's side of the panel: fed the pointer and the clock about 30 times a second while the pointer is on
/// the icon or the panel is open, it says what to do.
struct UsagePanelHover {
    enum Step: Equatable { case wait, open, close, stop }
    private(set) var shown = false
    /// Kept open until a click elsewhere (Settings' preview), whatever the pointer does.
    private(set) var pinned = false
    private var restingSince: TimeInterval?
    private var outsideSince: TimeInterval?
    /// Closed while the pointer was on the icon: it opens again only after leaving.
    private var waitForExit = false

    /// `blocked`: a mouse button or ⌘ is down (⌘-dragging the icon), so a rest does not open it.
    mutating func tick(now: TimeInterval, mouse: NSPoint, icon: NSRect, panels: [NSRect], blocked: Bool) -> Step {
        guard shown else {
            guard icon.contains(mouse) else { waitForExit = false; restingSince = nil; return .stop }
            guard !waitForExit, !blocked else { restingSince = nil; return .wait }
            if restingSince == nil { restingSince = now }
            return UsagePanelRules.due(restingSince, now, UsagePanelRules.openDelay) ? .open : .wait
        }
        guard !pinned else { return .wait }
        if UsagePanelRules.near(mouse, icon: icon, panels: panels) {
            outsideSince = nil
        } else if outsideSince == nil {
            outsideSince = now
        } else if UsagePanelRules.due(outsideSince, now, UsagePanelRules.closeDelay) {
            return .close
        }
        return .wait
    }

    mutating func opened(pinned: Bool = false) {
        shown = true
        self.pinned = pinned
        restingSince = nil; outsideSince = nil
    }

    mutating func closed(pointerOnIcon: Bool) {
        shown = false; pinned = false
        restingSince = nil; outsideSince = nil
        waitForExit = pointerOnIcon
    }
}
