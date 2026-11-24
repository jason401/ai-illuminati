import Cocoa
import AIAccounts
import AILocalization
import AIRuntime
import AIWorkspace
import AIProjects

extension Discussion {
    func linkProjectMaker() {
        ProjectMakerLink.shared.cancellation = { [weak self] room in self?.runToken(room) }
        ProjectMakerLink.shared.addChat = { [weak self] project, title in
            guard let self, let picked = self.identify(project, ask: false) else { return nil }
            self.addProjectChat(picked.project, title: title, open: false, lock: picked.lock); return title
        }
    }

    // A chat linked to a new project, as "Link folder" makes it (full auto unless turned off).
    @discardableResult
    func addProjectChat(_ project: ProjectBinding, title: String, open: Bool, lock: EnterpriseLock? = nil) -> UUID {
        var chat = Conversation()
        chat.title = String(title.prefix(80))
        chat.enterpriseLock = lock   // locked before anything is sent (a TODO of an Enterprise project)
        chat.workspace = WorkspaceBinding(roots: project.linkedRoots, project: project)
        conversations.insert(chat, at: 0)
        ChatStore.save(chat)
        if open { self.open(chat.id); focusRequest += 1 }
        return chat.id
    }

    // Projects are told apart by their id, so one folder may serve several. A folder being linked joins a project already
    // in it only when the user picks that (ask); else it becomes a new project with its own id. The lock follows the
    // folder: when a locked project works in it (or in a folder inside or around it), the new chat gets that lock, and
    // projects with different locks there refuse it (attachmentError). nil: cancelled or refused. A folderless
    // project's folder is its own already.
    func identify(_ found: ProjectBinding, ask: Bool) -> (project: ProjectBinding, lock: EnterpriseLock?)? {
        guard !found.isFolderless else { return (found, nil) }
        let todo = TodoStore.shared.current
        // A folderless project (its folder disconnected) may still carry the folder's old key as its id: it is not in the folder.
        let bindings = (conversations.filter { $0.meetingOf == nil }.sorted { $0.updatedAt > $1.updatedAt }.compactMap(\.workspace?.project)
            + todo.lists.compactMap(\.project)).filter { !$0.isFolderless }
        var using: [ProjectBinding] = []
        // The same folder, or another work tree of the same Git repository (a key can outlive its folder once a project switches).
        for p in bindings where (p.root == found.root || (!found.isDocuments && !p.isDocuments && p.common == found.common)) && !using.contains(where: { $0.groupKey == p.groupKey }) { using.append(p) }
        let locks = folderLocks(found.root)
        guard locks.count <= 1 else {
            attachmentError = L("이 폴더를 서로 다른 잠금의 프로젝트들이 쓰고 있어서 연결하지 않았어요.", "Projects with different locks use this folder, so it was not linked.")
            return nil
        }
        let lock = locks.first
        func joining(_ p: ProjectBinding) -> (project: ProjectBinding, lock: EnterpriseLock?) { var joined = found; joined.id = p.id; return (joined, lock) }
        var fresh = found
        fresh.id = ProjectBinding.newID()
        guard let existing = using.first else { return (fresh, lock) }
        if ask {
            let name = ProjectInfoStore.shared.names[existing.groupKey] ?? SidebarProjects.folderName(existing)
            let alert = NSAlert()
            alert.messageText = L("이 폴더를 쓰는 프로젝트가 이미 있어요", "A project already uses this folder")
            alert.informativeText = found.root + "\n\n" + L("같은 폴더로 새 프로젝트를 따로 만들거나, ‘\(name)’에 새 대화를 추가할 수 있어요. 새 프로젝트는 TODO·메모리·이름을 따로 가져요. 이 폴더에서는 한 번에 한 프로젝트만 일해요.",
                                                             "Make a separate new project on the same folder, or add a new chat to “\(name)”. A new project has its own TODOs, memory and name. Only one project works in this folder at a time.")
                + (lock.map { "\n\n" + L("이 폴더는 ‘\($0.name)’ 잠금이라 새 프로젝트도 같은 잠금이 돼요.", "This folder is locked to “\($0.name)”, so a new project gets the same lock.") } ?? "")
            alert.addButton(withTitle: L("새 프로젝트", "New project"))
            alert.addButton(withTitle: L("‘\(name)’에 추가", "Add to “\(name)”"))
            alert.addButton(withTitle: L("취소", "Cancel"))
            switch alert.runModal() {
            case .alertFirstButtonReturn: break
            case .alertSecondButtonReturn: return joining(existing)
            default: return nil
            }
        }
        // The sidebar tells the projects of one folder apart by a number after the folder's name.
        try? ProjectInfoStore.shared.rename(fresh.groupKey, to: SidebarProjects.folderName(found) + " \(using.count + 1)")
        return (fresh, lock)
    }

    // The same for the open chat linking a folder: a lock the folder carries must be the chat's own (a chat is never
    // locked behind the user's back).
    func identifyHere(_ found: ProjectBinding) -> ProjectBinding? {
        guard let picked = identify(found, ask: true) else { return nil }
        if let lock = picked.lock, current.enterpriseLock?.organization != lock.organization {
            attachmentError = L("이 폴더는 ‘\(lock.name)’ 잠금 프로젝트가 써요. 사이드바 프로젝트의 + → 폴더 연결로 새 대화에서 연결하세요.",
                                "A project locked to “\(lock.name)” uses this folder. Link it in a new chat with + → Link a folder in the sidebar's projects.")
            return nil
        }
        return picked.project
    }

    // The project row's new-chat button (and its menu): opens the project's blank chat when it has one, so pressing it
    // again adds nothing (one blank chat per project, like the one loose blank chat of newConversation). Older blank
    // chats of the project go. Project chats are never dropped as blank (hasContent counts the linked project).
    @discardableResult
    func openOrAddProjectChat(_ group: ProjectGroup, _ binding: ProjectBinding, lock: EnterpriseLock?, todo: TodoData) -> UUID {
        guard !importingMaterials else { return currentID }
        let todoRooms = Set(todo.items.compactMap(\.room))
        let blanks = group.chats.compactMap { chat in conversations.first { $0.id == chat.id } }
            .filter { SidebarProjects.reusableBlank($0, lock: lock, todoRooms: todoRooms, running: runningRooms) }
            .sorted { $0.updatedAt > $1.updatedAt }
        guard let keep = blanks.first(where: { $0.id == currentID }) ?? blanks.first else {
            return addProjectChat(binding, title: L("새 대화", "New chat"), open: true, lock: lock)
        }
        open(keep.id)   // the same chat keeps its draft and waiting pictures
        focusRequest += 1
        let extra = blanks.filter { $0.id != keep.id && SidebarProjects.removableBlank($0) && !hasDraft($0.id) }
        if !extra.isEmpty { removeChats(extra) }
        return keep.id
    }

    // Sidebar Projects + → Empty project: a name only; folders can be added later.
    func newEmptyProject() {
        guard !running, !importingMaterials else { return }
        let alert = NSAlert()
        alert.messageText = L("빈 프로젝트", "Empty project")
        alert.informativeText = L("폴더 없이 시작해요. 나중에 프로젝트 정보에서 폴더·파일을 추가할 수 있어요.",
                                  "Starts without folders. Add folders or files later in Project info.")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.placeholderString = L("새 프로젝트", "New project")
        alert.accessoryView = field
        alert.addButton(withTitle: L("만들기", "Create")); alert.addButton(withTitle: L("취소", "Cancel"))
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let typed = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let project = try ProjectCreator.createFolderless(name: typed.isEmpty ? L("새 프로젝트", "New project") : typed)
            attachmentError = nil
            _ = addProjectChat(project, title: L("새 대화", "New chat"), open: true)
            sessionNote = L("폴더 없는 프로젝트 만듦 · 폴더는 나중에 추가할 수 있어요", "Project created without folders · add folders later")
        } catch { attachmentError = error.localizedDescription }
    }

    // Project info / sidebar → Disconnect work folder…: the project keeps its chats, TODOs, name, memory, folders, links and
    // pin, but no longer works in its Git or documents folder (every worktree of it). The files on disk stay.
    // Refused while any of it runs; checked again after asking.
    public func disconnectProjectFolder(_ key: String, name: String) {
        guard !importingMaterials else { return }
        func tell(_ title: String, _ text: String) {
            let alert = NSAlert(); alert.messageText = title; alert.informativeText = text; alert.runModal()
        }
        let cannot = L("작업 폴더 연결을 끊을 수 없어요", "Cannot disconnect the work folder")
        if let why = disconnectRefusal(key) { tell(cannot, why); return }
        let roots = projectRoots(key)
        let alert = NSAlert()
        alert.messageText = L("‘\(name)’의 작업 폴더 연결을 끊을까요?", "Disconnect the work folder of “\(name)”?")
        alert.informativeText = roots.joined(separator: "\n") + "\n\n"
            + L("폴더 없는 프로젝트가 돼요. 채팅·TODO·이름·프로젝트 메모리·공통 폴더·링크는 그대로이고, 디스크의 폴더·파일·Git 기록도 그대로예요. 이 프로젝트의 AI는 더 이상 이 폴더를 고치거나 Git을 쓰지 않고, 결과는 채팅 폴더에 저장해요. 나중에 폴더를 다시 연결하면 새 프로젝트로 시작해요.",
                "It becomes a folderless project. Its chats, TODOs, name, project memory, shared folders and links stay, and so do the folder, its files and its Git history on disk. Its AI no longer edits this folder or uses Git; results go to the chat folder. Linking the folder again later starts a new project.")
        let keep = NSButton(checkboxWithTitle: L("이 폴더를 읽기 전용 공통 폴더로 남기기", "Keep this folder as a read-only shared folder"), target: nil, action: nil)
        keep.state = .off
        alert.accessoryView = keep
        alert.addButton(withTitle: L("연결 끊기", "Disconnect"))
        alert.addButton(withTitle: L("취소", "Cancel"))
        alert.buttons.first?.hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do { _ = try disconnectFolder(key, name: name, keepReadOnly: keep.state == .on) } catch { tell(cannot, error.localizedDescription) }
    }

    func projectRoots(_ key: String) -> [String] {
        var roots: [String] = []
        let bindings = conversations.compactMap(\.workspace?.project) + TodoStore.shared.current.lists.compactMap(\.project)
        for binding in bindings where SidebarProjects.key(binding) == key && !roots.contains(binding.root) { roots.append(binding.root) }
        return roots
    }

    func disconnectRefusal(_ key: String) -> String? {
        if let why = busyRefusal(key) { return why }
        let bindings = projectBindings(key)
        if bindings.isEmpty || bindings.contains(where: \.isFolderless) { return L("이 프로젝트에는 연결된 작업 폴더가 없어요.", "This project has no linked work folder.") }
        return nil
    }

    // Why the project's chats and TODO lists cannot be moved now (nil: they can).
    func busyRefusal(_ key: String) -> String? {
        let chats = conversations.filter { $0.workspace?.project?.groupKey == key }
        let rooms = chats.flatMap { [$0.id] + meetings(of: $0.id).map(\.id) }
        if !runningRooms.isDisjoint(with: rooms) { return L("이 프로젝트의 채팅이 답하는 중이에요. 끝난 뒤 다시 해 주세요.", "A chat of this project is answering. Try again when it is done.") }
        let todo = TodoStore.shared.current
        let lists = Set(todo.lists.filter { $0.project?.groupKey == key }.map(\.id))
        if todo.items.contains(where: { lists.contains($0.listID) && $0.state == .running }) {
            return L("이 프로젝트의 TODO가 진행 중이에요. 끝나거나 멈춘 뒤 다시 해 주세요.", "A TODO of this project is running. Try again when it is done or stopped.")
        }
        if let locked = TodoStore.shared.locked { return locked }
        if ProjectInfoStore.shared.isLocked { return L("project-info.json을 읽지 못해서 바꾸지 않았어요. 파일을 확인해 주세요.", "project-info.json could not be read, so nothing was changed. Please check the file.") }
        return nil
    }

    // Every binding of the project: its chats' (meetings too) and its TODO lists'.
    func projectBindings(_ key: String) -> [ProjectBinding] {
        (conversations.compactMap(\.workspace?.project) + TodoStore.shared.current.lists.compactMap(\.project)).filter { $0.groupKey == key }
    }

    // The move itself (on the main thread, so nothing starts in between). A fresh folderless binding keeps the project's
    // key as its id, so nothing keyed by it moves; a failure on the way takes back what was added.
    @discardableResult
    func disconnectFolder(_ key: String, name: String, keepReadOnly: Bool = false) throws -> ProjectBinding {
        if let why = disconnectRefusal(key) { throw MaterialReader.error(why) }
        let roots = projectRoots(key)
        var project = try ProjectCreator.folderlessBinding()
        project.id = key   // the same project: its name, memory, TODO lists, pin and tab stay under its key
        let kept = keepReadOnly ? roots.filter { FileManager.default.fileExists(atPath: $0) }.map { ProjectFolder(path: $0, directory: true) } : []
        let had = Set(ProjectInfoStore.shared.info(key).folders.map(\.path))
        do { try ProjectInfoStore.shared.copy(from: key, to: key, name: name, folders: kept) } catch {
            try? FileManager.default.removeItem(atPath: project.root)
            throw error
        }
        let lists = Set(TodoStore.shared.current.lists.filter { $0.project?.groupKey == key }.map(\.id))
        do { try TodoStore.shared.relink(lists, to: project) } catch {
            for folder in kept where !had.contains(folder.path) { try? ProjectInfoStore.shared.removeFolder(folder.path, from: key) }
            try? FileManager.default.removeItem(atPath: project.root)
            throw error
        }
        for i in conversations.indices {
            guard var binding = conversations[i].workspace, let old = binding.project, SidebarProjects.key(old) == key else { continue }
            binding.roots.removeAll { roots.contains($0.path) }
            binding.project = project
            binding.projectRunID = nil; binding.projectGeneration = nil
            conversations[i].workspace = binding
            ChatStore.save(conversations[i])
        }
        sessionNote = L("작업 폴더 연결을 끊었어요 · 폴더 없는 프로젝트", "Work folder disconnected · folderless project")
        return project
    }

    // + → New project…: the user's own dialog is the approval (destination, account and visibility shown first).
    func newProjectFromMenu() {
        guard !running, !importingMaterials else { return }
        let alert = NSAlert()
        alert.messageText = L("새 프로젝트", "New project")
        alert.informativeText = L("\(ProjectCreator.defaultLocation) 안에 폴더를 만들고 GitHub 저장소와 연결해요.",
                                  "Creates a folder in \(ProjectCreator.defaultLocation) and a GitHub repository for it.")
        let field = NSTextField(frame: NSRect(x: 0, y: 28, width: 280, height: 24))
        field.placeholderString = "my-app"
        let secret = NSButton(checkboxWithTitle: L("비공개 (private)", "Private"), target: nil, action: nil)
        secret.state = .on; secret.frame = NSRect(x: 0, y: 0, width: 280, height: 20)
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: 52))
        box.addSubview(field); box.addSubview(secret)
        alert.accessoryView = box
        alert.addButton(withTitle: L("다음", "Next")); alert.addButton(withTitle: L("취소", "Cancel"))
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue, isPrivate = secret.state == .on
        attachmentError = nil
        sessionNote = L("GitHub 계정 확인 중…", "Checking the GitHub account…")
        DispatchQueue.global().async {
            let prepared = Result { try ProjectCreator.prepare(name: name, location: nil, isPrivate: isPrivate, token: nil) }
            DispatchQueue.main.async {
                self.sessionNote = ""
                switch prepared {
                case .failure(let error): self.attachmentError = error.localizedDescription
                case .success(let (plan, resume)):
                    let confirm = NSAlert()
                    confirm.messageText = L("새 프로젝트 만들기", "Create a new project")
                    confirm.informativeText = ProjectCreator.summary(plan, resume: resume)
                    confirm.addButton(withTitle: L("만들기", "Create")); confirm.addButton(withTitle: L("취소", "Cancel"))
                    guard confirm.runModal() == .alertFirstButtonReturn else { return }
                    self.sessionNote = L("새 프로젝트 만드는 중…", "Creating the project…")
                    DispatchQueue.global().async {
                        let made = Result { try ProjectCreator.create(plan, token: nil) }
                        DispatchQueue.main.async {
                            self.sessionNote = ""
                            switch made {
                            case .failure(let error): self.attachmentError = error.localizedDescription
                            case .success(let project): self.addProjectChat(project, title: plan.repo, open: true)
                            }
                        }
                    }
                }
            }
        }
    }

    // A project's work folders: it works in one at a time (the root of its chats and TODO lists, the active one); the
    // others wait in its project info until the user switches. Switching keeps the project's id, so its name, memory,
    // TODOs and locks stay; it is refused while any of it runs, and the lock follows the folder as when linking.
    // The locks of the other projects working in `root` or in a folder inside or around it.
    func folderLocks(_ root: String, except key: String? = nil) -> [EnterpriseLock] {
        let todo = TodoStore.shared.current
        let bindings = (conversations.filter { $0.meetingOf == nil }.compactMap(\.workspace?.project) + todo.lists.compactMap(\.project)).filter { !$0.isFolderless }
        func overlaps(_ a: String, _ b: String) -> Bool { a == b || a.hasPrefix(b + "/") || b.hasPrefix(a + "/") }
        var seen = Set<String>(), locks: [EnterpriseLock] = []
        for p in bindings where p.groupKey != key && overlaps(p.root, root) && seen.insert(p.groupKey).inserted {
            if let lock = projectLock(p.groupKey, todos: todo), !locks.contains(where: { $0.organization == lock.organization }) { locks.append(lock) }
        }
        return locks
    }
    func projectLock(_ key: String, todos: TodoData) -> EnterpriseLock? {
        let parts = projectParts(key, todos: todos)
        return (parts.rooms.compactMap(\.enterpriseLock) + parts.lists.compactMap(\.lock)).first
    }

    // The active work folder (nil: folderless) and the others to switch to.
    public func workFolders(_ key: String) -> (active: String?, others: [String]) {
        let active = projectBindings(key).first { !$0.isFolderless }?.root
        return (active, ProjectInfoStore.shared.info(key).workFolders.filter { $0 != active })
    }

    // `path` as the project's work folder: a top-level Git folder with a remote, else a documents folder; the folder's
    // lock (another project's in it) must be the project's own.
    func workBinding(_ key: String, _ path: String) throws -> ProjectBinding {
        var project = try (try? ProjectProcess.inspect(path)) ?? ProjectProcess.documents(path)
        project.id = key
        let locks = folderLocks(project.root, except: key), mine = projectLock(key, todos: TodoStore.shared.current)
        if locks.count > 1 || locks.first.map({ $0.organization != mine?.organization }) == true {
            throw MaterialReader.error(L("이 폴더는 잠금이 다른 프로젝트가 써서 이 프로젝트의 작업 폴더가 될 수 없어요.",
                                         "A project with another lock uses this folder, so it cannot be this project's work folder."))
        }
        return project
    }

    public func addWorkFolder(_ key: String, path: String) throws {
        let project = try workBinding(key, path)
        let (active, others) = workFolders(key)
        guard project.root != active else { return }
        try ProjectInfoStore.shared.setWorkFolders(others + [project.root], of: key)
    }
    public func removeWorkFolder(_ key: String, path: String) throws {
        try ProjectInfoStore.shared.setWorkFolders(workFolders(key).others.filter { $0 != path }, of: key)
    }

    func switchRefusal(_ key: String) -> String? {
        if let why = busyRefusal(key) { return why }
        if projectBindings(key).isEmpty { return L("이 프로젝트에는 채팅이나 TODO가 없어요.", "This project has no chats or TODOs.") }
        if projectRoots(key).count > 1 {
            return L("이 프로젝트는 작업 트리 여러 개에서 일하고 있어서 바꿀 수 없어요. 하위 작업이 끝난 뒤 다시 해 주세요.", "This project works in several work trees, so it cannot switch. Try again when the sub-work is done.")
        }
        return nil
    }

    // The switch itself (on the main thread, so nothing starts in between). The old work folder stays in the list.
    @discardableResult
    func switchWorkFolder(_ key: String, to path: String) throws -> ProjectBinding {
        if let why = switchRefusal(key) { throw MaterialReader.error(why) }
        let project = try workBinding(key, path)
        let roots = projectRoots(key)
        let (active, others) = workFolders(key)
        guard project.root != active else { return project }
        try ProjectInfoStore.shared.setWorkFolders(others.filter { $0 != project.root } + (active.map { [$0] } ?? []), of: key)
        let lists = Set(TodoStore.shared.current.lists.filter { $0.project?.groupKey == key }.map(\.id))
        do { try TodoStore.shared.relink(lists, to: project) } catch {
            try? ProjectInfoStore.shared.setWorkFolders(others, of: key)
            throw error
        }
        for i in conversations.indices {
            guard var binding = conversations[i].workspace, let old = binding.project, SidebarProjects.key(old) == key else { continue }
            binding.roots.removeAll { roots.contains($0.path) || $0.path == project.root }
            binding.roots.insert(contentsOf: project.linkedRoots, at: 0)
            binding.project = project
            binding.projectRunID = nil; binding.projectGeneration = nil
            conversations[i].workspace = binding
            try? nativeSessions.reset(conversations[i].id)   // the AI's earlier sessions knew the old folder
            ChatStore.save(conversations[i])
        }
        try? ProjectInfoStore.shared.removeFolder(project.root, from: key)   // a read folder made the work folder is listed once, as ★
        sessionNote = L("작업 폴더를 바꿨어요: ", "Work folder switched: ") + (project.root as NSString).lastPathComponent
        return project
    }

    // Project info → Use as work folder: asks first (the AI then works there, full auto), then switches or says why not.
    public func useWorkFolder(_ key: String, path: String, name: String) {
        func tell(_ text: String) {
            let alert = NSAlert(); alert.messageText = L("작업 폴더를 바꾸지 못했어요", "Could not switch the work folder"); alert.informativeText = text; alert.runModal()
        }
        if let why = switchRefusal(key) { tell(why); return }
        let project: ProjectBinding
        do { project = try workBinding(key, path) } catch { tell(error.localizedDescription); return }
        if !project.isDocuments { guard Self.allowProjectWork(project) else { return } }
        else {
            let alert = NSAlert()
            alert.messageText = L("‘\(name)’의 작업 폴더를 바꿀까요?", "Switch the work folder of “\(name)”?")
            alert.informativeText = project.root + "\n\n" + L("이 프로젝트의 채팅과 TODO가 이 폴더에서 일해요 (완전 자동, 답할 때마다 백업). 이름·메모리·TODO는 그대로이고, 지금 폴더는 목록에 남아서 다시 바꿀 수 있어요.",
                                                               "This project's chats and TODOs work in this folder (full auto, backed up before each answer). Name, memory and TODOs stay; the current folder stays in the list to switch back.")
            alert.addButton(withTitle: L("바꾸기", "Switch")); alert.addButton(withTitle: L("취소", "Cancel"))
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        do { try switchWorkFolder(key, to: path) } catch { tell(error.localizedDescription) }
    }
}
