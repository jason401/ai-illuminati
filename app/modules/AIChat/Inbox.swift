import SwiftUI
import AILocalization
import AIProjects

// One explicit request from the AI writing the reply. It goes before any other hidden reply metadata.
enum ChatInputRequest {
    private static let opening = "<needs-you>", closing = "</needs-you>"
    static let rule = """

        [Inbox]
        If progress requires a specific answer, decision or action that only the user can provide, explain it in your reply.
        Then add one plain-text line at the end, before other hidden metadata, in this format:
        <needs-you>the exact request in the user's language</needs-you>
        Keep it under 300 characters. Use this only when blocked on the user. Omit it for optional follow-ups,
        ordinary status reports, or approvals and TODO questions already handled by the app.
        """

    // Split the trailing line out of the visible reply, including while it is still streaming.
    static func extract(_ text: String) -> (reply: String, request: String?) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lineStart = trimmed.lastIndex(where: \.isNewline).map { trimmed.index(after: $0) } ?? trimmed.startIndex
        let line = trimmed[lineStart...].trimmingCharacters(in: .whitespaces)
        guard line.hasPrefix(opening) || (line.hasPrefix("<needs") && opening.hasPrefix(line)) else { return (text, nil) }
        let reply = trimmed[..<lineStart].trimmingCharacters(in: .whitespacesAndNewlines)
        guard line.hasPrefix(opening), line.hasSuffix(closing) else { return (reply, nil) }
        let body = line.dropFirst(opening.count).dropLast(closing.count).trimmingCharacters(in: .whitespaces)
        guard !body.isEmpty, body.count <= 300, !body.contains(opening), !body.contains(closing) else { return (reply, nil) }
        return (reply.isEmpty ? body : reply, body)
    }

    static func pending(in chat: Conversation) -> (text: String, at: Date)? {
        guard chat.meetingOf == nil, chat.subOf == nil, let turn = chat.turns.last,
              let text = turn.inputRequest, let at = turn.answeredAt else { return nil }
        return (text, at)
    }
}

// The inbox follows actions still waiting for the user. Opening a chat only changes its read state.
enum InboxCheck: Identifiable {
    case todo(TodoItem), request(room: UUID, name: String, text: String, at: Date)
    var id: UUID { switch self { case .todo(let t): return t.id; case .request(let room, _, _, _): return room } }
    var at: Date { switch self { case .todo(let t): return t.stateSince ?? t.updatedAt; case .request(_, _, _, let at): return at } }
}

struct Inbox {
    var blocked: [BlockedItem] = []
    var check: [InboxCheck] = []
    var isEmpty: Bool { blocked.isEmpty && check.isEmpty }

    static func make(requests: [ProjectApproval], todos: TodoData, conversations: [Conversation], running: Set<UUID>) -> Inbox {
        let todoRooms = Set(todos.items.compactMap(\.room))
        let chatRequests = conversations.compactMap { chat -> InboxCheck? in
            guard !running.contains(chat.id), !todoRooms.contains(chat.id), let pending = ChatInputRequest.pending(in: chat) else { return nil }
            return .request(room: chat.id, name: chat.title, text: pending.text, at: pending.at)
        }
        let check = todos.items.filter { $0.state == .review }.map(InboxCheck.todo) + chatRequests
        return Inbox(blocked: BlockedItem.all(requests: requests, todos: todos),
                     check: check.sorted { $0.at != $1.at ? $0.at > $1.at : $0.id.uuidString < $1.id.uuidString })
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
// can also be handled here with the calls its own card makes: Allow/Deny (ProjectCenter.decide)
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
        let inbox = Inbox.make(requests: center.requests, todos: todos.snapshot, conversations: discussion.conversations, running: discussion.runningRooms)
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
                                header(L("응답·검토 필요", "Reply or review"), color: .yellow, count: inbox.check.count)
                                ForEach(inbox.check) { checkRow($0) }
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

    private func header(_ title: String, color: Color, count: Int) -> some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(title).font(.system(size: 11, weight: .semibold)).foregroundColor(.secondary)
            Text("\(count)").font(.system(size: 11).monospacedDigit()).foregroundColor(.secondary)
            Spacer()
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
        return VStack(alignment: .leading, spacing: 6) {
            if !request.detail.isEmpty {
                Text(request.detail).font(.system(size: 10, design: .monospaced)).foregroundColor(.secondary).textSelection(.enabled)
                    .lineLimit(open ? nil : 4).frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6).background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
            }
            HStack(spacing: 8) {
                // Whenever there is a detail: in 280 pt even one line can wrap past four, and Allow comes after reading it whole.
                if !request.detail.isEmpty {
                    Button(open ? L("접기", "Less") : L("자세히", "Details")) {
                        if open { details.open.remove(request.id) } else { details.open.insert(request.id) }
                    }
                    .buttonStyle(.plainHit).foregroundColor(.accentColor).frame(minHeight: 22)
                }
                Spacer()
                Button(L("거절", "Deny")) { center.decide(request.id, allow: false) }
                Button(request.allowLabel ?? L("허용", "Allow")) { center.decide(request.id, allow: true) }.buttonStyle(.borderedProminent)
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
        case .request(let room, let name, let text, _):
            row(room, .yellow, name: name, line: text, time: nil, help: text) { discussion.open(room) }
        }
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
