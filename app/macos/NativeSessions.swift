import Foundation

// Session ownership and provider history are distinct from the app's canonical chat.
// Only app-owned account directories qualify; personal default histories stay untouched.
final class NativeSessionCall {
    let id: String
    let resume: Bool
    let directory: URL
    var nativeID: String?
    var compacted = false
    var completed = false
    init(id: String, resume: Bool, directory: URL) {
        self.id = id; self.resume = resume; self.directory = directory
    }
    func observe(_ output: String) {
        for line in output.split(separator: "\n") {
            guard let data = line.data(using: .utf8),
                  let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            let type = event["type"] as? String ?? ""
            let subtype = event["subtype"] as? String ?? ""
            if type.contains("compact") || subtype.contains("compact") { compacted = true }
            if type == "thread.started" { nativeID = event["thread_id"] as? String }
            if type == "result" {
                nativeID = event["session_id"] as? String
                completed = event["is_error"] as? Bool != true
            }
            if type == "turn.completed" { completed = true }
            if type == "turn.failed" || type == "error" { completed = false }
        }
    }
}

final class NativeSessions {
    struct Record: Codable {
        var id = UUID()
        var accountID: String
        var provider: Account.Provider
        var role: String
        var nativeID: String?
        var context = ""
        var ownBlock = ""
        var images: [String] = []
        var valid = true
    }
    private let lock = NSLock()
    static func directory(_ room: UUID) -> URL {
        URL(fileURLWithPath: AccountStore.home).appendingPathComponent(".ai-illuminati/rooms/\(room.uuidString)")
    }
    static func eligible(_ account: Account) -> Bool {
        guard account.provider != .gemini, let path = account.dir else { return false }
        let root = URL(fileURLWithPath: AccountStore.accountsDir).resolvingSymlinksInPath().path + "/"
        return URL(fileURLWithPath: path).resolvingSymlinksInPath().path.hasPrefix(root)
    }
    private func load(_ room: UUID) -> [Record] {
        guard let data = try? Data(contentsOf: Self.directory(room).appendingPathComponent("ownership.json")) else { return [] }
        return (try? JSONDecoder().decode([Record].self, from: data)) ?? []
    }
    private func save(_ records: [Record], _ room: UUID) throws {
        let dir = Self.directory(room)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let file = dir.appendingPathComponent("ownership.json")
        try JSONEncoder().encode(records).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
    func pinnedAccount(_ provider: Account.Provider, room: UUID) -> String? {
        lock.lock(); defer { lock.unlock() }
        return load(room).last { $0.provider == provider && $0.role == "speaker" && $0.valid }?.accountID
    }
    func reset(_ room: UUID) throws {
        lock.lock(); defer { lock.unlock() }
        var records = load(room)
        for i in records.indices { records[i].valid = false }
        try save(records, room)
    }
    // Deleting a chat removes what its sessions left behind: the room's session folders and, in each
    // app-owned account folder, only the transcript files whose names carry a session ID this room
    // recorded (Claude: projects/*/<id>.jsonl and its <id>/ folder; Codex: sessions/**/*<id>*).
    // Account folders, logins, shared indexes and other sessions are never touched.
    static func purgeRoom(_ room: UUID, accounts: [Account]) throws {
        let fm = FileManager.default
        let base = directory(room).deletingLastPathComponent()
        var folders = [directory(room)]
        let archive = base.appendingPathComponent("archived")
        if let old = try? fm.contentsOfDirectory(atPath: archive.path) {
            folders += old.filter { $0.hasPrefix(room.uuidString) }.map { archive.appendingPathComponent($0) }
        }
        for folder in folders where fm.fileExists(atPath: folder.path) {
            let data = try? Data(contentsOf: folder.appendingPathComponent("ownership.json"))
            let records = data.flatMap { try? JSONDecoder().decode([Record].self, from: $0) } ?? []
            for record in records {
                guard let id = record.nativeID, id.count >= 16, !id.contains("/"),
                      let account = accounts.first(where: { $0.id == record.accountID }), eligible(account),
                      let dir = account.dir else { continue }
                let roots = record.provider == .claude ? ["projects"] : ["sessions", "archived_sessions"]
                for name in roots {
                    let root = URL(fileURLWithPath: dir).appendingPathComponent(name)
                    guard let walker = fm.enumerator(at: root, includingPropertiesForKeys: nil) else { continue }
                    var matches: [URL] = []
                    for case let url as URL in walker {
                        let file = url.lastPathComponent
                        if file == id || file == id + ".jsonl" || (record.provider == .codex && file.contains(id)) {
                            matches.append(url)
                            walker.skipDescendants()
                        }
                    }
                    for url in matches { try fm.removeItem(at: url) }
                }
                // Claude names a project folder after the session's working folder, which is inside this room.
                if record.provider == .claude {
                    let projects = URL(fileURLWithPath: dir).appendingPathComponent("projects")
                    for name in (try? fm.contentsOfDirectory(atPath: projects.path)) ?? [] where name.contains(room.uuidString) {
                        let url = projects.appendingPathComponent(name)
                        if (try? fm.contentsOfDirectory(atPath: url.path))?.isEmpty == true { try fm.removeItem(at: url) }
                    }
                }
            }
            try fm.removeItem(at: folder)
        }
    }

    static func archiveRoom(_ room: UUID) throws {
        let dir = directory(room)
        guard FileManager.default.fileExists(atPath: dir.path) else { return }
        // Preserve the exact ownership ledger for provider-native cleanup/recovery. Do not
        // remove shared provider indexes or unrelated native sessions from a UI callback.
        let archive = dir.deletingLastPathComponent().appendingPathComponent("archived")
        try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.moveItem(at: dir, to: archive.appendingPathComponent(room.uuidString + "-" + UUID().uuidString))
    }

    // The context prefix is canonical app history. Role instructions are always resent.
    // Reordered/edited history cannot be delta-delivered safely and starts a new session.
    static func split(_ prompt: String) -> (String, String, String)? {
        let markers = [("[MODE3 SPEECH]", "speaker"), ("[MODE3 MODERATION]", "moderator"), ("[MODE3 FINAL]", "moderator")]
        let found = markers.compactMap { marker, role -> (Range<String.Index>, String)? in
            prompt.range(of: marker, options: .backwards).map { ($0, role) }
        }.max { $0.0.lowerBound < $1.0.lowerBound }
        guard let (range, role) = found else { return nil }
        return (String(prompt[..<range.lowerBound]).trimmingCharacters(in: .newlines), String(prompt[range.lowerBound...]), role)
    }

    func ask(_ account: Account, room: UUID, prompt: String, images: [URL], timeout: TimeInterval,
             token: DebateCancellation, web: Bool, speaker: String, appendContext: Bool = false,
             invoke: (String, [URL], NativeSessionCall?) -> Result<String, Answerer.Failure>,
             note: (String) -> Void) -> Result<String, Answerer.Failure> {
        guard Self.eligible(account), let (incomingContext, instruction, role) = Self.split(prompt) else {
            note(L("\(account.provider.title): 전체 자료 전달 (전용 계정 세션 미지원)", "\(account.provider.title): full context (dedicated session unavailable)"))
            return invoke(prompt, images, nil)
        }
        lock.lock()
        var records = load(room)
        let index = records.lastIndex { $0.accountID == account.id && $0.role == role && $0.valid }
        var record = index.map { records[$0] } ?? Record(accountID: account.id, provider: account.provider, role: role)
        var context = incomingContext
        if appendContext, record.nativeID != nil {
            context = record.context + "\n\n[Next task context]\n" + incomingContext
        }
        if !context.hasPrefix(record.context) {
            if let index { records[index].valid = false }
            record = Record(accountID: account.id, provider: account.provider, role: role)
        }
        let resumed = record.nativeID != nil
        var delta = appendContext && resumed ? incomingContext : (resumed ? String(context.dropFirst(record.context.count)) : context)
        if !appendContext, resumed, !record.ownBlock.isEmpty, let range = delta.range(of: record.ownBlock) { delta.removeSubrange(range) }
        let newImages = resumed ? images.filter { !record.images.contains($0.path) } : images
        let directory = Self.directory(room).appendingPathComponent(record.id.uuidString)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            // Pre-register ownership even if the process fails or is interrupted.
            records.removeAll { $0.id == record.id }; records.append(record)
            try save(records, room)
        } catch {
            lock.unlock()
            note(L("세션 저장 실패: 전체 자료 전달", "Session storage failed: sending full context"))
            return invoke(prompt, images, nil)
        }
        lock.unlock()
        let call = NativeSessionCall(id: record.nativeID ?? record.id.uuidString, resume: resumed, directory: directory)
        let result = invoke(delta + "\n" + instruction, newImages, call)
        lock.lock()
        records = load(room)
        record.nativeID = call.nativeID ?? record.nativeID
        if case .success(let text) = result, call.completed, let sid = record.nativeID, UUID(uuidString: sid) != nil {
            record.context = context
            record.images = appendContext && resumed ? Array(Set(record.images + images.map(\.path))).sorted() : images.map(\.path)
            let body = ChatTurn.Entry.reply(round: 1, speaker: speaker, text: text).text
            record.ownBlock = role == "speaker" ? "[\(speaker)]\n" + body : ""
            record.valid = !call.compacted
        } else { record.valid = false }
        records.removeAll { $0.id == record.id }; records.append(record)
        do { try save(records, room) } catch { record.valid = false; try? resetWithoutLock(room) }
        lock.unlock()
        if case .failure = result {
            note(L("\(account.provider.title): 세션 호출 실패, 다음 질문에서 재구성", "\(account.provider.title): session failed; next question rebuilds context"))
        } else { note(call.compacted
             ? L("압축 감지: 다음 호출에서 원본 자료로 재구성", "Compaction detected: context will be rebuilt")
             : L("\(account.provider.title): \(resumed ? "세션 이어짐" : "새 세션")", "\(account.provider.title): \(resumed ? "session resumed" : "new session")")) }
        // Only an explicitly missing session may be retried, once, using stateless full context.
        // Never retry quota/auth/permissions, timeout, arbitrary failure, or user Stop.
        if case .failure(.failed(let message)) = result, !token.isCancelled, resumed,
           ["no conversation found", "session not found", "no session found"].contains(where: { message.lowercased().contains($0) }) {
            note(L("세션을 찾지 못해 전체 자료로 복구", "Session missing: restoring full context"))
            return invoke(prompt, images, nil)
        }
        return result
    }
    private func resetWithoutLock(_ room: UUID) throws {
        var records = load(room)
        for i in records.indices { records[i].valid = false }
        try save(records, room)
    }
}
