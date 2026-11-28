import Foundation
import CryptoKit
import AIAccounts
import AILocalization

// App-managed procedure guides ("skills", Hermes Agent style). Kept under the app's support folder — outside the
// folders CLIs can write and separate from CLI-native .claude/skills or .agents/skills — so skill files never bypass
// sandbox or permission rules.
//   Project skills: <support>/projects/<id>/skills/<name>/SKILL.md (ProjectSkillStore, keyed by ProjectBinding.groupKey)
//   Global skills:  <support>/skills/<name>/SKILL.md (AIChat SkillStore, sharing SkillDocument and SkillDirectory here)
// Each store keeps skills.json (metadata + tombstones for future iCloud sync) and skills-history.jsonl (one line per
// change for Undo). User-authored and externally edited skills are userLocked: AI and meeting saves return needsApproval.

public enum SkillAuthor: String, Codable, Equatable {
    case user, ai, meeting
}

// One SKILL.md file: agentskills-style YAML frontmatter (`name`, `description`) followed by markdown body.
public struct SkillDocument: Equatable {
    public static let maxSlugLength = 64
    public static let maxDescriptionLength = 1_024
    public static let maxBodyBytes = 200_000

    public var name: String
    public var description: String
    public var body: String

    public init(name: String, description: String, body: String) {
        self.name = name
        self.description = description
        self.body = body
    }

    // Lowercase ASCII letters, digits and single hyphens, starting and ending with a letter or digit (1...64 chars).
    public static func isValidSlug(_ name: String) -> Bool {
        guard !name.isEmpty, name.count <= maxSlugLength else { return false }
        var previousHyphen = true
        for scalar in name.unicodeScalars {
            let v = scalar.value
            let isLower = v >= 0x61 && v <= 0x7A
            let isDigit = v >= 0x30 && v <= 0x39
            if isLower || isDigit {
                previousHyphen = false
            } else if v == 0x2D {   // '-'
                if previousHyphen { return false }
                previousHyphen = true
            } else {
                return false
            }
        }
        return !previousHyphen
    }

    public static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public static func hash(_ text: String) -> String {
        hash(Data(text.utf8))
    }

    public func render() -> String {
        Self.render(name: name, description: description, body: body)
    }

    public static func render(name: String, description: String, body: String) -> String {
        let desc = cleanDescription(description)
        let cleanBody = normalizeNewlines(body).trimmingCharacters(in: CharacterSet(charactersIn: "\n"))
        var out = "---\nname: \(name)\ndescription: \(yamlScalar(desc))\n---\n"
        if !cleanBody.isEmpty { out += "\n" + cleanBody + "\n" }
        return out
    }

    // Parses agentskills frontmatter (`name`, `description`) and markdown body; nil if frontmatter or fields are invalid.
    public static func parse(_ text: String) -> SkillDocument? {
        var normalized = normalizeNewlines(text)
        if normalized.hasPrefix("\u{FEFF}") { normalized.removeFirst() }
        let lines = normalized.components(separatedBy: "\n")
        guard let first = lines.first, first.trimmingCharacters(in: .whitespaces) == "---" else { return nil }
        var closeIndex: Int?
        for i in 1..<lines.count {
            let trimmed = lines[i].trimmingCharacters(in: .whitespaces)
            if trimmed == "---" || trimmed == "..." { closeIndex = i; break }
        }
        guard let end = closeIndex else { return nil }
        let fields = parseFrontmatter(Array(lines[1..<end]))
        guard let rawName = fields["name"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              isValidSlug(rawName),
              let rawDesc = fields["description"] else { return nil }
        let desc = cleanDescription(rawDesc)
        guard !desc.isEmpty else { return nil }
        let bodyLines = end + 1 < lines.count ? Array(lines[(end + 1)...]) : []
        let body = bodyLines.joined(separator: "\n").trimmingCharacters(in: CharacterSet(charactersIn: "\n"))
        return SkillDocument(name: rawName, description: desc, body: body)
    }

    public static func read(from url: URL) throws -> (document: SkillDocument?, raw: String, hash: String) {
        let data = try Data(contentsOf: url)
        guard let raw = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileReadInapplicableStringEncoding)
        }
        return (parse(raw), raw, hash(data))
    }

    public static func write(_ document: SkillDocument, to url: URL) throws -> (raw: String, hash: String) {
        let raw = document.render()
        let data = Data(raw.utf8)
        let folder = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return (raw, hash(data))
    }

    static func cleanDescription(_ text: String) -> String {
        normalizeNewlines(text)
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func normalizeNewlines(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    }

    private static func yamlScalar(_ value: String) -> String {
        let lower = value.lowercased()
        let keywords: Set<String> = ["true", "false", "yes", "no", "on", "off", "null", "~"]
        let special = CharacterSet(charactersIn: ":#\"'\\[]{}|>!&*%@`?,")
        let needsQuotes = value.isEmpty
            || keywords.contains(lower)
            || value.hasPrefix("-") || value.hasPrefix(" ") || value.hasSuffix(" ")
            || value.rangeOfCharacter(from: special) != nil
        guard needsQuotes else { return value }
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\t", with: "\\t")
            .replacingOccurrences(of: "\n", with: "\\n")
        return "\"" + escaped + "\""
    }

    private static func parseFrontmatter(_ lines: [String]) -> [String: String] {
        var result: [String: String] = [:]
        var i = 0
        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { i += 1; continue }
            guard !line.hasPrefix(" "), !line.hasPrefix("\t"), let colon = line.firstIndex(of: ":") else {
                i += 1; continue
            }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            let rawValue = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if rawValue == "|" || rawValue == "|-" || rawValue == "|+" || rawValue == ">" || rawValue == ">-" || rawValue == ">+" {
                let folded = rawValue.hasPrefix(">")
                var block: [String] = []
                i += 1
                var indent: Int?
                while i < lines.count {
                    let next = lines[i]
                    if next.trimmingCharacters(in: .whitespaces).isEmpty {
                        block.append("")
                        i += 1
                        continue
                    }
                    let spaces = next.prefix { $0 == " " }.count
                    if spaces == 0 { break }
                    if indent == nil { indent = spaces }
                    let drop = min(spaces, indent ?? spaces)
                    block.append(String(next.dropFirst(drop)))
                    i += 1
                }
                while block.last == "" { block.removeLast() }
                result[key] = block.joined(separator: folded ? " " : "\n")
                continue
            }
            result[key] = unquoteYAML(rawValue)
            i += 1
        }
        return result
    }

    private static func unquoteYAML(_ raw: String) -> String {
        if raw.count >= 2, raw.hasPrefix("\""), raw.hasSuffix("\"") {
            let inner = raw.dropFirst().dropLast()
            var out = "", escaped = false
            for ch in inner {
                if escaped {
                    switch ch {
                    case "n": out.append("\n")
                    case "r": out.append("\r")
                    case "t": out.append("\t")
                    case "\"": out.append("\"")
                    case "\\": out.append("\\")
                    default: out.append(ch)
                    }
                    escaped = false
                } else if ch == "\\" {
                    escaped = true
                } else {
                    out.append(ch)
                }
            }
            if escaped { out.append("\\") }
            return out
        }
        if raw.count >= 2, raw.hasPrefix("'"), raw.hasSuffix("'") {
            return String(raw.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'")
        }
        return raw
    }
}

public struct SkillRecord: Codable, Identifiable, Equatable {
    public var id: UUID
    public var name: String
    public var enabled: Bool
    public var createdBy: SkillAuthor
    public var userLocked: Bool
    public var contentHash: String
    public var isNew: Bool
    public var updatedAt: Date

    public init(id: UUID = UUID(), name: String, enabled: Bool = true, createdBy: SkillAuthor,
                userLocked: Bool, contentHash: String, isNew: Bool = false, updatedAt: Date = Date()) {
        self.id = id
        self.name = name
        self.enabled = enabled
        self.createdBy = createdBy
        self.userLocked = userLocked
        self.contentHash = contentHash
        self.isNew = isNew
        self.updatedAt = updatedAt
    }
}

// Kept in skills.json when a skill is deleted so future iCloud sync does not resurrect it.
public struct SkillTombstone: Codable, Equatable {
    public var id: UUID
    public var name: String?
    public var deletedAt: Date

    public init(id: UUID, name: String? = nil, deletedAt: Date = Date()) {
        self.id = id
        self.name = name
        self.deletedAt = deletedAt
    }
}

struct SkillIndexData: Codable, Equatable {
    static let currentVersion = 1
    var version = currentVersion
    var skills: [SkillRecord] = []
    var tombstones: [SkillTombstone] = []

    init(version: Int = currentVersion, skills: [SkillRecord] = [], tombstones: [SkillTombstone] = []) {
        self.version = version
        self.skills = skills
        self.tombstones = tombstones
    }

    private enum Keys: String, CodingKey { case version, skills, tombstones }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? Self.currentVersion
        skills = try c.decodeIfPresent([SkillRecord].self, forKey: .skills) ?? []
        tombstones = try c.decodeIfPresent([SkillTombstone].self, forKey: .tombstones) ?? []
    }
}

public struct SkillSummary: Identifiable, Equatable {
    public var id: UUID { record.id }
    public var name: String { record.name }
    public var record: SkillRecord
    public var description: String
    public var externallyModified: Bool

    public init(record: SkillRecord, description: String, externallyModified: Bool = false) {
        self.record = record
        self.description = description
        self.externallyModified = externallyModified
    }
}

public struct SkillDetail: Identifiable, Equatable {
    public var id: UUID { record.id }
    public var name: String { record.name }
    public var record: SkillRecord
    public var document: SkillDocument
    public var externallyModified: Bool

    public init(record: SkillRecord, document: SkillDocument, externallyModified: Bool = false) {
        self.record = record
        self.document = document
        self.externallyModified = externallyModified
    }
}

public enum SkillAction: String, Codable, Equatable {
    case add, update, delete, enable, disable
    case setAllEnabled = "set_all_enabled"
    case undo
}

public struct SkillSnapshot: Codable, Equatable {
    public var record: SkillRecord
    public var markdown: String?

    public init(record: SkillRecord, markdown: String? = nil) {
        self.record = record
        self.markdown = markdown
    }
}

public struct SkillHistoryItem: Codable, Equatable {
    public var before: SkillSnapshot?
    public var after: SkillSnapshot?
    public var tombstone: SkillTombstone?

    public init(before: SkillSnapshot? = nil, after: SkillSnapshot? = nil, tombstone: SkillTombstone? = nil) {
        self.before = before
        self.after = after
        self.tombstone = tombstone
    }
}

// One line of skills-history.jsonl: every add, update, delete, enable, disable, set_all_enabled and undo.
public struct SkillHistoryEntry: Codable, Identifiable, Equatable {
    public var id: UUID
    public var at: Date
    public var action: SkillAction
    public var by: SkillAuthor
    public var actor: String?
    public var skillID: UUID?
    public var name: String?
    public var items: [SkillHistoryItem]
    public var undoes: UUID?

    public init(id: UUID = UUID(), at: Date = Date(), action: SkillAction, by: SkillAuthor, actor: String? = nil,
                skillID: UUID? = nil, name: String? = nil, items: [SkillHistoryItem], undoes: UUID? = nil) {
        self.id = id
        self.at = at
        self.action = action
        self.by = by
        self.actor = actor
        self.skillID = skillID
        self.name = name
        self.items = items
        self.undoes = undoes
    }
}

public enum SkillOutcome: Equatable {
    case saved(SkillRecord)
    case updated([SkillRecord])
    case deleted(SkillTombstone)
    case undone(SkillHistoryEntry)
    case needsApproval(SkillRecord, String)
    case refused(String)
}

// Directory-backed skill store used by ProjectSkillStore (AIProjects) and SkillStore (AIChat).
// Reads skills.json and SKILL.md directly under a lock so external edits are detected immediately and tests never keep
// stale state across homes.
public final class SkillDirectory {
    static let indexFileName = "skills.json"
    static let historyFileName = "skills-history.jsonl"
    static let skillFileName = "SKILL.md"

    private let folder: () -> URL
    private let onChange: (() -> Void)?
    private let lock = NSLock()

    private static let prettyEncoder: JSONEncoder = {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.prettyPrinted, .sortedKeys]; return e
    }()
    private static let lineEncoder: JSONEncoder = {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.sortedKeys]; return e
    }()
    private static let decoder: JSONDecoder = {
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d
    }()

    public init(folder: @escaping () -> URL, onChange: (() -> Void)? = nil) {
        self.folder = folder
        self.onChange = onChange
    }

    public var root: URL { folder() }
    var indexURL: URL { root.appendingPathComponent(Self.indexFileName) }
    var historyURL: URL { root.appendingPathComponent(Self.historyFileName) }
    func skillFolder(_ name: String) -> URL { root.appendingPathComponent(name, isDirectory: true) }
    func skillFile(_ name: String) -> URL { skillFolder(name).appendingPathComponent(Self.skillFileName) }

    public func list() -> [SkillSummary] {
        lock.lock(); defer { lock.unlock() }
        guard let index = loadIndex() else { return [] }
        let byName = Dictionary(index.skills.map { ($0.name, $0) }, uniquingKeysWith: { _, latest in latest })
        let names = Set(byName.keys).union(diskSkillNames())
        var out: [SkillSummary] = []
        for name in names.sorted() {
            guard let disk = try? SkillDocument.read(from: skillFile(name)) else { continue }
            let resolved = resolveRecord(name: name, tracked: byName[name], diskHash: disk.hash)
            let desc = disk.document?.description ?? ""
            out.append(SkillSummary(record: resolved.record, description: desc, externallyModified: resolved.externallyModified))
        }
        return out
    }

    public func read(_ name: String) -> SkillDetail? {
        guard SkillDocument.isValidSlug(name) else { return nil }
        lock.lock(); defer { lock.unlock() }
        guard let index = loadIndex(),
              let disk = try? SkillDocument.read(from: skillFile(name)) else { return nil }
        let tracked = index.skills.first { $0.name == name }
        let resolved = resolveRecord(name: name, tracked: tracked, diskHash: disk.hash)
        let doc = disk.document ?? SkillDocument(name: name, description: "", body: disk.raw)
        return SkillDetail(record: resolved.record, document: doc, externallyModified: resolved.externallyModified)
    }

    public func tombstones() -> [SkillTombstone] {
        lock.lock(); defer { lock.unlock() }
        return loadIndex()?.tombstones ?? []
    }

    public func history() -> [SkillHistoryEntry] {
        lock.lock(); defer { lock.unlock() }
        return loadHistory() ?? []
    }

    // Creates, updates, or (when `id` matches an existing skill with another name) renames a skill.
    // User saves always set userLocked = true. AI/meeting saves on a user-locked or externally edited skill return
    // .needsApproval without modifying disk files.
    public func save(name: String, description: String, body: String, by: SkillAuthor,
                     id: UUID? = nil, actor: String? = nil, isNew: Bool? = nil, now: Date = Date()) -> SkillOutcome {
        let now = Self.isoSecond(now)
        guard SkillDocument.isValidSlug(name) else {
            return .refused(L("스킬 이름은 소문자, 숫자, 하이픈만 쓸 수 있어요 (예: my-skill).",
                              "Skill names must be lowercase letters, digits and hyphens (e.g. my-skill)."))
        }
        let cleanDesc = SkillDocument.cleanDescription(description)
        guard !cleanDesc.isEmpty else {
            return .refused(L("스킬 설명을 한 줄 이상 적어 주세요.", "Write a description for the skill."))
        }
        guard cleanDesc.count <= SkillDocument.maxDescriptionLength else {
            return .refused(L("스킬 설명이 너무 길어요 (최대 \(SkillDocument.maxDescriptionLength)자).",
                              "Skill description is too long (at most \(SkillDocument.maxDescriptionLength) characters)."))
        }
        guard body.utf8.count <= SkillDocument.maxBodyBytes else {
            return .refused(L("스킬 본문이 너무 길어요.", "Skill body is too large."))
        }

        var changed = false
        defer { if changed { onChange?() } }

        lock.lock(); defer { lock.unlock() }
        guard var index = loadIndex(), loadHistory() != nil else {
            return .refused(L("스킬 저장소를 읽지 못해서 덮어쓰지 않았어요. 파일을 확인해 주세요.",
                              "The skill store could not be read, so nothing was overwritten. Please check the files."))
        }

        let existingIndex: Int?
        if let id {
            existingIndex = index.skills.firstIndex { $0.id == id }
            if existingIndex == nil, index.skills.contains(where: { $0.name == name }) {
                return .refused(L("같은 이름의 스킬(\(name))이 이미 있어요.", "A skill named \(name) already exists."))
            }
        } else {
            existingIndex = index.skills.firstIndex { $0.name == name }
        }

        // Prevent renaming onto another existing skill or untracked disk skill.
        if let i = existingIndex, index.skills[i].name != name {
            if index.skills.contains(where: { $0.name == name && $0.id != index.skills[i].id })
                || FileManager.default.fileExists(atPath: skillFile(name).path) {
                return .refused(L("같은 이름의 스킬(\(name))이 이미 있어요.", "A skill named \(name) already exists."))
            }
        }

        let existingRecord = existingIndex.map { index.skills[$0] }
        let sourceName = existingRecord?.name ?? name
        let disk = try? SkillDocument.read(from: skillFile(sourceName))

        // Untracked SKILL.md on disk is treated as user-authored and locked.
        if existingRecord == nil, let disk {
            let synthetic = resolveRecord(name: name, tracked: nil, diskHash: disk.hash).record
            if by != .user {
                return .needsApproval(synthetic, approvalMessage())
            }
            let doc = SkillDocument(name: name, description: cleanDesc, body: body)
            do {
                let written = try SkillDocument.write(doc, to: skillFile(name))
                var updated = synthetic
                updated.contentHash = written.hash
                updated.userLocked = true
                updated.isNew = isNew ?? false
                updated.updatedAt = now
                index.skills.append(updated)
                let before = SkillSnapshot(record: synthetic, markdown: disk.raw)
                let after = SkillSnapshot(record: updated, markdown: written.raw)
                let entry = SkillHistoryEntry(at: now, action: .update, by: by, actor: actor,
                                              skillID: updated.id, name: updated.name,
                                              items: [SkillHistoryItem(before: before, after: after)])
                try persist(index: index, append: entry)
                changed = true
                return .saved(updated)
            } catch {
                return .refused(saveFailure(error))
            }
        }

        if let i = existingIndex {
            let tracked = index.skills[i]
            let resolved = disk.map { resolveRecord(name: tracked.name, tracked: tracked, diskHash: $0.hash) }
            let effective = resolved?.record ?? tracked
            if effective.userLocked && by != .user {
                return .needsApproval(effective, approvalMessage())
            }
            let doc = SkillDocument(name: name, description: cleanDesc, body: body)
            do {
                let written = try SkillDocument.write(doc, to: skillFile(name))
                var updated = effective
                updated.name = name
                updated.contentHash = written.hash
                updated.userLocked = effective.userLocked || by == .user
                if let isNew { updated.isNew = isNew } else if by == .user { updated.isNew = false }
                updated.updatedAt = now
                index.skills[i] = updated
                let before = SkillSnapshot(record: effective, markdown: disk?.raw)
                let after = SkillSnapshot(record: updated, markdown: written.raw)
                let entry = SkillHistoryEntry(at: now, action: .update, by: by, actor: actor,
                                              skillID: updated.id, name: updated.name,
                                              items: [SkillHistoryItem(before: before, after: after)])
                try persist(index: index, append: entry)
                if tracked.name != name {
                    try? FileManager.default.removeItem(at: skillFolder(tracked.name))
                }
                changed = true
                return .saved(updated)
            } catch {
                return .refused(saveFailure(error))
            }
        }

        // New skill.
        let doc = SkillDocument(name: name, description: cleanDesc, body: body)
        do {
            let written = try SkillDocument.write(doc, to: skillFile(name))
            let record = SkillRecord(
                id: id ?? UUID(),
                name: name,
                enabled: true,
                createdBy: by,
                userLocked: by == .user,
                contentHash: written.hash,
                isNew: isNew ?? (by != .user),
                updatedAt: now
            )
            index.skills.append(record)
            let after = SkillSnapshot(record: record, markdown: written.raw)
            let entry = SkillHistoryEntry(at: now, action: .add, by: by, actor: actor,
                                          skillID: record.id, name: record.name,
                                          items: [SkillHistoryItem(before: nil, after: after)])
            try persist(index: index, append: entry)
            changed = true
            return .saved(record)
        } catch {
            return .refused(saveFailure(error))
        }
    }

    public func setEnabled(_ name: String, _ enabled: Bool, by: SkillAuthor = .user,
                           actor: String? = nil, now: Date = Date()) -> SkillOutcome {
        let now = Self.isoSecond(now)
        guard SkillDocument.isValidSlug(name) else {
            return .refused(L("올바른 스킬 이름이 아니에요.", "Invalid skill name."))
        }
        var changed = false
        defer { if changed { onChange?() } }

        lock.lock(); defer { lock.unlock() }
        guard var index = loadIndex(), loadHistory() != nil else {
            return .refused(L("스킬 저장소를 읽지 못해서 바꾸지 않았어요.", "The skill store could not be read."))
        }
        guard let disk = try? SkillDocument.read(from: skillFile(name)) else {
            return .refused(L("스킬(\(name))을 찾지 못했어요.", "Skill '\(name)' was not found."))
        }
        let trackedIndex = index.skills.firstIndex { $0.name == name }
        let beforeRecord = resolveRecord(name: name, tracked: trackedIndex.map { index.skills[$0] }, diskHash: disk.hash).record
        if beforeRecord.userLocked && by != .user {
            return .needsApproval(beforeRecord, approvalMessage())
        }
        if beforeRecord.enabled == enabled {
            return .saved(beforeRecord)
        }
        var afterRecord = beforeRecord
        afterRecord.enabled = enabled
        afterRecord.updatedAt = now
        if let i = trackedIndex { index.skills[i] = afterRecord } else { index.skills.append(afterRecord) }
        let item = SkillHistoryItem(before: SkillSnapshot(record: beforeRecord), after: SkillSnapshot(record: afterRecord))
        let entry = SkillHistoryEntry(at: now, action: enabled ? .enable : .disable, by: by, actor: actor,
                                      skillID: afterRecord.id, name: afterRecord.name, items: [item])
        do {
            try persist(index: index, append: entry)
            changed = true
            return .saved(afterRecord)
        } catch {
            return .refused(saveFailure(error))
        }
    }

    public func setAllEnabled(_ enabled: Bool, by: SkillAuthor = .user,
                              actor: String? = nil, now: Date = Date()) -> SkillOutcome {
        let now = Self.isoSecond(now)
        var changed = false
        defer { if changed { onChange?() } }

        lock.lock(); defer { lock.unlock() }
        guard var index = loadIndex(), loadHistory() != nil else {
            return .refused(L("스킬 저장소를 읽지 못해서 바꾸지 않았어요.", "The skill store could not be read."))
        }
        var byName = Dictionary(index.skills.map { ($0.name, $0) }, uniquingKeysWith: { _, latest in latest })
        let names = Set(byName.keys).union(diskSkillNames()).sorted()
        var items: [SkillHistoryItem] = []
        var updatedRecords: [SkillRecord] = []

        for name in names {
            guard let disk = try? SkillDocument.read(from: skillFile(name)) else { continue }
            let before = resolveRecord(name: name, tracked: byName[name], diskHash: disk.hash).record
            if before.userLocked && by != .user {
                return .needsApproval(before, approvalMessage())
            }
            var after = before
            if before.enabled != enabled {
                after.enabled = enabled
                after.updatedAt = now
                items.append(SkillHistoryItem(before: SkillSnapshot(record: before), after: SkillSnapshot(record: after)))
            }
            byName[name] = after
            updatedRecords.append(after)
        }
        guard !items.isEmpty else { return .updated(updatedRecords) }
        for rec in updatedRecords {
            if let i = index.skills.firstIndex(where: { $0.id == rec.id || $0.name == rec.name }) {
                index.skills[i] = rec
            } else {
                index.skills.append(rec)
            }
        }
        let entry = SkillHistoryEntry(at: now, action: .setAllEnabled, by: by, actor: actor,
                                      skillID: nil, name: nil, items: items)
        do {
            try persist(index: index, append: entry)
            changed = true
            return .updated(updatedRecords)
        } catch {
            return .refused(saveFailure(error))
        }
    }

    public func delete(_ name: String, by: SkillAuthor = .user,
                       actor: String? = nil, now: Date = Date()) -> SkillOutcome {
        let now = Self.isoSecond(now)
        guard SkillDocument.isValidSlug(name) else {
            return .refused(L("올바른 스킬 이름이 아니에요.", "Invalid skill name."))
        }
        var changed = false
        defer { if changed { onChange?() } }

        lock.lock(); defer { lock.unlock() }
        guard var index = loadIndex(), loadHistory() != nil else {
            return .refused(L("스킬 저장소를 읽지 못해서 삭제하지 않았어요.", "The skill store could not be read."))
        }
        let trackedIndex = index.skills.firstIndex { $0.name == name }
        let disk = try? SkillDocument.read(from: skillFile(name))
        guard trackedIndex != nil || disk != nil else {
            return .refused(L("스킬(\(name))을 찾지 못했어요.", "Skill '\(name)' was not found."))
        }
        let effective: SkillRecord
        if let disk {
            effective = resolveRecord(name: name, tracked: trackedIndex.map { index.skills[$0] }, diskHash: disk.hash).record
        } else {
            effective = index.skills[trackedIndex!]
        }
        if effective.userLocked && by != .user {
            return .needsApproval(effective, approvalMessage())
        }
        if let i = trackedIndex { index.skills.remove(at: i) }
        let tombstone = SkillTombstone(id: effective.id, name: effective.name, deletedAt: now)
        index.tombstones.append(tombstone)
        let before = SkillSnapshot(record: effective, markdown: disk?.raw)
        let entry = SkillHistoryEntry(at: now, action: .delete, by: by, actor: actor,
                                      skillID: effective.id, name: effective.name,
                                      items: [SkillHistoryItem(before: before, after: nil, tombstone: tombstone)])
        do {
            try persist(index: index, append: entry)
            if FileManager.default.fileExists(atPath: skillFolder(name).path) {
                try FileManager.default.removeItem(at: skillFolder(name))
            }
            changed = true
            return .deleted(tombstone)
        } catch {
            return .refused(saveFailure(error))
        }
    }

    // Reverts the latest change that has not yet been undone.
    public func undo(by: SkillAuthor = .user, actor: String? = nil, now: Date = Date()) -> SkillOutcome {
        let now = Self.isoSecond(now)
        var changed = false
        defer { if changed { onChange?() } }

        lock.lock(); defer { lock.unlock() }
        guard var index = loadIndex(), let history = loadHistory() else {
            return .refused(L("스킬 저장소를 읽지 못해서 되돌리지 못했어요.", "The skill store could not be read."))
        }
        let undone = Self.undoneIDs(history)
        guard let target = history.last(where: { $0.action != .undo && !undone.contains($0.id) }) else {
            return .refused(L("되돌릴 변경이 없어요.", "Nothing to undo."))
        }

        let isToggleUndo = target.action == .enable || target.action == .disable || target.action == .setAllEnabled

        // Pre-flight checks before touching disk so a refused undo writes nothing.
        for item in target.items {
            switch (item.before, item.after) {
            case (nil, let after?):
                // Undoing an add: refuse if the file was modified externally since it was added.
                if let disk = try? SkillDocument.read(from: skillFile(after.record.name)),
                   disk.hash != after.record.contentHash {
                    return .refused(L("스킬(\(after.record.name))이 밖에서 직접 수정되어 되돌릴 수 없어요.",
                                      "Skill '\(after.record.name)' was edited externally and cannot be undone automatically."))
                }
            case (let before?, let after?):
                if !isToggleUndo {
                    if let disk = try? SkillDocument.read(from: skillFile(after.record.name)),
                       disk.hash != after.record.contentHash {
                        return .refused(L("스킬(\(after.record.name))이 밖에서 직접 수정되어 되돌릴 수 없어요.",
                                          "Skill '\(after.record.name)' was edited externally and cannot be undone automatically."))
                    }
                    if before.record.name != after.record.name,
                       (index.skills.contains(where: { $0.name == before.record.name && $0.id != before.record.id })
                        || FileManager.default.fileExists(atPath: skillFile(before.record.name).path)) {
                        return .refused(L("같은 이름의 스킬(\(before.record.name))이 이미 있어 되돌릴 수 없어요.",
                                          "A skill named '\(before.record.name)' already exists."))
                    }
                }
            case (let before?, nil):
                // Undoing a delete: refuse if a new skill with the same name already exists.
                if index.skills.contains(where: { $0.name == before.record.name })
                    || FileManager.default.fileExists(atPath: skillFile(before.record.name).path) {
                    return .refused(L("같은 이름의 스킬(\(before.record.name))이 이미 있어 복원할 수 없어요.",
                                      "A skill named '\(before.record.name)' already exists."))
                }
            case (nil, nil):
                break
            }
        }

        // Apply each item in reverse.
        var reverseItems: [SkillHistoryItem] = []
        do {
            for item in target.items {
                switch (item.before, item.after) {
                case (nil, let after?):
                    index.skills.removeAll { $0.id == after.record.id }
                    if FileManager.default.fileExists(atPath: skillFolder(after.record.name).path) {
                        try FileManager.default.removeItem(at: skillFolder(after.record.name))
                    }
                    reverseItems.append(SkillHistoryItem(before: after, after: nil))

                case (let before?, let after?):
                    if !isToggleUndo {
                        if let md = before.markdown {
                            try writeRaw(md, to: skillFile(before.record.name))
                        } else if FileManager.default.fileExists(atPath: skillFolder(after.record.name).path) {
                            try FileManager.default.removeItem(at: skillFolder(after.record.name))
                        }
                        if before.record.name != after.record.name,
                           FileManager.default.fileExists(atPath: skillFolder(after.record.name).path) {
                            try FileManager.default.removeItem(at: skillFolder(after.record.name))
                        }
                        if let i = index.skills.firstIndex(where: { $0.id == before.record.id }) {
                            index.skills[i] = before.record
                        } else {
                            index.skills.append(before.record)
                        }
                    } else {
                        // Enable/disable undo: preserve any newer disk edits while restoring enabled state.
                        if let i = index.skills.firstIndex(where: { $0.id == before.record.id }) {
                            var rec = index.skills[i]
                            if let disk = try? SkillDocument.read(from: skillFile(rec.name)), disk.hash != rec.contentHash {
                                rec.userLocked = true
                                rec.contentHash = disk.hash
                            }
                            rec.enabled = before.record.enabled
                            rec.updatedAt = before.record.updatedAt
                            index.skills[i] = rec
                        } else {
                            index.skills.append(before.record)
                        }
                    }
                    reverseItems.append(SkillHistoryItem(before: after, after: before))

                case (let before?, nil):
                    if let md = before.markdown {
                        try writeRaw(md, to: skillFile(before.record.name))
                    }
                    index.skills.removeAll { $0.id == before.record.id }
                    index.skills.append(before.record)
                    if let tomb = item.tombstone {
                        index.tombstones.removeAll { $0.id == tomb.id && $0.deletedAt == tomb.deletedAt }
                    }
                    reverseItems.append(SkillHistoryItem(before: nil, after: before))

                case (nil, nil):
                    break
                }
            }
            let undoEntry = SkillHistoryEntry(at: now, action: .undo, by: by, actor: actor,
                                              skillID: target.skillID, name: target.name,
                                              items: reverseItems, undoes: target.id)
            try persist(index: index, append: undoEntry)
            changed = true
            return .undone(undoEntry)
        } catch {
            return .refused(saveFailure(error))
        }
    }

    static func undoneIDs(_ history: [SkillHistoryEntry]) -> Set<UUID> {
        var undone = Set<UUID>()
        for entry in history.reversed() where !undone.contains(entry.id) {
            if let target = entry.undoes { undone.insert(target) }
        }
        return undone
    }

    private func approvalMessage() -> String {
        L("Inbox 승인 필요: 사용자가 만들거나 수정한 스킬은 AI가 바로 덮어쓸 수 없어요.",
          "Inbox approval required: AI cannot overwrite a user-locked skill directly.")
    }

    private func saveFailure(_ error: Error) -> String {
        L("스킬을 저장하지 못했어요: ", "Could not save the skill: ") + error.localizedDescription
    }

    private func resolveRecord(name: String, tracked: SkillRecord?, diskHash: String) -> (record: SkillRecord, externallyModified: Bool) {
        if var record = tracked {
            if record.contentHash != diskHash {
                record.userLocked = true
                record.contentHash = diskHash
                return (record, true)
            }
            return (record, false)
        }
        let synthetic = SkillRecord(
            id: deterministicExternalID(name: name),
            name: name,
            enabled: true,
            createdBy: .user,
            userLocked: true,
            contentHash: diskHash,
            isNew: false,
            updatedAt: fileModifiedDate(skillFile(name)) ?? Self.isoSecond(Date())
        )
        return (synthetic, true)
    }

    // Stable UUID for an untracked external folder before it is persisted into skills.json.
    private func deterministicExternalID(name: String) -> UUID {
        let digest = Array(SHA256.hash(data: Data(("external-skill:" + root.path + "/" + name).utf8)))
        var bytes = Array(digest.prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        let tuple = (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                     bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15])
        return UUID(uuid: tuple)
    }

    private static func isoSecond(_ date: Date) -> Date {
        Date(timeIntervalSince1970: floor(date.timeIntervalSince1970))
    }

    private func fileModifiedDate(_ url: URL) -> Date? {
        ((try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date).map(Self.isoSecond)
    }

    private func diskSkillNames() -> [String] {
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: root.path) else { return [] }
        return entries.filter { name in
            !name.hasPrefix(".")
                && SkillDocument.isValidSlug(name)
                && FileManager.default.fileExists(atPath: skillFile(name).path)
        }
    }

    private func loadIndex() -> SkillIndexData? {
        let url = indexURL
        guard FileManager.default.fileExists(atPath: url.path) else { return SkillIndexData() }
        guard let data = try? Data(contentsOf: url),
              let decoded = try? Self.decoder.decode(SkillIndexData.self, from: data),
              decoded.version <= SkillIndexData.currentVersion else { return nil }
        return decoded
    }

    private func loadHistory() -> [SkillHistoryEntry]? {
        let url = historyURL
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        var rows = text.components(separatedBy: "\n")
        rows.removeLast()   // drop "" after trailing newline, or an incomplete line cut off by a crash
        var out: [SkillHistoryEntry] = []
        for row in rows where !row.isEmpty {
            guard let entry = try? Self.decoder.decode(SkillHistoryEntry.self, from: Data(row.utf8)) else { return nil }
            out.append(entry)
        }
        return out
    }

    private func persist(index: SkillIndexData, append entry: SkillHistoryEntry) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let row = try Self.lineEncoder.encode(entry)
        try Self.appendLine(row, to: historyURL)
        let indexData = try Self.prettyEncoder.encode(index)
        try Self.writePrivate(indexData, to: indexURL)
    }

    private func writeRaw(_ text: String, to url: URL) throws {
        let folder = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try Self.writePrivate(Data(text.utf8), to: url)
    }

    private static func writePrivate(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private static func appendLine(_ line: Data, to file: URL) throws {
        if !FileManager.default.fileExists(atPath: file.path) {
            guard FileManager.default.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
        let handle = try FileHandle(forUpdating: file)
        defer { try? handle.close() }
        // Truncate any line cut off by a crash (no trailing newline) before appending.
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
        var payload = line
        payload.append(0x0A)
        try handle.write(contentsOf: payload)
    }
}

// Per-project skills under <support>/projects/<id>/skills/, sharing ProjectMemoryStore's groupKey folder layout.
public final class ProjectSkillStore: ObservableObject {
    public static let shared = ProjectSkillStore()

    @Published public private(set) var revision = 0
    private let lock = NSLock()
    private var directories: [String: SkillDirectory] = [:]

    public init() {}

    public static func folder(_ project: String) -> URL {
        ProjectMemoryStore.folder(project).appendingPathComponent("skills", isDirectory: true)
    }

    private func directory(_ project: String) -> SkillDirectory {
        lock.lock(); defer { lock.unlock() }
        if let existing = directories[project] { return existing }
        let dir = SkillDirectory(folder: { Self.folder(project) }, onChange: { [weak self] in self?.bump() })
        directories[project] = dir
        return dir
    }

    private func bump() {
        let update = { self.revision += 1 }
        if Thread.isMainThread { update() } else { DispatchQueue.main.async(execute: update) }
    }

    public func list(_ project: String) -> [SkillSummary] { directory(project).list() }
    public func read(_ name: String, project: String) -> SkillDetail? { directory(project).read(name) }
    public func tombstones(_ project: String) -> [SkillTombstone] { directory(project).tombstones() }
    public func history(_ project: String) -> [SkillHistoryEntry] { directory(project).history() }

    public func save(name: String, description: String, body: String, by: SkillAuthor, project: String,
                     id: UUID? = nil, actor: String? = nil, isNew: Bool? = nil, now: Date = Date()) -> SkillOutcome {
        directory(project).save(name: name, description: description, body: body, by: by, id: id, actor: actor, isNew: isNew, now: now)
    }

    public func setEnabled(_ name: String, _ enabled: Bool, project: String, by: SkillAuthor = .user,
                           actor: String? = nil, now: Date = Date()) -> SkillOutcome {
        directory(project).setEnabled(name, enabled, by: by, actor: actor, now: now)
    }

    public func setAllEnabled(_ enabled: Bool, project: String, by: SkillAuthor = .user,
                              actor: String? = nil, now: Date = Date()) -> SkillOutcome {
        directory(project).setAllEnabled(enabled, by: by, actor: actor, now: now)
    }

    public func delete(_ name: String, project: String, by: SkillAuthor = .user,
                       actor: String? = nil, now: Date = Date()) -> SkillOutcome {
        directory(project).delete(name, by: by, actor: actor, now: now)
    }

    public func undo(project: String, by: SkillAuthor = .user, actor: String? = nil, now: Date = Date()) -> SkillOutcome {
        directory(project).undo(by: by, actor: actor, now: now)
    }
}
