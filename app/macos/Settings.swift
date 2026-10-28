import Cocoa
import ServiceManagement
import SwiftUI

// What the menu and the Settings window share: the account list (saved on every change) and
// the display options. The menu listens through the two callbacks.
final class AppModel: ObservableObject {
    @Published var language: AppLanguage {
        didSet {
            let wasDefault = chatRules == Self.rules(for: oldValue)
            UserDefaults.standard.set(language.rawValue, forKey: "appLanguage")
            if wasDefault { chatRules = Self.rules(for: language) }
            onLanguageChange?()
        }
    }
    var onLanguageChange: (() -> Void)?

    @Published var accounts: [Account] {
        didSet {
            AccountStore.save(accounts)
            onAccountsChange?()
        }
    }
    @Published var showPercent: Bool {
        didSet {
            UserDefaults.standard.set(showPercent, forKey: "showPercent")
            onDisplayChange?()
        }
    }
    // What the menu bar shows next to (or instead of) the mark. Saved as "menuBarStyle".
    enum MenuBarStyle: String, CaseIterable {
        case mark, markBars, bars, markPercent
        var title: String {
            switch self {
            case .mark: return L("마크만", "Mark")
            case .markBars: return L("마크 + 막대", "Mark + bars")
            case .bars: return L("막대만", "Bars")
            case .markPercent: return L("마크 + %", "Mark + %")
            }
        }
    }
    @Published var menuBarStyle: MenuBarStyle {
        didSet {
            UserDefaults.standard.set(menuBarStyle.rawValue, forKey: "menuBarStyle")
            onDisplayChange?()
        }
    }
    // Which limit the menu bar bars and numbers show. Saved as "menuBarWindow" (default 5-hour).
    enum MenuBarWindow: String, CaseIterable {
        case fiveHour, weekly
        var title: String { self == .fiveHour ? L("5시간", "5-hour") : L("주간", "Weekly") }
        // What is left of this limit. A plan without this limit (Gemini has no 5-hour one, a school Claude
        // plan no overall weekly one) is not held back by it, so it counts as full. No reading at all
        // (not signed in, not checked yet) stays empty.
        func left(_ usage: AIUsage) -> Double? {
            if let window = self == .fiveHour ? usage.fiveHour : usage.weekly { return window.left() }
            return hasNoLimit(usage) ? 100 : nil
        }
        func hasNoLimit(_ usage: AIUsage) -> Bool {
            (self == .fiveHour ? usage.fiveHour : usage.weekly) == nil && (usage.fiveHour != nil || usage.weekly != nil)
        }
    }
    @Published var menuBarWindow: MenuBarWindow {
        didSet {
            UserDefaults.standard.set(menuBarWindow.rawValue, forKey: "menuBarWindow")
            onDisplayChange?()
        }
    }
    @Published var menuBarColored: Bool {
        didSet {
            UserDefaults.standard.set(menuBarColored, forKey: "menuBarColored")
            onDisplayChange?()
        }
    }
    @Published var menuBarAnimation: Bool {
        didSet {
            UserDefaults.standard.set(menuBarAnimation, forKey: "menuBarAnimation")
            onDisplayChange?()
        }
    }
    enum UsageMenuStyle: String, CaseIterable {
        case cards, comparison, comparisonRings, compact
        var title: String {
            switch self {
            case .cards: return L("기존 카드", "Original cards")
            case .comparison: return L("비교 · 막대", "Compare · bars")
            case .comparisonRings: return L("비교 · 막대와 충전 시계", "Compare · bars & reset rings")
            case .compact: return L("압축 · 충전 시계", "Compact · reset rings")
            }
        }
    }
    @Published var usageMenuStyle: UsageMenuStyle {
        didSet {
            UserDefaults.standard.set(usageMenuStyle.rawValue, forKey: "usageMenuStyle")
            onDisplayChange?()
        }
    }
    @Published private(set) var openAtLogin: Bool
    let updater = Updater()
    // Rules put at the top of every message the chat sends to an AI (edited in Settings).
    @Published var chatRules: String {
        didSet { UserDefaults.standard.set(chatRules, forKey: "chatRules") }
    }
    // Style only. How long each AI turn is comes from the length menu in the chat window.
    private static let koreanChatRules = """
    - 인사, 칭찬, 맞장구, 질문 되풀이, 같은 말 반복은 쓰지 않는다.
    - 다른 AI의 답을 검토할 때는 틀린 점과 빠진 점에 집중한다.
    - 사용자의 최근 메시지 언어로 답한다. 다른 언어를 요청하면 그 언어로.
    """
    static func rules(for language: AppLanguage) -> String {
        if language == .korean { return koreanChatRules }
        return """
        - Avoid greetings, praise, filler, restating the question, and repetition.
        - When reviewing other answers, focus on errors and omissions.
        - Reply in the language of the user's latest message unless they request another language.
        """
    }

    // Earlier defaults, which also set a length ("3–5 sentences"). Saved copies of them are replaced
    // by the current default; rules the user wrote stay as they are.
    static let oldDefaultRules = [
        """
        - 짧게 핵심만 쓴다. 보통 3~5문장, 목록이면 5개 이내.
        - 인사, 칭찬, 맞장구, 질문 되풀이, 같은 말 반복은 쓰지 않는다.
        - 다른 AI의 답을 검토할 때는 틀린 점과 빠진 점만 3줄 이내로 쓴다.
        - 사용자가 자세히 해달라고 할 때만 길게 쓴다.
        """,
        """
        - Keep answers concise: usually 3–5 sentences, or at most 5 list items.
        - Avoid greetings, praise, filler, restating the question, and repetition.
        - When reviewing other answers, mention only errors or omissions in at most 3 lines.
        - Give more detail only when requested. Reply in the language of the user's latest message unless they request another language.
        """,
    ]
    static var defaultChatRules: String { rules(for: AppLanguage.current) }
    @Published var latestUsage: [String: AIUsage] = [:]   // last readings by account id (set by the menu)
    var onAccountsChange: (() -> Void)?
    var onDisplayChange: (() -> Void)?
    var onPreviewUsageMenu: (() -> Void)?

    init() {
        language = AppLanguage.current
        accounts = AccountStore.load()
        showPercent = UserDefaults.standard.bool(forKey: "showPercent")
        // Older setting: "% 같이 보기" on becomes "mark + %"; otherwise the new default "mark + bars".
        menuBarStyle = UserDefaults.standard.string(forKey: "menuBarStyle").flatMap(MenuBarStyle.init(rawValue:))
            ?? (UserDefaults.standard.bool(forKey: "showPercent") ? .markPercent : .markBars)
        menuBarAnimation = UserDefaults.standard.object(forKey: "menuBarAnimation") as? Bool ?? true
        menuBarWindow = UserDefaults.standard.string(forKey: "menuBarWindow").flatMap(MenuBarWindow.init(rawValue:)) ?? .fiveHour
        menuBarColored = UserDefaults.standard.bool(forKey: "menuBarColored")
        usageMenuStyle = UserDefaults.standard.string(forKey: "usageMenuStyle").flatMap(UsageMenuStyle.init(rawValue:)) ?? .cards
        openAtLogin = SMAppService.mainApp.status == .enabled
        let saved = UserDefaults.standard.string(forKey: "chatRules")
        chatRules = (saved == nil || saved == Self.koreanChatRules || saved == Self.rules(for: .english)
                     || Self.oldDefaultRules.contains(saved!))
            ? Self.defaultChatRules : saved!
    }

    var hasGemini: Bool { accounts.contains { $0.provider == .gemini } }

    // New entry with a default name (renamed in Settings), then that tool's login opens in Terminal.
    func add(_ provider: Account.Provider) {
        let name: String
        if provider == .gemini {
            name = "Gemini"
        } else {
            let count = accounts.filter { $0.provider == provider }.count
            name = "\(provider.title) \(count + 1)"
        }
        let account = AccountStore.newAccount(provider: provider, name: name)
        accounts.append(account)
        Login.login(account)
    }

    func login(_ account: Account) {
        ClaudeUsage.forget(account)
        CodexUsage.forget(account)
        Login.login(account)
    }

    func move(_ account: Account, by offset: Int) {
        guard let from = accounts.firstIndex(where: { $0.id == account.id }) else { return }
        let to = from + offset
        guard accounts.indices.contains(to) else { return }
        accounts.swapAt(from, to)
    }

    func rename(_ id: String, to name: String) {
        guard let index = accounts.firstIndex(where: { $0.id == id }), accounts[index].name != name else { return }
        accounts[index].name = name
    }

    // Removing only takes it off the list; the login stays where the tool keeps it.
    func remove(_ account: Account) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = L("'\(account.name)'을 목록에서 뺄까요?", "Remove “\(account.name)” from the list?")
        alert.informativeText = L("목록에서만 빠져요. 그 계정의 로그인 정보는 지우지 않아요.", "This removes the account from the list. Its sign-in credentials are kept.")
        alert.addButton(withTitle: L("빼기", "Remove"))
        alert.addButton(withTitle: L("취소", "Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        accounts.removeAll { $0.id == account.id }
    }

    func setOpenAtLogin(_ on: Bool) {
        let service = SMAppService.mainApp
        do {
            if on { try service.register() } else { try service.unregister() }
        } catch {
            NSLog("login item: \(error)")
        }
        refreshLoginItemStatus()
    }

    func refreshLoginItemStatus() {
        openAtLogin = SMAppService.mainApp.status == .enabled
    }
}

// Compact pages share the same insets and row rhythm instead of Form's large footers.
private struct SettingsCard<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                .padding(.horizontal, 2)
            VStack(spacing: 0) { content }
                .background(Color(nsColor: .controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.07)))
        }
    }
}

private struct SettingsRow<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: 12) {
            Text(title).frame(width: 112, alignment: .leading)
            Spacer(minLength: 0)
            content
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .frame(minHeight: 32)
    }
}

private struct SettingsPage<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) { content }
                .padding(14).frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .font(.system(size: 12))
        .controlSize(.small)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

struct GeneralSettingsTab: View {
    @ObservedObject var model: AppModel

    var body: some View {
        SettingsPage {
            SettingsCard(title: L("메뉴 표시", "Menu appearance")) {
                SettingsRow(title: L("메뉴바 표시", "Menu bar")) {
                    Picker("", selection: $model.menuBarStyle) {
                        ForEach(AppModel.MenuBarStyle.allCases, id: \.self) { Text($0.title).tag($0) }
                    }.labelsHidden().frame(width: 218)
                }
                Divider()
                SettingsRow(title: L("잔여량 기준", "Usage limit")) {
                    Picker("", selection: $model.menuBarWindow) {
                        ForEach(AppModel.MenuBarWindow.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .labelsHidden().pickerStyle(.segmented).frame(width: 218)
                    .help(L("계정마다 선택한 한도의 남은 양을 표시해요. 한도가 없으면 가득 찬 막대, 읽지 못했으면 빈 막대예요.",
                            "One bar per account for this limit. No limit: full bar. Unread account: empty bar."))
                }
                Divider()
                HStack(spacing: 16) {
                    Toggle(L("흑백", "Monochrome"), isOn: Binding(
                        get: { !model.menuBarColored }, set: { model.menuBarColored = !$0 }))
                        .help(L("끄면 계정 종류별 컬러로 표시해요.", "Turn off to use provider colors."))
                    Divider().frame(height: 16)
                    Toggle(L("눈과 후광", "Eye & halo"), isOn: $model.menuBarAnimation)
                        .help(L("메뉴바의 눈과 후광 애니메이션", "Animate the menu bar eye and halo"))
                }
                .toggleStyle(.switch).padding(.horizontal, 10).padding(.vertical, 6)
                Divider()
                SettingsRow(title: L("사용량 메뉴", "Usage menu")) {
                    Picker("", selection: $model.usageMenuStyle) {
                        ForEach(AppModel.UsageMenuStyle.allCases, id: \.self) { Text($0.title).tag($0) }
                    }.labelsHidden().frame(maxWidth: .infinity)
                    Button { model.onPreviewUsageMenu?() } label: { Image(systemName: "eye") }
                        .help(L("메뉴 미리 보기", "Preview usage menu"))
                        .accessibilityLabel(L("메뉴 미리 보기", "Preview usage menu"))
                }
            }
            SettingsCard(title: L("앱 기본 설정", "App")) {
                SettingsRow(title: L("언어", "Language")) {
                    Picker("", selection: $model.language) {
                        Text("English").tag(AppLanguage.english)
                        Text("한국어").tag(AppLanguage.korean)
                    }.labelsHidden().pickerStyle(.segmented).frame(width: 218)
                }
                Divider()
                SettingsRow(title: L("로그인 시 실행", "Open at login")) {
                    Toggle(L("로그인 시 실행", "Open at login"), isOn: Binding(
                        get: { model.openAtLogin }, set: { model.setOpenAtLogin($0) }))
                        .labelsHidden().toggleStyle(.switch)
                }
            }
            MaintenanceSettings(model: model, updater: model.updater)
        }
    }
}

private struct MaintenanceSettings: View {
    @ObservedObject var model: AppModel
    @ObservedObject var updater: Updater

    var body: some View {
        SettingsCard(title: L("업데이트와 저장 위치", "Updates & storage")) {
            SettingsRow(title: L("자동 업데이트", "Automatic updates")) {
                Toggle(L("자동 업데이트", "Automatic updates"), isOn: $updater.enabled)
                    .labelsHidden().toggleStyle(.switch)
                Button(L("지금 확인", "Check now")) { updater.check(manual: true) }
                    .disabled(updater.checking)
            }
            Text(updater.status.isEmpty ? L("시작 후, 그리고 3시간마다 확인해요.", "Checks at launch and every 3 hours.") : updater.status)
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10).padding(.bottom, 7)
                .help(L("시험과 빌드가 통과해야 교체해요. 채팅·자료 가져오기·포커 중에는 기다려요.",
                        "Installs after tests and build pass. Waits for chats, imports and poker to finish."))
            Divider()
            SettingsRow(title: L("저장 폴더", "Folders")) {
                Button(L("앱 데이터", "App data")) { DataFolders.open(DataFolders.appData) }
                    .help(L("계정 목록, 대화, 첨부 사본과 사용량 기록", "Account list, chats, attachment copies and usage logs"))
                Button(L("계정", "Accounts")) { DataFolders.open(DataFolders.accounts) }
                    .help(L("로그인 정보와 세션이 들어 있어요. 다른 사람과 공유하지 마세요.",
                            "Contains sign-in data and sessions. Do not share this folder."))
            }
        }
    }
}

// The two places the app keeps things, opened in Finder from Settings.
enum DataFolders {
    static var appData: String { AccountStore.supportDir }
    static var accounts: String { AccountStore.home + "/.ai-illuminati" }

    static func open(_ path: String) {
        try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        NSWorkspace.shared.open(URL(fileURLWithPath: path, isDirectory: true))
    }
}

struct AccountsSettingsTab: View {
    @ObservedObject var model: AppModel

    var body: some View {
        SettingsPage {
            HStack {
                Text(L("계정", "Accounts")).font(.system(size: 12, weight: .semibold))
                Text("\(model.accounts.count)").foregroundStyle(.secondary)
                Spacer()
                Menu {
                    Button(L("Claude 계정 추가", "Add Claude")) { model.add(.claude) }
                    Button(L("ChatGPT 계정 추가", "Add ChatGPT")) { model.add(.codex) }
                    Button(L("Gemini 추가", "Add Gemini")) { model.add(.gemini) }.disabled(model.hasGemini)
                } label: {
                    Label(L("계정 추가", "Add account"), systemImage: "plus")
                }.fixedSize()
            }
            VStack(spacing: 0) {
                if model.accounts.isEmpty {
                    Text(L("계정을 추가하면 사용량이 여기에 표시돼요.", "Add an account to see its usage here."))
                        .foregroundStyle(.secondary).padding(16)
                }
                ForEach(model.accounts, id: \.id) { account in
                    if account.id != model.accounts.first?.id { Divider() }
                    AccountRow(model: model, account: account)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                }
            }
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.07)))
            Text(L("이름을 눌러 수정 · 화살표로 순서 변경 · ⋯에서 로그인과 폴더 열기", "Edit names directly · Arrows reorder · ⋯ for sign-in and folders"))
                .font(.system(size: 11)).foregroundStyle(.secondary)
            Text(L("계정을 추가하면 브라우저 로그인을 위해 터미널이 열려요. 같은 ChatGPT 계정을 중복 추가하지 마세요.",
                   "Adding opens Terminal for browser sign-in. Add each ChatGPT account only once."))
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }
}

struct ChatSettingsTab: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(L("채팅 규칙", "Chat rules")).font(.system(size: 12, weight: .semibold))
                Spacer()
                Button(L("기본값으로", "Reset to default")) { model.chatRules = AppModel.defaultChatRules }
                    .disabled(model.chatRules == AppModel.defaultChatRules)
            }
            TextEditor(text: $model.chatRules)
                .font(.system(size: 12))
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.1)))
            Text(L("모든 AI 요청에 적용할 말투와 응답 규칙이에요. 답변 길이는 채팅창에서 선택해요.",
                   "Style and instructions for every AI request. Choose response length in the chat window."))
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .padding(14).controlSize(.small)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

private struct AccountRow: View {
    @ObservedObject var model: AppModel
    let account: Account

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                TextField(L("이름", "Name"), text: Binding(
                    get: { model.accounts.first { $0.id == account.id }?.name ?? "" },
                    set: { model.rename(account.id, to: $0) }))
                    .textFieldStyle(.plain)
                    .labelsHidden()
                Text(account.provider.title).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            status.font(.system(size: 11)).lineLimit(1)
            Button(action: { model.move(account, by: -1) }) { Image(systemName: "chevron.up") }
                .buttonStyle(.borderless)
                .disabled(model.accounts.first?.id == account.id)
            Button(action: { model.move(account, by: 1) }) { Image(systemName: "chevron.down") }
                .buttonStyle(.borderless)
                .disabled(model.accounts.last?.id == account.id)
            Menu {
                Button(L("로그인…", "Sign in…")) { model.login(account) }
                if let dir = account.dir {
                    Button(L("Finder에서 폴더 열기", "Show folder in Finder")) { DataFolders.open(dir) }
                }
                Divider()
                Button(L("목록에서 빼기…", "Remove from list…")) { model.remove(account) }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.vertical, 1)
    }

    // Like AI Face's "Connected": green when signed in, orange when a sign-in is needed.
    @ViewBuilder private var status: some View {
        if let usage = model.latestUsage[account.id] {
            if usage.needsLogin {
                Text(L("로그인 필요", "Sign-in needed")).foregroundStyle(.orange)
            } else if let left = usage.leftNow {
                Text(L("연결됨 · \(Int(left.rounded()))% 남음", "Connected · \(Int(left.rounded()))% left")).foregroundStyle(.green)
            } else {
                Text(L("연결됨", "Connected")).foregroundStyle(.green)
            }
        } else {
            Text(L("확인 중…", "Checking…")).foregroundStyle(.secondary)
        }
    }
}

// One Settings window with toolbar tabs, reused.
final class SettingsWindow {
    private var window: NSWindow?
    private var tabs: NSTabViewController?
    static let size = NSSize(width: 500, height: 420)

    private func tab<V: View>(_ content: V, symbol: String) -> NSTabViewItem {
        let size = Self.size
        let host = NSHostingController(rootView: content.frame(width: size.width, height: size.height))
        host.sizingOptions = []
        host.view.frame = NSRect(origin: .zero, size: size)
        host.preferredContentSize = size
        let item = NSTabViewItem(viewController: host)
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        return item
    }

    func updateLanguage() {
        guard let items = tabs?.tabViewItems, items.count == 3 else { return }
        for (item, title) in zip(items, [L("일반", "General"), L("계정", "Accounts"), L("채팅", "Chat")]) {
            item.label = title
            item.viewController?.title = title
        }
        if let selected = tabs?.tabView.selectedTabViewItem { window?.title = selected.label }
    }

    func show(model: AppModel) {
        if window == nil {
            let t = NSTabViewController()
            t.tabStyle = .toolbar
            t.addTabViewItem(tab(GeneralSettingsTab(model: model), symbol: "gearshape"))
            t.addTabViewItem(tab(AccountsSettingsTab(model: model), symbol: "person.2"))
            t.addTabViewItem(tab(ChatSettingsTab(model: model), symbol: "bubble.left.and.bubble.right"))
            tabs = t
            let w = NSWindow(contentViewController: t)
            w.styleMask = [.titled, .closable, .miniaturizable]
            w.setContentSize(Self.size)
            w.isReleasedWhenClosed = false
            w.center()
            window = w
            updateLanguage()
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
