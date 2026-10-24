import Cocoa
import Combine

// AI Illuminati: a menu bar gauge that shows how much of each AI subscription is left
// (5-hour and weekly limits) and when each one resets, for any number of Claude and ChatGPT
// accounts. Uses each tool's own login (subscription), never API keys.
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private let work = DispatchQueue(label: "usage")
    private let model = AppModel()
    private let settings = SettingsWindow()
    private let chat = ChatWindow()
    private lazy var discussion = Discussion(model: model)
    private var accounts: [Account] { model.accounts }
    private var usages: [AIUsage] = []
    private var timer: Timer?

    private var markTimer: Timer?
    private var runningObservation: AnyCancellable?
    private var motionObservation: NSObjectProtocol?
    private var iconRenderer: ((MenuMarkFrame?) -> NSImage)?
    private var lastMarkFrame: MenuMarkFrame?
    private let markStartedAt = ProcessInfo.processInfo.systemUptime
    private var markWorking = false
    private var markCompletedAt: TimeInterval?

    private func configureMarkAnimation() {
        markTimer?.invalidate()
        markTimer = nil
        lastMarkFrame = nil
        guard model.menuBarAnimation, model.menuBarStyle != .bars,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            item.button?.image = iconRenderer?(nil)
            return
        }
        animateMark()
        let ticker = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in self?.animateMark() }
        ticker.tolerance = 0.035
        RunLoop.main.add(ticker, forMode: .common)
        markTimer = ticker
    }

    // Keeps animating while the menu is open (like AI Face): the timer runs in .common mode and only
    // the menu bar image changes; the menu itself is not rebuilt while open.
    private func animateMark() {
        let now = ProcessInfo.processInfo.systemUptime
        let frame = MenuMarkFrame.at(now - markStartedAt, working: markWorking,
                                     completionAge: markCompletedAt.map { now - $0 })
        guard frame != lastMarkFrame else { return }
        lastMarkFrame = frame
        item.button?.image = iconRenderer?(frame)
    }

    func applicationDidFinishLaunching(_ note: Notification) {
        model.updater.isBusy = { [weak self] in
            guard let self else { return false }
            return self.discussion.running || self.discussion.importingMaterials
        }
        model.updater.start()
        // When the build script opens the app, the script's folder (inside ~/Documents) comes along
        // as PWD/OLDPWD and is passed to every AI tool we start; shells they run then look at that
        // folder, and macOS asks for Documents access. None of the tools need it.
        unsetenv("PWD")
        unsetenv("OLDPWD")
        item.button?.image = illuminatiIcon()
        item.button?.imagePosition = .imageLeading
        menu.delegate = self
        item.menu = menu
        NSApp.mainMenu = keyboardMenu()
        model.onAccountsChange = { [weak self] in self?.refresh() }
        model.onDisplayChange = { [weak self] in
            self?.updateTitle()
            self?.rebuildMenu()
        }
        model.onPreviewUsageMenu = { [weak self] in
            guard let self,
                  let window = NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first(where: { $0.isVisible }),
                  let content = window.contentView else { return }
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            let location = content.convert(window.mouseLocationOutsideOfEventStream, from: nil)
            self.menu.popUp(positioning: nil, at: location, in: content)
        }
        model.onLanguageChange = { [weak self] in
            guard let self else { return }
            NSApp.mainMenu = self.keyboardMenu()
            self.settings.updateLanguage()
            self.chat.updateLanguage()
            self.discussion.objectWillChange.send()
            self.updateTitle()
            self.rebuildMenu()
            let accounts = self.accounts
            self.work.async {
                for account in accounts {
                    ClaudeUsage.forget(account)
                    CodexUsage.forget(account)
                }
                GeminiUsage.forget()
                DispatchQueue.main.async { self.refresh() }
            }
        }
        rebuildMenu()
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.refresh() }
        runningObservation = discussion.$running.removeDuplicates().sink { [weak self] running in
            guard let self else { return }
            if self.markWorking && !running && !self.discussion.stopping,
               self.discussion.current.turns.last?.error == nil {
                self.markCompletedAt = ProcessInfo.processInfo.systemUptime
            }
            if running { self.markCompletedAt = nil }
            self.markWorking = running
        }
        motionObservation = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.configureMarkAnimation() }
        updateTitle()
    }

    func applicationWillTerminate(_ notification: Notification) {
        markTimer?.invalidate()
        if let motionObservation { NSWorkspace.shared.notificationCenter.removeObserver(motionObservation) }
        discussion.debateCancellation?.cancel()
        discussion.discardPendingImages()
    }

    // Reopening the menu-bar app should reveal its chat window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { chat.show(discussion: discussion) }
        return true
    }

    private var usageMenuIsOpen = false
    // Account rows are custom views: draw their hover highlight (their details open to the side).
    func menu(_ menu: NSMenu, willHighlight item: NSMenuItem?) {
        for entry in menu.items { (entry.view as? MenuRowView)?.highlighted = entry === item }
    }

    func menuWillOpen(_ menu: NSMenu) {
        rebuildMenu()
        usageMenuIsOpen = true
        refresh()
    }
    func menuDidClose(_ menu: NSMenu) {
        // AppKit can still be unwinding menu tracking here. Rebuild on the next event turn.
        DispatchQueue.main.async {
            self.usageMenuIsOpen = false
            self.rebuildMenu()
        }
    }

    // A menu bar app shows no app menus, but ⌘C/⌘V/⌘X/⌘A/⌘Z and ⌘W only work in text fields and
    // windows when an Edit/Window menu exists. This one is never visible; it just carries the shortcuts.
    private func keyboardMenu() -> NSMenu {
        let main = NSMenu()
        func submenu(_ title: String, _ items: [(String, Selector, String, NSEvent.ModifierFlags)]) {
            let holder = NSMenuItem()
            let sub = NSMenu(title: title)
            for (name, selector, key, modifiers) in items {
                let entry = NSMenuItem(title: name, action: selector, keyEquivalent: key)
                entry.keyEquivalentModifierMask = modifiers
                if selector == #selector(openSettings) || selector == #selector(openChat) { entry.target = self }
                sub.addItem(entry)
            }
            holder.submenu = sub
            main.addItem(holder)
        }
        submenu("AI Illuminati", [(L("설정…", "Settings…"), #selector(openSettings), ",", .command),
                                  (L("채팅창 열기…", "Open Chat…"), #selector(openChat), "n", .command),
                                  (L("숨기기", "Hide"), #selector(NSApplication.hide(_:)), "h", .command)])
        submenu(L("편집", "Edit"), [(L("실행 취소", "Undo"), Selector(("undo:")), "z", .command),
                       (L("실행 복귀", "Redo"), Selector(("redo:")), "z", [.command, .shift]),
                       (L("오려두기", "Cut"), #selector(NSText.cut(_:)), "x", .command),
                       (L("복사하기", "Copy"), #selector(NSText.copy(_:)), "c", .command),
                       (L("붙여넣기", "Paste"), #selector(NSText.paste(_:)), "v", .command),
                       (L("모두 선택", "Select All"), #selector(NSText.selectAll(_:)), "a", .command)])
        submenu(L("윈도우", "Window"), [(L("닫기", "Close"), #selector(NSWindow.performClose(_:)), "w", .command),
                        (L("최소화", "Minimize"), #selector(NSWindow.performMiniaturize(_:)), "m", .command)])
        return main
    }

    @objc private func refresh() {
        let list = accounts
        work.async {
            var fresh = list.map { account -> AIUsage in
                switch account.provider {
                case .claude: return ClaudeUsage.read(account)
                case .codex: return CodexUsage.read(account)
                case .gemini: return GeminiUsage.read(account)
                }
            }
            Self.markSameAccounts(&fresh)
            DispatchQueue.main.async {
                self.usages = fresh
                self.model.latestUsage = Dictionary(fresh.compactMap { u in u.account.map { ($0.id, u) } },
                                                    uniquingKeysWith: { a, _ in a })
                self.updateTitle()
                self.rebuildMenu()
            }
        }
    }

    // Two entries logged in to the same ChatGPT account break each other's login (the login
    // renews itself and the old one stops working), so point it out.
    private static func markSameAccounts(_ usages: inout [AIUsage]) {
        var seen: [String: String] = [:]
        for i in usages.indices {
            guard usages[i].account?.provider == .codex,
                  let email = usages[i].detail?.components(separatedBy: " · ").first, !email.isEmpty else { continue }
            if let other = seen[email] {
                usages[i].note = L("'\(other)'과 같은 계정이에요. 하나는 목록에서 빼 주세요", "Same account as “\(other)”. Remove one of the duplicate entries.")
            } else {
                seen[email] = usages[i].name
            }
        }
    }

    // Bars show every connected account in Settings order, including unknown readings.
    // Percentage text keeps its existing per-provider summary.
    private func updateTitle() {
        let groups: [(String, Account.Provider)] = [("Cl", .claude), ("Cx", .codex), ("Gm", .gemini)]
        let present = groups.filter { g in usages.contains { $0.account?.provider == g.1 } }
        // One limit everywhere in the menu bar: the 5-hour or the weekly one, as chosen in Settings.
        let window = model.menuBarWindow
        let best = present.map { g in usages.filter { $0.account?.provider == g.1 }.compactMap { window.left($0) }.max() }
        let listed = accounts
        let levels = listed.map { account in usages.first { $0.account?.id == account.id }.flatMap { window.left($0) } }
        item.button?.toolTip = window.title + "\n" + zip(listed, levels).map { account, left in
            let usage = usages.first { $0.account?.id == account.id }
            let text = usage.map { window.hasNoLimit($0) } == true ? L("한도 없음", "no limit")
                : left.map { "\(Int($0.rounded()))%" } ?? "–"
            return account.name + " " + text
        }.joined(separator: "\n")
        let style = model.menuBarStyle
        let colored = model.menuBarColored
        func tint(_ provider: Account.Provider) -> NSColor {
            switch provider {
            case .claude: return .systemOrange
            case .codex: return .systemGreen
            case .gemini: return .systemBlue
            }
        }
        let colors = present.map { tint($0.1) }
        let accountColors = listed.map { tint($0.provider) }
        switch style {
        case .mark, .markPercent:
            iconRenderer = { frame in illuminatiIcon(colored: colored, frame: frame) }
        case .markBars, .bars:
            iconRenderer = { frame in meterIcon(levels: levels, mark: style == .markBars, colors: colored ? accountColors : nil, frame: frame) }
        }
        configureMarkAnimation()
        guard style == .markPercent else {
            item.button?.attributedTitle = NSAttributedString(string: "")
            return
        }
        let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        let title = NSMutableAttributedString(string: " ", attributes: [.font: font])
        for (index, pair) in zip(present, best).enumerated() {
            let (g, left) = pair
            if title.length > 1 { title.append(NSAttributedString(string: "  ", attributes: [.font: font])) }
            title.append(NSAttributedString(string: g.0 + " ", attributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor]))
            title.append(NSAttributedString(string: left.map { "\(Int($0.rounded()))%" } ?? "?", attributes: [.font: font, .foregroundColor: colored ? colors[index] : NSColor.labelColor]))
        }
        item.button?.attributedTitle = title
    }

    private func rebuildMenu() {
        guard !usageMenuIsOpen else { return }
        menu.removeAllItems()
        if usages.isEmpty && !accounts.isEmpty { menu.addItem(info(L("확인 중…", "Checking…"))) }
        // Current order and names from the list (readings may be a little older).
        let shown = accounts.compactMap { account in
            usages.first { $0.account?.id == account.id }.map { usage -> AIUsage in
                var copy = usage
                copy.account = account
                return copy
            }
        }
        if model.usageMenuStyle == .cards {
            for (i, usage) in shown.enumerated() {
                if i > 0 { menu.addItem(.separator()) }
                menu.addItem(MenuCardItem.make(usage, title: label(for: usage)))
            }
            if !shown.isEmpty { menu.addItem(MenuCardItem.legend()) }
        } else if !shown.isEmpty {
            for row in MenuCardItem.comparison(shown, style: model.usageMenuStyle) { menu.addItem(row) }
        }
        if !shown.isEmpty { menu.addItem(.separator()) }
        menu.addItem(action(L("채팅창 열기…", "Open Chat…"), #selector(openChat), key: "n"))
        menu.addItem(action(L("설정…", "Settings…"), #selector(openSettings), key: ","))
        menu.addItem(action(L("지금 새로고침", "Refresh Now"), #selector(refresh), key: "r"))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: L("종료", "Quit"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    private func label(for usage: AIUsage) -> String {
        let name = usage.account?.name ?? usage.name
        guard let kind = usage.account?.provider.title else { return name }
        return name.hasPrefix(kind) ? name : "\(kind) · \(name)"
    }

    // MARK: Actions


    @objc private func openSettings() { settings.show(model: model) }
    @objc private func openChat() { chat.show(discussion: discussion) }

    // MARK: Helpers

    private func info(_ text: String) -> NSMenuItem {
        let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func action(_ title: String, _ selector: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: key)
        item.target = self
        return item
    }

}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
