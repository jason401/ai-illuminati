import SwiftUI
import AppKit
import UniformTypeIdentifiers
import AILocalization

// A project folder's "Project info" tab (the other tab is its TODO board): the Git repository, the folders, files
// and links kept for the whole project (ProjectInfo.swift; every chat and TODO of it reads them), and the folders
// linked to only one chat of it, which can be made the project's.

// The tab's typing and messages (an ObservableObject: this Mac's Command Line Tools cannot build SwiftUI's @State).
final class ProjectInfoDraft: ObservableObject {
    static let shared = ProjectInfoDraft()
    @Published var linkTitle = ""
    @Published var linkURL = ""
    @Published var error: String?
    @Published var dropping = false
    @Published var shownRules: Set<String> = []   // rules files opened on the tab
}

struct ProjectInfoView: View {
    @ObservedObject var discussion: Discussion
    let project: String   // SidebarProjects.key
    @ObservedObject private var store = ProjectInfoStore.shared
    @ObservedObject private var todos = TodoStore.shared
    @ObservedObject private var draft = ProjectInfoDraft.shared

    private var group: ProjectGroup? {
        SidebarProjects.group(discussion.listedConversations.filter(\.hasContent), todo: todos.snapshot, pinned: [], names: store.names).projects.first { $0.id == project }
    }
    private var info: ProjectInfo { store.snapshot.projects[project] ?? ProjectInfo() }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                let group = self.group
                header(group)
                if let why = draft.error ?? store.saveError { Text(why).font(.system(size: 12)).foregroundColor(.red) }
                if let group, group.bindings.first?.isFolderless != true { repository(group); rules(group) }
                folders
                links
                if let group { chatOnly(group) }
            }
            .frame(maxWidth: 760, alignment: .leading)
            .padding(.horizontal, 28).padding(.vertical, 16)
            .frame(maxWidth: .infinity)
        }
        .onAppear { draft.error = nil }
    }

    private func header(_ group: ProjectGroup?) -> some View {
        let left = todos.snapshot.items.filter { (group?.lists ?? []).contains($0.listID) && $0.state != .done && $0.state != .cancelled }.count
        let chats = group?.chats.count ?? 0
        let name = group?.name ?? store.names[project] ?? (project as NSString).lastPathComponent
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(name).font(.system(size: 22, weight: .semibold)).lineLimit(1).truncationMode(.tail)
                    .onTapGesture(count: 2) { rename(name) }
                    .help(L("두 번 눌러 이름 바꾸기", "Double-click to rename"))
                Button(action: { rename(name) }) { Image(systemName: "pencil").font(.system(size: 12)).frame(width: 22, height: 22) }
                    .buttonStyle(.plainHit).foregroundColor(.secondary)
                    .help(L("프로젝트 이름 바꾸기 (폴더 이름은 그대로)", "Rename the project (the folder keeps its name)"))
            }
            HStack(spacing: 6) {
                Text(L("대화 \(chats)개", "\(chats) chats"))
                Text("·")
                Button(L("남은 할 일 \(left)개", "\(left) TODOs left")) { discussion.showBoardTab(.todo) }.buttonStyle(.link)
            }
            .font(.system(size: 12)).foregroundColor(.secondary)
        }
    }

    private func rename(_ current: String) {
        if let why = Self.askName(project, current: current) { draft.error = why } else { draft.error = nil }
    }

    // Asks for the project's name in the sidebar and on its tabs; only the shown name changes, not the folder on disk.
    // An empty name gives it back its TODO list's or folder's name. From the sidebar, a failure shows in an alert.
    static func rename(_ project: String, current: String) {
        guard let why = askName(project, current: current) else { return }
        let alert = NSAlert()
        alert.messageText = why
        alert.runModal()
    }
    private static func askName(_ project: String, current: String) -> String? {
        let alert = NSAlert()
        alert.messageText = L("프로젝트 이름 바꾸기", "Rename project")
        alert.informativeText = L("사이드바와 보드에 보이는 이름만 바뀌어요. 폴더 이름은 그대로예요. 비우면 원래 이름으로 돌아가요.",
                                  "Only the name in the sidebar and on the board changes; the folder keeps its name. Leave it empty for the original name.")
        let field = NSTextField(string: current)
        field.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: L("바꾸기", "Rename"))
        alert.addButton(withTitle: L("취소", "Cancel"))
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        do { try ProjectInfoStore.shared.rename(project, to: field.stringValue); return nil } catch { return error.localizedDescription }
    }

    // MARK: Git repository

    private func repository(_ group: ProjectGroup) -> some View {
        let documents = group.bindings.first?.isDocuments == true
        return section(documents ? L("문서 폴더 (Git 없음)", "Documents folder (no Git)") : L("Git 저장소", "Git repository"),
                       systemImage: documents ? "doc.on.doc" : "arrow.triangle.branch") {
            if documents {
                Text(L("글·그림·슬라이드를 함께 다루는 문서 프로젝트예요. AI가 답할 때마다 이 폴더를 먼저 백업해서 되돌릴 수 있어요 (클라우드에만 있는 파일과 Google 문서 수정은 빼고).",
                       "A documents project for text, figures and slides together. The folder is backed up before each answer so it can be undone (not files only in the cloud or Google Docs edits)."))
                    .font(.system(size: 12)).foregroundColor(.secondary)
            }
            ForEach(group.bindings, id: \.root) { binding in
                VStack(alignment: .leading, spacing: 4) {
                    pathRow(binding.root, directory: true, note: group.bindings.count > 1 && binding.root != group.bindings.first?.root ? L("워크트리", "Worktree") : nil) {
                        EmptyView()
                    }
                    if !binding.remoteURL.isEmpty {
                        HStack(spacing: 6) {
                            Image(systemName: "globe").font(.system(size: 11)).foregroundColor(.secondary).frame(width: 18)
                            Text((binding.remote.isEmpty ? "" : binding.remote + " · ") + Self.shownRemote(binding.remoteURL))
                                .font(.system(size: 12)).foregroundColor(.secondary).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                            Spacer(minLength: 6)
                            if let web = ProjectInfoStore.webURL(binding.remoteURL) {
                                Button(L("웹에서 열기", "Open on the web")) { NSWorkspace.shared.open(web) }.buttonStyle(.link).font(.system(size: 12))
                            }
                        }
                    }
                }
            }
            if !documents, let binding = group.bindings.first { GitBranchesView(binding: binding) }
            HStack(spacing: 8) {
                Button(L("작업 폴더 연결 끊기…", "Disconnect work folder…")) { discussion.disconnectProjectFolder(group.id, name: group.name) }
                Text(L("채팅·TODO는 남기고 폴더 없는 프로젝트로 바꿔요 (파일은 그대로)", "Keeps the chats and TODOs as a folderless project (the files stay)"))
                    .font(.system(size: 11)).foregroundColor(.secondary)
            }
        }
    }

    // A remote shown without any user or password in it.
    static func shownRemote(_ remote: String) -> String {
        guard remote.contains("://"), var parts = URLComponents(string: remote), parts.password != nil || parts.user != nil else { return remote }
        parts.user = nil; parts.password = nil
        return parts.string ?? remote
    }

    // MARK: Rules for the AIs

    // AGENTS.md / CLAUDE.md at the project's root, the rules every answer of this project gets.
    private func rules(_ group: ProjectGroup) -> some View {
        let parts = group.bindings.first.map { ProjectRules.read(root: $0.root).parts } ?? []
        return section(L("AI 작업 규칙", "Rules for the AIs"), systemImage: "list.bullet.rectangle") {
            Text(parts.isEmpty
                 ? L("프로젝트 폴더에 AGENTS.md나 CLAUDE.md를 두면 AI가 답할 때마다 읽어요.", "Put an AGENTS.md or CLAUDE.md in the project folder and the AIs read it with every answer.")
                 : L("AI가 이 프로젝트에서 답할 때마다 읽는 파일이에요.", "The AIs read these with every answer in this project."))
                .font(.system(size: 12)).foregroundColor(.secondary)
            ForEach(parts, id: \.file.path) { part in
                let file = part.file, shown = draft.shownRules.contains(file.path)
                VStack(alignment: .leading, spacing: 6) {
                    pathRow(file.path, directory: false, note: Self.ruleNote(part)) {
                        Button(shown ? L("접기", "Hide") : L("보기", "Show")) {
                            if shown { draft.shownRules.remove(file.path) } else { draft.shownRules.insert(file.path) }
                        }.controlSize(.small)
                        Button(L("열기", "Open")) { NSWorkspace.shared.open(file) }.controlSize(.small)
                            .help(L("기본 편집기에서 열기", "Open in the default editor"))
                    }
                    if shown {
                        ScrollView {
                            Text(Self.preview(part)).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading).padding(10)
                        }
                        .frame(maxHeight: 320)
                        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
        }
    }

    // The file as the AIs get it (ProjectRules.read), with what they do not get marked.
    static func ruleNote(_ part: ProjectRules.Part) -> String? {
        part.sent == nil ? L("AI에 안 감", "Not sent to the AIs") : part.cut ? L("앞부분만 AI에 감", "Only the start is sent") : nil
    }
    static func preview(_ part: ProjectRules.Part) -> String {
        if let sent = part.sent {
            return part.cut ? sent + "\n\n" + L("… (여기까지 AI에 가요. 규칙 파일은 합쳐서 \(ProjectRules.limit)자까지)", "… (the AIs get up to here; rules files share \(ProjectRules.limit) characters)") : sent
        }
        guard let data = try? Data(contentsOf: part.file), String(data: data, encoding: .utf8) != nil else {
            return L("읽을 수 없는 파일이에요 (UTF-8 텍스트가 아님).", "This file cannot be read (not UTF-8 text).")
        }
        return L("앞의 규칙 파일이 \(ProjectRules.limit)자 한도를 다 써서 이 파일은 AI에 가지 않아요.", "The rules file before it uses the whole \(ProjectRules.limit)-character limit, so the AIs do not get this one.")
    }

    // MARK: The project's folders and files

    private var folders: some View {
        section(L("프로젝트 공통 폴더·파일", "Project folders and files"), systemImage: "folder") {
            Text(L("여기 넣은 폴더와 파일은 이 프로젝트의 모든 대화와 TODO에서 AI가 읽을 수 있어요 (읽기 전용).",
                   "Every chat and TODO of this project can read these folders and files (read only)."))
                .font(.system(size: 12)).foregroundColor(.secondary)
            ForEach(info.folders) { folder in
                pathRow(folder.path, directory: folder.directory, note: nil) {
                    Button(action: { act { try store.removeFolder(folder.path, from: project) } }) {
                        Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)).frame(width: 22, height: 22)
                    }
                    .buttonStyle(.plainHit).foregroundColor(.secondary)
                    .help(L("프로젝트에서 연결 해제 (파일은 그대로)", "Unlink from the project (the files stay)"))
                }
            }
            HStack(spacing: 8) {
                Button(L("폴더·파일 추가…", "Add folders or files…")) { addFolders(choose()) }
                Text(L("Finder에서 끌어다 놓아도 돼요", "or drop them from Finder")).font(.system(size: 11)).foregroundColor(.secondary)
            }
        }
        .padding(6)
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.accentColor, lineWidth: 2).opacity(draft.dropping ? 1 : 0))
        .onDrop(of: [UTType.fileURL], isTargeted: $draft.dropping) { providers in
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url, url.isFileURL else { return }
                    DispatchQueue.main.async { addFolders([url]) }
                }
            }
            return !providers.isEmpty
        }
    }

    private func choose() -> [URL] {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.message = L("이 프로젝트의 모든 대화가 읽을 폴더나 파일", "Folders or files every chat of this project may read")
        return panel.runModal() == .OK ? panel.urls : []
    }

    private func addFolders(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        act {
            let before = info.folders.count
            try store.addFolders(urls, to: project)
            if before + urls.count > ProjectInfoStore.maxFolders, store.snapshot.projects[project]?.folders.count == ProjectInfoStore.maxFolders {
                draft.error = L("프로젝트에는 폴더·파일을 \(ProjectInfoStore.maxFolders)개까지 넣을 수 있어요.", "A project keeps up to \(ProjectInfoStore.maxFolders) folders and files.")
            }
        }
    }

    // MARK: Links

    private var links: some View {
        section(L("링크", "Links"), systemImage: "link") {
            ForEach(info.links) { link in
                HStack(spacing: 6) {
                    Image(systemName: "link").font(.system(size: 11)).foregroundColor(.secondary).frame(width: 18)
                    Button(link.title) { if let url = URL(string: link.url) { NSWorkspace.shared.open(url) } }
                        .buttonStyle(.link).font(.system(size: 13)).lineLimit(1)
                    Text(link.url).font(.system(size: 11)).foregroundColor(.secondary).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                    Spacer(minLength: 6)
                    Button(action: { act { try store.removeLink(link.id, from: project) } }) {
                        Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)).frame(width: 22, height: 22)
                    }
                    .buttonStyle(.plainHit).foregroundColor(.secondary)
                    .help(L("링크 빼기", "Remove the link"))
                }
            }
            HStack(spacing: 8) {
                TextField(L("이름 (예: 디자인 문서)", "Name (e.g. design doc)"), text: $draft.linkTitle).textFieldStyle(.roundedBorder).frame(width: 180)
                TextField("https://…", text: $draft.linkURL).textFieldStyle(.roundedBorder).onSubmit(addLink)
                Button(L("추가", "Add"), action: addLink).disabled(draft.linkURL.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            Text(L("AI에게도 이 프로젝트의 링크로 알려 줘요.", "The AIs of this project are told about these links too."))
                .font(.system(size: 11)).foregroundColor(.secondary)
        }
    }

    private func addLink() {
        act { try store.addLink(title: draft.linkTitle, url: draft.linkURL, to: project); draft.linkTitle = ""; draft.linkURL = "" }
    }

    // MARK: Linked to one chat only

    // Folders and files linked to a chat of this project that the project itself does not keep yet.
    private func chatOnly(_ group: ProjectGroup) -> some View {
        let own = Set(group.bindings.map(\.root)).union(info.folders.map(\.path))
        var found: [(root: WorkspaceRoot, chats: [String])] = []
        for chat in group.chats + group.todoRooms {
            for root in chat.workspace?.roots ?? [] where !own.contains(root.path) {
                if let i = found.firstIndex(where: { $0.root.path == root.path }) { found[i].chats.append(chat.title) }
                else { found.append((root, [chat.title])) }
            }
        }
        return Group {
            if !found.isEmpty {
                section(L("대화에만 연결된 자료", "Linked to one chat only"), systemImage: "bubble.left") {
                    Text(L("이 프로젝트의 어떤 대화에만 붙어 있는 폴더·파일이에요. [공통으로]를 누르면 모든 대화가 읽어요.",
                           "These are linked to a chat of this project only. Press [Share] and every chat can read them."))
                        .font(.system(size: 12)).foregroundColor(.secondary)
                    ForEach(found, id: \.root.path) { entry in
                        pathRow(entry.root.path, directory: entry.root.directory, note: entry.chats.prefix(2).joined(separator: ", ") + (entry.chats.count > 2 ? " …" : "")) {
                            Button(L("공통으로", "Share")) { addFolders([URL(fileURLWithPath: entry.root.path)]) }.controlSize(.small)
                                .help(L("이 프로젝트의 공통 폴더·파일에 넣기 (대화의 연결은 그대로)", "Add it to the project's folders and files (the chat keeps its link)"))
                        }
                    }
                }
            }
        }
    }

    // MARK: Pieces

    private func section<Content: View>(_ title: String, systemImage: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: systemImage).font(.system(size: 15, weight: .semibold))
            content()
        }
    }

    private func pathRow<Trailing: View>(_ path: String, directory: Bool, note: String?, @ViewBuilder trailing: () -> Trailing) -> some View {
        let exists = FileManager.default.fileExists(atPath: path)
        return HStack(spacing: 6) {
            Image(systemName: directory ? "folder" : "doc").font(.system(size: 12)).foregroundColor(.secondary).frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text((path as NSString).lastPathComponent).font(.system(size: 13)).lineLimit(1)
                    if let note, !note.isEmpty { Text(note).font(.system(size: 11)).foregroundColor(.secondary).lineLimit(1) }
                    if !exists { Text(L("없음", "Missing")).font(.system(size: 11, weight: .medium)).foregroundColor(.red) }
                }
                Text((path as NSString).abbreviatingWithTildeInPath).font(.system(size: 11)).foregroundColor(.secondary)
                    .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
            }
            .opacity(exists ? 1 : 0.6)
            Spacer(minLength: 6)
            if exists {
                Button(action: { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }) {
                    Image(systemName: "magnifyingglass").font(.system(size: 11)).frame(width: 22, height: 22)
                }
                .buttonStyle(.plainHit).foregroundColor(.secondary)
                .help(L("Finder에서 보기", "Show in Finder"))
            }
            trailing()
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
    }

    private func act(_ change: () throws -> Void) {
        do { draft.error = nil; try change() } catch { draft.error = error.localizedDescription }
    }
}

// The repository's branches, read only (GitBranches.swift): local values when shown, origin only after the refresh button.
struct GitBranchesView: View {
    let binding: ProjectBinding
    @ObservedObject private var store = GitBranchStore.shared

    var body: some View {
        let report = store.reports[binding.root], busy = store.busy.contains(binding.root)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                if let report, let line = GitBranches.summary(report) {
                    Image(systemName: report.pending.map { $0.ahead > 0 } == true ? "clock" : "checkmark.circle")
                        .font(.system(size: 12)).foregroundColor(report.pending.map { $0.ahead > 0 } == true ? .orange : .green)
                    Text(line).font(.system(size: 12, weight: .medium))
                } else {
                    Text(report == nil ? L("브랜치 읽는 중…", "Reading branches…") : L("브랜치", "Branches")).font(.system(size: 12, weight: .medium))
                }
                Spacer(minLength: 6)
                if busy { ProgressView().controlSize(.small).frame(width: 22, height: 22) }
                Text(Self.checked(report?.fetched)).font(.system(size: 11)).foregroundColor(.secondary)
                Button(action: { store.load(binding, fetch: true) }) {
                    Image(systemName: "arrow.clockwise").font(.system(size: 11)).frame(width: 22, height: 22)
                }
                .buttonStyle(.plainHit).foregroundColor(.secondary).disabled(busy)
                .help(L("origin에서 새로 가져오기 (git fetch)", "Fetch from origin (git fetch)"))
            }
            if let why = report?.error { Text(why).font(.system(size: 11)).foregroundColor(.orange) }
            if let report, let flow = GitBranches.flow(report) { Text(flow).font(.system(size: 11)).foregroundColor(.secondary) }
            let lines = report.map(GitBranches.lines) ?? []
            ForEach(GitBranches.main(lines)) { line in mainLine(line) }
            ForEach(GitBranches.groups(lines)) { group in groupLine(group) }
            if let hidden = report?.hidden, hidden > 0 {
                Text(L("브랜치가 너무 많아 \(hidden)개는 읽지 않았어요", "\(hidden) more branches not read (too many)")).font(.system(size: 11)).foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
        // Local values are read again every time it is shown (commits or checkouts since); the old ones stay meanwhile.
        .onAppear { DispatchQueue.main.async { store.load(binding) } }
    }

    // stable, main and the checked-out branch: name, what it is for, where it lives, version and last commit date.
    private func mainLine(_ line: GitBranchLine) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.triangle.branch").font(.system(size: 10)).foregroundColor(.secondary).frame(width: 16)
            Text(line.branch).font(.system(size: 12, weight: .semibold)).lineLimit(1)
            if let label = GitBranches.label(line.role) {
                Text(label).font(.system(size: 10, weight: .medium)).padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Self.tint(line.role).opacity(0.18), in: Capsule()).foregroundColor(Self.tint(line.role))
            }
            if line.current { Text(L("(현재)", "(current)")).font(.system(size: 11)).foregroundColor(.accentColor) }
            Text(GitBranches.purpose(line)).font(.system(size: 11)).foregroundColor(.secondary).lineLimit(1)
            Spacer(minLength: 6)
            Text(details(line)).font(.system(size: 11)).foregroundColor(.secondary).lineLimit(1)
        }
        .padding(.vertical, 2)
    }

    // Side branches of one kind on one line; the names open below it.
    private func groupLine(_ group: GitBranchGroup) -> some View {
        let key = binding.root + "\u{0}" + group.key, open = store.expanded.contains(key)
        return VStack(alignment: .leading, spacing: 2) {
            Button(action: { if open { store.expanded.remove(key) } else { store.expanded.insert(key) } }) {
                HStack(spacing: 6) {
                    Image(systemName: open ? "chevron.down" : "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundColor(.secondary).frame(width: 16)
                    Text(GitBranches.purpose(group)).font(.system(size: 12)).foregroundColor(.primary)
                    Text(L("\(group.lines.count)개", "\(group.lines.count)")).font(.system(size: 11)).foregroundColor(.secondary)
                    Spacer(minLength: 6)
                    Text(([GitBranches.place(group)] + [group.latest.map { L("최근 ", "latest ") + Self.day($0) }].compactMap { $0 }).joined(separator: " · "))
                        .font(.system(size: 11)).foregroundColor(.secondary).lineLimit(1)
                }.contentShape(Rectangle())
            }
            .buttonStyle(.plainHit)
            if open {
                ForEach(group.lines) { line in
                    HStack(spacing: 6) {
                        Text(line.branch).font(.system(size: 11, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                        if let tree = line.worktree { Text(L("(워크트리에서 사용 중)", "(in a worktree)")).font(.system(size: 11)).foregroundColor(.secondary).help(tree) }
                        Spacer(minLength: 6)
                        Text(details(line)).font(.system(size: 11)).foregroundColor(.secondary).lineLimit(1)
                    }
                    .padding(.leading, 22).textSelection(.enabled)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private func details(_ line: GitBranchLine) -> String {
        ([GitBranches.sync(line) ?? GitBranches.place(line.place), line.version, line.date.map(Self.day)].compactMap { $0 }).joined(separator: " · ")
    }

    static func tint(_ role: GitBranchRow.Role) -> Color { role == .deploy ? .green : role == .beta ? .blue : .orange }
    static func day(_ date: Date) -> String {
        let f = DateFormatter(); f.locale = AppLanguage.current.locale; f.dateStyle = .medium; f.timeStyle = .short
        return f.string(from: date)
    }
    static func checked(_ date: Date?) -> String {
        guard let date else { return L("가져온 적 없음", "Never fetched") }
        return L("마지막 확인 ", "Last checked ") + day(date)
    }
}
