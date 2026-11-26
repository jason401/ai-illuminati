import AppKit
import AIAccounts
import AILocalization
import AIChatRecords
import AIProjects

// The iPhone page's view of the chats (the App serves it through AIRemote): the sidebar's sections in its order,
// one chat's messages and approval cards, and a message sent the way the message box sends it. Values are plain
// JSON (strings, numbers, arrays), so the page and the server need no chat type.
public enum RemoteChats {
    // Working, Needs review, Pinned, Projects (each folder with its newest chats), Recents, like ChatView's sidebar.
    // Long lists start at the sidebar's page; `limits` (the phone's "Show more") lengthens one by its key. A shortened
    // list carries "more": its key, page, how many it has and how many are left out. The sections the Mac folds and each
    // project folder carry "fold" (the sidebar's key) and "folded": one state with the Mac's sidebar (SidebarFold), so
    // every page of this Mac (Safari, the Home Screen app, another Mac's panel) shows the same and nothing is lost when
    // a browser's storage is.
    public static func list(_ d: Discussion, limits: [String: Int] = [:]) -> [[String: Any]] {
        func limit(_ key: String, _ page: Int) -> Int { max(limits[key] ?? page, page) }
        func more(_ key: String, page: Int, total: Int, listed: Int) -> [String: Any]? {
            total > page ? ["key": key, "page": page, "total": total, "hidden": total - listed] : nil
        }
        let todo = TodoStore.shared.snapshot, names = ProjectInfoStore.shared.names
        let waiting = Dictionary(grouping: ProjectCenter.shared.requests, by: \.room).mapValues(\.count)
        func row(_ chat: Conversation, depth: Int = 0, detail: String? = nil) -> [String: Any] {
            var row: [String: Any] = ["id": chat.id.uuidString, "title": chat.title, "depth": depth,
                                      "working": d.runningRooms.contains(chat.id), "unread": d.unreadRooms[chat.id] != nil]
            if let detail { row["detail"] = detail }
            if let count = waiting[chat.id] { row["approvals"] = count }
            if chat.pinned == true { row["pinned"] = true }
            if d.runningRooms.contains(chat.id), let by = chat.turns.last?.partialBy ?? chat.turns.last?.finalBy, let c = colors(by) { row["color"] = c }
            return row
        }
        var sections: [[String: Any]] = []
        let folds = SidebarFold.shared
        func add(_ title: String, _ rows: [[String: Any]], more: [String: Any]? = nil, fold: String? = nil) {
            guard !rows.isEmpty else { return }
            var section: [String: Any] = ["title": title, "chats": rows]
            if let more { section["more"] = more }
            if let fold { section["fold"] = fold; section["folded"] = folds.isFolded(fold) }
            sections.append(section)
        }
        add(L("작업 중", "Working"), WorkingChats.list(conversations: d.conversations, running: d.runningRooms, stopping: d.stoppingRooms,
                                                     todo: todo, names: names).map { row($0.conversation, detail: $0.project) }, fold: "working")
        let unread = UnreadChats.list(conversations: d.conversations, unread: d.unreadRooms, running: d.runningRooms, todo: todo, names: names)
        let unreadListed = unread.prefix(limit("unread", SidebarFold.projectPage))
        add(L("확인 필요", "Needs review"), unreadListed.map { row($0.conversation, detail: $0.project) },
            more: more("unread", page: SidebarFold.projectPage, total: unread.count, listed: unreadListed.count))
        let grouped = SidebarProjects.group(d.listedConversations.filter(\.hasContent), todo: todo, pinned: SidebarFold.shared.pinnedProjects, names: names)
        add(L("고정됨", "Pinned"), grouped.loose.filter { $0.pinned == true }.map { row($0) }, fold: "pinned")
        add(L("프로젝트", "Projects"), grouped.projects.flatMap { group -> [[String: Any]] in
            let rooms = SidebarProjects.runningFirst(group, todo: todo, running: d.runningRooms)
            let key = "project." + group.id, page = SidebarFold.projectPage
            let listed = SidebarFold.listedChats(rooms.chats, limit: limit(key, page), open: nil)
            let chats = rooms.running + rooms.going + listed.rows
            var folder: [String: Any] = ["folder": group.name, "id": key, "project": group.id, "fold": key, "folded": folds.isFolded(key)]
            if let more = more(key, page: page, total: listed.unpinned, listed: listed.listed) { folder["more"] = more }
            let count = group.chats.reduce(0) { $0 + (waiting[$1.id] ?? 0) }
            if count > 0 { folder["approvals"] = count }
            return [folder] + chats.map { row($0, depth: 1) }
        }, fold: "projects")
        let recents = grouped.loose.filter { $0.pinned != true }, recentsListed = recents.prefix(limit("recents", SidebarFold.recentsPage))
        add(L("최근", "Recents"), recentsListed.map { row($0) },
            more: more("recents", page: SidebarFold.recentsPage, total: recents.count, listed: recentsListed.count), fold: "recents")
        return sections
    }

    // Folds or unfolds a section or project folder from the phone, in the Mac's sidebar too. Only the keys `list` gives.
    public static func fold(_ key: String, folded: Bool) -> Bool {
        guard ["working", "pinned", "projects", "recents"].contains(key) || key.hasPrefix("project.") else { return false }
        if SidebarFold.shared.isFolded(key) != folded { SidebarFold.shared.toggle(key) }
        return true
    }

    // The inbox's 🔴 and 🟡 (Inbox.make, the Mac panel's lists), each with its name, one line, the time left and the chat it
    // opens. A chat's approval carries its id and detail for the page's Allow/Deny (POST /api/approval, like a chat's card);
    // the rest are answered in their chat (a TODO's through the message box, sendToTodo). An outside MCP tool only counts
    // down (its macOS notification is the way to answer).
    public static func inbox(_ d: Discussion, now: Date = Date()) -> [[String: Any]] {
        let center = ProjectCenter.shared, todo = TodoStore.shared.snapshot, names = ProjectInfoStore.shared.names
        let inbox = Inbox.make(requests: center.requests, expired: center.expired, todos: todo, conversations: d.conversations,
                               unread: d.unreadRooms, running: d.runningRooms, names: names)
        func chat(_ room: UUID?) -> String? { room.flatMap { r in d.conversations.contains { $0.id == r } ? r.uuidString : nil } }
        func entry(_ id: UUID, _ level: String, _ kind: String, name: String, line: String, time: String?, room: String?) -> [String: Any] {
            var row: [String: Any] = ["id": id.uuidString, "level": level, "kind": kind, "name": name.isEmpty ? L("새 대화", "New chat") : name, "line": line]
            if let time { row["time"] = time }
            if let room { row["room"] = room }
            return row
        }
        let blocked = inbox.blocked.map { item -> [String: Any] in
            switch item {
            case .approval(let r) where r.alwaysAllow != nil:
                return entry(r.id, "red", "outside", name: L("외부 도구 허가", "Outside tool approval"), line: r.title,
                             time: ApprovalBanner.approvalLeft(r, now: now), room: nil)
            case .approval(let r):
                let home = d.approvalHome(r.room)
                var row = entry(r.id, "red", "approval", name: d.approvalChatName(home), line: L("허가 · ", "Approval · ") + r.title,
                                time: r.deadline == nil ? nil : ApprovalBanner.approvalLeft(r, now: now), room: chat(home))
                row["approval"] = r.id.uuidString; row["detail"] = r.detail
                return row
            case .expired(let r):
                return entry(r.id, "red", "expired", name: d.approvalChatName(r.room), line: L("허가 기한 지남 · 거절로 처리됨 · ", "Approval timed out · denied · ") + r.title,
                             time: nil, room: chat(r.room))
            case .todo(let t):
                let due = TodoScheduler.shared?.standingIn.contains(t.id) == true ? L("다른 AI가 대신 답하는 중", "Another AI is answering")
                    : ApprovalBanner.todoDue(t, data: todo, discussion: d).map { ApprovalBanner.todoLeft($0, now: now) }
                return entry(t.id, "red", "todo", name: Inbox.projectName(t, todos: todo, names: names),
                             line: (t.isParked ? L("TODO 결정 필요 · 보류됨 · ", "TODO needs you · parked · ") : L("TODO 결정 필요 · ", "TODO needs you · ")) + t.title,
                             time: due, room: chat(t.room))
            }
        }
        let check = inbox.check.map { item -> [String: Any] in
            switch item {
            case .todo(let t):
                return entry(t.id, "yellow", "review", name: Inbox.projectName(t, todos: todo, names: names), line: L("TODO 결과 확인 · ", "TODO result · ") + t.title,
                             time: nil, room: chat(t.room))
            case .failed(let c):
                return entry(c.id, "yellow", "failed", name: c.conversation.title,
                             line: L("작업 실패", "Failed") + (Inbox.line(c.conversation.turns.last?.error).map { " · " + $0 } ?? ""), time: nil, room: c.id.uuidString)
            }
        }
        return blocked + check
    }

    // One chat as the page shows it: the user's messages and each AI's answer (the reply so far while it writes),
    // with picture links (/api/image/<chat>/<picture>) and the approval cards waiting in it. Opening it counts as seen.
    public static func chat(_ d: Discussion, _ room: UUID, opened: Bool) -> [String: Any]? {
        guard let chat = d.conversations.first(where: { $0.id == room }) else { return nil }
        if opened { d.markSeen(room) }
        let working = d.runningRooms.contains(room)
        func link(_ image: ChatImage) -> String { "/api/image/\(room.uuidString)/\(image.id.uuidString)" }
        func links(_ images: [ChatImage]?) -> [String] { (images ?? []).map(link) }
        // An answer's pictures as the Mac draws them: those with a marker line in the text go there ("places": N → link),
        // the rest are listed under it ("images").
        func pictures(_ images: [ChatImage]?, _ text: String) -> [String: Any] {
            let placed = ChatMarkdown.placedPictures(text)
            var places: [String: String] = [:], loose: [String] = []
            for image in images ?? [] {
                let number = image.name.hasPrefix("picture-") && image.name.hasSuffix(".png") ? Int(image.name.dropFirst(8).dropLast(4)) : nil
                if let number, placed.contains(image.name) { places[String(number)] = link(image) } else { loose.append(link(image)) }
            }
            return places.isEmpty ? ["images": loose] : ["images": loose, "places": places]
        }
        var turns: [[String: Any]] = []
        var lastDay: Date?
        for (index, turn) in chat.turns.enumerated() {
            let last = index == chat.turns.count - 1
            // The day line above the first message of each day, like the Mac's transcript (ChatView.dayLine).
            var day: String?
            if let when = ChatTime.when(turn, last: last, updatedAt: chat.updatedAt) {
                if lastDay.map({ !Calendar.current.isDate($0, inSameDayAs: when) }) ?? true { day = ChatTime.day(when) }
                lastDay = when
            }
            if !turn.question.isEmpty || !(turn.images ?? []).isEmpty {
                var mine: [String: Any] = ["key": turn.id.uuidString + ".q", "mine": true, "text": turn.question, "images": links(turn.images)]
                if let asked = turn.askedAt { mine["time"] = ChatTime.stamp(asked) }
                if let line = day { mine["day"] = line; day = nil }
                turns.append(mine)
            }
            var answers: [[String: Any]] = []
            if let final = turn.final {
                answers.append(pictures(ChatMarkdown.finalPictures(turn, final: final), final).merging(["name": turn.finalBy ?? "AI", "text": final]) { a, _ in a })
            } else if turn.mode != 0, let last = turn.entries.last(where: { !$0.failed }) {
                answers.append(pictures(last.images, last.text).merging(["name": last.speaker, "text": last.text]) { a, _ in a })
            }
            for more in turn.mode == 0 ? turn.moreAnswers ?? [] : [] {
                answers.append(pictures(more.images, more.text).merging(["name": more.speaker, "text": more.text, "error": more.failed ? more.text : NSNull()]) { a, _ in a })
            }
            if let partials = turn.partials, turn.final == nil {
                for name in turn.answerOrder ?? partials.keys.sorted() { if let text = partials[name], !text.isEmpty { answers.append(["name": name, "text": text, "waiting": true]) } }
            } else if let partial = turn.partial, !partial.isEmpty {
                answers.append(["name": turn.partialBy ?? "AI", "text": partial, "waiting": true])
            }
            if answers.isEmpty, last, working {
                answers.append(["name": turn.partialBy ?? (turn.status.isEmpty ? "AI" : turn.status), "text": "", "waiting": true])
            }
            if let error = turn.error {
                if answers.isEmpty { answers.append(["name": "AI", "text": ""]) }
                answers[answers.count - 1]["error"] = error
            }
            // Each answer: who wrote it in that AI's colors (light, dark), when it finished, and what it does now.
            let answered = (turn.answeredAt ?? (last && turn.askedAt == nil && turn.final != nil ? chat.updatedAt : nil)).map { ChatTime.stamp($0) }
            for (n, answer) in answers.enumerated() {
                var row = answer.merging(["mine": false, "key": turn.id.uuidString + ".a\(n)"]) { a, _ in a }
                if let name = answer["name"] as? String, let c = colors(name) { row["color"] = c }
                if let model = turn.finalModel, n == 0, turn.final != nil { row["model"] = model }
                if n == answers.count - 1 {
                    if let answered, answer["waiting"] == nil { row["time"] = answered }
                    if last, working, !turn.status.isEmpty {
                        row["status"] = turn.waitingApproval == true ? L("승인 대기 중 · 아래 카드에서 허용하거나 거절하세요", "Waiting for your approval · allow or deny below")
                            : turn.activity ?? turn.status
                        if turn.waitingApproval == true { row["approval"] = true }
                        if let asked = turn.askedAt { row["since"] = Int(asked.timeIntervalSince1970) }
                    }
                }
                if n == 0, let line = day { row["day"] = line }   // a turn with no message of its own
                turns.append(row)
            }
        }
        for (n, queued) in (chat.queued ?? []).enumerated() {
            turns.append(["key": "queued.\(n).\(queued.text.hashValue)", "mine": true, "text": queued.text, "images": links(queued.images), "waiting": true])
        }
        let approvals = ProjectCenter.shared.requests.filter { $0.room == room }
            .map { ["id": $0.id.uuidString, "title": $0.title, "detail": $0.detail] }
        var result: [String: Any] = ["id": room.uuidString, "title": chat.title, "working": working, "turns": turns, "approvals": approvals,
                                     "readOnly": chat.meetingOf != nil]
        if let project = WorkingChats.projectName(chat, todo: TodoStore.shared.snapshot, names: ProjectInfoStore.shared.names) { result["project"] = project }
        result["notes"] = notes(room)
        let plain = Discussion.modernModes && d.configuration(of: room).mode == 0 && chat.meetingOf == nil
        return result.merging(picks(d, plain: plain, project: chat.workspace?.project != nil, lock: chat.enterpriseLock)) { a, _ in a }
    }

    // A project folder's "Project info" as the phone page shows it, only to read (ProjectInfoView on the Mac, which also
    // changes it): the repository and its worktrees, the rules files the AIs get, the folders and files (★ work folder,
    // read, edited or off), the links, the project memory's notes in use, the folders linked to one chat only, the lock,
    // and the TODOs left (the panel beside the Mac's tab). nil for an unknown project.
    public static func projectInfo(_ d: Discussion, project: String) -> [String: Any]? {
        guard let group = projectGroups(d).first(where: { $0.id == project }) else { return nil }
        let todo = TodoStore.shared.snapshot, store = ProjectInfoStore.shared
        let info = store.snapshot.projects[project] ?? ProjectInfo()
        let first = group.bindings.first, folderless = first?.isFolderless == true, documents = first?.isDocuments == true
        let fm = FileManager.default
        func path(_ p: String) -> String { (p as NSString).abbreviatingWithTildeInPath }
        var result: [String: Any] = ["id": project, "name": group.name, "chats": group.chats.count,
                                     "kind": folderless ? "folderless" : documents ? "documents" : "git"]
        if !folderless {
            result["repository"] = group.bindings.map { binding -> [String: Any] in
                var row: [String: Any] = ["path": path(binding.root), "worktree": binding.root != first?.root]
                if !binding.remoteURL.isEmpty {
                    row["remote"] = (binding.remote.isEmpty ? "" : binding.remote + " · ") + ProjectInfoStore.shownRemote(binding.remoteURL)
                }
                return row
            }
            result["rules"] = (first.map { ProjectRules.read(root: $0.root).parts } ?? []).map { part -> [String: Any] in
                var row: [String: Any] = ["name": part.file.lastPathComponent, "path": path(part.file.path), "text": ProjectRules.preview(part)]
                if let note = ProjectRules.note(part) { row["note"] = note }
                return row
            }
        }
        // The same rows as the Mac's "Folders and files": the ★ work folder, the folders and files read, those turned off.
        let (active, others) = d.workFolders(project)
        func folder(_ p: String, directory: Bool, kind: String, writable: Bool) -> [String: Any] {
            let exists = fm.fileExists(atPath: p), work = kind == "work"
            let git = work ? !documents : directory && exists && ProjectInfoStore.isGit(p)
            return ["name": (p as NSString).lastPathComponent, "path": path(p), "kind": kind, "exists": exists, "writable": work || writable, "directory": directory,
                    "badge": !directory ? L("파일", "File") : git ? "Git" : work && documents ? L("문서", "Documents") : L("폴더", "Folder")]
        }
        result["folders"] = (active.map { [folder($0, directory: true, kind: "work", writable: true)] } ?? [])
            + info.folders.filter { $0.path != active }.map { folder($0.path, directory: $0.directory, kind: "read", writable: $0.writable == true) }
            + others.filter { p in !info.folders.contains { $0.path == p } }.map { folder($0, directory: true, kind: "off", writable: false) }
        result["links"] = info.links.map { ["title": $0.title, "url": $0.url] }
        // Project memory: the notes in use, newest first, a kind at a time; the work log only its newest lines.
        let notes = ProjectMemoryStore.shared.notes(project)
        let inUse = notes.filter { $0.state == .active }.sorted { $0.createdAt > $1.createdAt }
        result["memory"] = ProjectMemoryNote.Kind.allCases.map { kind -> [String: Any] in
            let all = inUse.filter { $0.kind == kind }, page = kind == .log ? 10 : 50
            return ["kind": kind.rawValue, "total": all.count, "notes": all.prefix(page).map { note -> [String: Any] in
                ["text": note.text, "by": note.by ?? "", "verified": note.verified, "date": ChatTime.day(note.createdAt)]
            }]
        }
        result["archived"] = notes.filter { $0.state == .archived }.count
        var chatOnly: [(path: String, directory: Bool, chats: [String])] = []
        let own = Set(group.bindings.map(\.root)).union(info.folders.map(\.path))
        for chat in group.chats + group.todoRooms {
            for root in chat.workspace?.roots ?? [] where !own.contains(root.path) {
                if let i = chatOnly.firstIndex(where: { $0.path == root.path }) { chatOnly[i].chats.append(chat.title) }
                else { chatOnly.append((root.path, root.directory, [chat.title])) }
            }
        }
        result["chatOnly"] = chatOnly.map { ["name": ($0.path as NSString).lastPathComponent, "path": path($0.path), "exists": fm.fileExists(atPath: $0.path),
                                             "chats": $0.chats.prefix(2).joined(separator: ", ") + ($0.chats.count > 2 ? " …" : "")] }
        if let lock = SidebarProjects.lock(of: group, todo: todo) {
            let left = d.unlockedParts(group.id, todos: todo)
            result["lock"] = ["personal": lock.isPersonal, "name": lock.name, "chatsLeft": left.chats, "listsLeft": left.lists]
        }
        // The TODOs left, yours first (needs you, check), then the rest in the board's order.
        let lists = todo.lists.filter { $0.project.map(SidebarProjects.key) == project }
        let open = lists.flatMap { todo.ordered($0.id) }.filter { $0.state != .done && $0.state != .cancelled }
        let mine = open.filter { $0.state == .needsYou || $0.state == .review }
        result["todos"] = (mine + open.filter { $0.state != .needsYou && $0.state != .review }).map { item -> [String: Any] in
            ["title": item.title, "state": item.state.rawValue, "label": item.state.title, "yours": item.state == .needsYou || item.state == .review]
        }
        return result
    }

    // The chat's notes (the Mac's 메모 panel, ChatNotes): what the Mac's panel holds now when it shows this chat, typing
    // not yet saved included, else the saved file. Read without saving, since the page asks for them every poll.
    static func notes(_ room: UUID) -> String {
        ChatNotes.shared.room == room ? ChatNotes.shared.text : ChatNotes.load(room)
    }

    // Notes edited on the phone: into the Mac's open panel when it shows this chat (so its next save keeps them), else
    // the file. Only the user writes them (the AIs only read). Returns why they were not saved.
    public static func saveNotes(_ d: Discussion, room: UUID, text: String) -> String? {
        guard d.host == nil, d.conversations.contains(where: { $0.id == room }) else { return L("대화를 찾지 못했어요.", "Chat not found.") }
        if ChatNotes.shared.room == room { ChatNotes.shared.text = text; ChatNotes.shared.flush() } else { ChatNotes.save(text, room: room) }
        return nil
    }

    // What the page's message box lists while @ or a first "/" is typed, as the Mac's does: "mentions" the accounts this
    // chat may call (Discussion.mentionable, narrowed on the page by `keys` and `names` as mentionMatches does) with their
    // colors and usage, "routes" the ways it offers (RouteChoice.offered) with the words that pick them. Empty in a
    // meeting record and the team modes, where the Mac shows neither.
    static func picks(_ d: Discussion, plain: Bool, project: Bool, lock: EnterpriseLock?) -> [String: Any] {
        guard plain else { return ["mentions": [Any](), "routes": [Any]()] }
        let mentions = Discussion.mentionable(d.model.accounts, lock: lock, localEnabled: d.model.localEnabled).map { account -> [String: Any] in
            let label = d.label(account)
            var row: [String: Any] = ["id": account.id, "label": label, "keys": [label.lowercased(), account.name.lowercased()],
                                      "names": Discussion.aiNames[account.provider] ?? [], "usage": AutoPick.describe(d.model.latestUsage[account.id])]
            if let c = colors(account.provider) { row["color"] = c }
            return row
        }
        let routes = RouteChoice.offered(project: project).map { choice -> [String: Any] in
            ["word": Route.words(choice).first ?? "", "words": Route.words(choice), "title": choice.title, "hint": Route.hint(choice)]
        }
        return ["mentions": mentions, "routes": routes]
    }

    // The lists for a new chat's message box (GET /api/chat/new?project=): a plain chat, locked like the project's new chat.
    public static func composer(_ d: Discussion, project: String?) -> [String: Any] {
        let group = project.flatMap { id in projectGroups(d).first { $0.id == id } }
        return picks(d, plain: Discussion.modernModes, project: group != nil,
                     lock: group.flatMap { SidebarProjects.lock(of: $0, todo: TodoStore.shared.snapshot) })
    }
    static func projectGroups(_ d: Discussion) -> [ProjectGroup] {
        SidebarProjects.group(d.listedConversations.filter(\.hasContent), todo: TodoStore.shared.snapshot, pinned: SidebarFold.shared.pinnedProjects,
                              names: ProjectInfoStore.shared.names).projects
    }

    // An AI's colors as the Mac shows them (AIColors, which the user may change): ["#light", "#dark"].
    static func colors(_ speaker: String) -> [String]? { Account.Provider.of(speaker: speaker).flatMap(colors) }
    static func colors(_ provider: Account.Provider) -> [String]? {
        let color = AIColors.color(provider)
        return [false, true].map { dark in
            var hex = "#888888"
            NSAppearance(named: dark ? .darkAqua : .aqua)?.performAsCurrentDrawingAppearance {
                if let c = color.usingColorSpace(.sRGB) {
                    hex = String(format: "#%02x%02x%02x", Int(c.redComponent * 255), Int(c.greenComponent * 255), Int(c.blueComponent * 255))
                }
            }
            return hex
        }
    }

    // The sidebar's search (ChatSearch: titles, messages and answers) over the chats the list shows.
    public static func search(_ d: Discussion, _ query: String) -> [[String: Any]] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        let chats = d.listedConversations.filter(\.hasContent)
        return ChatSearch.search(query, in: chats, limit: 40).map { r in
            var row: [String: Any] = ["id": r.id.uuidString, "title": r.title, "snippet": r.snippet, "words": r.words,
                                      "date": ChatTime.stamp(r.updatedAt)]
            if let turn = r.turn { row["turn"] = turn.uuidString }
            return row
        }
    }

    // A new chat from the phone, made only when its first message goes (so leaving before sending leaves nothing behind):
    // a loose chat, or a chat in the project whose sidebar id (ProjectGroup.id) is given. The Mac's open chat stays open.
    // Returns the new chat's id, or why it was not sent.
    public static func create(_ d: Discussion, project: String?, text: String, photos: [Data], mentions: [String] = []) -> (id: UUID?, reason: String?) {
        guard d.host == nil else { return (nil, L("이 Mac에서는 새 대화를 만들 수 없어요.", "Cannot start a chat on this Mac.")) }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !photos.isEmpty else { return (nil, L("보낼 내용이 없어요.", "Nothing to send.")) }
        guard d.runningRooms.count < Discussion.maxRunning else {
            return (nil, L("동시에 \(Discussion.maxRunning)개 대화까지 답할 수 있어요. 하나가 끝나면 보낼 수 있어요.",
                           "Up to \(Discussion.maxRunning) chats can answer at once. Send when one finishes."))
        }
        let room: UUID
        if let project, !project.isEmpty {
            let todo = TodoStore.shared.snapshot
            guard let group = projectGroups(d).first(where: { $0.id == project }), let binding = group.bindings.first else {
                return (nil, L("프로젝트를 찾지 못했어요.", "Project not found."))
            }
            room = d.addProjectChat(binding, title: L("새 대화", "New chat"), open: false, lock: SidebarProjects.lock(of: group, todo: todo))
        } else {
            let fresh = Conversation()
            d.conversations.insert(fresh, at: 0)
            room = fresh.id
        }
        if let reason = send(d, room: room, text: text, photos: photos, mentions: mentions) {
            if let chat = d.conversations.first(where: { $0.id == room }), chat.turns.isEmpty {
                try? ChatStore.delete(chat)
                d.conversations.removeAll { $0.id == room }
            }
            return (nil, reason)
        }
        return (room, nil)
    }

    // A picture of this chat by its id (a message's, an answer's or a queued one's), for the page's <img>.
    public static func image(_ d: Discussion, _ room: UUID, id: UUID) -> URL? {
        guard let chat = d.conversations.first(where: { $0.id == room }) else { return nil }
        var all: [ChatImage] = (chat.queued ?? []).flatMap { $0.images ?? [] }
        for turn in chat.turns {
            all += (turn.images ?? []) + (turn.finalImages ?? [])
            for entry in turn.entries + (turn.moreAnswers ?? []) { all += entry.images ?? [] }
        }
        return all.first { $0.id == id }?.url
    }

    // Sent from the phone like the message box sends (send()): into the queue while the chat answers, to its TODO,
    // or a new turn. Photos are imported into the chat (at most 4, like addImage). `mentions`: the accounts picked from
    // the page's @ list, in order; prepare keeps only those this chat may call whose "@name" is still in the text.
    // Returns why it was not sent.
    public static func send(_ d: Discussion, room: UUID, text: String, photos: [Data], mentions: [String] = []) -> String? {
        guard d.host == nil, let chat = d.conversations.first(where: { $0.id == room }) else { return L("대화를 찾지 못했어요.", "Chat not found.") }
        guard chat.meetingOf == nil else { return L("회의 기록에는 보낼 수 없어요.", "A meeting record cannot take messages.") }
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !photos.isEmpty else { return L("보낼 내용이 없어요.", "Nothing to send.") }
        guard photos.count <= 4, chat.turns.flatMap({ $0.images ?? [] }).count + photos.count < 200 else {
            return L("한 메시지에 4장, 한 대화에 200장까지 첨부할 수 있습니다.", "Attach up to 4 images per message and 200 per chat.")
        }
        let running = d.runningRooms.contains(room)
        if !running, d.runningRooms.count >= Discussion.maxRunning {
            return L("동시에 \(Discussion.maxRunning)개 대화까지 답할 수 있어요. 하나가 끝나면 보낼 수 있어요.",
                     "Up to \(Discussion.maxRunning) chats can answer at once. Send when one finishes.")
        }
        var images: [ChatImage] = []
        for (i, data) in photos.enumerated() {
            do { images.append(try ImageStore.importImage(data, name: L("iPhone 사진 \(i + 1)", "iPhone photo \(i + 1)"), conversationID: room)) } catch {
                for image in images { try? ImageStore.remove(image) }
                return L("사진을 첨부할 수 없습니다.", "Could not attach the photo.")
            }
        }
        // Like addImage: a Gemini leader cannot see pictures (while answering, flushQueue switches it).
        if !images.isEmpty, !running, d.configuration(of: room).leader == .gemini {
            d.configure(room: room) { config in config.leader = config.participants.contains(.claude) ? .claude : .codex }
        }
        let message = QueuedMessage(text: text, images: images.isEmpty ? nil : images, mentions: mentions.isEmpty ? nil : mentions, route: nil)
        if running { d.enqueue(message, room: room); return nil }
        let ready = d.prepare(message, room: room)
        switch d.sendToTodo(ready, room: room) {
        case .failed(let reason): for image in images { try? ImageStore.remove(image) }; return reason
        case .sent: return nil
        case .notTodo:
            if let reason = d.startTurn(room: room, question: ready.question, mentioned: ready.mentioned, images: ready.images, forced: ready.picked) {
                for image in images { try? ImageStore.remove(image) }
                return reason
            }
            return nil
        }
    }
}
