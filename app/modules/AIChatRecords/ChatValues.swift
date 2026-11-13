import Foundation
import ImageIO
import UniformTypeIdentifiers
import AIAccounts

// The values a chat's record holds, each saved inside chats/<id>.json (or a synced copy) as it was.

public struct ChatImage: Identifiable, Codable, Equatable {
    public var id = UUID()
    public var conversationID: UUID
    public var name: String
    public var url: URL {
        URL(fileURLWithPath: ChatPaths.dir).appendingPathComponent(conversationID.uuidString + ".assets")
            .appendingPathComponent(id.uuidString + ".png")
    }
    public init(id: UUID = UUID(), conversationID: UUID, name: String) {
        self.id = id
        self.conversationID = conversationID
        self.name = name
    }
}

public enum ImageStore {
    public static func importImage(_ data: Data, name: String, conversationID: UUID, id: UUID = UUID(), maxEdge: Int = 1600) throws -> ChatImage {
        guard data.count <= 25 * 1024 * 1024,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxEdge
              ] as CFDictionary) else { throw Failure.invalid }
        let item = ChatImage(id: id, conversationID: conversationID, name: name)
        try FileManager.default.createDirectory(at: item.url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let encoded = NSMutableData()
        guard let target = CGImageDestinationCreateWithData(encoded, UTType.png.identifier as CFString, 1, nil) else { throw Failure.invalid }
        CGImageDestinationAddImage(target, image, nil)
        guard CGImageDestinationFinalize(target) else { throw Failure.invalid }
        if encoded.length > 4_500_000 {
            guard maxEdge > 1024 else { throw Failure.invalid }
            return try importImage(data, name: name, conversationID: conversationID, id: id, maxEdge: 1024)
        }
        try (encoded as Data).write(to: item.url, options: .atomic)
        return item
    }
    public enum Failure: Error { case invalid }
    public static func remove(_ item: ChatImage) throws {
        if FileManager.default.fileExists(atPath: item.url.path) { try FileManager.default.removeItem(at: item.url) }
    }
}

public struct RoomDocument: Codable, Identifiable {
    public var id = UUID()
    public var name: String
    public var text: String
    public var units: [MaterialUnit]?
    public var notice: String?
    public init(id: UUID = UUID(), name: String, text: String, units: [MaterialUnit]? = nil, notice: String? = nil) {
        self.id = id
        self.name = name
        self.text = text
        self.units = units
        self.notice = notice
    }
}

public struct MaterialUnit: Codable, Identifiable {
    public var id: String
    public var locator: String
    public var text: String
    public var images: [String] = []
    public init(id: String, locator: String, text: String, images: [String] = []) {
        self.id = id
        self.locator = locator
        self.text = text
        self.images = images
    }
}

public struct CollaborationTask: Codable, Identifiable, Equatable {
    public var id = UUID()
    public var title: String
    public var accountID: String
    public var state = "queued"
    public var output: String?
    public var planID: String?
    public var dependsOn: [String]?
    public var expectedFiles: [String]?
    public var outputDigest: String?
    public init(id: UUID = UUID(), title: String, accountID: String, state: String = "queued", output: String? = nil, planID: String? = nil, dependsOn: [String]? = nil, expectedFiles: [String]? = nil, outputDigest: String? = nil) {
        self.id = id
        self.title = title
        self.accountID = accountID
        self.state = state
        self.output = output
        self.planID = planID
        self.dependsOn = dependsOn
        self.expectedFiles = expectedFiles
        self.outputDigest = outputDigest
    }
}

// Mode 4 · Vote (Vote.swift): one AI's ballot.
public struct VoteBallot: Codable, Equatable {
    public var speaker: String
    public var choice: Int?   // 1-based; nil = no valid vote
    public var reason: String
    public init(speaker: String, choice: Int? = nil, reason: String) {
        self.speaker = speaker
        self.choice = choice
        self.reason = reason
    }
}

// A project chat's message: how it was answered (Route.swift).
public enum ChatRoute: String, Codable { case opinion, work }

// A meeting's own chat (Meeting.swift): the message it was held for.
public struct MeetingLink: Codable, Equatable {
    public var room: UUID   // the chat the meeting was held for
    public var turn: UUID   // its message
    public init(room: UUID, turn: UUID) {
        self.room = room
        self.turn = turn
    }
}

// Where a chat continued on this Mac came from.
public struct SyncOrigin: Codable, Equatable {
    public var device: String        // the other Mac's device ID
    public var deviceName: String
    public var chat: UUID            // the chat's ID on that Mac
    public var lastTurn: UUID?       // its newest turn when it was copied
    public var contentAt: Date       // when that chat last changed
    public var importedAt: Date
    public init(device: String, deviceName: String, chat: UUID, lastTurn: UUID? = nil, contentAt: Date, importedAt: Date) {
        self.device = device
        self.deviceName = deviceName
        self.chat = chat
        self.lastTurn = lastTurn
        self.contentAt = contentAt
        self.importedAt = importedAt
    }
}

// A chat in another Mac's folder, listed without reading all of it.
public struct RemoteChat: Identifiable, Equatable {
    public enum Status: Equatable { case ready, downloading, unreadable, newerVersion }
    public var device: String
    public var deviceName: String
    public var chat: UUID
    public var title: String
    public var updatedAt: Date?
    public var school: Bool
    public var status: Status
    public var file: URL
    public var id: String { device + "/" + chat.uuidString }
    public init(device: String, deviceName: String, chat: UUID, title: String, updatedAt: Date? = nil, school: Bool, status: Status, file: URL) {
        self.device = device
        self.deviceName = deviceName
        self.chat = chat
        self.title = title
        self.updatedAt = updatedAt
        self.school = school
        self.status = status
        self.file = file
    }
}
