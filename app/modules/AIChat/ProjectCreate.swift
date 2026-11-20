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
            guard let self else { return title }
            self.addProjectChat(self.identify(project, ask: false) ?? project, title: title, open: false); return title
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
    // in it only when the user picks that (ask) or that project is locked (a new one would leave its lock behind); else
    // it becomes a new project with its own id. nil: cancelled. A folderless project's folder is its own already.
    func identify(_ found: ProjectBinding, ask: Bool) -> ProjectBinding? {
        guard !found.isFolderless else { return found }
        let todo = TodoStore.shared.current
        var using: [ProjectBinding] = []
        let bindings = conversations.filter { $0.meetingOf == nil }.sorted { $0.updatedAt > $1.updatedAt }.compactMap(\.workspace?.project)
            + todo.lists.compactMap(\.project)
        for p in bindings where (p.root == found.root || p.groupKey == found.groupKey) && !using.contains(where: { $0.groupKey == p.groupKey }) { using.append(p) }
        func joining(_ p: ProjectBinding) -> ProjectBinding { var joined = found; joined.id = p.id; return joined }
        if let locked = using.first(where: { p in
            let parts = projectParts(p.groupKey, todos: todo)
            return parts.rooms.contains { $0.enterpriseLock != nil } || parts.lists.contains { $0.lock != nil }
        }) { return joining(locked) }
        var fresh = found
        fresh.id = ProjectBinding.newID()
        guard let existing = using.first else { return fresh }
        if ask {
            let name = ProjectInfoStore.shared.names[existing.groupKey] ?? SidebarProjects.folderName(existing)
            let alert = NSAlert()
            alert.messageText = L("이 폴더를 쓰는 프로젝트가 이미 있어요", "A project already uses this folder")
            alert.informativeText = found.root + "\n\n" + L("같은 폴더로 새 프로젝트를 따로 만들거나, ‘\(name)’에 새 대화를 추가할 수 있어요. 새 프로젝트는 TODO·메모리·이름을 따로 가져요. 이 폴더에서는 한 번에 한 프로젝트만 일해요.",
                                                             "Make a separate new project on the same folder, or add a new chat to “\(name)”. A new project has its own TODOs, memory and name. Only one project works in this folder at a time.")
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
        return fresh
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
        let bindings = chats.compactMap(\.workspace?.project) + todo.lists.filter { lists.contains($0.id) }.compactMap(\.project)
        if bindings.isEmpty || bindings.contains(where: \.isFolderless) { return L("이 프로젝트에는 연결된 작업 폴더가 없어요.", "This project has no linked work folder.") }
        return nil
    }

    // The move itself (on the main thread, so nothing starts in between). A fresh folderless binding gets a new key;
    // the project info is copied first and the old entry forgotten last, so a failure on the way loses nothing.
    @discardableResult
    func disconnectFolder(_ key: String, name: String, keepReadOnly: Bool = false) throws -> ProjectBinding {
        if let why = disconnectRefusal(key) { throw MaterialReader.error(why) }
        let roots = projectRoots(key)
        let project = try ProjectCreator.folderlessBinding()
        let new = SidebarProjects.key(project)
        let kept = keepReadOnly ? roots.filter { FileManager.default.fileExists(atPath: $0) }.map { ProjectFolder(path: $0, directory: true) } : []
        do { try ProjectInfoStore.shared.copy(from: key, to: new, name: name, folders: kept) } catch {
            try? FileManager.default.removeItem(atPath: project.root)
            throw error
        }
        // The project's memory goes with it, so the folder linked again later starts with none.
        do { try ProjectMemoryStore.shared.move(from: key, to: new) } catch {
            try? ProjectInfoStore.shared.forget(new)
            try? FileManager.default.removeItem(atPath: project.root)
            throw error
        }
        let lists = Set(TodoStore.shared.current.lists.filter { $0.project?.groupKey == key }.map(\.id))
        do { try TodoStore.shared.relink(lists, to: project) } catch {
            try? ProjectMemoryStore.shared.move(from: new, to: key)
            try? ProjectInfoStore.shared.forget(new)
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
        try? ProjectInfoStore.shared.forget(key)
        SidebarFold.shared.rekey(key, to: new)
        if boardProject == key { boardProject = new }
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
}
