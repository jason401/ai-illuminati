import Foundation

// The meeting cleanup of project memory, the saving half (the meeting itself: AIChat). The meeting changes no file:
// it hands back a list of edits, and the app keeps only those that rest on evidence it actually sent (a chat id or a
// commit hash), that the meeting agreed on (the rest wait for the next cleanup), that touch notes still active and
// bring back no text the user deleted for good; at most `maxEdits` at once. Then the app's own rule folds old work
// logs into one line per week. Everything is one batch (the meeting id) in memory-history.jsonl, undone as a whole
// with ProjectMemoryStore.undo(batch:), and each cleanup is recorded in projects/<id>/memory-cleanups.json.
public struct ProjectMemoryEdit: Codable, Equatable {
    public enum Kind: String, Codable, CaseIterable {
        case merge      // several notes into one new note (`text`), the others archived
        case fix, shorten   // one note replaced by `text`
        case archive    // the notes in `ids` to the archive
        case add        // a new note (`text`, `noteKind`)
        case verify     // checked (`verified` true) or a guess again
        case resolve    // a contradiction: `keep` stays, the other notes in `ids` are archived
    }
    public var kind: Kind
    public var ids: [String]        // full ids or their first 8 characters, as the meeting saw them
    public var keep: String?
    public var text: String?
    public var noteKind: ProjectMemoryNote.Kind?
    public var verified: Bool?
    public var evidence: [String]   // chat ids or commit hashes from the meeting's material
    public var agreed: Bool

    public init(kind: Kind, ids: [String] = [], keep: String? = nil, text: String? = nil, noteKind: ProjectMemoryNote.Kind? = nil,
                verified: Bool? = nil, evidence: [String], agreed: Bool) {
        self.kind = kind; self.ids = ids; self.keep = keep; self.text = text; self.noteKind = noteKind
        self.verified = verified; self.evidence = evidence; self.agreed = agreed
    }
}

// One cleanup, as the info tab shows it: when, who met, what changed, what waits for the next one.
public struct ProjectMemoryCleanupRecord: Codable, Equatable, Identifiable {
    public struct Dropped: Codable, Equatable { public var edit: ProjectMemoryEdit; public var reason: String }
    public var id: UUID             // the meeting id, also the history batch
    public var at: Date
    public var attendees: [String]
    public var merged = 0, fixed = 0, archived = 0, added = 0
    public var deferred: [ProjectMemoryEdit] = []   // not agreed, or over the limit: for the next cleanup
    public var dropped: [Dropped] = []
    public var manual = false
}

public enum ProjectMemoryCleanup {
    public static let maxEdits = 30
    public static let logDays = 14          // committed work logs older than this become one line per ISO week
    public static let weekDays = 30         // weekly lines older than this go to the archive
    public static let interval: TimeInterval = 86_400
    public static let minAnswers = 5
    public static let fullShare = 0.8       // of ProjectMemoryStore.budget

    public enum Outcome: Equatable { case applied(ProjectMemoryCleanupRecord), refused(String) }

    static func file(_ project: String) -> URL { ProjectMemoryStore.folder(project).appendingPathComponent("memory-cleanups.json") }
    private static func attemptFile(_ project: String) -> URL {
        ProjectMemoryStore.folder(project).appendingPathComponent("memory-cleanup-attempt.json")
    }
    private static let lock = NSLock()
    private static let encoder: JSONEncoder = {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.sortedKeys, .prettyPrinted]; return e
    }()
    private static let decoder: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }()

    // Every cleanup of the project, oldest first.
    public static func records(_ project: String) -> [ProjectMemoryCleanupRecord] {
        lock.lock(); defer { lock.unlock() }
        return read(project)
    }
    public static func last(_ project: String) -> ProjectMemoryCleanupRecord? { records(project).last }

    // Save before calling any AI. An interrupted or failed meeting still counts as an attempt.
    public static func recordAttempt(_ project: String, at: Date) -> Bool {
        lock.lock(); defer { lock.unlock() }
        do {
            let file = attemptFile(project)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            try encoder.encode(at).write(to: file, options: .atomic)
            return true
        } catch { return false }
    }

    public static func pending(_ project: String) -> [ProjectMemoryEdit] {
        let edits = last(project)?.deferred ?? []
        let history = ProjectMemoryStore.shared.history(project)
        let marks = ProjectMemoryStore.deleted(history)
        return edits.filter { edit in
            edit.text.map { $0.count <= ProjectMemoryStore.textLimit && !containsDeletedText($0, marks: marks) } ?? true
        }
    }

    private static func read(_ project: String) -> [ProjectMemoryCleanupRecord] {
        (try? Data(contentsOf: file(project))).flatMap { try? decoder.decode([ProjectMemoryCleanupRecord].self, from: $0) } ?? []
    }

    // Time for a cleanup: asked for by hand; or a day since the last one (or never one) with at least `minAnswers`
    // project answers since; or the active notes over 80% of what an instruction carries. `answers`: the project
    // chats' answers since `last(project)?.at` (the chat counts them); `size`: one note's line as the AIs get it.
    public static func due(_ project: String, answers: Int, manual: Bool = false, now: Date = Date(),
                           size: (ProjectMemoryNote) -> Int = { $0.text.count + 40 }) -> Bool {
        if manual { return true }
        lock.lock()
        let last = read(project).last?.at
        let attempt = (try? Data(contentsOf: attemptFile(project))).flatMap { try? decoder.decode(Date.self, from: $0) }
        lock.unlock()
        if let last, now.timeIntervalSince(last) < interval { return false }
        if let attempt, last.map({ attempt > $0 }) ?? true, now.timeIntervalSince(attempt) < 3_600 { return false }
        if answers >= minAnswers { return true }
        let used = ProjectMemoryStore.shared.notes(project).filter { $0.state == .active }.reduce(0) { $0 + size($1) + 1 }
        return Double(used) > Double(ProjectMemoryStore.budget) * fullShare
    }

    // Applies a meeting's edits. `chats`, `commits`: the evidence the meeting was given; `meeting`: its id, the batch.
    public static func apply(_ edits: [ProjectMemoryEdit], meeting: UUID, attendees: [String], chats: Set<UUID>, commits: [String],
                             project: String, manual: Bool = false, now: Date = Date()) -> Outcome {
        lock.lock(); defer { lock.unlock() }
        var records = read(project)
        if records.contains(where: { $0.id == meeting }) { return .refused("This cleanup was already applied.") }
        var record = ProjectMemoryCleanupRecord(id: meeting, at: now, attendees: attendees, manual: manual)
        let hashes = commits.map { $0.lowercased() }
        func found(_ evidence: String) -> String? {
            let e = evidence.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if let id = UUID(uuidString: e), chats.contains(id) { return id.uuidString }
            guard e.count >= 7, e.allSatisfy(\.isHexDigit) else { return nil }
            return hashes.first { $0.hasPrefix(e) }
        }
        var repeated = false
        let failure = ProjectMemoryStore.shared.batch(project) { notes, history in
            if history.contains(where: { $0.batch == meeting }) { repeated = true; return [] }
            let marks = ProjectMemoryStore.deleted(history)
            var lines: [ProjectMemoryChange] = [], applied = 0
            func line(_ action: String, _ note: ProjectMemoryNote, others: [ProjectMemoryNote]? = nil, evidence: [String]? = nil) {
                lines.append(ProjectMemoryChange(at: now, action: action, note: note, by: ProjectMemoryChange.byMeeting, batch: meeting,
                                                 others: others?.isEmpty == true ? nil : others, evidence: evidence))
            }
            func index(_ id: String) -> Int? {
                let s = id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if let full = UUID(uuidString: s) { return notes.firstIndex { $0.id == full && $0.state != .deleted } }
                guard s.count >= 8 else { return nil }
                let hits = notes.indices.filter { notes[$0].state != .deleted && notes[$0].id.uuidString.lowercased().hasPrefix(s) }
                return hits.count == 1 ? hits[0] : nil
            }
            func archive(_ i: Int, by replacement: UUID?) -> ProjectMemoryNote {
                notes[i].state = .archived; notes[i].archivedAt = now; notes[i].replacedBy = replacement
                return notes[i]
            }
            for edit in edits {
                func drop(_ reason: String) { record.dropped.append(.init(edit: edit, reason: reason)) }
                let evidence = Array(Set(edit.evidence.compactMap(found))).sorted()
                guard !evidence.isEmpty else { drop("no evidence from the material"); continue }
                let picked = edit.ids.map(index)
                guard !picked.contains(nil) else { drop("no such note"); continue }
                var targets: [Int] = []
                for i in picked.compactMap({ $0 }) where !targets.contains(i) { targets.append(i) }
                guard targets.allSatisfy({ notes[$0].state == .active }) else { drop("note already archived"); continue }
                var text = edit.text?.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
                if [.merge, .fix, .shorten, .add].contains(edit.kind) {
                    guard let t = text, !t.isEmpty, t.count <= ProjectMemoryStore.textLimit else { drop("no text, or over the limit"); continue }
                    if containsDeletedText(t, marks: marks) {
                        var redacted = edit; redacted.text = nil
                        record.dropped.append(.init(edit: redacted, reason: "brings back a deleted text"))
                        continue
                    }
                    text = t
                }
                if !edit.agreed || applied >= maxEdits {
                    var deferred = edit; deferred.evidence = evidence
                    if !record.deferred.contains(deferred) { record.deferred.append(deferred) }
                    continue
                }
                func fresh(_ kind: ProjectMemoryNote.Kind, verified: Bool, pinned: Bool, replaces: UUID?) -> ProjectMemoryNote {
                    var n = ProjectMemoryNote(kind: kind, text: text ?? "", by: ProjectMemoryChange.byMeeting, verified: verified,
                                              pinned: pinned, createdAt: now)
                    n.replaces = replaces
                    return n
                }
                switch edit.kind {
                case .merge:
                    guard targets.count >= 2 else { drop("merge needs two notes or more"); continue }
                    let old = targets.map { notes[$0] }
                    let note = fresh(edit.noteKind ?? old[0].kind, verified: edit.verified ?? old.allSatisfy(\.verified),
                                     pinned: old.contains(where: \.pinned), replaces: old[0].id)
                    let gone = targets.map { archive($0, by: note.id) }
                    notes.append(note); line("merge", note, others: gone, evidence: evidence); record.merged += 1
                case .fix, .shorten:
                    guard targets.count == 1, let i = targets.first else { drop("needs one note"); continue }
                    if edit.kind == .shorten, (text ?? "").count >= notes[i].text.count { drop("not shorter"); continue }
                    let note = fresh(notes[i].kind, verified: edit.verified ?? notes[i].verified, pinned: notes[i].pinned, replaces: notes[i].id)
                    let old = archive(i, by: note.id)
                    notes.append(note)
                    lines.append(ProjectMemoryChange(at: now, action: "replace", note: note, old: old.id, archived: old,
                                                     by: ProjectMemoryChange.byMeeting, batch: meeting, evidence: evidence))
                    record.fixed += 1
                case .archive:
                    guard !targets.isEmpty else { drop("no note"); continue }
                    let gone = targets.map { archive($0, by: nil) }
                    line("archive", gone.last!, others: Array(gone.dropLast()), evidence: evidence); record.archived += gone.count
                case .add:
                    guard targets.isEmpty else { drop("an add names no note"); continue }
                    let kind = edit.noteKind ?? .decision
                    if notes.contains(where: { $0.state == .active && $0.kind == kind && $0.text.lowercased() == text!.lowercased() }) {
                        drop("already in memory"); continue
                    }
                    guard notes.filter({ $0.state == .active && !($0.kind == .log && $0.commits != nil) }).count < ProjectMemoryStore.maxActive
                    else { drop("memory is full"); continue }
                    let note = fresh(kind, verified: edit.verified ?? false, pinned: false, replaces: nil)
                    notes.append(note); line("add", note, evidence: evidence); record.added += 1
                case .verify:
                    guard targets.count == 1, let i = targets.first else { drop("needs one note"); continue }
                    let next = edit.verified ?? !notes[i].verified
                    guard next != notes[i].verified else { drop("no change"); continue }
                    notes[i].verified = next
                    line("verify", notes[i], evidence: evidence); record.fixed += 1
                case .resolve:
                    guard let keep = edit.keep.flatMap(index), notes[keep].state == .active, targets.contains(keep), targets.count >= 2
                    else { drop("resolve keeps one of its notes"); continue }
                    let gone = targets.filter { $0 != keep }.map { archive($0, by: notes[keep].id) }
                    line("resolve", notes[keep], others: gone, evidence: evidence); record.archived += gone.count
                }
                applied += 1
            }
            fold(&notes, now: now, marks: marks, record: &record, line: { action, note, others in line(action, note, others: others) })
            return lines
        }
        if let failure { return .refused(failure) }
        if repeated { return .refused("This cleanup was already applied.") }
        records.append(record)
        do {
            try FileManager.default.createDirectory(at: ProjectMemoryStore.folder(project), withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            try encoder.encode(records).write(to: file(project), options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file(project).path)
        } catch { return .refused("The cleanup was saved in the history, but its record could not be written.") }
        return .applied(record)
    }

    // The app's rule: committed work logs older than `logDays` become one line per ISO week (a week's line made
    // before joins them), and weekly lines older than `weekDays` (a week whose newest work is) go to the archive.
    private static func containsDeletedText(_ text: String, marks: Set<String>) -> Bool {
        guard !marks.isEmpty else { return false }
        let words = text.split(whereSeparator: \.isWhitespace)
        for start in words.indices {
            for end in start..<words.count {
                let passage = text[words[start].startIndex..<words[end].endIndex]
                if marks.contains(ProjectMemoryStore.mark(String(passage))) { return true }
            }
        }
        return false
    }

    static func fold(_ notes: inout [ProjectMemoryNote], now: Date, marks: Set<String>, record: inout ProjectMemoryCleanupRecord,
                     line: (String, ProjectMemoryNote, [ProjectMemoryNote]) -> Void) {
        var calendar = Calendar(identifier: .iso8601); calendar.timeZone = .current
        func week(_ date: Date) -> String {
            let c = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)
            return String(format: "%04d-W%02d", c.yearForWeekOfYear ?? 0, c.weekOfYear ?? 0)
        }
        let logCutoff = now.addingTimeInterval(-Double(logDays) * 86_400), weekCutoff = now.addingTimeInterval(-Double(weekDays) * 86_400)
        let old = notes.indices.filter { notes[$0].state == .active && notes[$0].kind == .log && notes[$0].commits != nil && notes[$0].createdAt < logCutoff }
        let groups = Dictionary(grouping: old) { week(notes[$0].createdAt) }
        for key in groups.keys.sorted() {
            let members = groups[key]!.sorted { notes[$0].createdAt < notes[$1].createdAt }
            let newest = notes[members.last!].createdAt
            if newest < weekCutoff {
                let gone = members.map { i -> ProjectMemoryNote in notes[i].state = .archived; notes[i].archivedAt = now; return notes[i] }
                line("archive", gone.last!, Array(gone.dropLast())); record.archived += gone.count
                continue
            }
            guard members.count > 1 || weekly(notes[members[0]].text) == nil else { continue }
            let prefix = key + " · work log · "
            let joined = members.map { work(notes[$0].text) }.filter { !$0.isEmpty }.joined(separator: "; ")
            let room = ProjectMemoryStore.textLimit - prefix.count
            let text = prefix + (joined.count > room ? String(joined.prefix(room - 1)) + "…" : joined)
            guard !containsDeletedText(text, marks: marks) else { continue }
            var note = ProjectMemoryNote(kind: .log, text: text,
                                         verified: members.allSatisfy { notes[$0].verified }, pinned: members.contains { notes[$0].pinned },
                                         createdAt: newest)
            var seen = Set<String>()
            note.commits = members.flatMap { notes[$0].commits ?? [] }.filter { seen.insert($0).inserted }
            note.replaces = notes[members[0]].id
            let gone = members.map { i -> ProjectMemoryNote in
                notes[i].state = .archived; notes[i].archivedAt = now; notes[i].replacedBy = note.id; return notes[i]
            }
            notes.append(note)
            line("merge", note, gone); record.merged += 1
        }
    }

    // "2026-W45" when the text is a weekly line.
    static func weekly(_ text: String) -> String? {
        let head = String(text.prefix(8))
        return head.range(of: #"^\d{4}-W\d{2}$"#, options: .regularExpression) != nil && text.dropFirst(8).hasPrefix(" · ") ? head : nil
    }

    // The work in a log line: "date · AI · work · chat:id" or a weekly line "week · work log · work".
    static func work(_ text: String) -> String {
        var parts = text.components(separatedBy: " · ")
        if weekly(text) != nil, parts.count >= 3 { parts.removeFirst(2) }
        else if parts.count >= 4, parts.last?.hasPrefix("chat:") == true { parts = Array(parts[2..<(parts.count - 1)]) }
        return parts.joined(separator: " · ")
    }
}
