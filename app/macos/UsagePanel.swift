import Cocoa
import Combine
import SwiftUI
import AIAccounts
import AILocalization
import AIRuntime
import AIChat

// The usage panel under the menu bar icon (it replaced the menu): the account cards or comparison rows, then the
// app's buttons. Resting on an account row opens its details beside it; resting on an AI's title, its color button.
// - Resting on the icon opens it, a click on the icon opens it at once; neither keeps it. It closes once the pointer
//   has been away from the icon and both panels for a moment, or on a click elsewhere (UsagePanelRules.swift).
// - Settings' preview opens it until a click elsewhere or Esc.
// Both panels are non-activating, so showing them never takes the keyboard from the app in front. A tracking area
// on the icon starts a 30 Hz check of the pointer, which runs only while the pointer is on the icon or the panel is open.

enum UsagePanelRow: Hashable {
    case account(String)
    case provider(Account.Provider)
}

enum UsagePanelAction {
    case approvals, chat, unloadLocal, installUpdate, settings, refresh, quit
    case color(Account.Provider)
}

/// What the panel shows; AppDelegate fills it whenever readings, approvals or updates change.
final class UsagePanelContent: ObservableObject {
    @Published var pending = 0
    @Published var checking = false
    @Published var shown: [AIUsage] = []
    @Published var style: AppModel.UsageMenuStyle = .cards
    @Published var local: String?      // the Ollama model in memory, one line
    @Published var update: String?     // update progress
    @Published var install: String?    // "Install New Version (…)"
    /// The row whose details show beside the panel.
    @Published var detail: UsagePanelRow?
    var rows: [UsagePanelRow: CGRect] = [:]
    var title: (AIUsage) -> String = { $0.name }
    var act: (UsagePanelAction) -> Void = { _ in }

    var width: CGFloat { style == .cards || shown.isEmpty ? MenuCardItem.width : ComparisonLayout.width }
    func usage(_ id: String) -> AIUsage? { shown.first { $0.account?.id == id } }
}

private struct UsageRowFrames: PreferenceKey {
    static let defaultValue: [UsagePanelRow: CGRect] = [:]
    static func reduce(value: inout [UsagePanelRow: CGRect], nextValue: () -> [UsagePanelRow: CGRect]) { value.merge(nextValue()) { $1 } }
}

struct UsagePanelView: View {
    static let space = "usagePanel"
    @ObservedObject var content: UsagePanelContent

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if content.pending > 0 {
                PanelLine(icon: "exclamationmark.circle.fill", tint: .orange,
                          text: L("허가 대기 \(content.pending)건…", "\(content.pending) Approval\(content.pending == 1 ? "" : "s") Waiting…")) { content.act(.approvals) }
                Divider().padding(.vertical, 4)
            }
            if content.checking {
                Text(L("확인 중…", "Checking…")).font(.system(size: 12)).foregroundColor(.secondary).padding(.horizontal, 14).padding(.vertical, 4)
            }
            if content.style == .cards {
                ForEach(Array(content.shown.enumerated()), id: \.offset) { i, usage in
                    if i > 0 { Divider().padding(.horizontal, 10) }
                    tracked(UsageCard(usage: usage, title: content.title(usage)), usage.account.map { .account($0.id) })
                }
                if !content.shown.isEmpty { UsageLegend() }
            } else if !content.shown.isEmpty {
                ComparisonHeader()
                ForEach(Account.Provider.allCases, id: \.self) { provider in
                    let group = content.shown.filter { $0.account?.provider == provider }
                    if !group.isEmpty {
                        tracked(ComparisonGroupTitle(provider: provider), .provider(provider))
                        ForEach(Array(group.enumerated()), id: \.offset) { _, usage in
                            tracked(ComparisonRow(usage: usage, style: content.style), usage.account.map { .account($0.id) })
                        }
                    }
                }
            }
            if let local = content.local {
                Divider().padding(.vertical, 4)
                Text(local).font(.system(size: 12)).foregroundColor(.secondary).padding(.horizontal, 14).padding(.vertical, 2)
                PanelLine(icon: "eject", text: L("로컬 모델 지금 내리기", "Unload Local Model Now")) { content.act(.unloadLocal) }
            }
            if content.update != nil || content.install != nil { Divider().padding(.vertical, 4) }
            if let update = content.update {
                Text(update).font(.system(size: 12)).foregroundColor(.secondary).padding(.horizontal, 14).padding(.vertical, 2)
            }
            if let install = content.install {
                PanelLine(icon: "arrow.down.circle", text: install) { content.act(.installUpdate) }
            }
            Divider().padding(.vertical, 6)
            VStack(spacing: 4) {
                HStack(spacing: 4) {
                    PanelButton(icon: "bubble.left.and.bubble.right", label: L("채팅창 열기", "Open Chat")) { content.act(.chat) }
                    PanelButton(icon: "gearshape", label: L("설정", "Settings")) { content.act(.settings) }
                }
                HStack(spacing: 4) {
                    PanelButton(icon: "arrow.clockwise", label: L("새로고침", "Refresh")) { content.act(.refresh) }
                    PanelButton(icon: "power", label: L("종료", "Quit")) { content.act(.quit) }
                }
            }
            .padding(.horizontal, 10)
        }
        .padding(.vertical, 8)
        .frame(width: content.width, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .coordinateSpace(name: Self.space)
        .onPreferenceChange(UsageRowFrames.self) { content.rows = $0 }
    }

    /// A row the pointer can rest on: its frame goes to the panel, and it is highlighted while its details show.
    @ViewBuilder private func tracked<V: View>(_ view: V, _ row: UsagePanelRow?) -> some View {
        if let row {
            view
                .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(content.detail == row ? 0.1 : 0)).padding(.horizontal, 5))
                .background(GeometryReader { geometry in
                    Color.clear.preference(key: UsageRowFrames.self, value: [row: geometry.frame(in: .named(Self.space))])
                })
        } else {
            view
        }
    }
}

/// Beside the panel: the account's details and its AI's color, or only the color for an AI's title.
struct UsageDetailView: View {
    @ObservedObject var content: UsagePanelContent
    let row: UsagePanelRow

    var body: some View {
        let usage: AIUsage? = { if case .account(let id) = row { return content.usage(id) } else { return nil } }()
        let provider: Account.Provider? = { if case .provider(let p) = row { return p } else { return usage?.account?.provider } }()
        VStack(alignment: .leading, spacing: 4) {
            if let usage {
                ForEach(Array(UsageDetail.lines(usage).enumerated()), id: \.offset) { i, line in
                    Text(line).font(.system(size: 12, weight: i == 0 ? .semibold : .regular))
                        .foregroundColor(i == 0 ? .primary : .secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if let provider {
                if usage != nil { Divider().padding(.vertical, 3) }
                Button { content.act(.color(provider)) } label: {
                    HStack(spacing: 6) {
                        Circle().fill(provider.color).frame(width: 10, height: 10)
                            .overlay(Circle().stroke(Color.primary.opacity(0.2)))
                        Text(AIColorWindow.menuTitle(provider)).font(.system(size: 12))
                        Spacer(minLength: 0)
                    }
                    .frame(minHeight: 22).contentShape(Rectangle())
                }.buttonStyle(.plainHit)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .frame(width: 300, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// A full-width line that does something (approvals waiting, unloading the local model, installing an update).
private struct PanelLine: View {
    let icon: String
    var tint: Color = .secondary
    let text: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 12)).foregroundColor(tint).frame(width: 16)
                Text(text).font(.system(size: 13))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 9).frame(minHeight: 24)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plainHit)
        .padding(.horizontal, 5)
    }
}

private struct PanelButton: View {
    let icon: String
    let label: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 11, weight: .medium))
                Text(label).font(.system(size: 12)).lineLimit(1)
            }
            .frame(maxWidth: .infinity).frame(height: 26)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.07)))
            .contentShape(RoundedRectangle(cornerRadius: 6))
        }.buttonStyle(.plainHit)
    }
}

final class UsagePanelWindow: NSPanel {
    override var canBecomeKey: Bool { false }
}

/// Buttons take the first click even while another app is in front.
final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

final class UsagePanel: NSResponder {
    /// The icon on screen; nil while it has none.
    var icon: () -> NSRect? = { nil }
    /// About to show: time for fresh readings.
    var willShow: () -> Void = {}
    var pointer: () -> NSPoint = { NSEvent.mouseLocation }
    var clock: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    var isShown: Bool { hover.shown }

    let content = UsagePanelContent()
    private var hover = UsagePanelHover()
    private let host: FirstClickHostingView<UsagePanelView>
    private let detailHost: FirstClickHostingView<UsageDetailView>
    private let panel: UsagePanelWindow
    private let detail: UsagePanelWindow
    private var timer: Timer?
    /// The row under the pointer that is not shown yet (nil: no row), and since when.
    private var pending: (row: UsagePanelRow?, since: TimeInterval)?
    private var monitors: [Any] = []
    private var changes: AnyCancellable?

    override init() {
        host = FirstClickHostingView(rootView: UsagePanelView(content: content))
        detailHost = FirstClickHostingView(rootView: UsageDetailView(content: content, row: .provider(.claude)))
        panel = Self.window(host)
        detail = Self.window(detailHost)
        super.init()
        // New readings, approvals or an update can change the size: the panel stays where it hangs.
        changes = content.objectWillChange.sink { [weak self] in DispatchQueue.main.async { self?.resize() } }
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    private static func window(_ content: NSView) -> UsagePanelWindow {
        let panel = UsagePanelWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 300), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.level = .popUpMenu
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        let effect = NSVisualEffectView()
        effect.material = .menu
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 10
        effect.layer?.masksToBounds = true
        content.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            content.topAnchor.constraint(equalTo: effect.topAnchor),
            content.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
        ])
        panel.contentView = effect
        return panel
    }

    // MARK: The pointer

    /// The icon's tracking area: the pointer arrived, so watch it until it leaves.
    override func mouseEntered(with event: NSEvent) { startTimer() }
    override func mouseExited(with event: NSEvent) {}

    private func startTimer() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in self?.tick() }
        timer.tolerance = 0.01
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        tick()
    }

    private func stopTimer() { timer?.invalidate(); timer = nil }

    private func tick() {
        guard let icon = icon() else { hide(); stopTimer(); return }
        let now = clock(), mouse = pointer()
        if hover.shown { follow(mouse, now) }
        // A held button or ⌘ (⌘-dragging the icon elsewhere) does not open it.
        let blocked = NSEvent.pressedMouseButtons != 0 || NSEvent.modifierFlags.contains(.command)
        switch hover.tick(now: now, mouse: mouse, icon: icon, panels: panelFrames, blocked: blocked) {
        case .open: show(pinned: false)
        case .close: hide()
        case .stop: stopTimer()
        case .wait: break
        }
    }

    private var panelFrames: [NSRect] { [panel.frame] + (detail.isVisible ? [detail.frame] : []) }

    /// The side panel follows the row under the pointer, and stays while the pointer is on it or off the panel.
    private func follow(_ mouse: NSPoint, _ now: TimeInterval) {
        guard !(detail.isVisible && detail.frame.contains(mouse)), panel.frame.contains(mouse) else { pending = nil; return }
        let row = row(at: mouse)
        if row == content.detail { pending = nil; return }
        if let pending, pending.row == row {
            if UsagePanelRules.due(pending.since, now, UsagePanelRules.switchDelay) { self.pending = nil; showDetail(row) }
        } else {
            pending = (row, now)
        }
    }

    /// Row frames come from SwiftUI, top-left based.
    private func row(at mouse: NSPoint) -> UsagePanelRow? {
        var point = host.convert(panel.convertPoint(fromScreen: mouse), from: nil)
        if !host.isFlipped { point.y = host.bounds.height - point.y }
        return content.rows.first { $0.value.insetBy(dx: 0, dy: -1).contains(point) }?.key
    }

    private func screenRect(of rect: CGRect) -> NSRect {
        var local = rect
        if !host.isFlipped { local.origin.y = host.bounds.height - rect.maxY }
        return panel.convertToScreen(host.convert(local, to: nil))
    }

    // MARK: Showing and hiding

    /// The status item's click: open at once; a click while it is open (often just after the rest opened it) leaves it.
    func click() {
        guard !hover.shown else { return }
        show(pinned: false)
    }

    /// Settings' preview: open until a click elsewhere or Esc, wherever the pointer is.
    func preview() {
        if hover.shown { hide() }
        show(pinned: true)
    }

    private func show(pinned: Bool) {
        guard let icon = icon() else { return }
        willShow()
        hover.opened(pinned: pinned)
        pending = nil
        content.detail = nil; detail.orderOut(nil)
        place(under: icon)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.08; panel.animator().alphaValue = 1 }
        watchClicks()
        startTimer()
    }

    func hide() {
        guard hover.shown else { return }
        hover.closed(pointerOnIcon: icon()?.contains(pointer()) == true)
        pending = nil
        monitors.forEach(NSEvent.removeMonitor); monitors = []
        content.detail = nil
        detail.orderOut(nil)
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.08; panel.animator().alphaValue = 0 }) { [weak self] in
            guard let self, !self.hover.shown else { return }
            self.panel.orderOut(nil)
        }
    }

    /// A click anywhere else closes the panel; one on the icon is the icon's own (see `click`). Esc closes the preview.
    private func watchClicks() {
        guard monitors.isEmpty else { return }
        let clicks: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: clicks, handler: { [weak self] _ in self?.hide() }) { monitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: clicks.union(.keyDown), handler: { [weak self] event in
            guard let self else { return event }
            if event.type == .keyDown {
                if event.keyCode == 53, self.hover.pinned { self.hide(); return nil }
                return event
            }
            if event.window === self.panel || event.window === self.detail || self.icon()?.contains(self.pointer()) == true { return event }
            self.hide()
            return event
        }) { monitors.append(local) }
    }

    private func screen(for icon: NSRect) -> NSRect {
        (NSScreen.screens.first { $0.frame.contains(NSPoint(x: icon.midX, y: icon.midY)) } ?? NSScreen.main)?.visibleFrame ?? .zero
    }

    private func place(under icon: NSRect) {
        host.rootView = UsagePanelView(content: content)
        host.layoutSubtreeIfNeeded()
        let frame = UsagePanelRules.panelFrame(size: host.fittingSize, icon: icon, screen: screen(for: icon))
        if frame != panel.frame { panel.setFrame(frame, display: true); panel.invalidateShadow() }
    }

    private func showDetail(_ row: UsagePanelRow?) {
        content.detail = row
        guard let row else { detail.orderOut(nil); return }
        detailHost.rootView = UsageDetailView(content: content, row: row)
        placeDetail()
        if content.detail != nil && !detail.isVisible { detail.orderFrontRegardless() }
    }

    private func placeDetail() {
        guard let row = content.detail, let rect = content.rows[row], let icon = icon() else {
            content.detail = nil; detail.orderOut(nil); return
        }
        detailHost.layoutSubtreeIfNeeded()
        let frame = UsagePanelRules.detailFrame(size: detailHost.fittingSize, panel: panel.frame, row: screenRect(of: rect), screen: screen(for: icon))
        if frame != detail.frame { detail.setFrame(frame, display: true); detail.invalidateShadow() }
    }

    func resize() {
        guard hover.shown, let icon = icon() else { return }
        place(under: icon)
        if content.detail != nil { placeDetail() }
    }
}
