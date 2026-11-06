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
    // Folders every chat and every AI may read (left side of the chat window). Read only for now.
    @Published var sharedFolders: [String] {
        didSet {
            UserDefaults.standard.set(sharedFolders, forKey: "sharedFolders")
            if !pausedSharedFolders.isSubset(of: Set(sharedFolders)) { pausedSharedFolders.formIntersection(sharedFolders) }
            if !writableSharedFolders.isSubset(of: Set(sharedFolders)) { writableSharedFolders.formIntersection(sharedFolders) }
        }
    }
    // Shared folders kept in the list but not given to the AIs for now (the eye in the chat sidebar).
    @Published var pausedSharedFolders: Set<String> = [] {
        didSet { UserDefaults.standard.set(pausedSharedFolders.sorted(), forKey: "pausedSharedFolders") }
    }
    var activeSharedFolders: [String] { sharedFolders.filter { !pausedSharedFolders.contains($0) } }
    // Shared folders the AIs may also change (the pencil): backed up before each answer, like linked folders.
    // The others stay read only.
    @Published var writableSharedFolders: Set<String> = [] {
        didSet { UserDefaults.standard.set(writableSharedFolders.sorted(), forKey: "writableSharedFolders") }
    }
    // A school chat is continued only by school accounts, a personal chat only by personal ones.
    // Gemma on this Mac: on/off (menu bar) and how long it stays in memory after a reply (Settings → Accounts).
    @Published var localEnabled: Bool {
        didSet {
            UserDefaults.standard.set(localEnabled, forKey: "localEnabled")
            if !localEnabled { DispatchQueue.global(qos: .utility).async { LocalModel.unload() } }
            onAccountsChange?()
        }
    }
    @Published var localKeepAlive: Int {
        didSet { UserDefaults.standard.set(localKeepAlive, forKey: "localKeepAlive") }
    }
    @Published var schoolOnlyHandoff: Bool {
        didSet { UserDefaults.standard.set(schoolOnlyHandoff, forKey: "schoolOnlyHandoff") }
    }
    var onAccountsChange: (() -> Void)?
    var onDisplayChange: (() -> Void)?
    var onPreviewUsageMenu: (() -> Void)?

    init() {
        language = AppLanguage.current
        var loaded = AccountStore.load()
        // The first Gemma entry was named before there were two models: name its model.
        if let i = loaded.firstIndex(where: { $0.id == LocalModel.variants[0].id && ["Gemma 4 (내 Mac)", "Gemma 4 (this Mac)"].contains($0.name) }) {
            loaded[i].name = L("\(LocalModel.variants[0].title) (내 Mac)", "\(LocalModel.variants[0].title) (this Mac)")
            AccountStore.save(loaded)
        }
        accounts = loaded
        showPercent = UserDefaults.standard.bool(forKey: "showPercent")
        // The legacy show-percent option maps to "mark + %"; otherwise default to "mark + bars".
        menuBarStyle = UserDefaults.standard.string(forKey: "menuBarStyle").flatMap(MenuBarStyle.init(rawValue:))
            ?? (UserDefaults.standard.bool(forKey: "showPercent") ? .markPercent : .markBars)
        menuBarAnimation = UserDefaults.standard.object(forKey: "menuBarAnimation") as? Bool ?? true
        menuBarWindow = UserDefaults.standard.string(forKey: "menuBarWindow").flatMap(MenuBarWindow.init(rawValue:)) ?? .fiveHour
        menuBarColored = UserDefaults.standard.bool(forKey: "menuBarColored")
        usageMenuStyle = UserDefaults.standard.string(forKey: "usageMenuStyle").flatMap(UsageMenuStyle.init(rawValue:)) ?? .cards
        openAtLogin = SMAppService.mainApp.status == .enabled
        sharedFolders = UserDefaults.standard.stringArray(forKey: "sharedFolders") ?? []
        pausedSharedFolders = Set(UserDefaults.standard.stringArray(forKey: "pausedSharedFolders") ?? [])
        writableSharedFolders = Set(UserDefaults.standard.stringArray(forKey: "writableSharedFolders") ?? [])
        schoolOnlyHandoff = UserDefaults.standard.object(forKey: "schoolOnlyHandoff") as? Bool ?? true
        localEnabled = LocalModel.enabled
        localKeepAlive = LocalModel.keepAlive
        let saved = UserDefaults.standard.string(forKey: "chatRules")
        chatRules = (saved == nil || saved == Self.koreanChatRules || saved == Self.rules(for: .english)
                     || Self.oldDefaultRules.contains(saved!))
            ? Self.defaultChatRules : saved!
    }

    var hasGemini: Bool { accounts.contains { $0.provider == .gemini } }

    // New entry with a default name (renamed in Settings), then that tool's login opens in Terminal.
    func add(_ provider: Account.Provider) {
        if provider == .ollama { return addLocal(LocalModel.variants[0]) }
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

    var hasLocal: Bool { accounts.contains { $0.provider == .ollama } }
    func hasLocal(_ variant: LocalModel.Variant) -> Bool { accounts.contains { $0.id == variant.id } }

    // Gemma 4 on this Mac: check the Mac, then add the entry and open the installer in Terminal.
    func addLocal(_ variant: LocalModel.Variant) {
        NSApp.activate(ignoringOtherApps: true)
        if let why = LocalModel.unsuitable() {
            let alert = NSAlert()
            alert.messageText = L("이 Mac에서는 Gemma를 설치할 수 없어요", "Gemma cannot be installed on this Mac")
            alert.informativeText = why
            alert.runModal()
            return
        }
        let alert = NSAlert()
        alert.messageText = L("\(variant.title)를 이 Mac에 설치할까요?", "Install \(variant.title) on this Mac?")
        alert.informativeText = L("Ollama(무료)로 모델 약 \(variant.downloadGB)GB를 받아요. 터미널에서 단계마다 확인해요. 답할 때 메모리를 \(variant.memory)GB 써요. 인터넷 없이 이 Mac 안에서만 돌아가고, 사용량 한도가 없어요. @로 부르거나, 모든 클라우드 계정이 한도에 걸렸을 때 답해요. Gemma를 둘 다 받아도 메모리에는 한 번에 하나만 올라가요.",
                                  "Uses Ollama (free) to download about \(variant.downloadGB) GB; Terminal asks at each step. Uses \(variant.memory) GB of memory while answering. Runs only on this Mac, without the internet or usage limits. It answers when called with @, or when every cloud account is out of usage. With both Gemma models installed, only one is in memory at a time.")
        alert.addButton(withTitle: L("설치", "Install"))
        alert.addButton(withTitle: L("취소", "Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        if !hasLocal(variant) {
            accounts.append(Account(id: variant.id, provider: .ollama, name: L("\(variant.title) (내 Mac)", "\(variant.title) (this Mac)"), dir: nil))
        }
        LocalModel.install(variant)
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

    func setSchool(_ id: String, _ on: Bool) {
        guard let index = accounts.firstIndex(where: { $0.id == id }) else { return }
        accounts[index].school = on
    }

    func addSharedFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = L("공동 폴더로 추가", "Add as shared folder")
        guard panel.runModal() == .OK else { return }
        for url in panel.urls where !sharedFolders.contains(url.path) { sharedFolders.append(url.path) }
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
        HStack(spacing: 10) {
            Text(title).frame(width: 96, alignment: .leading)
            HStack(spacing: 6) { content }.frame(maxWidth: .infinity, alignment: .leading)
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
                .padding(12).frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .font(.system(size: 12))
        .controlSize(.small)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

// Explicit labels fill the control column; native picker intrinsic widths otherwise
// leave the visible buttons centered at different positions inside their frames.
private struct SettingsMenu<Value: Hashable>: View {
    let options: [(String, Value)]
    @Binding var selection: Value

    var body: some View {
        SettingsPopup(titles: options.map { $0.0 }, selection: Binding(
            get: { options.firstIndex { $0.1 == selection } ?? 0 },
            set: { if options.indices.contains($0) { selection = options[$0].1 } }))
            .frame(maxWidth: .infinity).frame(height: 24)
    }
}

private struct SettingsPopup: NSViewRepresentable {
    let titles: [String]
    @Binding var selection: Int

    final class Coordinator: NSObject {
        var parent: SettingsPopup
        init(_ parent: SettingsPopup) { self.parent = parent }
        @objc func select(_ sender: NSPopUpButton) { parent.selection = sender.indexOfSelectedItem }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        button.controlSize = .small
        button.font = .systemFont(ofSize: 11)
        button.target = context.coordinator
        button.action = #selector(Coordinator.select(_:))
        button.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return button
    }
    func updateNSView(_ button: NSPopUpButton, context: Context) {
        context.coordinator.parent = self
        if button.itemTitles != titles {
            button.removeAllItems()
            button.addItems(withTitles: titles)
        }
        button.selectItem(at: selection)
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSPopUpButton, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 184, height: 24)
    }
}

private struct SettingsSegments<Value: Hashable>: View {
    let options: [(String, Value)]
    @Binding var selection: Value

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options.indices, id: \.self) { index in
                Button { selection = options[index].1 } label: {
                    Text(options[index].0).lineLimit(1)
                        .frame(maxWidth: .infinity, minHeight: 22)
                        .foregroundStyle(selection == options[index].1 ? Color.white : Color.primary)
                        .background(RoundedRectangle(cornerRadius: 4).fill(selection == options[index].1 ? Color.accentColor : Color.clear))
                }.buttonStyle(.plainHit)
                    .accessibilityAddTraits(selection == options[index].1 ? [.isSelected] : [])
            }
        }
        .padding(2).background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))
    }
}

// Like .plain, but the whole frame of the label is clickable, not only the drawn pixels of an icon
// (a thin pencil was almost impossible to hit). Dims while pressed or disabled.
struct PlainHitButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { HitArea(configuration: configuration) }
    private struct HitArea: View {
        let configuration: Configuration
        @Environment(\.isEnabled) private var enabled
        var body: some View {
            configuration.label
                .contentShape(Rectangle())
                .opacity(!enabled ? 0.4 : configuration.isPressed ? 0.6 : 1)
        }
    }
}
extension ButtonStyle where Self == PlainHitButtonStyle {
    static var plainHit: PlainHitButtonStyle { PlainHitButtonStyle() }
}

private struct SettingsAction: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title).lineLimit(1).frame(maxWidth: .infinity, minHeight: 24)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.07)))
        }.buttonStyle(.plainHit)
    }
}

// What most apps have: language, launch at login, updates, where data lives, and the version.
struct GeneralSettingsTab: View {
    @ObservedObject var model: AppModel

    var body: some View {
        SettingsPage {
            SettingsCard(title: L("앱", "App")) {
                SettingsRow(title: L("언어", "Language")) {
                    SettingsSegments(options: [("English", AppLanguage.english), ("한국어", .korean)], selection: $model.language)
                }
                Divider()
                SettingsRow(title: L("로그인 시 실행", "Open at login")) {
                    Spacer()
                    Toggle(L("로그인 시 실행", "Open at login"), isOn: Binding(
                        get: { model.openAtLogin }, set: { model.setOpenAtLogin($0) }))
                        .labelsHidden().toggleStyle(.switch)
                }
            }
            MaintenanceSettings(updater: model.updater)
        }
    }
}

// The menu bar mark and the usage menu.
struct AppearanceSettingsTab: View {
    @ObservedObject var model: AppModel

    private var menuOptions: [(String, AppModel.UsageMenuStyle)] {
        [(L("카드", "Cards"), .cards), (L("막대", "Bars"), .comparison),
         (L("막대 + 충전 시계", "Bars + reset rings"), .comparisonRings),
         (L("충전 시계", "Reset rings"), .compact)]
    }

    var body: some View {
        SettingsPage {
            SettingsCard(title: L("메뉴바", "Menu bar")) {
                SettingsRow(title: L("표시", "Show")) {
                    SettingsMenu(options: AppModel.MenuBarStyle.allCases.map { ($0.title, $0) }, selection: $model.menuBarStyle)
                }
                Divider()
                SettingsRow(title: L("잔여량 기준", "Usage limit")) {
                    SettingsSegments(options: AppModel.MenuBarWindow.allCases.map { ($0.title, $0) }, selection: $model.menuBarWindow)
                        .help(L("선택한 한도의 남은 양이에요. 한도가 없으면 가득 찬 막대, 읽지 못했으면 빈 막대예요.", "Remaining usage for this limit. No limit: full bar. Unread: empty bar."))
                }
                Divider()
                SettingsRow(title: L("흑백", "Monochrome")) {
                    Spacer()
                    Toggle(L("흑백", "Monochrome"), isOn: Binding(get: { !model.menuBarColored }, set: { model.menuBarColored = !$0 }))
                        .labelsHidden().toggleStyle(.switch)
                        .help(L("끄면 계정 종류별 컬러로 표시해요.", "Turn off to use provider colors."))
                }
                Divider()
                SettingsRow(title: L("애니메이션", "Animate")) {
                    Spacer()
                    Toggle(L("애니메이션", "Animate"), isOn: $model.menuBarAnimation)
                        .labelsHidden().toggleStyle(.switch)
                        .help(L("눈 깜빡임과 후광. macOS '동작 줄이기'를 켜면 멈춰요.", "Eye blinks and halo. Stops with macOS Reduce Motion."))
                }
            }
            SettingsCard(title: L("사용량 메뉴", "Usage menu")) {
                SettingsRow(title: L("모양", "Style")) {
                    SettingsMenu(options: menuOptions, selection: $model.usageMenuStyle)
                    Button { model.onPreviewUsageMenu?() } label: {
                        Image(systemName: "eye").frame(width: 24, height: 24)
                            .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.07)))
                    }.buttonStyle(.plainHit)
                        .help(L("메뉴 미리 보기", "Preview usage menu"))
                        .accessibilityLabel(L("메뉴 미리 보기", "Preview usage menu"))
                }
            }
        }
    }
}

private struct MaintenanceSettings: View {
    @ObservedObject var updater: Updater

    // "0.2.0 (82 · a1fb746)": the app version, the build number and the source revision it was built from.
    static var version: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let short = info["CFBundleShortVersionString"] as? String ?? "–"
        let build = info["CFBundleVersion"] as? String ?? "–"
        let revision = (info["AISourceRevision"] as? String).map { " · " + $0.prefix(7) } ?? ""
        return "\(short) (\(build)\(revision))"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
        SettingsCard(title: L("업데이트", "Updates")) {
            // Switches sit at the right end of their row.
            SettingsRow(title: L("새 버전 확인", "Check updates")) {
                SettingsAction(title: L("지금 확인", "Check now")) { updater.check() }
                    .disabled(updater.checking)
                Toggle(L("새 버전 자동 확인", "Check for updates automatically"), isOn: $updater.enabled)
                    .labelsHidden().toggleStyle(.switch)
                    .help(L("켜면 시작 후, 그리고 3시간마다 확인만 해요. 설치는 버튼을 눌러야 해요.",
                            "Checks at launch and every 3 hours. Installing always needs the button."))
            }
            if updater.available != nil {
                SettingsRow(title: L("새 버전", "New version")) {
                    SettingsAction(title: L("지금 업데이트", "Update Now")) { updater.install() }
                        .disabled(updater.checking)
                }
            }
            Text(updater.status.isEmpty ? L("새 버전은 확인만 하고, 설치는 버튼을 눌러야 해요.", "Checks only; installing needs the button.") : updater.status)
                .font(.system(size: 10)).foregroundStyle(.secondary)
                .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10).padding(.bottom, 7)
                .help(updater.status + "\n" + L("시험과 빌드가 통과해야 교체해요. 채팅·게임 중에는 기다려요.", "Installs after tests and build pass. Waits for chats and games."))
            Divider()
            SettingsRow(title: L("버전", "Version")) {
                Text(Self.version).font(.system(size: 12)).foregroundStyle(.secondary).textSelection(.enabled)
                Spacer()
            }
        }
        SettingsCard(title: L("저장 위치", "Storage")) {
            SettingsRow(title: L("저장 폴더", "Folders")) {
                SettingsAction(title: L("앱 데이터", "App data")) { DataFolders.open(DataFolders.appData) }
                    .help(L("계정 목록, 대화와 첨부 사본", "Account list, chats and attachment copies"))
                SettingsAction(title: L("계정", "Accounts")) { DataFolders.open(DataFolders.accounts) }
                    .help(L("로그인 정보가 있어요. 공유하지 마세요.", "Contains sign-in data. Do not share."))
            }
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
                    Divider()
                    ForEach(LocalModel.variants, id: \.id) { variant in
                        Button(L("\(variant.title) (내 Mac) 설치…", "Install \(variant.title) (this Mac)…")) { model.addLocal(variant) }
                            .disabled(model.hasLocal(variant))
                    }
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
            Toggle(L("엔터프라이즈·개인 대화를 따로 이어받기", "Keep Enterprise and personal chats apart"), isOn: $model.schoolOnlyHandoff)
                .toggleStyle(.switch)
            Text(L("켜면 엔터프라이즈 대화는 엔터프라이즈 계정끼리, 개인 대화는 개인 계정끼리만 이어받아요. 엔터프라이즈 계정은 계정 탭에서 표시해요.",
                   "On: Enterprise chats are continued only by Enterprise accounts, personal chats only by personal ones. Mark Enterprise accounts in the Accounts tab."))
                .font(.system(size: 11)).foregroundStyle(.secondary)
            MCPSettings()
        }
        .padding(12).controlSize(.small)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

// MCP servers the chat's AI may use, one switch each (like the ChatGPT app). AI Face adds itself when
// AI Illuminati is connected in AI Face; which of its tools work is set there.
private struct MCPSettings: View {
    @ObservedObject var link = FaceLink.shared
    @ObservedObject var drive = DriveCenter.shared

    var body: some View {
        SettingsCard(title: L("MCP 서버", "MCP servers")) {
            if link.configured {
                SettingsRow(title: "ai-face") {
                    Text(!link.on ? L("꺼짐", "Off") : link.connected ? L("연결됨", "Connected") : L("연결 중…", "Connecting…"))
                        .foregroundStyle(link.on && link.connected ? .green : .secondary)
                    Spacer()
                    Toggle("ai-face", isOn: $link.on).labelsHidden().toggleStyle(.switch)
                }
                .help(L("AI Face: 일반 채팅의 AI가 표정을 바꿔요. 캘린더·메일·폴더 권한은 AI Face 설정에서 정해요.",
                        "AI Face: the AI in plain chat sets the face. Calendar, mail and folder access is set in AI Face."))
            } else {
                note(L("ai-face: 없어요. AI Face 설정 → AI에서 AI Illuminati를 연결하면 여기에 보여요.",
                       "ai-face: none. Connect AI Illuminati in AI Face (Settings → AI) and it shows here."))
            }
            // Google Drive (read only): connected and its folders chosen in the chat window's sidebar.
            if drive.connected || drive.needsReconnect {
                SettingsRow(title: "google-drive") {
                    Text(drive.needsReconnect ? L("다시 연결 필요", "Reconnect needed")
                         : !drive.on ? L("꺼짐", "Off")
                         : drive.folders.isEmpty ? L("연결됨 · 폴더 없음", "Connected · no folders")
                         : L("읽기 전용 · 폴더 \(drive.folders.count - drive.paused.count)개", "Read only · \(drive.folders.count - drive.paused.count) folders"))
                        .foregroundStyle(drive.needsReconnect ? .orange : drive.on && !drive.folders.isEmpty ? .green : .secondary)
                    Spacer()
                    Toggle("google-drive", isOn: $drive.on).labelsHidden().toggleStyle(.switch)
                }
                .help(L("Google 드라이브: 일반 채팅의 AI가 고른 드라이브 폴더만 읽어요. 연결과 폴더는 채팅창 사이드바에서 정해요.",
                        "Google Drive: the AI in plain chat reads only the chosen Drive folders. Connect and choose folders in the chat window's sidebar."))
            } else {
                note(L("google-drive: 연결 안 됨. 채팅창 사이드바의 Google Drive에서 연결해요.",
                       "google-drive: not connected. Connect it under Google Drive in the chat window's sidebar."))
            }
        }
        .onAppear { link.refresh(); drive.refresh() }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11)).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10).padding(.vertical, 8)
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
                HStack(spacing: 6) {
                    Text(account.provider.title).foregroundStyle(.secondary)
                    status
                    if account.provider == .ollama {
                        // How long Gemma stays in memory after a reply (closing the chat window unloads it anyway).
                        Menu {
                            Picker(L("답한 뒤 메모리에 남겨 두기", "Keep in memory after a reply"), selection: $model.localKeepAlive) {
                                ForEach(LocalModel.keepAliveChoices, id: \.self) { Text(LocalModel.keepAliveName($0)).tag($0) }
                            }
                        } label: {
                            Text(L("유지 ", "Keep ") + LocalModel.keepAliveName(model.localKeepAlive))
                        }
                        .menuStyle(.borderlessButton).fixedSize().controlSize(.mini)
                        .help(L("답한 뒤 Gemma를 메모리에 남겨 두는 시간. 다시 부를 때 기다리지 않아요. 채팅창을 닫으면 바로 내려요.",
                                "How long Gemma stays in memory after a reply, so the next one starts at once. Closing the chat window unloads it."))
                    }
                    if account.provider != .gemini && account.provider != .ollama {
                        Toggle(L("엔터프라이즈", "Enterprise"), isOn: Binding(
                            get: { model.accounts.first { $0.id == account.id }?.isSchool ?? false },
                            set: { model.setSchool(account.id, $0) }))
                            .toggleStyle(.checkbox).controlSize(.mini)
                            .help(L("엔터프라이즈(학교·회사) 계정: 엔터프라이즈 대화는 이런 계정끼리만 이어받아요", "Enterprise (school or work) account: Enterprise chats are continued only by these accounts"))
                    }
                }.font(.system(size: 10)).lineLimit(1)
            }
            Spacer(minLength: 4)
            Button(action: { model.move(account, by: -1) }) { Image(systemName: "chevron.up") }
                .buttonStyle(.borderless)
                .disabled(model.accounts.first?.id == account.id)
            Button(action: { model.move(account, by: 1) }) { Image(systemName: "chevron.down") }
                .buttonStyle(.borderless)
                .disabled(model.accounts.last?.id == account.id)
            Menu {
                Button(account.provider == .ollama ? L("설치·업데이트…", "Install or update…") : L("로그인…", "Sign in…")) { model.login(account) }
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
                Text(L("\(Int(left.rounded()))% 남음", "\(Int(left.rounded()))% left")).foregroundStyle(.green)
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
    static let size = NSSize(width: 334, height: 420)

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
        guard let items = tabs?.tabViewItems, items.count == 4 else { return }
        for (item, title) in zip(items, [L("일반", "General"), L("모양", "Appearance"), L("계정", "Accounts"), L("채팅", "Chat")]) {
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
            t.addTabViewItem(tab(AppearanceSettingsTab(model: model), symbol: "paintbrush"))
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

// A section title in the chat sidebar, with an optional accessory (a + button) on the right.
struct SidebarHeader<Accessory: View>: View {
    let title: String
    let accessory: Accessory
    init(title: String, @ViewBuilder accessory: () -> Accessory) { self.title = title; self.accessory = accessory() }

    var body: some View {
        HStack {
            Text(title).font(.system(size: 11, weight: .medium)).foregroundColor(.secondary)
            Spacer()
            accessory
        }
        .padding(.horizontal, 10).padding(.top, 16).padding(.bottom, 4)
    }
}

extension SidebarHeader where Accessory == EmptyView {
    init(title: String) { self.init(title: title) { EmptyView() } }
}
