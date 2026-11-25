import Cocoa
import Combine
import AIAccounts
import AILocalization
import AISpaces
import AIRuntime
import AIWorkspace
import AIProjects
import AIChat
import AIIntegrations

// AI Illuminati: a menu bar gauge that shows how much of each AI subscription is left
// (5-hour and weekly limits) and when each one resets, for any number of Claude and ChatGPT
// accounts. Uses each tool's own login (subscription), never API keys.
final class AppDelegate: NSObject, NSApplicationDelegate, PhoneUsage {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let panel = UsagePanel()   // opens when the pointer rests on the icon (UsagePanel.swift)
    private let work = DispatchQueue(label: "usage")
    private let model = AppModel()
    private let settings = SettingsWindow()
    private let chat = ChatWindow()
    private lazy var discussion = Discussion(model: model)
    private lazy var approvals = ApprovalAlerts(discussion: discussion) { [weak self] room in
        guard let self else { return }
        self.chat.show(discussion: self.discussion)
        if let room { self.discussion.open(room) }
    }
    private var approvalObservation: AnyCancellable?
    // The menu bar text without the waiting-approval count (see showPending).
    private var baseTitle = NSAttributedString(string: "")
    private var accounts: [Account] { model.accounts }
    private var usages: [AIUsage] = []
    private var timer: Timer?
    private var pullTimer: Timer?
    private var memoryCleanupTimer: Timer?
    private var wakeObservation: NSObjectProtocol?

    private var markTimer: Timer?
    private var runningObservation: AnyCancellable?
    private var updateIdleObservation: AnyCancellable?
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

    // Keeps animating while the panel is open (like AI Face): the timer runs in .common mode.
    private func animateMark() {
        let now = ProcessInfo.processInfo.systemUptime
        let frame = MenuMarkFrame.at(now - markStartedAt, working: markWorking,
                                     completionAge: markCompletedAt.map { now - $0 })
        guard frame != lastMarkFrame else { return }
        lastMarkFrame = frame
        item.button?.image = iconRenderer?(frame)
    }

    func applicationDidFinishLaunching(_ note: Notification) {
        // The old per-chat Spaces (<room>.work/space.json) become Spaces of their own, once (Space.swift).
        SpaceStore.migrateLegacy()
        SpaceStore.pruneDrafts()
        SpaceStore.shared.reload()
        discussion.fillSpaceLocks()   // Spaces from before their chat's Enterprise lock was saved with them
        SpaceRefiner.watchLibrary()   // the Spaces folder, as chats and editors left it (SpaceLibrary.sync)
        // TODO work (Todo.swift): running TODOs from before a quit are ready again, then the board is checked.
        let todos = TodoScheduler(discussion: discussion, store: .shared)
        TodoScheduler.shared = todos
        todos.start()
        // Old workspace backups go by age and count: now, after each answer and once a day.
        WorkspaceBackup.startAutomaticCleanUp()
        model.updater.onAvailableChange = { [weak self] in self?.updatePanel() }
        model.updater.isBusy = { [weak self] in
            guard let self else { return false }
            return self.discussion.anyRunning || self.discussion.importingMaterials
        }
        model.updater.activeWork = { [weak self] in
            guard let self else { return 0 }
            return self.discussion.runningRooms.count + (self.discussion.importingMaterials ? 1 : 0)
        }
        // Published values arrive before assignment; deliver on the main queue to read the new state.
        updateIdleObservation = Publishers.CombineLatest(discussion.$runningRooms, discussion.$importingMaterials)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.model.updater.resumeWhenIdle() }
        // When the build script opens the app, the script's folder (inside ~/Documents) comes along
        // as PWD/OLDPWD and is passed to every AI tool we start; shells they run then look at that
        // folder, and macOS asks for Documents access. None of the tools need it.
        unsetenv("PWD")
        unsetenv("OLDPWD")
        item.button?.image = illuminatiIcon()
        item.button?.imagePosition = .imageLeading
        setUpPanel()
        NSApp.mainMenu = keyboardMenu()
        model.onAccountsChange = { [weak self] in self?.refresh() }
        model.onDisplayChange = { [weak self] in
            self?.updateTitle()
            self?.updatePanel()
        }
        model.onPreviewUsageMenu = { [weak self] in self?.panel.preview() }
        updatePanel()
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.refresh() }
        memoryCleanupTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            guard let self else { return }
            ChatLinksApp.cleanProjectMemory(in: self.discussion)
        }
        // Linked projects pull main by themselves: shortly after start, on wake (back from another device) and every 10 minutes.
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in self?.autoPullProjects() }
        pullTimer = Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { [weak self] _ in self?.autoPullProjects() }
        wakeObservation = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 20) { self?.autoPullProjects() }   // the network comes back after wake
        }
        // The halo works while any chat is answering and shimmers when the last one finishes.
        runningObservation = discussion.$runningRooms.map { !$0.isEmpty }.removeDuplicates().sink { [weak self] running in
            guard let self else { return }
            if self.markWorking && !running && self.discussion.stoppingRooms.isEmpty,
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
        approvals.start()
        ChatApp.screens.approvals = { [weak self] in self?.approvals.show() }
        approvalObservation = ProjectCenter.shared.$requests.map(\.count).removeDuplicates().receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.showPending(); self?.updatePanel() }
        PhoneServer.shared.usage = self
        // The phone page's update screen; an update started there is acknowledged once that page answers again.
        PhoneServer.shared.updates = model.updater
        model.updater.phoneReady = { PhoneServer.shared.reachable($0) }
        model.updater.start()
        // The bridge's tool socket and AI Face's older socket open first, then the link to AI Face (as before I).
        ToolHub.shared.start()
        ToolHub.shared.startLegacyFaceSocket(at: FaceLink.socketPath)
        FaceLink.shared.start()
        ExternalMCP.shared.start()   // servers added in Settings → MCP
        DriveCleanup.start()   // once: what the removed Google Drive left (settings, drive.log, its Keychain login)
        // Chats from your other Macs (off until turned on in Settings → Chat).
        DeviceSync.shared.checkOnline = { PhoneAccess.shared.refresh() }   // Other Macs: which Macs Tailscale sees online
        DeviceSync.shared.start(discussion: discussion)
        // The iPhone page, when it was turned on in Manage chats → Connect iPhone (PhoneAccess.swift).
        PhoneServer.shared.start(discussion: discussion)
        // The Usage window's chat names and links, and token sums from the other Macs (off until turned on there).
        TokenStatsModel.shared.chats = { [weak self] in
            guard let self else { return [:] }
            return Dictionary(self.discussion.conversations.map { ($0.id, (title: $0.title, project: $0.workspace?.project?.root)) }) { a, _ in a }
        }
        TokenStatsWindow.openChat = { [weak self] room in
            guard let self else { return }
            self.chat.show(discussion: self.discussion)
            self.discussion.open(room)
        }
        TokenStatsModel.shared.start(model)
        model.refreshLoginItemStatus()
    }

    func applicationWillTerminate(_ notification: Notification) {
        markTimer?.invalidate()
        memoryCleanupTimer?.invalidate()
        if let motionObservation { NSWorkspace.shared.notificationCenter.removeObserver(motionObservation) }
        TodoScheduler.shared?.closeClocks()
        discussion.cancelAll()
        discussion.saveDrafts()   // unsent message boxes and their pictures wait for the next launch
        ExternalMCP.shared.stopAll()
    }

    // Reopening the app (its Dock icon, Spotlight, Finder) always brings up the chat window,
    // also while Settings or the game is open.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        chat.show(discussion: discussion)
        return true
    }

    private var localLoaded: LocalModel.Loaded?   // Gemma in memory, read when the panel opens
    private var lastRead: TimeInterval?   // when the last usage reading started

    // Resting on the icon or clicking it opens the panel; there is no menu any more.
    private func setUpPanel() {
        guard let button = item.button else { return }
        button.target = self
        button.action = #selector(iconClicked)
        panel.icon = { [weak self] in
            guard let button = self?.item.button, let window = button.window else { return nil }
            return window.convertToScreen(button.convert(button.bounds, to: nil))
        }
        panel.willShow = { [weak self] in self?.panelWillShow() }
        panel.content.title = { [weak self] in self?.label(for: $0) ?? $0.name }
        panel.content.act = { [weak self] in self?.perform($0) }
        button.addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: panel, userInfo: nil))
    }

    @objc private func iconClicked() { panel.click() }

    // Opening shows the last readings at once; they are read again only when older than 30 s (the 60 s timer
    // keeps them fresh), so resting on the icon many times a day does not ask each service each time.
    // The Ollama check waits up to 0.7 s, so it runs off the main thread and its line comes when it answers.
    private func panelWillShow() {
        updatePanel()
        if UsagePanelRules.stale(lastRead: lastRead, now: ProcessInfo.processInfo.systemUptime) { refresh() }
        guard model.hasLocal && model.localEnabled else { localLoaded = nil; updatePanel(); return }
        DispatchQueue.global(qos: .userInitiated).async {
            let loaded = LocalModel.loaded()
            DispatchQueue.main.async {
                self.localLoaded = loaded
                self.updatePanel()
            }
        }
    }

    private func perform(_ action: UsagePanelAction) {
        switch action {
        case .refresh: refresh()   // the panel stays to show the new numbers
        case .unloadLocal: unloadLocal()
        default:
            // The rest opens a window or quits: the panel goes first.
            panel.hide()
            switch action {
            case .approvals: openApprovals()
            case .chat: openChat()
            case .settings: openSettings()
            case .installUpdate: installUpdate()
            case .quit: NSApp.terminate(nil)
            case .color(let provider): AIColorWindow.show(provider)
            case .refresh, .unloadLocal: break
            }
        }
    }

    // A menu bar app shows no app menus, but ⌘C/⌘V/⌘X/⌘A/⌘Z and ⌘W only work in text fields and
    // windows when an Edit/Window menu exists. This one is never visible; it just carries the shortcuts.
    private func keyboardMenu() -> NSMenu {
        let main = NSMenu()
        @discardableResult
        func submenu(_ title: String, _ items: [(String, Selector, String, NSEvent.ModifierFlags)]) -> NSMenu {
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
            return sub
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
        let window = submenu(L("윈도우", "Window"), [(L("닫기", "Close"), #selector(NSWindow.performClose(_:)), "w", .command),
                        (L("최소화", "Minimize"), #selector(NSWindow.performMiniaturize(_:)), "m", .command),
                        (L("확대/축소", "Zoom"), #selector(NSWindow.performZoom(_:)), "", [])])
        window.addItem(.separator())
        window.addItem(NSMenuItem(title: L("모두 앞으로 가져오기", "Bring All to Front"),
                                  action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: ""))
        // Registering it as the Window menu lets macOS add Fill, Center, Move & Resize (left/right halves,
        // quarters) with their shortcuts, plus the open-window list, the same as in other apps.
        NSApp.windowsMenu = window
        return main
    }

    private func autoPullProjects() {
        guard model.autoPullMain else { return }
        let projects = SidebarProjects.group(discussion.listedConversations.filter(\.hasContent), todo: TodoStore.shared.snapshot, pinned: []).projects
        GitBranchStore.shared.autoPull(projects.flatMap(\.bindings))
    }

    func phoneUsageSnapshot() -> PhoneUsageSnapshot {
        let colors = Dictionary(uniqueKeysWithValues: Set(accounts.map(\.provider)).map { ($0, PhoneUsageSnapshot.webColors($0)) })
        return PhoneUsageSnapshot(device: DeviceSync.shared.deviceName, accounts: accounts, readings: model.latestUsage, colors: colors)
    }

    func phoneRefreshUsage() { refresh() }

    @objc private func refresh() {
        lastRead = ProcessInfo.processInfo.systemUptime
        let list = accounts
        work.async {
            var fresh = list.map { account -> AIUsage in
                switch account.provider {
                case .claude: return ClaudeUsage.read(account)
                case .codex: return CodexUsage.read(account)
                case .gemini: return GeminiUsage.read(account)
                case .ollama: return LocalUsage.read(account)
                }
            }
            Self.markSameAccounts(&fresh)
            DispatchQueue.main.async {
                self.usages = fresh
                self.model.latestUsage = Dictionary(fresh.compactMap { u in u.account.map { ($0.id, u) } },
                                                    uniquingKeysWith: { a, _ in a })
                self.updateTitle()
                self.updatePanel()
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

    // Bars show the accounts checked in Settings → Appearance, in Settings order, including unknown readings.
    // Percentage text keeps its existing per-provider summary.
    private func updateTitle() {
        let groups: [(String, Account.Provider)] = [("Cl", .claude), ("Cx", .codex), ("Gm", .gemini)]
        // Only the accounts checked in Settings → Appearance.
        let listed = model.menuBarAccounts
        let shown = Set(listed.map(\.id))
        let visible = usages.filter { $0.account.map { shown.contains($0.id) } == true }
        let present = groups.filter { g in visible.contains { $0.account?.provider == g.1 } }
        // One limit everywhere in the menu bar: the 5-hour or the weekly one, as chosen in Settings.
        let window = model.menuBarWindow
        let best = present.map { g in visible.filter { $0.account?.provider == g.1 }.compactMap { window.left($0) }.max() }
        let levels = listed.map { account in usages.first { $0.account?.id == account.id }.flatMap { window.left($0) } }
        // Every account hidden: the mark alone, so the menu bar item never shrinks to nothing.
        let style = listed.isEmpty && model.menuBarStyle != .mark ? .mark : model.menuBarStyle
        let colored = model.menuBarColored
        func tint(_ provider: Account.Provider) -> NSColor {
            switch provider {
            case .claude: return .systemOrange
            case .codex: return .systemGreen
            case .gemini: return .systemBlue
            case .ollama: return .systemPurple
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
            baseTitle = NSAttributedString(string: "")
            showPending()
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
        baseTitle = title
        showPending()
    }

    // An orange count beside the mark while approvals wait; it stays until each one is decided.
    private func showPending() {
        let count = ProjectCenter.shared.requests.count
        guard count > 0 else { item.button?.attributedTitle = baseTitle; return }
        let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        let title = NSMutableAttributedString(string: " ●\(count)", attributes: [.font: font, .foregroundColor: NSColor.systemOrange])
        title.append(baseTitle)
        item.button?.attributedTitle = title
    }

    private func updatePanel() {
        let content = panel.content
        content.pending = ProjectCenter.shared.requests.count
        content.checking = usages.isEmpty && !accounts.isEmpty
        // Current order and names from the list (readings may be a little older).
        content.shown = accounts.compactMap { account in
            usages.first { $0.account?.id == account.id }.map { usage -> AIUsage in
                var copy = usage
                copy.account = account
                // The local model has no limit: its full bars stay in the menu bar only; here it shows "—" like a missing limit.
                if account.provider == .ollama, copy.fiveHour != nil || copy.weekly != nil {
                    copy.fiveHour = nil
                    copy.weekly = nil
                    copy.extras.insert(L("한도 없음", "No limit"), at: 0)
                }
                return copy
            }
        }
        content.style = model.usageMenuStyle
        // The Ollama model on this Mac, only while it is in memory: how much and until when, with Unload now.
        // (Its on/off switch is also in Settings by AI.)
        content.local = model.hasLocal ? localLoaded.map { loaded in
            let size = String(format: "%.1f", Double(loaded.bytes) / 1_073_741_824)
            let minutes = loaded.until.map { max(0, Int(($0.timeIntervalSinceNow / 60).rounded(.up))) }
            return loaded.title + L(" · 메모리 \(size)GB 사용 중", " · using \(size) GB of memory") + (minutes.map { L(" · \($0)분 뒤 내려감", " · unloads in \($0) min") } ?? "")
        } : nil
        // Also seen with Settings closed; read again each time the panel opens.
        content.update = model.updater.progress.map { L("업데이트 ", "Update ") + $0.summary(at: Date()) }
        content.install = model.updater.available.flatMap { next in
            model.updater.progress?.failed ?? true ? L("새 버전 설치 (\(next.prefix(7)))", "Install New Version (\(next.prefix(7)))") : nil
        }
    }

    private func label(for usage: AIUsage) -> String {
        let name = usage.account?.name ?? usage.name
        guard let kind = usage.account?.provider.title else { return name }
        return name.hasPrefix(kind) ? name : "\(kind) · \(name)"
    }

    // MARK: Actions


    @objc private func openSettings() { settings.show(model: model) }
    private func unloadLocal() {
        localLoaded = nil
        updatePanel()
        DispatchQueue.global(qos: .utility).async { LocalModel.unload() }
    }
    private func installUpdate() { model.updater.install() }
    @objc private func openChat() { chat.show(discussion: discussion) }
    private func openApprovals() { approvals.show() }

}

// Only the app itself uses the real accounts and settings; tests and previews never call this.
AccountStore.useRealHome()
ChatLinksApp.connect()
Discussion.draftsFile = URL(fileURLWithPath: AccountStore.supportDir + "/drafts.json")   // the app's own; tests keep boxes in memory
Discussion.unreadFile = URL(fileURLWithPath: AccountStore.supportDir + "/unread.json")   // "Needs review", this Mac only
ChatScreensApp.connect()
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
