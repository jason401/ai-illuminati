import Foundation
import AIAccounts
import AILocalization
import AIWorkspace

// The chat sidebar by project: the chats and TODO chats of one Git repository under one folder (like the
// projects of the desktop apps), and which sections and folders the user folded or pinned.

// One repository in the sidebar. Its worktrees share it (the same git common dir); each chat and TODO keeps
// working in its own root.
struct ProjectGroup: Identifiable, Equatable {
    let id: String                     // the repository: ProjectBinding.common (root when unknown)
    var name: String
    var bindings: [ProjectBinding]     // every root of it, newest chat first
    var lists: [UUID]                  // its TODO lists
    var chats: [Conversation]          // its chats (pinned ones first), each with its meetings under it
    var todoRooms: [Conversation]      // the chats its TODOs work in
    var pinned: Bool
    var updatedAt: Date
    static func == (a: ProjectGroup, b: ProjectGroup) -> Bool {
        a.id == b.id && a.name == b.name && a.bindings == b.bindings && a.lists == b.lists && a.pinned == b.pinned
            && a.chats.map(\.id) == b.chats.map(\.id) && a.todoRooms.map(\.id) == b.todoRooms.map(\.id)
    }
}

enum SidebarProjects {
    static func key(_ project: ProjectBinding) -> String { project.common.isEmpty ? project.root : project.common }

    // "AI Illuminati" for …/AI Illuminati/.git, else the root's folder name.
    static func folderName(_ project: ProjectBinding) -> String {
        if project.isFolderless { return L("새 프로젝트", "New project") }
        let common = project.common as NSString
        if common.lastPathComponent == ".git" { return (common.deletingLastPathComponent as NSString).lastPathComponent }
        return (project.root as NSString).lastPathComponent
    }

    // How a root is named in the project picker: on one project's board by its folder; on the whole board by the
    // project's name, with the folder after it when worktrees of one repository share that name.
    static func pickerName(_ option: (name: String, binding: ProjectBinding), among options: [(name: String, binding: ProjectBinding)], board: String?) -> String {
        if option.binding.isFolderless { return option.name }
        let folder = (option.binding.root as NSString).lastPathComponent
        guard board == nil else { return folder }
        let shared = options.filter { $0.name == option.name && $0.binding.root != option.binding.root }
        return shared.isEmpty || folder == option.name ? option.name : option.name + " · " + folder
    }

    // Chats with a Git project go under their repository; the rest stay in Pinned and Recents. A project with
    // TODO lists but no chat yet still gets its folder (withLists), so its board is one click away. A name the user
    // gave the folder (names, ProjectInfoStore.names) comes before its TODO list's title and the folder's own name.
    static func group(_ chats: [Conversation], todo: TodoData, pinned: Set<String>, withLists: Bool = true, names: [String: String] = [:]) -> (projects: [ProjectGroup], loose: [Conversation]) {
        let todoRooms = Set(todo.items.compactMap(\.room))
        var groups: [String: ProjectGroup] = [:]
        var loose: [Conversation] = []
        func add(_ project: ProjectBinding, name: String?, at date: Date) {
            let id = key(project)
            var g = groups[id] ?? ProjectGroup(id: id, name: name ?? folderName(project), bindings: [], lists: [], chats: [], todoRooms: [],
                                               pinned: pinned.contains(id), updatedAt: .distantPast)
            if let name, !name.isEmpty { g.name = name }
            if !g.bindings.contains(where: { $0.root == project.root }) { g.bindings.append(project) }
            g.updatedAt = max(g.updatedAt, date)
            groups[id] = g
        }
        for chat in chats.sorted(by: newerFirst) {
            guard let project = chat.workspace?.project else { loose.append(chat); continue }
            add(project, name: nil, at: chat.updatedAt)
            if todoRooms.contains(chat.id) { groups[key(project)]!.todoRooms.append(chat) } else { groups[key(project)]!.chats.append(chat) }
        }
        for list in todo.lists {
            guard let project = list.project, withLists || groups[key(project)] != nil else { continue }
            let latest = todo.items.filter { $0.listID == list.id }.map(\.updatedAt).max() ?? .distantPast
            add(project, name: list.title, at: latest)
            groups[key(project)]!.lists.append(list.id)
        }
        for (id, name) in names where groups[id] != nil { groups[id]!.name = name }
        for id in groups.keys { groups[id]!.chats.sort { ($0.pinned == true) != ($1.pinned == true) ? $0.pinned == true : newerFirst($0, $1) } }
        let projects = groups.values.sorted { a, b in
            if a.pinned != b.pinned { return a.pinned }
            if a.updatedAt != b.updatedAt { return a.updatedAt > b.updatedAt }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending || (a.name == b.name && a.id < b.id)
        }
        let pinnedFirst = loose.filter { $0.pinned == true } + loose.filter { $0.pinned != true }
        return (projects, pinnedFirst)
    }

    private static func newerFirst(_ a: Conversation, _ b: Conversation) -> Bool {
        a.updatedAt != b.updatedAt ? a.updatedAt > b.updatedAt : a.id.uuidString < b.id.uuidString
    }

    // TODO chats in a folder: the ones still going (or waiting for the user) always listed; the finished ones
    // (every TODO of the chat done or cancelled) go together under one "Finished TODOs" row, folded by default.
    static func todoRooms(_ rooms: [Conversation], todo: TodoData) -> (going: [Conversation], finished: [Conversation]) {
        let finishedStates: Set<TodoItem.State> = [.done, .cancelled]
        var going: [Conversation] = [], finished: [Conversation] = []
        for room in rooms {
            let states = todo.items.filter { $0.room == room.id }.map(\.state)
            if !states.isEmpty && states.allSatisfy(finishedStates.contains) { finished.append(room) } else { going.append(room) }
        }
        return (going, finished)
    }

    // A folder's rows with the chats answering now (its own or its TODOs') lifted to the top, in the folder's order;
    // the rest keep their places (going TODO chats, its chats, finished TODO chats).
    static func runningFirst(_ group: ProjectGroup, todo: TodoData, running: Set<UUID>)
        -> (running: [Conversation], going: [Conversation], chats: [Conversation], finished: [Conversation]) {
        let rooms = todoRooms(group.todoRooms, todo: todo)
        let lifted = (rooms.going + group.chats + rooms.finished).filter { running.contains($0.id) }
        let rest = { (rows: [Conversation]) in rows.filter { !running.contains($0.id) } }
        return (lifted, rest(rooms.going), rest(group.chats), rest(rooms.finished))
    }

    // Finished TODO chats that may be deleted: every TODO of the chat done or cancelled, not pinned, not protected
    // (running, open, or the parent of the open meeting), and, with a cutoff, nothing in it (the chat, its TODOs'
    // finishing, its meetings) newer than the cutoff. The TODOs stay on the board as the record.
    static func deletable(_ rooms: [Conversation], todo: TodoData, meetings: (UUID) -> [Conversation] = { _ in [] },
                          before cutoff: Date? = nil, protected: Set<UUID> = []) -> [Conversation] {
        let finishedStates: Set<TodoItem.State> = [.done, .cancelled]
        return rooms.filter { room in
            let items = todo.items.filter { $0.room == room.id }
            guard !items.isEmpty, items.allSatisfy({ finishedStates.contains($0.state) }), room.pinned != true, !protected.contains(room.id) else { return false }
            guard let cutoff else { return true }
            let last = ([room.updatedAt] + items.map { $0.finishedAt ?? $0.updatedAt } + meetings(room.id).map(\.updatedAt)).max()!
            return last < cutoff
        }
    }
}

// Folded sections and project folders, and pinned projects: kept on this Mac (UserDefaults.app).
final class SidebarFold: ObservableObject {
    static let shared = SidebarFold(defaults: .app)
    private let defaults: UserDefaults
    @Published private(set) var folded: Set<String>
    @Published private(set) var pinnedProjects: Set<String>
    @Published private(set) var openFinished: Set<String>   // projects whose "Finished TODOs" row is unfolded
    @Published var dropProject: String?             // the project folder a dragged chat is over
    private static let foldedKey = "sidebar.folded", pinnedKey = "sidebar.pinnedProjects", openFinishedKey = "sidebar.openFinishedTodos", adoptedKey = "sidebar.pinsAdopted"

    init(defaults: UserDefaults) {
        self.defaults = defaults
        folded = Set(defaults.stringArray(forKey: Self.foldedKey) ?? [])
        pinnedProjects = Set(defaults.stringArray(forKey: Self.pinnedKey) ?? [])
        openFinished = Set(defaults.stringArray(forKey: Self.openFinishedKey) ?? [])
    }

    // Long lists (Recents, each Mac under Other Macs) show the newest page; "Show more" adds a page.
    // Kept in memory only: a restart starts short again.
    // A project folder's own chats (not its TODO chats) too: pinned ones always, then the newest page.
    static let recentsPage = 10, devicePage = 5, projectPage = 5
    @Published private(set) var listLimits: [String: Int] = [:]
    func limit(_ key: String, page: Int) -> Int { listLimits[key] ?? page }
    func showMore(_ key: String, page: Int) { listLimits[key] = limit(key, page: page) + page }
    func showLess(_ key: String) { listLimits[key] = nil }

    // The first `limit` rows, plus the open one when it is further down (only it, so "Show less" still shortens).
    static func listed<Row: Identifiable>(_ rows: [Row], limit: Int, open: Row.ID?) -> [Row] {
        rows.enumerated().filter { $0.offset < limit || $0.element.id == open }.map(\.element)
    }
    static func listedChats(_ chats: [Conversation], limit: Int, open: UUID?) -> (rows: [Conversation], unpinned: Int, listed: Int) {
        let pinned = chats.filter { $0.pinned == true }, rest = chats.filter { $0.pinned != true }
        let listed = Self.listed(rest, limit: limit, open: open)
        return (pinned + listed, rest.count, listed.count)
    }

    func toggleFinished(_ project: String) {
        if openFinished.contains(project) { openFinished.remove(project) } else { openFinished.insert(project) }
        defaults.set(openFinished.sorted(), forKey: Self.openFinishedKey)
    }

    func isFolded(_ key: String) -> Bool { folded.contains(key) }
    func toggle(_ key: String) {
        if folded.contains(key) { folded.remove(key) } else { folded.insert(key) }
        defaults.set(folded.sorted(), forKey: Self.foldedKey)
    }

    func isPinned(_ project: String) -> Bool { pinnedProjects.contains(project) }
    func togglePin(_ project: String) {
        if pinnedProjects.contains(project) { pinnedProjects.remove(project) } else { pinnedProjects.insert(project) }
        defaults.set(pinnedProjects.sorted(), forKey: Self.pinnedKey)
    }

    // A deleted project: its pin, fold and tab are forgotten (a folder linked again starts fresh).
    func forget(_ project: String) {
        pinnedProjects.remove(project); folded.remove("project." + project); openFinished.remove(project)
        defaults.set(pinnedProjects.sorted(), forKey: Self.pinnedKey)
        defaults.set(folded.sorted(), forKey: Self.foldedKey)
        defaults.set(openFinished.sorted(), forKey: Self.openFinishedKey)
        var tabs = defaults.dictionary(forKey: BoardTab.key) ?? [:]
        if tabs.removeValue(forKey: project) != nil { defaults.set(tabs, forKey: BoardTab.key) }
    }

    // A project that got a new key (its work folder disconnected) keeps its pin, fold and tab.
    func rekey(_ old: String, to new: String) {
        if pinnedProjects.remove(old) != nil { pinnedProjects.insert(new) }
        if folded.remove("project." + old) != nil { folded.insert("project." + new) }
        if openFinished.remove(old) != nil { openFinished.insert(new) }
        defaults.set(pinnedProjects.sorted(), forKey: Self.pinnedKey)
        defaults.set(folded.sorted(), forKey: Self.foldedKey)
        defaults.set(openFinished.sorted(), forKey: Self.openFinishedKey)
        var tabs = defaults.dictionary(forKey: BoardTab.key) ?? [:]
        if let tab = tabs.removeValue(forKey: old) { tabs[new] = tab; defaults.set(tabs, forKey: BoardTab.key) }
    }

    // Once, when the sidebar first groups by project: a pinned project chat pins its project's folder (the chat
    // stays pinned too, at the top inside its folder).
    func adoptPins(_ chats: [Conversation]) {
        guard !defaults.bool(forKey: Self.adoptedKey) else { return }
        for chat in chats where chat.pinned == true { if let project = chat.workspace?.project { pinnedProjects.insert(SidebarProjects.key(project)) } }
        defaults.set(pinnedProjects.sorted(), forKey: Self.pinnedKey)
        defaults.set(true, forKey: Self.adoptedKey)
    }
}

extension SidebarProjects {
    // What waits for the user in these lists (the folder's count), like TodoStore.waitingForUser for all.
    static func waiting(_ todo: TodoData, lists: [UUID]) -> Int {
        todo.items.filter { lists.contains($0.listID) && ($0.state == .needsYou || $0.state == .review) }.count
    }
}

extension Discussion {
    // The TODO board in place of the chat: one project's (a click on its folder) or every project's. A project's
    // opens on the tab the user last chose for it (Project info the first time); `tab` asks for one.
    func openBoard(project: String?, tab: BoardTab? = nil) {
        viewingRemote = nil; viewingSpace = nil; boardProject = project; viewingBoard = true; sidebarOverlay = false
        if let project { showBoardTab(tab ?? BoardTab.saved(project) ?? .info) } else { boardTab = .todo }
    }
    func showBoardTab(_ tab: BoardTab) {
        boardTab = tab
        if let project = boardProject { BoardTab.save(tab, for: project) }
    }
}

// The two tabs of a project folder: what belongs to the project, and its TODOs.
enum BoardTab: String {
    case info, todo
    static let key = "sidebar.projectTabs"
    static func saved(_ project: String) -> BoardTab? {
        (UserDefaults.app.dictionary(forKey: key)?[project] as? String).flatMap(BoardTab.init(rawValue:))
    }
    static func save(_ tab: BoardTab, for project: String) {
        var all = UserDefaults.app.dictionary(forKey: key) ?? [:]
        all[project] = tab.rawValue
        UserDefaults.app.set(all, forKey: key)
    }
}

// Dragging a chat onto a project folder (or "Move to project" in its menu) links it to that project, like
// "Link folder" does: its other linked files stay, an earlier project's root goes.
extension SidebarProjects {
    static let dragPrefix = "ai-illuminati-chat:"

    // The project's Enterprise lock, if its chats or TODO lists have one (as a new chat in it gets).
    static func lock(of group: ProjectGroup, todo: TodoData) -> EnterpriseLock? {
        (group.chats + group.todoRooms).first { $0.enterpriseLock != nil }?.enterpriseLock
            ?? todo.lists.first { group.lists.contains($0.id) && $0.lock != nil }?.lock
    }

    // Why this chat cannot go into this project (nil: it can). mode: the chat's mode (project work is plain chat only).
    static func moveRefusal(_ chat: Conversation, into group: ProjectGroup, todo: TodoData, running: Bool, mode: Int) -> String? {
        guard group.bindings.first != nil else { return L("이 프로젝트에는 연결할 폴더가 없어요.", "This project has no folder to link.") }
        if let project = chat.workspace?.project, key(project) == group.id { return L("이미 이 프로젝트에 있어요.", "Already in this project.") }
        if chat.meetingOf != nil { return L("회의 기록은 옮길 수 없어요.", "Meeting records cannot be moved.") }
        if todo.items.contains(where: { $0.room == chat.id }) { return L("TODO 작업방은 그 TODO의 프로젝트에 남아요.", "A TODO chat stays in its TODO's project.") }
        if running { return L("답하는 중에는 옮길 수 없어요. 끝난 뒤 다시 해 주세요.", "Cannot move a chat while it answers. Try again when it is done.") }
        if mode != 0 { return L("프로젝트에는 일반 대화만 넣을 수 있어요.", "Only plain chats can go into a project.") }
        if chat.enterpriseLock?.organization != lock(of: group, todo: todo)?.organization {
            return L("Enterprise 대화와 일반 대화는 서로의 프로젝트로 옮길 수 없어요.", "Enterprise and open chats cannot move into each other's projects.")
        }
        return nil
    }

    // The chat's link after the move: the project's newest root, writable, plus what else it had linked.
    static func moved(_ workspace: WorkspaceBinding?, to project: ProjectBinding) -> WorkspaceBinding {
        var binding = workspace ?? WorkspaceBinding(roots: [])
        let old = binding.project?.root
        binding.roots.removeAll { $0.path == old || $0.path == project.root }
        binding.roots.insert(contentsOf: project.linkedRoots, at: 0)
        binding.project = project
        binding.projectRunID = nil; binding.projectGeneration = nil
        return binding
    }
}
