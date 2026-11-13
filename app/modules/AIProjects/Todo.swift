import Foundation
import Combine
import UniformTypeIdentifiers
import AIAccounts
import AILocalization
import AIWorkspace

// TODO work (TODO_PLAN.md): the user writes TODOs on the board, presses Start, and the app gives the next one
// that may start to a Claude/Codex account in a chat of its own (the project work path, with a review by another
// account). The AI reports with task_done (waits for the user's check) or task_ask (the user decides); the user
// accepts the result. Two kinds of order: one TODO per project folder at a time (automatic), and the order the
// user sets (a list in order, or "after" links to other TODOs).

public struct TodoNote: Codable, Equatable {
    public enum Kind: String, Codable { case answer, feedback, retry, system }
    public var at = Date()
    public var kind: Kind
    public var text: String
}

// What task_ask left for the user: questions with choices, or why the work cannot go on.
public struct TodoQuestion: Codable, Equatable {
    public struct Item: Codable, Equatable { public var text: String; public var options: [String] = []; public var recommended: String? }
    public var blocked: Bool
    public var reason: String
    public var items: [Item] = []
}

// What task_done / task_ask said during an attempt. It becomes the TODO's state only when the whole attempt (the
// work, the review and the fixes after it) has finished: an error after it still counts as an error.
public struct TodoReport: Codable, Equatable {
    public var summary: String?
    public var assumptions: [String] = []
    public var files: [String] = []
    public var question: TodoQuestion?   // task_ask: the user decides, whatever task_done said
    public init(summary: String? = nil, assumptions: [String] = [], files: [String] = [], question: TodoQuestion? = nil) {
        self.summary = summary; self.assumptions = assumptions; self.files = files; self.question = question
    }
}

// A photo or file the user attached to a TODO's details. The copy lives in the store's todo-files/<TODO id>/ folder
// (TodoStore.file); the AI gets it in its chat's own folder when the TODO starts (TodoScheduler.deliver).
public struct TodoAttachment: Codable, Identifiable, Equatable {
    public var id = UUID()
    public var name: String
    public var image: Bool
}

public struct TodoItem: Codable, Identifiable, Equatable {
    // draft (not taken yet) → ready → running → review (the AI is done; waits for the user's check) → done.
    // needsYou: a question, or the work cannot go on; the user's answer makes it ready again, Stop cancels it.
    public enum State: String, Codable, CaseIterable { case draft, ready, running, review, done, needsYou, cancelled }
    public var id = UUID()
    public var listID: UUID
    public var title: String
    public var detail = ""
    public var attachments: [TodoAttachment] = []
    public var askFirst = false            // ask before starting; otherwise assume, go on and list the assumptions
    public var state: State = .draft
    public var after: [UUID] = []          // TODOs that must be finished first (any list)
    public var room: UUID?                 // the TODO's own chat, made when it first starts
    public var originRoom: UUID?           // the chat it was written from: its report card shows there too
    public var notes: [TodoNote] = []      // the user's answers and change requests, retries; sent with the next attempt
    public var question: TodoQuestion?
    public var attempts = 0                // attempts that ended in an error since the user last answered
    public var lastError: String?
    public var result: String?
    public var assumptions: [String] = []
    public var files: [String] = []
    public var report: TodoReport?         // the running attempt's report, not final yet
    public var workers: [String]?          // the running attempt's allowed accounts (the list's pick when it started); nil: any
    public var interrupted = false         // the app quit while it ran: the next attempt checks git status first
    public var unreported = false          // review or needsYou not yet announced (macOS notification)
    public var createdAt = Date()
    public var updatedAt = Date()
    // Time kept by TodoStore.update on every state change (none for TODOs started before it was added).
    public var workSeconds: Double = 0     // in .running, all attempts (work and review)
    public var waitSeconds: Double = 0     // in .review or .needsYou: waiting for the user
    public var stateSince: Date?           // the current state began; nil: not timed (old TODO, or settled when the app quit)
    public var startedAt: Date?            // first went running
    public var finishedAt: Date?           // became done or cancelled

    public init(listID: UUID, title: String, detail: String = "", askFirst: Bool = false, after: [UUID] = [], originRoom: UUID? = nil) {
        self.listID = listID; self.title = title; self.detail = detail; self.askFirst = askFirst; self.after = after; self.originRoom = originRoom
    }

    // Older or newer files: unknown fields are ignored, missing ones get their defaults. A field that is there but
    // cannot be read fails the whole file, which TodoStore then keeps as it is (no default silently saved over it).
    private enum Keys: String, CodingKey {
        case id, listID, title, detail, attachments, askFirst, state, after, room, originRoom, notes, question, attempts, lastError, result, assumptions, files, report, workers, interrupted, unreported, createdAt, updatedAt,
             workSeconds, waitSeconds, stateSince, startedAt, finishedAt
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        id = try c.decode(UUID.self, forKey: .id)
        listID = try c.decode(UUID.self, forKey: .listID)
        title = (try c.decodeIfThere(String.self, forKey: .title)) ?? ""
        detail = (try c.decodeIfThere(String.self, forKey: .detail)) ?? ""
        attachments = (try c.decodeIfThere([TodoAttachment].self, forKey: .attachments)) ?? []
        askFirst = (try c.decodeIfThere(Bool.self, forKey: .askFirst)) ?? false
        // An unknown state (a newer app's) is not read as a draft: the file is held, not rewritten.
        if let raw = try c.decodeIfThere(String.self, forKey: .state) {
            guard let known = State(rawValue: raw) else { throw DecodingError.dataCorruptedError(forKey: .state, in: c, debugDescription: "Unknown state \(raw)") }
            state = known
        } else { state = .draft }
        after = (try c.decodeIfThere([UUID].self, forKey: .after)) ?? []
        room = try c.decodeIfPresent(UUID.self, forKey: .room)
        originRoom = try c.decodeIfPresent(UUID.self, forKey: .originRoom)
        notes = (try c.decodeIfThere([TodoNote].self, forKey: .notes)) ?? []
        question = try c.decodeIfPresent(TodoQuestion.self, forKey: .question)
        attempts = (try c.decodeIfThere(Int.self, forKey: .attempts)) ?? 0
        lastError = try c.decodeIfPresent(String.self, forKey: .lastError)
        result = try c.decodeIfPresent(String.self, forKey: .result)
        assumptions = (try c.decodeIfThere([String].self, forKey: .assumptions)) ?? []
        files = (try c.decodeIfThere([String].self, forKey: .files)) ?? []
        report = try c.decodeIfPresent(TodoReport.self, forKey: .report)
        workers = try c.decodeIfPresent([String].self, forKey: .workers)
        interrupted = (try c.decodeIfThere(Bool.self, forKey: .interrupted)) ?? false
        unreported = (try c.decodeIfThere(Bool.self, forKey: .unreported)) ?? false
        createdAt = (try c.decodeIfThere(Date.self, forKey: .createdAt)) ?? Date()
        updatedAt = (try c.decodeIfThere(Date.self, forKey: .updatedAt)) ?? createdAt
        workSeconds = (try c.decodeIfThere(Double.self, forKey: .workSeconds)) ?? 0
        waitSeconds = (try c.decodeIfThere(Double.self, forKey: .waitSeconds)) ?? 0
        stateSince = try c.decodeIfPresent(Date.self, forKey: .stateSince)
        startedAt = try c.decodeIfPresent(Date.self, forKey: .startedAt)
        finishedAt = try c.decodeIfPresent(Date.self, forKey: .finishedAt)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(id, forKey: .id); try c.encode(listID, forKey: .listID); try c.encode(title, forKey: .title); try c.encode(detail, forKey: .detail)
        try c.encode(attachments, forKey: .attachments)
        try c.encode(askFirst, forKey: .askFirst); try c.encode(state.rawValue, forKey: .state); try c.encode(after, forKey: .after)
        try c.encodeIfPresent(room, forKey: .room); try c.encodeIfPresent(originRoom, forKey: .originRoom); try c.encode(notes, forKey: .notes)
        try c.encodeIfPresent(question, forKey: .question); try c.encode(attempts, forKey: .attempts); try c.encodeIfPresent(lastError, forKey: .lastError)
        try c.encodeIfPresent(result, forKey: .result); try c.encode(assumptions, forKey: .assumptions); try c.encode(files, forKey: .files)
        try c.encodeIfPresent(report, forKey: .report); try c.encodeIfPresent(workers, forKey: .workers)
        try c.encode(interrupted, forKey: .interrupted); try c.encode(unreported, forKey: .unreported)
        try c.encode(createdAt, forKey: .createdAt); try c.encode(updatedAt, forKey: .updatedAt)
        try c.encode(workSeconds, forKey: .workSeconds); try c.encode(waitSeconds, forKey: .waitSeconds)
        try c.encodeIfPresent(stateSince, forKey: .stateSince); try c.encodeIfPresent(startedAt, forKey: .startedAt); try c.encodeIfPresent(finishedAt, forKey: .finishedAt)
    }

    // The time so far: the stored sums plus the current state's open part.
    func work(at now: Date) -> Double { workSeconds + (state == .running ? stateSince.map { max(0, now.timeIntervalSince($0)) } ?? 0 : 0) }
    func wait(at now: Date) -> Double { waitSeconds + (state == .review || state == .needsYou ? stateSince.map { max(0, now.timeIntervalSince($0)) } ?? 0 : 0) }

    // The board's time line: "AI 작업 12분 · 확인 기다림 3분 · 시작 후 2시간 5분". Never started since timing came: nothing.
    public func timeLine(at now: Date) -> String? {
        guard let started = startedAt else { return nil }
        var parts = [L("AI 작업 ", "AI work ") + Self.span(work(at: now))]
        let wait = wait(at: now)
        if wait >= 60 || state == .review || state == .needsYou { parts.append(L("확인 기다림 ", "waiting for you ") + Self.span(wait)) }
        parts.append(L("시작 후 ", "since start ") + Self.span((finishedAt ?? now).timeIntervalSince(started)))
        return parts.joined(separator: " · ")
    }
    static func span(_ seconds: Double) -> String {
        let m = max(0, Int(seconds)) / 60
        if m < 1 { return L("1분 미만", "<1 min") }
        if m < 60 { return L("\(m)분", "\(m) min") }
        let h = m / 60
        if h < 24 { return m % 60 == 0 ? L("\(h)시간", "\(h) h") : L("\(h)시간 \(m % 60)분", "\(h) h \(m % 60) min") }
        return h % 24 == 0 ? L("\(h / 24)일", "\(h / 24) d") : L("\(h / 24)일 \(h % 24)시간", "\(h / 24) d \(h % 24) h")
    }

    // The old state's time goes to its sum; the new state starts now.
    mutating func clock(from old: State, at now: Date) {
        if let since = stateSince {
            let spent = max(0, now.timeIntervalSince(since))
            if old == .running { workSeconds += spent } else if old == .review || old == .needsYou { waitSeconds += spent }
        }
        stateSince = now
        if state == .running, startedAt == nil { startedAt = now }
        finishedAt = state == .done || state == .cancelled ? finishedAt ?? now : nil
    }
}

// One list per project. In order: each TODO waits for the one above it. waitForDone: the next one waits for the
// user's [Done] instead of starting when the previous one waits for the check (for work the user must see first).
public struct TodoList: Codable, Identifiable, Equatable {
    public var id = UUID()
    public var title: String
    public var project: ProjectBinding?
    public var sequential = true
    public var waitForDone = false
    var order: [UUID] = []
    public var lock: EnterpriseLock?       // the project is worked on in an Enterprise chat: its TODOs go only to those accounts
    public var accounts: [String] = []     // the accounts the user picked to work and review its TODOs; empty: automatic (every Claude/Codex)
    public var paused = false              // ⏸ nothing new starts (a running TODO finishes); ready ones stay ready for the resume
    public var stopAfter: UUID?            // "stop after this one": TODOs below it on the board do not start
    public init(title: String, project: ProjectBinding?, lock: EnterpriseLock? = nil) { self.title = title; self.project = project; self.lock = lock }
    private enum Keys: String, CodingKey { case id, title, project, sequential, waitForDone, order, lock, accounts, paused, stopAfter }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        id = try c.decode(UUID.self, forKey: .id)
        title = (try c.decodeIfThere(String.self, forKey: .title)) ?? ""
        project = try c.decodeIfPresent(ProjectBinding.self, forKey: .project)
        sequential = (try c.decodeIfThere(Bool.self, forKey: .sequential)) ?? true
        waitForDone = (try c.decodeIfThere(Bool.self, forKey: .waitForDone)) ?? false
        order = (try c.decodeIfThere([UUID].self, forKey: .order)) ?? []
        lock = try c.decodeIfPresent(EnterpriseLock.self, forKey: .lock)
        accounts = (try c.decodeIfThere([String].self, forKey: .accounts)) ?? []
        paused = (try c.decodeIfThere(Bool.self, forKey: .paused)) ?? false
        stopAfter = try c.decodeIfPresent(UUID.self, forKey: .stopAfter)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(id, forKey: .id); try c.encode(title, forKey: .title); try c.encodeIfPresent(project, forKey: .project)
        try c.encode(sequential, forKey: .sequential); try c.encode(waitForDone, forKey: .waitForDone); try c.encode(order, forKey: .order)
        try c.encodeIfPresent(lock, forKey: .lock)
        if !accounts.isEmpty { try c.encode(accounts, forKey: .accounts) }
        if paused { try c.encode(paused, forKey: .paused) }
        try c.encodeIfPresent(stopAfter, forKey: .stopAfter)
    }
}

enum TodoError: LocalizedError, Equatable {
    case cycle, notFound, busy, notEditable, save(String), attachment(String), locked(String)
    var errorDescription: String? {
        switch self {
        case .cycle: return L("순서가 돌고 돌아요: 서로 기다리는 TODO가 생겨요.", "That order goes in a circle: these TODOs would wait for each other.")
        case .notFound: return L("TODO를 찾지 못했어요.", "TODO not found.")
        case .busy: return L("진행 중인 TODO는 먼저 멈춰야 해요.", "Stop the running TODO first.")
        case .notEditable: return L("AI가 이미 가져간 TODO는 고칠 수 없어요. 결과에 수정 요청이나 답으로 알려 주세요.", "The AI already took this TODO; tell it through a change request or an answer.")
        case .attachment(let why), .locked(let why): return why
        case .save(let why): return L("TODO를 저장하지 못했어요: ", "Could not save the TODOs: ") + why
        }
    }
}

// Fields that always have a value: missing (an older file) gets the default, but an explicit null is a broken
// file (this app never writes one), so it fails like any other bad value and the file is held.
extension KeyedDecodingContainer {
    func decodeIfThere<T: Decodable>(_ type: T.Type, forKey key: Key) throws -> T? {
        contains(key) ? try decode(type, forKey: key) : nil
    }
}

public struct TodoData: Codable, Equatable {
    static let currentVersion = 1
    var version = 1
    public var lists: [TodoList] = []
    public var items: [TodoItem] = []
    public init() {}
    private enum Keys: String, CodingKey { case version, lists, items }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        version = (try c.decodeIfThere(Int.self, forKey: .version)) ?? 1
        lists = (try c.decodeIfThere([TodoList].self, forKey: .lists)) ?? []
        items = (try c.decodeIfThere([TodoItem].self, forKey: .items)) ?? []
    }

    public func item(_ id: UUID) -> TodoItem? { items.first { $0.id == id } }
    // Who may work in a chat: the accounts a TODO running in it was given when it started; nil: not limited
    // (no TODO running there, or one whose list lets every Claude/Codex work).
    public func workers(room: UUID) -> [String]? { items.first { $0.room == room && $0.state == .running }?.workers }
    func list(_ id: UUID) -> TodoList? { lists.first { $0.id == id } }
    // A list's TODOs in the user's order (ones missing from `order` last, oldest first).
    public func ordered(_ listID: UUID) -> [TodoItem] {
        let mine = items.filter { $0.listID == listID }
        let order = list(listID)?.order ?? []
        return mine.sorted { a, b in
            let i = order.firstIndex(of: a.id) ?? Int.max, j = order.firstIndex(of: b.id) ?? Int.max
            return i != j ? i < j : a.createdAt < b.createdAt
        }
    }
    // What a TODO waits for: its "after" links and, in a list in order, the nearest TODO above it that is neither
    // cancelled nor a draft (a draft is not going to run, so the ready ones below it go on in the user's order).
    public func blockers(_ item: TodoItem) -> [UUID] {
        var ids = item.after
        if list(item.listID)?.sequential == true {
            let row = ordered(item.listID)
            if let at = row.firstIndex(where: { $0.id == item.id }), let above = row[..<at].last(where: { $0.state != .cancelled && $0.state != .draft }) { ids.append(above.id) }
        }
        return ids
    }
    // A TODO it waits for is far enough: done, or waiting for the user's check when the list lets the next one start then.
    public func satisfied(_ blocker: TodoItem, for item: TodoItem) -> Bool {
        blocker.state == .done || (blocker.state == .review && list(item.listID)?.waitForDone != true)
    }
    // "After" links to TODOs the user cancelled: the TODO cannot go on without the user (the answer drops the link).
    func cancelledBlockers(_ item: TodoItem) -> [TodoItem] { item.after.compactMap(self.item).filter { $0.state == .cancelled } }
    // Held by the user: its list is paused, or it is below the list's stop point on the board (in any order mode).
    public func stopped(_ item: TodoItem) -> Bool {
        guard let list = list(item.listID) else { return false }
        if list.paused { return true }
        guard let stop = list.stopAfter else { return false }
        let row = ordered(list.id).map(\.id)
        guard let at = row.firstIndex(of: stop), let mine = row.firstIndex(of: item.id) else { return false }
        return mine > at
    }

    // The TODOs that may start now, in board order: ready, everything they wait for far enough, a project, and
    // their folder free (no other TODO running in it, no chat writing it: `held`).
    func eligible(held: (String) -> Bool) -> [TodoItem] {
        let busy = Set(items.filter { $0.state == .running }.compactMap { list($0.listID)?.project?.root })
        return lists.flatMap { ordered($0.id) }.filter { item in
            guard item.state == .ready, !stopped(item), let root = list(item.listID)?.project?.root, !busy.contains(root), cancelledBlockers(item).isEmpty else { return false }
            guard blockers(item).allSatisfy({ id in self.item(id).map { satisfied($0, for: item) } ?? true }) else { return false }
            return !held(root)
        }
    }

    // A TODO put in front of `before` (nil: at the end) of its own list; `before` in another list is not found.
    mutating func place(_ id: UUID, before: UUID?) throws {
        guard let item = item(id), let l = lists.firstIndex(where: { $0.id == item.listID }) else { throw TodoError.notFound }
        guard before != id else { return }
        var order = ordered(item.listID).map(\.id)
        if let before, !order.contains(before) { throw TodoError.notFound }
        order.removeAll { $0 == id }
        order.insert(id, at: before.flatMap { order.firstIndex(of: $0) } ?? order.endIndex)
        lists[l].order = order
    }

    // Waiting for each other in a circle (links and list order together) never starts: refused when saved.
    var hasCycle: Bool {
        var state: [UUID: Int] = [:]   // 1 visiting, 2 done
        func visit(_ id: UUID) -> Bool {
            if state[id] == 1 { return true }
            if state[id] == 2 { return false }
            state[id] = 1
            if let item = item(id), blockers(item).contains(where: visit) { return true }
            state[id] = 2
            return false
        }
        return items.contains { visit($0.id) }
    }
}

// todos.json in the app's data folder (tests give their own file). Changes come from the main thread (the board,
// the scheduler) and from tool calls (task_done / task_ask on the tool socket's thread).
public final class TodoStore: ObservableObject {
    public static var shared = TodoStore(url: URL(fileURLWithPath: AccountStore.supportDir).appendingPathComponent("todos.json"))
    public let url: URL
    private let lock = NSLock()
    private var data: TodoData
    // A file this version cannot read (broken, or from a newer app) is never overwritten: changes are refused
    // (the same rule as ProjectInfoStore).
    public let locked: String?
    var now: () -> Date = Date.init   // tests set the clock
    @Published public private(set) var snapshot: TodoData
    @Published public private(set) var saveError: String?   // the last save failed: shown on the board until one succeeds

    public init(url: URL) {
        self.url = url
        var loaded = TodoData(), why: String?
        // Only a file that is not there starts empty; one that cannot be read (permissions, a passing error) is held.
        let raw: Data?
        do { raw = try Data(contentsOf: url) } catch {
            let missing = (error as NSError).domain == NSCocoaErrorDomain && (error as NSError).code == NSFileReadNoSuchFileError
            raw = nil
            if !missing { why = L("todos.json을 열지 못해서 TODO를 바꾸지 않았어요. 앱을 다시 열어 주세요.", "todos.json could not be opened, so the TODOs are left as they are. Please reopen the app.") }
        }
        if let raw {
            if let decoded = try? Self.decoder.decode(TodoData.self, from: raw), decoded.version <= TodoData.currentVersion {
                loaded = decoded
            } else {
                why = L("todos.json을 읽지 못해서 TODO를 바꾸지 않았어요. 파일을 확인해 주세요.", "todos.json could not be read, so the TODOs are left as they are. Please check the file.")
            }
        }
        data = loaded; snapshot = loaded; locked = why; saveError = why
    }
    static let decoder = JSONDecoder()
    static let encoder: JSONEncoder = { let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]; return e }()

    public var current: TodoData { lock.lock(); defer { lock.unlock() }; return data }

    // One change, saved at once. A change that makes TODOs wait for each other in a circle is refused.
    @discardableResult
    public func update<T>(_ edit: (inout TodoData) throws -> T) throws -> T {
        if let locked { throw TodoError.locked(locked) }
        lock.lock()
        var copy = data
        let result: T
        do { result = try edit(&copy) } catch { lock.unlock(); throw error }
        if copy.hasCycle { lock.unlock(); throw TodoError.cycle }
        let now = now()
        for i in copy.items.indices {
            let old = data.item(copy.items[i].id)
            if let old, old.state != copy.items[i].state { copy.items[i].clock(from: old.state, at: now) }
            if old != copy.items[i] { copy.items[i].updatedAt = now }
        }
        // Saved first: a change that is not on disk is not made (it would be lost or run again after a restart).
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Self.encoder.encode(copy).write(to: url, options: .atomic)
        } catch {
            lock.unlock()
            let why = TodoError.save(error.localizedDescription)
            if Thread.isMainThread { saveError = why.errorDescription } else { DispatchQueue.main.async { self.saveError = why.errorDescription } }
            throw why
        }
        data = copy
        lock.unlock()
        if Thread.isMainThread { snapshot = copy; saveError = nil } else { DispatchQueue.main.async { self.snapshot = self.current; self.saveError = nil } }
        return result
    }
    public func change(_ id: UUID, _ edit: (inout TodoItem) throws -> Void) throws {
        try update { data in
            guard let i = data.items.firstIndex(where: { $0.id == id }) else { throw TodoError.notFound }
            try edit(&data.items[i])
        }
    }

    // MARK: The board's actions (main thread)

    // A new TODO is a draft: the scheduler does not take it until the user presses Start. Added to a list that is
    // already going (a TODO of it running or ready), it joins the queue as ready, so the work goes on to it by itself.
    // files: the photos and files attached to it (copied in; the originals are left as they are).
    // fromAI (the todo_add tool): always a draft, a list already locked must have `lock`'s organization (the tool passes
    // the project's lock, a locked chat's when the list has none, and offers personal chats only projects without one),
    // and an open TODO of the same title in that list is returned instead of a new one (all checked in the one save).
    @discardableResult
    public func add(title: String, detail: String = "", files: [URL] = [], project: ProjectBinding, projectName: String, after: [UUID] = [], askFirst: Bool = false, originRoom: UUID? = nil, lock: EnterpriseLock? = nil, fromAI: Bool = false) throws -> TodoItem {
        let id = UUID()
        let attachments = try copyIn(files, to: id, already: 0)
        do { return try update { data in
            let listID: UUID
            if let l = data.lists.firstIndex(where: { $0.project?.root == project.root }) {
                listID = data.lists[l].id
                if fromAI, let held = data.lists[l].lock, held.organization != lock?.organization { throw TodoError.locked(L("이 채팅에서는 그 프로젝트에 TODO를 적을 수 없어요 (Enterprise).", "This chat cannot add TODOs to that project (Enterprise).")) }
                if fromAI, let same = data.ordered(listID).first(where: { ![.done, .cancelled].contains($0.state) && Self.sameTitle($0.title, title) }) { return same }
                if data.lists[l].lock == nil { data.lists[l].lock = lock }   // like a chat's lock, never removed
            } else {
                // A new worktree of a locked project: its list keeps the project's lock.
                let held = data.lists.first { $0.project?.groupKey == project.groupKey && $0.lock != nil }?.lock
                if fromAI, let held, held.organization != lock?.organization { throw TodoError.locked(L("이 채팅에서는 그 프로젝트에 TODO를 적을 수 없어요 (Enterprise).", "This chat cannot add TODOs to that project (Enterprise).")) }
                let list = TodoList(title: projectName, project: project, lock: held ?? lock); data.lists.append(list); listID = list.id
            }
            var item = TodoItem(listID: listID, title: title, detail: detail, askFirst: askFirst, after: after, originRoom: originRoom)
            item.id = id; item.attachments = attachments
            if !fromAI, data.list(listID)?.paused != true, data.items.contains(where: { $0.listID == listID && ($0.state == .running || $0.state == .ready) }) { item.state = .ready }
            data.items.append(item)
            if let i = data.lists.firstIndex(where: { $0.id == listID }) { data.lists[i].order = data.ordered(listID).map(\.id) }
            return item
        } } catch { try? FileManager.default.removeItem(at: folder(id)); throw error }
    }
    static func sameTitle(_ a: String, _ b: String) -> Bool {
        a.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(b.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame
    }
    // ▶ Start now: every draft may be taken, and the lists' pause and stop point are lifted.
    // lists: only these (▶ on one project's board); nil = every list.
    public func startDrafts(lists: Set<UUID>? = nil) {
        try? update { data in
            for i in data.items.indices where data.items[i].state == .draft && lists.map({ $0.contains(data.items[i].listID) }) ?? true { data.items[i].state = .ready }
            for l in data.lists.indices where lists.map({ $0.contains(data.lists[l].id) }) ?? true { data.lists[l].paused = false; data.lists[l].stopAfter = nil }
        }
    }
    // ⏸ Pause: nothing new of these lists starts (a running TODO finishes); ready TODOs stay ready for the resume.
    public func pause(lists: Set<UUID>? = nil) throws {
        try update { data in for l in data.lists.indices where lists.map({ $0.contains(data.lists[l].id) }) ?? true { data.lists[l].paused = true } }
    }
    // Resume: the ready TODOs go on again; drafts stay drafts (▶ Start makes them ready).
    public func resume(lists: Set<UUID>? = nil) throws {
        try update { data in for l in data.lists.indices where lists.map({ $0.contains(data.lists[l].id) }) ?? true { data.lists[l].paused = false; data.lists[l].stopAfter = nil } }
    }
    // Stop after this TODO: the ones below it on the board do not start. The same TODO again lifts the stop point.
    public func stop(after id: UUID) throws {
        try update { data in
            guard let item = data.item(id), let l = data.lists.firstIndex(where: { $0.id == item.listID }) else { throw TodoError.notFound }
            data.lists[l].stopAfter = data.lists[l].stopAfter == id ? nil : id
        }
    }
    // The row's draft/ready capsule: only while it is still one of the two (the scheduler may have taken it meanwhile).
    public func setReady(_ id: UUID, _ ready: Bool) throws {
        try change(id) { item in
            guard item.state == .draft || item.state == .ready else { throw TodoError.notEditable }
            item.state = ready ? .ready : .draft
        }
    }
    public func accept(_ id: UUID) { try? change(id) { guard $0.state == .review else { return }; $0.state = .done; $0.unreported = false } }
    // Change request: the feedback goes with the next attempt, in the same chat.
    public func requestChanges(_ id: UUID, _ text: String) {
        try? change(id) { item in
            guard item.state == .review else { return }
            item.notes.append(TodoNote(kind: .feedback, text: text)); item.state = .ready; item.attempts = 0; item.unreported = false
        }
    }
    // The user's decision: ready again with the answer (links to cancelled TODOs are dropped).
    public func answer(_ id: UUID, _ text: String) {
        try? update { data in
            guard let i = data.items.firstIndex(where: { $0.id == id }), data.items[i].state == .needsYou else { return }
            let gone = Set(data.cancelledBlockers(data.items[i]).map(\.id))
            data.items[i].after.removeAll { gone.contains($0) }
            if !text.isEmpty { data.items[i].notes.append(TodoNote(kind: .answer, text: text)) }
            data.items[i].state = .ready; data.items[i].question = nil; data.items[i].attempts = 0; data.items[i].lastError = nil; data.items[i].unreported = false
        }
    }
    // Editing: only a TODO the AI has not taken yet (draft or ready); once it runs, the AI already has the text.
    public static func editable(_ item: TodoItem) -> Bool { item.state == .draft || item.state == .ready }
    public func edit(_ id: UUID, title: String, detail: String, askFirst: Bool) throws {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        try change(id) { item in
            guard Self.editable(item) else { throw TodoError.notEditable }
            item.title = title; item.detail = detail.trimmingCharacters(in: .whitespacesAndNewlines); item.askFirst = askFirst
        }
    }
    // The todo_edit tool, all checked again in the one save: never a running TODO (busy); a draft or ready one may
    // change its text, become the other of the two and move; any other only moves (its text is the AI's already).
    // Only in a list the asking chat's organization may write (nil: personal; a list without a lock is the tool's to
    // judge). Leaving a field out keeps it. before: in front of that TODO of the same list; .some(nil): to the end.
    @discardableResult
    func editForAI(_ id: UUID, title: String?, detail: String?, askFirst: Bool?, ready: Bool? = nil, before: UUID?? = nil, organization: String?) throws -> TodoItem {
        let title = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        return try update { data in
            guard let i = data.items.firstIndex(where: { $0.id == id }), let list = data.list(data.items[i].listID) else { throw TodoError.notFound }
            if let held = list.lock, held.organization != organization { throw TodoError.notFound }
            let state = data.items[i].state
            guard state != .running else { throw TodoError.busy }
            if title != nil || detail != nil || askFirst != nil || ready != nil {
                guard Self.editable(data.items[i]) else { throw TodoError.notEditable }
            }
            if let title, !title.isEmpty { data.items[i].title = title }
            if let detail { data.items[i].detail = detail.trimmingCharacters(in: .whitespacesAndNewlines) }
            if let askFirst { data.items[i].askFirst = askFirst }
            if let ready { data.items[i].state = ready ? .ready : .draft }
            if let before { try data.place(id, before: before) }
            return data.items[i]
        }
    }
    public func cancel(_ id: UUID) throws { try change(id) { guard $0.state != .running else { throw TodoError.busy }; $0.state = .cancelled; $0.unreported = false } }
    public func delete(_ id: UUID) throws {
        try update { data in
            guard let item = data.item(id) else { throw TodoError.notFound }
            guard item.state != .running else { throw TodoError.busy }
            data.items.removeAll { $0.id == id }
            // The stop point deleted: the list stays stopped (paused) rather than going on below it by itself.
            for l in data.lists.indices where data.lists[l].stopAfter == id { data.lists[l].stopAfter = nil; data.lists[l].paused = true }
            for i in data.items.indices { data.items[i].after.removeAll { $0 == id } }
            for i in data.lists.indices { data.lists[i].order.removeAll { $0 == id } }
            data.lists.removeAll { list in !data.items.contains { $0.listID == list.id } }
        }
        try? FileManager.default.removeItem(at: folder(id))   // only once the TODO is gone from the saved file
    }
    // Whole lists (a deleted project's) with their TODOs and attachments, in one save; refused while one of them runs.
    // TODOs of other lists that waited for them no longer wait; a list stopped after one stays stopped (paused).
    @discardableResult
    public func deleteLists(_ ids: Set<UUID>) throws -> Int {
        guard !ids.isEmpty else { return 0 }
        let gone: Set<UUID> = try update { data in
            let items = data.items.filter { ids.contains($0.listID) }
            guard !items.contains(where: { $0.state == .running }) else { throw TodoError.busy }
            let gone = Set(items.map(\.id))
            data.items.removeAll { gone.contains($0.id) }
            data.lists.removeAll { ids.contains($0.id) }
            for l in data.lists.indices {
                if let stop = data.lists[l].stopAfter, gone.contains(stop) { data.lists[l].stopAfter = nil; data.lists[l].paused = true }
                data.lists[l].order.removeAll { gone.contains($0) }
            }
            for i in data.items.indices { data.items[i].after.removeAll { gone.contains($0) } }
            return gone
        }
        for id in gone { try? FileManager.default.removeItem(at: folder(id)) }   // only once they are gone from the saved file
        return gone.count
    }
    // Lists of a project whose work folder was disconnected now belong to its folderless binding, in one save.
    // A project locked for good (`groupKey` `key`): each of its lists without a lock gets `lock`; a project with no list gets
    // one (`name`, `project`), so the lock stays after its chats go. Lists with a lock keep theirs (the chat side refuses a
    // project whose locks differ before it asks).
    public func lockProject(_ key: String, name: String, project: ProjectBinding, lock: EnterpriseLock) throws {
        try update { data in
            var found = false
            for i in data.lists.indices where data.lists[i].project?.groupKey == key {
                found = true
                if data.lists[i].lock == nil { data.lists[i].lock = lock }
            }
            if !found { data.lists.append(TodoList(title: name, project: project, lock: lock)) }
        }
    }
    public func relink(_ ids: Set<UUID>, to project: ProjectBinding) throws {
        guard !ids.isEmpty else { return }
        try update { data in
            guard !data.items.contains(where: { ids.contains($0.listID) && $0.state == .running }) else { throw TodoError.busy }
            for l in data.lists.indices where ids.contains(data.lists[l].id) { data.lists[l].project = project }
        }
    }
    // Up (-1) or down (+1) in its list.
    public func move(_ id: UUID, by step: Int) throws {
        try update { data in
            guard let item = data.item(id), let l = data.lists.firstIndex(where: { $0.id == item.listID }) else { throw TodoError.notFound }
            var order = data.ordered(item.listID).map(\.id)
            guard let at = order.firstIndex(of: id), order.indices.contains(at + step) else { return }
            order.swapAt(at, at + step)
            data.lists[l].order = order
        }
    }
    // Dragged on the board: in front of `before` (nil: to the end), in the same list only. A running TODO may move
    // too (its place, not its work); an order that makes TODOs wait in a circle is refused by update.
    public func move(_ id: UUID, before: UUID?) throws {
        try update { data in try data.place(id, before: before) }
    }
    public func setAfter(_ id: UUID, _ after: [UUID]) throws { try change(id) { $0.after = after.filter { $0 != id } } }
    // accounts: [] goes back to automatic. Takes effect from the next start; a running attempt keeps its crew.
    public func setList(_ listID: UUID, sequential: Bool? = nil, waitForDone: Bool? = nil, accounts: [String]? = nil) throws {
        try update { data in
            guard let l = data.lists.firstIndex(where: { $0.id == listID }) else { throw TodoError.notFound }
            if let sequential { data.lists[l].sequential = sequential }
            if let waitForDone { data.lists[l].waitForDone = waitForDone }
            if let accounts { var seen = Set<String>(); data.lists[l].accounts = accounts.filter { !$0.isEmpty && seen.insert($0).inserted } }
        }
    }
    // MARK: Attachments

    public static let maxAttachments = 10
    static let maxAttachmentBytes = 25 * 1024 * 1024
    var filesDir: URL { url.deletingLastPathComponent().appendingPathComponent("todo-files") }
    func folder(_ id: UUID) -> URL { filesDir.appendingPathComponent(id.uuidString) }
    public func file(_ item: UUID, _ attachment: TodoAttachment) -> URL { folder(item).appendingPathComponent(attachment.id.uuidString + "-" + attachment.name) }

    // A name that stays one file name (no folders, no hidden file).
    static let maxNameBytes = 200
    static func safeName(_ name: String) -> String {
        var clean = name.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while clean.hasPrefix(".") { clean.removeFirst() }
        // File names are limited in UTF-8 bytes (255); the stored copy adds a UUID and "-" (37 bytes).
        if clean.utf8.count > maxNameBytes {
            let ext = (clean as NSString).pathExtension
            let tail = ext.isEmpty || ext.utf8.count > 20 ? "" : "." + ext
            var stem = tail.isEmpty ? clean : (clean as NSString).deletingPathExtension
            while !stem.isEmpty && stem.utf8.count + tail.utf8.count > maxNameBytes { stem.removeLast() }
            clean = stem + tail
        }
        return clean.isEmpty ? "file" : clean
    }

    // Copies the files into the TODO's folder before anything is saved: on any failure the copies made are removed.
    private func copyIn(_ urls: [URL], to id: UUID, already: Int) throws -> [TodoAttachment] {
        guard !urls.isEmpty else { return [] }
        guard already + urls.count <= Self.maxAttachments else {
            throw TodoError.attachment(L("TODO 하나에 \(Self.maxAttachments)개까지 첨부할 수 있어요.", "Up to \(Self.maxAttachments) attachments per TODO."))
        }
        var made: [URL] = []
        do {
            try FileManager.default.createDirectory(at: folder(id), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            return try urls.map { source in
                let values = try source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentTypeKey])
                guard values.isRegularFile == true, values.isSymbolicLink != true else {
                    throw TodoError.attachment(L("일반 파일만 첨부할 수 있어요: ", "Only regular files can be attached: ") + source.lastPathComponent)
                }
                guard (values.fileSize ?? 0) <= Self.maxAttachmentBytes else {
                    throw TodoError.attachment(L("25MB 이하만 첨부할 수 있어요: ", "Attachments must be under 25 MB: ") + source.lastPathComponent)
                }
                let attachment = TodoAttachment(name: Self.safeName(source.lastPathComponent), image: values.contentType?.conforms(to: .image) == true)
                let target = file(id, attachment)
                try FileManager.default.copyItem(at: source, to: target)
                made.append(target)
                return attachment
            }
        } catch {
            for url in made { try? FileManager.default.removeItem(at: url) }
            if let error = error as? TodoError { throw error }
            throw TodoError.attachment(L("파일을 첨부하지 못했어요: ", "Could not attach the file: ") + error.localizedDescription)
        }
    }

    // More files for a TODO that is not running (the running one already got its files).
    public func attach(_ id: UUID, files: [URL]) throws {
        guard let item = current.item(id) else { throw TodoError.notFound }
        guard item.state != .running else { throw TodoError.busy }
        let added = try copyIn(files, to: id, already: item.attachments.count)
        do {
            try change(id) { t in
                guard t.state != .running else { throw TodoError.busy }
                guard t.attachments.count + added.count <= Self.maxAttachments else {
                    throw TodoError.attachment(L("TODO 하나에 \(Self.maxAttachments)개까지 첨부할 수 있어요.", "Up to \(Self.maxAttachments) attachments per TODO."))
                }
                t.attachments += added
            }
        } catch { for a in added { try? FileManager.default.removeItem(at: file(id, a)) }; throw error }
    }
    public func detach(_ id: UUID, _ attachment: UUID) throws {
        var gone: TodoAttachment?
        try change(id) { t in
            guard t.state != .running else { throw TodoError.busy }
            gone = t.attachments.first { $0.id == attachment }
            t.attachments.removeAll { $0.id == attachment }
        }
        if let gone { try? FileManager.default.removeItem(at: file(id, gone)) }
    }

    // Waiting for the user (the sidebar badge): a decision, or a result to check.
    public var waitingForUser: Int { snapshot.items.filter { $0.state == .needsYou || $0.state == .review }.count }
}

// task_done / task_ask: only for the live attempt of a TODO's own chat (like work_plan).
public final class TaskLink: ToolProvider {
    public static let shared = TaskLink()
    public var active: Bool { ProjectWork.active }
    public func tools() -> [[String: Any]] { [] }
    private func live(_ context: ToolContext) -> TodoItem? {
        guard let run = ProjectWork.get(context.projectRun), run.room == context.room, context.projectGeneration == run.generation, !run.cancelled else { return nil }
        return TodoStore.shared.current.items.first { $0.room == context.room && $0.state == .running }
    }
    public func tools(context: ToolContext) -> [[String: Any]] {
        guard live(context) != nil else { return [] }
        let string: [String: Any] = ["type": "string"], strings: [String: Any] = ["type": "array", "items": string]
        let question: [String: Any] = ["type": "object", "properties": ["text": string, "options": strings, "recommended": string],
                                       "required": ["text"], "additionalProperties": false]
        return [["name": "task_done",
                 "description": "Report that this TODO is finished (and tested where it can be). When this chat's work and review are over, the TODO waits for the user's check. Call it again after fixes to update the report. Then end your reply with a short report.",
                 "inputSchema": ["type": "object", "properties": ["summary": string, "assumptions": strings, "files": strings],
                                 "required": ["summary"], "additionalProperties": false]],
                ["name": "task_ask",
                 "description": "This TODO cannot go on without the user: kind 'question' (at most 3 questions, with options and your recommendation) or 'blocked' (missing information, an approval, contradicting requirements). Then stop and end your reply.",
                 "inputSchema": ["type": "object", "properties": ["kind": ["type": "string", "enum": ["question", "blocked"]], "reason": string,
                                                                   "questions": ["type": "array", "items": question, "maxItems": 3]],
                                 "required": ["kind", "reason"], "additionalProperties": false]]]
    }
    public func call(_ name: String, _ arguments: [String: Any], context: ToolContext) -> [String: Any] {
        guard let item = live(context) else { return ProjectTools.failure("No running TODO in this chat.") }
        func text(_ key: String) -> String { (arguments[key] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
        func list(_ value: Any?) -> [String] { (value as? [String] ?? []).map { String($0.prefix(300)) }.filter { !$0.isEmpty }.prefix(30).map { $0 } }
        switch name {
        case "task_done":
            let summary = text("summary")
            guard !summary.isEmpty else { return ProjectTools.failure("summary is required.") }
            // Kept with the attempt: the TODO waits for the check only once the review and its fixes are over (settle).
            do {
                try TodoStore.shared.change(item.id) { t in
                    var report = t.report ?? TodoReport()
                    report.summary = String(summary.prefix(4000)); report.assumptions = list(arguments["assumptions"]); report.files = list(arguments["files"])
                    t.report = report
                }
            } catch { return ProjectTools.failure(error.localizedDescription) }
            return ["content": [["type": "text", "text": "Recorded. When this chat's work and review are over, the TODO waits for the user's check. End your reply with a short report of what you did and what to check."]], "isError": false]
        case "task_ask":
            let kind = text("kind"), reason = text("reason")
            guard ["question", "blocked"].contains(kind), !reason.isEmpty else { return ProjectTools.failure("kind (question|blocked) and reason are required.") }
            let raw = arguments["questions"] as? [[String: Any]] ?? []
            guard raw.count <= 3 else { return ProjectTools.failure("At most 3 questions.") }
            let items = raw.compactMap { q -> TodoQuestion.Item? in
                let t = (q["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                return t.isEmpty ? nil : TodoQuestion.Item(text: String(t.prefix(500)), options: list(q["options"]).prefix(6).map { $0 }, recommended: (q["recommended"] as? String).map { String($0.prefix(300)) })
            }
            guard kind == "blocked" || !items.isEmpty else { return ProjectTools.failure("A question needs at least one question.") }
            do {
                try TodoStore.shared.change(item.id) { t in
                    var report = t.report ?? TodoReport()
                    report.question = TodoQuestion(blocked: kind == "blocked", reason: String(reason.prefix(2000)), items: items)
                    t.report = report
                }
            } catch { return ProjectTools.failure(error.localizedDescription) }
            return ["content": [["type": "text", "text": "Recorded. Stop working now: end your reply with the reason and the questions. The user decides in the chat."]], "isError": false]
        default: return ProjectTools.failure("Unknown tool: " + name)
        }
    }
}

// What project code reads of a chat; the chats themselves are the chat side's. The app gives the list (ProjectChats.list,
// set where the chat tools are linked), read on the main thread.
public struct ProjectChatSummary: Equatable {
    var id: UUID
    var updatedAt: Date
    var project: ProjectBinding?
    var lock: EnterpriseLock?
    var enterprise: Bool    // locked by an organization (a personal lock is not)
    var openTurn: UUID?     // the newest message while its answer is still open
    public init(id: UUID, updatedAt: Date, project: ProjectBinding?, lock: EnterpriseLock?, enterprise: Bool, openTurn: UUID?) {
        self.id = id; self.updatedAt = updatedAt; self.project = project; self.lock = lock; self.enterprise = enterprise; self.openTurn = openTurn
    }
}
public enum ProjectChats {
    public static var list: () -> [ProjectChatSummary] = { [] }
}

// The projects TODOs are written for (the board's add bar, the todo_add tool): the TODO lists' and those of the
// chats (newest first), one per root, with the Enterprise lock its TODOs keep (the list's, else a locked chat's).
public struct TodoProject {
    public var name: String
    public var binding: ProjectBinding
    var lock: EnterpriseLock?
    public static func all(_ data: TodoData, chats: [ProjectChatSummary], names: [String: String]) -> [TodoProject] {
        var seen = Set<String>(), result: [TodoProject] = []
        func lock(_ p: ProjectBinding) -> EnterpriseLock? {
            // The whole project's (every worktree of the repository), as the sidebar shows it.
            let key = p.groupKey
            return data.lists.first { $0.project?.groupKey == key && $0.lock != nil }?.lock
                ?? chats.first { $0.project?.groupKey == key && $0.lock != nil }?.lock
        }
        for list in data.lists { if let p = list.project, seen.insert(p.root).inserted { result.append(TodoProject(name: names[p.groupKey] ?? list.title, binding: p, lock: lock(p))) } }
        for chat in chats.sorted(by: { $0.updatedAt > $1.updatedAt }) {
            if let p = chat.project, seen.insert(p.root).inserted { result.append(TodoProject(name: names[p.groupKey] ?? (p.root as NSString).lastPathComponent, binding: p, lock: lock(p))) }
        }
        return result
    }
}

// todo_add: from any chat (a project's or not, a TODO's own one too), the AI writes a TODO on a project's board
// when the user asks, e.g. an idea from another talk. Always a draft: nothing runs until the user presses Start.
// todo_list / todo_edit: the same chats read a board in its order and, when the user asks, change any TODO that is
// not running: a draft's or ready one's text, draft ↔ ready (ready runs without ▶ Start), and the place of any.
// An Enterprise chat sees and writes only its organization's projects; any other chat only projects without a lock.
public final class TodoAddLink: ToolProvider {
    public static let shared = TodoAddLink()
    var store: () -> TodoStore = { TodoStore.shared }
    var names: () -> [String: String] = { ProjectInfoStore.shared.names }
    public var active: Bool { true }
    public func tools() -> [[String: Any]] { [] }
    private func main<T>(_ work: () -> T) -> T { Thread.isMainThread ? work() : DispatchQueue.main.sync(execute: work) }

    // The asking chat while its newest message is being answered (a session of an earlier answer adds nothing), and the projects it may write to.
    private func scope(_ context: ToolContext) -> (chat: ProjectChatSummary, projects: [TodoProject])? {
        guard context.asker != nil, let turn = context.turn else { return nil }
        let (chats, names) = main { (ProjectChats.list(), self.names()) }
        guard let chat = chats.first(where: { $0.id == context.room }), chat.openTurn == turn else { return nil }
        let mine = chat.lock?.organization
        let projects = TodoProject.all(store().current, chats: chats, names: names).filter { $0.lock?.organization == mine }
        return (chat, projects)
    }

    private static func describe(_ projects: [TodoProject]) -> String {
        projects.prefix(30).map { "\($0.name) (\($0.binding.isFolderless ? "no folder" : $0.binding.root))" }.joined(separator: "; ")
    }

    public func tools(context: ToolContext) -> [[String: Any]] {
        guard let (chat, projects) = scope(context), !projects.isEmpty else { return [] }
        let string: [String: Any] = ["type": "string"]
        let here = chat.project.flatMap { p in projects.first { $0.binding.root == p.root } }
        return [["name": "todo_add",
                 "description": "Add a TODO to the user's TODO board for a project, from any chat, when the user asks to add or note one (or clearly agrees to your suggestion). Never on your own. It is added as a draft: it runs only when the user presses Start on the board. title: one short line in the user's language; detail: what to do, the context from this chat and what done looks like (the AI that takes it sees only this). project: a name or folder from the list\(here.map { "; leave it out for this chat's project \($0.name)" } ?? ""). One TODO per call. Projects: " + Self.describe(projects),
                 "inputSchema": ["type": "object", "properties": ["title": string, "detail": string, "project": string, "ask_first": ["type": "boolean"]],
                                 "required": ["title"], "additionalProperties": false]],
                ["name": "todo_list",
                 "description": "List the TODOs on a project's board in the board's order (in an in-order list the ready ones run top to bottom; drafts are skipped until made ready) with their position, id, state (draft, ready, running, review = waits for the user's check, needsYou = waits for the user's answer, done, cancelled), title, ask_first and full detail, before todo_edit, 30 at a time (offset: how many to skip, for the next ones). Done and cancelled ones only with include_done. project: as for todo_add\(here.map { "; leave it out for this chat's project \($0.name)" } ?? "; leave it out for every project")).",
                 "inputSchema": ["type": "object", "properties": ["project": string, "offset": ["type": "integer"], "include_done": ["type": "boolean"]], "additionalProperties": false]],
                ["name": "todo_edit",
                 "description": "Change a TODO (from todo_list) only when the user asks. Never on your own: a TODO made ready runs without the user pressing Start. id: its id from todo_list. Give only what changes: title (one short line), detail (replaces the whole detail: keep what still holds), ask_first, state (\"draft\" or \"ready\"), before (the id of a TODO of the same board to put it in front of, or \"end\"). A running TODO cannot be changed at all; title, detail, ask_first and state only for draft or ready ones; any other (review, needsYou, done, cancelled) can only move with before.",
                 "inputSchema": ["type": "object", "properties": ["id": string, "title": string, "detail": string, "ask_first": ["type": "boolean"],
                                                                   "state": ["type": "string", "enum": ["draft", "ready"]], "before": string],
                                 "required": ["id"], "additionalProperties": false]]]
    }

    // The TODOs this chat may see, in board order with their place in their list: in lists of its projects (one project when given).
    private func visible(_ projects: [TodoProject], in data: TodoData) -> [(project: TodoProject, place: Int, item: TodoItem)] {
        data.lists.flatMap { list -> [(project: TodoProject, place: Int, item: TodoItem)] in
            guard let root = list.project?.root, let p = projects.first(where: { $0.binding.root == root }) else { return [] }
            return data.ordered(list.id).enumerated().map { (p, $0.offset + 1, $0.element) }
        }
    }

    // A name (any case), a folder path, or a folder name; nil with the reason when none or several fit.
    static func pick(_ wanted: String, in projects: [TodoProject]) -> (TodoProject?, String?) {
        let w = wanted.trimmingCharacters(in: .whitespacesAndNewlines)
        let path = (w as NSString).expandingTildeInPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let tests: [(TodoProject) -> Bool] = [
            { $0.name.caseInsensitiveCompare(w) == .orderedSame },
            { !$0.binding.isFolderless && $0.binding.root.trimmingCharacters(in: CharacterSet(charactersIn: "/")) == path },
            { !$0.binding.isFolderless && ($0.binding.root as NSString).lastPathComponent.caseInsensitiveCompare(w) == .orderedSame }]
        for test in tests {
            let found = projects.filter(test)
            if found.count == 1 { return (found[0], nil) }
            if found.count > 1 { return (nil, "Several projects fit \"\(w)\": " + describe(found) + ". Give the folder path.") }
        }
        return (nil, "No project \"\(w)\". Projects: " + describe(projects) + ".")
    }

    private static func reply(_ text: String) -> [String: Any] { ["content": [["type": "text", "text": text]], "isError": false] }

    public func call(_ name: String, _ arguments: [String: Any], context: ToolContext) -> [String: Any] {
        guard ["todo_add", "todo_list", "todo_edit"].contains(name) else { return ProjectTools.failure("Unknown tool: " + name) }
        guard let (chat, projects) = scope(context), !projects.isEmpty else { return ProjectTools.failure("TODO tools are not available for this answer.") }
        func text(_ key: String) -> String { (arguments[key] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
        func oneLine(_ value: String) -> String { String(value.split(whereSeparator: \.isNewline).first.map(String.init)?.prefix(200) ?? "") }
        let store = store()
        if name == "todo_list" {
            var shown = projects
            if !text("project").isEmpty {
                let (found, why) = Self.pick(text("project"), in: projects)
                guard let found else { return ProjectTools.failure(why ?? "No such project.") }
                shown = [found]
            } else if let p = chat.project, let found = projects.first(where: { $0.binding.root == p.root }) { shown = [found] }
            let data = store.current
            let all = arguments["include_done"] as? Bool == true
            let list = visible(shown, in: data).filter { all || ($0.item.state != .done && $0.item.state != .cancelled) }
            guard !list.isEmpty else { return Self.reply("No\(all ? "" : " open") TODOs on " + shown.map(\.name).joined(separator: ", ") + ".") }
            let skip = min(max(arguments["offset"] as? Int ?? 0, 0), list.count)
            let page = list.dropFirst(skip).prefix(30)
            guard !page.isEmpty else { return Self.reply("No TODOs after offset \(skip): there are \(list.count).") }
            let lines = page.map { p, place, item in
                let order = data.list(item.listID)?.sequential == true ? "in order" : "any order"
                return "id: \(item.id.uuidString)\nproject: \(p.name) (\(order))\nplace: \(place)\nstate: \(item.state.rawValue)\ntitle: \(item.title)\nask_first: \(item.askFirst)\ndetail:\n\(item.detail.isEmpty ? "(none)" : item.detail)"
            }
            return Self.reply(lines.joined(separator: "\n\n---\n\n") + (skip + page.count < list.count ? "\n\n(\(list.count - skip - page.count) more: call again with offset \(skip + page.count).)" : ""))
        }
        if name == "todo_edit" {
            guard let id = UUID(uuidString: text("id")) else { return ProjectTools.failure("id is required: take it from todo_list.") }
            let data = store.current
            guard let found = visible(projects, in: data).first(where: { $0.item.id == id })?.item else { return ProjectTools.failure("No TODO with that id here: call todo_list.") }
            let title = arguments["title"] == nil ? nil : oneLine(text("title"))
            if title?.isEmpty == true { return ProjectTools.failure("title cannot be empty.") }
            // A detail longer than todo_add's limit (written on the board) may be sent back whole: nothing is cut.
            let detail = arguments["detail"] == nil ? nil : text("detail")
            let limit = max(8000, found.detail.count)
            if let detail, detail.count > limit { return ProjectTools.failure("detail is too long (\(detail.count) characters, at most \(limit)): shorten it; nothing was changed.") }
            let askFirst = arguments["ask_first"] as? Bool
            var ready: Bool?
            if arguments["state"] != nil {
                guard ["draft", "ready"].contains(text("state")) else { return ProjectTools.failure("state must be \"draft\" or \"ready\".") }
                ready = text("state") == "ready"
            }
            var before: UUID??
            if arguments["before"] != nil {
                if text("before").lowercased() == "end" { before = .some(nil) }
                else if let other = UUID(uuidString: text("before")), data.item(other)?.listID == found.listID { before = .some(other) }
                else { return ProjectTools.failure("before must be the id of a TODO on the same board (from todo_list) or \"end\"; nothing was changed.") }
            }
            guard title != nil || detail != nil || askFirst != nil || ready != nil || before != nil else {
                return ProjectTools.failure("Nothing to change: give title, detail, ask_first, state or before.")
            }
            do {
                let item = try store.editForAI(id, title: title, detail: detail, askFirst: askFirst, ready: ready, before: before, organization: chat.lock?.organization)
                let note = item.state == .ready ? " It is ready: it may start by itself when its turn comes." : item.state == .draft ? " It is a draft: it runs only when the user presses Start or makes it ready." : ""
                return Self.reply("Changed \"\(item.title)\" (\(item.state.rawValue)).\(note) Tell the user briefly.")
            } catch TodoError.busy {
                return ProjectTools.failure("That TODO is running: it cannot be changed or moved now. Tell the user.")
            } catch TodoError.notEditable {
                return ProjectTools.failure("That TODO is \(store.current.item(id)?.state.rawValue ?? found.state.rawValue): only its place can change (before). Nothing was changed. Tell the user.")
            } catch { return ProjectTools.failure(error.localizedDescription) }
        }
        let title = oneLine(text("title"))
        guard !title.isEmpty else { return ProjectTools.failure("title is required.") }
        let target: TodoProject
        if !text("project").isEmpty {
            let (found, why) = Self.pick(text("project"), in: projects)
            guard let found else { return ProjectTools.failure(why ?? "No such project.") }
            target = found
        } else if let p = chat.project, let found = projects.first(where: { $0.binding.root == p.root }) {
            target = found
        } else {
            return ProjectTools.failure("This chat is not linked to a project: ask the user which one, then give project. Projects: " + Self.describe(projects) + ".")
        }
        // The report card shows in the chat it came from, unless that is a TODO's own chat (it has its own card).
        let origin = store.current.items.contains { $0.room == chat.id } ? nil : chat.id
        let before = Set(store.current.items.map(\.id))
        do {
            let item = try store.add(title: title, detail: String(text("detail").prefix(8000)), project: target.binding, projectName: target.name,
                                     askFirst: arguments["ask_first"] as? Bool ?? false, originRoom: origin, lock: target.lock, fromAI: true)
            if before.contains(item.id) {
                return ["content": [["type": "text", "text": "Already on \(target.name)'s board as \"\(item.title)\" (\(item.state.rawValue)); nothing was added or changed. Tell the user."]], "isError": false]
            }
            return ["content": [["type": "text", "text": "Added to \(target.name)'s TODO board as a draft: \"\(item.title)\". It runs only when the user presses Start on the board. Tell the user briefly."]], "isError": false]
        } catch { return ProjectTools.failure(error.localizedDescription) }
    }
}

extension Notification.Name {
    // A TODO waits for the user (its result to check, or a decision): ApprovalAlerts shows a macOS notification.
    public static let todoNeedsUser = Notification.Name("AIIlluminatiTodoNeedsUser")
}

// The chat side the scheduler works through (the app's Discussion: TodoChatsApp.swift), on the main thread.
public protocol TodoChats: AnyObject {
    var answering: Set<UUID> { get }              // the chats answering now
    var answeringChanged: AnyPublisher<Void, Never> { get }
    var maxAnswering: Int { get }                 // how many chats may answer at once
    var importing: Bool { get }                   // attached files are being read: nothing starts
    var chats: [ProjectChatSummary] { get }
    // Who works and who reviews (nil: nobody may now), and why nobody can.
    func crew(lock: EnterpriseLock?, allowed: [String]) -> (lead: Account, reviewer: Account?)?
    func noCrew(_ allowed: [String], lock: EnterpriseLock?) -> String
    func addChat(_ project: ProjectBinding, title: String, lock: EnterpriseLock?) -> UUID
    func setCrew(room: UUID, members: [String], lead: String)
    func folder(_ room: UUID) -> URL              // the chat's own folder
    func sentPhotos(_ room: UUID) -> Set<UUID>    // photos already sent in that chat (by ID)
    // Sends the TODO's message; the photos go with it under their IDs. Returns why it did not start.
    func start(room: UUID, question: String, photos: [TodoPhoto], review: Bool, extra: String) -> String?
    func ended(_ room: UUID) -> TodoTurnEnd       // how the chat's last answer ended
    func stop(_ room: UUID)
}
// A photo attached to a TODO, sent with its message (the chat side makes its own copy under the same ID).
public struct TodoPhoto: Equatable {
    public var file: URL
    public var name: String
    public var id: UUID
}
public struct TodoTurnEnd: Equatable {
    var error: String?
    var unreviewed = false   // a review card failed without a headline: the review could not be done
    public init(error: String? = nil, unreviewed: Bool = false) { self.error = error; self.unreviewed = unreviewed }
}

// Picks and starts TODOs (main thread). Wakes on Start, every 30 minutes, when a chat finishes and when the board
// changes. One of the three answering places stays free for the user's own chats; at most two TODOs at once; an
// account needs 30% of both its 5-hour and weekly usage left to take a TODO.
public final class TodoScheduler: ObservableObject {
    public static var shared: TodoScheduler?
    static let interval: TimeInterval = 1800
    public static let threshold = 30.0
    static let maxTodos = 2
    public static let maxAttempts = 2   // retries after an error before the user is asked
    let chats: TodoChats
    let store: TodoStore
    @Published public private(set) var nextCheck: Date?
    @Published public private(set) var waiting: String?   // why nothing starts although TODOs are ready
    private var timer: Timer?
    private var watching: [AnyCancellable] = []
    private var pending = false
    private var retryAt: [UUID: (at: Date, reason: String)] = [:]   // a TODO whose chat refused to start: not tried again before `at`
    static let retryDelay: TimeInterval = 60
    var held: (String) -> Bool = ProjectWork.isHeld
    // The TODO open for editing on the board: not started until the edit is saved or dropped.
    public var editing: UUID? { didSet { if oldValue != editing { wake() } } }

    public init(chats: TodoChats, store: TodoStore) { self.chats = chats; self.store = store }

    public func start() {
        recover()
        let timer = Timer(timeInterval: Self.interval, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        nextCheck = Date().addingTimeInterval(Self.interval)
        watching = [chats.answeringChanged.receive(on: DispatchQueue.main).sink { [weak self] _ in self?.wake() },
                    store.$snapshot.receive(on: DispatchQueue.main).sink { [weak self] _ in self?.wake() },
                    // A chat lets go of a repository after its answer is marked finished: the next TODO need not wait 30 minutes.
                    NotificationCenter.default.publisher(for: .projectReleased).receive(on: DispatchQueue.main).sink { [weak self] _ in self?.wake() }]
        wake()
    }

    // ▶ Start now on the board.
    public func startNow(lists: Set<UUID>? = nil) { store.startDrafts(lists: lists); tick() }

    // Once per run of the main loop, however many changes came in.
    public func wake() {
        guard !pending else { return }
        pending = true
        DispatchQueue.main.async { self.pending = false; self.tick() }
    }

    // The app quits: running TODOs stop counting work time now (not while the app is off).
    public func closeClocks() {
        let now = store.now()
        try? store.update { data in
            for i in data.items.indices where data.items[i].state == .running {
                if let since = data.items[i].stateSince { data.items[i].workSeconds += max(0, now.timeIntervalSince(since)) }
                data.items[i].stateSince = nil
            }
        }
    }

    // The app quit while TODOs ran: they are ready again, and the next attempt first looks at what is left.
    public func recover() {
        try? store.update { data in
            for i in data.items.indices where data.items[i].state == .running {
                // Not closed at quit (a crash): the work counts up to its last saved change, a lower bound.
                if let since = data.items[i].stateSince { data.items[i].workSeconds += max(0, data.items[i].updatedAt.timeIntervalSince(since)) }
                data.items[i].stateSince = nil
                data.items[i].attempts += 1
                data.items[i].interrupted = true
                data.items[i].report = nil
                data.items[i].notes.append(TodoNote(kind: .retry, text: L("앱이 꺼져서 이전 시도가 중간에 끊겼어요.", "The app quit during the previous attempt.")))
                if data.items[i].attempts > Self.maxAttempts {
                    data.items[i].state = .needsYou; data.items[i].unreported = true
                    data.items[i].question = TodoQuestion(blocked: true, reason: L("여러 번 중간에 끊겼어요. 계속할까요?", "It was interrupted several times. Continue?"))
                } else { data.items[i].state = .ready }
            }
        }
    }

    public func tick() {
        settle()
        if timer != nil { nextCheck = (timer?.fireDate).flatMap { $0 > Date() ? $0 : nil } ?? Date().addingTimeInterval(Self.interval) }
        // An "after" link to a cancelled TODO: the user decides.
        let snapshot = store.current
        for item in snapshot.items where item.state == .ready && !snapshot.cancelledBlockers(item).isEmpty {
            let names = snapshot.cancelledBlockers(item).map(\.title).joined(separator: ", ")
            try? store.change(item.id) {
                $0.state = .needsYou; $0.unreported = true
                $0.question = TodoQuestion(blocked: true, reason: L("먼저 끝나야 할 TODO가 취소됐어요: \(names). 이대로 진행할까요?", "A TODO this one waits for was cancelled: \(names). Go ahead anyway?"))
            }
        }
        var started = 0
        var note: String?
        for item in store.current.eligible(held: held) {
            let data = store.current
            guard data.items.filter({ $0.state == .running }).count < Self.maxTodos else { break }
            guard chats.answering.count + 1 < chats.maxAnswering, !chats.importing else {
                note = L("다른 대화가 답하는 중이라 기다려요.", "Waiting for other chats to finish."); break
            }
            if let retry = retryAt[item.id], retry.at > Date() { note = retry.reason; continue }
            if item.id == editing { note = L("고치는 중인 TODO는 저장할 때까지 기다려요.", "The TODO being edited waits until it is saved."); continue }
            guard data.item(item.id)?.state == .ready, let list = data.list(item.listID), let project = list.project,
                  !data.items.contains(where: { $0.state == .running && data.list($0.listID)?.project?.root == project.root }) else { continue }
            let lock = lock(for: item, list: list, project: project)
            guard let crew = crew(lock: lock, allowed: list.accounts) else {
                // Picked AIs: only this project waits, the others may still start.
                if !list.accounts.isEmpty { note = chats.noCrew(list.accounts, lock: lock); continue }
                note = chats.noCrew([], lock: lock); break
            }
            if let reason = begin(item, list: list, project: project, crew: crew, lock: lock) {
                // Changed meanwhile (todo_edit, the board): its change wakes the scheduler again, no waiting.
                if reason == Self.changed { continue }
                note = reason
                // Not again at once (its chat may be answering the user): the change to ready would wake the scheduler.
                retryAt[item.id] = (Date().addingTimeInterval(Self.retryDelay), reason)
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.retryDelay) { [weak self] in self?.wake() }
            } else { started += 1; retryAt[item.id] = nil }
        }
        let ready = store.current.items.contains { $0.state == .ready }
        waiting = started == 0 && ready ? note : nil
    }

    // The Enterprise lock a TODO's work keeps: its list's, else that of a locked chat on the project (the one it was
    // written from, its own chat, any other). Its chat is locked with it, so the review and handoffs keep it too.
    public func lock(for item: TodoItem, list: TodoList, project: ProjectBinding) -> EnterpriseLock? {
        if let lock = list.lock { return lock }
        let chats = chats.chats
        for id in [item.originRoom, item.room].compactMap({ $0 }) { if let lock = chats.first(where: { $0.id == id })?.lock { return lock } }
        let key = project.groupKey
        return store.current.lists.first { $0.project?.groupKey == key && $0.lock != nil }?.lock
            ?? chats.first { $0.project?.groupKey == key && $0.lock != nil }?.lock
    }

    // Who works and who reviews (the chat side picks by usage and lock); allowed: the accounts picked for the list
    // (TodoList.accounts); empty: any. Never falls back to the others.
    public func crew(lock: EnterpriseLock? = nil, allowed: [String] = []) -> (lead: Account, reviewer: Account?)? { chats.crew(lock: lock, allowed: allowed) }

    // The crew a list's next TODO would get if it started now (the board shows it).
    public func crew(for list: TodoList) -> (lead: Account, reviewer: Account?)? {
        guard list.project != nil else { return nil }
        return crew(lock: lock(for: list), allowed: list.accounts)
    }
    // The lock of the list's next TODO to start (the board's picker and preview use the same one).
    public func lock(for list: TodoList) -> EnterpriseLock? {
        guard let project = list.project else { return nil }
        let item = store.current.ordered(list.id).first { $0.state == .ready || $0.state == .draft } ?? TodoItem(listID: list.id, title: "")
        return lock(for: item, list: list, project: project)
    }

    // Starts one TODO in its own chat. Returns why it did not start (it stays ready). The message is made from the
    // TODO as saved now, and it becomes running only if it is still exactly that and may still start, checked in the
    // same save: todo_edit (another thread) or the board may change it, make it a draft or move it meanwhile.
    static let changed = "changed"
    @discardableResult
    func begin(_ item: TodoItem, list: TodoList, project: ProjectBinding, crew: (lead: Account, reviewer: Account?), lock: EnterpriseLock? = nil) -> String? {
        guard let item = store.current.item(item.id), item.state == .ready else { return Self.changed }
        var room = item.room
        // A new chat when there is none, or when its lock is not the TODO's (a chat made before the project was locked).
        if room == nil || chats.chats.first(where: { $0.id == room }).map({ $0.lock?.organization != lock?.organization }) ?? true {
            room = chats.addChat(project, title: "TODO · " + item.title, lock: lock)
        }
        guard let room else { return nil }
        if chats.answering.contains(room) { return L("TODO 채팅이 아직 답하는 중이라 기다려요.", "Waiting for the TODO's chat to finish answering.") }
        chats.setCrew(room: room, members: [crew.lead.id] + (crew.reviewer.map { [$0.id] } ?? []), lead: crew.lead.id)
        // The attachments go into the chat's own folder (the AI reads them there); photos it has not seen yet also go with the message.
        let delivered: (paths: [String], photos: [TodoPhoto])
        do { delivered = try deliver(item, room: room) } catch {
            try? store.change(item.id) { $0.room = room }   // the next try reuses this chat and the copies already made
            return error.localizedDescription
        }
        let question = Self.question(item, files: delivered.paths, documents: project.isDocuments)
        // Running before the turn starts: the AI's first tool call must find it.
        do {
            try store.update { data in
                guard let i = data.items.firstIndex(where: { $0.id == item.id }), data.items[i] == item,
                      data.eligible(held: { _ in false }).contains(where: { $0.id == item.id }) else { throw TodoError.notEditable }
                data.items[i].state = .running; data.items[i].room = room; data.items[i].lastError = nil; data.items[i].report = nil
                data.items[i].workers = list.accounts.isEmpty ? nil : list.accounts
            }
        } catch TodoError.notEditable {
            try? store.change(item.id) { $0.room = room }   // the chat made for it is reused next time
            return Self.changed
        } catch {
            return error.localizedDescription
        }
        if let reason = chats.start(room: room, question: question, photos: delivered.photos, review: crew.reviewer != nil, extra: Self.instruction(item, documents: project.isDocuments)) {
            try? store.change(item.id) { $0.state = .ready; $0.lastError = reason }
            return reason
        }
        try? store.change(item.id) { $0.interrupted = false }
        return nil
    }

    // Copies the TODO's attachments into its chat's folder (kept when already there) and returns their paths, with
    // the photos not yet sent in that chat (at most 4 per message, like the message box). A photo carries its
    // attachment's ID, so a retry in the same chat does not send it twice.
    static let attachmentFolder = "TODO attachments"
    func deliver(_ item: TodoItem, room: UUID) throws -> (paths: [String], photos: [TodoPhoto]) {
        guard !item.attachments.isEmpty else { return ([], []) }
        let target = chats.folder(room).appendingPathComponent(Self.attachmentFolder)
        let sent = chats.sentPhotos(room)
        var paths: [String] = [], photos: [TodoPhoto] = []
        do {
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            for attachment in item.attachments {
                let source = store.file(item.id, attachment)
                let copy = target.appendingPathComponent(String(attachment.id.uuidString.prefix(8)) + "-" + attachment.name)
                if !FileManager.default.fileExists(atPath: copy.path) { try FileManager.default.copyItem(at: source, to: copy) }
                paths.append(copy.path)
                if attachment.image, !sent.contains(attachment.id), photos.count < 4 { photos.append(TodoPhoto(file: source, name: attachment.name, id: attachment.id)) }
            }
        } catch {
            throw TodoError.attachment(L("첨부 파일을 TODO 채팅에 넣지 못했어요: ", "Could not put the attachments into the TODO's chat: ") + error.localizedDescription)
        }
        return (paths, photos)
    }

    // A TODO chat stopped answering while its TODO still runs: the AI did not report.
    func settle() {
        for item in store.current.items where item.state == .running {
            guard let room = item.room, !chats.answering.contains(room) else { continue }
            let turn = chats.ended(room)
            let report = item.report
            if let error = turn.error {
                // Another chat writing the repository is not the TODO's fault: try again later.
                let busy = ProjectWork.isBusy(error)
                try? store.change(item.id) { t in
                    if !busy { t.attempts += 1 }
                    t.lastError = error
                    // It had reported, then the review or the fixes failed: the next attempt looks at what is there first.
                    if report != nil { t.interrupted = true }
                    t.report = nil
                    if t.attempts > Self.maxAttempts {
                        t.state = .needsYou; t.unreported = true
                        t.question = TodoQuestion(blocked: true, reason: L("\(Self.maxAttempts)번 다시 시도했지만 실패했어요: ", "Failed after \(Self.maxAttempts) retries: ") + String(error.prefix(600)))
                    } else {
                        t.state = .ready
                        if !busy { t.notes.append(TodoNote(kind: .retry, text: L("오류로 다시 시도해요: ", "Retrying after an error: ") + String(error.prefix(300)))) }
                    }
                }
            } else if let question = report?.question {
                try? store.change(item.id) { t in t.state = .needsYou; t.question = question; t.report = nil; t.unreported = true }
            } else if let report, let summary = report.summary {
                // The review could not be done: the result still waits for the check, with that said on its card.
                let unreviewed = turn.unreviewed
                try? store.change(item.id) { t in
                    t.state = .review; t.result = summary; t.assumptions = report.assumptions; t.files = report.files; t.report = nil
                    t.question = nil; t.unreported = true
                    t.lastError = unreviewed ? L("검수하지 못했어요. 채팅에서 이유를 확인해 주세요.", "The review could not be done. See the chat for why.") : nil
                }
            } else {
                try? store.change(item.id) { t in
                    t.state = .needsYou; t.unreported = true; t.report = nil
                    t.question = TodoQuestion(blocked: true, reason: L("AI가 결과 보고(task_done/task_ask) 없이 끝냈어요. 채팅을 보고 정해 주세요.", "The AI ended without reporting (task_done/task_ask). Check the chat and decide."))
                }
            }
        }
        // Announce results and questions once their chat has finished answering.
        for item in store.current.items where item.unreported && (item.state == .review || item.state == .needsYou) {
            if let room = item.room, chats.answering.contains(room) { continue }
            guard (try? store.change(item.id) { $0.unreported = false }) != nil else { continue }   // not saved: announced later, once
            NotificationCenter.default.post(name: .todoNeedsUser, object: nil, userInfo: ["room": item.room ?? item.originRoom as Any, "title": item.title,
                                                                                         "review": item.state == .review, "body": item.state == .review ? item.result ?? "" : item.question?.reason ?? ""])
        }
    }

    // Stops a running TODO and cancels it.
    public func cancel(_ id: UUID) {
        guard let item = store.current.item(id) else { return }
        if item.state == .running {
            try? store.change(id) { $0.state = .cancelled }
            if let room = item.room { chats.stop(room) }
        } else { try? store.cancel(id) }
    }

    // What the AI is asked: the TODO, then everything the user said about it since.
    // files: where its attachments are for the AI (deliver).
    public static func question(_ item: TodoItem, files: [String] = [], documents: Bool = false) -> String {
        var text = "TODO: " + item.title
        if !item.detail.isEmpty { text += "\n\n" + item.detail }
        if !files.isEmpty { text += "\n\n" + L("[첨부 파일]", "[Attached files]") + "\n" + files.map { "- " + $0 }.joined(separator: "\n") }
        let said = item.notes.filter { $0.kind == .answer || $0.kind == .feedback }
        if !said.isEmpty {
            text += "\n\n" + L("[내 답과 수정 요청]", "[My answers and change requests]") + "\n"
                + said.map { ($0.kind == .feedback ? L("수정 요청: ", "Change request: ") : L("답: ", "Answer: ")) + $0.text }.joined(separator: "\n")
        }
        if item.interrupted {
            text += "\n\n" + (documents ? L("이전 시도가 중간에 끊겼어. 파일 상태부터 확인하고 남은 것만 이어서 해.", "The previous attempt was cut off. Check the files first and continue only what is left.")
                                        : L("이전 시도가 중간에 끊겼어. git status부터 확인하고 남은 것만 이어서 해.", "The previous attempt was cut off. Check git status first and continue only what is left."))
        }
        else if item.attempts > 0, let error = item.lastError { text += "\n\n" + L("이전 시도가 오류로 끝났어: ", "The previous attempt ended with an error: ") + String(error.prefix(300)) }
        return text
    }

    public static func instruction(_ item: TodoItem, documents: Bool = false) -> String {
        let usual = documents ? "Work in this documents project as usual (plan, change the files, build or render and look at the result where you can)."
            : "Work in this project as usual (plan, change, test, commit and push when the project rules say so)."
        return """
        [TODO work] This is a TODO from the user's board, done while the user may be away. \(usual)
        When it is finished and \(documents ? "checked" : "tested"), call task_done with a summary, the assumptions you made and the files you changed\(documents ? " (and any steps left for the user)" : ""), then end with a short report.
        If you cannot go on (missing information, a decision or an approval only the user can give, contradicting requirements), call task_ask and stop.
        \(item.askFirst ? "Before changing anything, ask with task_ask what is unclear (at most 3 questions, with options and your recommendation). If nothing is unclear, go ahead."
                       : "Where something is unclear, make a reasonable assumption, go on, and list it in task_done.")
        Never publish stable. Do not wait on approval cards: if a step needs the user's approval, call task_ask instead.
        """
    }
}
