import Cocoa
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

// What the menu and the Settings window share: the account list (saved on every change) and
// the display options. The menu listens through the two callbacks.
final class AppModel: ObservableObject {
    @Published var accounts: [Account] {
        didSet {
            if persist { AccountStore.save(accounts) }
            onAccountsChange?()
        }
    }
    // A preview model (persist: false) starts with no accounts and default settings, and never
    // reads or writes the account list; its settings go to a throwaway file.
    let persist: Bool
    private let defaults: UserDefaults
    @Published var draggingAccount: String?   // Settings > Accounts row being dragged
    @Published var showPercent: Bool {
        didSet {
            defaults.set(showPercent, forKey: "showPercent")
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
            defaults.set(menuBarStyle.rawValue, forKey: "menuBarStyle")
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
            defaults.set(menuBarWindow.rawValue, forKey: "menuBarWindow")
            onDisplayChange?()
        }
    }
    // Accounts left out of the menu bar bars and numbers (Settings → Appearance). The usage menu still lists them;
    // a new account starts shown.
    @Published var menuBarHidden: Set<String> {
        didSet {
            defaults.set(menuBarHidden.sorted(), forKey: "menuBarHidden")
            onDisplayChange?()
        }
    }
    var menuBarAccounts: [Account] { accounts.filter { !menuBarHidden.contains($0.id) } }
    @Published var menuBarColored: Bool {
        didSet {
            defaults.set(menuBarColored, forKey: "menuBarColored")
            onDisplayChange?()
        }
    }
    @Published var menuBarAnimation: Bool {
        didSet {
            defaults.set(menuBarAnimation, forKey: "menuBarAnimation")
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
            defaults.set(usageMenuStyle.rawValue, forKey: "usageMenuStyle")
            onDisplayChange?()
        }
    }
    @Published private(set) var openAtLogin: Bool
    let updater = Updater()
    // Rules put at the top of every message the chat sends to an AI (edited in Settings).
    @Published var chatRules: String {
        didSet { defaults.set(chatRules, forKey: "chatRules") }
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
            defaults.set(sharedFolders, forKey: "sharedFolders")
            if !pausedSharedFolders.isSubset(of: Set(sharedFolders)) { pausedSharedFolders.formIntersection(sharedFolders) }
            if !writableSharedFolders.isSubset(of: Set(sharedFolders)) { writableSharedFolders.formIntersection(sharedFolders) }
        }
    }
    // Shared folders kept in the list but not given to the AIs for now (the eye in the chat sidebar).
    @Published var pausedSharedFolders: Set<String> = [] {
        didSet { defaults.set(pausedSharedFolders.sorted(), forKey: "pausedSharedFolders") }
    }
    var activeSharedFolders: [String] { sharedFolders.filter { !pausedSharedFolders.contains($0) } }
    // Shared folders the AIs may also change (the pencil): backed up before each answer, like linked folders.
    // The others stay read only.
    @Published var writableSharedFolders: Set<String> = [] {
        didSet { defaults.set(writableSharedFolders.sorted(), forKey: "writableSharedFolders") }
    }
    // A school chat is continued only by school accounts, a personal chat only by personal ones.
    // Ollama models on this Mac: on/off (Settings → Accounts) and how long it stays in memory after a reply (Settings → Accounts).
    @Published var localEnabled: Bool {
        didSet {
            defaults.set(localEnabled, forKey: "localEnabled")
            if !localEnabled { DispatchQueue.global(qos: .utility).async { LocalModel.unload() } }
            onAccountsChange?()
        }
    }
    @Published var localKeepAlive: Int {
        didSet { defaults.set(localKeepAlive, forKey: "localKeepAlive") }
    }
    // Which model on this Mac sorts a project chat's messages into one, all or work (Route.swift).
    @Published var routeSorter: RouteSorter {
        didSet { defaults.set(routeSorter.rawValue, forKey: "routeSorter") }
    }
    // ChatGPT accounts unchecked as picture makers (Settings → Chat). The others draw every picture the
    // other AIs need; a new ChatGPT account starts checked.
    @Published var pictureMakersOff: Set<String> {
        didSet { defaults.set(pictureMakersOff.sorted(), forKey: "pictureMakersOff") }
    }
    var pictureMakers: [Account] { accounts.filter { $0.provider == .codex && !pictureMakersOff.contains($0.id) } }
    var onAccountsChange: (() -> Void)?
    var onDisplayChange: (() -> Void)?
    var onPreviewUsageMenu: (() -> Void)?

    init(persist: Bool = true) {
        self.persist = persist
        defaults = persist ? .app : UserDefaults(suiteName: NSTemporaryDirectory() + "ai-illuminati-preview-" + UUID().uuidString)!
        var loaded: [Account] = []
        if persist {
            defaults.removeObject(forKey: "appLanguage")   // the old in-app choice; macOS decides now
            loaded = AccountStore.load()
            // The first Gemma entry was named before there were two models: name its model.
            if let i = loaded.firstIndex(where: { $0.id == LocalModel.legacy[0].id && ["Gemma 4 (내 Mac)", "Gemma 4 (this Mac)"].contains($0.name) }) {
                loaded[i].name = L("\(LocalModel.legacy[0].title) (내 Mac)", "\(LocalModel.legacy[0].title) (this Mac)")
                AccountStore.save(loaded)
            }
        }
        accounts = loaded
        showPercent = defaults.bool(forKey: "showPercent")
        // The legacy show-percent option maps to "mark + %"; otherwise default to "mark + bars".
        menuBarStyle = defaults.string(forKey: "menuBarStyle").flatMap(MenuBarStyle.init(rawValue:))
            ?? (defaults.bool(forKey: "showPercent") ? .markPercent : .markBars)
        menuBarAnimation = defaults.object(forKey: "menuBarAnimation") as? Bool ?? true
        menuBarWindow = defaults.string(forKey: "menuBarWindow").flatMap(MenuBarWindow.init(rawValue:)) ?? .fiveHour
        menuBarColored = defaults.bool(forKey: "menuBarColored")
        menuBarHidden = Set(defaults.stringArray(forKey: "menuBarHidden") ?? [])
        usageMenuStyle = defaults.string(forKey: "usageMenuStyle").flatMap(UsageMenuStyle.init(rawValue:)) ?? .cards
        openAtLogin = SMAppService.mainApp.status == .enabled
        sharedFolders = defaults.stringArray(forKey: "sharedFolders") ?? []
        pausedSharedFolders = Set(defaults.stringArray(forKey: "pausedSharedFolders") ?? [])
        writableSharedFolders = Set(defaults.stringArray(forKey: "writableSharedFolders") ?? [])
        pictureMakersOff = Set(defaults.stringArray(forKey: "pictureMakersOff") ?? [])
        localEnabled = persist ? LocalModel.enabled : true
        localKeepAlive = persist ? LocalModel.keepAlive : 5
        routeSorter = persist ? RouteSorter.current : .off
        // A saved default in either language becomes the default in today's language.
        let saved = defaults.string(forKey: "chatRules")
        chatRules = (saved == nil || saved == Self.koreanChatRules || saved == Self.rules(for: .english)
                     || Self.oldDefaultRules.contains(saved!))
            ? Self.defaultChatRules : saved!
    }

    var hasGemini: Bool { accounts.contains { $0.provider == .gemini } }

    // New entry with a default name (renamed in Settings), then that tool's login opens in Terminal.
    func add(_ provider: Account.Provider) {
        if provider == .ollama { return LocalModelsWindow.shared.show(model: self) }
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
    func hasLocal(_ model: String) -> Bool {
        accounts.contains { $0.provider == .ollama && LocalModel.same(LocalModel.variant($0).model, model) }
    }

    // An Ollama model on this Mac: check the Mac, ask, add the entry, then download it in the app (or, without
    // Ollama, open the installer in Terminal). `downloadGB` is nil when the size is not known yet.
    func addLocal(_ name: String, downloadGB: Double?) {
        let model = LocalModel.normalized(name)
        if LocalModel.sortOnly(model) { return addSortModel(.decider) }
        NSApp.activate(ignoringOtherApps: true)
        let title = LocalModel.title(for: model)
        if let why = LocalModel.unsuitable(downloadGB: downloadGB ?? 0) {
            let alert = NSAlert()
            alert.messageText = L("이 Mac에서는 \(title)를 설치할 수 없어요", "\(title) cannot be installed on this Mac")
            alert.informativeText = why
            alert.runModal()
            return
        }
        let alert = NSAlert()
        alert.messageText = L("\(title)를 이 Mac에 설치할까요?", "Install \(title) on this Mac?")
        let size = downloadGB.map { String(format: "%.1f", $0) }
        let need = downloadGB.map { String(format: "%.0f", LocalModel.memoryNeed(downloadGB: $0).rounded(.up)) }
        var fit = ""
        if let downloadGB, LocalModel.fit(downloadGB: downloadGB) != .good { fit = "\n\n" + LocalModel.fit(downloadGB: downloadGB).title + "." }
        let ollama = LocalModel.binary == nil ? L(" Ollama(무료)가 없어서 터미널에서 먼저 설치해요.", " Ollama (free) is not installed yet, so Terminal installs it first.") : ""
        alert.informativeText = L("모델 \(model)\(size.map { " 약 \($0)GB" } ?? "")를 받아요.\(need.map { " 답할 때 메모리를 약 \($0)GB 써요." } ?? "")\(ollama) 인터넷 없이 이 Mac 안에서만 돌아가고, 사용량 한도가 없어요. @로 부르거나, 모든 클라우드 계정이 한도에 걸렸을 때 답해요. 여러 모델을 받아도 메모리에는 한 번에 하나만 올라가요.\(fit)",
                                  "Downloads \(model)\(size.map { ", about \($0) GB" } ?? "").\(need.map { " Uses about \($0) GB of memory while answering." } ?? "")\(ollama) Runs only on this Mac, without the internet or usage limits. It answers when called with @, or when every cloud account is out of usage. With several models installed, only one is in memory at a time.\(fit)")
        alert.addButton(withTitle: L("설치", "Install"))
        alert.addButton(withTitle: L("취소", "Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        if !hasLocal(model) { accounts.append(LocalModel.account(for: model)) }
        let account = accounts.first { $0.provider == .ollama && LocalModel.same(LocalModel.variant($0).model, model) }!
        if LocalModel.binary == nil { LocalModel.install(LocalModel.variant(account)) } else { LocalModelStore.shared.pull(model) }
    }

    // A model already on this Mac (downloaded in Terminal, say) joins the list without downloading.
    func addInstalled(_ name: String) {
        if !hasLocal(name) && !LocalModel.sortOnly(name) { accounts.append(LocalModel.account(for: name)) }
    }

    // The message-sorting model (Settings → Chat): ask, then download it in the app, or open the Ollama installer in
    // Terminal. It does not join the account list.
    func addSortModel(_ sorter: RouteSorter) {
        guard let variant = sorter.variant else { return }
        NSApp.activate(ignoringOtherApps: true)
        if let why = LocalModel.unsuitable(downloadGB: sorter.downloadGB) {
            let alert = NSAlert()
            alert.messageText = L("이 Mac에서는 \(variant.title)를 설치할 수 없어요", "\(variant.title) cannot be installed on this Mac")
            alert.informativeText = why
            alert.runModal()
            return
        }
        let alert = NSAlert()
        alert.messageText = L("\(variant.title)를 이 Mac에 받을까요?", "Download \(variant.title) to this Mac?")
        let size = String(format: "%.1f", sorter.downloadGB)
        let ollama = LocalModel.binary == nil ? L(" Ollama(무료)가 없어서 터미널에서 먼저 설치해요.", " Ollama (free) is not installed yet, so Terminal installs it first.") : ""
        let only = LocalModel.sortOnly(variant.model) ? L(" 채팅 목록이나 @에는 나오지 않아요.", " It does not appear in the chat list or with @.") : ""
        alert.informativeText = L("모델 \(variant.model) 약 \(size)GB를 받아요.\(ollama) 프로젝트 채팅에서 메시지 판정에 써요.\(only)",
                                  "Downloads \(variant.model), about \(size) GB.\(ollama) It sorts messages in project chats.\(only)")
        alert.addButton(withTitle: L("받기", "Download"))
        alert.addButton(withTitle: L("취소", "Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        if LocalModel.binary == nil { LocalModel.install(variant) } else { LocalModelStore.shared.pull(variant.model) }
    }

    func login(_ account: Account) {
        // An Ollama model: download it again (gets updates); without Ollama, Terminal installs it first.
        if account.provider == .ollama {
            if LocalModel.binary == nil { LocalModel.install(LocalModel.variant(account)) } else { LocalModelStore.shared.pull(LocalModel.variant(account).model) }
            return
        }
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

    // Drag to reorder: the dragged account takes the place of the one it is over.
    func move(_ id: String, to target: String) {
        guard id != target,
              let from = accounts.firstIndex(where: { $0.id == id }),
              let to = accounts.firstIndex(where: { $0.id == target }) else { return }
        accounts.insert(accounts.remove(at: from), at: to)
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
        if account.provider == .ollama { return removeLocal(account) }
        let alert = NSAlert()
        alert.messageText = L("'\(account.name)'을 목록에서 뺄까요?", "Remove “\(account.name)” from the list?")
        alert.informativeText = L("목록에서만 빠져요. 그 계정의 로그인 정보는 지우지 않아요.", "This removes the account from the list. Its sign-in credentials are kept.")
        alert.addButton(withTitle: L("빼기", "Remove"))
        alert.addButton(withTitle: L("취소", "Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        accounts.removeAll { $0.id == account.id }
    }

    // An Ollama model: off the list only, or its files deleted too (unless another entry uses the same model).
    func removeLocal(_ account: Account) {
        let model = LocalModel.variant(account).model
        let shared = accounts.contains { $0.id != account.id && $0.provider == .ollama && LocalModel.same(LocalModel.variant($0).model, model) }
        let onDisk = shared ? nil : LocalModel.installed(timeout: 1)?.first { LocalModel.matches($0.name, model) }
        let alert = NSAlert()
        alert.messageText = L("'\(account.name)'을 목록에서 뺄까요?", "Remove “\(account.name)” from the list?")
        if let onDisk {
            let size = String(format: "%.1f", Double(onDisk.bytes) / 1e9)
            alert.informativeText = L("모델 파일(\(size)GB)도 지우면 디스크가 비워져요. 나중에 다시 받을 수 있어요.", "Deleting the model files too frees \(size) GB of disk. You can download it again later.")
            alert.addButton(withTitle: L("모델 파일도 지우기", "Delete Model Files Too"))
            alert.addButton(withTitle: L("목록에서만 빼기", "Remove from List Only"))
        } else {
            alert.informativeText = L("목록에서만 빠져요.", "This removes the entry from the list.")
            alert.addButton(withTitle: L("빼기", "Remove"))
        }
        alert.addButton(withTitle: L("취소", "Cancel"))
        let answer = alert.runModal()
        if answer == .alertThirdButtonReturn || (onDisk == nil && answer == .alertSecondButtonReturn) { return }
        accounts.removeAll { $0.id == account.id }
        if let onDisk, answer == .alertFirstButtonReturn { LocalModelStore.shared.delete(onDisk.name) }
    }

    func setOpenAtLogin(_ on: Bool) {
        guard persist else { return }
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
            Text(title).frame(width: 118, alignment: .leading)   // fits "Check automatically" on one line
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
    var prominent = false   // blue, for the one thing to do next (Update Now)
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title).lineLimit(1).frame(maxWidth: .infinity, minHeight: 24)
                .foregroundStyle(prominent ? Color.white : Color.primary)
                .background(RoundedRectangle(cornerRadius: 5).fill(prominent ? Color.accentColor : Color.primary.opacity(0.07)))
        }.buttonStyle(.plainHit)
    }
}

// The same General tab as AI Face and Cats in Menubar (docs/SETTINGS_GENERAL.md):
// App, Updates, Folders, About, in that order. The language follows macOS.
struct GeneralSettingsTab: View {
    @ObservedObject var model: AppModel

    var body: some View {
        SettingsPage {
            SettingsCard(title: L("앱", "App")) {
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
            if !model.accounts.isEmpty {
                SettingsCard(title: L("메뉴바에 보일 계정", "Accounts in the menu bar")) {
                    ForEach(model.accounts, id: \.id) { account in
                        if account.id != model.accounts.first?.id { Divider() }
                        SettingsRow(title: account.name) {
                            Spacer()
                            Toggle(account.name, isOn: Binding(
                                get: { !model.menuBarHidden.contains(account.id) },
                                set: { on in if on { model.menuBarHidden.remove(account.id) } else { model.menuBarHidden.insert(account.id) } }))
                                .labelsHidden().toggleStyle(.switch)
                        }
                    }
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

    // "0.3.0 Beta (3a3588d)": the app version and the source revision it was built from.
    // The build number and the full revision show on hover.
    static var version: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let short = info["CFBundleShortVersionString"] as? String ?? "–"
        let revision = (info["AISourceRevision"] as? String).map { " (" + $0.prefix(7) + ")" } ?? ""
        let beta = UpdateChannel.built == "main" ? " Beta" : ""   // built from main, not stable
        return "\(short)\(beta)\(revision)"
    }
    static var versionDetail: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let build = info["CFBundleVersion"] as? String ?? "–"
        return L("빌드 ", "Build ") + build + ((info["AISourceRevision"] as? String).map { " · " + $0 } ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
        SettingsCard(title: L("업데이트", "Updates")) {
            SettingsRow(title: L("자동 확인", "Check automatically")) {
                Spacer()
                Toggle(L("새 버전 자동 확인", "Check for updates automatically"), isOn: $updater.enabled)
                    .labelsHidden().toggleStyle(.switch)
                    .help(L("켜면 시작 후, 그리고 3시간마다 확인만 해요. 설치는 버튼을 눌러야 해요.",
                            "Checks at launch and every 3 hours. Installing always needs the button."))
            }
            Divider()
            SettingsRow(title: L("채널", "Channel")) {
                SettingsMenu(options: [(L("안정", "Stable"), "stable"), (L("베타(main, 테스트용)", "Beta (main, for testing)"), "main")],
                             selection: Binding(get: { updater.channel }, set: { updater.setChannel($0) }))
                    .disabled(updater.checking || updater.installing)
                    .help(L("안정 채널은 테스트를 거쳐 배포된 버전만 받아요. 베타는 새 변경이 먼저 올라오는 main을 따라가서 깨져 있을 수도 있어요. 안정으로 돌아가면 stable이 지금 쓰는 버전을 따라잡을 때 업데이트돼요.",
                            "Stable gets versions that were published after testing. Beta follows main, where new changes arrive first; it may be broken. Going back to Stable updates once stable catches up with the version you run."))
            }
            Divider()
            // Check Now until a new version is found, then the blue Update Now in the same place.
            // While it installs, the step bar takes the card's full width (five named steps do not fit
            // the value column), with Update Now again under a bar that stopped.
            if let progress = updater.progress {
                VStack(alignment: .leading, spacing: 6) {
                    UpdateProgressBar(progress: progress)
                    if progress.failed, updater.available != nil {
                        SettingsAction(title: L("지금 업데이트", "Update Now"), prominent: true) { updater.install() }
                            .disabled(updater.checking || updater.installing)
                    }
                }
                .padding(.horizontal, 10).padding(.vertical, 8)
            } else {
                SettingsRow(title: L("새 버전", "New version")) {
                    if updater.available != nil {
                        SettingsAction(title: L("지금 업데이트", "Update Now"), prominent: true) { updater.install() }
                            .disabled(updater.checking || updater.installing)
                    } else {
                        SettingsAction(title: L("지금 확인", "Check Now")) { updater.check() }
                            .disabled(updater.checking || updater.installing)
                    }
                }
            }
            Text((updater.channel == "main" ? L("베타: 아직 테스트되지 않은 변경이 올 수 있어요.", "Beta: changes may not be tested yet.") + "\n" : "")
                 + (updater.status.isEmpty ? L("새 버전은 확인만 하고, 설치는 버튼을 눌러야 해요.", "Checks only; installing needs the button.") : updater.status))
                .font(.system(size: 10)).foregroundStyle(.secondary)
                .lineLimit(3).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10).padding(.bottom, 7)
                .help(updater.status + "\n" + L("시험과 빌드가 통과해야 교체해요. 채팅·게임 중에는 기다려요.", "Installs after tests and build pass. Waits for chats and games."))
        }
        SettingsCard(title: L("폴더", "Folders")) {
            SettingsRow(title: L("열기", "Open")) {
                SettingsAction(title: L("앱 데이터", "App data")) { DataFolders.open(DataFolders.appData) }
                    .help(L("계정 목록, 대화와 첨부 사본", "Account list, chats and attachment copies"))
                SettingsAction(title: L("계정", "Accounts")) { DataFolders.open(DataFolders.accounts) }
                    .help(L("로그인 정보가 있어요. 공유하지 마세요.", "Contains sign-in data. Do not share."))
                SettingsAction(title: L("앱", "App")) { DataFolders.reveal(Bundle.main.bundleURL) }
                    .help(Bundle.main.bundlePath)
            }
        }
        SettingsCard(title: L("정보", "About")) {
            SettingsRow(title: L("버전", "Version")) {
                Text(Self.version).font(.system(size: 12)).foregroundStyle(.secondary).textSelection(.enabled)
                    .help(Self.versionDetail)
                Spacer()
            }
            Divider()
            SettingsRow(title: L("라이선스", "Licenses")) {
                SettingsAction(title: L("보기", "Show")) {
                    if let url = Bundle.main.url(forResource: "THIRD_PARTY_NOTICES", withExtension: "md") { NSWorkspace.shared.open(url) }
                }
                .disabled(Bundle.main.url(forResource: "THIRD_PARTY_NOTICES", withExtension: "md") == nil)
            }
        }
        }
    }
}

// Five segments for fetch, test, build, prepare and restart: done ones full, the current one filling
// by last time's duration (pulsing when there is none), yellow while waiting, red where it stopped.
// Below: the step, time elapsed and left, and the last line of output, so a stalled step shows.
private struct UpdateProgressBar: View {
    let progress: UpdateProgress

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let now = context.date
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .top, spacing: 3) {
                    ForEach(0 ..< UpdateProgress.count, id: \.self) { step in
                        VStack(alignment: .leading, spacing: 3) {
                            segment(step, now)
                            Text(UpdateProgress.names[step] + (step < progress.stage ? " ✓" : ""))
                                .font(.system(size: 10, weight: step == progress.stage ? .semibold : .regular))
                                .foregroundStyle(step == progress.stage ? Color.primary : Color.secondary)
                                .lineLimit(1)
                        }
                    }
                }
                Text(progress.summary(at: now))
                    .font(.system(size: 11)).foregroundStyle(tint == .accentColor ? Color.primary : tint)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                if let output = output(now) {
                    Text(output).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)   // a long line must not squeeze the steps
                        .help(progress.line)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var tint: Color { progress.failed ? .red : progress.waiting ? .yellow : .accentColor }

    private func segment(_ step: Int, _ now: Date) -> some View {
        let current = step == progress.stage
        let fill: Double = step < progress.stage ? 1
            : current ? (progress.failed || progress.waiting ? 1 : progress.fraction(at: now) ?? 0.5) : 0
        // Without last time's duration the current segment pulses instead of pretending to know.
        let pulse = current && !progress.failed && !progress.waiting && progress.fraction(at: now) == nil
            && Int(now.timeIntervalSince1970) % 2 == 1
        return GeometryReader { box in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.1))
                Capsule().fill(current ? tint : Color.accentColor)
                    .frame(width: box.size.width * fill)
                    .opacity(pulse ? 0.45 : 1)
                    .animation(.easeInOut(duration: 0.9), value: pulse)
            }
        }
        .frame(height: 4)
    }

    private func output(_ now: Date) -> String? {
        let quiet = progress.quiet(at: now).map { L("\(UpdateProgress.duration($0))째 새 출력 없음", "no output for \(UpdateProgress.duration($0))") }
        guard !progress.line.isEmpty || quiet != nil else { return nil }
        return "› " + [progress.line, quiet].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

// Where the app keeps things, opened in Finder from Settings.
enum DataFolders {
    static var appData: String { AccountStore.supportDir }
    static var accounts: String { AccountStore.home + "/.ai-illuminati" }

    static func open(_ path: String) {
        try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        NSWorkspace.shared.open(URL(fileURLWithPath: path, isDirectory: true))
    }

    // Selects the item in Finder (the app itself, so it is not launched again).
    static func reveal(_ url: URL) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
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
                    Button(L("Ollama 모델 (내 Mac)…", "Ollama Models (this Mac)…")) { LocalModelsWindow.shared.show(model: model) }
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
                        .contentShape(Rectangle())
                        .onDrag {
                            model.draggingAccount = account.id
                            return NSItemProvider(object: account.id as NSString)
                        }
                        .onDrop(of: [UTType.text], delegate: AccountDropDelegate(model: model, target: account.id))
                }
            }
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.07)))
            .onDisappear { model.draggingAccount = nil }
            Text(L("이름을 눌러 수정 · 끌어서 순서 변경 · ⋯에서 로그인과 폴더 열기", "Edit names directly · Drag to reorder · ⋯ for sign-in and folders"))
                .font(.system(size: 11)).foregroundStyle(.secondary)
            Text(L("계정을 추가하면 브라우저 로그인을 위해 터미널이 열려요. 같은 ChatGPT 계정을 중복 추가하지 마세요.",
                   "Adding opens Terminal for browser sign-in. Add each ChatGPT account only once."))
                .font(.system(size: 11)).foregroundStyle(.secondary)
            if model.hasLocal {
                // Ollama models on this Mac: off leaves them out of @, votes and the last resort, and unloads them.
                SettingsCard(title: L("Ollama (내 Mac)", "Ollama (this Mac)")) {
                    SettingsRow(title: L("모델", "Models")) {
                        SettingsAction(title: L("고르기·받기·지우기…", "Pick, download, delete…")) { LocalModelsWindow.shared.show(model: model) }
                    }
                    SettingsRow(title: L("쓰기", "Use")) {
                        Text(L("끄면 @·투표·대타에서 빠져요", "Off: no @, votes or stand-in"))
                            .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                            .help(L("끄면 @ 목록, 투표, 클라우드 계정이 다 바닥났을 때의 대타에서 빠지고 메모리에서 내려요.",
                                    "Off: left out of @, votes and the last resort when every cloud account is out, and unloaded."))
                        Spacer()
                        Toggle(L("Ollama 모델 쓰기", "Use Ollama models"), isOn: $model.localEnabled).labelsHidden().toggleStyle(.switch)
                    }
                }
            }
        }
    }
}

private struct AccountDropDelegate: DropDelegate {
    let model: AppModel
    let target: String

    func validateDrop(info: DropInfo) -> Bool { model.draggingAccount != nil }

    func dropEntered(info: DropInfo) {
        guard let id = model.draggingAccount else { return }
        withAnimation(.easeInOut(duration: 0.15)) { model.move(id, to: target) }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        model.draggingAccount = nil
        return true
    }
}

struct ChatSettingsTab: View {
    @ObservedObject var model: AppModel

    private var isDefault: Bool { model.chatRules == AppModel.defaultChatRules }
    // The first two non-empty lines, so the tab shows what is set without a cramped editor.
    private var preview: String {
        let lines = model.chatRules.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return lines.isEmpty ? L("규칙 없음", "No rules") : lines.prefix(2).joined(separator: "\n")
    }

    var body: some View {
        SettingsPage {
            VStack(alignment: .leading, spacing: 6) {
                SettingsCard(title: L("채팅 규칙", "Chat rules")) {
                    SettingsRow(title: isDefault ? L("기본값", "Default") : L("직접 고침", "Custom")) {
                        SettingsAction(title: L("편집…", "Edit…")) { ChatRulesWindow.shared.show(model: model) }
                    }
                    Divider()
                    Text(preview)
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .lineLimit(2).truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                }
                hint(L("모든 AI 요청에 적용할 말투와 응답 규칙이에요. 답변 길이는 채팅창에서 선택해요.",
                       "Style and instructions for every AI request. Choose response length in the chat window."))
            }
            VStack(alignment: .leading, spacing: 6) {
                SettingsCard(title: L("메시지 판정", "Message sorting")) {
                    SettingsRow(title: L("내 Mac 모델", "Model on this Mac")) {
                        SettingsMenu(options: RouteSorter.allCases.map { ($0.title, $0) }, selection: $model.routeSorter)
                    }
                    .onChange(of: model.routeSorter) { SortModelStatus.offer($0, model: model) }
                    Divider()
                    Text(model.routeSorter.summary)
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                    if model.routeSorter != .off {
                        Divider()
                        SortModelStatus(model: model, store: .shared)
                    }
                }
                hint(L("프로젝트 채팅에서 메시지마다 한 명이 답할지, 모두 답할지, 작업할지 정해요. 고른 모델을 받아 두지 않았거나 Ollama를 껐으면 참여한 AI가 판정해요.",
                       "Decides for each project-chat message: one answer, everyone, or work. Model not downloaded or Ollama off: a member AI judges."))
            }
            let makers = model.accounts.filter { $0.provider == .codex }
            if !makers.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    SettingsCard(title: L("그림 담당", "Picture makers")) {
                        ForEach(makers, id: \.id) { account in
                            SettingsRow(title: account.name) {
                                Text(account.isSchool ? L("엔터프라이즈", "Enterprise") : L("개인", "Personal"))
                                    .font(.system(size: 11)).foregroundStyle(.secondary)
                                Spacer()
                                Toggle(account.name, isOn: Binding(
                                    get: { !model.pictureMakersOff.contains(account.id) },
                                    set: { on in if on { model.pictureMakersOff.remove(account.id) } else { model.pictureMakersOff.insert(account.id) } }))
                                    .labelsHidden().toggleStyle(.switch)
                            }
                        }
                    }
                    hint(L("켜 둔 ChatGPT 계정이 다른 AI 대신 모든 그림을 그려요. 위 설정이 켜져 있으면 엔터프라이즈 AI는 엔터프라이즈 ChatGPT에게, 개인 AI는 개인 ChatGPT에게만 맡겨요. 숫자가 정확해야 하는 그래프와 도표는 각 AI가 직접 그려요.",
                           "Checked ChatGPT accounts draw every picture for the other AIs. With the setting above on, Enterprise AIs ask only Enterprise ChatGPT and personal AIs only personal ChatGPT. Charts and diagrams that must be exact are still drawn by each AI."))
                }
            }
            ApprovalAlertSettingsView()
            DeviceSyncSettingsView()
            MCPSettings()
        }
    }

    // Wraps instead of truncating; the page scrolls when the notes are long.
    private func hint(_ text: String) -> some View {
        Text(text).font(.system(size: 11)).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 2)
    }
}

// Under the message-sorting menu: whether the chosen model can sort now, with the one step that fixes it.
// Picking a model that is not downloaded asks to download it right away.
struct SortModelStatus: View {
    @ObservedObject var model: AppModel
    @ObservedObject var store: LocalModelStore

    private var state: RouteSorter.State { Self.state(model.routeSorter, store) }
    static func state(_ sorter: RouteSorter, _ store: LocalModelStore) -> RouteSorter.State {
        let name = sorter.variant.map { LocalModel.normalized($0.model) } ?? ""
        return sorter.state(checked: store.checked, hasBinary: LocalModel.binary != nil, enabled: LocalModel.enabled,
                            installed: store.installed?.map(\.name), version: store.version,
                            pull: store.pulls[name].map { ($0.status, $0.fraction) }, failure: store.failures[name])
    }

    // Just picked from the menu: look again, then offer the download when that is the step missing.
    static func offer(_ sorter: RouteSorter, model: AppModel) {
        guard sorter != .off else { return }
        LocalModelStore.shared.refresh {
            guard model.routeSorter == sorter else { return }
            switch state(sorter, .shared) {
            case .missing, .failed, .noOllama: model.addSortModel(sorter)
            default: break
            }
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            switch state {
            case .off, .checking:
                line(L("확인하는 중…", "Checking…"))
            case .ready:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                line(L("준비됨", "Ready"))
            case .missing:
                line(L("아직 받지 않았어요 · 약 \(String(format: "%.1f", model.routeSorter.downloadGB))GB · 지금은 참여한 AI가 판정해요",
                       "Not downloaded · about \(String(format: "%.1f", model.routeSorter.downloadGB)) GB · a member AI judges for now"))
                action(L("받기", "Download")) { model.addSortModel(model.routeSorter) }
            case .downloading(let status, let fraction):
                if let fraction { ProgressView(value: fraction).frame(width: 80) } else { ProgressView().controlSize(.small) }
                line(status)
                action(L("취소", "Cancel")) { if let v = model.routeSorter.variant { store.cancel(v.model) } }
            case .failed(let why):
                line(L("받지 못했어요 · \(why)", "Download failed · \(why)"), warn: true)
                action(L("다시 시도", "Try Again")) { if let v = model.routeSorter.variant { store.pull(v.model) } }
            case .noOllama:
                line(L("Ollama(무료)가 필요해요", "Needs Ollama (free)"), warn: true)
                action(L("설치…", "Install…")) { model.addSortModel(model.routeSorter) }
            case .ollamaOff:
                line(store.startFailure ?? L("Ollama가 꺼져 있어요", "Ollama is off"), warn: true)
                if store.starting { ProgressView().controlSize(.small) }
                action(L("켜기", "Turn On")) { store.start() }.disabled(store.starting)
            case .outdated(let version):
                line(L("Ollama \(version)이라 쓸 수 없어요 · \(model.routeSorter.minimumOllama ?? "") 이상으로 업데이트해 주세요",
                       "Ollama \(version) cannot run it · update to \(model.routeSorter.minimumOllama ?? "") or later"), warn: true)
            case .localOff:
                line(L("받아 뒀지만 Ollama 모델이 꺼져 있어요 · 메뉴 막대나 설정 → 계정에서 켜요",
                       "Downloaded, but Ollama models are off · turn them on from the menu bar or Settings → Accounts"), warn: true)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .onAppear { store.refresh() }
        // Back from Terminal (Ollama installed, model pulled) or from turning Ollama on elsewhere.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in store.refresh() }
    }

    private func action(_ title: String, _ run: @escaping () -> Void) -> some View {
        SettingsAction(title: title, action: run).frame(width: 84)
    }

    private func line(_ text: String, warn: Bool = false) -> some View {
        Text(text).font(.system(size: 11)).foregroundStyle(warn ? Color.orange : Color.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// Long-term memory (Memory.swift): on/off, whether the AI saves on its own, and a window to edit it.
struct MemorySettingsTab: View {
    @ObservedObject var memory = MemoryStore.shared

    var body: some View {
        SettingsPage {
            VStack(alignment: .leading, spacing: 6) {
                SettingsCard(title: L("기억", "Memory")) {
                    SettingsRow(title: L("기억 사용", "Use memory")) {
                        Spacer()
                        Toggle(L("기억 사용", "Use memory"), isOn: Binding(
                            get: { memory.data.enabled }, set: { on in memory.update { $0.enabled = on } }))
                            .labelsHidden().toggleStyle(.switch)
                    }
                    Divider()
                    SettingsRow(title: L("AI가 알아서 저장", "AI saves on its own")) {
                        Spacer()
                        Toggle(L("AI가 알아서 저장", "AI saves on its own"), isOn: Binding(
                            get: { memory.data.autoSave }, set: { on in memory.update { $0.autoSave = on } }))
                            .labelsHidden().toggleStyle(.switch)
                            .disabled(!memory.data.enabled)
                    }
                }
                hint(memory.data.autoSave
                     ? L("AI가 기억할 만한 내용을 스스로 저장해요. 저장하면 답 아래에 \"기억함\"과 취소 버튼이 떠요.",
                         "AIs save lasting facts on their own. Each one shows under the answer with Undo.")
                     : L("꺼져 있으면 \"기억해\"라고 말한 메시지에서만 저장해요.",
                         "Off: facts are saved only when your message asks to remember."))
            }
            VStack(alignment: .leading, spacing: 6) {
                SettingsCard(title: L("저장된 내용", "Saved")) {
                    SettingsRow(title: L("프로필", "Profile")) {
                        Text(memory.data.profile.isEmpty ? L("없음", "None") : L("\(memory.data.profile.count)자", "\(memory.data.profile.count) characters"))
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Divider()
                    SettingsRow(title: L("기억", "Facts")) {
                        Text(L("\(memory.data.items.count)개", "\(memory.data.items.count)"))
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Divider()
                    SettingsRow(title: L("편집", "Edit")) {
                        SettingsAction(title: L("기억 열기…", "Open memory…")) { MemoryWindow.shared.show() }
                    }
                }
                hint(L("모든 AI가 같은 기억을 읽어요. 이 Mac에만 저장되지만 답할 때 그 AI에게 보내져요. Enterprise 방은 읽기만 하고 저장하지 않아요. 비밀번호나 키는 저장하지 않아요.",
                       "Every AI reads the same memory. It stays on this Mac but is sent to the AI that answers. Enterprise chats only read it. Passwords and keys are never saved."))
            }
        }
    }

    private func hint(_ text: String) -> some View {
        Text(text).font(.system(size: 11)).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 2)
    }
}

final class MemoryWindow {
    static let shared = MemoryWindow()
    private var window: NSWindow?

    func show() {
        if window == nil {
            let host = NSHostingController(rootView: MemoryView(close: { [weak self] in self?.window?.close() })
                .frame(minWidth: 460, idealWidth: 560, minHeight: 420, idealHeight: 560))
            let w = NSWindow(contentViewController: host)
            w.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            w.title = L("기억", "Memory")
            w.setContentSize(NSSize(width: 560, height: 560))
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        MemoryStore.shared.reload()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

struct MemoryView: View {
    @ObservedObject var memory = MemoryStore.shared
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L("프로필", "Profile")).font(.system(size: 12, weight: .semibold))
            Text(L("직업, 연구, 원하는 답 방식처럼 모든 AI가 늘 알았으면 하는 것을 짧게 적어요. 고치면 바로 저장돼요.",
                   "Who you are, your work and how you like answers: what every AI should always know. Saves as you type."))
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            TextEditor(text: Binding(get: { memory.data.profile }, set: { memory.setProfile($0) }))
                .font(.system(size: 12))
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.1)))
                .frame(minHeight: 90, maxHeight: 150)
            Text("\(memory.data.profile.count) / \(MemoryStore.profileLimit)").font(.system(size: 10)).foregroundStyle(.secondary)
            HStack {
                Text(L("기억 \(memory.data.items.count)개", "\(memory.data.items.count) facts")).font(.system(size: 12, weight: .semibold))
                Spacer()
                Button(L("모두 지우기…", "Remove all…")) { confirmClear() }.disabled(memory.data.items.isEmpty)
            }
            if memory.data.items.isEmpty {
                Text(L("아직 없어요. 채팅에서 \"기억해\"라고 말하면 여기에 쌓여요.", "Nothing yet. Say \"remember …\" in a chat and it lands here."))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
            } else {
                List {
                    ForEach(memory.data.items.reversed()) { item in
                        MemoryRow(item: item)
                    }
                }
                .listStyle(.inset)
            }
            HStack {
                Spacer()
                Button(L("완료", "Done"), action: close).keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func confirmClear() {
        let alert = NSAlert()
        alert.messageText = L("기억을 모두 지울까요?", "Remove every saved fact?")
        alert.informativeText = L("프로필은 남아요.", "The profile stays.")
        alert.addButton(withTitle: L("모두 지우기", "Remove all"))
        alert.addButton(withTitle: L("취소", "Cancel"))
        if alert.runModal() == .alertFirstButtonReturn { memory.removeAll() }
    }
}

private struct MemoryRow: View {
    let item: MemoryItem

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                // Saves as you type; emptying it keeps the fact (the trash button removes it).
                TextField("", text: Binding(get: { item.text }, set: { MemoryStore.shared.setItem(item.id, text: $0) }), axis: .vertical)
                    .textFieldStyle(.plain).font(.system(size: 12))
                Text([ChatLink.day(item.createdAt), item.roomTitle, item.by].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Button(action: { MemoryStore.shared.remove(item.id) }) { Image(systemName: "trash") }
                .buttonStyle(.borderless).help(L("지우기", "Remove"))
        }
        .padding(.vertical, 2)
    }
}

// Chat rules get their own resizable window: the settings window is too small for a useful editor.
final class ChatRulesWindow {
    static let shared = ChatRulesWindow()
    private var window: NSWindow?

    func show(model: AppModel) {
        if window == nil {
            let host = NSHostingController(rootView: ChatRulesView(model: model, close: { [weak self] in self?.window?.close() })
                .frame(minWidth: 420, idealWidth: 520, minHeight: 300, idealHeight: 420))
            let w = NSWindow(contentViewController: host)
            w.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            w.title = L("채팅 규칙", "Chat rules")
            w.setContentSize(NSSize(width: 520, height: 420))
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

struct ChatRulesView: View {
    @ObservedObject var model: AppModel
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L("모든 AI 요청 맨 앞에 붙는 말투와 응답 규칙이에요. 고치면 바로 저장돼요.",
                   "Style and instructions added to the top of every AI request. Changes save as you type."))
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextEditor(text: $model.chatRules)
                .font(.system(size: 12))
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.1)))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            HStack {
                Button(L("기본값으로", "Reset to default")) { model.chatRules = AppModel.defaultChatRules }
                    .disabled(model.chatRules == AppModel.defaultChatRules)
                Spacer()
                Button(L("완료", "Done"), action: close).keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

// Chats from your other Macs (DeviceSync.swift): read only, continued here as a new chat.
private struct DeviceSyncSettingsView: View {
    @ObservedObject var sync = DeviceSync.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SettingsCard(title: L("다른 기기의 대화", "Chats from other Macs")) {
                SettingsRow(title: L("켜기", "On")) {
                    Text(sync.settings.enabled ? status : L("꺼짐", "Off")).font(.system(size: 11))
                        .foregroundStyle(sync.problem != nil || (sync.settings.enabled && !sync.folderAvailable) ? .orange : .secondary).lineLimit(1)
                    Spacer()
                    Toggle(L("켜기", "On"), isOn: Binding(get: { sync.settings.enabled }, set: setEnabled)).labelsHidden().toggleStyle(.switch)
                }
                if sync.settings.enabled {
                    Divider()
                    SettingsRow(title: L("이 Mac 이름", "This Mac's name")) {
                        TextField(Host.current().localizedName ?? "Mac", text: Binding(
                            get: { sync.settings.deviceName ?? "" },
                            set: { sync.settings.deviceName = $0.isEmpty ? nil : $0 }))
                            .textFieldStyle(.roundedBorder)
                    }
                    Divider()
                    SettingsRow(title: L("보일 대화", "Chats shown")) {
                        SettingsSegments(options: [(L("고른 대화만", "Chosen chats"), false), (L("전부", "All"), true)],
                                         selection: Binding(get: { sync.settings.shareAll }, set: { sync.settings.shareAll = $0 }))
                    }
                    Divider()
                    SettingsRow(title: L("엔터프라이즈", "Enterprise")) {
                        Text(L("엔터프라이즈 대화도 올리기", "Include Enterprise chats")).font(.system(size: 11)).foregroundStyle(.secondary)
                        Spacer()
                        Toggle("", isOn: Binding(get: { sync.settings.includeSchool }, set: { sync.settings.includeSchool = $0 }))
                            .labelsHidden().toggleStyle(.switch)
                    }
                    Divider()
                    SettingsRow(title: L("폴더", "Folder")) {
                        Text(sync.folder.path.replacingOccurrences(of: DeviceSync.iCloudDrive.path, with: "iCloud Drive"))
                            .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            .help(sync.folder.path)
                        Spacer()
                        Button(L("바꾸기…", "Change…"), action: chooseFolder)
                        if sync.settings.folder != nil { Button(L("기본값", "Default")) { sync.settings.folder = nil } }
                    }
                    Divider()
                    SettingsRow(title: L("관리", "Manage")) {
                        SettingsAction(title: L("지금 확인", "Check now")) { sync.reconcile(); sync.scan() }
                        SettingsAction(title: L("이 Mac 사본 지우기", "Remove this Mac's copies"), action: removeMine)
                    }
                }
            }
            hint(L("다른 Mac에서 하던 대화를 읽기 전용으로 보고, 원하면 이 Mac에서 새 대화로 이어가요. 각 Mac은 동기화 폴더의 자기 폴더에만 써서 서로 덮어쓰지 않아요. ‘고른 대화만’이면 대화 메뉴(⋯)의 ‘다른 기기에 보이기’로 골라요. 엔터프라이즈 대화는 켜야만 올라가고, 끄면 이미 올린 사본도 지워져요. 그림, 연결한 폴더, 세션 기록은 올라가지 않아요.",
                   "See chats from your other Macs read only, and continue one here as a new chat. Each Mac writes only its own folder in the sync folder, so nothing is overwritten. With ‘Chosen chats’, pick them with ‘Show on other Macs’ in a chat's ⋯ menu. Enterprise chats go up only when included; turning that off removes their copies. Pictures, linked folders and sessions are not copied."))
        }
    }

    private var status: String {
        if let problem = sync.problem { return problem }
        if !sync.folderAvailable { return L("iCloud Drive가 꺼져 있어요", "iCloud Drive is off") }
        let macs = L("다른 Mac \(sync.devices.count)대", "\(sync.devices.count) other Macs")
        return sync.lastChecked.map { macs + L(" · 확인 ", " · checked ") + DeviceSync.ago($0) } ?? macs
    }

    private func setEnabled(_ on: Bool) {
        if on {
            let alert = NSAlert()
            alert.messageText = L("다른 기기의 대화를 켤까요?", "Turn on chats from other Macs?")
            alert.informativeText = L("고른 대화의 질문과 답이 동기화 폴더(기본: iCloud Drive)에 누구나 읽을 수 있는 파일로 저장돼요. 같은 iCloud 계정의 다른 Mac에서 읽기 전용으로 보여요. 엔터프라이즈 대화는 따로 켜야 올라가요.",
                                      "The messages and answers of the chats you pick are saved as plain readable files in the sync folder (iCloud Drive by default), and shown read only on your other Macs with the same iCloud account. Enterprise chats go up only if you include them.")
            alert.addButton(withTitle: L("켜기", "Turn On"))
            alert.addButton(withTitle: L("취소", "Cancel"))
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            sync.settings.enabled = true
        } else {
            let alert = NSAlert()
            alert.messageText = L("끌까요?", "Turn off?")
            alert.informativeText = L("이 Mac이 올린 사본은 남겨 두면 다른 Mac에서 계속 보여요.", "Copies this Mac wrote stay visible on your other Macs unless you remove them.")
            alert.addButton(withTitle: L("끄기", "Turn Off"))
            alert.addButton(withTitle: L("끄고 사본 지우기", "Turn Off and Remove Copies"))
            alert.addButton(withTitle: L("취소", "Cancel"))
            switch alert.runModal() {
            case .alertFirstButtonReturn: sync.settings.enabled = false
            case .alertSecondButtonReturn: sync.removeMine(); sync.settings.enabled = false
            default: return
            }
        }
    }

    private func removeMine() {
        let alert = NSAlert()
        alert.messageText = L("이 Mac이 올린 사본을 지울까요?", "Remove the copies this Mac wrote?")
        alert.informativeText = L("동기화 폴더에서만 지워요. 이 Mac의 대화는 그대로예요. 켜 둔 상태면 다음에 대화가 바뀔 때 다시 올라가요.",
                                  "Only the sync folder is cleared; the chats on this Mac stay. While on, chats go up again when they change.")
        alert.addButton(withTitle: L("지우기", "Remove"))
        alert.addButton(withTitle: L("취소", "Cancel"))
        alert.buttons.first?.hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        sync.removeMine()
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = L("이 폴더 쓰기", "Use This Folder")
        panel.message = L("모든 Mac에서 같은 폴더를 골라 주세요.", "Pick the same folder on every Mac.")
        panel.directoryURL = FileManager.default.fileExists(atPath: DeviceSync.iCloudDrive.path) ? DeviceSync.iCloudDrive : nil
        guard panel.runModal() == .OK, let url = panel.url else { return }
        sync.settings.folder = url.path
    }

    private func hint(_ text: String) -> some View {
        Text(text).font(.system(size: 11)).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 2)
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
                        // How long the model stays in memory after a reply (closing the chat window unloads it anyway).
                        Menu {
                            Picker(L("답한 뒤 메모리에 남겨 두기", "Keep in memory after a reply"), selection: $model.localKeepAlive) {
                                ForEach(LocalModel.keepAliveChoices, id: \.self) { Text(LocalModel.keepAliveName($0)).tag($0) }
                            }
                        } label: {
                            Text(L("유지 ", "Keep ") + LocalModel.keepAliveName(model.localKeepAlive))
                        }
                        .menuStyle(.borderlessButton).fixedSize().controlSize(.mini)
                        .help(L("답한 뒤 모델을 메모리에 남겨 두는 시간. 다시 부를 때 기다리지 않아요. 채팅창을 닫으면 바로 내려요.",
                                "How long the model stays in memory after a reply, so the next one starts at once. Closing the chat window unloads it."))
                    }
                    if account.provider != .gemini && account.provider != .ollama {
                        Toggle(L("엔터프라이즈", "Enterprise"), isOn: Binding(
                            get: { model.accounts.first { $0.id == account.id }?.isSchool ?? false },
                            set: { model.setSchool(account.id, $0) }))
                            .toggleStyle(.checkbox).controlSize(.mini)
                            .help(L("엔터프라이즈(학교·회사) 계정: 직접 잠근 Enterprise 방에는 이름이 같은 엔터프라이즈 계정과 내 Mac 모델만 참여해요", "Enterprise (school or work) account: a chat you lock as Enterprise is answered only by Enterprise accounts of the same name and models on this Mac"))
                    }
                }.font(.system(size: 10)).lineLimit(1)
            }
            Spacer(minLength: 4)
            Image(systemName: "line.3.horizontal")
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 24)
                .help(L("끌어서 순서 변경", "Drag to reorder"))
            Menu {
                Button(account.provider == .ollama ? L("다시 받기·업데이트", "Download again or update") : L("로그인…", "Sign in…")) { model.login(account) }
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
        .accessibilityAction(named: L("위로 이동", "Move up")) { model.move(account, by: -1) }
        .accessibilityAction(named: L("아래로 이동", "Move down")) { model.move(account, by: 1) }
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
        guard let items = tabs?.tabViewItems, items.count == 5 else { return }
        for (item, title) in zip(items, [L("일반", "General"), L("모양", "Appearance"), L("계정", "Accounts"), L("채팅", "Chat"), L("기억", "Memory")]) {
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
            t.addTabViewItem(tab(MemorySettingsTab(), symbol: "brain.head.profile"))
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

// How a waiting approval reaches you outside its chat (ApprovalAlerts). The menu bar count, the banner and
// the dot in the chat list always show; these only change the macOS notification.
private struct ApprovalAlertSettingsView: View {
    @AppStorage(ApprovalAlertSettings.notifyKey, store: .app) private var notify = true
    @AppStorage(ApprovalAlertSettings.soundKey, store: .app) private var sound = false
    @AppStorage(ApprovalAlertSettings.repeatKey, store: .app) private var repeats = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SettingsCard(title: L("허가 요청", "Approval requests")) {
                SettingsRow(title: L("알림", "Notify")) {
                    Spacer()
                    Toggle(L("알림", "Notify"), isOn: $notify).labelsHidden().toggleStyle(.switch)
                }
                Divider()
                SettingsRow(title: L("소리", "Sound")) {
                    Spacer()
                    Toggle(L("소리", "Sound"), isOn: $sound).labelsHidden().toggleStyle(.switch).disabled(!notify)
                }
                Divider()
                SettingsRow(title: L("5분마다 다시", "Every 5 min")) {
                    Spacer()
                    Toggle(L("5분마다 다시", "Every 5 min"), isOn: $repeats).labelsHidden().toggleStyle(.switch).disabled(!notify)
                }
            }
            Text(L("다른 채팅이나 다른 앱을 보고 있을 때 허가 요청을 macOS 알림으로 알려요. 메뉴바 숫자와 채팅 목록의 점은 늘 보여요. 15분 안에 답하지 않으면 거절로 처리해요.",
                   "Notifies you in macOS when an approval waits while you look at another chat or app. The menu bar count and the dot in the chat list always show. Unanswered for 15 minutes counts as denied."))
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 2)
        }
    }
}
