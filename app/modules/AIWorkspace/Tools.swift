import Foundation
import AIAccounts

public struct ToolContext {
    public var room: UUID
    public var roots: [WorkspaceRoot]
    public var projectRun: UUID? = nil
    public var projectGeneration: Int? = nil
    public var asker: Account? = nil   // the account answering (search_chats / read_chat decide by it)
    public var turn: UUID? = nil       // the message being answered when the session was made (remember saves only to it)
    public var origin: ToolOrigin = .member
    public init(room: UUID, roots: [WorkspaceRoot], projectRun: UUID? = nil, projectGeneration: Int? = nil, asker: Account? = nil, turn: UUID? = nil, origin: ToolOrigin = .member) {
        self.room = room; self.roots = roots; self.projectRun = projectRun; self.projectGeneration = projectGeneration; self.asker = asker; self.turn = turn; self.origin = origin
    }
}

public protocol ToolProvider: AnyObject {
    var active: Bool { get }
    func tools() -> [[String: Any]]
    func tools(context: ToolContext) -> [[String: Any]]
    func call(_ name: String, _ arguments: [String: Any], context: ToolContext) -> [String: Any]
}

extension ToolProvider {
    public func tools(context: ToolContext) -> [[String: Any]] { tools() }
}
