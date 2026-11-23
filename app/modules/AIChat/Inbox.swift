import SwiftUI
import AILocalization
import AIProjects

// The inbox (알림함): what waits on the user now, not a record of notices. Worked out from the current state each
// time (nothing saved), so a handled item leaves by itself. 🔴 blocked: the strip's items (BlockedItem, also the Dock);
// 🟡 to check: a TODO's result (still on its board: the same state) and work that ended in an error elsewhere;
// ⚪ for reference: an answer or work that ended elsewhere, until its chat is opened or "Mark all read" (⚪ only: a failure stays).
// The sidebar's old "Needs review" is the 🟡/⚪ part of it (UnreadChats: Discussion's "Needs review" state).
enum InboxCheck: Identifiable {
    case todo(TodoItem), failed(UnreadChat)
    var id: UUID { switch self { case .todo(let t): return t.id; case .failed(let c): return c.id } }
    var at: Date { switch self { case .todo(let t): return t.stateSince ?? t.updatedAt; case .failed(let c): return c.endedAt } }
}

struct Inbox {
    var blocked: [BlockedItem] = []
    var check: [InboxCheck] = []
    var info: [UnreadChat] = []
    var isEmpty: Bool { blocked.isEmpty && check.isEmpty && info.isEmpty }

    // 🔴 in the strip's order; 🟡 and ⚪ newest first.
    static func make(requests: [ProjectApproval], expired: [ProjectApproval], todos: TodoData, conversations: [Conversation],
                     unread: [UUID: Date], running: Set<UUID>, names: [String: String] = [:]) -> Inbox {
        let ended = UnreadChats.list(conversations: conversations, unread: unread, running: running, todo: todos, names: names)
        let check = todos.items.filter { $0.state == .review }.map(InboxCheck.todo) + ended.filter(\.failed).map(InboxCheck.failed)
        return Inbox(blocked: BlockedItem.all(requests: requests, expired: expired, todos: todos),
                     check: check.sorted { $0.at != $1.at ? $0.at > $1.at : $0.id.uuidString < $1.id.uuidString },
                     info: ended.filter { !$0.failed })
    }

    // The TODO's project as the sidebar names it, else its list's title.
    static func projectName(_ item: TodoItem, todos: TodoData, names: [String: String]) -> String {
        guard let list = todos.lists.first(where: { $0.id == item.listID }) else { return "TODO" }
        return list.project.map(SidebarProjects.key).flatMap { names[$0] } ?? list.title
    }

    // One line of an answer or a TODO's text.
    static func line(_ text: String?) -> String? {
        let first = (text ?? "").split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty }
        return first.map { String($0.prefix(160)) }
    }
}

// Which approvals show their whole detail in the inbox (kept while the panel closes; the ids leave with the requests).
// (An ObservableObject: this Mac's Command Line Tools cannot build SwiftUI's @State macro.)
final class InboxDetails: ObservableObject {
    static let shared = InboxDetails()
    @Published var open: Set<UUID> = []
}

// The inbox on the right of the chat window, in the notes' place (ChatView), opened by the bell in the sidebar. A panel,
// not a popover: one keeps what was typed when the user clicks elsewhere. Clicking an item opens where it is; each item
// is also handled right here with the calls its own card makes: Allow/Deny (ProjectCenter.decide), Dismiss/Ask again,
// and a TODO's answer or result box (the board's TodoCard, through ChatApp.screens.inboxCard, with the same draft).
// An outside MCP tool keeps its macOS notification as the way to answer: its row only counts down.
struct InboxPanel: View {
    @ObservedObject var discussion: Discussion
    let close: () -> Void
    @ObservedObject private var center = ProjectCenter.shared
    @ObservedObject private var todos = TodoStore.shared
    @ObservedObject private var projectInfo = ProjectInfoStore.shared
    @ObservedObject private var details = InboxDetails.shared

    var body: some View {
        let inbox = Inbox.make(requests: center.requests, expired: center.expired, todos: todos.snapshot, conversations: discussion.conversations,
                               unread: discussion.unreadRooms, running: discussion.runningRooms, names: projectInfo.names)
        // Seconds count down only while an outside MCP tool waits (60 seconds); minutes otherwise.
        let seconds = inbox.blocked.contains { if case .approval(let r) = $0 { return r.alwaysAllow != nil }; return false }
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text(L("알림함", "Inbox")).font(.system(size: 13, weight: .medium))
                WindowDragRegion().frame(maxWidth: .infinity, maxHeight: .infinity)
                Button(action: close) { Image(systemName: "xmark").font(.system(size: 11)).frame(width: 22, height: 22) }
                    .buttonStyle(.plainHit).foregroundColor(.secondary)
                    .help(L("알림함 닫기", "Close the inbox"))
            }
            .padding(.horizontal, 14).frame(height: 40)
            if inbox.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "checkmark.circle").font(.system(size: 22)).foregroundColor(.secondary)
                    Text(L("지금 처리할 일이 없어요", "Nothing waits on you")).font(.system(size: 12)).foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    TimelineView(.periodic(from: .now, by: seconds ? 1 : 15)) { context in
                        VStack(alignment: .leading, spacing: 2) {
                            if !inbox.blocked.isEmpty {
                                header(L("막힘", "Blocked"), color: .red, count: inbox.blocked.count)
                                ForEach(inbox.blocked) { blockedRow($0, now: context.date) }
                            }
                            if !inbox.check.isEmpty {
                                header(L("확인", "To check"), color: .yellow, count: inbox.check.count)
                                ForEach(inbox.check) { checkRow($0) }
                            }
                            if !inbox.info.isEmpty {
                                header(L("참고", "For reference"), color: Color.secondary.opacity(0.5), count: inbox.info.count) {
                                    Button(L("모두 읽음", "Mark all read")) { discussion.markSeen(inbox.info.map(\.id)) }
                                        .buttonStyle(.plainHit).font(.system(size: 11)).foregroundColor(.accentColor)
                                        .frame(minHeight: 22)
                                }
                                ForEach(inbox.info) { infoRow($0) }
                            }
                        }
                        .padding(.horizontal, 8).padding(.bottom, 12)
                    }
                }
            }
        }
        .frame(width: ChatViewSize.notesWidth)
        .frame(maxHeight: .infinity)
        .background(Color.primary.opacity(0.035))
    }

    private func header(_ title: String, color: Color, count: Int) -> some View { header(title, color: color, count: count) { EmptyView() } }
    private func header<Accessory: View>(_ title: String, color: Color, count: Int, @ViewBuilder accessory: () -> Accessory) -> some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(title).font(.system(size: 11, weight: .semibold)).foregroundColor(.secondary)
            Text("\(count)").font(.system(size: 11).monospacedDigit()).foregroundColor(.secondary)
            Spacer()
            accessory()
        }
        .padding(.horizontal, 6).padding(.top, 12).padding(.bottom, 2)
    }

    @ViewBuilder private func blockedRow(_ item: BlockedItem, now: Date) -> some View {
        switch item {
        case .approval(let request) where request.alwaysAllow != nil:
            // An outside MCP tool has no chat to open: the app's approval window, where its details and buttons are.
            row(request.id, .red, name: L("외부 도구 허가", "Outside tool approval"), line: request.title, time: ApprovalBanner.approvalLeft(request, now: now),
                help: L("허가 창 열기", "Open the approval window")) { ChatApp.screens.approvals() }
        case .approval(let request):
            let home = discussion.approvalHome(request.room)
            VStack(alignment: .leading, spacing: 0) {
                row(request.id, .red, name: discussion.approvalChatName(home), line: L("허가 · ", "Approval · ") + request.title,
                    time: request.deadline == nil ? nil : ApprovalBanner.approvalLeft(request, now: now),
                    help: L("허가를 기다리는 방 열기", "Open the chat waiting for approval")) { discussion.open(home) }
                approvalBox(request)
            }
        case .expired(let request):
            VStack(alignment: .leading, spacing: 0) {
                row(request.id, .red, name: discussion.approvalChatName(request.room), line: L("허가 기한 지남 · 거절로 처리됨 · ", "Approval timed out · denied · ") + request.title,
                    time: nil, help: L("기한이 지난 허가가 있던 방 열기", "Open the chat of the timed-out approval")) { discussion.open(request.room) }
                HStack(spacing: 8) {
                    Spacer()
                    Button(L("닫기", "Dismiss")) { center.dismiss(request.id) }
                    Button(L("다시 요청", "Ask again")) { discussion.askAgain(request) }
                        .buttonStyle(.borderedProminent).disabled(discussion.runningRooms.contains(request.room))
                }
                .font(.system(size: 12)).controlSize(.small).padding(.leading, 23).padding(.trailing, 8).padding(.bottom, 8)
            }
        case .todo(let todo):
            let due = TodoScheduler.shared?.standingIn.contains(todo.id) == true ? L("다른 AI가 대신 답하는 중", "Another AI is answering")
                : ApprovalBanner.todoDue(todo, data: todos.snapshot, discussion: discussion).map { ApprovalBanner.todoLeft($0, now: now) }
            row(todo.id, .red, name: Inbox.projectName(todo, todos: todos.snapshot, names: projectInfo.names),
                line: (todo.isParked ? L("TODO 결정 필요 · 보류됨 · ", "TODO needs you · parked · ") : L("TODO 결정 필요 · ", "TODO needs you · ")) + todo.title,
                time: due, help: Inbox.line(todo.question?.reason) ?? todo.title) { discussion.openTodo(todo) }
            todoBox(todo)
        }
    }

    // What the request does (the detail its card and the approval window show), then Deny / Allow: allowed only where it is read.
    private func approvalBox(_ request: ProjectApproval) -> some View {
        let open = details.open.contains(request.id)
        let lines = request.detail.split(whereSeparator: \.isNewline).count
        return VStack(alignment: .leading, spacing: 6) {
            if !request.detail.isEmpty {
                Text(request.detail).font(.system(size: 10, design: .monospaced)).foregroundColor(.secondary).textSelection(.enabled)
                    .lineLimit(open ? nil : 4).frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6).background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
            }
            HStack(spacing: 8) {
                if lines > 4 || request.detail.count > 240 {
                    Button(open ? L("접기", "Less") : L("자세히", "Details")) {
                        if open { details.open.remove(request.id) } else { details.open.insert(request.id) }
                    }
                    .buttonStyle(.plainHit).foregroundColor(.accentColor).frame(minHeight: 22)
                }
                Spacer()
                Button(L("거절", "Deny")) { center.decide(request.id, allow: false) }
                Button(L("허용", "Allow")) { center.decide(request.id, allow: true) }.buttonStyle(.borderedProminent)
            }
            .font(.system(size: 12)).controlSize(.small)
        }
        .padding(.leading, 23).padding(.trailing, 8).padding(.bottom, 8)
    }

    // A TODO's question (answer box, Your call, Answer and go on) or result (Request changes, Done): the board's own card.
    private func todoBox(_ todo: TodoItem) -> some View {
        ChatApp.screens.inboxCard(todo, discussion).padding(.leading, 23).padding(.trailing, 8).padding(.bottom, 8)
    }

    @ViewBuilder private func checkRow(_ item: InboxCheck) -> some View {
        switch item {
        case .todo(let todo):
            row(todo.id, .yellow, name: Inbox.projectName(todo, todos: todos.snapshot, names: projectInfo.names), line: L("TODO 결과 확인 · ", "TODO result · ") + todo.title,
                time: nil, help: Inbox.line(todo.result) ?? todo.title) { discussion.openTodo(todo) }
            todoBox(todo)
        case .failed(let chat):
            let turn = chat.conversation.turns.last
            row(chat.id, .yellow, name: chat.conversation.title, line: L("작업 실패", "Failed") + (Inbox.line(turn?.error).map { " · " + $0 } ?? ""),
                time: nil, help: chat.project ?? chat.conversation.title) { discussion.open(chat.id) }
                .contextMenu { Button(L("확인한 걸로 표시", "Mark as seen")) { discussion.markSeen(chat.id) } }
        }
    }

    private func infoRow(_ chat: UnreadChat) -> some View {
        let kind = chat.conversation.isProjectChat ? L("작업 완료", "Work done") : L("답변 끝남", "Answered")
        return row(chat.id, Color.secondary.opacity(0.5), name: chat.conversation.title, line: kind + (Inbox.line(chat.conversation.turns.last?.final).map { " · " + $0 } ?? ""),
                   time: nil, help: chat.project ?? chat.conversation.title) { discussion.open(chat.id) }
            .contextMenu { Button(L("읽음으로 표시", "Mark as read")) { discussion.markSeen(chat.id) } }
    }

    // Name (chat or project) over one line of what it is, the time left on the right; the whole row opens it.
    private func row(_ id: UUID, _ color: Color, name: String, line: String, time: String?, help: String, open: (() -> Void)?) -> some View {
        let key = "inbox." + id.uuidString
        return HStack(alignment: .top, spacing: 8) {
            Circle().fill(color).frame(width: 7, height: 7).padding(.top, 5)
            VStack(alignment: .leading, spacing: 1) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(name.isEmpty ? L("새 대화", "New chat") : name).font(.system(size: 12, weight: .semibold)).lineLimit(1).truncationMode(.tail)
                    Spacer(minLength: 4)
                    if let time {
                        Text(time).font(.system(size: 10).monospacedDigit()).foregroundColor(.secondary).lineLimit(1).fixedSize()
                    }
                }
                Text(line).font(.system(size: 11)).foregroundColor(.secondary).lineLimit(2).truncationMode(.tail)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(open != nil && discussion.hoverKey == key ? Color.primary.opacity(0.06) : .clear, in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .onTapGesture { open?() }
        .onHover { inside in discussion.hover(key, inside) }
        .help(help)
        .accessibilityAddTraits(open == nil ? [] : .isButton)
    }
}
