import Cocoa

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

    func applicationDidFinishLaunching(_ note: Notification) {
        item.button?.image = illuminatiIcon()
        item.button?.imagePosition = .imageLeading
        menu.delegate = self
        item.menu = menu
        NSApp.mainMenu = keyboardMenu()
        model.onAccountsChange = { [weak self] in self?.refresh() }
        model.onDisplayChange = { [weak self] in self?.updateTitle() }
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
    }

    // Reopening the menu-bar app should reveal its chat window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { chat.show(discussion: discussion) }
        return true
    }

    func menuWillOpen(_ menu: NSMenu) { refresh() }

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

    private var showPercent: Bool { model.showPercent }

    // Menu bar: the eye-in-triangle mark. With "% 같이 보기" on, also "Cl 80%  Cx 95%  Gm ?"
    // (per AI, the account with the most left).
    private func updateTitle() {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        let groups: [(String, [AIUsage])] = [
            ("Cl", usages.filter { $0.account?.provider == .claude }),
            ("Cx", usages.filter { $0.account?.provider == .codex }),
            ("Gm", usages.filter { $0.account?.provider == .gemini }),
        ]
        guard showPercent else {
            item.button?.attributedTitle = NSAttributedString(string: "")
            return
        }
        let title = NSMutableAttributedString(string: " ", attributes: [.font: font])
        for (label, group) in groups where !group.isEmpty {
            if title.length > 1 { title.append(NSAttributedString(string: "  ", attributes: [.font: font])) }
            title.append(NSAttributedString(string: label + " ", attributes: [
                .font: font, .foregroundColor: NSColor.secondaryLabelColor]))
            if let best = group.compactMap(\.leftNow).max() {
                title.append(NSAttributedString(string: "\(Int(best.rounded()))%", attributes: [
                    .font: font, .foregroundColor: color(forLeft: best)]))
            } else {
                title.append(NSAttributedString(string: "?", attributes: [
                    .font: font, .foregroundColor: NSColor.tertiaryLabelColor]))
            }
        }
        item.button?.attributedTitle = title
    }

    private func color(forLeft left: Double) -> NSColor {
        if left < 10 { return .systemRed }
        if left < 30 { return .systemOrange }
        return .labelColor
    }

    private func rebuildMenu() {
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
        let nameWidth = shown.map { label(for: $0).size(withAttributes: [.font: rowFont]).width }.max() ?? 0
        for usage in shown { menu.addItem(row(for: usage, nameWidth: nameWidth)) }
        if !shown.isEmpty { menu.addItem(.separator()) }
        menu.addItem(action(L("채팅창 열기…", "Open Chat…"), #selector(openChat), key: "n"))
        menu.addItem(action(L("설정…", "Settings…"), #selector(openSettings), key: ","))
        menu.addItem(action(L("지금 새로고침", "Refresh Now"), #selector(refresh), key: "r"))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: L("종료", "Quit"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    private let rowFont = NSFont.systemFont(ofSize: 13, weight: .semibold)
    private let barFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)

    private func label(for usage: AIUsage) -> String {
        let name = usage.account?.name ?? usage.name
        guard let kind = usage.account?.provider.title else { return name }
        return name.hasPrefix(kind) ? name : "\(kind) · \(name)"
    }

    // "████████░░" for the part left (10 blocks), like Claude Code's usage bars.
    private func bar(left: Double, cells: Int = 10) -> NSAttributedString {
        let filled = max(0, min(cells, Int((left / 100 * Double(cells)).rounded())))
        let text = NSMutableAttributedString(string: String(repeating: "█", count: filled), attributes: [
            .font: barFont, .foregroundColor: NSColor.labelColor])
        text.append(NSAttributedString(string: String(repeating: "░", count: cells - filled), attributes: [
            .font: barFont, .foregroundColor: NSColor.tertiaryLabelColor]))
        return text
    }

    // One line per account in the main menu: name, bar, "62%". Hovering opens the details.
    private func row(for usage: AIUsage, nameWidth: CGFloat) -> NSMenuItem {
        let style = NSMutableParagraphStyle()
        style.tabStops = [NSTextTab(textAlignment: .left, location: nameWidth + 16)]
        let title = NSMutableAttributedString(string: label(for: usage) + "\t", attributes: [.font: rowFont])
        if let left = usage.leftNow {
            title.append(bar(left: left))
            title.append(NSAttributedString(string: String(format: "  %3d%%", Int(left.rounded())), attributes: [.font: barFont]))
        } else {
            title.append(NSAttributedString(string: usage.needsLogin ? L("로그인 필요", "Sign-in required") : "?", attributes: [
                .font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.secondaryLabelColor]))
        }
        title.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: title.length))
        let item = NSMenuItem(title: label(for: usage), action: nil, keyEquivalent: "")
        item.attributedTitle = title
        item.submenu = detailMenu(for: usage)
        return item
    }

    // The side menu: account, each limit with its own bar and reset time, then account actions.
    private func detailMenu(for usage: AIUsage) -> NSMenu {
        let sub = NSMenu()
        sub.autoenablesItems = false   // lets the limit lines below show in full color
        if let detail = usage.detail, !detail.isEmpty { sub.addItem(info(detail)) }
        var limits: [(String, UsageWindow)] = []
        if let w = usage.fiveHour { limits.append((L("5시간", "5-hour"), w)) }
        if let w = usage.weekly { limits.append((L("주간", "Weekly"), w)) }
        for (name, w) in limits {
            let text = NSMutableAttributedString(string: name + "\t", attributes: [.font: NSFont.systemFont(ofSize: 13)])
            text.append(bar(left: w.left()))
            text.append(NSAttributedString(string: "  " + describeLeft(w), attributes: [.font: NSFont.systemFont(ofSize: 12)]))
            let style = NSMutableParagraphStyle()
            style.tabStops = [NSTextTab(textAlignment: .left, location: 48)]
            text.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: text.length))
            let line = info(name)
            line.attributedTitle = text
            line.isEnabled = true
            sub.addItem(line)
        }
        for extra in usage.extras { sub.addItem(info(extra)) }
        if let note = usage.note { sub.addItem(info(note)) }
        sub.addItem(.separator())
        if let account = usage.account {
            let title = account.provider == .gemini && !Login.agyInstalled ? L("agy 설치하고 로그인…", "Install agy and Sign In…")
                : usage.needsLogin ? L("로그인…", "Sign In…") : L("다시 로그인…", "Sign In Again…")
            let entry = action(title, #selector(loginAccount(_:)))
            entry.representedObject = account.id
            sub.addItem(entry)
        }
        sub.addItem(action(L("설정…", "Settings…"), #selector(openSettings)))
        return sub
    }

    // MARK: Actions

    @objc private func openSettings() { settings.show(model: model) }
    @objc private func openChat() { chat.show(discussion: discussion) }

    @objc private func loginAccount(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let account = accounts.first(where: { $0.id == id }) else { return }
        model.login(account)
    }

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
