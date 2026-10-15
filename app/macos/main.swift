import Cocoa
import ServiceManagement

// AI Illuminati: a menu bar gauge that shows how much of each AI subscription is left
// (5-hour and weekly limits) and when each one resets, for any number of Claude and ChatGPT
// accounts. Uses each tool's own login (subscription), never API keys.
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private let work = DispatchQueue(label: "usage")
    private var accounts: [Account] = []
    private var usages: [AIUsage] = []
    private var timer: Timer?

    func applicationDidFinishLaunching(_ note: Notification) {
        item.button?.image = illuminatiIcon()
        item.button?.imagePosition = .imageLeading
        menu.delegate = self
        item.menu = menu
        accounts = AccountStore.load()
        rebuildMenu()
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.refresh() }
    }

    func menuWillOpen(_ menu: NSMenu) { refresh() }

    @objc private func refresh() {
        let list = accounts
        work.async {
            var fresh = list.filter { $0.provider == .claude }.map(ClaudeUsage.read)
            fresh += list.filter { $0.provider == .codex }.map(CodexUsage.read)
            fresh.append(GeminiUsage.read())
            Self.markSameAccounts(&fresh)
            DispatchQueue.main.async {
                self.usages = fresh
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
                usages[i].note = "'\(other)'과 같은 계정이에요. 하나는 목록에서 빼 주세요"
            } else {
                seen[email] = usages[i].name
            }
        }
    }

    private var showPercent: Bool {
        get { UserDefaults.standard.bool(forKey: "showPercent") }
        set { UserDefaults.standard.set(newValue, forKey: "showPercent") }
    }

    // Menu bar: the eye-in-triangle mark. With "% 같이 보기" on, also "Cl 80%  Cx 95%  Gm ?"
    // (per AI, the account with the most left).
    private func updateTitle() {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        let groups: [(String, [AIUsage])] = [
            ("Cl", usages.filter { $0.account?.provider == .claude }),
            ("Cx", usages.filter { $0.account?.provider == .codex }),
            ("Gm", usages.filter { $0.account == nil }),
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
        if usages.isEmpty && !accounts.isEmpty { menu.addItem(info("확인 중…")) }
        let nameWidth = usages.map { label(for: $0).size(withAttributes: [.font: rowFont]).width }.max() ?? 0
        for usage in usages { menu.addItem(row(for: usage, nameWidth: nameWidth)) }
        if !usages.isEmpty { menu.addItem(.separator()) }
        menu.addItem(action("Claude 계정 추가…", #selector(addClaude)))
        menu.addItem(action("ChatGPT(Codex) 계정 추가…", #selector(addCodex)))
        menu.addItem(.separator())
        menu.addItem(action("지금 새로고침", #selector(refresh), key: "r"))
        let percent = action("메뉴바에 % 같이 보기", #selector(togglePercent))
        percent.state = showPercent ? .on : .off
        menu.addItem(percent)
        let login = action("로그인할 때 자동 실행", #selector(toggleLogin))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        menu.addItem(NSMenuItem(title: "종료", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    private let rowFont = NSFont.systemFont(ofSize: 13, weight: .semibold)
    private let barFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)

    private func label(for usage: AIUsage) -> String {
        let kind: String
        switch usage.account?.provider {
        case .claude: kind = "Claude"
        case .codex: kind = "ChatGPT"
        case nil: kind = ""
        }
        return kind.isEmpty || usage.name.hasPrefix(kind) ? usage.name : "\(kind) · \(usage.name)"
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
            title.append(NSAttributedString(string: usage.needsLogin ? "로그인 필요" : "?", attributes: [
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
        if let w = usage.fiveHour { limits.append(("5시간", w)) }
        if let w = usage.weekly { limits.append(("주간", w)) }
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
            for (title, selector) in [(usage.needsLogin ? "로그인…" : "다시 로그인…", #selector(loginAccount(_:))),
                                      ("이름 바꾸기…", #selector(renameAccount(_:))),
                                      ("목록에서 빼기…", #selector(removeAccount(_:)))] {
                let entry = action(title, selector)
                entry.representedObject = account.id
                sub.addItem(entry)
            }
        } else {
            let title = !Login.agyInstalled ? "agy 설치하고 로그인…" : usage.needsLogin ? "로그인…" : "다시 로그인…"
            sub.addItem(action(title, #selector(loginGemini)))
        }
        return sub
    }

    // MARK: Account actions

    @objc private func addClaude() { addAccount(.claude) }
    @objc private func addCodex() { addAccount(.codex) }

    private func addAccount(_ provider: Account.Provider) {
        let count = accounts.filter { $0.provider == provider }.count
        let suggestion = (provider == .claude ? "Claude " : "ChatGPT ") + "\(count + 1)"
        guard let name = askText(title: provider == .claude ? "Claude 계정 추가" : "ChatGPT(Codex) 계정 추가",
                                 message: "메뉴에 보일 이름을 정해 주세요 (예: 개인, 회사). 다음에 터미널이 열리면 그 계정으로 로그인하면 돼요.",
                                 value: suggestion) else { return }
        let account = AccountStore.newAccount(provider: provider, name: name)
        accounts.append(account)
        AccountStore.save(accounts)
        Login.login(account)
        refresh()
    }

    @objc private func loginAccount(_ sender: NSMenuItem) {
        guard let account = account(for: sender) else { return }
        ClaudeUsage.forget(account)
        CodexUsage.forget(account)
        Login.login(account)
    }

    @objc private func renameAccount(_ sender: NSMenuItem) {
        guard let account = account(for: sender),
              let name = askText(title: "이름 바꾸기", message: "", value: account.name),
              let index = accounts.firstIndex(of: account) else { return }
        accounts[index].name = name
        AccountStore.save(accounts)
        ClaudeUsage.forget(account)
        CodexUsage.forget(account)
        refresh()
    }

    @objc private func removeAccount(_ sender: NSMenuItem) {
        guard let account = account(for: sender) else { return }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "'\(account.name)'을 목록에서 뺄까요?"
        alert.informativeText = "메뉴에서만 빠져요. 그 계정의 로그인 정보는 지우지 않아요."
        alert.addButton(withTitle: "빼기")
        alert.addButton(withTitle: "취소")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        accounts.removeAll { $0.id == account.id }
        AccountStore.save(accounts)
        refresh()
    }

    @objc private func loginGemini() { Login.gemini() }

    private func account(for sender: NSMenuItem) -> Account? {
        guard let id = sender.representedObject as? String else { return nil }
        return accounts.first { $0.id == id }
    }

    private func askText(title: String, message: String, value: String) -> String? {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = value
        alert.accessoryView = field
        alert.addButton(withTitle: "확인")
        alert.addButton(withTitle: "취소")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let text = field.stringValue.trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : text
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


    @objc private func togglePercent() {
        showPercent.toggle()
        updateTitle()
        rebuildMenu()
    }

    @objc private func toggleLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled { try service.unregister() } else { try service.register() }
        } catch {
            NSLog("login item: \(error)")
        }
        rebuildMenu()
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
