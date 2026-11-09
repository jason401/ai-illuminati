import Foundation

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
        let common = project.common as NSString
        if common.lastPathComponent == ".git" { return (common.deletingLastPathComponent as NSString).lastPathComponent }
        return (project.root as NSString).lastPathComponent
    }

    // Chats with a Git project go under their repository; the rest stay in Pinned and Recents. A project with
    // TODO lists but no chat yet still gets its folder (withLists), so its board is one click away.
    static func group(_ chats: [Conversation], todo: TodoData, pinned: Set<String>, withLists: Bool = true) -> (projects: [ProjectGroup], loose: [Conversation]) {
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

    // TODO chats listed in a folder: the ones still going always, the finished ones newest 3 until "show all".
    static func shownTodoRooms(_ rooms: [Conversation], todo: TodoData, all: Bool) -> (shown: [Conversation], hidden: Int) {
        if all { return (rooms, 0) }
        let finished: Set<TodoItem.State> = [.done, .cancelled]
        var kept = 0
        let shown = rooms.filter { room in
            guard let state = todo.items.first(where: { $0.room == room.id })?.state, finished.contains(state) else { return true }
            kept += 1
            return kept <= 3
        }
        return (shown, rooms.count - shown.count)
    }
}

// Folded sections and project folders, and pinned projects: kept on this Mac (UserDefaults.app).
final class SidebarFold: ObservableObject {
    static let shared = SidebarFold(defaults: .app)
    private let defaults: UserDefaults
    @Published private(set) var folded: Set<String>
    @Published private(set) var pinnedProjects: Set<String>
    @Published var allTodoRooms: Set<String> = []   // projects whose finished TODO chats are all listed (until the app quits)
    private static let foldedKey = "sidebar.folded", pinnedKey = "sidebar.pinnedProjects", adoptedKey = "sidebar.pinsAdopted"

    init(defaults: UserDefaults) {
        self.defaults = defaults
        folded = Set(defaults.stringArray(forKey: Self.foldedKey) ?? [])
        pinnedProjects = Set(defaults.stringArray(forKey: Self.pinnedKey) ?? [])
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
    // The TODO board in place of the chat: one project's (a click on its folder) or every project's.
    func openBoard(project: String?) {
        viewingRemote = nil; boardProject = project; viewingBoard = true; sidebarOverlay = false
    }
}
