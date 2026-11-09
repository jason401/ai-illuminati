import Foundation
import Combine

// TODO work (TODO_PLAN.md): the user writes TODOs on the board, presses Start, and the app gives the next one
// that may start to a Claude/Codex account in a chat of its own (the project work path, with a review by another
// account). The AI reports with task_done (waits for the user's check) or task_ask (the user decides); the user
// accepts the result. Two kinds of order: one TODO per project folder at a time (automatic), and the order the
// user sets (a list in order, or "after" links to other TODOs).

struct TodoNote: Codable, Equatable {
    enum Kind: String, Codable { case answer, feedback, retry, system }
    var at = Date()
    var kind: Kind
    var text: String
}

// What task_ask left for the user: questions with choices, or why the work cannot go on.
struct TodoQuestion: Codable, Equatable {
    struct Item: Codable, Equatable { var text: String; var options: [String] = []; var recommended: String? }
    var blocked: Bool
    var reason: String
    var items: [Item] = []
}

// What task_done / task_ask said during an attempt. It becomes the TODO's state only when the whole attempt (the
// work, the review and the fixes after it) has finished: an error after it still counts as an error.
struct TodoReport: Codable, Equatable {
    var summary: String?
    var assumptions: [String] = []
    var files: [String] = []
    var question: TodoQuestion?   // task_ask: the user decides, whatever task_done said
}

struct TodoItem: Codable, Identifiable, Equatable {
    // draft (not taken yet) → ready → running → review (the AI is done; waits for the user's check) → done.
    // needsYou: a question, or the work cannot go on; the user's answer makes it ready again, Stop cancels it.
    enum State: String, Codable, CaseIterable { case draft, ready, running, review, done, needsYou, cancelled }
    var id = UUID()
    var listID: UUID
    var title: String
    var detail = ""
    var askFirst = false            // ask before starting; otherwise assume, go on and list the assumptions
    var state: State = .draft
    var after: [UUID] = []          // TODOs that must be finished first (any list)
    var room: UUID?                 // the TODO's own chat, made when it first starts
    var originRoom: UUID?           // the chat it was written from: its report card shows there too
    var notes: [TodoNote] = []      // the user's answers and change requests, retries; sent with the next attempt
    var question: TodoQuestion?
    var attempts = 0                // attempts that ended in an error since the user last answered
    var lastError: String?
    var result: String?
    var assumptions: [String] = []
    var files: [String] = []
    var report: TodoReport?         // the running attempt's report, not final yet
    var interrupted = false         // the app quit while it ran: the next attempt checks git status first
    var unreported = false          // review or needsYou not yet announced (macOS notification)
    var createdAt = Date()
    var updatedAt = Date()

    init(listID: UUID, title: String, detail: String = "", askFirst: Bool = false, after: [UUID] = [], originRoom: UUID? = nil) {
        self.listID = listID; self.title = title; self.detail = detail; self.askFirst = askFirst; self.after = after; self.originRoom = originRoom
    }

    // Older or newer files: unknown fields are ignored, missing ones get their defaults.
    private enum Keys: String, CodingKey {
        case id, listID, title, detail, askFirst, state, after, room, originRoom, notes, question, attempts, lastError, result, assumptions, files, report, interrupted, unreported, createdAt, updatedAt
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        id = try c.decode(UUID.self, forKey: .id)
        listID = try c.decode(UUID.self, forKey: .listID)
        title = (try? c.decode(String.self, forKey: .title)) ?? ""
        detail = (try? c.decode(String.self, forKey: .detail)) ?? ""
        askFirst = (try? c.decode(Bool.self, forKey: .askFirst)) ?? false
        state = (try? c.decode(String.self, forKey: .state)).flatMap(State.init(rawValue:)) ?? .draft
        after = (try? c.decode([UUID].self, forKey: .after)) ?? []
        room = try? c.decode(UUID.self, forKey: .room)
        originRoom = try? c.decode(UUID.self, forKey: .originRoom)
        notes = (try? c.decode([TodoNote].self, forKey: .notes)) ?? []
        question = try? c.decode(TodoQuestion.self, forKey: .question)
        attempts = (try? c.decode(Int.self, forKey: .attempts)) ?? 0
        lastError = try? c.decode(String.self, forKey: .lastError)
        result = try? c.decode(String.self, forKey: .result)
        assumptions = (try? c.decode([String].self, forKey: .assumptions)) ?? []
        files = (try? c.decode([String].self, forKey: .files)) ?? []
        report = try? c.decode(TodoReport.self, forKey: .report)
        interrupted = (try? c.decode(Bool.self, forKey: .interrupted)) ?? false
        unreported = (try? c.decode(Bool.self, forKey: .unreported)) ?? false
        createdAt = (try? c.decode(Date.self, forKey: .createdAt)) ?? Date()
        updatedAt = (try? c.decode(Date.self, forKey: .updatedAt)) ?? createdAt
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(id, forKey: .id); try c.encode(listID, forKey: .listID); try c.encode(title, forKey: .title); try c.encode(detail, forKey: .detail)
        try c.encode(askFirst, forKey: .askFirst); try c.encode(state.rawValue, forKey: .state); try c.encode(after, forKey: .after)
        try c.encodeIfPresent(room, forKey: .room); try c.encodeIfPresent(originRoom, forKey: .originRoom); try c.encode(notes, forKey: .notes)
        try c.encodeIfPresent(question, forKey: .question); try c.encode(attempts, forKey: .attempts); try c.encodeIfPresent(lastError, forKey: .lastError)
        try c.encodeIfPresent(result, forKey: .result); try c.encode(assumptions, forKey: .assumptions); try c.encode(files, forKey: .files)
        try c.encodeIfPresent(report, forKey: .report)
        try c.encode(interrupted, forKey: .interrupted); try c.encode(unreported, forKey: .unreported)
        try c.encode(createdAt, forKey: .createdAt); try c.encode(updatedAt, forKey: .updatedAt)
    }
}

// One list per project. In order: each TODO waits for the one above it. waitForDone: the next one waits for the
// user's [Done] instead of starting when the previous one waits for the check (for work the user must see first).
struct TodoList: Codable, Identifiable, Equatable {
    var id = UUID()
    var title: String
    var project: ProjectBinding?
    var sequential = true
    var waitForDone = false
    var order: [UUID] = []
    var lock: EnterpriseLock?       // the project is worked on in an Enterprise chat: its TODOs go only to those accounts
    init(title: String, project: ProjectBinding?, lock: EnterpriseLock? = nil) { self.title = title; self.project = project; self.lock = lock }
    private enum Keys: String, CodingKey { case id, title, project, sequential, waitForDone, order, lock }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        id = try c.decode(UUID.self, forKey: .id)
        title = (try? c.decode(String.self, forKey: .title)) ?? ""
        project = try? c.decode(ProjectBinding.self, forKey: .project)
        sequential = (try? c.decode(Bool.self, forKey: .sequential)) ?? true
        waitForDone = (try? c.decode(Bool.self, forKey: .waitForDone)) ?? false
        order = (try? c.decode([UUID].self, forKey: .order)) ?? []
        lock = try? c.decode(EnterpriseLock.self, forKey: .lock)
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(id, forKey: .id); try c.encode(title, forKey: .title); try c.encodeIfPresent(project, forKey: .project)
        try c.encode(sequential, forKey: .sequential); try c.encode(waitForDone, forKey: .waitForDone); try c.encode(order, forKey: .order)
        try c.encodeIfPresent(lock, forKey: .lock)
    }
}

enum TodoError: LocalizedError, Equatable {
    case cycle, notFound, busy, save(String)
    var errorDescription: String? {
        switch self {
        case .cycle: return L("순서가 돌고 돌아요: 서로 기다리는 TODO가 생겨요.", "That order goes in a circle: these TODOs would wait for each other.")
        case .notFound: return L("TODO를 찾지 못했어요.", "TODO not found.")
        case .busy: return L("진행 중인 TODO는 먼저 멈춰야 해요.", "Stop the running TODO first.")
        case .save(let why): return L("TODO를 저장하지 못했어요: ", "Could not save the TODOs: ") + why
        }
    }
}

struct TodoData: Codable, Equatable {
    var version = 1
    var lists: [TodoList] = []
    var items: [TodoItem] = []
    init() {}
    private enum Keys: String, CodingKey { case version, lists, items }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        version = (try? c.decode(Int.self, forKey: .version)) ?? 1
        lists = (try? c.decode([TodoList].self, forKey: .lists)) ?? []
        items = (try? c.decode([TodoItem].self, forKey: .items)) ?? []
    }

    func item(_ id: UUID) -> TodoItem? { items.first { $0.id == id } }
    func list(_ id: UUID) -> TodoList? { lists.first { $0.id == id } }
    // A list's TODOs in the user's order (ones missing from `order` last, oldest first).
    func ordered(_ listID: UUID) -> [TodoItem] {
        let mine = items.filter { $0.listID == listID }
        let order = list(listID)?.order ?? []
        return mine.sorted { a, b in
            let i = order.firstIndex(of: a.id) ?? Int.max, j = order.firstIndex(of: b.id) ?? Int.max
            return i != j ? i < j : a.createdAt < b.createdAt
        }
    }
    // What a TODO waits for: its "after" links and, in a list in order, the nearest TODO above it that was not cancelled.
    func blockers(_ item: TodoItem) -> [UUID] {
        var ids = item.after
        if list(item.listID)?.sequential == true {
            let row = ordered(item.listID)
            if let at = row.firstIndex(where: { $0.id == item.id }), let above = row[..<at].last(where: { $0.state != .cancelled }) { ids.append(above.id) }
        }
        return ids
    }
    // A TODO it waits for is far enough: done, or waiting for the user's check when the list lets the next one start then.
    func satisfied(_ blocker: TodoItem, for item: TodoItem) -> Bool {
        blocker.state == .done || (blocker.state == .review && list(item.listID)?.waitForDone != true)
    }
    // "After" links to TODOs the user cancelled: the TODO cannot go on without the user (the answer drops the link).
    func cancelledBlockers(_ item: TodoItem) -> [TodoItem] { item.after.compactMap(self.item).filter { $0.state == .cancelled } }

    // The TODOs that may start now, in board order: ready, everything they wait for far enough, a project, and
    // their folder free (no other TODO running in it, no chat writing it: `held`).
    func eligible(held: (String) -> Bool) -> [TodoItem] {
        let busy = Set(items.filter { $0.state == .running }.compactMap { list($0.listID)?.project?.root })
        return lists.flatMap { ordered($0.id) }.filter { item in
            guard item.state == .ready, let root = list(item.listID)?.project?.root, !busy.contains(root), cancelledBlockers(item).isEmpty else { return false }
            guard blockers(item).allSatisfy({ id in self.item(id).map { satisfied($0, for: item) } ?? true }) else { return false }
            return !held(root)
        }
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
final class TodoStore: ObservableObject {
    static var shared = TodoStore(url: URL(fileURLWithPath: AccountStore.supportDir).appendingPathComponent("todos.json"))
    let url: URL
    private let lock = NSLock()
    private var data: TodoData
    @Published private(set) var snapshot: TodoData
    @Published private(set) var saveError: String?   // the last save failed: shown on the board until one succeeds

    init(url: URL) {
        self.url = url
        let loaded = (try? Data(contentsOf: url)).flatMap { try? Self.decoder.decode(TodoData.self, from: $0) } ?? TodoData()
        data = loaded; snapshot = loaded
    }
    static let decoder = JSONDecoder()
    static let encoder: JSONEncoder = { let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]; return e }()

    var current: TodoData { lock.lock(); defer { lock.unlock() }; return data }

    // One change, saved at once. A change that makes TODOs wait for each other in a circle is refused.
    @discardableResult
    func update<T>(_ edit: (inout TodoData) throws -> T) throws -> T {
        lock.lock()
        var copy = data
        let result: T
        do { result = try edit(&copy) } catch { lock.unlock(); throw error }
        if copy.hasCycle { lock.unlock(); throw TodoError.cycle }
        let now = Date()
        for i in copy.items.indices where data.item(copy.items[i].id) != copy.items[i] { copy.items[i].updatedAt = now }
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
    func change(_ id: UUID, _ edit: (inout TodoItem) throws -> Void) throws {
        try update { data in
            guard let i = data.items.firstIndex(where: { $0.id == id }) else { throw TodoError.notFound }
            try edit(&data.items[i])
        }
    }

    // MARK: The board's actions (main thread)

    // A new TODO is a draft: the scheduler does not take it until the user presses Start.
    @discardableResult
    func add(title: String, detail: String = "", project: ProjectBinding, projectName: String, after: [UUID] = [], askFirst: Bool = false, originRoom: UUID? = nil, lock: EnterpriseLock? = nil) throws -> TodoItem {
        try update { data in
            let listID: UUID
            if let l = data.lists.firstIndex(where: { $0.project?.root == project.root }) {
                listID = data.lists[l].id
                if data.lists[l].lock == nil { data.lists[l].lock = lock }   // like a chat's lock, never removed
            } else { let list = TodoList(title: projectName, project: project, lock: lock); data.lists.append(list); listID = list.id }
            let item = TodoItem(listID: listID, title: title, detail: detail, askFirst: askFirst, after: after, originRoom: originRoom)
            data.items.append(item)
            if let i = data.lists.firstIndex(where: { $0.id == listID }) { data.lists[i].order = data.ordered(listID).map(\.id) }
            return item
        }
    }
    // ▶ Start now: every draft may be taken.
    func startDrafts() { try? update { data in for i in data.items.indices where data.items[i].state == .draft { data.items[i].state = .ready } } }
    func accept(_ id: UUID) { try? change(id) { guard $0.state == .review else { return }; $0.state = .done; $0.unreported = false } }
    // Change request: the feedback goes with the next attempt, in the same chat.
    func requestChanges(_ id: UUID, _ text: String) {
        try? change(id) { item in
            guard item.state == .review else { return }
            item.notes.append(TodoNote(kind: .feedback, text: text)); item.state = .ready; item.attempts = 0; item.unreported = false
        }
    }
    // The user's decision: ready again with the answer (links to cancelled TODOs are dropped).
    func answer(_ id: UUID, _ text: String) {
        try? update { data in
            guard let i = data.items.firstIndex(where: { $0.id == id }), data.items[i].state == .needsYou else { return }
            let gone = Set(data.cancelledBlockers(data.items[i]).map(\.id))
            data.items[i].after.removeAll { gone.contains($0) }
            if !text.isEmpty { data.items[i].notes.append(TodoNote(kind: .answer, text: text)) }
            data.items[i].state = .ready; data.items[i].question = nil; data.items[i].attempts = 0; data.items[i].lastError = nil; data.items[i].unreported = false
        }
    }
    func cancel(_ id: UUID) throws { try change(id) { guard $0.state != .running else { throw TodoError.busy }; $0.state = .cancelled; $0.unreported = false } }
    func delete(_ id: UUID) throws {
        try update { data in
            guard let item = data.item(id) else { throw TodoError.notFound }
            guard item.state != .running else { throw TodoError.busy }
            data.items.removeAll { $0.id == id }
            for i in data.items.indices { data.items[i].after.removeAll { $0 == id } }
            for i in data.lists.indices { data.lists[i].order.removeAll { $0 == id } }
            data.lists.removeAll { list in !data.items.contains { $0.listID == list.id } }
        }
    }
    // Up (-1) or down (+1) in its list.
    func move(_ id: UUID, by step: Int) throws {
        try update { data in
            guard let item = data.item(id), let l = data.lists.firstIndex(where: { $0.id == item.listID }) else { throw TodoError.notFound }
            var order = data.ordered(item.listID).map(\.id)
            guard let at = order.firstIndex(of: id), order.indices.contains(at + step) else { return }
            order.swapAt(at, at + step)
            data.lists[l].order = order
        }
    }
    func setAfter(_ id: UUID, _ after: [UUID]) throws { try change(id) { $0.after = after.filter { $0 != id } } }
    func setList(_ listID: UUID, sequential: Bool? = nil, waitForDone: Bool? = nil) throws {
        try update { data in
            guard let l = data.lists.firstIndex(where: { $0.id == listID }) else { throw TodoError.notFound }
            if let sequential { data.lists[l].sequential = sequential }
            if let waitForDone { data.lists[l].waitForDone = waitForDone }
        }
    }
    // Waiting for the user (the sidebar badge): a decision, or a result to check.
    var waitingForUser: Int { snapshot.items.filter { $0.state == .needsYou || $0.state == .review }.count }
}

// task_done / task_ask: only for the live attempt of a TODO's own chat (like work_plan).
final class TaskLink: ToolProvider {
    static let shared = TaskLink()
    var active: Bool { ProjectWork.active }
    func tools() -> [[String: Any]] { [] }
    private func live(_ context: ToolContext) -> TodoItem? {
        guard let run = ProjectWork.get(context.projectRun), run.room == context.room, context.projectGeneration == run.generation, !run.cancelled else { return nil }
        return TodoStore.shared.current.items.first { $0.room == context.room && $0.state == .running }
    }
    func tools(context: ToolContext) -> [[String: Any]] {
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
    func call(_ name: String, _ arguments: [String: Any], context: ToolContext) -> [String: Any] {
        guard let item = live(context) else { return ToolHub.failure("No running TODO in this chat.") }
        func text(_ key: String) -> String { (arguments[key] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
        func list(_ value: Any?) -> [String] { (value as? [String] ?? []).map { String($0.prefix(300)) }.filter { !$0.isEmpty }.prefix(30).map { $0 } }
        switch name {
        case "task_done":
            let summary = text("summary")
            guard !summary.isEmpty else { return ToolHub.failure("summary is required.") }
            // Kept with the attempt: the TODO waits for the check only once the review and its fixes are over (settle).
            do {
                try TodoStore.shared.change(item.id) { t in
                    var report = t.report ?? TodoReport()
                    report.summary = String(summary.prefix(4000)); report.assumptions = list(arguments["assumptions"]); report.files = list(arguments["files"])
                    t.report = report
                }
            } catch { return ToolHub.failure(error.localizedDescription) }
            return ["content": [["type": "text", "text": "Recorded. When this chat's work and review are over, the TODO waits for the user's check. End your reply with a short report of what you did and what to check."]], "isError": false]
        case "task_ask":
            let kind = text("kind"), reason = text("reason")
            guard ["question", "blocked"].contains(kind), !reason.isEmpty else { return ToolHub.failure("kind (question|blocked) and reason are required.") }
            let raw = arguments["questions"] as? [[String: Any]] ?? []
            guard raw.count <= 3 else { return ToolHub.failure("At most 3 questions.") }
            let items = raw.compactMap { q -> TodoQuestion.Item? in
                let t = (q["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                return t.isEmpty ? nil : TodoQuestion.Item(text: String(t.prefix(500)), options: list(q["options"]).prefix(6).map { $0 }, recommended: (q["recommended"] as? String).map { String($0.prefix(300)) })
            }
            guard kind == "blocked" || !items.isEmpty else { return ToolHub.failure("A question needs at least one question.") }
            do {
                try TodoStore.shared.change(item.id) { t in
                    var report = t.report ?? TodoReport()
                    report.question = TodoQuestion(blocked: kind == "blocked", reason: String(reason.prefix(2000)), items: items)
                    t.report = report
                }
            } catch { return ToolHub.failure(error.localizedDescription) }
            return ["content": [["type": "text", "text": "Recorded. Stop working now: end your reply with the reason and the questions. The user decides in the chat."]], "isError": false]
        default: return ToolHub.failure("Unknown tool: " + name)
        }
    }
}

extension Notification.Name {
    // A TODO waits for the user (its result to check, or a decision): ApprovalAlerts shows a macOS notification.
    static let todoNeedsUser = Notification.Name("AIIlluminatiTodoNeedsUser")
}

// Picks and starts TODOs (main thread). Wakes on Start, every 30 minutes, when a chat finishes and when the board
// changes. One of the three answering places stays free for the user's own chats; at most two TODOs at once; an
// account needs 30% of both its 5-hour and weekly usage left to take a TODO.
final class TodoScheduler: ObservableObject {
    static var shared: TodoScheduler?
    static let interval: TimeInterval = 1800
    static let threshold = 30.0
    static let maxTodos = 2
    static let maxAttempts = 2   // retries after an error before the user is asked
    let discussion: Discussion
    let store: TodoStore
    @Published private(set) var nextCheck: Date?
    @Published private(set) var waiting: String?   // why nothing starts although TODOs are ready
    private var timer: Timer?
    private var watching: [AnyCancellable] = []
    private var pending = false
    private var retryAt: [UUID: (at: Date, reason: String)] = [:]   // a TODO whose chat refused to start: not tried again before `at`
    static let retryDelay: TimeInterval = 60
    var held: (String) -> Bool = ProjectWork.isHeld

    init(discussion: Discussion, store: TodoStore) { self.discussion = discussion; self.store = store }

    func start() {
        recover()
        let timer = Timer(timeInterval: Self.interval, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        nextCheck = Date().addingTimeInterval(Self.interval)
        watching = [discussion.$runningRooms.receive(on: DispatchQueue.main).sink { [weak self] _ in self?.wake() },
                    store.$snapshot.receive(on: DispatchQueue.main).sink { [weak self] _ in self?.wake() }]
        wake()
    }

    // ▶ Start now on the board.
    func startNow() { store.startDrafts(); tick() }

    // Once per run of the main loop, however many changes came in.
    func wake() {
        guard !pending else { return }
        pending = true
        DispatchQueue.main.async { self.pending = false; self.tick() }
    }

    // The app quit while TODOs ran: they are ready again, and the next attempt first looks at what is left.
    func recover() {
        try? store.update { data in
            for i in data.items.indices where data.items[i].state == .running {
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

    func tick() {
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
            guard discussion.runningRooms.count + 1 < Discussion.maxRunning, !discussion.importingMaterials else {
                note = L("다른 대화가 답하는 중이라 기다려요.", "Waiting for other chats to finish."); break
            }
            if let retry = retryAt[item.id], retry.at > Date() { note = retry.reason; continue }
            guard data.item(item.id)?.state == .ready, let list = data.list(item.listID), let project = list.project,
                  !data.items.contains(where: { $0.state == .running && data.list($0.listID)?.project?.root == project.root }) else { continue }
            let lock = lock(for: item, list: list, project: project)
            guard let crew = crew(lock: lock) else {
                note = L("남은 사용량이 30% 넘는 Claude/Codex 계정이 없어서 기다려요.", "Waiting for a Claude/Codex account with 30% usage left."); break
            }
            if let reason = begin(item, list: list, project: project, crew: crew, lock: lock) {
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
    func lock(for item: TodoItem, list: TodoList, project: ProjectBinding) -> EnterpriseLock? {
        if let lock = list.lock { return lock }
        let chats = discussion.conversations
        for id in [item.originRoom, item.room].compactMap({ $0 }) { if let lock = chats.first(where: { $0.id == id })?.enterpriseLock { return lock } }
        return chats.first { $0.workspace?.project?.root == project.root && $0.enterpriseLock != nil }?.enterpriseLock
    }

    // Who works and who reviews: Claude/Codex accounts with 30% of both limits left (and allowed by the lock), the
    // most weekly usage first (Enterprise first when close, like AutoPick); the reviewer of the other kind when there is one.
    func crew(lock: EnterpriseLock? = nil) -> (lead: Account, reviewer: Account?)? {
        let usage = discussion.model.latestUsage
        let ready = AutoPick.candidates(discussion.model.accounts, usage: usage, lock: lock)
            .filter { [.claude, .codex].contains($0.provider) && AutoPick.enough(usage[$0.id], threshold: Self.threshold) }
        func score(_ a: Account) -> (Double, Double) { (AutoPick.weekly(usage[a.id]) + (a.isSchool ? AutoPick.enterpriseBonus : 0), AutoPick.fiveHour(usage[a.id])) }
        guard let lead = ready.max(by: { score($0) < score($1) }) else { return nil }
        let others = ready.filter { $0.id != lead.id }
        let reviewer = others.filter { $0.provider != lead.provider }.max { score($0) < score($1) } ?? others.max { score($0) < score($1) }
        return (lead, reviewer)
    }

    // Starts one TODO in its own chat. Returns why it did not start (it stays ready).
    @discardableResult
    func begin(_ item: TodoItem, list: TodoList, project: ProjectBinding, crew: (lead: Account, reviewer: Account?), lock: EnterpriseLock? = nil) -> String? {
        var room = item.room
        // A new chat when there is none, or when its lock is not the TODO's (a chat made before the project was locked).
        if room == nil || discussion.conversations.first(where: { $0.id == room }).map({ $0.enterpriseLock?.organization != lock?.organization }) ?? true {
            room = discussion.addProjectChat(project, title: "TODO · " + item.title, open: false, lock: lock)
        }
        guard let room else { return nil }
        if discussion.runningRooms.contains(room) { return L("TODO 채팅이 아직 답하는 중이라 기다려요.", "Waiting for the TODO's chat to finish answering.") }
        let members = [crew.lead.id] + (crew.reviewer.map { [$0.id] } ?? [])
        discussion.configure(room: room) { c in
            c.mode = 0; c.memberIDs = members; c.leadID = crew.lead.id; c.soloAccountID = members.count == 1 ? crew.lead.id : nil
        }
        let question = Self.question(item)
        // Running before the turn starts: the AI's first tool call must find it.
        do { try store.change(item.id) { $0.state = .running; $0.room = room; $0.lastError = nil; $0.report = nil } } catch { return error.localizedDescription }
        if let reason = discussion.startTurn(room: room, question: question, forced: crew.reviewer == nil ? nil : .work, extra: Self.instruction(item)) {
            try? store.change(item.id) { $0.state = .ready; $0.lastError = reason }
            return reason
        }
        try? store.change(item.id) { $0.interrupted = false }
        return nil
    }

    // A TODO chat stopped answering while its TODO still runs: the AI did not report.
    func settle() {
        for item in store.current.items where item.state == .running {
            guard let room = item.room, !discussion.runningRooms.contains(room) else { continue }
            let turn = discussion.conversation(room).turns.last
            let report = item.report
            if let error = turn?.error {
                // Another chat writing the repository is not the TODO's fault: try again later.
                let busy = error.contains("Another AI is writing") || error.contains("Repository is busy")
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
                let unreviewed = turn?.peerNotes?.contains { $0.failed } == true
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
            if let room = item.room, discussion.runningRooms.contains(room) { continue }
            guard (try? store.change(item.id) { $0.unreported = false }) != nil else { continue }   // not saved: announced later, once
            NotificationCenter.default.post(name: .todoNeedsUser, object: nil, userInfo: ["room": item.room ?? item.originRoom as Any, "title": item.title,
                                                                                         "review": item.state == .review, "body": item.state == .review ? item.result ?? "" : item.question?.reason ?? ""])
        }
    }

    // Stops a running TODO and cancels it.
    func cancel(_ id: UUID) {
        guard let item = store.current.item(id) else { return }
        if item.state == .running {
            try? store.change(id) { $0.state = .cancelled }
            if let room = item.room { discussion.runToken(room)?.cancel() }
        } else { try? store.cancel(id) }
    }

    // What the AI is asked: the TODO, then everything the user said about it since.
    static func question(_ item: TodoItem) -> String {
        var text = "TODO: " + item.title
        if !item.detail.isEmpty { text += "\n\n" + item.detail }
        let said = item.notes.filter { $0.kind == .answer || $0.kind == .feedback }
        if !said.isEmpty {
            text += "\n\n" + L("[내 답과 수정 요청]", "[My answers and change requests]") + "\n"
                + said.map { ($0.kind == .feedback ? L("수정 요청: ", "Change request: ") : L("답: ", "Answer: ")) + $0.text }.joined(separator: "\n")
        }
        if item.interrupted { text += "\n\n" + L("이전 시도가 중간에 끊겼어. git status부터 확인하고 남은 것만 이어서 해.", "The previous attempt was cut off. Check git status first and continue only what is left.") }
        else if item.attempts > 0, let error = item.lastError { text += "\n\n" + L("이전 시도가 오류로 끝났어: ", "The previous attempt ended with an error: ") + String(error.prefix(300)) }
        return text
    }

    static func instruction(_ item: TodoItem) -> String {
        """
        [TODO work] This is a TODO from the user's board, done while the user may be away. Work in this project as usual \
        (plan, change, test, commit and push when the project rules say so).
        When it is finished and tested, call task_done with a summary, the assumptions you made and the files you changed, then end with a short report.
        If you cannot go on (missing information, a decision or an approval only the user can give, contradicting requirements), call task_ask and stop.
        \(item.askFirst ? "Before changing anything, ask with task_ask what is unclear (at most 3 questions, with options and your recommendation). If nothing is unclear, go ahead."
                       : "Where something is unclear, make a reasonable assumption, go on, and list it in task_done.")
        Never publish stable. Do not wait on approval cards: if a step needs the user's approval, call task_ask instead.
        """
    }
}
