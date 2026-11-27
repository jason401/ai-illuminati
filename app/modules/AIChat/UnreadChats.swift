import Foundation
import AIProjects

// Chats with a finished reply to read, newest first. An explicit request appears in Inbox.
struct UnreadChat: Identifiable {
    var id: UUID { conversation.id }
    let conversation: Conversation
    let project: String?
    let failed: Bool     // the last answer ended in an error
    let endedAt: Date
}

enum UnreadChats {
    // Newest first; a chat answering again (sent from elsewhere) is in Working instead, a deleted one is gone.
    static func list(conversations: [Conversation], unread: [UUID: Date], running: Set<UUID>, todo: TodoData,
                     names: [String: String] = [:]) -> [UnreadChat] {
        let todoRooms = Set(todo.items.compactMap(\.room))
        return conversations.compactMap { chat -> UnreadChat? in
            guard let at = unread[chat.id], !running.contains(chat.id), chat.meetingOf == nil,
                  !todoRooms.contains(chat.id), ChatInputRequest.pending(in: chat) == nil else { return nil }
            let failed = chat.turns.last.map { turn in
                let replies = turn.entries + (turn.moreAnswers ?? [])
                return turn.error != nil || (turn.final == nil && !replies.isEmpty && replies.allSatisfy(\.failed))
            } ?? false
            return UnreadChat(conversation: chat, project: WorkingChats.projectName(chat, todo: todo, names: names), failed: failed, endedAt: at)
        }
        .sorted { $0.endedAt != $1.endedAt ? $0.endedAt > $1.endedAt : $0.id.uuidString < $1.id.uuidString }
    }
}
