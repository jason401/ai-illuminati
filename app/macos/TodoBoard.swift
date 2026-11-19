import SwiftUI
import AppKit
import Combine
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
    // A TODO dragged by its handle to a new place in its list. It travels as plain data: the board's own type was
    // not declared in Info.plist and no drop saw it, and text would be typed into the add bar's fields. A drag
    // cancelled outside a drop tells nobody, so the next click in the app or leaving the app clears it: a stale
    // value would make the next drop without files a move.
    var dragging: UUID? { didSet { if dragging != nil { watchDragEnd() } } }
    private var clickWatch: Any?, leaveWatch: NSObjectProtocol?
    private func watchDragEnd() {
        guard clickWatch == nil else { return }
        clickWatch = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            self?.endDrag(); return event
        }
        leaveWatch = NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.endDrag()
        }
    }
    func endDrag() {
        dragging = nil; dropSlot = nil
        if let clickWatch { NSEvent.removeMonitor(clickWatch) }
        if let leaveWatch { NotificationCenter.default.removeObserver(leaveWatch) }
        clickWatch = nil; leaveWatch = nil
    }
    struct Slot: Equatable { var id: UUID; var below: Bool }
    @Published var dropSlot: Slot?   // where the dragged TODO would go: the line above or below this row
    @Published var projectRoot = ""
    @Published var after: Set<UUID> = []
    @Published var askFirst = false
    @Published var error: String?
    @Published var showDone = false
    @Published var replies: [UUID: String] = [:]   // a card's answer or change request, by TODO
    // A chat card folded to one line, with what it showed then: a new state, question or result opens it again.
    struct Fold: Equatable { var state: TodoItem.State; var question: UUID?; var result: String? }
    static func fold(_ item: TodoItem) -> Fold { Fold(state: item.state, question: item.question?.id, result: item.result) }
    @Published var collapsed: [UUID: Fold] = [:]
    // Editing a TODO the AI has not taken yet (TodoStore.editable); the scheduler leaves it alone meanwhile.
    @Published private(set) var editing: UUID?
    @Published var editTitle = ""
    @Published var editDetail = ""
    @Published var editAskFirst = false
    @Published var splitOpen: Set<UUID> = []   // finish rows whose split record is unfolded

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
    @ObservedObject private var splitCommits = TodoSplitCommits.shared

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
                if TodoScheduler.shared != nil || !lists.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        if let scheduler = TodoScheduler.shared {
                            TodoBoardHeader(scheduler: scheduler, discussion: discussion,
                                            project: discussion.boardProject.map { projectInfo.names[$0] ?? projects.first?.name ?? lists.first.map(title) ?? "" }, lists: Set(lists.map(\.id)))
                        }
                        if !lists.isEmpty {
                            Toggle(L("완료·취소된 것도 보기", "Show done and cancelled"), isOn: $draft.showDone)
                                .toggleStyle(.checkbox).font(.system(size: 12))
                                .frame(maxWidth: .infinity, alignment: .trailing)
                        }
                    }
                    .padding(.bottom, lists.isEmpty ? 0 : 6)
                }
                if let error = draft.error ?? store.saveError { Text(error).font(.system(size: 12)).foregroundColor(.red) }
                ForEach(lists) { list in listView(list) }
                if lists.isEmpty {
                    Text(L("아직 TODO가 없어요. 아래에서 프로젝트를 고르고 적어 주세요.", "No TODOs yet. Pick a project below and write one."))
                        .font(.system(size: 13)).foregroundColor(.secondary)
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text(L("새 TODO", "New TODO")).font(.system(size: 12)).foregroundColor(.secondary)
                    addBar
                }
                .padding(.top, 6)   // Together with the board spacing: 24 pt clear of the last card or empty message.
            }
            .frame(maxWidth: 760, alignment: .leading)
            .padding(.horizontal, 28).padding(.vertical, 16)
            .frame(maxWidth: .infinity)
        }
        .onDisappear { draft.endEdit(); draft.endDrag(); splitCommits.watch(false) }   // an edit left open would hold the TODO back
        .onAppear { splitCommits.watch(true) }
        .onChange(of: store.snapshot) { splitCommits.refresh($0) }
    }

    // A list is shown with the name the user gave its project, else the name it was made with.
    private func title(_ list: TodoList) -> String { list.project.flatMap { projectInfo.names[SidebarProjects.key($0)] } ?? list.title }

    private func listView(_ list: TodoList) -> some View {
        let rows = store.snapshot.ordered(list.id).filter { draft.showDone || ($0.state != .done && $0.state != .cancelled) }
        return VStack(alignment: .leading, spacing: 6) {
            // One line: a long project name gives way, the mode menu and pause keep their size.
            HStack(spacing: 10) {
                Text(title(list)).font(.system(size: 15, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                modeControl(list)
                Spacer(minLength: 6)
                pauseControl(list)
            }
            if let scheduler = TodoScheduler.shared { TodoCrewRow(list: list, scheduler: scheduler, discussion: discussion, error: { draft.error = $0 }) }
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, item in row(item, index: index + 1, list: list) }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.08), lineWidth: 1).allowsHitTesting(false))
    }

    // How the list goes on when a TODO waits for the user (RunMode); always in order.
    static func modeTitle(_ mode: RunMode) -> String {
        switch mode {
        case .checkEach: return L("하나씩 내가 확인", "Check each one")
        case .stopOnIssue: return L("문제 생기면 멈춤", "Stop on issues")
        case .aiThenPark: return L("AI 판단 후 보류", "AI decides, else park")
        case .auto: return L("완전 자동", "Fully automatic")
        }
    }
    static func modeHelp(_ mode: RunMode) -> String {
        switch mode {
        case .checkEach: return L("결과 확인·질문·실패 모두 내가 처리해야 다음 TODO가 시작돼요. AI가 대신 답하지 않아요.", "The next TODO starts only after you check each result and answer each question or failure. No AI answers for you.")
        case .stopOnIssue: return L("결과는 확인 대기로 두고 다음으로 넘어가요. 질문이나 실패는 내가 답할 때까지 멈춰요.", "Results wait for your check while the next one starts; a question or failure stops the list until you answer.")
        case .aiThenPark: return L("질문·실패는 멈추고 15분 뒤 다른 AI가 답이나 해결책을 줘요. 안 되면(거절, 30분 경과, 도움 뒤 또 막힘) 보류하고 다음으로 가요.", "A question or failure stops the list; after 15 minutes another AI answers or proposes a fix. Otherwise (declined, 30 minutes, stuck again) it is parked and the next one goes on.")
        case .auto: return L("실패는 바로 보류하고 다음으로 가요. 질문은 15분 뒤 다른 AI가 답하고, 30분 뒤 AI에게 판단을 맡기고, 그래도 막히면 보류해요.", "A failure is parked at once and the next one goes on. A question gets another AI at 15 minutes, the AI's own call at 30, and is parked if still stuck.")
        }
    }
    private func modeControl(_ list: TodoList) -> some View {
        Picker("", selection: Binding(get: { list.mode }, set: { value in act { try store.setList(list.id, mode: value); TodoScheduler.shared?.wake() } })) {
            ForEach(RunMode.allCases, id: \.self) { mode in Text(Self.modeTitle(mode)).tag(mode).help(Self.modeHelp(mode)) }
        }
        .pickerStyle(.menu).labelsHidden().fixedSize().font(.system(size: 12))
        .help(Self.modeHelp(list.mode))
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
        // Once each: a link to the TODO just above is also the order's wait.
        let waits = data.blockers(item).reduce(into: [UUID]()) { if !$0.contains($1) { $0.append($1) } }
            .compactMap(data.item).filter { !data.satisfied($0, for: item) && $0.state != .cancelled }
        let editing = draft.editing == item.id && TodoStore.editable(item)
        let split = data.splitLine(item)
        return VStack(alignment: .leading, spacing: 4) {
            if editing { editor(item) } else {
            HStack(spacing: 8) {
                Image(systemName: "line.3.horizontal").font(.system(size: 11)).foregroundColor(.secondary).frame(width: 22, height: 22).contentShape(Rectangle())
                    .help(L("끌어서 순서 바꾸기", "Drag to reorder"))
                    .onDrag {
                        draft.dragging = item.id
                        let provider = NSItemProvider()
                        provider.registerDataRepresentation(forTypeIdentifier: UTType.data.identifier, visibility: .all) { done in
                            done(Data(item.id.uuidString.utf8), nil); return nil
                        }
                        return provider
                    }
                Text("\(index). " + item.title).font(.system(size: 13, weight: .medium))
                    .foregroundColor(item.state == .draft ? .secondary : .primary).lineLimit(2)
                if let split { splitChip(split) }
                Spacer(minLength: 6)
                if item.state == .ready, !waits.isEmpty {
                    let linked = waits.filter { item.after.contains($0.id) }, above = waits.filter { !item.after.contains($0.id) }
                    Label(waits.map(\.title).joined(separator: ", ") + L(" 기다림", " first"), systemImage: "hourglass").font(.system(size: 11)).foregroundColor(.secondary).lineLimit(1)
                        .help(([linked.isEmpty ? nil : L("직접 건 링크: ", "Linked by you: ") + linked.map(\.title).joined(separator: ", "),
                                above.isEmpty ? nil : L("위 TODO가 끝나길 기다려요(순서대로): ", "Waits for the TODO above (in order): ") + above.map(\.title).joined(separator: ", ")] as [String?])
                                .compactMap { $0 }.joined(separator: "\n"))
                }
                if let retry = TodoScheduler.retrying(item) {
                    Label(retry.label, systemImage: "arrow.clockwise").font(.system(size: 11)).foregroundColor(.orange).lineLimit(1).help(retry.why)
                }
                if !item.after.isEmpty { linkDropdown(item) }
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
                    Menu(L("먼저 끝나야 할 TODO", "Must finish first")) { linkItems(item) }
                    if item.state != .running && item.state != .done && item.state != .cancelled {
                        Button(L("사진·파일 첨부…", "Attach photos or files…")) { let urls = Self.chooseFiles(); if !urls.isEmpty { act { try store.attach(item.id, files: urls) } } }
                    }
                    if item.state == .draft { Button(L("대기로 (바로 가져가도 됨)", "Make ready")) { act { try store.setReady(item.id, true); TodoScheduler.shared?.wake() } } }
                    if item.state == .ready { Button(L("초안으로 되돌리기", "Back to draft")) { act { try store.setReady(item.id, false) } } }
                    Button(list.stopAfter == item.id ? L("멈춤 지점 지우기", "Remove the stop point") : L("여기까지 하고 멈추기", "Stop after this one")) {
                        act { try store.stop(after: item.id); TodoScheduler.shared?.wake() }
                    }
                    Divider()
                    if item.state != .done { Button(L("완료로 표시", "Mark as done")) { discussion.markTodoDone(item.id) } }
                    if item.state != .done && item.state != .cancelled { Button(L("그만 (취소)", "Stop (cancel)")) { TodoScheduler.shared?.cancel(item.id) } }
                    Button(L("삭제", "Delete"), role: .destructive) { act { try store.delete(item.id) } }.disabled(item.state == .running)
                } label: { Image(systemName: "ellipsis") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            }
            // Right-click on the row: done from any state, without finding the ⋯.
            .contextMenu { if item.state != .done { Button(L("완료로 표시", "Mark as done")) { discussion.markTodoDone(item.id) } } }
            if !item.detail.isEmpty { Text(item.detail).font(.system(size: 12)).foregroundColor(.secondary).lineLimit(3) }
            if let split, split.isFinish { splitFinish(split) }
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
        .onDrop(of: [UTType.fileURL, UTType.image, UTType.data, UTType.item],
                delegate: TodoFileDrop(target: item.id, accepts: item.state != .running && item.state != .done && item.state != .cancelled,
                                       reorder: { reorder(onto: item, in: list, probe: $0) }) { urls, folder in
            defer { if let folder { try? FileManager.default.removeItem(at: folder) } }
            if urls.isEmpty { draft.error = L("파일을 첨부할 수 없어요.", "Could not attach the file."); return }
            act { try store.attach(item.id, files: urls) }
        })
    }

    // A split's pieces (docs/TODO_SPLIT_PLAN.md 2): "① · AI가 나눔" on a step, "마무리 · AI가 나눔 · 1/3" on the finish.
    static func circled(_ n: Int) -> String { (1...20).contains(n) ? String(UnicodeScalar(0x245F + n)!) : "(\(n))" }
    private func splitChip(_ split: TodoSplitLine) -> some View {
        let byAI = L("AI가 나눔", "split by AI")
        let text = split.isFinish ? L("마무리", "Finish") + " · " + byAI + " · \(split.done)/\(split.pieces.count)" : Self.circled(split.number) + " · " + byAI
        return Text(text).font(.system(size: 11, weight: .medium)).foregroundColor(.purple).lineLimit(1).fixedSize()
            .padding(.horizontal, 6).frame(minHeight: 18)
            .background(Color.purple.opacity(0.1), in: Capsule())
            .help(split.isFinish ? L("AI가 이 TODO를 나눴어요. 앞 조각이 차례로 끝나면 이 TODO가 마무리로 전체 테스트와 push를 해요 (끝난 조각/전체).",
                                     "The AI split this TODO. Once the pieces above are done in order, this TODO finishes: full tests and one push (pieces done/all).")
                                 : L("AI가 나눈 조각이에요. 관련 테스트와 커밋까지만 하고, push는 마무리에서 해요.", "A piece the AI split off. It runs related tests and commits; the finish pushes."))
    }

    // Under the finish: a stuck piece, piece commits not pushed yet (stage 1 limit) and the split record to unfold.
    @ViewBuilder private func splitFinish(_ split: TodoSplitLine) -> some View {
        if let stuck = split.stuck {
            Label(L("\(Self.circled(stuck)) 조각이 막혀 멈춤", "\(Self.circled(stuck)) piece is stuck; the rest waits"), systemImage: "exclamationmark.triangle")
                .font(.system(size: 11, weight: .medium)).foregroundColor(.orange)
                .help(L("그 조각에 답하거나 고치면 다음 조각과 마무리가 이어서 시작해요.", "Answer or fix that piece; the next pieces and the finish go on after it."))
        }
        if let count = splitCommits.unpushed[split.group], count > 0 {
            Label(L("push 안 된 조각 커밋 \(count)개", "\(count) piece commit\(count == 1 ? "" : "s") not pushed"), systemImage: "arrow.up.circle")
                .font(.system(size: 11)).foregroundColor(.orange)
                .help(L("마무리가 전체 테스트 뒤에 한 번에 push해요. 그 전에 같은 프로젝트의 다른 채팅이 push하면 아직 검증 안 된 이 커밋들도 같이 올라가요.",
                        "The finish pushes them once, after the full tests. A push from another chat of this project before that takes these unchecked commits along."))
        }
        let open = draft.splitOpen.contains(split.group)
        Button(action: { if open { draft.splitOpen.remove(split.group) } else { draft.splitOpen.insert(split.group) } }) {
            HStack(spacing: 4) {
                Image(systemName: open ? "chevron.down" : "chevron.right").font(.system(size: 9, weight: .semibold)).frame(width: 12)
                Text(L("나누기 기록", "Split record") + (split.minutes.map { L(" · 예상 약 \($0)분", " · about \($0) min") } ?? ""))
            }
            .font(.system(size: 11)).foregroundColor(.secondary).frame(minHeight: 22).contentShape(Rectangle())
        }
        .buttonStyle(.plainHit)
        if open {
            VStack(alignment: .leading, spacing: 3) {
                if let reason = split.reason { Text(L("이유: ", "Why: ") + reason) }
                ForEach(Array(split.pieces.enumerated()), id: \.element.id) { n, piece in
                    Text((piece.finish ? L("마무리", "Finish") : Self.circled(n + 1) + " " + piece.title) + " — " + piece.state.title).foregroundColor(.primary)
                    if piece.finish, let done = split.finishDone { Text("   " + L("끝 조건: ", "Done when: ") + done) }
                    Text("   " + L("파일: ", "Files: ") + (piece.files.isEmpty ? L("없음", "none") : piece.files.joined(separator: ", ")))
                }
            }
            .font(.system(size: 11)).foregroundColor(.secondary).textSelection(.enabled)
            .padding(.leading, 16)
        }
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

    // The new TODO's links that count: only to TODOs of the list it goes to. The project can change without the picker (another
    // project's board opened), so the menu, its count and the add all read this, never draft.after directly.
    private func draftLinks(_ root: String) -> [UUID] {
        guard let id = boardList(root)?.id else { return [] }
        return store.snapshot.ordered(id).map(\.id).filter(draft.after.contains)
    }

    // The list a new TODO for `root` goes to (nil until its first TODO).
    private func boardList(_ root: String) -> TodoList? { store.snapshot.lists.first { $0.project?.root == root } }

    // One "must finish first" line: ✓ when linked, the board's number, and why it no longer holds one back.
    private func linkLine(_ choice: (item: TodoItem, number: Int?), linked: Bool, for item: TodoItem?) -> String {
        let other = choice.item, data = store.snapshot
        let state: String
        switch other.state {
        case .done: state = L(" · 완료", " · done")
        case .cancelled: state = L(" · 취소됨", " · cancelled")
        case .review where data.satisfied(other, for: item ?? other): state = L(" · 확인 대기 (통과)", " · waiting for check (passed)")
        default: state = item.map { other.listID != $0.listID } == true ? L(" · 다른 목록", " · other list") : ""
        }
        return (linked ? "✓ " : "") + (choice.number.map { "\($0). " } ?? "") + other.title + state
    }

    // The ⋯ menu's "must finish first" items and the row's dropdown: the same list. Links change only while the AI has not
    // taken the TODO (draft or ready); otherwise they are shown only.
    @ViewBuilder private func linkItems(_ item: TodoItem) -> some View {
        let open = item.state == .draft || item.state == .ready
        ForEach(store.snapshot.linkChoices(item.listID, except: item.id, linked: item.after, showingDone: draft.showDone), id: \.item.id) { choice in
            let on = item.after.contains(choice.item.id)
            Button(linkLine(choice, linked: on, for: item)) {
                act { try store.setAfter(item.id, on ? item.after.filter { $0 != choice.item.id } : item.after + [choice.item.id]) }
            }
            .disabled(!open)
        }
    }

    // [먼저: n ▾] left of the state chip, only with links the user set (more are added from ⋯). Fixed size, so the title
    // keeps its room; dimmed once none of them holds the TODO back any more.
    private func linkDropdown(_ item: TodoItem) -> some View {
        let data = store.snapshot
        let linked = item.after.compactMap(data.item)
        let holding = linked.filter { !data.satisfied($0, for: item) }
        return Menu { linkItems(item) } label: {
            Text(L("먼저: \(linked.count)개", "First: \(linked.count)")).font(.system(size: 12)).foregroundColor(holding.isEmpty ? .secondary : .primary)
        }
        .menuStyle(.borderlessButton).fixedSize()
        .help(L("직접 건 링크 (먼저 끝나야 할 TODO): ", "Linked by you (must finish first): ") + linked.map(\.title).joined(separator: ", ")
              + (holding.isEmpty ? L(" · 모두 통과", " · all passed") : ""))
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
            Picker(L("프로젝트", "Project"), selection: Binding(get: { root }, set: { value in
                // Links are within one list: ones to the old project's TODOs go.
                let mine = Set(store.snapshot.ordered(boardList(value)?.id ?? UUID()).map(\.id))
                draft.projectRoot = value; draft.after = draft.after.filter(mine.contains)
            })) {
                ForEach(options, id: \.binding.root) { option in
                    Text(SidebarProjects.pickerName(option, among: options, board: discussion.boardProject)).tag(option.binding.root)
                }
            }
            .fixedSize()
        }
    }

    @ViewBuilder private func fileAndOrder(_ root: String) -> some View {
        Button(action: { addDraftFiles(Self.chooseFiles()) }) { Label(L("첨부", "Attach"), systemImage: "paperclip") }
            .help(L("사진이나 파일을 첨부해요 (여기나 TODO 줄 위에 끌어다 놓아도 돼요 · 사진 앱·스크린샷도)", "Attach photos or files (or drop them here or on a TODO, also from Photos or a screenshot)"))
            .fixedSize()
        let links = draftLinks(root)
        Menu(links.isEmpty ? L("먼저 끝나야 할 TODO", "Must finish first") : L("먼저: \(links.count)개", "First: \(links.count)")) {
            ForEach(store.snapshot.linkChoices(boardList(root)?.id, except: nil, linked: links, showingDone: draft.showDone), id: \.item.id) { choice in
                let on = links.contains(choice.item.id)
                // From the shown links only: ones left from another project (another board open) go with the first change.
                Button(linkLine(choice, linked: on, for: nil)) { draft.after = Set(on ? links.filter { $0 != choice.item.id } : links + [choice.item.id]) }
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
                HStack(spacing: 10) { projectPicker(options, root); fileAndOrder(root); askAndAdd(root) }
                VStack(alignment: .leading, spacing: 8) {
                    projectPicker(options, root)
                    HStack(spacing: 10) { fileAndOrder(root); askAndAdd(root) }
                }
                VStack(alignment: .leading, spacing: 8) {
                    projectPicker(options, root)
                    HStack(spacing: 10) { fileAndOrder(root) }
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
        .background(Color.primary.opacity(0.015), in: RoundedRectangle(cornerRadius: 10))
        .overlay(draft.dropTarget == TodoDraft.addBar ? RoundedRectangle(cornerRadius: 10).strokeBorder(Color.accentColor, lineWidth: 2) : nil)
        .onDrop(of: [UTType.fileURL, UTType.image, UTType.data, UTType.item], delegate: TodoFileDrop(target: TodoDraft.addBar, accepts: true) { urls, folder in
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
                          after: draftLinks(root), askFirst: draft.askFirst, originRoom: origin, lock: lock)
            draft.title = ""; draft.detail = ""; draft.files = []; draft.after = []
            for folder in draft.dropFolders { try? FileManager.default.removeItem(at: folder) }
            draft.dropFolders = []
        }
    }

    private func act(_ change: () throws -> Void) {
        do { try change(); draft.error = nil } catch { draft.error = error.localizedDescription }
    }
}

// "push 안 된 조각 커밋 n개": counted with git off the main thread after each board change and every minute while the
// board is open (another chat may push them without any TODO changing). A cancelled split keeps its warning while its
// steps' commits are still local; a done one was pushed by its finish (or the user marked it done).
final class TodoSplitCommits: ObservableObject {
    static let shared = TodoSplitCommits()
    @Published private(set) var unpushed: [UUID: Int] = [:]
    private var busy = false, again = false, timer: Timer?
    func watch(_ on: Bool) {
        timer?.invalidate(); timer = nil
        guard on else { return }
        refresh(TodoStore.shared.snapshot)
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.refresh(TodoStore.shared.snapshot) }
    }
    func refresh(_ data: TodoData) {
        guard !busy else { again = true; return }
        let lines = data.items.compactMap(data.splitLine).filter { line in
            line.isFinish && line.pieces.last?.state != .done
        }
        guard !lines.isEmpty || !unpushed.isEmpty else { return }
        busy = true
        DispatchQueue.global(qos: .utility).async {
            var counts: [UUID: Int] = [:]
            for line in lines { if let n = TodoStore.unpushedPieceCommits(line), n > 0 { counts[line.group] = n } }
            DispatchQueue.main.async {
                // Set only on a change: a set redraws the board, whose onChange would ask again.
                if self.unpushed != counts { self.unpushed = counts }
                self.busy = false
                if self.again { self.again = false; self.refresh(TodoStore.shared.snapshot) }
            }
        }
    }
}

// Which AIs take a project's TODOs: [AI ▾] picks them (automatic = every Claude/Codex with enough left for a TODO, AutoPick.need), then who
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
            Text(discussion.noCrew(list.accounts, lock: lock)).foregroundColor(.orange).lineLimit(2)
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
// A TODO dragged by its handle (TodoDraft.dragging, carried as plain data) is checked first: it is never taken as a
// file (the types below include UTType.item); a file or photo drop clears a stale `dragging`.
// `reorder(true)` says where it would go, `reorder(false)` moves it; nil: not here.
private struct TodoFileDrop: DropDelegate {
    let target: UUID
    let accepts: Bool
    var reorder: ((Bool) -> TodoDraft.Slot?)? = nil
    let receive: ([URL], URL?) -> Void
    private func moving(_ info: DropInfo) -> Bool {
        TodoDraft.shared.dragging != nil && !info.hasItemsConforming(to: [UTType.fileURL]) && !PictureDrop.hasPromises()
    }
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
            defer { TodoDraft.shared.endDrag() }
            return reorder?(false) != nil
        }
        TodoDraft.shared.endDrag()
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

// (An ObservableObject, not @State: see KeyMonitorBox.)
private final class StandInBox: ObservableObject { @Published var on = false }
private final class HeightBox: ObservableObject { @Published var height: CGFloat = 0 }

// The report card: what the AI did and [Done] / [Request changes], or its questions with an answer box, [Stop] and [Done].
struct TodoCard: View {
    let item: TodoItem
    private var question: TodoQuestion? { item.question }
    static func time(_ date: Date) -> String { date.formatted(date: .omitted, time: .shortened) }
    // What happens next to a TODO waiting for the user, by its list's mode: another AI, the delegation, parking.
    static func steps(_ item: TodoItem, _ data: TodoData) -> [(at: Date, what: String)]? {
        let steps = [data.standInDue(item).map { ($0, L("AI 판단", "an AI decides")) }, data.autoAnswerDue(item).map { ($0, L("위임", "handed to the AI")) },
                     data.parkDue(item).map { ($0, L("보류", "parked")) }].compactMap { $0 }.sorted { $0.0 < $1.0 }
        return steps.isEmpty ? nil : steps.map { (at: $0.0, what: $0.1) }
    }
    static func left(_ at: Date, from now: Date) -> String {
        let m = Int((at.timeIntervalSince(now) / 60).rounded(.up))
        return m <= 0 ? L("곧", "soon:") : L("\(m)분 뒤", "in \(m) min:")
    }
    @ObservedObject var discussion: Discussion
    var compact = false
    @ObservedObject private var draft = TodoDraft.shared
    @StateObject private var stand = StandInBox()   // TodoScheduler.standingIn: the due time has passed, another AI answers now
    @StateObject private var reviewHeight = HeightBox()   // the review text's own height: the scroll box is no taller
    private var text: String {
        get { draft.replies[item.id] ?? "" }
        nonmutating set { draft.replies[item.id] = newValue.isEmpty ? nil : newValue }
    }
    // Only the chat cards fold; the board's compact card always shows everything.
    private var folded: Bool { !compact && draft.collapsed[item.id] == TodoDraft.fold(item) }
    private func toggleFold() {
        // Set only on a change (see the note at onReceive below).
        if folded { draft.collapsed[item.id] = nil } else { draft.collapsed[item.id] = TodoDraft.fold(item) }
    }
    private var header: some View {
        Button(action: toggleFold) {
            HStack(spacing: 6) {
                Image(systemName: folded ? "chevron.right" : "chevron.down").font(.system(size: 10, weight: .semibold)).foregroundColor(.secondary).frame(width: 12)
                Image(systemName: item.state == .review ? "checkmark.seal" : "questionmark.bubble").foregroundColor(item.state.color)
                Text("TODO · " + item.title).font(.system(size: 13, weight: .semibold)).lineLimit(1).layoutPriority(1)
                if folded, let line = (item.state == .review ? item.result : item.question?.reason)?
                    .split(whereSeparator: \.isNewline).first.map(String.init) {
                    Text("— " + line).font(.system(size: 12)).foregroundColor(.secondary).lineLimit(1).truncationMode(.tail)
                }
                Spacer(minLength: 4)
                Text(item.state.title).font(.system(size: 12, weight: .medium)).foregroundColor(item.state.color)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(folded ? L("펼치기", "Expand") : L("접기", "Collapse"))
    }
    var body: some View {
        if folded {
            HStack(spacing: 8) {
                header
                if item.state == .review {
                    Button(L("완료", "Done")) { TodoStore.shared.accept(item.id) }.buttonStyle(.borderedProminent)
                } else if question?.delegable == true {
                    Button(L("알아서 해", "Your call")) { text = ""; TodoScheduler.shared?.delegate(item.id) }
                }
            }
            .font(.system(size: 12)).controlSize(.small)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(item.state.color.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        } else {
            card
        }
    }
    // The result, assumptions and errors; in the chat card they scroll inside a capped height so the chat stays visible.
    @ViewBuilder private var reviewBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let result = item.result { Text(result).font(.system(size: 12)).textSelection(.enabled).lineLimit(compact ? 3 : nil) }
            if !item.assumptions.isEmpty {
                Text(L("가정: ", "Assumed: ") + item.assumptions.joined(separator: " · ")).font(.system(size: 11)).foregroundColor(.secondary)
                    .textSelection(.enabled)
            }
            if let error = item.lastError { Text(error).font(.system(size: 11)).foregroundColor(.orange) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    private func measure(_ height: CGFloat) {
        // Set only on a change (see the note at onReceive below).
        if abs(reviewHeight.height - height) > 0.5 { reviewHeight.height = height }
    }
    private var card: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !compact { header }
            if item.state == .review {
                if compact { reviewBody } else {
                    // A ScrollView's own ideal height is not its content's: measured, so short text is not cut and long text scrolls.
                    ScrollView {
                        reviewBody.background(GeometryReader { g in
                            Color.clear.onAppear { measure(g.size.height) }.onChange(of: g.size.height) { measure($0) }
                        })
                    }
                    .frame(height: min(reviewHeight.height, 180))
                }
                if item.room.map({ discussion.conversation($0).configuration?.memberIDs?.count ?? 0 }) == 1 {
                    Text(L("리뷰 없음 (리뷰할 계정이 없었어요)", "No review (no account was free to review)")).font(.system(size: 11)).foregroundColor(.orange)
                }
            } else if let question = item.question {
                Text(question.reason).font(.system(size: 12)).textSelection(.enabled)
                if stand.on {
                    Text(L("다른 AI가 네 대신 답하는 중이에요. 지금 답하면 그 답은 버려요.", "Another AI is answering for you. Answer now and its answer is dropped.")).font(.system(size: 11)).foregroundColor(.secondary)
                } else if item.isParked {
                    Text(L("⏸ 보류됨 · 답하면 다시 진행", "⏸ Parked · answer to go on")).font(.system(size: 11, weight: .medium)).foregroundColor(.orange)
                    if let reason = item.parked?.reason { Text(reason).font(.system(size: 11)).foregroundColor(.secondary) }
                } else if let steps = Self.steps(item, TodoStore.shared.snapshot) {
                    if let note = item.notes.last, note.kind == .system, note.by != nil, TodoStore.shared.snapshot.standInDue(item) == nil {
                        Text(note.text).font(.system(size: 11)).foregroundColor(.secondary)
                    }
                    TimelineView(.periodic(from: .now, by: 30)) { context in
                        Text(steps.map { Self.left($0.at, from: context.date) + " " + $0.what }.joined(separator: " · ") + L(" (그 전에 답하면 네 답대로)", " (unless you answer first)"))
                            .font(.system(size: 11)).foregroundColor(.secondary)
                    }
                } else if let note = item.notes.last, note.kind == .system, note.by != nil {
                    Text(note.text).font(.system(size: 11)).foregroundColor(.secondary)
                }
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
                    Button(L("완료", "Done")) { discussion.markTodoDone(item.id) }
                        .help(L("답 없이 이 TODO를 끝난 것으로 표시해요", "Mark this TODO done without answering"))
                    if question?.delegable == true {
                        Button(L("알아서 해", "Your call")) { text = ""; TodoScheduler.shared?.delegate(item.id) }
                            .help(L("AI에게 판단을 맡겨요. 추천안이 있으면 그걸로, 없으면 AI가 정해서 진행하고, push·배포·삭제 같은 단계는 하지 않고 확인을 받아요.",
                                    "Hand the decision to the AI: it takes the recommended answer or decides itself, and leaves pushing, publishing or deleting for your check."))
                    }
                    // Failed after its retries: with nothing typed it simply tries again.
                    Button(question?.kind == .failed && text.trimmingCharacters(in: .whitespaces).isEmpty ? L("다시 시도", "Try again") : L("답하고 계속", "Answer and go on")) { TodoStore.shared.answer(item.id, text.trimmingCharacters(in: .whitespacesAndNewlines)); text = ""; TodoScheduler.shared?.wake() }
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
        // The publisher is made anew on every redraw, so SwiftUI subscribes again and receives the current value at
        // once. Setting a @Published value, even the same one, redraws the card: set it only when it changes, or the
        // card redraws itself forever and the app stops answering (2026-11-14).
        .onReceive(TodoScheduler.shared?.$standingIn.eraseToAnyPublisher() ?? Just([]).eraseToAnyPublisher()) { standing in
            let on = standing.contains(item.id)
            if stand.on != on { stand.on = on }
        }
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
