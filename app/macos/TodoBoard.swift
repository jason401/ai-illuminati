import SwiftUI
import AppKit
import UniformTypeIdentifiers

// The TODO board (Todo.swift): sidebar entry with the count waiting for the user, the board shown in place of the
// chat, and the report cards above the message box of a TODO's own chat and of the chat it was written from.

struct TodoSidebarSection: View {
    @ObservedObject var discussion: Discussion
    @ObservedObject private var store = TodoStore.shared
    @ObservedObject private var folds = SidebarFold.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            SidebarHeader(title: "TODO", fold: "todo", badge: store.waitingForUser)
            if !folds.isFolded("todo") { boardRow }
        }
    }

    // Every project's TODOs (the folders below have one project's each).
    private var boardRow: some View {
        VStack(alignment: .leading, spacing: 1) {
            let selected = discussion.viewingBoard && discussion.boardProject == nil
            let hovered = discussion.hoverKey == "todo.board"
            Button(action: { discussion.openBoard(project: nil) }) {
                HStack(spacing: 8) {
                    Image(systemName: "checklist").frame(width: 18)
                    Text(L("전체 할 일 보드", "All TODOs"))
                    Spacer()
                    let count = store.waitingForUser
                    if count > 0 {
                        Text("\(count)").font(.system(size: 11, weight: .semibold)).foregroundColor(.white)
                            .padding(.horizontal, 6).frame(minWidth: 18, minHeight: 18)
                            .background(Color.orange, in: Capsule())
                            .help(L("네 결정이나 확인을 기다리는 TODO", "TODOs waiting for your decision or check"))
                    }
                }
                .font(.system(size: 13))
                .padding(.horizontal, 10).frame(height: 30)
                .background(selected ? Color.primary.opacity(0.1) : hovered ? Color.primary.opacity(0.06) : .clear, in: RoundedRectangle(cornerRadius: 8))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plainHit)
            .onHover { discussion.hover("todo.board", $0) }
        }
    }
}

extension TodoItem.State {
    var title: String {
        switch self {
        case .draft: return L("초안", "Draft")
        case .ready: return L("대기", "Ready")
        case .running: return L("진행 중", "Running")
        case .review: return L("확인 대기", "Check")
        case .done: return L("완료", "Done")
        case .needsYou: return L("네 결정 필요", "Needs you")
        case .cancelled: return L("취소", "Cancelled")
        }
    }
    var color: Color {
        switch self {
        case .draft, .cancelled: return .secondary
        case .ready: return .green
        case .running: return .blue
        case .review: return .yellow
        case .done: return .purple
        case .needsYou: return .orange
        }
    }
}

// What is being typed on the board and in the cards (no @State: see DriveUI.swift).
final class TodoDraft: ObservableObject {
    static let shared = TodoDraft()
    @Published var title = ""
    @Published var detail = ""
    struct File: Equatable { var id = UUID(); var url: URL }
    @Published var files: [File] = []   // photos and files to attach (copied in when the TODO is added)
    @Published var dropFolders: [URL] = []   // temporary folders of dropped Photos/screenshot files, removed once added
    @Published var dropTarget: UUID?   // where a drag is over now: a TODO, or `addBar`
    static let addBar = UUID()
    @Published var projectRoot = ""
    @Published var after: Set<UUID> = []
    @Published var askFirst = false
    @Published var error: String?
    @Published var showDone = false
    @Published var replies: [UUID: String] = [:]   // a card's answer or change request, by TODO
    // Editing a TODO the AI has not taken yet (TodoStore.editable); the scheduler leaves it alone meanwhile.
    @Published private(set) var editing: UUID?
    @Published var editTitle = ""
    @Published var editDetail = ""
    @Published var editAskFirst = false

    func beginEdit(_ item: TodoItem) {
        // Another TODO open for editing: saved first (it would otherwise lose the text and start with the old one).
        if let open = editing, open != item.id {
            if let other = TodoStore.shared.current.item(open), TodoStore.editable(other) {
                guard !editTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    error = L("고치던 TODO의 제목이 비어 있어요. 먼저 저장하거나 취소해 주세요.", "The TODO you are editing has no title. Save or cancel it first."); return
                }
                saveEdit()
                guard editing == nil else { return }   // not saved: its editor stays open with the error
            }
        }
        editTitle = item.title; editDetail = item.detail; editAskFirst = item.askFirst
        editing = item.id; TodoScheduler.shared?.editing = item.id
    }
    func endEdit() { editing = nil; TodoScheduler.shared?.editing = nil }
    func saveEdit() {
        guard let id = editing, !editTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        do { try TodoStore.shared.edit(id, title: editTitle, detail: editDetail, askFirst: editAskFirst); error = nil; endEdit() }
        catch { self.error = error.localizedDescription }
    }
}

struct TodoBoardView: View {
    @ObservedObject var discussion: Discussion
    @ObservedObject private var store = TodoStore.shared
    @ObservedObject private var draft = TodoDraft.shared

    // Projects to write TODOs for: every linked Git project of the chats (newest first); on one project's board
    // only its roots (a repository with several worktrees has one per root).
    private var projects: [(name: String, binding: ProjectBinding)] {
        var seen = Set<String>(), result: [(String, ProjectBinding)] = []
        let mine = { (p: ProjectBinding) in discussion.boardProject.map { SidebarProjects.key(p) == $0 } ?? true }
        for list in store.snapshot.lists { if let p = list.project, mine(p), seen.insert(p.root).inserted { result.append((list.title, p)) } }
        for chat in discussion.conversations.sorted(by: { $0.updatedAt > $1.updatedAt }) {
            if let p = chat.workspace?.project, mine(p), seen.insert(p.root).inserted { result.append(((p.root as NSString).lastPathComponent, p)) }
        }
        return result
    }

    private var shownLists: [TodoList] {
        store.snapshot.lists.filter { list in discussion.boardProject.map { list.project.map(SidebarProjects.key) == $0 } ?? true }
    }

    // The root a new TODO goes to: the one picked, if it is on this board, else the newest.
    private func pickedRoot(_ options: [(name: String, binding: ProjectBinding)]) -> String {
        options.contains { $0.binding.root == draft.projectRoot } ? draft.projectRoot : options.first?.binding.root ?? ""
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                let lists = shownLists
                if let scheduler = TodoScheduler.shared {
                    TodoBoardHeader(scheduler: scheduler, discussion: discussion,
                                    project: discussion.boardProject.map { _ in projects.first?.name ?? lists.first?.title ?? "" }, lists: Set(lists.map(\.id)))
                }
                if let error = draft.error ?? store.saveError { Text(error).font(.system(size: 12)).foregroundColor(.red) }
                ForEach(lists) { list in listView(list) }
                if lists.isEmpty {
                    Text(L("아직 TODO가 없어요. 아래에서 프로젝트를 고르고 적어 주세요.", "No TODOs yet. Pick a project below and write one."))
                        .font(.system(size: 13)).foregroundColor(.secondary)
                }
                Toggle(L("완료·취소된 것도 보기", "Show done and cancelled"), isOn: $draft.showDone).toggleStyle(.checkbox).font(.system(size: 12))
                addBar
            }
            .frame(maxWidth: 760, alignment: .leading)
            .padding(.horizontal, 28).padding(.vertical, 16)
            .frame(maxWidth: .infinity)
        }
        .onDisappear { draft.endEdit() }   // an edit left open would hold the TODO back
    }

    private func listView(_ list: TodoList) -> some View {
        let rows = store.snapshot.ordered(list.id).filter { draft.showDone || ($0.state != .done && $0.state != .cancelled) }
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Text(list.title).font(.system(size: 15, weight: .semibold))
                Picker("", selection: Binding(get: { list.sequential }, set: { value in act { try store.setList(list.id, sequential: value) } })) {
                    Text(L("순서대로", "In order")).tag(true)
                    Text(L("상관없음", "Any order")).tag(false)
                }
                .pickerStyle(.segmented).fixedSize()
                if list.sequential {
                    Toggle(L("내 확인 후 다음", "Next after my check"), isOn: Binding(get: { list.waitForDone }, set: { value in act { try store.setList(list.id, waitForDone: value) } }))
                        .toggleStyle(.checkbox).font(.system(size: 12))
                        .help(L("켜면 앞 TODO에 [완료]를 눌러야 다음이 시작돼요. 끄면 앞 TODO가 확인 대기가 될 때 시작해요.",
                                "On: the next starts after you press Done. Off: it starts when the previous one waits for your check."))
                }
                Spacer()
                pauseControl(list)
            }
            if let scheduler = TodoScheduler.shared { TodoCrewRow(list: list, scheduler: scheduler, discussion: discussion, error: { draft.error = $0 }) }
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, item in row(item, index: index + 1, list: list) }
        }
    }

    // ⏸ Pause / Resume for one list, with what holds it: paused now, or going on only up to a TODO.
    @ViewBuilder private func pauseControl(_ list: TodoList) -> some View {
        let stop = list.stopAfter.flatMap(store.snapshot.item)
        if list.paused {
            Label(L("멈춤", "Paused"), systemImage: "pause.fill").font(.system(size: 12, weight: .medium)).foregroundColor(.orange)
        } else if let stop {
            Label(L("「\(stop.title)」까지 진행", "Up to \"\(stop.title)\""), systemImage: "flag.checkered").font(.system(size: 12, weight: .medium)).foregroundColor(.orange).lineLimit(1)
        }
        if list.paused || stop != nil {
            Button(L("다시 진행", "Resume")) { act { try store.resume(lists: [list.id]); TodoScheduler.shared?.wake() } }.controlSize(.small)
                .help(L("대기 중인 TODO가 다시 차례대로 시작돼요. 초안은 그대로예요(▶ 작업 시작을 누르면 초안도 대기로 바뀌어요).",
                        "Ready TODOs start again in turn. Drafts stay drafts (▶ Start also makes them ready)."))
        } else {
            Button(action: { act { try store.pause(lists: [list.id]) } }) { Label(L("멈추기", "Pause"), systemImage: "pause") }.controlSize(.small)
                .help(L("지금 하는 TODO는 마치고, 다음 TODO부터 자동으로 시작하지 않아요.", "The running TODO finishes; the next ones do not start by themselves."))
        }
    }

    private func row(_ item: TodoItem, index: Int, list: TodoList) -> some View {
        let data = store.snapshot
        let waits = data.blockers(item).compactMap(data.item).filter { !data.satisfied($0, for: item) && $0.state != .cancelled }
        let editing = draft.editing == item.id && TodoStore.editable(item)
        return VStack(alignment: .leading, spacing: 4) {
            if editing { editor(item) } else {
            HStack(spacing: 8) {
                Text(list.sequential ? "\(index). " + item.title : item.title).font(.system(size: 13, weight: .medium))
                    .foregroundColor(item.state == .draft ? .secondary : .primary).lineLimit(2)
                Spacer(minLength: 6)
                if item.state == .ready, !waits.isEmpty {
                    Label(waits.map(\.title).joined(separator: ", ") + L(" 기다림", " first"), systemImage: "hourglass").font(.system(size: 11)).foregroundColor(.secondary).lineLimit(1)
                }
                Text(item.state.title + (item.state == .running ? runner(item) : "") + (item.state == .ready && data.stopped(item) ? L(" · 멈춤", " · paused") : "")).font(.system(size: 12, weight: .medium)).foregroundColor(item.state.color)
                if item.state == .review {
                    Button(L("완료", "Done")) { store.accept(item.id) }.buttonStyle(.borderedProminent).controlSize(.small)
                }
                if TodoStore.editable(item) {
                    Button(action: { draft.beginEdit(item) }) { Image(systemName: "pencil").frame(width: 22, height: 22) }
                        .buttonStyle(.plainHit).help(L("고치기 (AI가 아직 가져가지 않은 TODO)", "Edit (the AI has not taken it yet)"))
                }
                if let room = item.room {
                    Button(action: { discussion.open(room) }) { Image(systemName: "bubble.left") }.buttonStyle(.plainHit).help(L("이 TODO의 채팅 열기", "Open this TODO's chat"))
                }
                Menu {
                    if TodoStore.editable(item) { Button(L("고치기…", "Edit…")) { draft.beginEdit(item) } }
                    Button(L("위로", "Move up")) { act { try store.move(item.id, by: -1) } }
                    Button(L("아래로", "Move down")) { act { try store.move(item.id, by: 1) } }
                    Menu(L("먼저 끝나야 할 TODO", "Must finish first")) {
                        ForEach(data.items.filter { $0.id != item.id && $0.state != .cancelled }) { other in
                            Button((item.after.contains(other.id) ? "✓ " : "") + other.title) {
                                act { try store.setAfter(item.id, item.after.contains(other.id) ? item.after.filter { $0 != other.id } : item.after + [other.id]) }
                            }
                        }
                    }
                    if item.state != .running && item.state != .done && item.state != .cancelled {
                        Button(L("사진·파일 첨부…", "Attach photos or files…")) { let urls = Self.chooseFiles(); if !urls.isEmpty { act { try store.attach(item.id, files: urls) } } }
                    }
                    if item.state == .draft { Button(L("대기로 (바로 가져가도 됨)", "Make ready")) { try? store.change(item.id) { $0.state = .ready } } }
                    if item.state == .ready { Button(L("초안으로 되돌리기", "Back to draft")) { try? store.change(item.id) { $0.state = .draft } } }
                    Button(list.stopAfter == item.id ? L("멈춤 지점 지우기", "Remove the stop point") : L("여기까지 하고 멈추기", "Stop after this one")) {
                        act { try store.stop(after: item.id); TodoScheduler.shared?.wake() }
                    }
                    Divider()
                    if item.state != .done && item.state != .cancelled { Button(L("그만 (취소)", "Stop (cancel)")) { TodoScheduler.shared?.cancel(item.id) } }
                    Button(L("삭제", "Delete"), role: .destructive) { act { try store.delete(item.id) } }.disabled(item.state == .running)
                } label: { Image(systemName: "ellipsis") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            }
            if !item.detail.isEmpty { Text(item.detail).font(.system(size: 12)).foregroundColor(.secondary).lineLimit(3) }
            if item.startedAt != nil {
                let live = item.state == .running || item.state == .review || item.state == .needsYou
                TimelineView(.periodic(from: .now, by: live ? 30 : 3600)) { context in
                    if let line = item.timeLine(at: context.date) {
                        Label(line, systemImage: "clock").font(.system(size: 11)).foregroundColor(.secondary).lineLimit(1)
                            .help(L("AI 작업: AI가 맡아 일한 시간(검수 포함, 여러 번 시도한 것 합침). 확인 기다림: 확인이나 답을 기다린 시간. 시작 후: 처음 시작부터 끝(완료·취소) 또는 지금까지.",
                                    "AI work: time the AI had it (review included, all attempts). Waiting for you: time it waited for your check or answer. Since start: from the first start to done or cancelled, or now."))
                    }
                }
            }
            }
            if !item.attachments.isEmpty {
                TodoChips(items: item.attachments.map { a in (a.id, a.name, a.image) },
                          open: { id in if let a = item.attachments.first(where: { $0.id == id }) { NSWorkspace.shared.open(store.file(item.id, a)) } },
                          remove: item.state == .running ? nil : { id in act { try store.detach(item.id, id) } })
            }
            if item.state == .review || item.state == .needsYou { TodoCard(item: item, discussion: discussion, compact: true) }
            if list.stopAfter == item.id, !list.paused {
                Label(L("이 TODO까지 하고 멈춰요. 아래 TODO는 자동으로 시작하지 않아요.", "Stops after this TODO; the ones below do not start by themselves."), systemImage: "flag.checkered")
                    .font(.system(size: 11)).foregroundColor(.orange)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 9))
        .overlay(item.state == .draft ? RoundedRectangle(cornerRadius: 9).strokeBorder(Color.secondary.opacity(0.4), style: StrokeStyle(lineWidth: 1, dash: [5, 4])) : nil)
        .overlay(draft.dropTarget == item.id ? RoundedRectangle(cornerRadius: 9).strokeBorder(Color.accentColor, lineWidth: 2) : nil)
        // Photos or files dropped on a TODO the AI is not working on are attached to it right away.
        .onDrop(of: [UTType.fileURL, UTType.image, UTType.item],
                delegate: TodoFileDrop(target: item.id, accepts: item.state != .running && item.state != .done && item.state != .cancelled) { urls, folder in
            defer { if let folder { try? FileManager.default.removeItem(at: folder) } }
            if urls.isEmpty { draft.error = L("파일을 첨부할 수 없어요.", "Could not attach the file."); return }
            act { try store.attach(item.id, files: urls) }
        })
    }

    // In place of the title and details while editing: [Cancel] / [Save] (Return in the title saves, Esc cancels).
    private func editor(_ item: TodoItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField(L("할 일", "TODO"), text: $draft.editTitle).textFieldStyle(.roundedBorder).onSubmit { draft.saveEdit() }
            TextField(L("자세한 내용 (선택)", "Details (optional)"), text: $draft.editDetail, axis: .vertical).textFieldStyle(.roundedBorder).lineLimit(1...8)
            HStack(spacing: 8) {
                Picker("", selection: $draft.editAskFirst) {
                    Text(L("가정하고 표시", "Assume and note")).tag(false)
                    Text(L("먼저 묻기", "Ask first")).tag(true)
                }
                .pickerStyle(.segmented).fixedSize()
                Text(L("고치는 동안은 시작하지 않아요", "It does not start while you edit")).foregroundColor(.secondary)
                Spacer()
                Button(L("취소", "Cancel")) { draft.endEdit() }
                Button(L("저장", "Save")) { draft.saveEdit() }.buttonStyle(.borderedProminent)
                    .disabled(draft.editTitle.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .font(.system(size: 12)).controlSize(.small)
        }
        .onExitCommand { draft.endEdit() }
    }

    private func runner(_ item: TodoItem) -> String {
        guard let room = item.room, let lead = discussion.conversation(room).configuration?.leadID,
              let account = discussion.model.accounts.first(where: { $0.id == lead }) else { return "" }
        return " · " + discussion.label(account)
    }

    private var addBar: some View {
        let options = projects
        let root = pickedRoot(options)
        return VStack(alignment: .leading, spacing: 8) {
            TextField(L("+ 할 일 추가…", "+ Add a TODO…"), text: $draft.title).textFieldStyle(.roundedBorder).onSubmit(add)
            TextField(L("자세한 내용 (선택)", "Details (optional)"), text: $draft.detail, axis: .vertical).textFieldStyle(.roundedBorder).lineLimit(1...5)
            if !draft.files.isEmpty {
                TodoChips(items: draft.files.map { f in (f.id, f.url.lastPathComponent, (try? f.url.resourceValues(forKeys: [.contentTypeKey]).contentType?.conforms(to: .image)) == true) },
                          open: { id in if let f = draft.files.first(where: { $0.id == id }) { NSWorkspace.shared.open(f.url) } },
                          remove: { id in draft.files.removeAll { $0.id == id } })
            }
            HStack(spacing: 10) {
                // One project's board: its only root needs no picking.
                if discussion.boardProject == nil || options.count > 1 {
                    Picker(L("프로젝트", "Project"), selection: Binding(get: { root }, set: { draft.projectRoot = $0 })) {
                        ForEach(options, id: \.binding.root) { option in
                            Text(discussion.boardProject == nil ? option.name : (option.binding.root as NSString).lastPathComponent).tag(option.binding.root)
                        }
                    }
                    .fixedSize()
                }
                Button(action: { addDraftFiles(Self.chooseFiles()) }) { Label(L("첨부", "Attach"), systemImage: "paperclip") }
                    .help(L("사진이나 파일을 첨부해요 (여기나 TODO 줄 위에 끌어다 놓아도 돼요 · 사진 앱·스크린샷도)", "Attach photos or files (or drop them here or on a TODO, also from Photos or a screenshot)"))
                Menu(draft.after.isEmpty ? L("먼저 끝나야 할 TODO", "Must finish first") : L("먼저: \(draft.after.count)개", "First: \(draft.after.count)")) {
                    ForEach(store.snapshot.items.filter { $0.state != .done && $0.state != .cancelled }) { other in
                        Button((draft.after.contains(other.id) ? "✓ " : "") + other.title) { if draft.after.contains(other.id) { draft.after.remove(other.id) } else { draft.after.insert(other.id) } }
                    }
                }
                .fixedSize()
                Picker("", selection: $draft.askFirst) {
                    Text(L("가정하고 표시", "Assume and note")).tag(false)
                    Text(L("먼저 묻기", "Ask first")).tag(true)
                }
                .pickerStyle(.segmented).fixedSize()
                Spacer()
                Button(L("추가", "Add"), action: add).disabled(draft.title.trimmingCharacters(in: .whitespaces).isEmpty || root.isEmpty)
            }
            .font(.system(size: 12))
            if options.isEmpty {
                Text(L("Git 프로젝트가 연결된 채팅이 있어야 TODO를 적을 수 있어요.", "Link a Git project to a chat first; TODOs are written for a project."))
                    .font(.system(size: 12)).foregroundColor(.secondary)
            }
        }
        .padding(12)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
        .overlay(draft.dropTarget == TodoDraft.addBar ? RoundedRectangle(cornerRadius: 10).strokeBorder(Color.accentColor, lineWidth: 2) : nil)
        .onDrop(of: [UTType.fileURL, UTType.image, UTType.item], delegate: TodoFileDrop(target: TodoDraft.addBar, accepts: true) { urls, folder in
            if urls.isEmpty { draft.error = L("파일을 첨부할 수 없어요.", "Could not attach the file."); if let folder { try? FileManager.default.removeItem(at: folder) }; return }
            // Promised files (Photos, screenshots) live in a temporary folder until the TODO is added.
            if let folder { draft.dropFolders.append(folder) }
            addDraftFiles(urls)
        })
    }

    static func chooseFiles() -> [URL] {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.message = L("TODO에 첨부할 사진이나 파일", "Photos or files for the TODO")
        return panel.runModal() == .OK ? panel.urls : []
    }

    private func addDraftFiles(_ urls: [URL]) {
        let fresh = urls.filter { url in !draft.files.contains { $0.url == url } }.map { TodoDraft.File(url: $0) }
        guard draft.files.count + fresh.count <= TodoStore.maxAttachments else {
            draft.error = L("TODO 하나에 \(TodoStore.maxAttachments)개까지 첨부할 수 있어요.", "Up to \(TodoStore.maxAttachments) attachments per TODO."); return
        }
        draft.files += fresh
    }

    private func add() {
        let text = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let options = projects
        let root = pickedRoot(options)
        guard !text.isEmpty, let project = options.first(where: { $0.binding.root == root }) else { return }
        // The chat open before the board, when it works on the same project, gets the report card too.
        let origin = discussion.current.workspace?.project?.root == root && !store.snapshot.items.contains { $0.room == discussion.currentID } ? discussion.currentID : nil
        // Written for a project worked on in an Enterprise chat: its TODOs keep that lock.
        let lock = (discussion.current.workspace?.project?.root == root ? discussion.current.enterpriseLock : nil)
            ?? discussion.conversations.first { $0.workspace?.project?.root == root && $0.enterpriseLock != nil }?.enterpriseLock
        act {
            try store.add(title: text, detail: draft.detail.trimmingCharacters(in: .whitespacesAndNewlines), files: draft.files.map(\.url), project: project.binding, projectName: project.name,
                          after: Array(draft.after), askFirst: draft.askFirst, originRoom: origin, lock: lock)
            draft.title = ""; draft.detail = ""; draft.files = []; draft.after = []
            for folder in draft.dropFolders { try? FileManager.default.removeItem(at: folder) }
            draft.dropFolders = []
        }
    }

    private func act(_ change: () throws -> Void) {
        do { try change(); draft.error = nil } catch { draft.error = error.localizedDescription }
    }
}

// Which AIs take a project's TODOs: [AI ▾] picks them (automatic = every Claude/Codex with 30% left), then who
// works now (a running TODO's chat) or who would if one started now, or why nobody can.
struct TodoCrewRow: View {
    let list: TodoList
    let scheduler: TodoScheduler
    @ObservedObject var discussion: Discussion
    let error: (String?) -> Void

    private var workers: [Account] { discussion.model.accounts.filter { [.claude, .codex].contains($0.provider) } }
    private var lock: EnterpriseLock? { scheduler.lock(for: list) }
    private func name(_ id: String) -> String { discussion.model.accounts.first { $0.id == id }.map(discussion.label) ?? L("없어진 계정", "Removed account") }
    private func left(_ account: Account) -> String {
        let usage = discussion.model.latestUsage[account.id]
        return L(" · 5시간 \(Int(AutoPick.fiveHour(usage)))% · 주간 \(Int(AutoPick.weekly(usage)))% 남음", " · 5h \(Int(AutoPick.fiveHour(usage)))% · week \(Int(AutoPick.weekly(usage)))% left")
    }
    private func save(_ accounts: [String]) {
        do { try TodoStore.shared.setList(list.id, accounts: accounts); error(nil) } catch { self.error(error.localizedDescription) }
    }
    // Picking one while automatic: only that one. The last one picked cannot be taken off (that would mean every account).
    private func toggle(_ id: String) {
        if list.accounts.isEmpty { save([id]) }
        else if list.accounts.contains(id) { if list.accounts.count > 1 { save(list.accounts.filter { $0 != id }) } }
        else { save(list.accounts + [id]) }
    }

    var body: some View {
        let lock = self.lock
        let gone = list.accounts.filter { id in !workers.contains { $0.id == id } }
        HStack(spacing: 8) {
            Menu {
                Button((list.accounts.isEmpty ? "✓ " : "") + L("자동 (Claude·Codex 모두)", "Automatic (every Claude/Codex)")) { save([]) }
                Divider()
                ForEach(workers, id: \.id) { account in
                    let picked = list.accounts.contains(account.id)
                    let allowed = Enterprise.permits(account, lock: lock)
                    Button((picked ? "✓ " : "") + discussion.label(account) + (allowed ? left(account) : L(" · 회사·학교 잠금 밖", " · outside the Enterprise lock"))) { toggle(account.id) }
                        .disabled(!allowed && !picked || picked && list.accounts.count == 1)
                }
                if !gone.isEmpty {
                    Divider()
                    ForEach(gone, id: \.self) { id in
                        // The last one stays (taking it off would mean every account): pick another first.
                        Button(L("없어진 계정 빼기", "Remove a removed account") + " (\(id.prefix(8)))") { save(list.accounts.filter { $0 != id }) }
                            .disabled(list.accounts.count == 1)
                    }
                }
            } label: {
                Label(list.accounts.isEmpty ? L("일할 AI: 자동", "AIs: automatic") : L("일할 AI: ", "AIs: ") + list.accounts.map(name).joined(separator: ", "), systemImage: "person.2")
            }
            .menuStyle(.borderlessButton).fixedSize()
            .help(L("이 프로젝트의 TODO를 맡을 AI 계정이에요. 남은 사용량이 많은 계정이 일하고, 다른 하나가 검수해요. 바꾸면 다음에 시작할 때부터 적용돼요 (진행 중인 일은 그대로).",
                    "The AI accounts that take this project's TODOs. The one with the most usage left works, another reviews. Changes apply from the next start (running work goes on)."))
            status
            Spacer()
        }
        .font(.system(size: 12))
    }

    // A running TODO's chat has its crew; otherwise the one a start now would get.
    @ViewBuilder private var status: some View {
        let running = TodoStore.shared.snapshot.ordered(list.id).first { $0.state == .running }
        if let room = running?.room, let config = discussion.conversation(room).configuration, let lead = config.leadID {
            let others = (config.memberIDs ?? []).filter { $0 != lead }
            Text(L("지금 일하는 중: ", "Working now: ") + name(lead) + (others.isEmpty ? L(" · 검수 없음", " · no review") : L(" · 검수 ", " · review ") + others.map(name).joined(separator: ", ")))
                .foregroundColor(.blue).lineLimit(1)
        } else if let crew = scheduler.crew(for: list) {
            Text(L("지금 시작하면: ", "If started now: ") + discussion.label(crew.lead) + (crew.reviewer.map { L(" · 검수 ", " · review ") + discussion.label($0) } ?? L(" · 검수 없음", " · no review")))
                .foregroundColor(.secondary).lineLimit(1)
        } else {
            Text(TodoScheduler.noCrew(list.accounts, accounts: discussion.model.accounts, lock: lock)).foregroundColor(.orange).lineLimit(2)
        }
    }
}

// Photos and files dragged onto the add bar or a TODO row: from Finder, the Photos app or a screenshot
// thumbnail (PictureDrop). `receive` runs on the main thread; a temporary `folder` is the caller's to remove.
private struct TodoFileDrop: DropDelegate {
    let target: UUID
    let accepts: Bool
    let receive: ([URL], URL?) -> Void
    func validateDrop(info: DropInfo) -> Bool {
        accepts && (info.hasItemsConforming(to: [UTType.fileURL, UTType.image]) || PictureDrop.hasPromises())
    }
    func dropEntered(info: DropInfo) { if validateDrop(info: info) { TodoDraft.shared.dropTarget = target } }
    func dropExited(info: DropInfo) { if TodoDraft.shared.dropTarget == target { TodoDraft.shared.dropTarget = nil } }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: validateDrop(info: info) ? .copy : .forbidden) }
    func performDrop(info: DropInfo) -> Bool {
        TodoDraft.shared.dropTarget = nil
        guard validateDrop(info: info) else { return false }
        PictureDrop.receive(info.itemProviders(for: [UTType.image]), done: receive)
        return true
    }
}

// Attached photos and files: click opens one, × takes it off (when `remove` is given).
struct TodoChips: View {
    let items: [(id: UUID, name: String, image: Bool)]
    let open: (UUID) -> Void
    let remove: ((UUID) -> Void)?
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(items, id: \.id) { item in
                    HStack(spacing: 4) {
                        Button(action: { open(item.id) }) {
                            Label(item.name, systemImage: item.image ? "photo" : "paperclip").lineLimit(1).frame(maxWidth: 200, minHeight: 22)
                        }
                        .buttonStyle(.plainHit).help(L("열기", "Open"))
                        if let remove {
                            Button(action: { remove(item.id) }) { Image(systemName: "xmark").frame(width: 22, height: 22) }
                                .buttonStyle(.plainHit).help(L("첨부 빼기", "Remove attachment"))
                        }
                    }
                    .font(.system(size: 11))
                    .padding(.leading, 8).padding(.trailing, remove == nil ? 8 : 2)
                    .background(Color.primary.opacity(0.07), in: Capsule())
                }
            }
        }
    }
}

// Title, when the board is checked next, why nothing starts, and ▶ Start now.
// On one project's board (project: its name) ▶ starts only its drafts, and a link goes back to every project's.
struct TodoBoardHeader: View {
    @ObservedObject var scheduler: TodoScheduler
    @ObservedObject var discussion: Discussion
    var project: String? = nil
    var lists: Set<UUID> = []
    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(project.map { $0 + L(" · 할 일", " · TODOs") } ?? L("전체 할 일 보드", "All TODOs")).font(.system(size: 22, weight: .semibold))
                    if project != nil {
                        Button(L("전체 보드 보기", "All projects")) { discussion.openBoard(project: nil) }.buttonStyle(.link).font(.system(size: 12))
                    }
                }
                let next = scheduler.nextCheck.map { DateFormatter.localizedString(from: $0, dateStyle: .none, timeStyle: .short) } ?? "–"
                Text(L("할 일이 없을 때는 30분마다 확인 · 다음 확인 \(next)", "Checks every 30 minutes when idle · next \(next)"))
                    .font(.system(size: 12)).foregroundColor(.secondary)
                if let waiting = scheduler.waiting { Text(waiting).font(.system(size: 12)).foregroundColor(.orange) }
            }
            Spacer()
            Button(action: { try? TodoStore.shared.pause(lists: project == nil ? nil : lists) }) {
                Label(project == nil ? L("모두 멈추기", "Pause all") : L("멈추기", "Pause"), systemImage: "pause.fill")
            }
                .controlSize(.large)
                .help(L("지금 하는 TODO는 마치고, 다음 TODO부터 자동으로 시작하지 않아요. ▶ 작업 시작이나 목록의 [다시 진행]으로 이어서 해요.",
                        "The running TODO finishes; the next ones do not start by themselves. ▶ Start or the list's Resume goes on."))
            Button(action: { scheduler.startNow(lists: project == nil ? nil : lists) }) {
                Label(project == nil ? L("모든 프로젝트 작업 시작", "Start all projects") : L("이 프로젝트 작업 시작", "Start this project"), systemImage: "play.fill")
            }
                .buttonStyle(.borderedProminent).controlSize(.large)
                .help(project == nil ? L("모든 프로젝트의 초안을 대기로 바꾸고 멈춤도 풀어서 바로 확인해요", "Makes every project's drafts ready, lifts the pauses and checks now")
                                     : L("이 프로젝트의 초안만 대기로 바꾸고 멈춤도 풀어서 바로 확인해요. 다른 프로젝트에서 이미 대기인 TODO도 차례가 되면 시작돼요.",
                                         "Makes only this project's drafts ready, lifts its pause and checks now. Ready TODOs of other projects may start too."))
        }
    }
}

// The report card: what the AI did and [Done] / [Request changes], or its questions with an answer box and [Stop].
struct TodoCard: View {
    let item: TodoItem
    @ObservedObject var discussion: Discussion
    var compact = false
    @ObservedObject private var draft = TodoDraft.shared
    private var text: String {
        get { draft.replies[item.id] ?? "" }
        nonmutating set { draft.replies[item.id] = newValue.isEmpty ? nil : newValue }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !compact {
                HStack {
                    Image(systemName: item.state == .review ? "checkmark.seal" : "questionmark.bubble").foregroundColor(item.state.color)
                    Text("TODO · " + item.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Spacer()
                    Text(item.state.title).font(.system(size: 12, weight: .medium)).foregroundColor(item.state.color)
                }
            }
            if item.state == .review {
                if let result = item.result { Text(result).font(.system(size: 12)).textSelection(.enabled).lineLimit(compact ? 3 : 12) }
                if !item.assumptions.isEmpty {
                    Text(L("가정: ", "Assumed: ") + item.assumptions.joined(separator: " · ")).font(.system(size: 11)).foregroundColor(.secondary)
                }
                if let error = item.lastError { Text(error).font(.system(size: 11)).foregroundColor(.orange) }
                if item.room.map({ discussion.conversation($0).configuration?.memberIDs?.count ?? 0 }) == 1 {
                    Text(L("리뷰 없음 (리뷰할 계정이 없었어요)", "No review (no account was free to review)")).font(.system(size: 11)).foregroundColor(.orange)
                }
            } else if let question = item.question {
                Text(question.reason).font(.system(size: 12)).textSelection(.enabled)
                ForEach(Array(question.items.enumerated()), id: \.offset) { _, q in
                    VStack(alignment: .leading, spacing: 3) {
                        Text("• " + q.text).font(.system(size: 12, weight: .medium))
                        if !q.options.isEmpty {
                            HStack(spacing: 6) {
                                ForEach(q.options, id: \.self) { option in
                                    Button(option + (option == q.recommended ? L(" (추천)", " (recommended)") : "")) {
                                        text = (text.isEmpty ? "" : text + "\n") + q.text + " → " + option
                                    }.controlSize(.small)
                                }
                            }
                        }
                    }
                }
            }
            HStack(spacing: 8) {
                TextField(item.state == .review ? L("수정할 점 (수정 요청)", "What to change") : L("답이나 바뀐 방향", "Your answer or new direction"), text: Binding(get: { text }, set: { text = $0 }), axis: .vertical)
                    .textFieldStyle(.roundedBorder).lineLimit(1...4)
                if item.state == .review {
                    Button(L("수정 요청", "Request changes")) { TodoStore.shared.requestChanges(item.id, text); text = ""; TodoScheduler.shared?.wake() }
                        .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
                    if !compact { Button(L("완료", "Done")) { TodoStore.shared.accept(item.id) }.buttonStyle(.borderedProminent) }
                } else {
                    Button(L("그만", "Stop")) { TodoScheduler.shared?.cancel(item.id) }
                    Button(L("답하고 계속", "Answer and go on")) { TodoStore.shared.answer(item.id, text.trimmingCharacters(in: .whitespacesAndNewlines)); text = ""; TodoScheduler.shared?.wake() }
                        .buttonStyle(.borderedProminent)
                }
                if !compact, let room = item.room, room != discussion.currentID {
                    Button(L("방 열기", "Open chat")) { discussion.open(room) }
                }
            }
            .font(.system(size: 12)).controlSize(.small)
        }
        .padding(compact ? 0 : 12)
        .background(compact ? Color.clear : item.state.color.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
    }
}

// Above the message box: the cards of TODOs that work in this chat or were written from it.
struct TodoCardsView: View {
    let room: UUID
    @ObservedObject var discussion: Discussion
    @ObservedObject private var store = TodoStore.shared
    var body: some View {
        let items = store.snapshot.items.filter { ($0.room == room || $0.originRoom == room) && ($0.state == .review || $0.state == .needsYou) }
        VStack(spacing: 6) { ForEach(items) { TodoCard(item: $0, discussion: discussion) } }
    }
}
