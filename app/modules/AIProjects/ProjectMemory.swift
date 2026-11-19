import Foundation
import CryptoKit
import AIAccounts

// Project memory: notes every AI of one project shares (Claude, Codex, Gemini, the local model), unlike the app's
// memory of the user (AIChat Memory.swift). Kept per project (ProjectBinding.groupKey, so its worktrees share it) in
// <support>/projects/<id>/memory.json; every change also appends one line per changed note to memory-history.jsonl,
// so each can be undone later. An AI never edits a note in place: it adds one, or replaces one (the old note is
// archived and both keep the link). Archived notes stay searchable; only the user deletes.
public struct ProjectMemoryNote: Codable, Identifiable, Equatable {
    public enum Kind: String, Codable, CaseIterable { case decision, progress, log }   // decision/fact, open progress, work log
    public enum State: String, Codable { case active, archived }
    public var id = UUID()
    public var kind: Kind
    public var text: String
    public var by: String?          // the AI that wrote it
    public var account: String?     // its account id
    public var createdAt = Date()
    public var chat: UUID?          // where it was written
    public var message: UUID?
    public var verified = false     // checked (code, test, commit), else a guess
    public var pinned = false
    public var replaces: UUID?      // the note this one took the place of
    public var replacedBy: UUID?
    public var state = State.active
    public var archivedAt: Date?

    public init(kind: Kind, text: String, by: String? = nil, account: String? = nil, chat: UUID? = nil, message: UUID? = nil,
                verified: Bool = false, pinned: Bool = false, createdAt: Date = Date()) {
        self.kind = kind; self.text = text; self.by = by; self.account = account; self.chat = chat; self.message = message
        self.verified = verified; self.pinned = pinned; self.createdAt = createdAt
    }
}

// One line of memory-history.jsonl: a note as it is after the change.
public struct ProjectMemoryChange: Codable, Equatable {
    public var at: Date
    public var action: String       // "add", "replace" (note is the new one, old the archived), "archive"
    public var note: ProjectMemoryNote
    public var old: UUID?
}

struct ProjectMemoryData: Codable {
    var project = ""                // the project key, for a person reading the folder
    var notes: [ProjectMemoryNote] = []
}

public final class ProjectMemoryStore: ObservableObject {
    public static let shared = ProjectMemoryStore()
    public static let textLimit = 500
    static let maxActive = 400

    @Published public private(set) var revision = 0   // bumped on every save, for the chat's "saved" lines
    private let lock = NSLock()       // tool calls come from several threads and AIs: one change at a time
    private var cache: [String: ProjectMemoryData] = [:]

    // The folder name: the key is a path, so a short hash of it.
    static func id(_ project: String) -> String {
        SHA256.hash(data: Data(project.utf8)).map { String(format: "%02x", $0) }.joined().prefix(16).description
    }
    static func folder(_ project: String) -> URL {
        URL(fileURLWithPath: AccountStore.supportDir).appendingPathComponent("projects/" + id(project), isDirectory: true)
    }
    static func file(_ project: String) -> URL { folder(project).appendingPathComponent("memory.json") }
    static func historyFile(_ project: String) -> URL { folder(project).appendingPathComponent("memory-history.jsonl") }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.sortedKeys]; return e
    }()
    private static let decoder: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }()

    // Every note of the project, archived ones too, oldest first (any thread).
    public func notes(_ project: String) -> [ProjectMemoryNote] {
        lock.lock(); defer { lock.unlock() }
        return load(project).notes
    }

    // Read again from disk on the next use (tests that clear the folder).
    func forget() { lock.lock(); cache = [:]; lock.unlock() }

    // Every change, oldest first.
    public func history(_ project: String) -> [ProjectMemoryChange] {
        guard let text = try? String(contentsOf: Self.historyFile(project), encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { try? Self.decoder.decode(ProjectMemoryChange.self, from: Data($0.utf8)) }
    }

    public enum Outcome: Equatable { case saved(ProjectMemoryNote), duplicate(ProjectMemoryNote), refused(String) }

    public func add(_ note: ProjectMemoryNote, project: String) -> Outcome {
        var note = note
        if let why = Self.clean(&note) { return .refused(why) }
        return change(project) { data in
            if let same = data.notes.first(where: { $0.state == .active && $0.kind == note.kind && $0.text.lowercased() == note.text.lowercased() }) {
                return (.duplicate(same), [])
            }
            guard data.notes.filter({ $0.state == .active }).count < Self.maxActive else {
                return (.refused("Project memory is full (\(Self.maxActive) active notes): replace outdated notes instead of adding."), [])
            }
            note.state = .active; note.replaces = nil; note.replacedBy = nil; note.archivedAt = nil
            data.notes.append(note)
            return (.saved(note), [ProjectMemoryChange(at: note.createdAt, action: "add", note: note)])
        }
    }

    // `old` goes to the archive and `note` takes its place (pinned stays pinned).
    public func replace(_ old: UUID, with note: ProjectMemoryNote, project: String) -> Outcome {
        var note = note
        if let why = Self.clean(&note) { return .refused(why) }
        return change(project) { data in
            guard let i = data.notes.firstIndex(where: { $0.id == old }) else { return (.refused("No project memory note has that id."), []) }
            guard data.notes[i].state == .active else {
                return (.refused("That note is already archived" + (data.notes[i].replacedBy.map { " (replaced by \($0.uuidString))" } ?? "") + "."), [])
            }
            note.state = .active; note.replaces = old; note.replacedBy = nil; note.archivedAt = nil
            note.pinned = note.pinned || data.notes[i].pinned
            data.notes[i].state = .archived; data.notes[i].replacedBy = note.id; data.notes[i].archivedAt = note.createdAt
            data.notes.append(note)
            return (.saved(note), [ProjectMemoryChange(at: note.createdAt, action: "archive", note: data.notes[i], old: nil),
                                   ProjectMemoryChange(at: note.createdAt, action: "replace", note: note, old: old)])
        }
    }

    // One line, trimmed, within the limit; nil when it may be saved.
    private static func clean(_ note: inout ProjectMemoryNote) -> String? {
        note.text = note.text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        if note.text.isEmpty { return "Write the note in one line." }
        if note.text.count > textLimit { return "Too long: keep a note to one line (at most \(textLimit) characters)." }
        return nil
    }

    private func load(_ project: String) -> ProjectMemoryData {
        if let data = cache[project] { return data }
        let data = (try? Data(contentsOf: Self.file(project))).flatMap { try? Self.decoder.decode(ProjectMemoryData.self, from: $0) }
            ?? ProjectMemoryData(project: project)
        cache[project] = data
        return data
    }

    // Saves the notes, then the history lines; when the history cannot be written the notes go back as they were,
    // so no change is left out of the history.
    private func change(_ project: String, _ edit: (inout ProjectMemoryData) -> (Outcome, [ProjectMemoryChange])) -> Outcome {
        lock.lock()
        let before = load(project)
        var next = before
        next.project = project
        let (outcome, lines) = edit(&next)
        guard !lines.isEmpty else { lock.unlock(); return outcome }
        let failed = Outcome.refused("Project memory could not be saved on this Mac.")
        let folder = Self.folder(project), file = Self.file(project)
        let previous = try? Data(contentsOf: file)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try Self.write(Self.encoder.encode(next), to: file)
        } catch { lock.unlock(); return failed }
        do {
            try Self.append(lines.map { try Self.encoder.encode($0) }, to: Self.historyFile(project))
        } catch {
            if let previous { try? Self.write(previous, to: file) } else { try? FileManager.default.removeItem(at: file) }
            lock.unlock(); return failed
        }
        cache[project] = next
        lock.unlock()
        let bump = { self.revision += 1 }
        if Thread.isMainThread { bump() } else { DispatchQueue.main.async(execute: bump) }
        return outcome
    }

    private static func write(_ data: Data, to file: URL) throws {
        try data.write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    private static func append(_ lines: [Data], to file: URL) throws {
        if !FileManager.default.fileExists(atPath: file.path) {
            guard FileManager.default.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: lines.reduce(into: Data()) { $0.append($1); $0.append(0x0A) })
    }
}
