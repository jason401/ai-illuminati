import Foundation
import AILocalization
import AIRuntime
import AIWorkspace

// How much disk each chat takes (Settings > Chat > Storage, and the AIs' chat_storage tool). Read only.
// A chat's data is everything under paths carrying its id (the same ones ChatStore.delete removes):
// its messages, its work folder, dropped files, pictures, the backups made before AI writes, and the
// CLI session folders. A meeting is counted with the chat it was held for. Linked project folders are
// the user's own and not counted. The CLIs' own transcripts in the account folders are not counted yet.
// Sizes are read from file metadata only (lstat), so cloud-only files are not downloaded; symbolic
// links are not followed, and a file with several hard links counts once. Backups are APFS clones that
// share blocks with the originals, so their size is an upper bound of what deleting them frees.
public enum ChatStorage {
    public typealias Size = DiskUsage.Size
    public enum Kind: String, CaseIterable {
        case chat, work, documents, pictures, backups, sessions
        public var title: String {
            switch self {
            case .chat: return L("대화", "Messages")
            case .work: return L("채팅 폴더", "Chat folder")
            case .documents: return L("드롭한 파일", "Dropped files")
            case .pictures: return L("그림", "Pictures")
            case .backups: return L("백업", "Backups")
            case .sessions: return L("CLI 세션", "CLI sessions")
            }
        }
    }
    public struct Room: Identifiable {
        public var id: UUID
        public var title: String
        public var parts: [Kind: Size] = [:]
        public var meetings = 0
        public var backups = 0
        public var total: Size { parts.values.reduce(Size(), +) }
    }
    public struct Report {
        public var rooms: [Room] = []            // largest first
        public var orphans: [(url: URL, size: Size)] = []   // data of chats that are gone
        public var total = Size()
        public var date = Date()
    }

    public static func items(_ room: UUID) -> [(Kind, URL)] {
        let chats = URL(fileURLWithPath: ChatPaths.dir), id = room.uuidString
        let sessions = NativeSessions.directory(room)
        let archive = sessions.deletingLastPathComponent().appendingPathComponent("archived")
        let archived = ((try? FileManager.default.contentsOfDirectory(atPath: archive.path)) ?? [])
            .filter { $0.hasPrefix(id + "-") }.map { (Kind.sessions, archive.appendingPathComponent($0)) }
        return [(.chat, chats.appendingPathComponent(id + ".json")),
                (.work, chats.appendingPathComponent(id + ".work")),
                (.documents, RoomDocuments.directory(room)),
                (.pictures, chats.appendingPathComponent(id + ".assets")),
                (.backups, WorkspaceBackup.base.appendingPathComponent(id)),
                (.sessions, sessions)] + archived
    }

    typealias FileID = DiskUsage.FileID
    static func size(of url: URL, seen: inout Set<FileID>) -> Size { DiskUsage.of(url, seen: &seen) }
    static func size(of url: URL) -> Size { DiskUsage.of(url) }

    // `chats`: id, title and the chat a meeting belongs to, for every chat the app has.
    public static func report(_ chats: [(id: UUID, title: String, meetingOf: UUID?)], only: Set<UUID>? = nil) -> Report {
        var seen = Set<FileID>(), rooms: [UUID: Room] = [:]
        let known = Set(chats.map(\.id))
        for chat in chats where chat.meetingOf == nil || !known.contains(chat.meetingOf!) {
            if let only, !only.contains(chat.id) { continue }
            rooms[chat.id] = Room(id: chat.id, title: chat.title)
        }
        for chat in chats {
            let owner = chat.meetingOf.flatMap { known.contains($0) ? $0 : nil } ?? chat.id
            guard rooms[owner] != nil else { continue }
            if owner != chat.id { rooms[owner]?.meetings += 1 }
            for (kind, url) in items(chat.id) where FileManager.default.fileExists(atPath: url.path) {
                rooms[owner]?.parts[kind, default: Size()] += size(of: url, seen: &seen)
                if kind == .backups {
                    rooms[owner]?.backups += ((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []).filter { UUID(uuidString: $0) != nil }.count
                }
            }
        }
        var report = Report()
        report.rooms = rooms.values.sorted { $0.total.allocated > $1.total.allocated }
        report.total = report.rooms.map(\.total).reduce(Size(), +)
        guard only == nil else { return report }
        // Data whose chat is gone: the same kinds of paths, named by an id no chat has.
        let ids = Set(known.map(\.uuidString))
        let chatDir = URL(fileURLWithPath: ChatPaths.dir), sessions = NativeSessions.directory(UUID()).deletingLastPathComponent()
        var places: [URL] = []
        for name in (try? FileManager.default.contentsOfDirectory(atPath: chatDir.path)) ?? [] {
            let id = String(name.prefix(36))
            if UUID(uuidString: id) != nil, !ids.contains(id) { places.append(chatDir.appendingPathComponent(name)) }
        }
        for folder in [WorkspaceBackup.base, sessions, sessions.appendingPathComponent("archived")] {
            for name in (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [] {
                let id = String(name.prefix(36))
                if UUID(uuidString: id) != nil, !ids.contains(id) { places.append(folder.appendingPathComponent(name)) }
            }
        }
        report.orphans = places.map { ($0, size(of: $0, seen: &seen)) }.sorted { $0.1.allocated > $1.1.allocated }
        report.total += report.orphans.map(\.size).reduce(Size(), +)
        return report
    }

    public static func format(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }

    public static func describe(_ room: Room) -> String {
        var line = "\(format(room.total.allocated)) on disk (\(format(room.total.logical)) in \(room.total.files) files)"
        let parts = Kind.allCases.compactMap { kind in room.parts[kind].flatMap { $0.allocated > 0 || $0.files > 0 ? "\(kind.rawValue) \(format($0.allocated))" : nil } }
        if !parts.isEmpty { line += "; " + parts.joined(separator: ", ") }
        if room.backups > 0 { line += "; \(room.backups) backups (APFS clones: an upper bound)" }
        if room.meetings > 0 { line += "; includes \(room.meetings) meetings" }
        if room.total.unreadable > 0 { line += "; \(room.total.unreadable) entries unreadable (sum may be low)" }
        return line
    }
}
