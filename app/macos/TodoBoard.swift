import SwiftUI
import AppKit
import UniformTypeIdentifiers
import AIAccounts
import AILocalization
import AIWorkspace
import AIProjects
import AIChat

// The TODO board (Todo.swift): sidebar entry (first row under Projects) with the count waiting for the user, the board shown in place of the
// chat, and the report cards above the message box of a TODO's own chat and of the chat it was written from.

struct TodoBoardRow: View {
    @ObservedObject var discussion: Discussion
    @ObservedObject private var store = TodoStore.shared
    var body: some View { boardRow }

    // Every project's TODOs (the project folders below it have one project's each).
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
    // A TODO dragged by its handle to a new place in its list: the board's own type, so no drop takes it for a file.
    static let itemType = UTType(exportedAs: "com.aiilluminati.todo-item")
    var dragging: UUID?
    struct Slot: Equatable { var id: UUID; var below: Bool }
    @Published var dropSlot: Slot?   // where the dragged TODO would go: the line above or below this row
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
    @ObservedObject private var projectInfo = ProjectInfoStore.shared

    // Projects to write TODOs for: every linked Git project of the chats (newest first); on one project's board
    // only its roots (a repository with several worktrees has one per root).
    private var projects: [(name: String, binding: ProjectBinding)] {
        let mine = { (p: ProjectBinding) in discussion.boardProject.map { SidebarProjects.key(p) == $0 } ?? true }
        return TodoProject.all(store.snapshot, chats: discussion.conversations.map(\.projectSummary), names: projectInfo.names).filter { mine($0.binding) }.map { ($0.name, $0.binding) }
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
                                    project: discussion.boardProject.map { projectInfo.names[$0] ?? projects.first?.name ?? lists.first.map(title) ?? "" }, lists: Set(lists.map(\.id)))
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

    // A list is shown with the name the user gave its project, else the name it was made with.
    private func title(_ list: TodoList) -> String { list.project.flatMap { projectInfo.names[SidebarProjects.key($0)] } ?? list.title }

    private func listView(_ list: TodoList) -> some View {
        let rows = store.snapshot.ordered(list.id).filter { draft.showDone || ($0.state != .done && $0.state != .cancelled) }
        return VStack(alignment: .leading, spacing: 6) {
            // A narrow window puts the order choice on its own line instead of pushing the board wider.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    Text(title(list)).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                    orderControls(list)
                    Spacer()
                    pauseControl(list)
                }
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 10) {
                        Text(title(list)).font(.system(size: 15, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 6)
                        pauseControl(list)
                    }
                    HStack(spacing: 10) { orderControls(list) }
                }
            }
            if let scheduler = TodoScheduler.shared { TodoCrewRow(list: list, scheduler: scheduler, discussion: discussion, error: { draft.error = $0 }) }
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, item in row(item, index: index + 1, list: list) }
        }
    }

    @ViewBuilder private func orderControls(_ list: TodoList) -> some View {
        Picker("", selection: Binding(get: { list.sequential }, set: { value in act { try store.setList(list.id, sequential: value) } })) {
            Text(L("순서대로", "In order")).tag(true)
            Text(L("상관없음", "Any order")).tag(false)
        }
        .pickerStyle(.segmented).fixedSize()
        if list.sequential {
            Toggle(L("내 확인 후 다음", "Next after my check"), isOn: Binding(get: { list.waitForDone }, set: { value in act { try store.setList(list.id, waitForDone: value) } }))
                .toggleStyle(.checkbox).font(.system(size: 12)).fixedSize()
                .help(L("켜면 앞 TODO에 [완료]를 눌러야 다음이 시작돼요. 끄면 앞 TODO가 확인 대기나 질문 대기가 될 때 시작해요.",
                        "On: the next starts after you press Done. Off: it starts when the previous one waits for your check or answer."))
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
                Image(systemName: "line.3.horizontal").font(.system(size: 11)).foregroundColor(.secondary).frame(width: 22, height: 22).contentShape(Rectangle())
                    .help(L("끌어서 순서 바꾸기", "Drag to reorder"))
                    .onDrag {
                        draft.dragging = item.id
                        let provider = NSItemProvider()
                        provider.registerDataRepresentation(forTypeIdentifier: TodoDraft.itemType.identifier, visibility: .ownProcess) { done in
                            done(Data(item.id.uuidString.utf8), nil); return nil
                        }
                        return provider
                    }
                Text(list.sequential ? "\(index). " + item.title : item.title).font(.system(size: 13, weight: .medium))
                    .foregroundColor(item.state == .draft ? .secondary : .primary).lineLimit(2)
                Spacer(minLength: 6)
                if item.state == .ready, !waits.isEmpty {
                    Label(waits.map(\.title).joined(separator: ", ") + L(" 기다림", " first"), systemImage: "hourglass").font(.system(size: 11)).foregroundColor(.secondary).lineLimit(1)
                }
                let status = item.state.title + (item.state == .running ? runner(item) : "") + (item.state == .ready && data.stopped(item) ? L(" · 멈춤", " · paused") : "")
                if item.state == .draft || item.state == .ready {
                    // One click: draft ↔ ready (the ⋯ menu has the same).
                    Button(action: { act { try store.setReady(item.id, item.state == .draft); if item.state == .draft { TodoScheduler.shared?.wake() } } }) {
                        Text(status).font(.system(size: 12, weight: .medium)).foregroundColor(item.state.color).lineLimit(1)
                            .padding(.horizontal, 8).frame(minHeight: 22)
                            .background(item.state.color.opacity(0.12), in: Capsule())
                            .overlay(Capsule().strokeBorder(item.state.color.opacity(0.35)))
                    }
                    .buttonStyle(.plainHit)
                    .help(item.state == .draft ? L("누르면 대기로: 차례가 오면 AI가 가져가요", "Click to make it ready: the AI takes it when its turn comes")
                                               : L("누르면 초안으로: AI가 가져가지 않아요 (순서대로 목록에서는 건너뛰어요)", "Click to make it a draft: the AI leaves it (an in-order list skips it)"))
                } else {
                    Text(status).font(.system(size: 12, weight: .medium)).foregroundColor(item.state.color)
                }
                if item.state == .review {
                    Button(L("완료", "Done")) { store.accept(item.id) }.buttonStyle(.borderedProminent).controlSize(.small)
                }
                if TodoStore.editable(item) {
                    Button(action: { draft.beginEdit(item) }) { Image(systemName: "pencil").frame(width: 22, height: 22) }
                        .buttonStyle(.plainHit).help(L("고치기 (AI가 아직 가져가지 않은 TODO)", "Edit (the AI has not taken it yet)"))
                }
                if let room = item.room {
                    if discussion.conversations.contains(where: { $0.id == room }) {
                        Button(action: { discussion.open(room) }) { Image(systemName: "bubble.left") }.buttonStyle(.plainHit).help(L("이 TODO의 채팅 열기", "Open this TODO's chat"))
                    } else {
                        Image(systemName: "bubble.left").foregroundColor(.secondary.opacity(0.4)).frame(width: 22, height: 22)
                            .help(L("이 TODO의 채팅은 삭제했어요 (기록은 여기 남아요)", "This TODO's chat was deleted (its record stays here)"))
                    }
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
                    if item.state == .draft { Button(L("대기로 (바로 가져가도 됨)", "Make ready")) { act { try store.setReady(item.id, true); TodoScheduler.shared?.wake() } } }
                    if item.state == .ready { Button(L("초안으로 되돌리기", "Back to draft")) { act { try store.setReady(item.id, false) } } }
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
        .overlay(alignment: draft.dropSlot?.below == true ? .bottom : .top) {
            if draft.dropSlot?.id == item.id {
                Capsule().fill(Color.accentColor).frame(height: 3).offset(y: draft.dropSlot?.below == true ? 4.5 : -4.5).allowsHitTesting(false)
            }
        }
        // Photos or files dropped on a TODO the AI is not working on are attached to it right away; a TODO of the
        // same list dragged by its handle goes above it (dragged up) or below it (dragged down).
        .onDrop(of: [TodoDraft.itemType, UTType.fileURL, UTType.image, UTType.item],
                delegate: TodoFileDrop(target: item.id, accepts: item.state != .running && item.state != .done && item.state != .cancelled,
                                       reorder: { reorder(onto: item, in: list, probe: $0) }) { urls, folder in
            defer { if let folder { try? FileManager.default.removeItem(at: folder) } }
            if urls.isEmpty { draft.error = L("파일을 첨부할 수 없어요.", "Could not attach the file."); return }
            act { try store.attach(item.id, files: urls) }
        })
    }

    // Where the dragged TODO would go if dropped on `target`: below it when dragged down, above it when dragged up;
    // nil for one of another list. probe false: moves it there.
    private func reorder(onto target: TodoItem, in list: TodoList, probe: Bool) -> TodoDraft.Slot? {
        let row = store.snapshot.ordered(list.id).map(\.id)
        guard let moving = draft.dragging, moving != target.id, let from = row.firstIndex(of: moving), let to = row.firstIndex(of: target.id) else { return nil }
        let below = from < to
        if !probe {
            let rest = row.filter { $0 != moving }
            let before = below ? rest.firstIndex(of: target.id).flatMap { rest.indices.contains($0 + 1) ? rest[$0 + 1] : nil } : target.id
            act { try store.move(moving, before: before) }
        }
        return TodoDraft.Slot(id: target.id, below: below)
    }

    // In place of the title and details while editing: [Cancel] / [Save] (Return saves, Shift+Return breaks a detail line, Esc cancels).
    private func editor(_ item: TodoItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField(L("할 일", "TODO"), text: $draft.editTitle).textFieldStyle(.roundedBorder).onSubmit { draft.saveEdit() }
            TextField(L("자세한 내용 (선택)", "Details (optional)"), text: $draft.editDetail, axis: .vertical).textFieldStyle(.roundedBorder).lineLimit(1...8)
                .modifier(ShiftReturnNewline { draft.saveEdit() })
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

    // The add bar's controls, laid out by addBar to fit the width.
    @ViewBuilder private func projectPicker(_ options: [(name: String, binding: ProjectBinding)], _ root: String) -> some View {
        // One project's board: its only root needs no picking.
        if discussion.boardProject == nil || options.count > 1 {
            Picker(L("프로젝트", "Project"), selection: Binding(get: { root }, set: { draft.projectRoot = $0 })) {
                ForEach(options, id: \.binding.root) { option in
                    Text(SidebarProjects.pickerName(option, among: options, board: discussion.boardProject)).tag(option.binding.root)
                }
            }
            .fixedSize()
        }
    }

    @ViewBuilder private var fileAndOrder: some View {
        Button(action: { addDraftFiles(Self.chooseFiles()) }) { Label(L("첨부", "Attach"), systemImage: "paperclip") }
            .help(L("사진이나 파일을 첨부해요 (여기나 TODO 줄 위에 끌어다 놓아도 돼요 · 사진 앱·스크린샷도)", "Attach photos or files (or drop them here or on a TODO, also from Photos or a screenshot)"))
            .fixedSize()
        Menu(draft.after.isEmpty ? L("먼저 끝나야 할 TODO", "Must finish first") : L("먼저: \(draft.after.count)개", "First: \(draft.after.count)")) {
            ForEach(store.snapshot.items.filter { $0.state != .done && $0.state != .cancelled }) { other in
                Button((draft.after.contains(other.id) ? "✓ " : "") + other.title) { if draft.after.contains(other.id) { draft.after.remove(other.id) } else { draft.after.insert(other.id) } }
            }
        }
        .fixedSize()
    }

    @ViewBuilder private func askAndAdd(_ root: String) -> some View {
        Picker("", selection: $draft.askFirst) {
            Text(L("가정하고 표시", "Assume and note")).tag(false)
            Text(L("먼저 묻기", "Ask first")).tag(true)
        }
        .pickerStyle(.segmented).fixedSize()
        Spacer()
        Button(L("추가", "Add"), action: add).disabled(draft.title.trimmingCharacters(in: .whitespaces).isEmpty || root.isEmpty).fixedSize()
    }

    private var addBar: some View {
        let options = projects
        let root = pickedRoot(options)
        return VStack(alignment: .leading, spacing: 8) {
            TextField(L("+ 할 일 추가…", "+ Add a TODO…"), text: $draft.title).textFieldStyle(.roundedBorder).onSubmit(add)
            TextField(L("자세한 내용 (선택)", "Details (optional)"), text: $draft.detail, axis: .vertical).textFieldStyle(.roundedBorder).lineLimit(1...5)
                .modifier(ShiftReturnNewline(submit: add))
            if !draft.files.isEmpty {
                TodoChips(items: draft.files.map { f in (f.id, f.url.lastPathComponent, (try? f.url.resourceValues(forKeys: [.contentTypeKey]).contentType?.conforms(to: .image)) == true) },
                          open: { id in if let f = draft.files.first(where: { $0.id == id }) { NSWorkspace.shared.open(f.url) } },
                          remove: { id in draft.files.removeAll { $0.id == id } })
            }
            // All in one line when it fits, else the project on its own line, then the choices over two lines.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { projectPicker(options, root); fileAndOrder; askAndAdd(root) }
                VStack(alignment: .leading, spacing: 8) {
                    projectPicker(options, root)
                    HStack(spacing: 10) { fileAndOrder; askAndAdd(root) }
                }
                VStack(alignment: .leading, spacing: 8) {
                    projectPicker(options, root)
                    HStack(spacing: 10) { fileAndOrder }
                    HStack(spacing: 10) { askAndAdd(root) }
                }
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
        .onDrop(of: [TodoDraft.itemType, UTType.fileURL, UTType.image, UTType.item], delegate: TodoFileDrop(target: TodoDraft.addBar, accepts: true) { urls, folder in
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
        // Written for a locked project (or one worked on in a locked chat): its TODOs keep that lock.
        let lock = (discussion.current.workspace?.project?.root == root ? discussion.current.enterpriseLock : nil)
            ?? discussion.conversations.first { $0.workspace?.project.map(SidebarProjects.key) == SidebarProjects.key(project.binding) && $0.enterpriseLock != nil }?.enterpriseLock
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
                    Button((picked ? "✓ " : "") + discussion.label(account) + (allowed ? left(account) : L(" · 잠금 밖", " · outside the lock"))) { toggle(account.id) }
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

// Details fields work like the chat box: Return adds or saves (`submit`), Shift+Return (or Option+Return)
// starts a new line. Only while this field has focus; Korean text still being composed just finishes on Return.
// Return is caught here, not left to onSubmit: a vertical TextField does not reliably submit on Return.
// (The monitor is kept in an ObservableObject: this Mac's Command Line Tools cannot build SwiftUI's @State macro.)
private final class KeyMonitorBox: ObservableObject { var monitor: Any?; var submit: () -> Void = {} }

private struct ShiftReturnNewline: ViewModifier {
    let submit: () -> Void
    @FocusState private var focused: Bool
    @StateObject private var box = KeyMonitorBox()
    func body(content: Content) -> some View {
        box.submit = submit   // the newest one: the monitor outlives this view value
        return content.focused($focused)
            .onChange(of: focused) { on in if on { start() } else { stop() } }
            .onDisappear { stop() }
    }
    private func start() {
        let box = box
        guard box.monitor == nil else { return }
        // Only the window this field is in: its focus stays set while another window takes the typing.
        weak var window = NSApp.keyWindow
        box.monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.keyCode == 36 || event.keyCode == 76, let window, event.window === window,
                  event.modifierFlags.intersection([.command, .control]).isEmpty,
                  let editor = event.window?.firstResponder as? NSTextView, !editor.hasMarkedText() else { return event }
            if event.modifierFlags.intersection([.shift, .option]).isEmpty { box.submit() } else { editor.insertNewlineIgnoringFieldEditor(nil) }
            return nil
        }
    }
    private func stop() { if let monitor = box.monitor { NSEvent.removeMonitor(monitor) }; box.monitor = nil }
}

// Photos and files dragged onto the add bar or a TODO row: from Finder, the Photos app or a screenshot
// thumbnail (PictureDrop). `receive` runs on the main thread; a temporary `folder` is the caller's to remove.
// A TODO dragged by its handle (TodoDraft.itemType) is checked first: it is never taken as a file (the types
// below include UTType.item). `reorder(true)` says where it would go, `reorder(false)` moves it; nil: not here.
private struct TodoFileDrop: DropDelegate {
    let target: UUID
    let accepts: Bool
    var reorder: ((Bool) -> TodoDraft.Slot?)? = nil
    let receive: ([URL], URL?) -> Void
    private func moving(_ info: DropInfo) -> Bool { info.hasItemsConforming(to: [TodoDraft.itemType]) }
    func validateDrop(info: DropInfo) -> Bool {
        if moving(info) { return reorder?(true) != nil }
        return accepts && (info.hasItemsConforming(to: [UTType.fileURL, UTType.image]) || PictureDrop.hasPromises())
    }
    func dropEntered(info: DropInfo) {
        if moving(info) { TodoDraft.shared.dropSlot = reorder?(true) } else if validateDrop(info: info) { TodoDraft.shared.dropTarget = target }
    }
    func dropExited(info: DropInfo) {
        if TodoDraft.shared.dropTarget == target { TodoDraft.shared.dropTarget = nil }
        if TodoDraft.shared.dropSlot?.id == target { TodoDraft.shared.dropSlot = nil }
    }
    func dropUpdated(info: DropInfo) -> DropProposal? {
        if moving(info) { return DropProposal(operation: reorder?(true) != nil ? .move : .forbidden) }
        return DropProposal(operation: validateDrop(info: info) ? .copy : .forbidden)
    }
    func performDrop(info: DropInfo) -> Bool {
        TodoDraft.shared.dropTarget = nil
        if moving(info) {
            TodoDraft.shared.dropSlot = nil
            defer { TodoDraft.shared.dragging = nil }
            return reorder?(false) != nil
        }
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
                if !compact, let room = item.room, room != discussion.currentID, discussion.conversations.contains(where: { $0.id == room }) {
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
