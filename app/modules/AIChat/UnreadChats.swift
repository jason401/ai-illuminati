import Foundation
import AIProjects

// "Needs review" (확인 필요) rows under Working; the state and its rules are Discussion's ("Needs review" in Discussion.swift).
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
        conversations.compactMap { chat -> UnreadChat? in
            guard let at = unread[chat.id], !running.contains(chat.id), chat.meetingOf == nil else { return nil }
            let last = chat.turns.last
            let failed = last.map { $0.error != nil || ($0.final == nil && !$0.entries.isEmpty && $0.entries.allSatisfy(\.failed)) } ?? false
            return UnreadChat(conversation: chat, project: WorkingChats.projectName(chat, todo: todo, names: names), failed: failed, endedAt: at)
        }
        .sorted { $0.endedAt != $1.endedAt ? $0.endedAt > $1.endedAt : $0.id.uuidString < $1.id.uuidString }
    }
}
