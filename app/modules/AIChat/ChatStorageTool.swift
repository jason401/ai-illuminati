import Foundation
import AIWorkspace

// chat_storage: the AI answering a chat can tell how much disk that chat (or, with scope "all", the chats it
// may read, as search_chats) takes. Sizes and titles only; no paths of other chats.
public final class StorageLink: ToolProvider {
    public static let shared = StorageLink()
    static let listLimit = 20
    public var active: Bool { true }
    public func tools() -> [[String: Any]] { [] }
    public func tools(context: ToolContext) -> [[String: Any]] {
        guard context.asker != nil else { return [] }
        return [["name": "chat_storage",
                 "description": "How much disk this chat's data takes in the app (messages, chat folder, dropped files, pictures, backups before AI writes, CLI sessions), measured now. scope \"all\": the largest of the chats you may read, too. Linked project folders are not counted.",
                 "inputSchema": ["type": "object", "properties": ["scope": ["type": "string", "enum": ["this", "all"]]], "additionalProperties": false]]]
    }
    public func call(_ name: String, _ arguments: [String: Any], context: ToolContext) -> [String: Any] {
        guard name == "chat_storage" else { return toolFailure("Unknown tool: " + name) }
        let all = Thread.isMainThread ? ChatLink.shared.conversations() : DispatchQueue.main.sync { ChatLink.shared.conversations() }
        let chats = all.map { (id: $0.id, title: $0.title, meetingOf: $0.meetingOf?.room) }
        let wide = (arguments["scope"] as? String) == "all"
        var only: Set<UUID> = [context.room]
        if wide { only.formUnion(all.filter { ChatLink.allowed($0, asker: context.asker, room: context.room) }.map(\.id)) }
        let report = ChatStorage.report(chats, only: only)
        var lines: [String] = []
        if let mine = report.rooms.first(where: { $0.id == context.room }) {
            lines.append("[This chat] " + ChatStorage.describe(mine))
        } else { lines.append("[This chat] nothing stored yet") }
        if wide {
            lines.append("[Largest chats you may read]")
            for room in report.rooms.filter({ $0.id != context.room }).prefix(Self.listLimit) {
                lines.append("- \"\(room.title)\" (id \(room.id.uuidString)): " + ChatStorage.describe(room))
            }
            lines.append("Total of these: \(ChatStorage.format(report.total.allocated)). The user sees every chat in Settings > Chat > Storage > Show List.")
        }
        return ["content": [["type": "text", "text": lines.joined(separator: "\n")]], "isError": false]
    }
}
