import Cocoa

// A new project from any chat (the create_project tool, after the user's card) or the + menu (the user's own dialog):
// a folder, Git with a first commit, a GitHub repository, then a new chat linked to it like "Link folder".
// The app runs it with the user's own GitHub CLI login; the AI's environment still has no credentials (AutoGuard).
enum ProjectCreator {
    // What was approved. Kept in the new repository's .git (never committed), so asking again after a failed step
    // continues only that exact project: same folder, account, name and visibility.
    struct Plan: Codable, Equatable {
        var folder: String
        var owner: String
        var repo: String
        var isPrivate: Bool
        var url: String { "https://github.com/\(owner)/\(repo)" }
    }
    // Where a push may really go (after pushurl and insteadOf); tests add their local "GitHub".
    static var pushTarget: (String, Plan) -> Bool = { sameRepo($0, $1) }
    static var ghCandidates = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh"]
    static var home = NSHomeDirectory()   // new projects go under here (tests: their own folder)
    static var defaultLocation: String { (home as NSString).appendingPathComponent("Documents/Projects") }
    static let markerName = "ai-illuminati-project.json"
    private static let busy = NSLock()   // one creation at a time

    static func error(_ korean: String, _ english: String) -> NSError { MaterialReader.error(L(korean, english)) }
    static var gh: String? { ghCandidates.first { FileManager.default.isExecutableFile(atPath: $0) } }

    // The folder and repository name: letters, digits, . _ - (spaces become -), as GitHub allows.
    static func name(_ raw: String) throws -> String {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: " ", with: "-")
        guard (1...100).contains(name.count), !name.hasPrefix("."), !name.hasPrefix("-"),
              name.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "._-".contains($0)) }) else {
            throw error("프로젝트 이름은 영문·숫자·. _ - 로 100자까지예요 (예: my-app).", "Use letters, digits and . _ - for the project name, up to 100 characters (e.g. my-app).")
        }
        return name
    }

    // An existing folder in the user's home, not in Library. Symlinks are resolved first.
    static func location(_ raw: String?) throws -> String {
        let value = raw.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 } ?? defaultLocation
        let expanded = (value as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/") else { throw error("위치는 절대 경로로 주세요.", "Give the location as an absolute path.") }
        let resolved = URL(fileURLWithPath: expanded).resolvingSymlinksInPath().standardizedFileURL.path
        let base = URL(fileURLWithPath: home).resolvingSymlinksInPath().standardizedFileURL.path
        var folder: ObjCBool = false
        let fallback = raw.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? true
        // The default ~/Documents/Projects may not exist yet: it is made with the project (create).
        if fallback, !FileManager.default.fileExists(atPath: resolved), resolved.hasPrefix(base + "/") { return resolved }
        guard FileManager.default.fileExists(atPath: resolved, isDirectory: &folder), folder.boolValue else {
            throw error("위치 폴더가 없어요: \(resolved)", "The location folder does not exist: \(resolved)")
        }
        guard resolved.hasPrefix(base + "/"), !resolved.hasPrefix(base + "/Library/"), resolved != base + "/Library" else {
            throw error("새 프로젝트는 홈 폴더 안(Library 제외)에만 만들 수 있어요.", "New projects go inside your home folder (not Library).")
        }
        return resolved
    }

    // A documents project (create_project kind "documents"): a folder only, no Git or GitHub. Its name may have spaces
    // and Korean; an existing folder there is linked as it is.
    static func documentsFolder(name raw: String, location: String?) throws -> String {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...100).contains(name.count), !name.hasPrefix("."), !name.contains("/"), !name.contains(":") else {
            throw error("폴더 이름은 100자까지, / : 없이, 점으로 시작하지 않게 주세요.", "Give a folder name up to 100 characters, without / or :, not starting with a dot.")
        }
        return (try self.location(location) as NSString).appendingPathComponent(name)
    }
    static func createDocuments(_ folder: String) throws -> ProjectBinding {
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        return try ProjectProcess.documents(folder)
    }

    // No user folder is created or linked. The internal directory supplies a stable identity
    // and a cwd for project tools; it is never added to the chat's allowed roots.
    static func createFolderless(name: String) throws -> ProjectBinding {
        let project = try folderlessBinding()
        try ProjectInfoStore.shared.rename(SidebarProjects.key(project), to: name)
        return project
    }
    static func folderlessBinding() throws -> ProjectBinding {
        let folder = URL(fileURLWithPath: AccountStore.supportDir)
            .appendingPathComponent("folderless-projects").appendingPathComponent(UUID().uuidString).path
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return ProjectBinding(root: URL(fileURLWithPath: folder).resolvingSymlinksInPath().path, common: URL(fileURLWithPath: folder).resolvingSymlinksInPath().path, remote: "", remoteURL: "", kind: "folderless")
    }

    private static var ghEnvironment: [String: String] {
        let dir = gh.map { ($0 as NSString).deletingLastPathComponent } ?? "/usr/local/bin"
        return ["PATH": dir + ":/usr/bin:/bin:/usr/sbin:/sbin", "GH_PROMPT_DISABLED": "1", "GH_NO_UPDATE_NOTIFIER": "1", "NO_COLOR": "1"]
    }
    private static func requireGH() throws -> String {
        guard let gh else {
            throw error("GitHub CLI(gh)가 없어요. 터미널에서 brew install gh 와 gh auth login 을 한 번 해 주세요.",
                        "GitHub CLI (gh) is not installed. Run brew install gh and gh auth login in Terminal once.")
        }
        return gh
    }
    private static func runGH(_ args: [String], cwd: String, token: DebateCancellation?, timeout: TimeInterval = 90) throws -> ProjectProcess.Reply {
        try ProjectProcess.run(try requireGH(), args, cwd: cwd, token: token, deadline: Date().addingTimeInterval(timeout), extra: ghEnvironment)
    }
    private static func short(_ text: String) -> String { String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(400)) }

    // The GitHub account gh is logged in to.
    static func owner(token: DebateCancellation?) throws -> String {
        let reply = try runGH(["api", "user", "--jq", ".login"], cwd: home, token: token)
        let login = reply.output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard reply.status == 0, !login.isEmpty, login.count <= 39, login.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }) else {
            throw error("GitHub 로그인을 확인하지 못했어요. 터미널에서 gh auth login 후 다시 요청해 주세요. (\(short(reply.output)))",
                        "Could not confirm the GitHub login. Run gh auth login in Terminal, then ask again. (\(short(reply.output)))")
        }
        return login
    }

    // true: it exists; false: GitHub says there is no such repository. Any other failure (login, network) stops.
    static func repoExists(_ owner: String, _ repo: String, token: DebateCancellation?) throws -> Bool {
        let reply = try runGH(["repo", "view", owner + "/" + repo, "--json", "name"], cwd: home, token: token)
        if reply.status == 0 { return true }
        if reply.output.contains("Could not resolve to a Repository") { return false }
        throw error("GitHub 저장소를 확인하지 못했어요: \(short(reply.output))", "Could not check the GitHub repository: \(short(reply.output))")
    }

    static func marker(_ folder: String) -> Plan? {
        let git = URL(fileURLWithPath: folder).appendingPathComponent(".git", isDirectory: true)
        guard (try? git.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == false,
              let data = try? Data(contentsOf: git.appendingPathComponent(markerName)) else { return nil }
        return try? JSONDecoder().decode(Plan.self, from: data)
    }
    private static func exists(_ path: String) -> Bool { (try? FileManager.default.attributesOfItem(atPath: path)) != nil }

    // Before the card: everything the user approves, checked. resume: an earlier try of this same plan stopped midway.
    static func prepare(name raw: String, location raw2: String?, isPrivate: Bool, token: DebateCancellation?) throws -> (plan: Plan, resume: Bool) {
        let repo = try name(raw), parent = try location(raw2)
        let plan = Plan(folder: parent + "/" + repo, owner: try owner(token: token), repo: repo, isPrivate: isPrivate)
        if exists(plan.folder) {
            guard marker(plan.folder) == plan else {
                throw error("이미 있는 폴더예요: \(plan.folder). 다른 이름을 쓰거나, 기존 폴더는 + → 폴더 연결로 연결하세요.",
                            "That folder already exists: \(plan.folder). Use another name, or link the existing folder with + → Link folder.")
            }
            return (plan, true)
        }
        if try repoExists(plan.owner, plan.repo, token: token) {
            throw error("GitHub에 \(plan.owner)/\(plan.repo)가 이미 있어요. 다른 이름을 써 주세요.", "\(plan.owner)/\(plan.repo) already exists on GitHub. Use another name.")
        }
        return (plan, false)
    }

    // What the card (or the + menu dialog) shows.
    static func summary(_ plan: Plan, resume: Bool) -> String {
        [L("폴더: ", "Folder: ") + plan.folder,
         "GitHub: \(plan.owner)/\(plan.repo) (\(plan.isPrivate ? "private" : "public"))",
         resume ? L("앞서 멈춘 단계부터 이어서 해요.", "Continues from the step that stopped before.") : "",
         L("순서: 폴더 → git init → README 첫 커밋 → GitHub 저장소 → push → 이 프로젝트에 연결된 새 채팅",
           "Steps: folder → git init → first commit (README) → GitHub repository → push → a new chat linked to it"),
         L("새 채팅은 완전 자동으로 일해요 (+ 메뉴에서 끌 수 있어요).", "The new chat works in full auto (turn it off in the + menu).")]
            .filter { !$0.isEmpty }.joined(separator: "\n")
    }

    // origin as written in .git/config: https or ssh to github.com/owner/repo(.git).
    static func sameRepo(_ remote: String, _ plan: Plan) -> Bool {
        let wanted = "github.com/" + plan.owner.lowercased() + "/" + plan.repo.lowercased()
        var path = remote.lowercased()
        for prefix in ["https://", "ssh://git@", "git@"] where path.hasPrefix(prefix) { path = String(path.dropFirst(prefix.count)); break }
        path = path.replacingOccurrences(of: "github.com:", with: "github.com/")
        if path.hasSuffix(".git") { path = String(path.dropLast(4)) }
        if path.hasSuffix("/") { path = String(path.dropLast()) }
        return path == wanted
    }

    // Each step runs only when it is not done yet; nothing already there is overwritten or deleted.
    static func create(_ plan: Plan, token: DebateCancellation?) throws -> ProjectBinding {
        guard busy.try() else { throw error("다른 프로젝트를 만드는 중이에요. 끝나면 다시 요청해 주세요.", "Another project is being created. Ask again when it finishes.") }
        defer { busy.unlock() }
        let folder = plan.folder
        func git(_ args: [String]) throws -> String { try ProjectProcess.git(args, root: folder, token: token) }
        if !exists(folder) {
            let parent = (folder as NSString).deletingLastPathComponent
            if !exists(parent) { try FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true) }
            try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: false)
            _ = try git(["init", "-b", "main"])
            try JSONEncoder().encode(plan).write(to: URL(fileURLWithPath: folder).appendingPathComponent(".git/" + markerName), options: .atomic)
        } else if marker(folder) != plan {
            throw error("이미 있는 폴더예요: \(folder)", "That folder already exists: \(folder)")
        }
        if (try? git(["rev-parse", "--verify", "-q", "HEAD"])) == nil {
            let readme = URL(fileURLWithPath: folder).appendingPathComponent("README.md")
            if !exists(readme.path) { try ("# " + plan.repo + "\n").write(to: readme, atomically: true, encoding: .utf8) }
            _ = try git(["add", "--", "README.md"])
            do { _ = try git(["commit", "-m", "Initial commit", "--", "README.md"]) } catch {
                let text = error.localizedDescription
                if text.contains("user.email") || text.contains("who you are") {
                    throw Self.error("Git 사용자 이름·이메일이 없어요. 터미널에서 git config --global user.name \"이름\" 과 git config --global user.email \"메일\" 을 한 뒤 다시 요청하면 이어서 해요.",
                                     "Git has no user name/email. Run git config --global user.name \"Name\" and git config --global user.email \"you@example.com\" in Terminal, then ask again to continue.")
                }
                throw error
            }
        }
        var remote = try? git(["config", "--get", "remote.origin.url"])
        if remote == nil, try repoExists(plan.owner, plan.repo, token: token) {
            // Made on GitHub, but stopped before origin was added (it did not exist before the card): add it and push.
            remote = plan.url + ".git"
            _ = try git(["remote", "add", "origin", plan.url + ".git"])
        }
        if let remote {
            // The repository was made before and only the push failed: push again, to that repository only.
            guard sameRepo(remote, plan) else {
                throw error("origin이 \(remote)를 가리켜요. 계획한 \(plan.url)와 달라서 멈췄어요.", "origin points to \(remote), not \(plan.url); stopped.")
            }
            let targets = ((try? git(["remote", "get-url", "--push", "--all", "origin"])) ?? "").split(separator: "\n").map(String.init)
            guard !targets.isEmpty, targets.allSatisfy({ pushTarget($0, plan) }) else {
                throw error("push가 \(targets.joined(separator: ", "))로 가게 설정돼 있어요 (pushurl·insteadOf). 계획한 \(plan.url)와 달라서 멈췄어요.",
                            "The push would go to \(targets.joined(separator: ", ")) (pushurl/insteadOf), not \(plan.url); stopped.")
            }
            let gh = try requireGH()
            let reply = try ProjectProcess.run("/usr/bin/git", ["-c", "credential.helper=", "-c", "credential.helper=!" + gh + " auth git-credential",
                                                                "push", "-u", "origin", "main"],
                                               cwd: folder, token: token, deadline: Date().addingTimeInterval(180), extra: ghEnvironment)
            guard reply.status == 0 else {
                throw error("GitHub에 올리지 못했어요: \(short(reply.output)). 다시 요청하면 push부터 해요.", "Could not push to GitHub: \(short(reply.output)). Ask again to retry the push.")
            }
        } else {
            let reply = try runGH(["repo", "create", plan.owner + "/" + plan.repo, plan.isPrivate ? "--private" : "--public",
                                   "--source=.", "--remote=origin", "--push"], cwd: folder, token: token, timeout: 300)
            guard reply.status == 0 else {
                throw error("GitHub 저장소를 만들거나 올리지 못했어요: \(short(reply.output)). 다시 요청하면 된 단계는 건너뛰고 이어서 해요.",
                            "Could not create or push the GitHub repository: \(short(reply.output)). Ask again to continue from there.")
            }
        }
        let project = try ProjectProcess.inspect(folder)
        // Done: from now on it is an existing project like any other (asking again does not make it twice).
        try? FileManager.default.removeItem(at: URL(fileURLWithPath: folder).appendingPathComponent(".git/" + markerName))
        return project
    }
}

// create_project: offered to the AI answering any open chat (not an Enterprise chat: the user's personal GitHub).
// Nothing is made before the user allows the card in that chat.
final class ProjectMakerLink: ToolProvider {
    static let shared = ProjectMakerLink()
    // Set by the app's Discussion (main thread): the chat's stop button, and adding the new linked chat (its title).
    var cancellation: (UUID) -> DebateCancellation? = { _ in nil }
    var addChat: (ProjectBinding, String) -> String = { _, title in title }

    var active: Bool { true }
    func tools() -> [[String: Any]] { [] }
    fileprivate func main<T>(_ work: () -> T) -> T { Thread.isMainThread ? work() : DispatchQueue.main.sync(execute: work) }

    func tools(context: ToolContext) -> [[String: Any]] {
        guard context.asker != nil else { return [] }
        let chat = main { ChatLink.shared.conversations().first { $0.id == context.room } }
        guard let chat, !chat.isEnterprise else { return [] }
        let string: [String: Any] = ["type": "string"]
        return [["name": "create_project",
                 "description": "When the user asks for a new project: create its folder with Git and a first commit, a GitHub repository under the user's own account (gh login), push, and add a new chat linked to it. The user approves a card first. name: letters, digits, . _ - only (turn a Korean name into a short English one). location: absolute folder path, default ~/Documents/Projects. private: default true. If it fails midway, calling it again with the same arguments continues. kind \"folderless\": create a named project without linking or creating a user folder; add shared folders later in Project info. kind \"documents\" (papers, slides, posters, figures; no code): only a folder (an existing one is linked as it is), no Git or GitHub; name may then be any folder name.",
                 "inputSchema": ["type": "object", "properties": ["name": string, "location": string, "private": ["type": "boolean"], "kind": ["type": "string", "enum": ["code", ProjectBinding.documentsKind, "folderless"]]],
                                 "required": ["name"], "additionalProperties": false]]]
    }

    func call(_ name: String, _ arguments: [String: Any], context: ToolContext) -> [String: Any] {
        guard name == "create_project", !tools(context: context).isEmpty else { return ToolHub.failure("Unknown tool: " + name) }
        let token = main { cancellation(context.room) } ?? DebateCancellation()
        if arguments["kind"] as? String == "folderless" { return folderless(arguments, context: context, token: token) }
        if arguments["kind"] as? String == ProjectBinding.documentsKind { return documents(arguments, context: context, token: token) }
        do {
            let (plan, resume) = try ProjectCreator.prepare(name: arguments["name"] as? String ?? "", location: arguments["location"] as? String,
                                                            isPrivate: arguments["private"] as? Bool ?? true, token: token)
            let deadline = Date().addingTimeInterval(900)
            let card = ProjectApproval(room: context.room, run: UUID(), title: L("새 프로젝트 만들기", "Create a new project"), detail: ProjectCreator.summary(plan, resume: resume))
            guard ProjectCenter.shared.approve(card, token: token, deadline: deadline) else {
                if Date() >= deadline, !token.isCancelled { return ToolHub.failure("Approval timed out after 15 minutes; treated as refused. Nothing was created. Tell the user they can ask again.") }
                return ToolHub.failure("The user did not allow creating the project. Nothing new was created; stop and say so.")
            }
            let project = try ProjectCreator.create(plan, token: token)
            let title = main { addChat(project, plan.repo) }
            return ["content": [["type": "text", "text": "Created \(plan.folder) and \(plan.url) (\(plan.isPrivate ? "private" : "public")); main is pushed. A new chat \"\(title)\" linked to this project is at the top of the chat list (full auto). Tell the user to open it and ask for the work there; this chat is not linked to the project."]], "isError": false]
        } catch { return ToolHub.failure(error.localizedDescription) }
    }
}

extension ProjectMakerLink {
    func folderless(_ arguments: [String: Any], context: ToolContext, token: DebateCancellation) -> [String: Any] {
        let title = ProjectInfoStore.cleanName(arguments["name"] as? String ?? "") ?? L("새 프로젝트", "New project")
        let deadline = Date().addingTimeInterval(900)
        let card = ProjectApproval(room: context.room, run: UUID(), title: L("폴더 없는 프로젝트 만들기", "Create a folderless project"),
                                   detail: title + "\n" + L("폴더·Git·GitHub 없이 시작해요. 폴더는 나중에 프로젝트 정보에서 추가할 수 있어요.", "Starts without folders, Git or GitHub. Add folders later in Project info."))
        guard ProjectCenter.shared.approve(card, token: token, deadline: deadline) else {
            return ToolHub.failure("Creating the folderless project was not approved or timed out. Nothing was created.")
        }
        do {
            let project = try ProjectCreator.createFolderless(name: title)
            let chat = main { addChat(project, title) }
            return ["content": [["type": "text", "text": "Created folderless project \(title) and chat \(chat). No user folder, Git or GitHub repository was created or linked. Add folders later in Project info."]], "isError": false]
        } catch { return ToolHub.failure(error.localizedDescription) }
    }

    func documents(_ arguments: [String: Any], context: ToolContext, token: DebateCancellation) -> [String: Any] {
        do {
            let folder = try ProjectCreator.documentsFolder(name: arguments["name"] as? String ?? "", location: arguments["location"] as? String)
            let exists = FileManager.default.fileExists(atPath: folder)
            if exists { _ = try ProjectProcess.documents(folder) }   // refused before the card: Git inside, too big
            let detail = folder + "\n\n" + (exists ? L("이미 있는 폴더를 문서 프로젝트로 연결해요.", "Links the existing folder as a documents project.")
                                                    : L("새 폴더를 만들어 문서 프로젝트로 연결해요.", "Creates the folder and links it as a documents project."))
                + "\n" + L("Git·GitHub는 쓰지 않아요. AI가 답할 때마다 폴더를 백업해요 (Undo).", "No Git or GitHub. The folder is backed up before each answer (Undo).")
            let deadline = Date().addingTimeInterval(900)
            let card = ProjectApproval(room: context.room, run: UUID(), title: L("문서 프로젝트 만들기", "Create a documents project"), detail: detail)
            guard ProjectCenter.shared.approve(card, token: token, deadline: deadline) else {
                if Date() >= deadline, !token.isCancelled { return ToolHub.failure("Approval timed out after 15 minutes; treated as refused. Nothing was created. Tell the user they can ask again.") }
                return ToolHub.failure("The user did not allow creating the project. Nothing new was created; stop and say so.")
            }
            let project = try ProjectCreator.createDocuments(folder)
            let title = main { addChat(project, (folder as NSString).lastPathComponent) }
            return ["content": [["type": "text", "text": "Linked \(project.root) as a documents project (no Git). A new chat \"\(title)\" linked to it is at the top of the chat list (full auto, backed up before each answer). Tell the user to open it, or its TODO board, and ask for the work there; this chat is not linked to the project."]], "isError": false]
        } catch { return ToolHub.failure(error.localizedDescription) }
    }
}

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
        if open { self.open(chat.id) }
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
    func disconnectProjectFolder(_ key: String, name: String) {
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
        let chats = conversations.filter { $0.workspace?.project.map(SidebarProjects.key) == key }
        let rooms = chats.flatMap { [$0.id] + meetings(of: $0.id).map(\.id) }
        if !runningRooms.isDisjoint(with: rooms) { return L("이 프로젝트의 채팅이 답하는 중이에요. 끝난 뒤 다시 해 주세요.", "A chat of this project is answering. Try again when it is done.") }
        let todo = TodoStore.shared.current
        let lists = Set(todo.lists.filter { $0.project.map(SidebarProjects.key) == key }.map(\.id))
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
        try ProjectInfoStore.shared.copy(from: key, to: new, name: name, folders: kept)
        let lists = Set(TodoStore.shared.current.lists.filter { $0.project.map(SidebarProjects.key) == key }.map(\.id))
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
