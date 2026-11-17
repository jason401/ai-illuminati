import Foundation
import AILocalization
import AIChatRecords
import AIProjects

// The iPhone page's view of the chats (the App serves it through AIRemote): the sidebar's sections in its order,
// one chat's messages and approval cards, and a message sent the way the message box sends it. Values are plain
// JSON (strings, numbers, arrays), so the page and the server need no chat type.
public enum RemoteChats {
    // Working, Needs review, Pinned, Projects (each folder with its newest chats), Recents, like ChatView's sidebar.
    public static func list(_ d: Discussion) -> [[String: Any]] {
        let todo = TodoStore.shared.snapshot, names = ProjectInfoStore.shared.names
        let waiting = Dictionary(grouping: ProjectCenter.shared.requests, by: \.room).mapValues(\.count)
        func row(_ chat: Conversation, depth: Int = 0, detail: String? = nil) -> [String: Any] {
            var row: [String: Any] = ["id": chat.id.uuidString, "title": chat.title, "depth": depth,
                                      "working": d.runningRooms.contains(chat.id), "unread": d.unreadRooms[chat.id] != nil]
            if let detail { row["detail"] = detail }
            if let count = waiting[chat.id] { row["approvals"] = count }
            return row
        }
        var sections: [[String: Any]] = []
        func add(_ title: String, _ rows: [[String: Any]]) { if !rows.isEmpty { sections.append(["title": title, "chats": rows]) } }
        add(L("작업 중", "Working"), WorkingChats.list(conversations: d.conversations, running: d.runningRooms, stopping: d.stoppingRooms,
                                                     todo: todo, names: names).map { row($0.conversation, detail: $0.project) })
        add(L("확인 필요", "Needs review"), UnreadChats.list(conversations: d.conversations, unread: d.unreadRooms, running: d.runningRooms,
                                                         todo: todo, names: names).map { row($0.conversation, detail: $0.project) })
        let grouped = SidebarProjects.group(d.listedConversations.filter(\.hasContent), todo: todo, pinned: SidebarFold.shared.pinnedProjects, names: names)
        add(L("고정됨", "Pinned"), grouped.loose.filter { $0.pinned == true }.map { row($0) })
        add(L("프로젝트", "Projects"), grouped.projects.flatMap { group -> [[String: Any]] in
            let rooms = SidebarProjects.runningFirst(group, todo: todo, running: d.runningRooms)
            let chats = rooms.running + rooms.going + SidebarFold.listedChats(rooms.chats, limit: SidebarFold.projectPage * 2, open: nil).rows
            return [["folder": group.name, "id": "project." + group.id]] + chats.map { row($0, depth: 1) }
        })
        add(L("최근", "Recents"), grouped.loose.filter { $0.pinned != true }.prefix(SidebarFold.recentsPage * 3).map { row($0) })
        return sections
    }

    // One chat as the page shows it: the user's messages and each AI's answer (the reply so far while it writes),
    // with picture links (/api/image/<chat>/<picture>) and the approval cards waiting in it. Opening it counts as seen.
    public static func chat(_ d: Discussion, _ room: UUID, opened: Bool) -> [String: Any]? {
        guard let chat = d.conversations.first(where: { $0.id == room }) else { return nil }
        if opened { d.markSeen(room) }
        let working = d.runningRooms.contains(room)
        func links(_ images: [ChatImage]?) -> [String] { (images ?? []).map { "/api/image/\(room.uuidString)/\($0.id.uuidString)" } }
        var turns: [[String: Any]] = []
        for (index, turn) in chat.turns.enumerated() {
            if !turn.question.isEmpty || !(turn.images ?? []).isEmpty {
                turns.append(["mine": true, "text": turn.question, "images": links(turn.images)])
            }
            var answers: [[String: Any]] = []
            if let final = turn.final {
                answers.append(["name": turn.finalBy ?? "AI", "text": final, "images": links(turn.finalImages)])
            } else if turn.mode != 0, let last = turn.entries.last(where: { !$0.failed }) {
                answers.append(["name": last.speaker, "text": last.text, "images": links(last.images)])
            }
            for more in turn.mode == 0 ? turn.moreAnswers ?? [] : [] {
                answers.append(["name": more.speaker, "text": more.text, "images": links(more.images), "error": more.failed ? more.text : NSNull()])
            }
            if let partials = turn.partials, turn.final == nil {
                for name in turn.answerOrder ?? partials.keys.sorted() { if let text = partials[name], !text.isEmpty { answers.append(["name": name, "text": text, "waiting": true]) } }
            } else if let partial = turn.partial, !partial.isEmpty {
                answers.append(["name": turn.partialBy ?? "AI", "text": partial, "waiting": true])
            }
            let last = index == chat.turns.count - 1
            if answers.isEmpty, last, working {
                answers.append(["name": turn.partialBy ?? (turn.status.isEmpty ? "AI" : turn.status), "text": "", "waiting": true])
            }
            if let error = turn.error {
                if answers.isEmpty { answers.append(["name": "AI", "text": ""]) }
                answers[answers.count - 1]["error"] = error
            }
            turns.append(contentsOf: answers.map { $0.merging(["mine": false]) { a, _ in a } })
        }
        for queued in chat.queued ?? [] { turns.append(["mine": true, "text": queued.text, "images": links(queued.images), "waiting": true]) }
        let approvals = ProjectCenter.shared.requests.filter { $0.room == room }
            .map { ["id": $0.id.uuidString, "title": $0.title, "detail": $0.detail] }
        return ["id": room.uuidString, "title": chat.title, "working": working, "turns": turns, "approvals": approvals,
                "readOnly": chat.meetingOf != nil]
    }

    // A picture of this chat by its id (a message's, an answer's or a queued one's), for the page's <img>.
    public static func image(_ d: Discussion, _ room: UUID, id: UUID) -> URL? {
        guard let chat = d.conversations.first(where: { $0.id == room }) else { return nil }
        var all: [ChatImage] = (chat.queued ?? []).flatMap { $0.images ?? [] }
        for turn in chat.turns {
            all += (turn.images ?? []) + (turn.finalImages ?? [])
            for entry in turn.entries + (turn.moreAnswers ?? []) { all += entry.images ?? [] }
        }
        return all.first { $0.id == id }?.url
    }

    // Sent from the phone like the message box sends (send()): into the queue while the chat answers, to its TODO,
    // or a new turn. Photos are imported into the chat (at most 4, like addImage). Returns why it was not sent.
    public static func send(_ d: Discussion, room: UUID, text: String, photos: [Data]) -> String? {
        guard d.host == nil, let chat = d.conversations.first(where: { $0.id == room }) else { return L("대화를 찾지 못했어요.", "Chat not found.") }
        guard chat.meetingOf == nil else { return L("회의 기록에는 보낼 수 없어요.", "A meeting record cannot take messages.") }
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !photos.isEmpty else { return L("보낼 내용이 없어요.", "Nothing to send.") }
        guard photos.count <= 4, chat.turns.flatMap({ $0.images ?? [] }).count + photos.count < 200 else {
            return L("한 메시지에 4장, 한 대화에 200장까지 첨부할 수 있습니다.", "Attach up to 4 images per message and 200 per chat.")
        }
        let running = d.runningRooms.contains(room)
        if !running, d.runningRooms.count >= Discussion.maxRunning {
            return L("동시에 \(Discussion.maxRunning)개 대화까지 답할 수 있어요. 하나가 끝나면 보낼 수 있어요.",
                     "Up to \(Discussion.maxRunning) chats can answer at once. Send when one finishes.")
        }
        var images: [ChatImage] = []
        for (i, data) in photos.enumerated() {
            do { images.append(try ImageStore.importImage(data, name: L("iPhone 사진 \(i + 1)", "iPhone photo \(i + 1)"), conversationID: room)) } catch {
                for image in images { try? ImageStore.remove(image) }
                return L("사진을 첨부할 수 없습니다.", "Could not attach the photo.")
            }
        }
        // Like addImage: a Gemini leader cannot see pictures (while answering, flushQueue switches it).
        if !images.isEmpty, !running, d.configuration(of: room).leader == .gemini {
            d.configure(room: room) { config in config.leader = config.participants.contains(.claude) ? .claude : .codex }
        }
        let message = QueuedMessage(text: text, images: images.isEmpty ? nil : images, mentions: nil, route: nil)
        if running { d.enqueue(message, room: room); return nil }
        let ready = d.prepare(message, room: room)
        switch d.sendToTodo(ready, room: room) {
        case .failed(let reason): for image in images { try? ImageStore.remove(image) }; return reason
        case .sent: return nil
        case .notTodo:
            if let reason = d.startTurn(room: room, question: ready.question, mentioned: ready.mentioned, images: ready.images, forced: ready.picked) {
                for image in images { try? ImageStore.remove(image) }
                return reason
            }
            return nil
        }
    }
}
