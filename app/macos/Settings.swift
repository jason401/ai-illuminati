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
    @Published private(set) var openAtLogin: Bool
    // Rules put at the top of every message the chat sends to an AI (edited in Settings).
    @Published var chatRules: String {
        didSet { UserDefaults.standard.set(chatRules, forKey: "chatRules") }
    }
    private static let koreanChatRules = """
    - 짧게 핵심만 쓴다. 보통 3~5문장, 목록이면 5개 이내.
    - 인사, 칭찬, 맞장구, 질문 되풀이, 같은 말 반복은 쓰지 않는다.
    - 다른 AI의 답을 검토할 때는 틀린 점과 빠진 점만 3줄 이내로 쓴다.
    - 사용자가 자세히 해달라고 할 때만 길게 쓴다.
    """
    static func rules(for language: AppLanguage) -> String {
        if language == .korean { return koreanChatRules }
        return """
        - Keep answers concise: usually 3–5 sentences, or at most 5 list items.
        - Avoid greetings, praise, filler, restating the question, and repetition.
        - When reviewing other answers, mention only errors or omissions in at most 3 lines.
        - Give more detail only when requested. Reply in the language of the user's latest message unless they request another language.
        """
    }
    static var defaultChatRules: String { rules(for: AppLanguage.current) }
    var latestUsage: [String: AIUsage] = [:]   // last readings by account id (set by the menu)
    var onAccountsChange: (() -> Void)?
    var onDisplayChange: (() -> Void)?

    init() {
        language = AppLanguage.current
        accounts = AccountStore.load()
        showPercent = UserDefaults.standard.bool(forKey: "showPercent")
        openAtLogin = SMAppService.mainApp.status == .enabled
        let saved = UserDefaults.standard.string(forKey: "chatRules")
        chatRules = (saved == nil || saved == Self.koreanChatRules || saved == Self.rules(for: .english))
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

struct SettingsView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(L("언어", "Language"))
                Picker(L("언어", "Language"), selection: $model.language) {
                    Text("English").tag(AppLanguage.english)
                    Text("한국어").tag(AppLanguage.korean)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            .frame(width: 340)
            Divider()
            Text(L("계정", "Accounts")).font(.headline)
            Text(L("끌어서 놓거나 화살표로 순서를 바꿔요. 메뉴에 이 순서대로 보여요. 이름은 바로 고칠 수 있어요.", "Drag or use the arrows to reorder accounts in the menu. Edit names directly."))
                .font(.caption)
                .foregroundColor(.secondary)
            List {
                ForEach(model.accounts, id: \.id) { account in
                    AccountRow(model: model, account: account)
                }
                .onMove { model.accounts.move(fromOffsets: $0, toOffset: $1) }
            }
            .frame(minHeight: 240)
            HStack {
                Button(L("Claude 계정 추가", "Add Claude account")) { model.add(.claude) }
                Button(L("ChatGPT 계정 추가", "Add ChatGPT account")) { model.add(.codex) }
                Button(L("Gemini 추가", "Add Gemini")) { model.add(.gemini) }.disabled(model.hasGemini)
            }
            Text(L("추가하면 터미널이 열려요. 그 계정으로 브라우저 로그인을 하면 돼요. 같은 ChatGPT 계정을 두 번 추가하지 마세요.", "Adding an account opens Terminal for browser sign-in. Do not add the same ChatGPT account twice."))
                .font(.caption)
                .foregroundColor(.secondary)
            Divider()
            HStack {
                Text(L("채팅 규칙", "Chat rules")).font(.headline)
                Spacer()
                Button(L("기본값으로", "Reset to default")) { model.chatRules = AppModel.defaultChatRules }
                    .disabled(model.chatRules == AppModel.defaultChatRules)
            }
            Text(L("채팅에서 AI들에게 보내는 모든 메시지 맨 앞에 붙어요. 답 길이와 말투를 여기서 정해요.", "Included with each AI request. Set the answer length and style here."))
                .font(.caption)
                .foregroundColor(.secondary)
            TextEditor(text: $model.chatRules)
                .font(.body)
                .frame(height: 96)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
            Divider()
            Toggle(L("메뉴바에 % 같이 보기", "Show percentages in the menu bar"), isOn: $model.showPercent)
            Toggle(L("로그인할 때 자동 실행", "Open at login"), isOn: Binding(get: { model.openAtLogin },
                                                    set: { model.setOpenAtLogin($0) }))
        }
        .padding(20)
        .frame(width: 600)
    }
}

private struct AccountRow: View {
    @ObservedObject var model: AppModel
    let account: Account

    var body: some View {
        HStack(spacing: 10) {
            Text(account.provider.title)
                .foregroundColor(.secondary)
                .frame(width: 64, alignment: .leading)
            TextField(L("이름", "Name"), text: Binding(
                get: { model.accounts.first { $0.id == account.id }?.name ?? "" },
                set: { model.rename(account.id, to: $0) }))
                .textFieldStyle(.roundedBorder)
            Button(action: { model.move(account, by: -1) }) { Image(systemName: "chevron.up") }
                .buttonStyle(.borderless)
                .disabled(model.accounts.first?.id == account.id)
            Button(action: { model.move(account, by: 1) }) { Image(systemName: "chevron.down") }
                .buttonStyle(.borderless)
                .disabled(model.accounts.last?.id == account.id)
            Button(L("로그인", "Sign in")) { model.login(account) }
            Button(L("빼기", "Remove")) { model.remove(account) }
        }
        .padding(.vertical, 2)
    }
}

// One Settings window, reused.
final class SettingsWindow {
    private var window: NSWindow?

    func updateLanguage() { window?.title = L("AI Illuminati 설정", "AI Illuminati Settings") }

    func show(model: AppModel) {
        if window == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(model: model)))
            w.title = L("AI Illuminati 설정", "AI Illuminati Settings")
            w.styleMask = [.titled, .closable, .miniaturizable]
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
