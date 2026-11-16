import Cocoa
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers
import AIAccounts
import AIChatRecords
import AILocalization
import AIRuntime
import AIWorkspace
import AIChat
import AIIntegrations

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
    // Which AIs the app may pick when a chat's members are automatic (meetings, several views; Meeting.swift autoPicked):
    // only the switches changed in Settings → Chat; the others follow the default (cloud AIs on, models on this Mac off).
    @Published var autoTeamPicks: [String: Bool] {
        didSet { defaults.set(autoTeamPicks, forKey: "autoTeamPicks") }
    }
    // AI-to-AI collaboration (CollabLog.swift): off, show cards and go (default), or on its own with folded cards.
    @Published var collaboration: CollabMode {
        didSet { defaults.set(collaboration.rawValue, forKey: "aiCollaboration") }
    }
    // Several views on one message: the AI with the most usage left sums them up and the answers fold under it.
    @Published var opinionDigest: Bool {
        didSet { defaults.set(opinionDigest, forKey: "opinionDigest") }
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
        autoTeamPicks = defaults.dictionary(forKey: "autoTeamPicks") as? [String: Bool] ?? [:]
        collaboration = defaults.string(forKey: "aiCollaboration").flatMap(CollabMode.init(rawValue:)) ?? .notify
        opinionDigest = defaults.object(forKey: "opinionDigest") as? Bool ?? true
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
        // An older entry (no mark yet) keeps what its name made it: only the Enterprise checkbox changes that.
        if accounts[index].school == nil { accounts[index].school = accounts[index].isSchool }
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

    // One step from the ⋯ menu: delete the model files, and every entry that uses them (they could no longer answer).
    func deleteLocal(_ account: Account) {
        NSApp.activate(ignoringOtherApps: true)
        let model = LocalModel.variant(account).model
        let users = accounts.filter { $0.provider == .ollama && LocalModel.same(LocalModel.variant($0).model, model) }
        let alert = NSAlert()
        guard let onDisk = LocalModel.installed(timeout: 1)?.first(where: { LocalModel.matches($0.name, model) }) else {
            alert.messageText = L("이 Mac에서 모델 파일을 찾지 못했어요.", "The model files were not found on this Mac.")
            alert.informativeText = L("Ollama가 꺼져 있거나 이미 지워졌어요. 목록에서만 빼려면 '목록에서 빼기…'를 쓰세요.", "Ollama is off or the files are already gone. To take it off the list, use “Remove from list…”.")
            alert.runModal()
            return
        }
        let size = String(format: "%.1f", Double(onDisk.bytes) / 1e9)
        alert.messageText = L("'\(account.name)'을 이 Mac에서 지울까요?", "Delete “\(account.name)” from this Mac?")
        alert.informativeText = users.count > 1
            ? L("모델 파일(\(size)GB)을 지우고, 이 모델을 쓰는 항목 \(users.count)개를 모두 목록에서 빼요. 나중에 다시 받을 수 있어요.", "Deletes the model files (\(size) GB) and removes all \(users.count) entries that use this model. You can download it again later.")
            : L("모델 파일(\(size)GB)을 지우고 목록에서도 빼요. 나중에 다시 받을 수 있어요.", "Deletes the model files (\(size) GB) and removes the entry from the list. You can download it again later.")
        alert.alertStyle = .warning
        alert.addButton(withTitle: L("지우기", "Delete"))
        alert.addButton(withTitle: L("취소", "Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let ids = Set(users.map(\.id))
        accounts.removeAll { ids.contains($0.id) }
        LocalModelStore.shared.delete(onDisk.name)
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
// `help` is the card's explanation: a tooltip over the card (rows with their own help keep theirs), marked by ⓘ.
private struct SettingsCard<Content: View>: View {
    let title: String
    var help: String? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 3) {
                Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                if help != nil { Image(systemName: "info.circle").font(.system(size: 10)).foregroundStyle(.tertiary) }
            }
            .padding(.horizontal, 2)
            VStack(spacing: 0) { content }
                .background(Color(nsColor: .controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.07)))
        }
        .help(help ?? "")
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
            AIColorsSettingsCard()
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

// Each AI's color (names in the chat and the menu, the sidebar's answering ring): one line per AI with its color
// and "Change…", which opens the color window (AIColorWindow, also on a right-click of the AI's name).
private struct AIColorsSettingsCard: View {
    @AppStorage(AIColors.revisionKey) private var revision = 0   // redraw when a color changes in the color window

    var body: some View {
        SettingsCard(title: L("AI 색", "AI colors"),
                     help: L("채팅 이름, 사용량 메뉴, 사이드바의 '답하는 중' 표시에 쓰여요. AI 이름을 우클릭해도 바꿀 수 있어요.",
                             "Used for names in the chat, the usage menu and the sidebar's answering mark. You can also right-click an AI's name.")) {
            ForEach(Account.Provider.allCases, id: \.self) { provider in
                if provider != Account.Provider.allCases.first { Divider() }
                HStack(spacing: 8) {
                    Circle().fill(Color(nsColor: AIColors.color(provider))).frame(width: 10, height: 10)
                    Text(provider.title)
                    Spacer()
                    Button(L("변경…", "Change…")) { AIColorWindow.show(provider) }
                        .help(AIColorWindow.menuTitle(provider))
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
                .frame(minHeight: 32)
            }
        }
        .id(revision)
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
    @ObservedObject private var usage = TokenUsageModel.shared

    var body: some View {
        SettingsPage {
            SettingsSegments(options: [(L("계정 관리", "Manage"), false), (L("사용량", "Usage"), true)], selection: $usage.shown)
                .frame(width: 200).frame(maxWidth: .infinity)
            if usage.shown { TokenUsageView(model: model, ledger: usage) } else { manage }
        }
    }

    @ViewBuilder private var manage: some View {
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
            Text(L("이름을 눌러 수정 · 오른쪽에서 모델 선택 · 끌어서 순서 변경 · ⋯에서 로그인과 폴더 열기", "Edit names directly · Pick each model on the right · Drag to reorder · ⋯ for sign-in and folders"))
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

// Settings > Accounts > Usage: tokens from the CLIs' own logs (TokenLedger) by day, week, month or year, laid out like
// AI Face's History. Every count is there: the header splits the period's tokens into the four kinds with their shares,
// and the metric picks what the chart and bars measure (everything, everything but cache reads, or output), on one
// scale for every account. With sync on, other Macs' sums (TokenSync) are added to the same accounts by provider and
// name. Limits % are the menu's, not here.
// (The page's choices live here: this Mac's Command Line Tools cannot build SwiftUI's @State macro.)
final class TokenUsageModel: ObservableObject {
    enum Span: Hashable { case day, week, month, year }
    enum Metric: Hashable { case all, fresh, output }
    static let shared = TokenUsageModel()
    static let syncKey = "tokenUsageSync"
    @Published var shown = false      // Accounts: the Usage page instead of the list
    @Published var span: Span = .week
    @Published var metric: Metric = .all
    @Published var back = 0           // how many periods before the current one
    @Published var open: Set<String> = []   // rows showing every count
    @Published var device: String?    // nil: every Mac; "": this Mac; else another Mac's id
    @Published var sources: [TokenSource]?
    @Published var peers: [TokenDevice] = []
    @Published var syncedAt: Date?
    @Published var syncOn = UserDefaults.app.bool(forKey: TokenUsageModel.syncKey) {
        didSet {
            UserDefaults.app.set(syncOn, forKey: Self.syncKey)
            if !syncOn { peers = []; device = nil; syncedAt = nil }
        }
    }
    private var reading = false
    private var timer: Timer?

    // App start: with sync on, this Mac's sums go up every 30 minutes even when Settings stays closed.
    func start(_ model: AppModel) {
        if syncOn { peers = TokenSync.cached() }
        let ticker = Timer(timeInterval: 1800, repeats: true) { [weak self, weak model] _ in
            guard let self, let model, self.syncOn else { return }
            self.load(model)
        }
        ticker.tolerance = 120
        RunLoop.main.add(ticker, forMode: .common)
        timer = ticker
        if syncOn { DispatchQueue.main.asyncAfter(deadline: .now() + 60) { [weak self, weak model] in if let model { self?.load(model) } } }
    }

    func load(_ model: AppModel) {
        guard !reading else { return }
        reading = true
        let accounts = model.accounts, toolHome = model.persist ? ToolHome.path : AccountStore.home
        let sync = syncOn && model.persist ? DeviceSync.shared : nil
        let folder = sync?.folder, id = sync?.deviceID, name = sync?.deviceName
        DispatchQueue.global(qos: .utility).async {
            let read = TokenLedger.read(accounts, toolHome: toolHome)
            DispatchQueue.main.async { self.sources = read }
            var peers: [TokenDevice]?
            if let folder, let id, let name {
                peers = TokenSync.exchange(Self.shares(read, accounts), folder: folder, deviceID: id, deviceName: name)
            }
            DispatchQueue.main.async {
                if let peers, self.syncOn { self.peers = peers; self.syncedAt = Date() }
                self.reading = false
            }
        }
    }

    // What this Mac shares: its sums per account name (ids differ on each Mac) and per program outside the app.
    static func shares(_ sources: [TokenSource], _ accounts: [Account]) -> [TokenShare] {
        sources.compactMap { s in
            if let id = s.accountID {
                guard let a = accounts.first(where: { $0.id == id }) else { return nil }
                return TokenShare(provider: s.provider, name: a.name, outside: false, origin: nil, days: s.days)
            }
            return TokenShare(provider: s.provider, name: "", outside: true, origin: s.origin, days: s.days)
        }
    }
}

struct TokenUsageView: View {
    typealias Span = TokenUsageModel.Span
    typealias Metric = TokenUsageModel.Metric
    struct Line: Identifiable {
        let id: String                       // TokenShare.key
        let name: String
        let provider: Account.Provider
        let outside: Bool
        var folder: String?                  // outside the app on this Mac
        var days: [String: [Date: TokenCounts]] = [:]   // by Mac: "" this Mac, else its id
    }
    enum Kind: CaseIterable { case input, cacheWrite, cacheRead, output }

    @ObservedObject var model: AppModel
    @ObservedObject var ledger: TokenUsageModel
    @ObservedObject private var deviceSync = DeviceSync.shared
    @AppStorage(AIColors.revisionKey) private var revision = 0   // redraw when an AI's color changes
    private var span: Span { ledger.span }
    private var back: Int { ledger.back }

    private var calendar: Calendar { .current }
    private var unit: Calendar.Component {
        switch span { case .day: return .day; case .week: return .weekOfYear; case .month: return .month; case .year: return .year }
    }
    private var period: DateInterval {
        let anchor = calendar.date(byAdding: unit, value: -back, to: Date()) ?? Date()
        return calendar.dateInterval(of: unit, for: anchor) ?? DateInterval(start: anchor, duration: 86400)
    }
    // Chart columns: the days of a week or month, the months of a year. The logs count by day, so a day has no chart.
    private var columns: [DateInterval] {
        guard span != .day else { return [] }
        var list: [DateInterval] = []
        var start = period.start
        while start < period.end, let next = calendar.date(byAdding: span == .year ? .month : .day, value: 1, to: start) {
            list.append(DateInterval(start: start, end: next))
            start = next
        }
        return list
    }

    // The kinds of tokens: the header's split, the account bars and the legend.
    static func kindColor(_ k: Kind) -> Color {
        switch k {
        case .input: return Color(red: 0.30, green: 0.55, blue: 0.98)
        case .cacheWrite: return Color(red: 0.62, green: 0.48, blue: 0.96)
        case .cacheRead: return Color(nsColor: .systemGray)
        case .output: return Color(red: 0.96, green: 0.76, blue: 0.25)
        }
    }
    static func kindName(_ k: Kind) -> String {
        switch k {
        case .input: return L("캐시 아닌 입력", "Uncached input")
        case .cacheWrite: return L("캐시 쓰기", "Cache writes")
        case .cacheRead: return L("캐시 읽기", "Cache reads")
        case .output: return L("출력", "Output")
        }
    }
    static func value(_ c: TokenCounts, _ k: Kind) -> Int {
        switch k { case .input: return c.input; case .cacheWrite: return c.cacheWrite; case .cacheRead: return c.cacheRead; case .output: return c.output }
    }
    private func kinds(_ m: Metric) -> [Kind] {
        switch m { case .all: return Kind.allCases; case .fresh: return [.input, .cacheWrite, .output]; case .output: return [.output] }
    }
    private func measure(_ c: TokenCounts) -> Int { kinds(ledger.metric).reduce(0) { $0 + Self.value(c, $1) } }

    // Accounts in the menu's colors: every account of a provider has its color, told apart by a line between them
    // (and their names). Outside the app: the same color striped.
    private func color(_ line: Line) -> Color { Color(nsColor: AIColors.color(line.provider)) }
    @ViewBuilder private func swatch(_ line: Line) -> some View {
        if line.outside {
            ZStack { color(line).opacity(0.3); Stripes().stroke(color(line), lineWidth: 1.5) }.clipped()
        } else {
            color(line)
        }
    }

    private var lines: [Line] {
        let sources = ledger.sources ?? []
        var result: [Line] = []
        func add(_ line: Line, device: String, _ days: [Date: TokenCounts]) {
            if let i = result.firstIndex(where: { $0.id == line.id }) { result[i].days[device] = days; return }
            var line = line
            line.days[device] = days
            result.append(line)
        }
        let local = TokenUsageModel.shares(sources, model.accounts)
        for a in model.accounts where a.provider != .ollama {
            let share = local.first { !$0.outside && $0.name == a.name && $0.provider == a.provider }
            add(Line(id: a.provider.rawValue + "#" + a.name, name: a.name, provider: a.provider, outside: false), device: "", share?.days ?? [:])
        }
        for s in sources where s.accountID == nil {
            let share = TokenShare(provider: s.provider, name: "", outside: true, origin: s.origin, days: s.days)
            add(Line(id: share.key, name: Self.outsideName(s.provider, s.origin), provider: s.provider, outside: true, folder: s.folder),
                device: "", s.days)
        }
        for peer in ledger.syncOn ? ledger.peers : [] {
            for share in peer.shares {
                add(Line(id: share.key, name: share.outside ? Self.outsideName(share.provider, share.origin) : share.name,
                         provider: share.provider, outside: share.outside), device: peer.id, share.days)
            }
        }
        // Accounts first (in the app's order), then outside the app; a provider's lines together.
        let order = Account.Provider.allCases
        return result.enumerated().sorted { a, b in
            let ka = (a.element.outside ? 1 : 0, order.firstIndex(of: a.element.provider) ?? 9, a.offset)
            let kb = (b.element.outside ? 1 : 0, order.firstIndex(of: b.element.provider) ?? 9, b.offset)
            return ka < kb
        }.map(\.element)
    }

    // Which program wrote the logs no account uses (Claude `entrypoint`, Codex `originator`).
    private static func outsideName(_ provider: Account.Provider, _ origin: TokenSource.Origin?) -> String {
        switch (provider, origin) {
        case (.claude, .desktop?): return L("Claude 데스크톱 앱 (Code)", "Claude desktop app (Code)")
        case (.claude, .terminal?): return L("터미널의 Claude Code", "Claude Code in Terminal")
        case (.codex, .desktop?): return L("Codex 앱", "Codex app")
        case (.codex, .terminal?): return L("터미널의 Codex", "Codex in Terminal")
        case (.claude, _): return L("Claude Code (앱 밖)", "Claude Code (outside the app)")
        case (.codex, _): return L("Codex (앱 밖)", "Codex (outside the app)")
        default: return L("Gemini (앱 밖)", "Gemini (outside the app)")
        }
    }

    // The Macs counted: every one, this Mac or one other Mac.
    private func counted(_ device: String) -> Bool { ledger.device == nil || ledger.device == device }
    private func counts(_ line: Line, _ range: DateInterval, device: String? = nil) -> TokenCounts {
        line.days.reduce(into: TokenCounts()) { sum, entry in
            guard device.map({ $0 == entry.key }) ?? counted(entry.key) else { return }
            for (day, c) in entry.value where day >= range.start && day < range.end { sum += c }
        }
    }
    private func deviceName(_ id: String) -> String {
        id.isEmpty ? L("이 Mac", "This Mac") : ledger.peers.first { $0.id == id }?.name ?? L("다른 Mac", "Other Mac")
    }

    var body: some View {
        let _ = revision
        VStack(alignment: .leading, spacing: 10) {
            SettingsSegments(options: [(L("일", "Day"), Span.day), (L("주", "Week"), .week), (L("월", "Month"), .month), (L("년", "Year"), .year)],
                             selection: Binding(get: { ledger.span }, set: { ledger.span = $0; ledger.back = 0 }))
            HStack(spacing: 6) {
                Button { ledger.back += 1 } label: { Image(systemName: "chevron.left") }.buttonStyle(.plainHit)
                Text(periodTitle).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Button { ledger.back -= 1 } label: { Image(systemName: "chevron.right") }.buttonStyle(.plainHit)
                    .disabled(back == 0).opacity(back == 0 ? 0.3 : 1)
                Spacer()
                let picker = ledger.syncOn && !ledger.peers.isEmpty
                if let first = firstDay, period.start < first { partial(first, short: picker) }
                if picker { devicePicker }
            }
            SettingsSegments(options: [(L("전체", "All"), Metric.all), (L("캐시 읽기 제외", "No cache reads"), .fresh), (L("출력만", "Output only"), .output)],
                             selection: $ledger.metric)
            if ledger.sources == nil {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(L("CLI 로그를 읽는 중… (처음 한 번은 몇 초 걸려요)", "Reading the CLI logs… (the first time takes a few seconds)"))
                        .foregroundStyle(.secondary)
                }.padding(.vertical, 20).frame(maxWidth: .infinity)
            } else {
                content
            }
            syncCard
        }
        .onAppear { ledger.load(model) }
    }

    private var devicePicker: some View {
        Menu {
            Button(L("모든 Mac", "All Macs")) { ledger.device = nil }
            Button(L("이 Mac", "This Mac")) { ledger.device = "" }
            ForEach(ledger.peers, id: \.id) { peer in Button(peer.name) { ledger.device = peer.id } }
        } label: {
            Text(ledger.device.map(deviceName) ?? L("모든 Mac", "All Macs")).lineLimit(1)
        }.fixedSize().help(L("어느 Mac의 사용량을 볼지", "Which Macs to count"))
    }

    // The first day any log has: earlier days are missing, not unused (Claude Code deletes logs after 30 days, and
    // what it deleted before the app first read it cannot be counted).
    private var firstDay: Date? { lines.flatMap { $0.days.values.flatMap { $0.filter { !$0.value.isEmpty }.keys } }.min() }

    private func partial(_ first: Date, short: Bool) -> some View {
        let f = DateFormatter()
        f.locale = AppLanguage.current.locale
        f.setLocalizedDateFormatFromTemplate("MMMd")
        let text = L("\(f.string(from: first)) 이전 기록 없음", "No logs before \(f.string(from: first))")
        return Label(text, systemImage: "exclamationmark.triangle").labelStyle(PartialLabel(iconOnly: short))
            .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
            .help(text + " · " + L("Claude Code는 30일 지난 로그를 지워요. 앱이 한 번 읽은 로그는 지워져도 합계가 남지만, 그 전에 지워진 건 셀 수 없어요.",
                    "Claude Code deletes logs after 30 days. A log the app has read keeps its sums when deleted; ones deleted before cannot be counted."))
    }

    @ViewBuilder private var content: some View {
        let lines = self.lines
        let totals = lines.map { counts($0, period) }
        let sum = totals.reduce(TokenCounts(), +)
        header(sum)
        if !columns.isEmpty { chart(lines) }
        SettingsCard(title: L("계정별 (같은 눈금)", "By account (one scale)")) {
            let scale = max(totals.map(measure).max() ?? 0, 1)
            ForEach(Array(lines.enumerated()), id: \.1.id) { index, line in
                if index > 0 { Divider() }
                row(line, totals[index], scale: scale)
            }
        }
        legend
        Text((ledger.device == nil && !ledger.peers.isEmpty ? L("동기화한 Mac들의", "From the synced Macs'") : L("이 Mac의", "From this Mac's"))
             + L(" CLI 로그와 데스크톱 앱의 Code 작업 기준 · 웹과 앱의 일반 채팅은 빠져요 · 출력에 thinking/reasoning 포함",
                 " CLI logs and the desktop apps' Code work · Web and plain app chats are not included · Output includes thinking/reasoning"))
            .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }

    private static let cacheHelp = L("에이전트는 요청마다 지금까지의 대화 전체를 다시 보내요. 이미 처리한 앞부분은 캐시에서 읽어서(입력 단가의 약 0.1배) 숫자는 크지만 새로 한 일은 아니에요.",
                                     "Agents resend the whole conversation with every request. The part already processed is read from the cache (about 0.1× the input price): a big number, but no new work.")
    private static func help(_ k: Kind) -> String {
        switch k {
        case .input: return L("캐시에 없던 입력: 내 메시지, 도구 결과(파일 내용, 명령 출력), 처음 보낸 대화 기록.", "Input not in the cache: your messages, tool results (files, command output), conversation sent the first time.")
        case .cacheWrite: return L("캐시에 새로 저장한 입력. Claude만 따로 세요(Codex·Gemini는 캐시 아닌 입력에 들어가요).", "Input newly stored in the cache. Only Claude counts it apart (Codex and Gemini count it as uncached input).")
        case .cacheRead: return cacheHelp
        case .output: return L("AI가 만든 토큰 전부: 보이는 답, thinking/reasoning, 도구 호출(쓴 코드, 실행한 명령)까지.", "Every token the AIs produced: the answers you see, thinking/reasoning and tool calls (code written, commands run).")
        }
    }

    private static func percent(_ part: Int, of whole: Int) -> String {
        guard whole > 0 else { return "—" }
        let p = Double(part) / Double(whole) * 100
        if part == 0 { return "0%" }
        return p < 0.1 ? "<0.1%" : p < 10 ? String(format: "%.1f%%", p) : "\(Int(p.rounded()))%"
    }

    // The period's tokens: the metric's total, and every kind with its share of all tokens.
    private func header(_ sum: TokenCounts) -> some View {
        let fed = sum.input + sum.cacheWrite + sum.cacheRead
        let title: String
        switch ledger.metric {
        case .all: title = L("전체 토큰", "All tokens")
        case .fresh: title = L("캐시 읽기 제외", "Without cache reads")
        case .output: title = L("출력", "Output")
        }
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(title).font(.system(size: 11)).foregroundStyle(.secondary)
                    Text(Self.short(measure(sum))).font(.system(size: 26, weight: .semibold, design: .rounded))
                        .foregroundStyle(ledger.metric == .output ? Self.kindColor(.output) : Color.primary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 1) {
                    if ledger.metric != .all { Text(L("전체 ", "All ") + Self.short(sum.total)) }
                    if ledger.metric != .fresh { Text(L("캐시 읽기 제외 ", "No cache reads ") + Self.short(sum.fresh)) }
                    Text(L("캐시 적중 ", "Cache hits ") + Self.percent(sum.cacheRead, of: fed))
                        .help(L("입력 중 캐시에서 읽은 비율: 캐시 읽기 ÷ (캐시 아닌 입력 + 캐시 쓰기 + 캐시 읽기)",
                                "The share of input read from the cache: cache reads ÷ (uncached input + cache writes + cache reads)"))
                }.font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            split(sum, kinds: Kind.allCases, scale: sum.total, height: 8)
            VStack(spacing: 2) {
                ForEach(Kind.allCases, id: \.self) { k in
                    HStack(spacing: 4) {
                        RoundedRectangle(cornerRadius: 2).fill(Self.kindColor(k)).frame(width: 8, height: 8)
                        Text(Self.kindName(k)).lineLimit(1)
                        Spacer(minLength: 2)
                        Text(Self.short(Self.value(sum, k))).monospacedDigit().foregroundStyle(.primary)
                        Text(Self.percent(Self.value(sum, k), of: sum.total)).monospacedDigit().frame(width: 42, alignment: .trailing)
                    }
                    .opacity(kinds(ledger.metric).contains(k) ? 1 : 0.5)
                    .help(Self.help(k))
                }
            }.font(.system(size: 10)).foregroundStyle(.secondary)
        }
        .padding(10).frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.07)))
    }

    // One stacked column per day (month per year): each account in its provider's color, a thin gap between
    // accounts, all on one scale.
    private func chart(_ lines: [Line]) -> some View {
        let cols = columns
        let stacks = cols.map { col in lines.map { measure(counts($0, col)) } }
        let top = max(stacks.map { $0.reduce(0, +) }.max() ?? 0, 1)
        let height: CGFloat = 86
        let what: String
        switch ledger.metric {
        case .all: what = span == .year ? L("월별 전체 토큰", "All tokens per month") : L("일별 전체 토큰", "All tokens per day")
        case .fresh: what = span == .year ? L("월별 토큰 (캐시 읽기 제외)", "Tokens per month (no cache reads)") : L("일별 토큰 (캐시 읽기 제외)", "Tokens per day (no cache reads)")
        case .output: what = span == .year ? L("월별 출력", "Output per month") : L("일별 출력", "Output per day")
        }
        return SettingsCard(title: what) {
            HStack(alignment: .bottom, spacing: cols.count > 12 ? 2 : 5) {
                ForEach(cols.indices, id: \.self) { i in
                    let total = stacks[i].reduce(0, +)
                    let parts = lines.indices.reversed().filter { stacks[i][$0] > 0 }
                    let room = max(height - CGFloat(max(parts.count - 1, 0)), 0)
                    VStack(spacing: 2) {
                        if cols.count <= 7 {
                            Text(total > 0 ? Self.short(total) : " ").font(.system(size: 8)).foregroundStyle(.secondary).lineLimit(1).fixedSize()
                        }
                        ZStack(alignment: .bottom) {
                            RoundedRectangle(cornerRadius: 2).fill(Color.primary.opacity(0.06))
                            VStack(spacing: 1) {
                                ForEach(parts, id: \.self) { k in
                                    swatch(lines[k]).frame(height: CGFloat(stacks[i][k]) / CGFloat(top) * room)
                                }
                            }.clipShape(RoundedRectangle(cornerRadius: 2))
                        }.frame(height: height)
                        Text(columnLabel(cols[i], index: i)).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1).fixedSize()
                    }
                    .frame(maxWidth: .infinity)
                    .help(columnHelp(cols[i]) + " · " + Self.short(total)
                          + lines.indices.filter { stacks[i][$0] > 0 }.map { "\n" + lines[$0].name + " " + Self.short(stacks[i][$0]) }.joined())
                }
            }.padding(10)
        }
    }

    private func row(_ line: Line, _ c: TokenCounts, scale: Int) -> some View {
        let open = ledger.open.contains(line.id)
        let devices = line.days.keys.filter(counted).sorted { ($0.isEmpty ? "" : deviceName($0)) < ($1.isEmpty ? "" : deviceName($1)) }
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                swatch(line).frame(width: 8, height: 8).clipShape(Circle())
                Text(line.name).lineLimit(1)
                Spacer()
                Text(Self.short(measure(c))).font(.system(size: 12, weight: .semibold)).monospacedDigit()
                Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(open ? 90 : 0))
            }
            split(c, kinds: kinds(ledger.metric), scale: scale, height: 7)
            if open {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(Kind.allCases, id: \.self) { k in
                        detail(Self.kindName(k), k == .cacheWrite && line.provider != .claude ? "—"
                               : Self.short(Self.value(c, k)) + "  " + Self.percent(Self.value(c, k), of: c.total), color: Self.kindColor(k))
                    }
                    detail(L("전체", "All"), Self.short(c.total), color: nil)
                }
                if line.provider != .claude {
                    Text(L("캐시 쓰기는 Claude만 따로 세요", "Only Claude counts cache writes separately"))
                        .font(.system(size: 9)).foregroundStyle(.tertiary)
                }
                if devices.count > 1 || devices.first.map({ !$0.isEmpty }) == true {
                    Text(devices.map { deviceName($0) + " " + Self.short(measure(counts(line, period, device: $0))) }.joined(separator: " · "))
                        .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(2)
                }
            } else {
                Text(L("입력 ", "In ") + Self.short(c.input) + L(" · 쓰기 ", " · Write ") + (line.provider == .claude ? Self.short(c.cacheWrite) : "—")
                     + L(" · 읽기 ", " · Read ") + Self.short(c.cacheRead) + L(" · 출력 ", " · Out ") + Self.short(c.output))
                    .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
            }
            if line.outside {
                Text(((line.folder?.replacingOccurrences(of: AccountStore.home, with: "~")).map { $0 + " · " } ?? "")
                     + L("앱 계정 밖이라 어느 계정인지 몰라요", "Not an app account: unknown which one"))
                    .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .contentShape(Rectangle())
        .onTapGesture { if open { ledger.open.remove(line.id) } else { ledger.open.insert(line.id) } }
        .overlay(line.outside ? RoundedRectangle(cornerRadius: 6).strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .foregroundStyle(Color.secondary.opacity(0.5)).padding(2) : nil)
    }

    private func detail(_ title: String, _ value: String, color: Color?) -> some View {
        HStack(spacing: 4) {
            if let color { RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 6, height: 6) }
            Text(title)
            Spacer()
            Text(value).monospacedDigit()
        }.font(.system(size: 10)).foregroundStyle(.secondary)
    }

    // The kinds side by side, the bar's length on the given scale.
    private func split(_ c: TokenCounts, kinds: [Kind], scale: Int, height: CGFloat) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3).fill(Color.primary.opacity(0.06))
                HStack(spacing: 0) {
                    ForEach(kinds, id: \.self) { k in
                        Rectangle().fill(Self.kindColor(k)).frame(width: CGFloat(Self.value(c, k)) / CGFloat(max(scale, 1)) * geo.size.width)
                    }
                }.clipShape(RoundedRectangle(cornerRadius: 3))
            }
        }.frame(height: height)
    }

    private static func shortName(_ k: Kind) -> String {
        switch k {
        case .input: return L("입력", "Input")
        case .cacheWrite: return L("캐시 쓰기", "Cache write")
        case .cacheRead: return L("캐시 읽기", "Cache read")
        case .output: return L("출력", "Output")
        }
    }

    private var legend: some View {
        HStack(spacing: 8) {
            ForEach(kinds(ledger.metric), id: \.self) { k in
                HStack(spacing: 3) {
                    RoundedRectangle(cornerRadius: 2).fill(Self.kindColor(k)).frame(width: 8, height: 8)
                    Text(Self.shortName(k)).lineLimit(1).fixedSize()
                }
            }
            HStack(spacing: 3) {
                ZStack { Color.secondary.opacity(0.3); Stripes().stroke(Color.secondary, lineWidth: 1.2) }.frame(width: 8, height: 8).clipShape(RoundedRectangle(cornerRadius: 2))
                Text(L("앱 밖", "Outside")).lineLimit(1).fixedSize()
            }
        }.font(.system(size: 10)).foregroundStyle(.secondary)
    }

    // Other Macs' sums (TokenSync), through the folder of Chats from other Macs.
    private var syncCard: some View {
        SettingsCard(title: L("모든 Mac 합산", "All Macs together"),
                     help: L("각 Mac이 일별 토큰 합계(계정 이름과 숫자만, 대화 내용 없음)를 동기화 폴더(기본: iCloud Drive)의 자기 파일에만 쓰고 다른 Mac 것을 읽어요. 계정은 provider와 이름이 같으면 합쳐요. 30분마다, 그리고 이 화면을 열 때 올라가요.",
                             "Each Mac writes its daily token sums (account names and numbers only, no chat text) to its own file in the sync folder (iCloud Drive by default) and reads the others. Accounts with the same provider and name add up. Sent every 30 minutes and when this page opens.")) {
            SettingsRow(title: L("켜기", "On")) {
                Text(syncStatus).font(.system(size: 11)).foregroundStyle(ledger.syncOn && !deviceSync.folderAvailable ? .orange : .secondary).lineLimit(1)
                Spacer()
                Toggle(L("켜기", "On"), isOn: Binding(get: { ledger.syncOn }, set: { on in
                    ledger.syncOn = on
                    if on { ledger.peers = TokenSync.cached(); ledger.load(model) }
                })).labelsHidden().toggleStyle(.switch)
            }
            if ledger.syncOn {
                Divider()
                SettingsRow(title: L("관리", "Manage")) {
                    SettingsAction(title: L("지금 동기화", "Sync now")) { ledger.load(model) }
                    SettingsAction(title: L("내 사본 지우기", "Remove mine")) {
                        let sync = DeviceSync.shared
                        DispatchQueue.global(qos: .utility).async { TokenSync.removeMine(folder: sync.folder, deviceID: sync.deviceID) }
                        ledger.syncOn = false
                    }
                }
            }
        }
    }

    private var syncStatus: String {
        guard ledger.syncOn else { return L("꺼짐 · 이 Mac만", "Off · this Mac only") }
        if !deviceSync.folderAvailable { return L("iCloud Drive가 꺼져 있어요", "iCloud Drive is off") }
        let macs = L("다른 Mac \(ledger.peers.count)대", "\(ledger.peers.count) other Macs")
        return ledger.syncedAt.map { macs + L(" · 확인 ", " · checked ") + DeviceSync.ago($0) } ?? macs
    }

    private var periodTitle: String {
        let f = DateFormatter()
        f.locale = AppLanguage.current.locale
        switch span {
        case .day: f.setLocalizedDateFormatFromTemplate("MMMdEEE")
        case .week:
            let i = DateIntervalFormatter()
            i.locale = AppLanguage.current.locale
            i.dateTemplate = "MMMd"
            return i.string(from: period.start, to: period.end.addingTimeInterval(-1))
        case .month: f.setLocalizedDateFormatFromTemplate("yMMMM")
        case .year: f.setLocalizedDateFormatFromTemplate("y")
        }
        return f.string(from: period.start)
    }

    private func columnLabel(_ col: DateInterval, index: Int) -> String {
        let f = DateFormatter()
        f.locale = AppLanguage.current.locale
        switch span {
        case .week: f.setLocalizedDateFormatFromTemplate("EEE")
        case .year: f.setLocalizedDateFormatFromTemplate("MMM"); return f.string(from: col.start).replacingOccurrences(of: ".", with: "")
        default: return index % 5 == 0 ? "\(index + 1)" : ""
        }
        return f.string(from: col.start)
    }

    private func columnHelp(_ col: DateInterval) -> String {
        let f = DateFormatter()
        f.locale = AppLanguage.current.locale
        f.setLocalizedDateFormatFromTemplate(span == .year ? "yMMMM" : "MMMdEEE")
        return f.string(from: col.start)
    }

    // The "no logs before" note, as its icon alone when the Mac picker needs the room.
    private struct PartialLabel: LabelStyle {
        let iconOnly: Bool
        func makeBody(configuration: Configuration) -> some View {
            HStack(spacing: 3) { configuration.icon; if !iconOnly { configuration.title } }
        }
    }

    // Diagonal lines: a source outside the app.
    private struct Stripes: Shape {
        func path(in r: CGRect) -> Path {
            var p = Path()
            var x = -r.height
            while x < r.width {
                p.move(to: CGPoint(x: r.minX + x, y: r.maxY))
                p.addLine(to: CGPoint(x: r.minX + x + r.height, y: r.minY))
                x += 4
            }
            return p
        }
    }
    // 950, 12.3K, 7.58M, 1.48B: three digits at most.
    static func short(_ n: Int) -> String {
        let v = Double(n)
        for (size, mark) in [(1e9, "B"), (1e6, "M"), (1e3, "K")] where v >= size {
            let x = v / size
            return String(format: x >= 100 ? "%.0f" : x >= 10 ? "%.1f" : "%.2f", x) + mark
        }
        return "\(n)"
    }
}

// Which model a cloud account answers with, picked in its row: Auto (the CLI's default, as before) or a model.
private final class CloudModelPick: ObservableObject {
    @Published var picked: String?   // nil = Auto
    @Published var gemini: [CloudModels.Choice] = []
    @Published var seen: [String: String] = [:]   // pick ("" = Auto): model id it last ran on
}

private struct CloudModelMenu: View {
    let account: Account
    @StateObject private var state = CloudModelPick()
    private var gemini: [CloudModels.Choice] { state.gemini }
    private static let custom = "\u{0}custom"

    var body: some View {
        let options = options(account)
        Menu {
            Picker(L("모델", "Model"), selection: Binding(get: { state.picked ?? "" }, set: { choose($0, for: account) })) {
                ForEach(options, id: \.1) { Text($0.0).tag($0.1) }
            }
            .pickerStyle(.inline).labelsHidden()
            Divider()
            Button(L("직접 입력…", "Other…")) { choose(Self.custom, for: account) }
        } label: {
            // Cut by hand: fixedSize gives the label its full width, and a typed name may be 80 characters.
            let title = options.first { $0.1 == (state.picked ?? "") }?.0 ?? state.picked ?? ""
            Text(title.count > 18 ? String(title.prefix(17)) + "…" : title).lineLimit(1)
        }
        .menuStyle(.borderlessButton).fixedSize().controlSize(.small)
        .help(L("이 계정이 답할 모델. 자동이면 지금처럼 각 프로그램(Claude Code·Codex·agy)의 기본 모델을 써요. 그 계정에서 못 쓰는 모델을 고르면 답이 오류로 끝나요.",
                "The model this account answers with. Auto keeps each CLI's (Claude Code, Codex, agy) default, as before. A model the account cannot use ends its answers with an error."))
        .onAppear(perform: load)
        // An answer that ends while Settings is open saves a new version (on its own thread): show it.
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification).receive(on: RunLoop.main)) { _ in readSeen() }
    }

    private func readSeen() {
        guard account.provider == .claude else { return }
        let seen = (UserDefaults.app.dictionary(forKey: CloudModels.seenKey) as? [String: [String: String]])?[account.id] ?? [:]
        if seen != state.seen { state.seen = seen }
    }

    private func options(_ account: Account) -> [(String, String)] {
        let choices: [CloudModels.Choice]
        switch account.provider {
        case .claude: choices = CloudModels.claudeChoices
        case .codex: choices = CloudModels.codexChoices(account)
        case .gemini: choices = gemini
        case .ollama: choices = []
        }
        // Claude: the version each alias ran on last time ("Fable 5.1"), once this account has answered with it.
        // Auto stays just "Auto": it is the CLI's choice, not one model.
        func title(_ base: String, _ pick: String?) -> String {
            guard account.provider == .claude, let pick, let id = state.seen[pick] else { return base }
            return CloudModels.seenTitle(id, picked: pick)
        }
        var list = [(title(L("자동", "Auto"), nil), "")] + choices.map { (title($0.title, $0.id), $0.id) }
        // A typed name, or one the list no longer has, still shows as picked.
        if let current = state.picked, !choices.contains(where: { $0.id == current }) { list.append((title(current, current), current)) }
        return list
    }

    private func choose(_ value: String, for account: Account) {
        var name: String? = value.isEmpty ? nil : value
        if value == Self.custom {
            guard let typed = ask(account) else { return }
            name = typed.isEmpty ? nil : typed
        }
        CloudModels.set(name, for: account)
        state.picked = CloudModels.model(account)
    }

    private func ask(_ account: Account) -> String? {
        let alert = NSAlert()
        alert.messageText = L("\(account.name) 모델 이름", "Model name for \(account.name)")
        alert.informativeText = L("CLI에 그대로 넘길 모델 이름이에요(예: opus, gpt-6.1-sol). 비우면 자동이에요.",
                                  "Passed to the CLI as is (e.g. opus, gpt-6.1-sol). Empty: Auto.")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = state.picked ?? ""
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        alert.addButton(withTitle: L("저장", "Save"))
        alert.addButton(withTitle: L("취소", "Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let typed = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !typed.isEmpty && !CloudModels.valid(typed) {
            let bad = NSAlert()
            bad.messageText = L("쓸 수 없는 이름이에요", "Not a model name")
            bad.informativeText = L("영문·숫자로 시작하고 영문·숫자·. _ - : / [ ]만 써 주세요.", "Start with a letter or digit; use only letters, digits and . _ - : / [ ].")
            bad.runModal()
            return nil
        }
        return typed
    }

    private func load() {
        state.picked = CloudModels.model(account)
        readSeen()
        if account.provider == .gemini, gemini.isEmpty {
            CloudModels.loadGemini(account) { [state] in state.gemini = $0 }
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
            SettingsCard(title: L("채팅 규칙", "Chat rules"),
                         help: L("모든 AI 요청에 적용할 말투와 응답 규칙이에요. 답변 길이는 채팅창에서 선택해요.",
                                 "Style and instructions for every AI request. Choose response length in the chat window.")) {
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
            MemorySettingsCard()
            SettingsCard(title: L("메시지 판정", "Message sorting"),
                         help: L("프로젝트 채팅에서 메시지마다 한 명이 답할지, 모두 답할지, 작업할지 정해요. 고른 모델을 받아 두지 않았거나 Ollama를 껐으면 참여한 AI가 판정해요.",
                                 "Decides for each project-chat message: one answer, everyone, or work. Model not downloaded or Ollama off: a member AI judges.")) {
                SettingsRow(title: L("내 Mac 모델", "Model on this Mac")) {
                    SettingsMenu(options: RouteSorter.allCases.map { ($0.title, $0) }, selection: $model.routeSorter)
                }
                .help(model.routeSorter.summary)
                .onChange(of: model.routeSorter) { SortModelStatus.offer($0, model: model) }
                if model.routeSorter != .off {
                    Divider()
                    SortModelStatus(model: model, store: .shared)
                }
            }
            CollabSettingsCard(model: model)
            AutoTeamSettingsCard(model: model)
            SettingsCard(title: L("의견 자동 정리", "Sum up views"),
                         help: L("여러 AI가 의견을 내면, 답한 AI 중 사용량이 가장 많이 남은 AI가 결론·합의·갈린 점·결정할 것으로 정리해요. 개별 답변은 그 아래에 접혀요. 정리하지 못하면 개별 답변만 보여요.",
                                 "When several AIs give views, the one with the most usage left sums them up: conclusion, agreements, disagreements, what to decide. The answers fold under it. If it cannot, the answers show as before.")) {
                SettingsRow(title: L("자동 정리", "Sum up")) {
                    Spacer()
                    Toggle(L("의견 자동 정리", "Sum up views"), isOn: $model.opinionDigest).labelsHidden().toggleStyle(.switch)
                }
            }
            let makers = model.accounts.filter { $0.provider == .codex }
            if !makers.isEmpty {
                SettingsCard(title: L("그림 담당", "Picture makers"),
                             help: L("켜 둔 ChatGPT 계정이 다른 AI 대신 모든 그림을 그려요. 위 설정이 켜져 있으면 엔터프라이즈 AI는 엔터프라이즈 ChatGPT에게, 개인 AI는 개인 ChatGPT에게만 맡겨요. 숫자가 정확해야 하는 그래프와 도표는 각 AI가 직접 그려요.",
                                     "Checked ChatGPT accounts draw every picture for the other AIs. With the setting above on, Enterprise AIs ask only Enterprise ChatGPT and personal AIs only personal ChatGPT. Charts and diagrams that must be exact are still drawn by each AI.")) {
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
            }
            StorageSettingsCard()
            ApprovalAlertSettingsView()
            DeviceSyncSettingsView()
        }
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

// In the Chat tab: long-term memory (Memory.swift). Only the switch until it is on; then whether the AI saves
// on its own, and the saved profile and facts in their own window.
// AI-to-AI collaboration: off / show and go / on its own, and what the log counted in the last 30 days.
private struct CollabSettingsCard: View {
    @ObservedObject var model: AppModel

    var body: some View {
        SettingsCard(title: L("AI끼리 협업", "AIs working together"),
                     help: L("답하는 AI가 필요할 때 다른 AI에게 묻고(ask_ai), 검토를 받고, 회의를 열어요. 불려 온 AI는 읽기만 하고 다시 부르지 않아요. 기록에는 누가 누구에게 왜 불렀는지만 남고 내용은 남지 않아요.",
                             "An answering AI asks other AIs (ask_ai), gets reviews and holds meetings when needed. AIs it calls only read and call nobody. The log keeps who called whom and why, never the text.")) {
            SettingsRow(title: L("AI끼리 협업", "AIs working together")) {
                SettingsMenu(options: CollabMode.allCases.map { ($0.title, $0) }, selection: $model.collaboration)
            }
            .help(model.collaboration.summary)
            Divider()
            Text(model.collaboration.summary)
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10).padding(.vertical, 4)
            Text(L("최근 30일: ", "Last 30 days: ") + CollabLog.line(CollabLog.summary(CollabLog.events(since: Date().addingTimeInterval(-30 * 86400)))))
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10).padding(.bottom, 6)
        }
    }
}

// Which AIs the app may call by itself when a chat's members are automatic: a meeting, or several views asked for.
private struct AutoTeamSettingsCard: View {
    @ObservedObject var model: AppModel

    var body: some View {
        let accounts = model.accounts.filter { Discussion.meets($0) || $0.provider == .ollama }
        if !accounts.isEmpty {
            SettingsCard(title: L("자동으로 부를 AI", "AIs picked automatically"),
                         help: L("참여 AI를 고르지 않은 채팅에서 회의나 여러 의견을 부탁하면, 켜 둔 AI 중에서 사용량이 많이 남은 AI를 종류별로 먼저 최대 4명 불러요. 기본은 Claude·ChatGPT·Gemini예요.",
                                 "In a chat without picked members, a meeting or several views call up to four of the AIs switched on here, one of each kind first, most usage left first. Default: Claude, ChatGPT and Gemini.")) {
                ForEach(accounts, id: \.id) { account in
                    let off = account.provider == .ollama && !model.localEnabled
                    SettingsRow(title: account.name) {
                        Text(off ? L("Ollama 꺼짐", "Ollama off") : account.provider == .ollama ? L("내 Mac", "This Mac") : account.provider.title)
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                        Spacer()
                        Toggle(account.name, isOn: Binding(
                            get: { Discussion.autoPicked(account, picks: model.autoTeamPicks) },
                            set: { model.autoTeamPicks[account.id] = $0 }))
                            .labelsHidden().toggleStyle(.switch).disabled(off)
                    }
                }
                if !model.autoTeamPicks.isEmpty {
                    Divider()
                    SettingsRow(title: L("직접 고침", "Custom")) {
                        SettingsAction(title: L("기본값으로", "Use default")) { model.autoTeamPicks = [:] }
                    }
                }
            }
        }
    }
}

private struct MemorySettingsCard: View {
    @ObservedObject var memory = MemoryStore.shared

    private var saved: String {
        let profile = memory.data.profile.isEmpty ? L("프로필 없음", "No profile") : L("프로필 \(memory.data.profile.count)자", "Profile \(memory.data.profile.count) chars")
        return profile + " · " + L("기억 \(memory.data.items.count)개", "\(memory.data.items.count) facts")
    }

    var body: some View {
        SettingsCard(title: L("기억", "Memory"),
                     help: L("모든 AI가 같은 기억을 읽어요. 이 Mac에만 저장되지만 답할 때 그 AI에게 보내져요. Enterprise 방은 읽기만 하고 저장하지 않아요. 비밀번호나 키는 저장하지 않아요.",
                             "Every AI reads the same memory. It stays on this Mac but is sent to the AI that answers. Enterprise chats only read it. Passwords and keys are never saved.")) {
            SettingsRow(title: L("기억 사용", "Use memory")) {
                Spacer()
                Toggle(L("기억 사용", "Use memory"), isOn: Binding(
                    get: { memory.data.enabled }, set: { on in memory.update { $0.enabled = on } }))
                    .labelsHidden().toggleStyle(.switch)
            }
            if memory.data.enabled {
                Divider()
                SettingsRow(title: L("AI가 알아서 저장", "AI saves on its own")) {
                    Spacer()
                    Toggle(L("AI가 알아서 저장", "AI saves on its own"), isOn: Binding(
                        get: { memory.data.autoSave }, set: { on in memory.update { $0.autoSave = on } }))
                        .labelsHidden().toggleStyle(.switch)
                }
                .help(memory.data.autoSave
                      ? L("AI가 기억할 만한 내용을 스스로 저장해요. 저장하면 답 아래에 \"기억함\"과 취소 버튼이 떠요.",
                          "AIs save lasting facts on their own. Each one shows under the answer with Undo.")
                      : L("꺼져 있으면 \"기억해\"라고 말한 메시지에서만 저장해요.",
                          "Off: facts are saved only when your message asks to remember."))
                Divider()
                SettingsRow(title: L("저장된 내용", "Saved")) {
                    Text(L("\(memory.data.items.count)개", "\(memory.data.items.count)")).monospacedDigit()
                    Spacer()
                    SettingsAction(title: L("열기…", "Open…")) { MemoryWindow.shared.show() }.frame(width: 70)
                }
                .help(saved)
            }
        }
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
        SettingsCard(title: L("다른 기기의 대화", "Chats from other Macs"),
                     help: L("다른 Mac에서 하던 대화를 읽기 전용으로 보고, 원하면 이 Mac에서 새 대화로 이어가요. 각 Mac은 동기화 폴더의 자기 폴더에만 써서 서로 덮어쓰지 않아요. ‘고른 대화만’이면 대화 메뉴(⋯)의 ‘다른 기기에 보이기’로 골라요. 엔터프라이즈 대화는 켜야만 올라가고, 끄면 이미 올린 사본도 지워져요. 그림, 연결한 폴더, 세션 기록은 올라가지 않아요.",
                             "See chats from your other Macs read only, and continue one here as a new chat. Each Mac writes only its own folder in the sync folder, so nothing is overwritten. With ‘Chosen chats’, pick them with ‘Show on other Macs’ in a chat's ⋯ menu. Enterprise chats go up only when included; turning that off removes their copies. Pictures, linked folders and sessions are not copied.")) {
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
}

// Every MCP server the chat's AI may use, in one tab, one switch each (like the ChatGPT app): the app's own
// tools, AI Face (adds itself when AI Illuminati is connected in AI Face; which of its tools work is set there),
// Google Drive, and the servers added here (ExternalMCP.swift).
struct MCPSettingsTab: View {
    var body: some View {
        SettingsPage { MCPSettings() }
    }
}

private struct MCPSettings: View {
    @ObservedObject var link = FaceLink.shared
    @ObservedObject var drive = DriveCenter.shared
    @ObservedObject var external = ExternalMCP.shared
    @ObservedObject var draft = MCPServerDraft.shared
    @ObservedObject var tools = MCPToolsChoice.shared

    private var importable: [MCPServerEntry] { ExternalMCP.claudeDesktopServers(existing: external.servers) }

    var body: some View {
        SettingsCard(title: L("앱에 들어 있는 서버", "Built in"),
                     help: L("일반 채팅과 프로젝트 작업의 AI가 쓰는 도구예요. 다른 모드(토론·협업·투표)는 MCP 도구를 쓰지 않아요.",
                             "Tools the AI uses in plain chat and project work. Debate, collaboration and vote modes use no MCP tools.")) {
            SettingsRow(title: "illuminati") {
                Text(L("늘 켜짐", "Always on")).foregroundStyle(.green)
            }
            .help(L("앱 기본 도구: 연결한 폴더 읽기·쓰기, 다른 채팅 찾기, Git, 다른 AI 의견, 할 일 등.",
                    "The app's own tools: linked folders, other chats, Git, a second opinion, TODOs and more."))
            Divider()
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
                note("ai-face", L("없음", "None"),
                     help: L("AI Face 설정 → AI에서 AI Illuminati를 연결하면 여기에 보여요.",
                             "Connect AI Illuminati in AI Face (Settings → AI) and it shows here."))
            }
            Divider()
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
                note("google-drive", L("연결 안 됨", "Not connected"),
                     help: L("채팅창 사이드바의 Google Drive에서 연결해요.",
                             "Connect it under Google Drive in the chat window's sidebar."))
            }
        }
        SettingsCard(title: L("직접 추가한 서버", "Added by you"),
                     help: L("명령 서버는 이 Mac에서 내 권한으로 실행되고, URL 서버는 앱이 이 Mac에서 직접 연결해요(VPN·학교 내부 서버도 돼요). 켜 둔 서버의 도구는 일반 채팅과 프로젝트 작업의 AI가 쓸 수 있어요(엔터프라이즈 채팅은 빼고). URL 서버의 쓰기 도구는 기본으로 쓸 때마다 물어봐요.",
                             "Command servers run on this Mac as you; URL servers are reached by the app from this Mac (VPN and campus servers work too). The AI in plain chat and project work may use the tools of a server that is on (not in Enterprise chats). Write tools of URL servers ask each time by default.")) {
            if let error = external.loadError {
                SettingsRow(title: "mcp-servers.json") { Text(error).foregroundStyle(.orange).lineLimit(3) }
                Divider()
            }
            ForEach(external.servers) { server in
                MCPServerRow(server: server, status: external.status[server.name], edit: { draft.open(server) },
                             enterKey: { draft.open(server, askKey: true) }, showTools: { tools.server = server.name })
                Divider()
            }
            HStack(spacing: 8) {
                Button(L("서버 추가…", "Add Server…")) { draft.open(nil) }
                if !importable.isEmpty {
                    Button(L("Claude 데스크톱에서 가져오기 (\(importable.count))", "Import from Claude Desktop (\(importable.count))")) {
                        _ = external.importClaudeDesktop()
                    }
                    .help(L("Claude 데스크톱에 등록한 서버를 꺼진 채로 가져와요. 하나씩 보고 켜세요.",
                            "Adds the servers set up in Claude desktop, switched off. Look at each one, then turn it on."))
                }
                Spacer()
            }
            .disabled(external.loadError != nil)
            .padding(.horizontal, 10).padding(.vertical, 6)
        }
        .sheet(isPresented: $draft.showing) { MCPServerEditor(draft: draft) }
        .sheet(isPresented: Binding(get: { tools.server != nil }, set: { if !$0 { tools.server = nil } })) {
            MCPToolsSheet(server: tools.server ?? "", external: external, done: { tools.server = nil })
        }
        .onAppear { link.refresh(); drive.refresh(); external.refresh() }
    }

    // A server that is not set up: one short line, with how to add it on hover.
    private func note(_ name: String, _ status: String, help: String) -> some View {
        SettingsRow(title: name) {
            Text(status).foregroundStyle(.secondary)
        }
        .help(help)
    }
}

private struct MCPServerRow: View {
    let server: MCPServerEntry
    let status: ExternalMCP.Status?
    let edit: () -> Void
    let enterKey: () -> Void
    let showTools: () -> Void

    private var label: (String, Color) {
        if status?.signingIn == true { return (L("브라우저에서 로그인 중…", "Signing in in the browser…"), .secondary) }
        switch status?.state {
        case .off: return (L("꺼짐", "Off"), .secondary)
        case .connected:
            let count = status?.tools.count ?? 0, changed = status?.changed.count ?? 0
            return (L("연결됨 · 도구 \(count)개", "Connected · \(count) tools") + (changed > 0 ? L(" · 바뀐 도구 \(changed)개", " · \(changed) changed") : ""),
                    changed > 0 ? .orange : .green)
        case .needsLogin: return (status?.oauth == true ? L("로그인 필요", "Sign-in needed") : L("API 키 필요", "API key needed"), .orange)
        case .failed: return (L("연결 안 됨", "Not connected"), .orange)
        default: return (L("연결 중…", "Connecting…"), .secondary)
        }
    }

    var body: some View {
        SettingsRow(title: server.name) {
            Text(label.0).foregroundStyle(label.1).lineLimit(1)
            Spacer()
            if status?.state == .needsLogin, status?.signingIn != true {
                if status?.oauth == true { Button(L("로그인", "Sign In")) { ExternalMCP.shared.signIn(server.name) } }
                else { Button(L("키 입력…", "Enter Key…"), action: enterKey) }
            }
            Toggle(server.name, isOn: Binding(get: { ExternalMCP.isOn(server.name) && status?.state != .off },
                                              set: { ExternalMCP.shared.setOn(server.name, $0) }))
                .labelsHidden().toggleStyle(.switch)
            Menu {
                Button(L("편집…", "Edit…"), action: edit)
                Button(L("도구…", "Tools…"), action: showTools).disabled(status?.state != .connected)
                Button(L("다시 연결", "Reconnect")) { ExternalMCP.shared.reconnect(server.name) }
                    .disabled(status?.state == .off)
                if server.isRemote {
                    if status?.signedIn == true { Button(L("로그아웃", "Sign Out")) { ExternalMCP.shared.signOut(server.name) } }
                    else { Button(L("브라우저로 로그인", "Sign In in Browser")) { ExternalMCP.shared.signIn(server.name) }.disabled(status?.signingIn == true) }
                }
                Divider()
                Button(L("삭제…", "Delete…")) { delete() }
            } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        }
        .help(details)
    }

    // On hover: what runs, why it failed, the tools it gives.
    private var details: String {
        var lines = [server.isRemote ? server.url : ([server.command] + server.args).joined(separator: " ")]
        if let message = status?.message { lines.append(message) }
        if let tools = status?.tools, !tools.isEmpty { lines.append(L("도구: ", "Tools: ") + tools.joined(separator: ", ")) }
        if let skipped = status?.skipped, !skipped.isEmpty { lines.append(L("이름이 길거나 겹쳐서 뺀 도구: ", "Left out (name too long or taken): ") + skipped.joined(separator: ", ")) }
        return lines.joined(separator: "\n")
    }

    private func delete() {
        let alert = NSAlert()
        alert.messageText = L("‘\(server.name)’ 서버를 삭제할까요?", "Delete the server “\(server.name)”?")
        alert.informativeText = server.isRemote ? L("이 Mac에 저장된 키와 로그인 정보도 지워요.", "Its key and sign-in saved on this Mac are removed too.")
            : L("앱 목록에서만 빠져요. 서버 프로그램은 그대로예요.", "It is only removed from the app's list. The server program stays.")
        alert.addButton(withTitle: L("삭제", "Delete"))
        alert.addButton(withTitle: L("취소", "Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do { try ExternalMCP.shared.remove(server.name) } catch { NSAlert(error: error).runModal() }
    }
}

// The editor's typing (an ObservableObject: this Mac's Command Line Tools cannot build SwiftUI's @State).
final class MCPServerDraft: ObservableObject {
    static let shared = MCPServerDraft()
    @Published var showing = false
    @Published var name = ""
    @Published var remote = false
    @Published var url = ""
    @Published var headers = ""          // remote: "Name: value" lines
    @Published var clientID = ""
    @Published var clientSecret = ""
    @Published var advanced = false
    @Published var command = ""
    @Published var args = ""
    @Published var env = ""
    @Published var pasted = ""
    @Published var error: String?
    var original: MCPServerEntry?
    /// The command as saved or pasted in JSON: one program, kept whole even with spaces in its path.
    private var exactCommand: String?
    private var savedSecret = ""

    /// askKey: the server wants an API key, so the header is ready to fill.
    func open(_ entry: MCPServerEntry?, askKey: Bool = false) {
        original = entry
        name = entry?.name ?? ""; command = entry?.command ?? ""; exactCommand = entry?.command
        args = entry?.args.joined(separator: "\n") ?? ""
        env = entry.map(Self.lines) ?? ""
        remote = entry?.isRemote ?? false; url = entry?.url ?? ""
        clientID = entry?.oauthClientID ?? ""
        headers = entry.map { Self.headerText($0.headers, server: $0.name) } ?? ""
        savedSecret = entry.flatMap { $0.isRemote ? MCPSecrets.store.get(MCPSecrets.clientSecret($0.name)) : nil } ?? ""
        clientSecret = savedSecret
        if askKey, !headers.lowercased().contains("authorization:") { headers = "Authorization: Bearer " + (headers.isEmpty ? "" : "\n" + headers) }
        advanced = askKey || !clientID.isEmpty
        pasted = ""; error = nil; showing = true
    }
    static func lines(_ entry: MCPServerEntry) -> String { entry.env.keys.sorted().map { "\($0)=\(entry.env[$0] ?? "")" }.joined(separator: "\n") }
    /// Saved header values come from the Keychain only here, when the user opens the editor.
    static func headerText(_ headers: [String: String], server: String) -> String {
        headers.keys.sorted().map { key in
            let value = headers[key].flatMap { $0.isEmpty ? nil : $0 } ?? (server.isEmpty ? nil : MCPSecrets.store.get(MCPSecrets.header(server, key))) ?? ""
            return "\(key): \(value)"
        }.joined(separator: "\n")
    }

    /// Fills the fields from a pasted URL, command line or JSON. quiet: while typing, no error for a half-pasted text.
    func fill(quiet: Bool = false) {
        guard let entry = MCPServerEntry.parse(pasted).first else {
            if !quiet { error = L("서버 설정을 찾지 못했어요. URL, 설치 명령(claude/codex mcp add …) 또는 JSON을 붙여 주세요.", "No server found. Paste a URL, an install command (claude/codex mcp add …) or JSON.") }
            return
        }
        if !entry.name.isEmpty { name = entry.name }
        remote = entry.isRemote
        if entry.isRemote {
            url = entry.url; clientID = entry.oauthClientID
            headers = Self.headerText(entry.headers, server: "")
            advanced = !entry.headers.isEmpty || !clientID.isEmpty
        } else {
            command = entry.command; exactCommand = entry.command
            args = entry.args.joined(separator: "\n")
            env = Self.lines(entry)
        }
        error = nil
    }

    /// The entry the fields describe, or why they do not describe one.
    func entry() -> Result<MCPServerEntry, MCPSession.Failure> {
        let entry: MCPServerEntry
        if remote {
            let address = url.trimmingCharacters(in: .whitespacesAndNewlines)
            if let problem = MCPServerEntry.urlProblem(address) { return .failure(.init(message: problem)) }
            var parsed: [String: String]
            switch MCPServerEntry.headerLines(headers) { case .success(let h): parsed = h; case .failure(let e): return .failure(e) }
            // "Authorization: Bearer " left empty is no header.
            parsed = parsed.filter { !$0.value.isEmpty && $0.value.lowercased() != "bearer" }
            entry = MCPServerEntry(name: MCPServerEntry.normalized(name.isEmpty ? MCPServerEntry.name(fromURL: address) : name), url: address,
                                   headers: parsed, oauthClientID: clientID.trimmingCharacters(in: .whitespaces))
        } else {
            let whole = command == exactCommand || FileManager.default.isExecutableFile(atPath: command.trimmingCharacters(in: .whitespaces))
            var words = whole ? [command.trimmingCharacters(in: .whitespaces)] : MCPServerEntry.words(command)
            var list = args.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            // "npx -y some-server" typed into the command field: the first word runs, the rest are arguments.
            if words.count > 1 { list = Array(words.dropFirst()) + list; words = [words[0]] }
            var variables: [String: String] = [:]
            for line in env.split(separator: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else { continue }
                guard let equal = trimmed.firstIndex(of: "="), equal != trimmed.startIndex else {
                    return .failure(.init(message: L("환경 변수는 이름=값 모양으로 적어 주세요: ", "Write variables as NAME=value: ") + trimmed))
                }
                variables[String(trimmed[..<equal])] = String(trimmed[trimmed.index(after: equal)...])
            }
            entry = MCPServerEntry(name: MCPServerEntry.normalized(name), command: words.first ?? command, args: list, env: variables)
        }
        if MCPServerEntry.reserved.contains(entry.name) { return .failure(.init(message: L("이 이름은 앱이 써요. 다른 이름을 골라 주세요.", "The app uses this name. Pick another."))) }
        return .success(entry)
    }

    var canSave: Bool { remote ? !url.trimmingCharacters(in: .whitespaces).isEmpty : !name.isEmpty && !command.trimmingCharacters(in: .whitespaces).isEmpty }

    func save() {
        do {
            let entry = try entry().get()
            // A new URL server, or a new address: try it at once and open the browser if it wants a sign-in.
            let fresh = entry.isRemote && (original?.url != entry.url)
            try ExternalMCP.shared.save(entry, replacing: original?.name, clientSecret: remote && clientSecret != savedSecret ? clientSecret : nil, signIn: fresh)
            showing = false
        } catch { self.error = (error as? MCPSession.Failure)?.message ?? error.localizedDescription }
    }
}

// Add or edit one server. New: one box takes a URL, an install command from a README (claude/codex mcp add …) or
// JSON, and fills the rest. A URL server shows its address and, folded, headers and an OAuth client; a command
// server its command, arguments and environment.
private struct MCPServerEditor: View {
    @ObservedObject var draft: MCPServerDraft

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(draft.original == nil ? L("MCP 서버 추가", "Add MCP Server") : L("MCP 서버 편집", "Edit MCP Server")).font(.headline)
            if draft.original == nil {
                label(L("URL, 설치 명령 또는 JSON을 붙여 넣으세요", "Paste a URL, an install command or JSON"))
                editor($draft.pasted, height: 46)
                    .onChange(of: draft.pasted) { _ in draft.fill(quiet: true) }
                Divider()
            }
            Picker("", selection: $draft.remote) {
                Text(L("URL (원격)", "URL (remote)")).tag(true)
                Text(L("명령 (이 Mac)", "Command (this Mac)")).tag(false)
            }.pickerStyle(.segmented).labelsHidden()
            field(L("이름", "Name"), TextField(draft.remote ? "notion" : "filesystem", text: $draft.name))
            if draft.remote {
                field("URL", TextField("https://mcp.example.com/mcp", text: $draft.url))
                DisclosureGroup(L("고급", "Advanced"), isExpanded: $draft.advanced) {
                    label(L("요청 헤더 (이름: 값, 한 줄에 하나 · 값은 키체인에 저장)", "Request headers (Name: value, one per line · values go to the Keychain)"))
                    editor($draft.headers, height: 40)
                    label(L("OAuth client (서버가 자동 등록을 지원하지 않을 때만)", "OAuth client (only when the server has no automatic registration)"))
                    field("ID", TextField("client-id", text: $draft.clientID))
                    field("Secret", SecureField(L("없으면 비워 두세요", "Leave empty if none"), text: $draft.clientSecret))
                }
                Text(L("저장하면 바로 연결해 보고, 로그인이 필요하면 브라우저가 열려요. 이 Mac에서 직접 연결하니 VPN·학교 내부 서버도 돼요. 믿을 수 있는 서버만 추가하세요.",
                       "Saving connects at once and opens the browser if the server wants a sign-in. The app connects from this Mac, so VPN and campus servers work. Add only servers you trust."))
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                field(L("명령", "Command"), TextField("npx", text: $draft.command))
                label(L("인자 (한 줄에 하나)", "Arguments (one per line)"))
                editor($draft.args, height: 64)
                label(L("환경 변수 (이름=값, 한 줄에 하나)", "Environment (NAME=value, one per line)"))
                editor($draft.env, height: 40)
                Text(L("이 서버는 이 Mac에서 내 권한으로 실행돼요. 믿을 수 있는 서버만 추가하세요.",
                       "The server runs on this Mac as you. Add only servers you trust."))
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let error = draft.error { Text(error).font(.system(size: 11)).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Spacer()
                Button(L("취소", "Cancel")) { draft.showing = false }.keyboardShortcut(.cancelAction)
                Button(draft.original == nil ? L("추가", "Add") : L("저장", "Save")) { draft.save() }.keyboardShortcut(.defaultAction)
                    .disabled(!draft.canSave)
            }
        }
        .font(.system(size: 12)).controlSize(.small)
        .padding(14).frame(width: 380)
    }

    private func label(_ text: String) -> some View { Text(text).font(.system(size: 11)).foregroundStyle(.secondary) }
    private func field<F: View>(_ title: String, _ control: F) -> some View {
        HStack { Text(title).frame(width: 44, alignment: .leading); control.textFieldStyle(.roundedBorder) }
    }
    private func editor(_ text: Binding<String>, height: CGFloat) -> some View {
        TextEditor(text: text).font(.system(size: 11, design: .monospaced)).frame(height: height)
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.primary.opacity(0.15)))
    }
}

final class MCPToolsChoice: ObservableObject {
    static let shared = MCPToolsChoice()
    @Published var server: String?
}

// One server's tools, each always allowed, asked each time, or blocked (like Claude's connector settings).
private struct MCPToolsSheet: View {
    let server: String
    @ObservedObject var external: ExternalMCP
    let done: () -> Void

    var body: some View {
        let status = external.status[server]
        VStack(alignment: .leading, spacing: 8) {
            Text(L("\(server) 도구", "\(server) tools")).font(.headline)
            Text(L("‘승인 필요’ 도구는 쓸 때마다 채팅에 승인 카드가 떠요. 서버가 도구를 바꾸면 기본값으로 돌아가요.",
                   "Tools set to Ask show an approval card in the chat each time. A tool the server changes goes back to its default."))
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(status?.tools ?? [], id: \.self) { tool in
                        HStack {
                            Text(tool).lineLimit(1)
                            if status?.readOnly.contains(tool) == true { Text(L("읽기", "read")).font(.system(size: 10)).foregroundStyle(.secondary) }
                            if status?.changed.contains(tool) == true { Text(L("바뀜", "changed")).font(.system(size: 10)).foregroundStyle(.orange) }
                            Spacer()
                            Picker("", selection: Binding(get: { status?.rules[tool] ?? .allow }, set: { external.setRule(server, tool, $0) })) {
                                Text(L("항상 허용", "Always allow")).tag(MCPToolRule.allow)
                                Text(L("승인 필요", "Ask")).tag(MCPToolRule.ask)
                                Text(L("차단", "Block")).tag(MCPToolRule.block)
                            }.labelsHidden().frame(width: 120)
                        }
                    }
                }
            }.frame(height: 260)
            // Seen: the "changed" marks go once the sheet is closed.
            HStack { Spacer(); Button(L("닫기", "Done")) { external.acknowledgeChanges(server); done() }.keyboardShortcut(.defaultAction) }
        }
        .font(.system(size: 12)).controlSize(.small)
        .padding(14).frame(width: 420)
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
                    // Fixed width so every row's Enterprise box starts at the same x.
                    Text(account.provider.title).foregroundStyle(.secondary)
                        .frame(width: 46, alignment: .leading)
                    if account.provider == .ollama {
                        status
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
                    if account.provider != .ollama {
                        Toggle(L("엔터프라이즈", "Enterprise"), isOn: Binding(
                            get: { model.accounts.first { $0.id == account.id }?.isSchool ?? false },
                            set: { model.setSchool(account.id, $0) }))
                            .toggleStyle(.checkbox).controlSize(.mini)
                            .help(L("엔터프라이즈(학교·회사) 계정: 직접 잠근 Enterprise 방에는 이름이 같은 엔터프라이즈 계정과 내 Mac 모델만 참여해요", "Enterprise (school or work) account: a chat you lock as Enterprise is answered only by Enterprise accounts of the same name and models on this Mac"))
                        status
                    }
                }.font(.system(size: 10)).lineLimit(1)
            }
            Spacer(minLength: 4)
            if account.provider != .ollama { CloudModelMenu(account: account) }
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
                if account.provider == .ollama {
                    Button(L("이 Mac에서 지우기…", "Delete from this Mac…")) { model.deleteLocal(account) }
                }
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

    // Like AI Face's "Connected": green when signed in, orange when a sign-in is needed. Usage % lives in the menu, not here.
    @ViewBuilder private var status: some View {
        if let usage = model.latestUsage[account.id] {
            if usage.needsLogin {
                Text(L("로그인 필요", "Sign-in needed")).foregroundStyle(.orange)
            } else {
                Text(L("연결됨", "Connected")).foregroundStyle(.green)
            }
        } else {
            Text(L("확인 중…", "Checking…")).foregroundStyle(.secondary)
        }
    }
}

// Storage: how much each chat takes, largest first, and the automatic cleanup of old backups.
// Measuring reads metadata only and runs in the background; nothing here deletes chats.
final class StorageModel: ObservableObject {
    static let shared = StorageModel()
    @Published var report: ChatStorage.Report?
    @Published var measuring = false
    @Published var cleaning = false
    @Published var note = ""
    @Published var policy = WorkspaceBackup.Policy.current {
        didSet { if policy != oldValue { WorkspaceBackup.Policy.current = policy } }
    }

    // Every chat's backups and those of deleted chats (an upper bound: clones share blocks).
    static func backups(_ report: ChatStorage.Report) -> Int64 {
        let base = WorkspaceBackup.base.path + "/"
        return report.rooms.compactMap { $0.parts[.backups]?.allocated }.reduce(0, +)
            + report.orphans.filter { $0.url.path.hasPrefix(base) }.map(\.size.allocated).reduce(0, +)
    }

    func measure() {
        guard !measuring else { return }
        measuring = true
        let chats = ChatLink.shared.conversations().map { (id: $0.id, title: $0.title, meetingOf: $0.meetingOf?.room) }
        DispatchQueue.global(qos: .utility).async {
            let report = ChatStorage.report(chats)
            DispatchQueue.main.async { self.report = report; self.measuring = false }
        }
    }

    func cleanNow() {
        guard !cleaning else { return }
        cleaning = true
        let policy = policy
        DispatchQueue.global(qos: .utility).async {
            let result = WorkspaceBackup.cleanUp(policy)
            DispatchQueue.main.async {
                self.cleaning = false
                self.note = result.removed + result.trimmed == 0 ? L("정리할 백업이 없어요.", "No backups to clean up.")
                    : L("백업 \(result.removed)개 삭제, \(result.trimmed)개 축소, 최대 \(ChatStorage.format(result.bytes)) 확보",
                        "Deleted \(result.removed) backups, trimmed \(result.trimmed), up to \(ChatStorage.format(result.bytes)) freed")
                self.measure()
            }
        }
    }
}

// In the Chat tab: the total, with the list by chat and the backup cleanup in their own resizable windows
// (the settings window is too narrow for full titles and sizes).
private struct StorageSettingsCard: View {
    @ObservedObject var storage = StorageModel.shared

    var body: some View {
        SettingsCard(title: L("저장 공간", "Storage"),
                     help: L("앱이 채팅마다 쓰는 디스크 크기예요. 백업은 원본과 블록을 나눠 쓰는 복제라 표시된 크기는 최대치예요.",
                             "Disk the app uses for chats. Backups are clones that share blocks with the originals: their size is an upper bound.")) {
            SettingsRow(title: L("전체", "Total")) {
                Text(storage.report.map { ChatStorage.format($0.total.allocated) } ?? "–").monospacedDigit()
                Spacer()
                SettingsAction(title: storage.measuring ? L("계산 중…", "Measuring…") : L("다시 계산", "Measure")) { storage.measure() }
                    .disabled(storage.measuring).frame(width: 90)
            }
            Divider()
            SettingsRow(title: L("백업", "Backups")) {
                Text(storage.report.map { ChatStorage.format(StorageModel.backups($0)) } ?? "–").monospacedDigit()
                Spacer()
            }
            Divider()
            SettingsRow(title: L("채팅방별 용량", "By chat")) {
                SettingsAction(title: L("목록 보기…", "Show List…")) { StorageWindows.shared.showList() }
            }
            Divider()
            SettingsRow(title: L("백업 자동 정리", "Backup cleanup")) {
                SettingsAction(title: L("설정…", "Settings…")) { StorageWindows.shared.showCleanup() }
            }
        }
        .onAppear { if storage.report == nil { storage.measure() } }
    }
}

// The two storage windows, made once and reused (like ChatRulesWindow).
final class StorageWindows {
    static let shared = StorageWindows()
    private var list: NSWindow?, cleanup: NSWindow?

    func showList() {
        list = list ?? make(StorageListView().frame(minWidth: 440, idealWidth: 560, minHeight: 320, idealHeight: 560),
                            title: L("채팅방별 용량", "Storage by Chat"), size: NSSize(width: 560, height: 560), resizable: true)
        bring(list)
    }
    func showCleanup() {
        cleanup = cleanup ?? make(BackupCleanupView().frame(width: 420), title: L("백업 자동 정리", "Backup Cleanup"),
                                  size: NSSize(width: 420, height: 330), resizable: false)
        bring(cleanup)
    }
    private func make<V: View>(_ view: V, title: String, size: NSSize, resizable: Bool) -> NSWindow {
        let host = NSHostingController(rootView: view)
        if !resizable { host.sizingOptions = [.preferredContentSize] }
        let w = NSWindow(contentViewController: host)
        w.styleMask = resizable ? [.titled, .closable, .miniaturizable, .resizable] : [.titled, .closable, .miniaturizable]
        w.title = title
        w.setContentSize(size)
        w.isReleasedWhenClosed = false
        w.center()
        return w
    }
    private func bring(_ window: NSWindow?) {
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

struct BackupCleanupView: View {
    @ObservedObject var storage = StorageModel.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SettingsCard(title: L("백업 자동 정리", "Backup cleanup")) {
                SettingsRow(title: L("보관 기간", "Keep for")) {
                    Text(L("\(storage.policy.days)일", "\(storage.policy.days) days")).monospacedDigit()
                    Spacer()
                    Stepper("", value: $storage.policy.days, in: 1...90).labelsHidden()
                }
                Divider()
                SettingsRow(title: L("채팅방당 개수", "Per chat")) {
                    Text("\(storage.policy.perChat)").monospacedDigit()
                    Spacer()
                    Stepper("", value: $storage.policy.perChat, in: 1...20).labelsHidden()
                }
                Divider()
                SettingsRow(title: L("지금 백업 크기", "Backups now")) {
                    Text(storage.report.map { ChatStorage.format(StorageModel.backups($0)) } ?? "–").monospacedDigit()
                    Spacer()
                    SettingsAction(title: storage.cleaning ? L("정리 중…", "Cleaning…") : L("지금 정리", "Clean Up Now")) { storage.cleanNow() }
                        .disabled(storage.cleaning).frame(width: 110)
                }
            }
            Text((storage.note.isEmpty ? "" : storage.note + "\n")
                 + L("AI가 연결 폴더에 쓰기 전에 만드는 Undo용 백업이에요. 기간이 지나거나 개수를 넘으면 지워져요(답변이 끝날 때, 앱 시작 때, 하루 한 번). 연결 폴더마다 가장 최근 백업 하나는 남겨요. 끝난 답변의 백업은 바뀐 파일만 남겨요.",
                     "Undo backups made before AIs write to linked folders. They go once older or more than the limit (after each answer, at launch and daily). The newest backup of each linked folder stays. Finished answers keep only the files they changed."))
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 2)
        }
        .padding(14)
        .font(.system(size: 12))
        .controlSize(.small)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { if storage.report == nil { storage.measure() } }
    }
}

// Every chat, largest first, with its full title and every kind of data it holds.
struct StorageListView: View {
    // "Backups 1.2 GB · Measured: 3:12 PM · 2 unreadable" (one string: the compiler took too long on it inline).
    static func measured(_ report: ChatStorage.Report) -> String {
        let backups: String = L("백업 ", "Backups ") + ChatStorage.format(StorageModel.backups(report)) + " · "
        let time: String = L("계산: ", "Measured: ") + DateFormatter.localizedString(from: report.date, dateStyle: .none, timeStyle: .short)
        let unreadable: String = report.total.unreadable > 0 ? L(" · 읽지 못한 항목 \(report.total.unreadable)개", " · \(report.total.unreadable) unreadable") : ""
        return backups + time + unreadable
    }
    @ObservedObject var storage = StorageModel.shared

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(storage.report.map { L("전체 ", "Total ") + ChatStorage.format($0.total.allocated) } ?? "–")
                        .font(.system(size: 13, weight: .semibold)).monospacedDigit()
                    if let report = storage.report {
                        Text(Self.measured(report))
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button(storage.measuring ? L("계산 중…", "Measuring…") : L("다시 계산", "Measure")) { storage.measure() }
                    .disabled(storage.measuring)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if let report = storage.report {
                        ForEach(report.rooms) { room in
                            row(room.title.isEmpty ? L("(제목 없음)", "(Untitled)") : room.title, room.total.allocated, detail(room)) {
                                if let first = ChatStorage.items(room.id).first(where: { FileManager.default.fileExists(atPath: $0.1.path) }) { DataFolders.reveal(first.1) }
                            }
                            Divider()
                        }
                        if !report.orphans.isEmpty {
                            row(L("지워진 채팅의 데이터", "Data of deleted chats"), report.orphans.map(\.size.allocated).reduce(0, +),
                                L("\(report.orphans.count)개 항목", "\(report.orphans.count) items")) { DataFolders.reveal(report.orphans[0].url) }
                        }
                    }
                }
            }
            Divider()
            Text(L("디스크에 실제로 쓰는 크기예요. 백업은 원본과 블록을 나눠 쓰는 복제라 지워도 이만큼 다 비지 않을 수 있어요. 연결한 프로젝트 폴더와 CLI 계정 폴더의 대화 원본은 빠져 있어요.",
                   "Space on disk. Backups are clones that share blocks with the originals, so deleting them may free less. Linked project folders and the CLIs' own transcripts are not counted."))
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14).padding(.vertical, 8)
        }
        .font(.system(size: 12))
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { if storage.report == nil { storage.measure() } }
    }

    // Every kind with data, largest first; the backups' count and the meetings counted in.
    private func detail(_ room: ChatStorage.Room) -> String {
        var parts = ChatStorage.Kind.allCases.compactMap { kind -> (Int64, String)? in
            guard let size = room.parts[kind], size.allocated > 0 else { return nil }
            let name = kind == .backups && room.backups > 0 ? kind.title + " \(room.backups)" + L("개", "") : kind.title
            return (size.allocated, name + " " + ChatStorage.format(size.allocated))
        }.sorted { $0.0 > $1.0 }.map(\.1)
        if room.meetings > 0 { parts.append(L("회의 \(room.meetings)개 포함", "incl. \(room.meetings) meetings")) }
        return parts.joined(separator: " · ")
    }

    private func row(_ title: String, _ bytes: Int64, _ detail: String, reveal: @escaping () -> Void) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).lineLimit(2).truncationMode(.tail)
                if !detail.isEmpty {
                    Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(ChatStorage.format(bytes)).monospacedDigit().foregroundStyle(.secondary)
                .fixedSize()
            Button(action: reveal) { Image(systemName: "magnifyingglass") }.buttonStyle(.borderless)
                .help(L("Finder에서 보기", "Show in Finder"))
        }
        .padding(.horizontal, 14).padding(.vertical, 7)
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
        for (item, title) in zip(items, [L("일반", "General"), L("모양", "Appearance"), L("계정", "Accounts"), L("채팅", "Chat"), "MCP"]) {
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
            t.addTabViewItem(tab(MCPSettingsTab(), symbol: "puzzlepiece.extension"))
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

// How a waiting approval reaches you outside its chat (ApprovalAlerts). The menu bar count, the banner and
// the dot in the chat list always show; these only change the macOS notification.
private struct ApprovalAlertSettingsView: View {
    @AppStorage(ApprovalAlertSettings.notifyKey, store: .app) private var notify = true
    @AppStorage(ApprovalAlertSettings.soundKey, store: .app) private var sound = false
    @AppStorage(ApprovalAlertSettings.repeatKey, store: .app) private var repeats = false

    var body: some View {
        SettingsCard(title: L("허가 요청", "Approval requests"),
                     help: L("다른 채팅이나 다른 앱을 보고 있을 때 허가 요청을 macOS 알림으로 알려요. 메뉴바 숫자와 채팅 목록의 점은 늘 보여요. 15분 안에 답하지 않으면 거절로 처리해요.",
                             "Notifies you in macOS when an approval waits while you look at another chat or app. The menu bar count and the dot in the chat list always show. Unanswered for 15 minutes counts as denied.")) {
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
    }
}

// What the chat reads of these settings (AIChat): the same properties, nothing new.
extension AppModel: ChatSettings {}
