import Foundation
import CryptoKit
import AIAccounts

// Project memory: notes every AI of one project shares (Claude, Codex, Gemini, the local model), unlike the app's
// memory of the user (AIChat Memory.swift). Kept per project (ProjectBinding.groupKey, so its worktrees share it) in
// <support>/projects/<id>/: memory-history.jsonl gets one line per change (the record; memory.json is a copy of
// the notes for people), so each can be undone later. An AI never edits a note in place: it adds one, or replaces one (the old note is
// archived and both keep the link). Archived notes stay searchable. The user (the project's info tab) may also edit, pin,
// archive and undo any change; only the user deletes for good, and a deleted text leaves a mark so no AI or meeting
// cleanup brings it back.
public struct ProjectMemoryNote: Codable, Identifiable, Equatable {
    public enum Kind: String, Codable, CaseIterable { case decision, progress, log }   // decision/fact, open progress, work log
    public enum State: String, Codable { case active, archived, deleted }   // deleted: its text is gone from every file
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
    public var commits: [String]?   // automatic log identity, kept after edits and deletion

    public init(kind: Kind, text: String, by: String? = nil, account: String? = nil, chat: UUID? = nil, message: UUID? = nil,
                verified: Bool = false, pinned: Bool = false, createdAt: Date = Date()) {
        self.kind = kind; self.text = text; self.by = by; self.account = account; self.chat = chat; self.message = message
        self.verified = verified; self.pinned = pinned; self.createdAt = createdAt
    }
}

// One line of memory-history.jsonl, one per change: the notes as they are after it. A replace is one line (the new
// note and the archived one), an undo of several changes too, so a crash never leaves half of it.
public struct ProjectMemoryChange: Codable, Equatable {
    public static let byUser = "user", byMeeting = "meeting"
    public var at: Date
    public var action: String       // "add", "replace"; the user's "edit", "pin", "unpin", "archive", "restore", "delete", "undo"
    public var note: ProjectMemoryNote
    public var old: UUID?           // replace: the note it archived
    public var archived: ProjectMemoryNote?   // replace: that note, archived
    public var by: String?          // who changed: an AI's name, byMeeting or byUser (nil in early lines: the note's AI)
    public var batch: UUID?         // one meeting cleanup, undone as a whole
    public var others: [ProjectMemoryNote]?   // undo, delete: the further notes it changed
    public var undoes: [Int]?       // undo: the lines (0 = first) it took back
    public var marks: [String]?     // delete: ProjectMemoryStore.mark of each deleted text

    public var who: String? { by ?? note.by }
    public var notes: [ProjectMemoryNote] { (archived.map { [$0] } ?? []) + (others ?? []) + [note] }
}

struct ProjectMemoryData: Codable {
    var project = ""                // the project key, for a person reading the folder
    var notes: [ProjectMemoryNote] = []
}

public final class ProjectMemoryStore: ObservableObject {
    public static let shared = ProjectMemoryStore()
    public static let textLimit = 500
    static let maxActive = 400

    @Published public private(set) var revision = 0   // bumped on every save, for the chat's "saved" lines and the info tab
    private let lock = NSLock()       // tool calls come from several threads and AIs: one change at a time
    private var cache: [String: ProjectMemoryData] = [:]
    private var lines: [String: [ProjectMemoryChange]] = [:]   // the history as read, same keys as cache

    // The folder name: the key is a path, so a short hash of it.
    static func id(_ project: String) -> String {
        SHA256.hash(data: Data(project.utf8)).map { String(format: "%02x", $0) }.joined().prefix(16).description
    }
    static func folder(_ project: String) -> URL {
        URL(fileURLWithPath: AccountStore.supportDir).appendingPathComponent("projects/" + id(project), isDirectory: true)
    }
    static func file(_ project: String) -> URL { folder(project).appendingPathComponent("memory.json") }
    static func historyFile(_ project: String) -> URL { folder(project).appendingPathComponent("memory-history.jsonl") }

    // What a deleted text leaves behind: a hash of it with case, runs of spaces and the closing punctuation aside, so
    // the same words saved again are recognized without keeping them. Signs and points inside stay ("+5 V" is not
    // "-5 V", "1.5 MHz" not "15 MHz").
    public static func mark(_ text: String) -> String {
        var kept = text.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
        while let last = kept.last, ".!?。！？…,;:".contains(last) || last == " " { kept.removeLast() }
        return SHA256.hash(data: Data(kept.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.sortedKeys]; return e
    }()
    private static let decoder: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }()

    // Every note of the project, archived ones too, oldest first (any thread). Deleted notes are not listed.
    public func notes(_ project: String) -> [ProjectMemoryNote] {
        lock.lock(); defer { lock.unlock() }
        return (load(project)?.notes ?? []).filter { $0.state != .deleted }
    }

    // Read again from disk on the next use (tests that clear the folder).
    func forget() { lock.lock(); cache = [:]; lines = [:]; lock.unlock() }

    // Every change, oldest first; a line's place in it is the number undo takes. Deleted texts are blanked in it.
    public func history(_ project: String) -> [ProjectMemoryChange] {
        lock.lock(); defer { lock.unlock() }
        if load(project) != nil { return lines[project] ?? [] }
        guard let text = try? String(contentsOf: Self.historyFile(project), encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { try? Self.decoder.decode(ProjectMemoryChange.self, from: Data($0.utf8)) }
    }

    public enum Outcome: Equatable { case saved(ProjectMemoryNote), duplicate(ProjectMemoryNote), refused(String) }

    static let deletedRefusal = "The user deleted this note for good; it is not saved again."

    // `by`: who adds when it is not the note's AI (a meeting); `batch`: one cleanup, undone as a whole.
    public func add(_ note: ProjectMemoryNote, project: String, by: String? = nil, batch: UUID? = nil) -> Outcome {
        var note = note
        if let why = Self.clean(&note) { return .refused(why) }
        return change(project) { data, history in
            if Self.deleted(history).contains(Self.mark(note.text)) { return Edit(.refused(Self.deletedRefusal)) }
            if let same = data.notes.first(where: { $0.state == .active && $0.kind == note.kind && $0.text.lowercased() == note.text.lowercased() }) {
                return Edit(.duplicate(same))
            }
            guard data.notes.filter({ $0.state == .active && !($0.kind == .log && $0.commits != nil) }).count < Self.maxActive else {
                return Edit(.refused("Project memory is full (\(Self.maxActive) active notes): replace outdated notes instead of adding."))
            }
            note.state = .active; note.replaces = nil; note.replacedBy = nil; note.archivedAt = nil
            data.notes.append(note)
            return Edit(.saved(note), [ProjectMemoryChange(at: note.createdAt, action: "add", note: note, by: by, batch: batch)])
        }
    }

    // The app records committed work without an AI call. The history keeps hashes even after deletion.
    func recordWork(_ commits: [(hash: String, title: String)], project: String, by: String, chat: UUID,
                    now: Date = Date()) -> Outcome? {
        guard !commits.isEmpty else { return nil }
        return change(project) { data, history in
            let seen = Set(history.flatMap { $0.notes.flatMap { $0.commits ?? [] } })
            var fresh = Set<String>()
            let pending = commits.filter { !seen.contains($0.hash) && fresh.insert($0.hash).inserted }
            guard !pending.isEmpty else {
                let existing = history.flatMap(\.notes).first { !Set($0.commits ?? []).isDisjoint(with: Set(commits.map(\.hash))) }
                return Edit(existing.map { .duplicate($0) } ?? .refused("Work already recorded."))
            }
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = .current
            formatter.dateFormat = "yyyy-MM-dd"
            let date = formatter.string(from: now)
            let titles = pending.map { $0.title.split(whereSeparator: \.isWhitespace).joined(separator: " ") + " [" + $0.hash.prefix(10) + "]" }.joined(separator: "; ")
            let prefix = date + " · " + String(by.prefix(80)) + " · "
            let suffix = " · chat:" + chat.uuidString
            let room = max(0, Self.textLimit - prefix.count - suffix.count)
            let summary = titles.count > room ? String(titles.prefix(max(0, room - 1))) + "…" : titles
            var note = ProjectMemoryNote(kind: .log, text: prefix + summary + suffix,
                                         by: by, chat: chat, verified: true, createdAt: now)
            note.commits = pending.map(\.hash)
            // Logs accumulate until the cleanup meeting; the manual active-note cap must not drop them.
            data.notes.append(note)
            return Edit(.saved(note), [ProjectMemoryChange(at: now, action: "add", note: note)])
        }
    }

    // `old` goes to the archive and `note` takes its place (pinned stays pinned).
    public func replace(_ old: UUID, with note: ProjectMemoryNote, project: String, by: String? = nil, batch: UUID? = nil) -> Outcome {
        var note = note
        if let why = Self.clean(&note) { return .refused(why) }
        return change(project) { data, history in
            guard let i = data.notes.firstIndex(where: { $0.id == old }), data.notes[i].state != .deleted else {
                return Edit(.refused("No project memory note has that id."))
            }
            guard data.notes[i].state == .active else {
                return Edit(.refused("That note is already archived" + (data.notes[i].replacedBy.map { " (replaced by \($0.uuidString))" } ?? "") + "."))
            }
            if Self.deleted(history).contains(Self.mark(note.text)) { return Edit(.refused(Self.deletedRefusal)) }
            note.state = .active; note.replaces = old; note.replacedBy = nil; note.archivedAt = nil
            note.pinned = note.pinned || data.notes[i].pinned
            data.notes[i].state = .archived; data.notes[i].replacedBy = note.id; data.notes[i].archivedAt = note.createdAt
            data.notes.append(note)
            return Edit(.saved(note), [ProjectMemoryChange(at: note.createdAt, action: "replace", note: note, old: old, archived: data.notes[i], by: by, batch: batch)])
        }
    }

    // MARK: The user's changes (the info tab)

    // The user corrects a note in place: text, kind, checked or not.
    public func edit(_ id: UUID, text: String, kind: ProjectMemoryNote.Kind, verified: Bool, project: String) -> Outcome {
        userChange(id, project: project, action: "edit", from: [.active, .archived]) { note in
            var next = note
            next.text = text; next.kind = kind; next.verified = verified
            if let why = Self.clean(&next) { return why }
            note = next
            return nil
        }
    }

    public func setPinned(_ id: UUID, _ pinned: Bool, project: String) -> Outcome {
        userChange(id, project: project, action: pinned ? "pin" : "unpin", from: [.active, .archived]) { $0.pinned = pinned; return nil }
    }

    public func archive(_ id: UUID, project: String) -> Outcome {
        userChange(id, project: project, action: "archive", from: [.active]) { $0.state = .archived; $0.archivedAt = Date(); return nil }
    }

    // Back from the archive (a replaced note keeps its link to the one that replaced it).
    public func restore(_ id: UUID, project: String) -> Outcome {
        userChange(id, project: project, action: "restore", from: [.archived]) { $0.state = .active; $0.archivedAt = nil; return nil }
    }

    private func userChange(_ id: UUID, project: String, action: String, from: Set<ProjectMemoryNote.State>,
                            _ apply: @escaping (inout ProjectMemoryNote) -> String?) -> Outcome {
        change(project) { data, _ in
            guard let i = data.notes.firstIndex(where: { $0.id == id }), data.notes[i].state != .deleted else {
                return Edit(.refused("No project memory note has that id."))
            }
            guard from.contains(data.notes[i].state) else { return Edit(.refused("That note cannot be changed this way now.")) }
            var note = data.notes[i]
            if let why = apply(&note) { return Edit(.refused(why)) }
            guard note != data.notes[i] else { return Edit(.saved(note)) }
            data.notes[i] = note
            return Edit(.saved(note), [ProjectMemoryChange(at: Date(), action: action, note: note, by: ProjectMemoryChange.byUser)])
        }
    }

    // Deletes a note for good, only ever by the user: every version of it and every note with the same text, in
    // memory.json and in the history (rewritten with those texts blanked), leaving only the marks of the texts, which
    // refuse the same words when an AI or a meeting adds them again.
    public func delete(_ id: UUID, project: String) -> Outcome {
        change(project) { data, history in
            guard let target = data.notes.first(where: { $0.id == id }), target.state != .deleted else {
                return Edit(.refused("No project memory note has that id."))
            }
            let marks = Set(history.flatMap(\.notes).filter { $0.id == id && $0.state != .deleted }.map { Self.mark($0.text) } + [Self.mark(target.text)])
            func gone(_ n: ProjectMemoryNote) -> Bool { n.id == id || (n.state != .deleted && marks.contains(Self.mark(n.text))) }
            func blank(_ n: ProjectMemoryNote) -> ProjectMemoryNote {
                guard gone(n) else { return n }
                var n = n; n.text = ""; n.state = .deleted; return n
            }
            let earlier = history.map { line -> ProjectMemoryChange in
                var line = line
                line.note = blank(line.note); line.archived = line.archived.map(blank); line.others = line.others?.map(blank)
                return line
            }
            let removed = data.notes.filter { $0.state != .deleted && gone($0) }.map(blank)
            for n in removed { if let i = data.notes.firstIndex(where: { $0.id == n.id }) { data.notes[i] = n } }
            let note = removed.first { $0.id == id } ?? blank(target)
            return Edit(.saved(note), [ProjectMemoryChange(at: Date(), action: "delete", note: note, by: ProjectMemoryChange.byUser,
                                                           others: removed.filter { $0.id != id }, marks: marks.sorted())], earlier: earlier)
        }
    }

    // Takes back history lines (their numbers in `history`): each note they changed goes back to how it was before
    // the first of them; a note they added goes to the archive. Refused when one of those notes was changed since
    // (undo that first; a change and its undo cancel out), when a line was already undone, is a delete, or would bring
    // back a deleted text.
    public func undo(_ numbers: [Int], project: String) -> Outcome {
        change(project) { data, history in
            let picked = Set(numbers)
            guard !picked.isEmpty, picked.allSatisfy({ $0 >= 0 && $0 < history.count }) else { return Edit(.refused("No such change.")) }
            if picked.contains(where: { history[$0].action == "delete" }) { return Edit(.refused("A delete for good cannot be undone.")) }
            if !picked.isDisjoint(with: Self.undone(history)) { return Edit(.refused("That change was already undone.")) }
            // Each note as these lines left it must still be as it is now, else a later change counts (undo that first).
            var left: [UUID: ProjectMemoryNote] = [:]
            for i in picked.sorted() { for n in history[i].notes { left[n.id] = n } }
            let touched = Set(left.keys)
            if touched.contains(where: { id in data.notes.first { $0.id == id } != left[id] }) {
                return Edit(.refused("A later change touched the same note: undo that one first."))
            }
            // Each note goes back to before the first picked line that touched it, so a change by someone else before
            // that stays; one between two picked lines on the same note refuses (it would be lost).
            var before: [UUID: ProjectMemoryNote] = [:]
            for id in touched {
                let on = history.indices.filter { history[$0].notes.contains { $0.id == id } }
                let mine = on.filter(picked.contains)
                guard let start = mine.first, let end = mine.last else { continue }
                if on.contains(where: { $0 > start && $0 < end && !picked.contains($0) }) {
                    return Edit(.refused("A later change touched the same note: undo that one first."))
                }
                if let n = Self.replay(Array(history[..<start])).first(where: { $0.id == id }) { before[id] = n }
            }
            let now = Date(), marks = Self.deleted(history)
            var restored: [ProjectMemoryNote] = []
            for id in touched.sorted(by: { $0.uuidString < $1.uuidString }) {
                guard let current = data.notes.first(where: { $0.id == id }) else { continue }
                var back = before[id] ?? current
                if before[id] == nil { back.state = .archived; back.archivedAt = now; back.replacedBy = nil }
                guard back.state != .deleted, current.state != .deleted, back.state != .active || !marks.contains(Self.mark(back.text)) else {
                    return Edit(.refused(Self.deletedRefusal))
                }
                if back != current { restored.append(back) }
            }
            guard let note = restored.first else { return Edit(.refused("Nothing to undo: the notes are already as they were.")) }
            for n in restored { if let i = data.notes.firstIndex(where: { $0.id == n.id }) { data.notes[i] = n } }
            return Edit(.saved(note), [ProjectMemoryChange(at: now, action: "undo", note: note, by: ProjectMemoryChange.byUser,
                                                           others: Array(restored.dropFirst()), undoes: picked.sorted())])
        }
    }

    // A whole meeting cleanup.
    public func undo(batch: UUID, project: String) -> Outcome {
        let all = history(project)
        return undo(all.indices.filter { all[$0].batch == batch }, project: project)
    }

    // The lines taken back by an undo that is itself still in effect (newest first: an undo only names earlier lines).
    public static func undone(_ history: [ProjectMemoryChange]) -> Set<Int> {
        var undone = Set<Int>()
        for i in history.indices.reversed() where !undone.contains(i) { undone.formUnion(history[i].undoes ?? []) }
        return undone
    }

    // One line, trimmed, within the limit; nil when it may be saved.
    private static func clean(_ note: inout ProjectMemoryNote) -> String? {
        note.text = note.text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        if note.text.isEmpty { return "Write the note in one line." }
        if note.text.count > textLimit { return "Too long: keep a note to one line (at most \(textLimit) characters)." }
        return nil
    }

    static func deleted(_ history: [ProjectMemoryChange]) -> Set<String> { Set(history.flatMap { $0.marks ?? [] }) }

    // The notes after these lines: each line holds its notes as they are after it.
    static func replay(_ history: [ProjectMemoryChange]) -> [ProjectMemoryNote] {
        var notes: [ProjectMemoryNote] = [], index: [UUID: Int] = [:]
        for change in history {
            for note in change.notes {
                if let i = index[note.id] { notes[i] = note } else { index[note.id] = notes.count; notes.append(note) }
            }
        }
        return notes
    }

    // The history is the record: the notes are its lines replayed, so a change is real once its line is written and
    // memory.json is only a copy for people. A line cut off by a crash at the end was never applied and is skipped;
    // anything else unreadable gives nil, and nothing is saved over it (a damaged file never turns into an empty memory).
    private func load(_ project: String) -> ProjectMemoryData? {
        if let data = cache[project] { return data }
        let fm = FileManager.default, history = Self.historyFile(project), file = Self.file(project)
        var data = ProjectMemoryData(project: project), read: [ProjectMemoryChange] = []
        if fm.fileExists(atPath: history.path) {
            guard let text = try? String(contentsOf: history, encoding: .utf8) else { return nil }
            var rows = text.components(separatedBy: "\n")
            rows.removeLast()   // "" after the last newline, else a line cut off before its newline (append drops it)
            for row in rows where !row.isEmpty {
                guard let change = try? Self.decoder.decode(ProjectMemoryChange.self, from: Data(row.utf8)) else { return nil }
                read.append(change)
            }
            data.notes = Self.replay(read)
        } else if fm.fileExists(atPath: file.path) {
            guard let saved = (try? Data(contentsOf: file)).flatMap({ try? Self.decoder.decode(ProjectMemoryData.self, from: $0) }) else { return nil }
            data = saved
        }
        cache[project] = data
        lines[project] = read
        return data
    }

    // What a change does: its outcome, the lines it appends, and for a delete the earlier lines rewritten.
    private struct Edit {
        var outcome: Outcome, lines: [ProjectMemoryChange] = [], earlier: [ProjectMemoryChange]? = nil
        init(_ outcome: Outcome, _ lines: [ProjectMemoryChange] = [], earlier: [ProjectMemoryChange]? = nil) {
            self.outcome = outcome; self.lines = lines; self.earlier = earlier
        }
    }

    // Writes the history lines first (that is the change), then the copy in memory.json.
    private func change(_ project: String, _ edit: (inout ProjectMemoryData, [ProjectMemoryChange]) -> Edit) -> Outcome {
        lock.lock()
        guard var next = load(project) else {
            lock.unlock(); return .refused("Project memory on this Mac could not be read, so nothing was saved over it. Ask the user to check it.")
        }
        next.project = project
        let done = edit(&next, lines[project] ?? [])
        guard !done.lines.isEmpty else { lock.unlock(); return done.outcome }
        var history = done.earlier ?? lines[project] ?? []
        do {
            try FileManager.default.createDirectory(at: Self.folder(project), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let rows = try done.lines.map { try Self.encoder.encode($0) }
            if let earlier = done.earlier {
                let all = try (earlier.map { try Self.encoder.encode($0) } + rows).reduce(into: Data()) { $0.append($1); $0.append(0x0A) }
                try Self.write(all, to: Self.historyFile(project))
            } else {
                try Self.append(rows, to: Self.historyFile(project))
            }
        } catch { lock.unlock(); return .refused("Project memory could not be saved on this Mac.") }
        history += done.lines
        var copy = next; copy.notes = next.notes.filter { $0.state != .deleted }
        var outcome = done.outcome
        if (try? Self.write(Self.encoder.encode(copy), to: Self.file(project))) == nil, done.earlier != nil {
            // A delete must not leave the text in the copy: without a fresh copy, none (the history rebuilds it).
            if FileManager.default.fileExists(atPath: Self.file(project).path), (try? FileManager.default.removeItem(at: Self.file(project))) == nil {
                outcome = .refused(Self.staleCopy)
            }
        }
        cache[project] = next
        lines[project] = history
        lock.unlock()
        let bump = { self.revision += 1 }
        if Thread.isMainThread { bump() } else { DispatchQueue.main.async(execute: bump) }
        return outcome
    }

    static let staleCopy = "Deleted from the history, but the copy memory.json could not be cleaned: it is written again with the next change."

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
        let handle = try FileHandle(forUpdating: file)
        defer { try? handle.close() }
        // A line cut off by a crash (no newline after it) was never part of the record: write over it.
        let end = try handle.seekToEnd()
        if end > 0 {
            let back = min(end, 64 * 1024)
            try handle.seek(toOffset: end - back)
            let tail = try handle.readToEnd() ?? Data()
            if tail.last != 0x0A {
                let keep = tail.lastIndex(of: 0x0A).map { end - back + UInt64($0 - tail.startIndex) + 1 } ?? (back == end ? 0 : end)
                try handle.truncate(atOffset: keep)
            }
            try handle.seek(toOffset: try handle.seekToEnd())
        }
        try handle.write(contentsOf: lines.reduce(into: Data()) { $0.append($1); $0.append(0x0A) })
    }
}
