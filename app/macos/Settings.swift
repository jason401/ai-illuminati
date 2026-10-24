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

    init() {
        language = AppLanguage.current
        accounts = AccountStore.load()
        showPercent = UserDefaults.standard.bool(forKey: "showPercent")
        // Older setting: "% 같이 보기" on becomes "mark + %"; otherwise the new default "mark + bars".
        menuBarStyle = UserDefaults.standard.string(forKey: "menuBarStyle").flatMap(MenuBarStyle.init(rawValue:))
            ?? (UserDefaults.standard.bool(forKey: "showPercent") ? .markPercent : .markBars)
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
        openAtLogin = service.status == .enabled
    }
}

// Settings look like AI Face's: toolbar tabs (일반 · 계정 · 채팅), each a grouped form of cards.
struct GeneralSettingsTab: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Form {
            Section {
                Picker(L("언어", "Language"), selection: $model.language) {
                    Text("English").tag(AppLanguage.english)
                    Text("한국어").tag(AppLanguage.korean)
                }
                .pickerStyle(.segmented)
            }
            Section {
                Picker(L("메뉴바 표시", "Menu bar"), selection: $model.menuBarStyle) {
                    ForEach(AppModel.MenuBarStyle.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Toggle(L("로그인할 때 자동 실행", "Open at login"), isOn: Binding(get: { model.openAtLogin },
                                                                          set: { model.setOpenAtLogin($0) }))
            } footer: {
                Text(L("막대는 왼쪽부터 Claude · ChatGPT · Gemini예요. 각 AI에서 가장 많이 남은 계정이 지금 쓸 수 있는 양(5시간과 주간 중 적은 쪽)을 채워서 보여줘요. 마우스를 올리면 숫자가 보여요.",
                       "Bars, left to right: Claude · ChatGPT · Gemini. Each is filled by what its best account can use now (the lower of 5-hour and weekly). Hover for the numbers."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            UpdateSection(updater: model.updater)
            Section {
                HStack {
                    Text(L("앱 데이터", "App data"))
                    Spacer()
                    Button(L("Finder에서 열기", "Show in Finder")) { DataFolders.open(DataFolders.appData) }
                }
                HStack {
                    Text(L("계정 폴더", "Account folders"))
                    Spacer()
                    Button(L("Finder에서 열기", "Show in Finder")) { DataFolders.open(DataFolders.accounts) }
                }
            } header: {
                Text(L("저장 위치", "Where things are saved"))
            } footer: {
                Text(L("앱 데이터: 계정 목록, 대화 기록(chats)과 첨부 사본, 사용량 기록. 계정 폴더: 계정마다 Claude·ChatGPT 도구의 로그인·설정·세션 기록이 있어요. 로그인 정보가 들어 있으니 고치거나 다른 사람과 공유하지 마세요.",
                       "App data: account list, chats and attachment copies, usage logs. Account folders: each account's Claude / ChatGPT login, settings and sessions. They contain sign-in data, so do not edit or share them."))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// Automatic updates (see Updater.swift).
private struct UpdateSection: View {
    @ObservedObject var updater: Updater

    var body: some View {
        Section {
            Toggle(L("자동 업데이트", "Automatic updates"), isOn: $updater.enabled)
            HStack {
                Text(updater.status.isEmpty ? L("아직 확인 안 함", "Not checked yet") : updater.status)
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button(L("지금 확인", "Check now")) { updater.check(manual: true) }
                    .disabled(updater.checking)
            }
        } header: {
            Text(L("업데이트", "Updates"))
        } footer: {
            Text(L("켜져 있으면 앱이 켜질 때와 3시간마다 GitHub의 새 버전을 확인해요. 시험과 빌드를 모두 통과해야 바꿔서 다시 켜고, 실패하면 지금 버전을 그대로 써요. 채팅 중에는 기다렸다가 바꿔요.",
                   "When on, the app checks GitHub at launch and every 3 hours. It restarts into a new version only after tests and the build pass; otherwise it keeps this version. It waits while a chat is answering."))
                .font(.caption).foregroundStyle(.secondary)
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
        Form {
            Section {
                ForEach(model.accounts, id: \.id) { account in
                    AccountRow(model: model, account: account)
                }
            } header: {
                Text(L("계정", "Accounts"))
            } footer: {
                Text(L("화살표로 순서를 바꾸면 메뉴에 그 순서대로 보여요. 이름은 바로 고칠 수 있어요.",
                       "Use the arrows to set the menu order. Edit names directly."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                HStack {
                    Button(L("Claude 계정 추가", "Add Claude")) { model.add(.claude) }
                    Button(L("ChatGPT 계정 추가", "Add ChatGPT")) { model.add(.codex) }
                    Button(L("Gemini 추가", "Add Gemini")) { model.add(.gemini) }.disabled(model.hasGemini)
                }
            } header: {
                Text(L("계정 추가", "Add an account"))
            } footer: {
                Text(L("추가하면 터미널이 열려요. 그 계정으로 브라우저 로그인을 하면 돼요. 같은 ChatGPT 계정을 두 번 추가하지 마세요.",
                       "Adding an account opens Terminal for browser sign-in. Do not add the same ChatGPT account twice."))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

struct ChatSettingsTab: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Form {
            Section {
                TextEditor(text: $model.chatRules)
                    .font(.body)
                    .frame(minHeight: 150)
                    .scrollContentBackground(.hidden)
            } header: {
                HStack {
                    Text(L("채팅 규칙", "Chat rules"))
                    Spacer()
                    Button(L("기본값으로", "Reset to default")) { model.chatRules = AppModel.defaultChatRules }
                        .disabled(model.chatRules == AppModel.defaultChatRules)
                        .controlSize(.small)
                }
            } footer: {
                Text(L("채팅에서 AI들에게 보내는 모든 메시지 맨 앞에 붙어요. 답 길이와 말투를 여기서 정해요.",
                       "Included with each AI request. Set the answer length and style here."))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct AccountRow: View {
    @ObservedObject var model: AppModel
    let account: Account

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                TextField(L("이름", "Name"), text: Binding(
                    get: { model.accounts.first { $0.id == account.id }?.name ?? "" },
                    set: { model.rename(account.id, to: $0) }))
                    .textFieldStyle(.plain)
                    .labelsHidden()
                Text(account.provider.title).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            status
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
        .padding(.vertical, 2)
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
    static let size = NSSize(width: 560, height: 480)

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
