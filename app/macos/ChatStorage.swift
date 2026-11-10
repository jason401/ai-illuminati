import Foundation

// How much disk each chat takes (Settings > Storage, and the AIs' chat_storage tool). Read only.
// A chat's data is everything under paths carrying its id (the same ones ChatStore.delete removes):
// its messages, its work folder, dropped files, pictures, the backups made before AI writes, and the
// CLI session folders. A meeting is counted with the chat it was held for. Linked project folders are
// the user's own and not counted. The CLIs' own transcripts in the account folders are not counted yet.
// Sizes are read from file metadata only (lstat), so cloud-only files are not downloaded; symbolic
// links are not followed, and a file with several hard links counts once. Backups are APFS clones that
// share blocks with the originals, so their size is an upper bound of what deleting them frees.
enum ChatStorage {
    struct Size: Equatable {
        var allocated: Int64 = 0   // disk blocks used
        var logical: Int64 = 0     // bytes in the files
        var files = 0
        var unreadable = 0         // entries that could not be read (the sum may be low)
        static func + (a: Size, b: Size) -> Size {
            Size(allocated: a.allocated + b.allocated, logical: a.logical + b.logical, files: a.files + b.files, unreadable: a.unreadable + b.unreadable)
        }
        static func += (a: inout Size, b: Size) { a = a + b }
    }
    enum Kind: String, CaseIterable {
        case chat, work, documents, pictures, backups, sessions
        var title: String {
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
    struct Room: Identifiable {
        var id: UUID
        var title: String
        var parts: [Kind: Size] = [:]
        var meetings = 0
        var backups = 0
        var total: Size { parts.values.reduce(Size(), +) }
    }
    struct Report {
        var rooms: [Room] = []            // largest first
        var orphans: [(url: URL, size: Size)] = []   // data of chats that are gone
        var total = Size()
        var date = Date()
    }

    static func items(_ room: UUID) -> [(Kind, URL)] {
        let chats = URL(fileURLWithPath: ChatStore.dir), id = room.uuidString
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

    struct FileID: Hashable { var device: Int32; var inode: UInt64 }
    // The size of a file or folder. `seen` keeps hard links counted once across calls.
    static func size(of url: URL, seen: inout Set<FileID>) -> Size {
        var result = Size()
        func add(_ path: String) -> Bool {   // true: a directory to go into
            var info = stat()
            guard lstat(path, &info) == 0 else { result.unreadable += 1; return false }
            let type = info.st_mode & S_IFMT
            if info.st_nlink > 1, type != S_IFDIR, !seen.insert(FileID(device: info.st_dev, inode: UInt64(info.st_ino))).inserted { return false }
            result.allocated += Int64(info.st_blocks) * 512
            if type == S_IFREG { result.logical += Int64(info.st_size); result.files += 1 }
            return type == S_IFDIR
        }
        guard add(url.path) else { return result }
        guard let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil, options: [], errorHandler: { _, _ in result.unreadable += 1; return true }) else { return result }
        for case let file as URL in walker {
            if !add(file.path), (try? FileManager.default.destinationOfSymbolicLink(atPath: file.path)) != nil { walker.skipDescendants() }
        }
        return result
    }
    static func size(of url: URL) -> Size { var seen = Set<FileID>(); return size(of: url, seen: &seen) }

    // `chats`: id, title and the chat a meeting belongs to, for every chat the app has.
    static func report(_ chats: [(id: UUID, title: String, meetingOf: UUID?)], only: Set<UUID>? = nil) -> Report {
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
        let chatDir = URL(fileURLWithPath: ChatStore.dir), sessions = NativeSessions.directory(UUID()).deletingLastPathComponent()
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

    static func format(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }

    static func describe(_ room: Room) -> String {
        var line = "\(format(room.total.allocated)) on disk (\(format(room.total.logical)) in \(room.total.files) files)"
        let parts = Kind.allCases.compactMap { kind in room.parts[kind].flatMap { $0.allocated > 0 || $0.files > 0 ? "\(kind.rawValue) \(format($0.allocated))" : nil } }
        if !parts.isEmpty { line += "; " + parts.joined(separator: ", ") }
        if room.backups > 0 { line += "; \(room.backups) backups (APFS clones: an upper bound)" }
        if room.meetings > 0 { line += "; includes \(room.meetings) meetings" }
        if room.total.unreadable > 0 { line += "; \(room.total.unreadable) entries unreadable (sum may be low)" }
        return line
    }
}

// chat_storage: the AI answering a chat can tell how much disk that chat (or, with scope "all", the chats it
// may read, as search_chats) takes. Sizes and titles only; no paths of other chats.
final class StorageLink: ToolProvider {
    static let shared = StorageLink()
    static let listLimit = 20
    var active: Bool { true }
    func tools() -> [[String: Any]] { [] }
    func tools(context: ToolContext) -> [[String: Any]] {
        guard context.asker != nil else { return [] }
        return [["name": "chat_storage",
                 "description": "How much disk this chat's data takes in the app (messages, chat folder, dropped files, pictures, backups before AI writes, CLI sessions), measured now. scope \"all\": the largest of the chats you may read, too. Linked project folders are not counted.",
                 "inputSchema": ["type": "object", "properties": ["scope": ["type": "string", "enum": ["this", "all"]]], "additionalProperties": false]]]
    }
    func call(_ name: String, _ arguments: [String: Any], context: ToolContext) -> [String: Any] {
        guard name == "chat_storage" else { return ToolHub.failure("Unknown tool: " + name) }
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
            lines.append("Total of these: \(ChatStorage.format(report.total.allocated)). The user sees every chat in Settings > Storage.")
        }
        return ["content": [["type": "text", "text": lines.joined(separator: "\n")]], "isError": false]
    }
}
