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
        for usage in usages {
            addRows(for: usage)
            menu.addItem(.separator())
        }
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

    private func addRows(for usage: AIUsage) {
        let kind: String
        switch usage.account?.provider {
        case .claude: kind = "Claude"
        case .codex: kind = "ChatGPT"
        case nil: kind = ""
        }
        let label = kind.isEmpty || usage.name.hasPrefix(kind) ? usage.name : "\(kind) · \(usage.name)"
        let head = usage.leftNow.map { "\(label) — \(Int($0.rounded()))% 남음" } ?? "\(label) — ?"
        let headItem = NSMenuItem(title: head, action: nil, keyEquivalent: "")
        headItem.attributedTitle = NSAttributedString(string: head, attributes: [.font: NSFont.boldSystemFont(ofSize: 13)])
        if let account = usage.account {
            headItem.submenu = accountMenu(account)
        } else {
            let sub = NSMenu()
            sub.addItem(action("다시 로그인…", #selector(loginGemini)))
            headItem.submenu = sub
        }
        menu.addItem(headItem)
        if let detail = usage.detail, !detail.isEmpty { menu.addItem(info("   " + detail)) }
        if let w = usage.fiveHour { menu.addItem(info("   5시간: " + describe(w))) }
        if let w = usage.weekly { menu.addItem(info("   주간: " + describe(w))) }
        for extra in usage.extras { menu.addItem(info("   " + extra)) }
        if let note = usage.note { menu.addItem(info("   " + note)) }
        if let account = usage.account, usage.needsLogin {
            let button = action("   로그인…", #selector(loginAccount(_:)))
            button.representedObject = account.id
            menu.addItem(button)
        } else if usage.account == nil, usage.needsLogin {
            menu.addItem(action(Login.agyInstalled ? "   Gemini 로그인…" : "   agy 설치하고 로그인…", #selector(loginGemini)))
        }
    }

    private func accountMenu(_ account: Account) -> NSMenu {
        let sub = NSMenu()
        for (title, selector) in [("다시 로그인…", #selector(loginAccount(_:))),
                                  ("이름 바꾸기…", #selector(renameAccount(_:))),
                                  ("목록에서 빼기…", #selector(removeAccount(_:)))] {
            let entry = action(title, selector)
            entry.representedObject = account.id
            sub.addItem(entry)
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

    private func describe(_ w: UsageWindow) -> String { describeLeft(w) }

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
