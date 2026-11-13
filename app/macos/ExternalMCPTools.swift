import Foundation
import AILocalization
import AIWorkspace
import AIRuntime
import AIProjects
import AIChat
import AIIntegrations

// Outside MCP servers' tools as ToolHub offers them (the connections live in AIIntegrations): never in Enterprise
// chats, and a tool set to "ask" waits for the chat's approval card.
extension ExternalMCP: @retroactive ToolProvider {
    // Enterprise chats get no outside servers (their data would leave through tools the user did not pick for them).
    static var isEnterprise: (UUID) -> Bool = { room in
        let look = { ChatLink.shared.conversations().first { $0.id == room }?.isEnterprise ?? false }
        return Thread.isMainThread ? look() : DispatchQueue.main.sync(execute: look)
    }

    public func tools(context: ToolContext) -> [[String: Any]] {
        let list = tools()
        return list.isEmpty || Self.isEnterprise(context.room) ? [] : list
    }

    public func call(_ name: String, _ arguments: [String: Any], context: ToolContext) -> [String: Any] {
        guard !Self.isEnterprise(context.room) else { return ToolHub.failure("Outside MCP servers are not available in Enterprise chats.") }
        return call(name, arguments) { Self.approve($0, $1, arguments, context) }
    }

    /// The chat's approval card; "Always allow" there saves the rule. Tests replace it.
    static var approve: (String, String, [String: Any], ToolContext) -> Bool = { server, tool, arguments, context in
        let detail = (try? JSONSerialization.data(withJSONObject: arguments, options: [.prettyPrinted, .sortedKeys])).map { String(decoding: $0, as: UTF8.self) } ?? ""
        var request = ProjectApproval(room: context.room, run: context.projectRun ?? UUID(),
                                      title: L("\(server) 도구 사용: \(tool)", "Use \(server) tool: \(tool)"), detail: String(detail.prefix(4000)))
        request.alwaysAllow = { ExternalMCP.shared.setRule(server, tool, .allow) }
        return ProjectCenter.shared.approve(request, token: DebateCancellation(), deadline: Date().addingTimeInterval(ExternalMCP.approvalWait))
    }
}
