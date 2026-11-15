import Cocoa
import SwiftUI
import AIAccounts
import AILocalization

// One small window for an AI's color, opened from "<AI> 색 바꾸기…" on its name (chat labels, the participant
// chips, the usage menu) and from Settings > Appearance. There is only one: opening it for another AI switches it.
// Every choice applies at once (AIColors.set), so the chat, the menu and the sidebar show it while choosing.
public enum AIColorWindow {
    private static var panel: ColorPanelWindow?

    public static func show(_ provider: Account.Provider, in defaults: UserDefaults = .standard) {
        let window = panel ?? ColorPanelWindow()
        panel = window
        window.show(provider, defaults: defaults)
    }

    // The right-click entry, the same words wherever an AI's name is.
    public static func menuTitle(_ provider: Account.Provider) -> String {
        L("\(provider.title) 색 바꾸기…", "Change \(provider.title) Color…")
    }
}

extension View {
    // Right-click on an AI's name: "<AI> 색 바꾸기…" opens the color window. Nothing when the speaker is not an AI.
    func aiColorMenu(_ provider: Account.Provider?) -> some View {
        contextMenu {
            if let provider { Button(AIColorWindow.menuTitle(provider)) { AIColorWindow.show(provider) } }
        }
    }
}

private final class ColorPanelWindow: NSPanel {
    private var provider: Account.Provider = .claude
    private var defaults: UserDefaults = .standard
    private var host: NSHostingView<AIColorView>?

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 320, height: 300), styleMask: [.titled, .closable],
                   backing: .buffered, defer: true)
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        center()
    }

    func show(_ provider: Account.Provider, defaults: UserDefaults) {
        self.provider = provider; self.defaults = defaults
        title = L("\(provider.title) 색", "\(provider.title) Color")
        let view = AIColorView(provider: provider, defaults: defaults, openOther: { [weak self] in self?.openColorPanel() },
                               done: { [weak self] in self?.close() })
        if let host { host.rootView = view } else {
            let host = NSHostingView(rootView: view)
            host.frame = NSRect(x: 0, y: 0, width: 320, height: 300)
            contentView = host
            self.host = host
        }
        setContentSize(NSSize(width: 320, height: 300))
        if editing != nil, NSColorPanel.shared.isVisible { openColorPanel(front: false) }   // follow the new AI
        NSApp.activate(ignoringOtherApps: true)
        makeKeyAndOrderFront(nil)
    }

    override func cancelOperation(_ sender: Any?) { close() }   // Esc

    override func close() {
        if editing != nil {   // the color panel opened from here goes too: left open it would change nothing
            let panel = NSColorPanel.shared
            panel.setTarget(nil); panel.setAction(nil); panel.orderOut(nil)
            editing = nil
        }
        super.close()
    }

    // "Other color…": the system color panel; every change applies at once.
    private var editing: Account.Provider?

    private func openColorPanel(front: Bool = true) {
        editing = provider
        let panel = NSColorPanel.shared
        panel.setTarget(nil); panel.setAction(nil)   // setting the color below must not save it to the AI before
        panel.showsAlpha = false
        panel.color = AIColors.color(provider, in: defaults).usingColorSpace(.sRGB) ?? .gray   // as it looks now
        panel.title = title
        panel.setTarget(self)
        panel.setAction(#selector(colorChanged(_:)))
        if front { panel.makeKeyAndOrderFront(nil) }
    }

    @objc private func colorChanged(_ panel: NSColorPanel) {
        guard let editing else { return }
        AIColors.set(custom: panel.color, for: editing, in: defaults)
    }
}

private struct AIColorView: View {
    let provider: Account.Provider
    let defaults: UserDefaults
    let openOther: () -> Void
    let done: () -> Void
    @AppStorage private var revision: Int   // redraw when a color changes here, in the color panel or elsewhere

    init(provider: Account.Provider, defaults: UserDefaults, openOther: @escaping () -> Void, done: @escaping () -> Void) {
        self.provider = provider; self.defaults = defaults; self.openOther = openOther; self.done = done
        _revision = AppStorage(wrappedValue: 0, AIColors.revisionKey, store: defaults)
    }

    private var current: String { AIColors.saved(provider, in: defaults) ?? AIColors.brand(provider).id }

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 8) {
                Circle().fill(Color(nsColor: AIColors.color(provider, in: defaults))).frame(width: 10, height: 10)
                Text(provider.title).font(.system(size: 20, weight: .semibold))
                    .foregroundColor(Color(nsColor: AIColors.color(provider, in: defaults)))
            }
            .frame(maxWidth: .infinity, minHeight: 40)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 5), spacing: 6) {
                ForEach(AIColors.presets, id: \.id) { swatch($0) }
            }
            Spacer(minLength: 0)
            HStack(spacing: 8) {
                Button(L("다른 색…", "Other Color…"), action: openOther)
                Button(L("기본 색으로", "Use Default")) { AIColors.set(nil, for: provider, in: defaults) }
                    .disabled(AIColors.saved(provider, in: defaults) == nil)
                Spacer(minLength: 0)
                Button(L("완료", "Done"), action: done).keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 320, height: 300)
        .id(revision)
    }

    private func swatch(_ preset: AIColors.Preset) -> some View {
        let brand = preset.id == AIColors.brand(provider).id
        let selected = current == preset.id
        let others = AIColors.sharing(preset.id, besides: provider, in: defaults)
        return Button { AIColors.set(brand ? nil : preset.id, for: provider, in: defaults) } label: {
            VStack(spacing: 2) {
                Circle().fill(Color(nsColor: preset.color)).frame(width: 22, height: 22)
                    .overlay(Circle().strokeBorder(Color.primary.opacity(selected ? 0.9 : 0.12), lineWidth: selected ? 2 : 1).padding(-3))
                    .padding(.vertical, 4)
                Text(preset.name).font(.system(size: 11)).lineLimit(1)
                Text(brand ? L("(기본)", "(default)") : " ").font(.system(size: 9)).foregroundColor(.secondary).lineLimit(1)
                // Another AI already wears it: its name, so two AIs are not given the same color by accident.
                Text(others.isEmpty ? " " : others.map(\.title).joined(separator: ", "))
                    .font(.system(size: 9)).foregroundColor(.secondary).lineLimit(1).truncationMode(.tail)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 3)
            .background(selected ? Color.accentColor.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plainHit)
        .help(preset.name + (brand ? L(" (기본)", " (default)") : "") + others.map { " · " + $0.title }.joined())
        .accessibilityLabel(preset.name + (selected ? L(", 선택됨", ", selected") : ""))
    }
}
