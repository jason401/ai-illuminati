import Cocoa
import CryptoKit
import IOKit
import AIAccounts

// Chats from your other Macs, read only, through a folder both Macs see (iCloud Drive by default):
//   <folder>/devices/<deviceID>/device.json         this Mac's name, app version, last write
//   <folder>/devices/<deviceID>/chats/<chatID>.json  one copy per shared chat (SyncSnapshot)
// Each Mac writes only its own folder and only reads the others, so two Macs never write the same file and
// nothing is merged. To go on with a chat from another Mac, "Continue on this Mac" makes a new chat here
// from the copy (Discussion.continueFromDevice): a new session that starts from the copied turns and state.
// Copies leave out this Mac's paths (folders, backups, results, sessions) and pictures.

// Where a chat continued on this Mac came from.
struct SyncOrigin: Codable, Equatable {
    var device: String        // the other Mac's device ID
    var deviceName: String
    var chat: UUID            // the chat's ID on that Mac
    var lastTurn: UUID?       // its newest turn when it was copied
    var contentAt: Date       // when that chat last changed
    var importedAt: Date
}

// One chat as another Mac sees it. Unknown newer versions are listed as unreadable, never guessed at.
struct SyncSnapshot: Codable, Equatable {
    static let version = 1
    var schemaVersion = SyncSnapshot.version
    var id: UUID
    var title: String
    var createdAt: Date
    var updatedAt: Date
    var school: Bool
    var mode: Int
    var summary: String
    var state: String?        // the chat state (.illuminati/state.md), the context a new session starts from
    var stateTurn: UUID?      // the newest turn that state covers; later turns go word for word
    var turns: [ChatTurn]
    var pictures: Int         // pictures left out of the copy
    var origin: SyncOrigin?   // set when this chat was itself continued from another Mac
    var enterpriseLock: EnterpriseLock?   // an Enterprise chat (`school` is true then too, for older apps)
}

struct SyncDeviceInfo: Codable {
    var schemaVersion = SyncSnapshot.version
    var id: String
    var name: String
    var app: String
    var writtenAt: Date
}

// A chat in another Mac's folder, listed without reading all of it.
struct RemoteChat: Identifiable, Equatable {
    enum Status: Equatable { case ready, downloading, unreadable, newerVersion }
    var device: String
    var deviceName: String
    var chat: UUID
    var title: String
    var updatedAt: Date?
    var school: Bool
    var status: Status
    var file: URL
    var id: String { device + "/" + chat.uuidString }
}

struct RemoteDevice: Identifiable, Equatable {
    var id: String
    var name: String
    var writtenAt: Date?
    var chats: [RemoteChat]
}

struct DeviceSyncSettings: Codable, Equatable {
    var enabled = false
    var folder: String?          // nil: iCloud Drive/AI Illuminati Sync
    var deviceName: String?      // nil: this Mac's name
    var shareAll = false         // false: only chats marked "Show on other Macs"
    var includeSchool = false    // Enterprise (school/work) chats stay off a personal iCloud unless turned on
}

final class DeviceSync: ObservableObject {
    static let shared = DeviceSync(deviceID: DeviceSync.hardwareID(), persist: true)

    @Published var settings: DeviceSyncSettings {
        didSet {
            guard settings != oldValue else { return }
            if persist, let data = try? JSONEncoder().encode(settings) { UserDefaults.app.set(data, forKey: Self.settingsKey) }
            if settings.enabled { reconcile(); scan() } else { devices = []; lastChecked = nil }
        }
    }
    @Published private(set) var devices: [RemoteDevice] = []
    @Published private(set) var lastChecked: Date?
    @Published private(set) var problem: String?

    let deviceID: String
    private let persist: Bool
    // Set by the app: the chats to share (the saved list) and whether a chat is answering right now.
    var conversations: () -> [Conversation] = { [] }
    var isBusy: (UUID) -> Bool = { _ in false }
    // Whether this Mac still has the chat's own file (one the list could not read, so not deleted).
    var hasLocalFile: (String) -> Bool = { FileManager.default.fileExists(atPath: ChatStore.dir + "/" + $0) }

    private var pending: [UUID: Conversation] = [:]
    private var flushScheduled = false
    private var timer: Timer?
    private var activation: NSObjectProtocol?
    private var scanning = false
    private var headers: [String: (Date, RemoteChat)] = [:]   // file path → (modification date, listing)
    private let io = DispatchQueue(label: "device-sync")
    static let settingsKey = "deviceSync"
    static let delay: TimeInterval = 3        // several saves in a row become one write
    static let interval: TimeInterval = 180   // look at the other Macs this often while the app runs

    init(deviceID: String, persist: Bool, settings: DeviceSyncSettings? = nil) {
        self.deviceID = deviceID
        self.persist = persist
        if let settings { self.settings = settings }
        else if persist, let data = UserDefaults.app.data(forKey: Self.settingsKey),
                let saved = try? JSONDecoder().decode(DeviceSyncSettings.self, from: data) { self.settings = saved }
        else { self.settings = DeviceSyncSettings() }
    }

    // MARK: Places

    static var iCloudDrive: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs")
    }
    static var defaultFolder: URL { iCloudDrive.appendingPathComponent("AI Illuminati Sync") }
    var folder: URL { settings.folder.map { URL(fileURLWithPath: $0) } ?? Self.defaultFolder }
    var devicesFolder: URL { folder.appendingPathComponent("devices") }
    var myFolder: URL { devicesFolder.appendingPathComponent(deviceID) }
    var myChats: URL { myFolder.appendingPathComponent("chats") }
    var deviceName: String {
        let name = settings.deviceName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return name.isEmpty ? (Host.current().localizedName ?? "Mac") : String(name.prefix(60))
    }
    // The folder can be used: iCloud Drive is on (or a folder was chosen that exists).
    var folderAvailable: Bool {
        settings.folder.map { FileManager.default.fileExists(atPath: $0) } ?? FileManager.default.fileExists(atPath: Self.iCloudDrive.path)
    }

    // This Mac's ID: from the hardware UUID, so a Mac restored or cloned from another gets its own folder
    // (an ID kept in settings would be copied with them). Hashed, so the hardware UUID itself is not shared.
    static func hardwareID() -> String {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        defer { if service != 0 { IOObjectRelease(service) } }
        let raw = (service != 0 ? IORegistryEntryCreateCFProperty(service, kIOPlatformUUIDKey as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? String : nil) ?? (Host.current().localizedName ?? "mac")
        let digest = SHA256.hash(data: Data(("ai-illuminati-device:" + raw).utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Starting (the app only; tests call the methods directly)

    func start(discussion: Discussion) {
        conversations = { [weak discussion] in discussion?.conversations.filter { $0.hasContent && $0.meetingOf == nil } ?? [] }
        isBusy = { [weak discussion] id in discussion?.runningRooms.contains(id) ?? false }
        activation = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.scan()
        }
        let ticker = Timer(timeInterval: Self.interval, repeats: true) { [weak self] _ in self?.scan() }
        ticker.tolerance = 30
        RunLoop.main.add(ticker, forMode: .common)
        timer = ticker
        if settings.enabled { reconcile(); scan() }
    }

    // MARK: What is shared

    // An Enterprise chat: one the user locked (Enterprise.swift). Older chats and older copies are open chats.
    static func isSchool(_ conversation: Conversation) -> Bool { conversation.isEnterprise }

    // A chat was just locked: with Enterprise chats not shared, its copy is taken down now.
    func chatLocked(_ conversation: Conversation) {
        guard settings.enabled else { return }
        if shares(conversation) { noteSaved(conversation) } else { noteDeleted(conversation.id) }
    }

    func shares(_ conversation: Conversation) -> Bool {
        // A meeting's hidden chat stays on this Mac (Meeting.swift).
        guard settings.enabled, conversation.hasContent, !conversation.turns.isEmpty, conversation.meetingOf == nil else { return false }
        if !settings.shareAll && conversation.shareToDevices != true { return false }
        if !settings.includeSchool && Self.isSchool(conversation) { return false }
        return true
    }

    // The copy of a chat: finished turns only (the one being answered stays out until it is done), without
    // this Mac's paths, pictures or work in progress.
    static func snapshot(_ conversation: Conversation, school: Bool, busy: Bool, state: String?, stateTurn: UUID?) -> SyncSnapshot {
        var turns = conversation.turns
        if busy, !turns.isEmpty { turns.removeLast() }
        var pictures = 0
        turns = turns.map { turn in
            var t = turn
            pictures += (t.images?.count ?? 0) + (t.finalImages?.count ?? 0)
                + (t.entries + (t.moreAnswers ?? [])).reduce(0) { $0 + ($1.images?.count ?? 0) }
            t.images = nil; t.finalImages = nil
            t.entries = t.entries.map { var e = $0; e.images = nil; return e }
            t.moreAnswers = t.moreAnswers?.map { var e = $0; e.images = nil; return e }
            t.backupPath = nil; t.workspaceChanges = nil; t.projectLog = nil; t.artifact = nil
            t.tasks = t.tasks?.map { var task = $0; task.output = nil; task.expectedFiles = nil; return task }
            t.partial = nil; t.partialBy = nil; t.partials = nil; t.activity = nil; t.status = ""
            return t
        }
        let state = state?.trimmingCharacters(in: .whitespacesAndNewlines)
        return SyncSnapshot(id: conversation.id, title: conversation.title, createdAt: conversation.createdAt,
                            updatedAt: conversation.updatedAt, school: school, mode: mode(conversation.configuration),
                            summary: conversation.summary, state: state?.isEmpty == false ? state : nil,
                            stateTurn: state?.isEmpty == false && turns.contains { $0.id == stateTurn } ? stateTurn : nil,
                            turns: turns, pictures: pictures, origin: conversation.origin, enterpriseLock: conversation.enterpriseLock)
    }

    // The mode the chat runs in (an unversioned saved mode is an old number: Discussion.configuration).
    static func mode(_ config: ChatConfiguration?) -> Int {
        guard let config else { return 0 }
        return !Discussion.modernModes || config.modeVersion == 2 ? config.mode : 1
    }

    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    // MARK: Writing this Mac's folder
    // What to write is worked out on the main thread (the chat, its side, whether it is answering); reading
    // the state, encoding and the file work happen on the io queue, in order, so long chats never hold up
    // the window.

    // A chat was saved (ChatStore.save) or deleted: write or remove its copy a few seconds later.
    func noteSaved(_ conversation: Conversation) {
        guard settings.enabled else { return }
        onMain { self.pending[conversation.id] = conversation; self.scheduleFlush() }
    }
    func noteDeleted(_ id: UUID) {
        guard settings.enabled else { return }
        onMain {
            self.pending[id] = nil
            let file = self.myChats.appendingPathComponent(id.uuidString + ".json")
            self.io.async { Self.removeFile(file) }
        }
    }
    // A chat finished answering: its last turn can go out now.
    func noteFinished(_ conversation: Conversation?) {
        guard let conversation, conversation.hasContent else { return }
        noteSaved(conversation)
    }

    private func onMain(_ work: @escaping () -> Void) {
        if Thread.isMainThread { work() } else { DispatchQueue.main.async(execute: work) }
    }

    private func scheduleFlush() {
        guard !flushScheduled else { return }
        flushScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.delay) { [weak self] in
            guard let self else { return }
            self.flushScheduled = false
            let copies = self.pending.values.map { self.copy($0) }
            self.pending = [:]
            let folder = self.myChats, info = self.deviceInfo()
            self.io.async {
                let outcomes = copies.map { Self.write($0, to: folder) }
                info?()
                self.report(outcomes)
            }
        }
    }

    // One chat's copy as worked out on the main thread.
    struct Copy {
        var conversation: Conversation
        var shared: Bool
        var school: Bool
        var busy: Bool
    }
    enum Outcome: Equatable { case removed, nothing, saved, failed(String) }

    func copy(_ conversation: Conversation) -> Copy {
        Copy(conversation: conversation, shared: shares(conversation),
             school: Self.isSchool(conversation), busy: isBusy(conversation.id))
    }

    // Writes a shared chat's copy (only when it changed), else removes it. Safe off the main thread.
    // With no finished turn yet (the first question still being answered), any copy is left as it is.
    static func write(_ copy: Copy, to folder: URL) -> Outcome {
        let file = folder.appendingPathComponent(copy.conversation.id.uuidString + ".json")
        guard copy.shared else { removeFile(file); return .removed }
        let id = copy.conversation.id
        let snap = snapshot(copy.conversation, school: copy.school, busy: copy.busy,
                            state: Discussion.loadState(id), stateTurn: Discussion.loadStateTurn(id))
        guard !snap.turns.isEmpty, let data = try? encoder().encode(snap) else { return .nothing }
        if (try? Data(contentsOf: file)) == data { return .saved }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try data.write(to: file, options: .atomic)
            return .saved
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    private func report(_ outcomes: [Outcome]) {
        let failure = outcomes.lazy.compactMap { if case .failed(let why) = $0 { return why } else { return nil } }.first
        let saved = outcomes.contains(.saved)
        guard failure != nil || saved else { return }
        DispatchQueue.main.async {
            self.problem = failure.map { L("동기화 폴더에 쓰지 못했어요: ", "Could not write to the sync folder: ") + $0 }
        }
    }

    // Writes or removes one chat's copy right away (tests). True when the chat's copy is in place.
    @discardableResult
    func publish(_ conversation: Conversation) -> Bool {
        Self.write(copy(conversation), to: myChats) == .saved
    }

    static func removeFile(_ file: URL) {
        if FileManager.default.fileExists(atPath: file.path) { try? FileManager.default.removeItem(at: file) }
    }

    // Writes device.json when run (on the io queue); nil when sharing is off.
    private func deviceInfo() -> (() -> Void)? {
        guard settings.enabled else { return nil }
        let info = SyncDeviceInfo(id: deviceID, name: deviceName,
                                  app: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "", writtenAt: Date())
        let folder = myFolder
        return {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try? Self.encoder().encode(info).write(to: folder.appendingPathComponent("device.json"), options: .atomic)
        }
    }

    // Brings this Mac's folder in line with the settings: copies of shared chats written, every other copy
    // (unshared, deleted while the app was closed, Enterprise after "include" was turned off) removed.
    // A shared chat's copy stays even when it could not be written just now: a passing write error must not
    // look to the other Macs as if the chat was taken away.
    func reconcile() {
        guard settings.enabled else { return }
        let copies = conversations().map { copy($0) }
        let folder = myChats, info = deviceInfo()
        io.async {
            let outcomes = copies.map { Self.write($0, to: folder) }
            let kept = Set(copies.filter(\.shared).map { $0.conversation.id.uuidString + ".json" })
            let listed = Set(copies.map { $0.conversation.id.uuidString + ".json" })
            // A chat missing from the list whose file is still here could not be read: its copy may be the only good one.
            for name in (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
            where !kept.contains(name) && (listed.contains(name) || !self.hasLocalFile(name)) {
                try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
            }
            info?()
            self.report(outcomes)
        }
    }

    // Removes every copy this Mac wrote (Settings → "Remove this Mac's copies"), after any write still queued.
    func removeMine() {
        let folder = myFolder
        io.async { try? FileManager.default.removeItem(at: folder) }
    }

    // Waits for the queued file work (tests).
    func waitForWrites() { io.sync {} }

    // MARK: Reading the other Macs

    func scan() {
        guard settings.enabled, !scanning else { return }
        scanning = true
        io.async {
            let found = self.scanNow()
            DispatchQueue.main.async {
                self.scanning = false
                guard self.settings.enabled else { return }
                if found != self.devices { self.devices = found }
                self.lastChecked = Date()
            }
        }
    }

    // Lists every other Mac's chats. A file iCloud has not brought down yet is asked for and shown as
    // downloading; a half-written or broken one is skipped this time and read again next time.
    func scanNow() -> [RemoteDevice] {
        let fm = FileManager.default
        var result: [RemoteDevice] = []
        let folders = (try? fm.contentsOfDirectory(at: devicesFolder, includingPropertiesForKeys: nil)) ?? []
        for deviceFolder in folders where deviceFolder.lastPathComponent != deviceID && !deviceFolder.lastPathComponent.hasPrefix(".") {
            let id = deviceFolder.lastPathComponent
            let infoFile = deviceFolder.appendingPathComponent("device.json")
            Self.download(infoFile)
            let info = (try? Data(contentsOf: infoFile)).flatMap { try? Self.decoder().decode(SyncDeviceInfo.self, from: $0) }
            let name = info?.name ?? L("다른 Mac", "Other Mac")
            let chatsFolder = deviceFolder.appendingPathComponent("chats")
            var chats: [RemoteChat] = []
            for entry in (try? fm.contentsOfDirectory(atPath: chatsFolder.path)) ?? [] {
                // Not downloaded yet: iCloud keeps a ".<name>.icloud" stand-in.
                if entry.hasPrefix("."), entry.hasSuffix(".json.icloud") {
                    let real = String(entry.dropFirst().dropLast(".icloud".count))
                    guard let chat = UUID(uuidString: String(real.dropLast(".json".count))) else { continue }
                    let file = chatsFolder.appendingPathComponent(real)
                    Self.download(file)
                    chats.append(RemoteChat(device: id, deviceName: name, chat: chat, title: L("받는 중…", "Downloading…"), updatedAt: nil,
                                            school: false, status: .downloading, file: file))
                    continue
                }
                guard entry.hasSuffix(".json"), !entry.hasPrefix("."), let chat = UUID(uuidString: String(entry.dropLast(5))) else { continue }
                let file = chatsFolder.appendingPathComponent(entry)
                if let listed = header(file, device: id, deviceName: name, chat: chat) { chats.append(listed) }
            }
            if chats.isEmpty && info == nil { continue }
            chats.sort { ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast) }
            result.append(RemoteDevice(id: id, name: name, writtenAt: info?.writtenAt, chats: chats))
        }
        return result.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private struct Header: Decodable {
        var schemaVersion: Int
        var title: String?
        var updatedAt: Date?
        var school: Bool?
    }

    private func header(_ file: URL, device: String, deviceName: String, chat: UUID) -> RemoteChat? {
        let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
        if let (date, listed) = headers[file.path], date == modified {
            var copy = listed; copy.deviceName = deviceName; return copy
        }
        guard let data = try? Data(contentsOf: file) else { return nil }
        var listed = RemoteChat(device: device, deviceName: deviceName, chat: chat, title: L("읽을 수 없는 대화", "Unreadable chat"),
                                updatedAt: modified, school: false, status: .unreadable, file: file)
        if let head = try? Self.decoder().decode(Header.self, from: data) {
            if head.schemaVersion > SyncSnapshot.version {
                listed.title = head.title ?? listed.title
                listed.status = .newerVersion
            } else if (try? Self.decoder().decode(SyncSnapshot.self, from: data)) != nil {
                listed.title = head.title ?? ""
                listed.updatedAt = head.updatedAt
                listed.school = head.school ?? false
                listed.status = .ready
            } else { return nil }   // still being written or synced: try again next time
        } else { return nil }
        headers[file.path] = (modified, listed)
        return listed
    }

    static func download(_ file: URL) {
        try? FileManager.default.startDownloadingUbiquitousItem(at: file)
    }

    // The whole copy, read when it is opened.
    static func load(_ chat: RemoteChat) -> SyncSnapshot? {
        guard chat.status == .ready, let data = try? Data(contentsOf: chat.file),
              let snap = try? decoder().decode(SyncSnapshot.self, from: data), snap.schemaVersion <= SyncSnapshot.version else { return nil }
        return snap
    }
}

// A chat from another Mac shown read only in the chat window.
struct RemoteViewing: Equatable {
    var chat: RemoteChat
    var snapshot: SyncSnapshot?
    var loading = false
}

extension Discussion {
    static func stateTurnFile(_ room: UUID) -> URL { stateFolder(room).appendingPathComponent("state-turn") }
    static func loadStateTurn(_ room: UUID) -> UUID? {
        (try? String(contentsOf: stateTurnFile(room), encoding: .utf8)).flatMap { UUID(uuidString: $0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }
    // Saves the chat state and which turn it covers (so a new session knows which later turns to read in full).
    func saveState(_ state: String, room: UUID, index: Int) {
        Self.saveText(state, to: Self.stateFile(room))
        // Read on the main thread (the host's list), where the turn's ID is current.
        change(room) { chat in
            if chat.turns.indices.contains(index) { Self.saveText(chat.turns[index].id.uuidString, to: Self.stateTurnFile(room)) }
        }
    }

    // How many turns at the end a new session reads word for word: the usual few, or every turn after the
    // one the chat state last covered (at most 12).
    static func recentCount(_ history: [ChatTurn], stateTurn: UUID?) -> Int {
        guard let stateTurn, let i = history.firstIndex(where: { $0.id == stateTurn }) else { return recentTurns }
        return min(12, max(recentTurns, history.count - 1 - i))
    }

    // What a chat continued from another Mac tells the AI before its copied turns.
    static func originNote(_ origin: SyncOrigin?) -> String? {
        guard let origin else { return nil }
        return """
            [Continued from another Mac]
            The earlier turns were copied from "\(origin.deviceName)". Its folders, files, sessions and approvals are not on this Mac.
            Treat earlier requests as history: do not carry them out again unless the user asks now.
            """
    }

    func openRemote(_ chat: RemoteChat) {
        // Read and decoded off the main thread, so a long chat does not hold up the window.
        let shown = viewingRemote?.chat.id == chat.id ? viewingRemote?.snapshot : nil   // a newer copy: keep the old one up meanwhile
        viewingSpace = nil
        viewingRemote = RemoteViewing(chat: chat, snapshot: shown, loading: true)
        DispatchQueue.global(qos: .userInitiated).async {
            let snapshot = DeviceSync.load(chat)
            DispatchQueue.main.async {
                guard self.viewingRemote?.chat.id == chat.id else { return }
                self.viewingRemote = RemoteViewing(chat: chat, snapshot: snapshot)
            }
        }
    }

    // Chats already continued on this Mac from this copy, newest first.
    func continued(from chat: RemoteChat) -> [Conversation] {
        conversations.filter { $0.origin?.device == chat.device && $0.origin?.chat == chat.chat }.sorted { $0.updatedAt > $1.updatedAt }
    }

    // A new chat on this Mac from another Mac's copy: its turns, summary, chat state and Enterprise/personal
    // side, with no folders, sessions or project. The copy itself is never changed.
    @discardableResult
    func continueFromDevice(_ snap: SyncSnapshot, device: String, deviceName: String) -> UUID {
        discardPendingImages()   // their files live with the chat being left, which may be removed below
        var chat = Conversation()
        chat.title = snap.title
        chat.turns = snap.turns
        chat.summary = snap.summary
        // Versioned like a new chat here, or the mode would be read as an old number (plain chat became a discussion).
        let config = ChatConfiguration(mode: Self.availableModes.contains(snap.mode) ? snap.mode : Self.availableModes[0],
                                       modeVersion: Self.modernModes ? 2 : nil)
        chat.configuration = config
        chat.enterpriseLock = snap.enterpriseLock   // an Enterprise chat stays one here (older copies have no lock: open)
        chat.origin = SyncOrigin(device: device, deviceName: deviceName, chat: snap.id, lastTurn: snap.turns.last?.id,
                                 contentAt: snap.updatedAt, importedAt: Date())
        if let state = snap.state {
            Self.saveText(state, to: Self.stateFile(chat.id))
            if let turn = snap.stateTurn { Self.saveText(turn.uuidString, to: Self.stateTurnFile(chat.id)) }
        }
        ChatStore.save(chat)
        dropBlanks(except: nil)
        conversations.insert(chat, at: 0)
        viewingRemote = nil
        currentID = chat.id
        sessionNote = L("\(deviceName)에서 가져온 대화예요. 다음 질문은 새 세션에서 시작해요.",
                        "Copied from \(deviceName). The next message starts a new session.")
        return chat.id
    }

    // "Continue on this Mac": asks first when this copy was already continued here.
    func continueRemote(_ viewing: RemoteViewing) {
        guard let snap = viewing.snapshot else { return }
        if let earlier = continued(from: viewing.chat).first {
            let alert = NSAlert()
            alert.messageText = L("이미 이어간 대화가 있어요", "You already continued this chat")
            alert.informativeText = L("‘\(earlier.title)’에서 이어가고 있어요. 그 대화를 열까요, 아니면 지금 사본으로 새로 이어갈까요? 두 대화는 합쳐지지 않아요.",
                                      "You are continuing it in “\(earlier.title)”. Open that chat, or continue again from this copy? The two chats are not merged.")
            alert.addButton(withTitle: L("이어간 대화 열기", "Open that chat"))
            alert.addButton(withTitle: L("새로 이어가기", "Continue again"))
            alert.addButton(withTitle: L("취소", "Cancel"))
            switch alert.runModal() {
            case .alertFirstButtonReturn: viewingRemote = nil; open(earlier.id); return
            case .alertSecondButtonReturn: break
            default: return
            }
        }
        continueFromDevice(snap, device: viewing.chat.device, deviceName: viewing.chat.deviceName)
    }

    func toggleShareToDevices(_ id: UUID) {
        guard let i = conversations.firstIndex(where: { $0.id == id }) else { return }
        conversations[i].shareToDevices = conversations[i].shareToDevices == true ? nil : true
        ChatStore.save(conversations[i])
    }
}

extension DeviceSync {
    // "3 hours ago", in the app's language.
    static func ago(_ date: Date, now: Date = Date()) -> String {
        if now.timeIntervalSince(date) < 60 { return L("방금", "just now") }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: AppLanguage.current == .korean ? "ko_KR" : "en_US")
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: now)
    }
}
