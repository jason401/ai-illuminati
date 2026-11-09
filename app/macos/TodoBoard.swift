import SwiftUI

// The TODO board (Todo.swift): sidebar entry with the count waiting for the user, the board shown in place of the
// chat, and the report cards above the message box of a TODO's own chat and of the chat it was written from.

struct TodoSidebarSection: View {
    @ObservedObject var discussion: Discussion
    @ObservedObject private var store = TodoStore.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            SidebarHeader(title: "TODO")
            let selected = discussion.viewingBoard
            let hovered = discussion.hoverKey == "todo.board"
            Button(action: { discussion.viewingRemote = nil; discussion.viewingBoard = true; discussion.sidebarOverlay = false }) {
                HStack(spacing: 8) {
                    Image(systemName: "checklist").frame(width: 18)
                    Text(L("할 일 보드", "TODO board"))
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
    @Published var projectRoot = ""
    @Published var after: Set<UUID> = []
    @Published var askFirst = false
    @Published var error: String?
    @Published var showDone = false
    @Published var replies: [UUID: String] = [:]   // a card's answer or change request, by TODO
}

struct TodoBoardView: View {
    @ObservedObject var discussion: Discussion
    @ObservedObject private var store = TodoStore.shared
    @ObservedObject private var draft = TodoDraft.shared

    // Projects to write TODOs for: every linked Git project of the chats (newest first).
    private var projects: [(name: String, binding: ProjectBinding)] {
        var seen = Set<String>(), result: [(String, ProjectBinding)] = []
        for list in store.snapshot.lists { if let p = list.project, seen.insert(p.root).inserted { result.append((list.title, p)) } }
        for chat in discussion.conversations.sorted(by: { $0.updatedAt > $1.updatedAt }) {
            if let p = chat.workspace?.project, seen.insert(p.root).inserted { result.append(((p.root as NSString).lastPathComponent, p)) }
        }
        return result
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let scheduler = TodoScheduler.shared { TodoBoardHeader(scheduler: scheduler) }
                if let error = draft.error ?? store.saveError { Text(error).font(.system(size: 12)).foregroundColor(.red) }
                ForEach(store.snapshot.lists) { list in listView(list) }
                if store.snapshot.lists.isEmpty {
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
            }
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, item in row(item, index: index + 1, list: list) }
        }
    }

    private func row(_ item: TodoItem, index: Int, list: TodoList) -> some View {
        let data = store.snapshot
        let waits = data.blockers(item).compactMap(data.item).filter { !data.satisfied($0, for: item) && $0.state != .cancelled }
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(list.sequential ? "\(index). " + item.title : item.title).font(.system(size: 13, weight: .medium))
                    .foregroundColor(item.state == .draft ? .secondary : .primary).lineLimit(2)
                Spacer(minLength: 6)
                if item.state == .ready, !waits.isEmpty {
                    Label(waits.map(\.title).joined(separator: ", ") + L(" 기다림", " first"), systemImage: "hourglass").font(.system(size: 11)).foregroundColor(.secondary).lineLimit(1)
                }
                Text(item.state.title + (item.state == .running ? runner(item) : "")).font(.system(size: 12, weight: .medium)).foregroundColor(item.state.color)
                if item.state == .review {
                    Button(L("완료", "Done")) { store.accept(item.id) }.buttonStyle(.borderedProminent).controlSize(.small)
                }
                if let room = item.room {
                    Button(action: { discussion.open(room) }) { Image(systemName: "bubble.left") }.buttonStyle(.plainHit).help(L("이 TODO의 채팅 열기", "Open this TODO's chat"))
                }
                Menu {
                    Button(L("위로", "Move up")) { act { try store.move(item.id, by: -1) } }
                    Button(L("아래로", "Move down")) { act { try store.move(item.id, by: 1) } }
                    Menu(L("먼저 끝나야 할 TODO", "Must finish first")) {
                        ForEach(data.items.filter { $0.id != item.id && $0.state != .cancelled }) { other in
                            Button((item.after.contains(other.id) ? "✓ " : "") + other.title) {
                                act { try store.setAfter(item.id, item.after.contains(other.id) ? item.after.filter { $0 != other.id } : item.after + [other.id]) }
                            }
                        }
                    }
                    if item.state == .draft { Button(L("대기로 (바로 가져가도 됨)", "Make ready")) { try? store.change(item.id) { $0.state = .ready } } }
                    if item.state == .ready { Button(L("초안으로 되돌리기", "Back to draft")) { try? store.change(item.id) { $0.state = .draft } } }
                    Divider()
                    if item.state != .done && item.state != .cancelled { Button(L("그만 (취소)", "Stop (cancel)")) { TodoScheduler.shared?.cancel(item.id) } }
                    Button(L("삭제", "Delete"), role: .destructive) { act { try store.delete(item.id) } }.disabled(item.state == .running)
                } label: { Image(systemName: "ellipsis") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            }
            if !item.detail.isEmpty { Text(item.detail).font(.system(size: 12)).foregroundColor(.secondary).lineLimit(3) }
            if item.state == .review || item.state == .needsYou { TodoCard(item: item, discussion: discussion, compact: true) }
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 9))
        .overlay(item.state == .draft ? RoundedRectangle(cornerRadius: 9).strokeBorder(Color.secondary.opacity(0.4), style: StrokeStyle(lineWidth: 1, dash: [5, 4])) : nil)
    }

    private func runner(_ item: TodoItem) -> String {
        guard let room = item.room, let lead = discussion.conversation(room).configuration?.leadID,
              let account = discussion.model.accounts.first(where: { $0.id == lead }) else { return "" }
        return " · " + discussion.label(account)
    }

    private var addBar: some View {
        let options = projects
        let root = draft.projectRoot.isEmpty ? options.first?.binding.root ?? "" : draft.projectRoot
        return VStack(alignment: .leading, spacing: 8) {
            TextField(L("+ 할 일 추가…", "+ Add a TODO…"), text: $draft.title).textFieldStyle(.roundedBorder).onSubmit(add)
            TextField(L("자세한 내용 (선택)", "Details (optional)"), text: $draft.detail, axis: .vertical).textFieldStyle(.roundedBorder).lineLimit(1...5)
            HStack(spacing: 10) {
                Picker(L("프로젝트", "Project"), selection: Binding(get: { root }, set: { draft.projectRoot = $0 })) {
                    ForEach(options, id: \.binding.root) { Text($0.name).tag($0.binding.root) }
                }
                .fixedSize()
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
    }

    private func add() {
        let text = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let options = projects
        let root = draft.projectRoot.isEmpty ? options.first?.binding.root ?? "" : draft.projectRoot
        guard !text.isEmpty, let project = options.first(where: { $0.binding.root == root }) else { return }
        // The chat open before the board, when it works on the same project, gets the report card too.
        let origin = discussion.current.workspace?.project?.root == root && !store.snapshot.items.contains { $0.room == discussion.currentID } ? discussion.currentID : nil
        // Written for a project worked on in an Enterprise chat: its TODOs keep that lock.
        let lock = (discussion.current.workspace?.project?.root == root ? discussion.current.enterpriseLock : nil)
            ?? discussion.conversations.first { $0.workspace?.project?.root == root && $0.enterpriseLock != nil }?.enterpriseLock
        act {
            try store.add(title: text, detail: draft.detail.trimmingCharacters(in: .whitespacesAndNewlines), project: project.binding, projectName: project.name,
                          after: Array(draft.after), askFirst: draft.askFirst, originRoom: origin, lock: lock)
            draft.title = ""; draft.detail = ""; draft.after = []
        }
    }

    private func act(_ change: () throws -> Void) {
        do { try change(); draft.error = nil } catch { draft.error = error.localizedDescription }
    }
}

// Title, when the board is checked next, why nothing starts, and ▶ Start now.
struct TodoBoardHeader: View {
    @ObservedObject var scheduler: TodoScheduler
    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text(L("할 일 보드", "TODO board")).font(.system(size: 22, weight: .semibold))
                let next = scheduler.nextCheck.map { DateFormatter.localizedString(from: $0, dateStyle: .none, timeStyle: .short) } ?? "–"
                Text(L("할 일이 없을 때는 30분마다 확인 · 다음 확인 \(next)", "Checks every 30 minutes when idle · next \(next)"))
                    .font(.system(size: 12)).foregroundColor(.secondary)
                if let waiting = scheduler.waiting { Text(waiting).font(.system(size: 12)).foregroundColor(.orange) }
            }
            Spacer()
            Button(action: { scheduler.startNow() }) { Label(L("지금 작업 시작", "Start now"), systemImage: "play.fill") }
                .buttonStyle(.borderedProminent).controlSize(.large)
                .help(L("초안을 모두 대기로 바꾸고 바로 확인해요", "Makes every draft ready and checks now"))
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
