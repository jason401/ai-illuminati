import Cocoa
import AIAccounts
import AILocalization
import AIRuntime
import AIWorkspace
import AIProjects

extension Discussion {
    func linkProjectMaker() {
        ProjectMakerLink.shared.cancellation = { [weak self] room in self?.runToken(room) }
        ProjectMakerLink.shared.addChat = { [weak self] project, title in self?.addProjectChat(project, title: title, open: false); return title }
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

    // Project info / sidebar → Disconnect work folder…: the project keeps its chats, TODOs, name, folders, links and
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
            + L("폴더 없는 프로젝트가 돼요. 채팅·TODO·이름·공통 폴더·링크는 그대로이고, 디스크의 폴더·파일·Git 기록도 그대로예요. 이 프로젝트의 AI는 더 이상 이 폴더를 고치거나 Git을 쓰지 않고, 결과는 채팅 폴더에 저장해요. 나중에 폴더를 다시 연결하면 새 프로젝트로 시작해요.",
                "It becomes a folderless project. Its chats, TODOs, name, shared folders and links stay, and so do the folder, its files and its Git history on disk. Its AI no longer edits this folder or uses Git; results go to the chat folder. Linking the folder again later starts a new project.")
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
        let lists = Set(TodoStore.shared.current.lists.filter { $0.project?.groupKey == key }.map(\.id))
        do { try TodoStore.shared.relink(lists, to: project) } catch {
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
