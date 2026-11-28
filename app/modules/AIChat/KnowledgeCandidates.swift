import Foundation
import Darwin
import AIAccounts
import AILocalization
import AIProjects

struct KnowledgeCandidate: Codable, Identifiable, Equatable {
    enum Kind: String, Codable { case skill, memory }
    // waiting: the review decided a change the user must approve (a locked skill or a fact the user made).
    enum State: String, Codable { case pending, applied, dropped, waiting }

    var id = UUID()
    let kind: Kind
    let content: [String: String]
    let evidence: String
    let accountID: String
    let accountName: String
    let chatID: UUID
    let turnID: UUID
    let todoID: UUID?
    var createdAt = Date()
    var state: State = .pending
    var origin: String?   // nil: proposed in a chat on this Mac; else the Mac it came from or "sync" (a conflict, 연동 2/3)
}

// The main thread serializes tool calls and chat actions. The files are the record for quotas, including after a
// restart or when a chat has moved to another project. Only the receipt index is kept for rendering the chat.
final class KnowledgeCandidates: ObservableObject {
    static let shared = KnowledgeCandidates()
    static let fileName = "knowledge-candidates.jsonl"

    @Published private var revision = 0
    private struct Receipt {
        let chat: UUID
        let candidate: UUID
        let file: URL
    }
    private var receipts: [UUID: Receipt]?
    private let root: URL?   // tests: another Mac's support folder

    init(root: URL? = nil) { self.root = root }

    private static var support: URL { URL(fileURLWithPath: AccountStore.supportDir, isDirectory: true) }
    private var support: URL { root ?? Self.support }
    var globalFile: URL { root?.appendingPathComponent(Self.fileName) ?? Self.file(nil) }
    static func file(_ project: String?) -> URL {
        let folder = project.map { ProjectSkillStore.folder($0).deletingLastPathComponent() } ?? support
        return folder.appendingPathComponent(fileName)
    }

    func submit(_ candidate: KnowledgeCandidate, project: String?) -> String? {
        do {
            let files = try readAll()
            let existing = files.values.joined()
            if existing.contains(where: { $0.turnID == candidate.turnID }) {
                return L("한 답에는 후보를 한 개만 올릴 수 있어요.", "Only one candidate can be proposed per answer.")
            }
            if let todo = candidate.todoID, existing.contains(where: { $0.todoID == todo }) {
                return L("TODO 하나에는 후보를 한 개만 올릴 수 있어요.", "Only one candidate can be proposed per TODO.")
            }
            let file = project.map { Self.file($0) } ?? globalFile
            // A directory listing can return a different URL for the same file as the project store.
            try write(try read(file) + [candidate], to: file)
            var updated = receiptIndex(files)
            updated[candidate.turnID] = Receipt(chat: candidate.chatID, candidate: candidate.id, file: file)
            receipts = updated
            revision += 1
            return nil
        } catch {
            return L("후보함에 저장하지 못했어요.", "Could not write to the candidate inbox.")
        }
    }

    func pending(chat: UUID, turn: UUID) -> UUID? {
        let _ = revision
        if receipts == nil {
            let files = (try? filesOnDisk()) ?? []
            receipts = receiptIndex(Dictionary(uniqueKeysWithValues: files.compactMap { file in
                (try? read(file)).map { (file, $0) }
            }))
        }
        guard let receipt = receipts?[turn], receipt.chat == chat else { return nil }
        return receipt.candidate
    }

    func drop(_ id: UUID, chat: UUID, turn: UUID) -> Bool {
        guard pending(chat: chat, turn: turn) == id, let file = receipts?[turn]?.file else { return false }
        do {
            var rows = try read(file)
            guard let index = rows.firstIndex(where: { $0.id == id && $0.chatID == chat && $0.turnID == turn && $0.state == .pending })
            else { return false }
            rows[index].state = .dropped
            try write(rows, to: file)
            receipts?.removeValue(forKey: turn)
            revision += 1
            return true
        } catch { return false }
    }

    // Every pending candidate with the inbox file it is in (the review's material).
    func pendingRows() throws -> [(file: URL, candidate: KnowledgeCandidate)] {
        try readAll().sorted { $0.key.path < $1.key.path }.flatMap { file, rows in
            rows.filter { $0.state == .pending }.map { (file, $0) }
        }
    }

    // A review's outcome: each listed candidate still in `from` (pending; waiting for the user's answer in the Inbox)
    // gets its new state. False when a file could not be written.
    func settle(_ states: [UUID: KnowledgeCandidate.State], from: KnowledgeCandidate.State = .pending) -> Bool {
        guard !states.isEmpty else { return true }
        do {
            var files = try readAll()
            for (file, rows) in files {
                var next = rows, touched = false
                for i in next.indices where next[i].state == from {
                    guard let state = states[next[i].id] else { continue }
                    next[i].state = state; touched = true
                }
                if touched { try write(next, to: file); files[file] = next }
            }
            receipts = receiptIndex(files)
            revision += 1
            return true
        } catch { return false }
    }

    // The global inbox as it is (KnowledgeSync shares it with the other Macs); nil when it cannot be read.
    func globalRows() -> [KnowledgeCandidate]? { try? read(globalFile) }

    // Rows from the other Macs' shared inboxes (연동 2/3): a row this Mac has takes the further state (pending, then
    // waiting, then applied or dropped), so the review Mac's outcome reaches the Mac that proposed it; a pending row it
    // does not have is added only when `adding` (the review Mac). False when the inbox could not be read or written.
    func merge(_ rows: [KnowledgeCandidate], adding: Bool) -> Bool {
        func rank(_ state: KnowledgeCandidate.State) -> Int { state == .pending ? 0 : state == .waiting ? 1 : 2 }
        do {
            var files = try readAll()
            let known = Set(files.values.joined().map(\.id))
            var global = files[globalFile] ?? [], touched = false
            for row in rows {
                if let i = global.firstIndex(where: { $0.id == row.id }) {
                    if rank(row.state) > rank(global[i].state) { global[i].state = row.state; touched = true }
                } else if adding, row.state == .pending, !known.contains(row.id), !global.contains(where: { $0.id == row.id }) {
                    global.append(row); touched = true
                }
            }
            guard touched else { return true }
            try write(global, to: globalFile)
            files[globalFile] = global
            receipts = receiptIndex(files)
            revision += 1
            return true
        } catch { return false }
    }

    private func receiptIndex(_ files: [URL: [KnowledgeCandidate]]) -> [UUID: Receipt] {
        var updated: [UUID: Receipt] = [:]
        for (file, rows) in files {
            for candidate in rows where candidate.state == .pending {
                updated[candidate.turnID] = Receipt(chat: candidate.chatID, candidate: candidate.id, file: file)
            }
        }
        return updated
    }

    private func filesOnDisk() throws -> [URL] {
        let projects = support.appendingPathComponent("projects", isDirectory: true)
        let fm = FileManager.default
        try checkLink(projects)
        let folders: [URL]
        do {
            folders = try fm.contentsOfDirectory(at: projects, includingPropertiesForKeys: nil)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            folders = []
        }
        // Match the existing project store's directory IDs. Other files under projects are unrelated.
        return [globalFile] + folders.filter {
            $0.lastPathComponent.range(of: "^[0-9a-f]{16}$", options: .regularExpression) != nil
        }.map { $0.appendingPathComponent(Self.fileName) }
    }

    private func readAll() throws -> [URL: [KnowledgeCandidate]] {
        try Dictionary(uniqueKeysWithValues: filesOnDisk().map { ($0, try read($0)) })
    }

    private func checkLink(_ url: URL) throws {
        if (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil {
            throw CocoaError(.fileReadNoPermission)
        }
    }

    private func read(_ file: URL) throws -> [KnowledgeCandidate] {
        try checkLink(file.deletingLastPathComponent())
        try checkLink(file)
        let data: Data
        do {
            data = try Data(contentsOf: file)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            return []
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try data.split(separator: 10).map { try decoder.decode(KnowledgeCandidate.self, from: Data($0)) }
    }

    private func write(_ rows: [KnowledgeCandidate], to file: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        var data = Data()
        for row in rows {
            data.append(try encoder.encode(row))
            data.append(10)
        }
        let folder = file.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        // Write privately in the same directory so the rename publishes a complete, owner-only file.
        var template = Array(folder.appendingPathComponent(".knowledge-candidates.XXXXXX").path.utf8CString)
        let descriptor = mkstemp(&template)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let temporaryPath = String(cString: template)
        defer { _ = unlink(temporaryPath) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        guard fchmod(descriptor, 0o600) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        try handle.write(contentsOf: data)
        try handle.close()
        guard rename(temporaryPath, file.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }
}
