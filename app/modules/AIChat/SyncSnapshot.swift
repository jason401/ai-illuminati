import Foundation
import AIAccounts

// One chat as another Mac sees it. Unknown newer versions are listed as unreadable, never guessed at.
public struct SyncSnapshot: Codable, Equatable {
    public static let version = 1
    public var schemaVersion = SyncSnapshot.version
    public var id: UUID
    public var title: String
    public var createdAt: Date
    public var updatedAt: Date
    public var school: Bool
    public var mode: Int
    public var summary: String
    public var state: String?        // the chat state (.illuminati/state.md), the context a new session starts from
    public var stateTurn: UUID?      // the newest turn that state covers; later turns go word for word
    public var turns: [ChatTurn]
    public var pictures: Int         // pictures left out of the copy
    public var origin: SyncOrigin?   // set when this chat was itself continued from another Mac
    public var enterpriseLock: EnterpriseLock?   // an Enterprise chat (`school` is true then too, for older apps)
    public init(schemaVersion: Int = SyncSnapshot.version, id: UUID, title: String, createdAt: Date, updatedAt: Date, school: Bool, mode: Int, summary: String, state: String? = nil, stateTurn: UUID? = nil, turns: [ChatTurn], pictures: Int, origin: SyncOrigin? = nil, enterpriseLock: EnterpriseLock? = nil) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.school = school
        self.mode = mode
        self.summary = summary
        self.state = state
        self.stateTurn = stateTurn
        self.turns = turns
        self.pictures = pictures
        self.origin = origin
        self.enterpriseLock = enterpriseLock
    }
}
