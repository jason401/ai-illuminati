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
        var out = "---\nname: \(yamlScalar(name))\ndescription: \(yamlScalar(desc))\n---\n"
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
        let keywords: Set<String> = [
            "true", "false", "yes", "no", "on", "off", "y", "n",
            "null", "~", ".nan", ".inf", "+.inf", "-.inf", "nan", "inf"
        ]
        let special = CharacterSet(charactersIn: ":#\"'\\[]{}|>!&*%@`?,\t\n\r")
        let hasControl = value.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7F }
        let needsQuotes = value.isEmpty
            || keywords.contains(lower)
            || looksNumericOrDate(value)
            || value == "---" || value == "..."
            || value.hasPrefix("-") || value.hasPrefix("+") || value.hasPrefix(".")
            || value.hasPrefix(" ") || value.hasSuffix(" ")
            || hasControl
            || value.rangeOfCharacter(from: special) != nil
        guard needsQuotes else { return value }
        var out = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            case "\t": out += "\\t"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\0": out += "\\0"
            default:
                if scalar.value < 0x20 || scalar.value == 0x7F {
                    out += String(format: "\\x%02x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        out += "\""
        return out
    }

    // Detects YAML 1.1/1.2 numbers (int, float, hex/octal/binary, underscore-separated) and ISO dates so
    // standard YAML parsers keep them as strings when quoted.
    private static func looksNumericOrDate(_ value: String) -> Bool {
        let stripped = value.replacingOccurrences(of: "_", with: "")
        if Int(stripped) != nil || Double(stripped) != nil { return true }
        let unsigned = (stripped.hasPrefix("+") || stripped.hasPrefix("-")) ? String(stripped.dropFirst()) : stripped
        let lower = unsigned.lowercased()
        if lower.hasPrefix("0x") || lower.hasPrefix("0o") || lower.hasPrefix("0b") {
            let digits = lower.dropFirst(2)
            let radix = lower.hasPrefix("0x") ? 16 : (lower.hasPrefix("0o") ? 8 : 2)
            if !digits.isEmpty, Int(digits, radix: radix) != nil { return true }
        }
        // YYYY-M-D (YAML 1.1 timestamp)
        let bytes = Array(value.utf8)
        if bytes.count >= 8,
           bytes[0...3].allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }),
           bytes[4] == 0x2D {
            var idx = 5
            var monthDigits = 0
            while idx < bytes.count, bytes[idx] >= 0x30 && bytes[idx] <= 0x39, monthDigits < 2 { idx += 1; monthDigits += 1 }
            if monthDigits >= 1, idx < bytes.count, bytes[idx] == 0x2D {
                idx += 1
                var dayDigits = 0
                while idx < bytes.count, bytes[idx] >= 0x30 && bytes[idx] <= 0x39, dayDigits < 2 { idx += 1; dayDigits += 1 }
                if dayDigits >= 1, idx == bytes.count || bytes[idx] == 0x20 || bytes[idx] == 0x54 || bytes[idx] == 0x74 {
                    return true
                }
            }
        }
        return false
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
            let afterColon = line.index(after: colon)
            guard afterColon == line.endIndex || line[afterColon] == " " || line[afterColon] == "\t" else {
                i += 1; continue
            }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            let rawValue = line[afterColon...].trimmingCharacters(in: .whitespaces)
            let header = stripInlineComment(rawValue)
            if isBlockScalarHeader(header) {
                let folded = header.hasPrefix(">")
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
            if let value = parseYAMLScalar(rawValue) {
                result[key] = value
            }
            i += 1
        }
        return result
    }

    private static func isBlockScalarHeader(_ s: String) -> Bool {
        guard let first = s.first, first == "|" || first == ">" else { return false }
        let rest = s.dropFirst()
        if rest.isEmpty { return true }
        // Optional chomping indicator (-/+) and/or single-digit indentation indicator (1-9) in either order.
        var sawChomp = false, sawIndent = false
        for ch in rest {
            if (ch == "-" || ch == "+"), !sawChomp { sawChomp = true }
            else if ch >= "1" && ch <= "9", !sawIndent { sawIndent = true }
            else { return false }
        }
        return true
    }

    // Strips a YAML inline comment (`#` at start or preceded by space/tab) from an unquoted scalar.
    private static func stripInlineComment(_ raw: String) -> String {
        var prevSpace = true
        for idx in raw.indices {
            let ch = raw[idx]
            if ch == "#" && prevSpace {
                return raw[..<idx].trimmingCharacters(in: .whitespaces)
            }
            prevSpace = (ch == " " || ch == "\t")
        }
        return raw.trimmingCharacters(in: .whitespaces)
    }

    private static func parseYAMLScalar(_ raw: String) -> String? {
        guard !raw.isEmpty else { return "" }
        if raw.hasPrefix("\"") {
            var out = "", escaped = false
            var idx = raw.index(after: raw.startIndex)
            while idx < raw.endIndex {
                let ch = raw[idx]
                if escaped {
                    switch ch {
                    case "n": out.append("\n")
                    case "r": out.append("\r")
                    case "t": out.append("\t")
                    case "\"": out.append("\"")
                    case "\\": out.append("\\")
                    case "/": out.append("/")
                    case "0": out.append("\0")
                    default: out.append(ch)
                    }
                    escaped = false
                } else if ch == "\\" {
                    escaped = true
                } else if ch == "\"" {
                    let tail = raw[raw.index(after: idx)...].trimmingCharacters(in: .whitespaces)
                    return (tail.isEmpty || tail.hasPrefix("#")) ? out : nil
                } else {
                    out.append(ch)
                }
                idx = raw.index(after: idx)
            }
            return nil
        }
        if raw.hasPrefix("'") {
            var out = ""
            var idx = raw.index(after: raw.startIndex)
            while idx < raw.endIndex {
                let ch = raw[idx]
                if ch == "'" {
                    let next = raw.index(after: idx)
                    if next < raw.endIndex && raw[next] == "'" {
                        out.append("'")
                        idx = raw.index(after: next)
                        continue
                    }
                    let tail = raw[next...].trimmingCharacters(in: .whitespaces)
                    return (tail.isEmpty || tail.hasPrefix("#")) ? out : nil
                }
                out.append(ch)
                idx = raw.index(after: idx)
            }
            return nil
        }
        return stripInlineComment(raw)
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
    public var turn: UUID?
    public var batch: UUID?     // a knowledge review meeting's id: its changes are undone together

    public init(id: UUID = UUID(), at: Date = Date(), action: SkillAction, by: SkillAuthor, actor: String? = nil,
                skillID: UUID? = nil, name: String? = nil, items: [SkillHistoryItem], undoes: UUID? = nil, turn: UUID? = nil,
                batch: UUID? = nil) {
        self.id = id
        self.at = at
        self.action = action
        self.by = by
        self.actor = actor
        self.skillID = skillID
        self.name = name
        self.items = items
        self.undoes = undoes
        self.turn = turn
        self.batch = batch
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
            guard case .present(_, let hash, _, let doc) = inspectDiskSkill(name) else { continue }
            let resolved = resolveRecord(name: name, tracked: byName[name], diskHash: hash, tombstones: index.tombstones)
            let desc = doc?.description ?? ""
            out.append(SkillSummary(record: resolved.record, description: desc, externallyModified: resolved.externallyModified))
        }
        return out
    }

    public func read(_ name: String) -> SkillDetail? {
        guard SkillDocument.isValidSlug(name) else { return nil }
        lock.lock(); defer { lock.unlock() }
        guard let index = loadIndex(),
              case .present(let data, let hash, let raw, let doc) = inspectDiskSkill(name) else { return nil }
        let tracked = index.skills.first { $0.name == name }
        let resolved = resolveRecord(name: name, tracked: tracked, diskHash: hash, tombstones: index.tombstones)
        let parsedDoc: SkillDocument
        if let doc {
            parsedDoc = doc
        } else if let raw {
            parsedDoc = SkillDocument(name: name, description: "", body: raw)
        } else if let utf16 = String(data: data, encoding: .utf16) {
            parsedDoc = SkillDocument.parse(utf16) ?? SkillDocument(name: name, description: "", body: utf16)
        } else {
            return nil
        }
        return SkillDetail(record: resolved.record, document: parsedDoc, externallyModified: resolved.externallyModified)
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
    // .needsApproval without modifying disk files, unless `approved` is the skill's content hash the user approved the
    // change against (Inbox, 회의 3/3): then it saves and the skill stays locked; a skill changed since still waits.
    public func save(name: String, description: String, body: String, by: SkillAuthor,
                     id: UUID? = nil, actor: String? = nil, isNew: Bool? = nil, now: Date = Date(), turn: UUID? = nil,
                     batch: UUID? = nil, approved: String? = nil) -> SkillOutcome {
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

        if let id, index.tombstones.contains(where: { $0.id == id }) {
            return .refused(L("삭제된 스킬 ID는 다시 사용할 수 없어요. 복원하려면 되돌리기(Undo)를 사용해 주세요.",
                              "A deleted skill ID cannot be reused. Use Undo to restore it."))
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
            guard unusedSkillFolder(name) else { return occupiedSkillFolder(name) }
        }

        let existingRecord = existingIndex.map { index.skills[$0] }
        let sourceName = existingRecord?.name ?? name
        let disk = inspectDiskSkill(sourceName)
        if case .unreadable(let err) = disk {
            return .refused(saveFailure(err))
        }
        if turn != nil {
            switch disk {
            case .present(_, _, nil, _): return cannotRestore()
            case .missing where existingRecord != nil: return cannotRestore()
            default: break
            }
        }

        // Untracked SKILL.md on disk is treated as user-authored and locked.
        if existingRecord == nil, case .present(_, let diskHash, let diskRaw, _) = disk {
            let synthetic = resolveRecord(name: name, tracked: nil, diskHash: diskHash, tombstones: index.tombstones).record
            if by != .user && approved != diskHash {
                return .needsApproval(synthetic, approvalMessage())
            }
            let doc = SkillDocument(name: name, description: cleanDesc, body: body)
            var tx = FileTransaction(root: root)
            do {
                let written = try tx.writeSkill(doc, to: skillFile(name))
                var updated = synthetic
                updated.contentHash = written.hash
                updated.userLocked = true
                updated.isNew = isNew ?? false
                updated.updatedAt = now
                index.skills.append(updated)
                let before = SkillSnapshot(record: synthetic, markdown: diskRaw)
                let after = SkillSnapshot(record: updated, markdown: written.raw)
                let entry = SkillHistoryEntry(at: now, action: .update, by: by, actor: actor,
                                              skillID: updated.id, name: updated.name,
                                              items: [SkillHistoryItem(before: before, after: after)], turn: turn, batch: batch)
                try persist(index: index, append: entry, tx: &tx)
                tx.commit()
                changed = true
                return turn == nil ? .saved(updated) : .updated([updated])
            } catch {
                tx.rollback()
                return .refused(saveFailure(error))
            }
        }

        if let i = existingIndex {
            let tracked = index.skills[i]
            let effective: SkillRecord
            let priorRaw: String?
            if case .present(_, let diskHash, let diskRaw, _) = disk {
                effective = resolveRecord(name: tracked.name, tracked: tracked, diskHash: diskHash, tombstones: index.tombstones).record
                priorRaw = diskRaw
            } else {
                effective = tracked
                priorRaw = nil
            }
            if effective.userLocked && by != .user && approved != effective.contentHash {
                return .needsApproval(effective, approvalMessage())
            }
            let doc = SkillDocument(name: name, description: cleanDesc, body: body)
            var tx = FileTransaction(root: root)
            do {
                // A rename moves the whole folder, so scripts and notes next to SKILL.md go with it.
                if tracked.name != name {
                    try tx.moveFolder(skillFolder(tracked.name), to: skillFolder(name))
                }
                let written = try tx.writeSkill(doc, to: skillFile(name))
                var updated = effective
                updated.name = name
                updated.contentHash = written.hash
                updated.userLocked = effective.userLocked || by == .user
                // A direct chat save records user ownership. The before snapshot keeps the earlier author.
                if by == .user && turn != nil { updated.createdBy = .user }
                if let isNew { updated.isNew = isNew } else if by == .user { updated.isNew = false }
                updated.updatedAt = now
                index.skills[i] = updated
                let before = SkillSnapshot(record: effective, markdown: priorRaw)
                let after = SkillSnapshot(record: updated, markdown: written.raw)
                let entry = SkillHistoryEntry(at: now, action: .update, by: by, actor: actor,
                                              skillID: updated.id, name: updated.name,
                                              items: [SkillHistoryItem(before: before, after: after)], turn: turn, batch: batch)
                try persist(index: index, append: entry, tx: &tx)
                tx.commit()
                changed = true
                return turn == nil ? .saved(updated) : .updated([updated])
            } catch {
                tx.rollback()
                return .refused(saveFailure(error))
            }
        }

        // New skill.
        guard unusedSkillFolder(name) else { return occupiedSkillFolder(name) }
        let doc = SkillDocument(name: name, description: cleanDesc, body: body)
        var tx = FileTransaction(root: root)
        do {
            let written = try tx.writeSkill(doc, to: skillFile(name))
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
                                          items: [SkillHistoryItem(before: nil, after: after)], turn: turn, batch: batch)
            try persist(index: index, append: entry, tx: &tx)
            tx.commit()
            changed = true
            return .saved(record)
        } catch {
            tx.rollback()
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
        let diskHash: String
        switch inspectDiskSkill(name) {
        case .missing:
            return .refused(L("스킬(\(name))을 찾지 못했어요.", "Skill '\(name)' was not found."))
        case .unreadable(let err):
            return .refused(saveFailure(err))
        case .present(_, let hash, _, _):
            diskHash = hash
        }
        let trackedIndex = index.skills.firstIndex { $0.name == name }
        let beforeRecord = resolveRecord(name: name, tracked: trackedIndex.map { index.skills[$0] },
                                         diskHash: diskHash, tombstones: index.tombstones).record
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
        var tx = FileTransaction(root: root)
        do {
            try persist(index: index, append: entry, tx: &tx)
            tx.commit()
            changed = true
            return .saved(afterRecord)
        } catch {
            tx.rollback()
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
            let diskHash: String
            switch inspectDiskSkill(name) {
            case .missing: continue
            case .unreadable(let err): return .refused(saveFailure(err))
            case .present(_, let hash, _, _): diskHash = hash
            }
            let before = resolveRecord(name: name, tracked: byName[name], diskHash: diskHash, tombstones: index.tombstones).record
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
        var tx = FileTransaction(root: root)
        do {
            try persist(index: index, append: entry, tx: &tx)
            tx.commit()
            changed = true
            return .updated(updatedRecords)
        } catch {
            tx.rollback()
            return .refused(saveFailure(error))
        }
    }

    // The user opened the skill: clears its "new" badge. Not a change of the skill, so no history line (Undo skips it
    // and it never blocks undoing the change that added the skill) and the lock and content stay as they are.
    @discardableResult public func markSeen(_ name: String) -> Bool {
        var changed = false
        defer { if changed { onChange?() } }
        lock.lock(); defer { lock.unlock() }
        guard var index = loadIndex(), let i = index.skills.firstIndex(where: { $0.name == name }), index.skills[i].isNew else { return false }
        index.skills[i].isNew = false
        var tx = FileTransaction(root: root)
        do {
            try tx.writePrivateFile(try Self.prettyEncoder.encode(index), to: indexURL)
            tx.commit()
            changed = true
            return true
        } catch {
            tx.rollback()
            return false
        }
    }

    public func delete(_ name: String, by: SkillAuthor = .user,
                       actor: String? = nil, now: Date = Date(), turn: UUID? = nil) -> SkillOutcome {
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
        let disk = inspectDiskSkill(name)
        if case .unreadable(let err) = disk {
            return .refused(saveFailure(err))
        }
        let effective: SkillRecord
        let priorRaw: String?
        switch disk {
        case .present(_, let hash, let raw, _):
            effective = resolveRecord(name: name, tracked: trackedIndex.map { index.skills[$0] },
                                      diskHash: hash, tombstones: index.tombstones).record
            priorRaw = raw
        case .missing:
            guard let i = trackedIndex else {
                return .refused(L("스킬(\(name))을 찾지 못했어요.", "Skill '\(name)' was not found."))
            }
            effective = index.skills[i]
            priorRaw = nil
        case .unreadable(let err):
            return .refused(saveFailure(err))
        }
        if effective.userLocked && by != .user {
            return .needsApproval(effective, approvalMessage())
        }
        if turn != nil && priorRaw == nil { return cannotRestore() }
        if let i = trackedIndex { index.skills.remove(at: i) }
        let tombstone = SkillTombstone(id: effective.id, name: effective.name, deletedAt: now)
        index.tombstones.append(tombstone)
        let before = SkillSnapshot(record: effective, markdown: priorRaw)
        let entry = SkillHistoryEntry(at: now, action: .delete, by: by, actor: actor,
                                      skillID: effective.id, name: effective.name,
                                      items: [SkillHistoryItem(before: before, after: nil, tombstone: tombstone)], turn: turn)
        var tx = FileTransaction(root: root)
        do {
            // History keeps only SKILL.md, so files next to it stay for Undo to bring back the whole skill.
            try tx.removeSkill(skillFile(name), preservingOtherFiles: true)
            try persist(index: index, append: entry, tx: &tx)
            tx.commit()
            changed = true
            return .deleted(tombstone)
        } catch {
            tx.rollback()
            return .refused(saveFailure(error))
        }
    }

    // A chat's Undo addresses its own change, provided no active newer change affects the same skills.
    public func undo(by: SkillAuthor = .user, actor: String? = nil, now: Date = Date(), change: UUID? = nil) -> SkillOutcome {
        var changed = false
        defer { if changed { onChange?() } }
        lock.lock(); defer { lock.unlock() }
        let outcome = undoLocked(by: by, actor: actor, now: Self.isoSecond(now), change: change)
        if case .undone = outcome { changed = true }
        return outcome
    }

    // Why a meeting's changes cannot all be undone now (nil: they can, or there are none): a later change outside the
    // meeting touched one of its skills, or the store cannot be read. Lets a caller check every store before undoing any.
    public func undoBlock(batch: UUID) -> String? {
        lock.lock(); defer { lock.unlock() }
        return batchBlock(batch)
    }

    // Undoes every active change of one meeting, newest first, after checking that no later change outside it touched
    // the same skills. `.updated` lists the restored records (none when every change was already undone one by one).
    public func undo(batch: UUID, by: SkillAuthor = .user, actor: String? = nil, now: Date = Date()) -> SkillOutcome {
        var changed = false
        defer { if changed { onChange?() } }
        lock.lock(); defer { lock.unlock() }
        if let block = batchBlock(batch) { return .refused(block) }
        guard let history = loadHistory() else {
            return .refused(L("스킬 저장소를 읽지 못해서 되돌리지 못했어요.", "The skill store could not be read."))
        }
        let undone = Self.undoneIDs(history)
        let targets = history.filter { $0.batch == batch && $0.action != .undo && !undone.contains($0.id) }
        var restored: [SkillRecord] = []
        for entry in targets.reversed() {
            let outcome = undoLocked(by: by, actor: actor, now: Self.isoSecond(now), change: entry.id)
            guard case .undone(let done) = outcome else { return outcome }
            changed = true
            restored += done.items.compactMap { $0.after?.record }
        }
        return .updated(restored)
    }

    private func batchBlock(_ batch: UUID) -> String? {
        guard let history = loadHistory(), let index = loadIndex() else {
            return L("스킬 저장소를 읽지 못해서 되돌리지 못했어요.", "The skill store could not be read.")
        }
        let undone = Self.undoneIDs(history)
        let active = history.filter { $0.action != .undo && !undone.contains($0.id) }
        guard let first = active.firstIndex(where: { $0.batch == batch }) else { return nil }
        let mine = active.filter { $0.batch == batch }
        // What undoLocked checks before each change, for all of them up front: the file each change left is still on
        // disk as it left it (readable, not edited outside), and a renamed skill's old name is free again.
        var left: [UUID: SkillSnapshot] = [:]
        for item in mine.flatMap(\.items) {
            if let after = item.after { left[after.record.id] = after } else if let before = item.before { left[before.record.id] = nil }
            if let before = item.before, let after = item.after, before.record.name != after.record.name,
               index.skills.contains(where: { $0.name == before.record.name && $0.id != before.record.id }) || !unusedSkillFolder(before.record.name) {
                return L("같은 이름의 스킬(\(before.record.name))이 이미 있어 되돌릴 수 없어요.", "A skill named '\(before.record.name)' already exists.")
            }
        }
        for after in left.values {
            switch inspectDiskSkill(after.record.name) {
            case .unreadable(let error): return saveFailure(error)
            case .present(_, let hash, _, _) where hash != after.record.contentHash:
                return L("스킬(\(after.record.name))이 밖에서 직접 수정되어 되돌릴 수 없어요.",
                         "Skill '\(after.record.name)' was edited externally and cannot be undone automatically.")
            default: break
            }
        }
        let records = mine.flatMap { $0.items.flatMap { [$0.before?.record, $0.after?.record].compactMap { $0 } } }
        let ids = Set(records.map(\.id)), names = Set(records.map(\.name))
        let later = active[(first + 1)...].filter { $0.batch != batch }
        if let entry = later.first(where: { entry in
            entry.items.contains { [$0.before?.record, $0.after?.record].compactMap { $0 }.contains { ids.contains($0.id) || names.contains($0.name) } }
        }) {
            let name = entry.name.map { " (\($0))" } ?? ""
            return L("회의 뒤에 같은 스킬이 바뀌어서 되돌리지 않았어요\(name).", "A skill this meeting changed was changed again later\(name), so nothing was undone.")
        }
        return nil
    }

    private func undoLocked(by: SkillAuthor, actor: String?, now: Date, change: UUID?) -> SkillOutcome {
        guard var index = loadIndex(), let history = loadHistory() else {
            return .refused(L("스킬 저장소를 읽지 못해서 되돌리지 못했어요.", "The skill store could not be read."))
        }
        let undone = Self.undoneIDs(history)
        let active = history.filter { $0.action != .undo && !undone.contains($0.id) }
        guard let position = active.lastIndex(where: { change == nil || $0.id == change }) else {
            return .refused(L("되돌릴 변경이 없어요.", "Nothing to undo."))
        }
        let target = active[position]
        let records = target.items.flatMap { [$0.before?.record, $0.after?.record].compactMap { $0 } }
        let ids = Set(records.map(\.id)), names = Set(records.map(\.name))
        if active.dropFirst(position + 1).contains(where: { entry in
            entry.items.contains { item in
                [item.before?.record, item.after?.record].compactMap { $0 }.contains {
                    ids.contains($0.id) || names.contains($0.name)
                }
            }
        }) {
            return .refused(L("그 뒤 같은 스킬이 바뀌었어요.", "The same skill changed after this edit."))
        }

        let isToggleUndo = target.action == .enable || target.action == .disable || target.action == .setAllEnabled

        // Pre-flight checks before touching disk so a refused or unapproved undo writes nothing.
        for item in target.items {
            switch (item.before, item.after) {
            case (nil, let after?):
                let tracked = index.skills.first { $0.id == after.record.id }
                switch inspectDiskSkill(after.record.name) {
                case .unreadable(let err):
                    return .refused(saveFailure(err))
                case .present(_, let hash, _, _):
                    let effective = resolveRecord(name: after.record.name, tracked: tracked ?? after.record,
                                                  diskHash: hash, tombstones: index.tombstones).record
                    if by != .user && (target.by == .user || effective.userLocked || after.record.userLocked) {
                        return .needsApproval(effective, approvalMessage())
                    }
                    if hash != after.record.contentHash {
                        return .refused(L("스킬(\(after.record.name))이 밖에서 직접 수정되어 되돌릴 수 없어요.",
                                          "Skill '\(after.record.name)' was edited externally and cannot be undone automatically."))
                    }
                case .missing:
                    let effective = tracked ?? after.record
                    if by != .user && (target.by == .user || effective.userLocked || after.record.userLocked) {
                        return .needsApproval(effective, approvalMessage())
                    }
                }

            case (let before?, let after?):
                let tracked = index.skills.first { $0.id == after.record.id }
                switch inspectDiskSkill(after.record.name) {
                case .unreadable(let err):
                    return .refused(saveFailure(err))
                case .present(_, let hash, _, _):
                    let effective = resolveRecord(name: after.record.name, tracked: tracked ?? after.record,
                                                  diskHash: hash, tombstones: index.tombstones).record
                    if by != .user && (target.by == .user || effective.userLocked || before.record.userLocked || after.record.userLocked) {
                        return .needsApproval(effective, approvalMessage())
                    }
                    if !isToggleUndo && hash != after.record.contentHash {
                        return .refused(L("스킬(\(after.record.name))이 밖에서 직접 수정되어 되돌릴 수 없어요.",
                                          "Skill '\(after.record.name)' was edited externally and cannot be undone automatically."))
                    }
                case .missing:
                    let effective = tracked ?? after.record
                    if by != .user && (target.by == .user || effective.userLocked || before.record.userLocked || after.record.userLocked) {
                        return .needsApproval(effective, approvalMessage())
                    }
                }
                if !isToggleUndo {
                    if before.markdown == nil {
                        return .refused(L("이전 파일 내용을 복원할 수 없어 되돌리지 않았어요.",
                                          "The previous file content cannot be restored."))
                    }
                    if before.record.name != after.record.name,
                       (index.skills.contains(where: { $0.name == before.record.name && $0.id != before.record.id })
                        || !unusedSkillFolder(before.record.name)) {
                        return .refused(L("같은 이름의 스킬(\(before.record.name))이 이미 있어 되돌릴 수 없어요.",
                                          "A skill named '\(before.record.name)' already exists."))
                    }
                }

            case (let before?, nil):
                if by != .user && (target.by == .user || before.record.userLocked) {
                    return .needsApproval(before.record, approvalMessage())
                }
                if before.markdown == nil {
                    return .refused(L("이전 파일 내용을 복원할 수 없어 되돌리지 않았어요.",
                                      "The previous file content cannot be restored."))
                }
                if index.skills.contains(where: { $0.name == before.record.name })
                    || FileManager.default.fileExists(atPath: skillFile(before.record.name).path) {
                    return .refused(L("같은 이름의 스킬(\(before.record.name))이 이미 있어 복원할 수 없어요.",
                                      "A skill named '\(before.record.name)' already exists."))
                }

            case (nil, nil):
                break
            }
        }

        // Apply each item in reverse inside a rollback-capable transaction.
        var tx = FileTransaction(root: root)
        var reverseItems: [SkillHistoryItem] = []
        do {
            for item in target.items {
                switch (item.before, item.after) {
                case (nil, let after?):
                    index.skills.removeAll { $0.id == after.record.id }
                    try tx.removeSkill(skillFile(after.record.name), preservingOtherFiles: target.turn != nil)
                    reverseItems.append(SkillHistoryItem(before: after, after: nil))

                case (let before?, let after?):
                    var restored = before.record
                    if !isToggleUndo {
                        if before.record.name != after.record.name {
                            try tx.moveFolder(skillFolder(after.record.name), to: skillFolder(before.record.name))
                        }
                        if let md = before.markdown {
                            try tx.writeRaw(md, to: skillFile(before.record.name))
                        }
                        let i = index.skills.firstIndex(where: { $0.id == before.record.id })
                        // A skill the user has already looked at does not get its "new" badge back.
                        if let i, !index.skills[i].isNew { restored.isNew = false }
                        if let i { index.skills[i] = restored } else { index.skills.append(restored) }
                    } else {
                        // Enable/disable undo: preserve any newer disk edits while restoring enabled state.
                        if let i = index.skills.firstIndex(where: { $0.id == before.record.id }) {
                            var rec = index.skills[i]
                            if case .present(_, let hash, _, _) = inspectDiskSkill(rec.name), hash != rec.contentHash {
                                rec.userLocked = true
                                rec.contentHash = hash
                            }
                            rec.enabled = before.record.enabled
                            rec.updatedAt = before.record.updatedAt
                            index.skills[i] = rec
                        } else {
                            index.skills.append(before.record)
                        }
                    }
                    reverseItems.append(SkillHistoryItem(before: after, after: SkillSnapshot(record: restored, markdown: before.markdown)))

                case (let before?, nil):
                    if let md = before.markdown {
                        try tx.writeRaw(md, to: skillFile(before.record.name))
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
            try persist(index: index, append: undoEntry, tx: &tx)
            tx.commit()
            return .undone(undoEntry)
        } catch {
            tx.rollback()
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

    private enum DiskSkill {
        case missing
        case present(data: Data, hash: String, raw: String?, document: SkillDocument?)
        case unreadable(Error)
    }

    // Reads raw bytes and computes SHA-256 before attempting UTF-8 decoding so non-UTF-8 external edits
    // (e.g. UTF-16) are never mistaken for missing files.
    private func inspectDiskSkill(_ name: String) -> DiskSkill {
        let url = skillFile(name)
        guard FileManager.default.fileExists(atPath: url.path) else { return .missing }
        do {
            let data = try Data(contentsOf: url)
            let hash = SkillDocument.hash(data)
            let raw = String(data: data, encoding: .utf8)
            let doc = raw.flatMap { SkillDocument.parse($0) }
            return .present(data: data, hash: hash, raw: raw, document: doc)
        } catch {
            return .unreadable(error)
        }
    }

    private func approvalMessage() -> String {
        L("Inbox 승인 필요: 사용자가 만들거나 수정한 스킬은 AI가 바로 덮어쓸 수 없어요.",
          "Inbox approval required: AI cannot overwrite a user-locked skill directly.")
    }

    private func unusedSkillFolder(_ name: String) -> Bool {
        let folder = skillFolder(name).path, fm = FileManager.default
        return !fm.fileExists(atPath: folder) || (try? fm.contentsOfDirectory(atPath: folder).isEmpty) == true
    }

    private func occupiedSkillFolder(_ name: String) -> SkillOutcome {
        .refused(L("스킬 폴더(\(name))에 파일이 남아 있어요. 파일을 옮기거나 다른 이름을 써 주세요.",
                   "Files remain in the skill folder '\(name)'. Move them or use a different skill name."))
    }

    private func cannotRestore() -> SkillOutcome {
        .refused(L("이전 파일 내용을 복원할 수 없어서 스킬을 바꾸지 않았어요.",
                   "The skill was left as it is because the previous file could not be restored."))
    }

    private func saveFailure(_ error: Error) -> String {
        L("스킬을 저장하지 못했어요: ", "Could not save the skill: ") + error.localizedDescription
    }

    private func resolveRecord(name: String, tracked: SkillRecord?, diskHash: String,
                               tombstones: [SkillTombstone]) -> (record: SkillRecord, externallyModified: Bool) {
        if var record = tracked {
            if record.contentHash != diskHash {
                record.userLocked = true
                record.contentHash = diskHash
                return (record, true)
            }
            return (record, false)
        }
        let synthetic = SkillRecord(
            id: deterministicExternalID(name: name, avoiding: Set(tombstones.map(\.id))),
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

    // Stable UUID for an untracked external folder before it is persisted into skills.json; avoids tombstoned IDs.
    private func deterministicExternalID(name: String, avoiding: Set<UUID>) -> UUID {
        var salt = 0
        while true {
            let key = salt == 0 ? "external-skill:\(root.path)/\(name)" : "external-skill:\(root.path)/\(name)#\(salt)"
            let digest = Array(SHA256.hash(data: Data(key.utf8)))
            var bytes = Array(digest.prefix(16))
            bytes[6] = (bytes[6] & 0x0F) | 0x50
            bytes[8] = (bytes[8] & 0x3F) | 0x80
            let tuple = (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                         bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15])
            let id = UUID(uuid: tuple)
            if !avoiding.contains(id) { return id }
            salt += 1
        }
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

    private func persist(index: SkillIndexData, append entry: SkillHistoryEntry, tx: inout FileTransaction) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let row = try Self.lineEncoder.encode(entry)
        let indexData = try Self.prettyEncoder.encode(index)
        try tx.appendHistory(row, to: historyURL)
        try tx.writePrivateFile(indexData, to: indexURL)
    }

    private struct FileTransaction {
        let root: URL
        private var rollbacks: [() -> Void] = []
        private var cleanups: [() -> Void] = []

        mutating func writeSkill(_ document: SkillDocument, to url: URL) throws -> (raw: String, hash: String) {
            let raw = document.render()
            let data = Data(raw.utf8)
            try writePrivateFile(data, to: url)
            return (raw, SkillDocument.hash(data))
        }

        mutating func writeRaw(_ text: String, to url: URL) throws {
            try writePrivateFile(Data(text.utf8), to: url)
        }

        mutating func writePrivateFile(_ data: Data, to url: URL) throws {
            let fm = FileManager.default
            let folder = url.deletingLastPathComponent()
            let folderExisted = fm.fileExists(atPath: folder.path)
            let fileExisted = fm.fileExists(atPath: url.path)
            let priorData = fileExisted ? try Data(contentsOf: url) : nil

            if !folderExisted {
                try fm.createDirectory(at: folder, withIntermediateDirectories: true,
                                       attributes: [.posixPermissions: 0o700])
            }
            do {
                try SkillDirectory.writePrivate(data, to: url)
            } catch {
                if let priorData {
                    try? SkillDirectory.writePrivate(priorData, to: url)
                } else {
                    try? fm.removeItem(at: url)
                    if !folderExisted { try? fm.removeItem(at: folder) }
                }
                throw error
            }
            rollbacks.append {
                if let priorData {
                    try? SkillDirectory.writePrivate(priorData, to: url)
                } else {
                    try? fm.removeItem(at: url)
                    if !folderExisted { try? fm.removeItem(at: folder) }
                }
            }
        }

        // Chat history snapshots the skill document. Keep any companion files so Undo can restore the whole skill.
        mutating func removeSkill(_ file: URL, preservingOtherFiles: Bool) throws {
            let folder = file.deletingLastPathComponent()
            let fm = FileManager.default
            if preservingOtherFiles, fm.fileExists(atPath: folder.path),
               try fm.contentsOfDirectory(atPath: folder.path).contains(where: { $0 != file.lastPathComponent }) {
                try removeItem(file)
            } else {
                try removeItem(folder)
            }
        }

        // Moves a skill folder onto an unused name (an empty folder there is set aside first).
        mutating func moveFolder(_ from: URL, to: URL) throws {
            let fm = FileManager.default
            guard fm.fileExists(atPath: from.path) else { return }
            try removeItem(to)
            try fm.moveItem(at: from, to: to)
            rollbacks.append { try? fm.moveItem(at: to, to: from) }
        }

        mutating func removeItem(_ item: URL) throws {
            let fm = FileManager.default
            guard fm.fileExists(atPath: item.path) else { return }
            try fm.createDirectory(at: root, withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
            let backup = root.appendingPathComponent(".rollback-\(UUID().uuidString)", isDirectory: true)
            try fm.moveItem(at: item, to: backup)
            rollbacks.append {
                if fm.fileExists(atPath: item.path) { try? fm.removeItem(at: item) }
                try? fm.moveItem(at: backup, to: item)
            }
            cleanups.append {
                try? fm.removeItem(at: backup)
            }
        }

        mutating func appendHistory(_ line: Data, to file: URL) throws {
            let state = try SkillDirectory.appendLine(line, to: file)
            rollbacks.append {
                let fm = FileManager.default
                if !state.existed {
                    try? fm.removeItem(at: file)
                } else if let handle = try? FileHandle(forUpdating: file) {
                    defer { try? handle.close() }
                    try? handle.truncate(atOffset: state.offset)
                }
            }
        }

        mutating func commit() {
            rollbacks.removeAll()
            for cleanup in cleanups { cleanup() }
            cleanups.removeAll()
        }

        mutating func rollback() {
            cleanups.removeAll()
            for action in rollbacks.reversed() { action() }
            rollbacks.removeAll()
        }
    }

    private static func writePrivate(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private static func appendLine(_ line: Data, to file: URL) throws -> (existed: Bool, offset: UInt64) {
        let existed = FileManager.default.fileExists(atPath: file.path)
        if !existed {
            guard FileManager.default.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
        let handle = try FileHandle(forUpdating: file)
        defer { try? handle.close() }
        // Truncate any incomplete trailing line of arbitrary length cut off by a crash before appending.
        let end = try handle.seekToEnd()
        var writeOffset = end
        if end > 0 {
            try handle.seek(toOffset: end - 1)
            let lastByte = try handle.read(upToCount: 1)
            if lastByte?.first != 0x0A {
                let chunkSize: UInt64 = 64 * 1024
                var cursor = end
                var keep: UInt64 = 0
                while cursor > 0 {
                    let start = cursor > chunkSize ? cursor - chunkSize : 0
                    try handle.seek(toOffset: start)
                    let chunk = try handle.read(upToCount: Int(cursor - start)) ?? Data()
                    if let nl = chunk.lastIndex(of: 0x0A) {
                        keep = start + UInt64(nl - chunk.startIndex) + 1
                        break
                    }
                    cursor = start
                }
                try handle.truncate(atOffset: keep)
                writeOffset = keep
            }
            try handle.seek(toOffset: writeOffset)
        }
        var payload = line
        payload.append(0x0A)
        try handle.write(contentsOf: payload)
        return (existed, writeOffset)
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
                     id: UUID? = nil, actor: String? = nil, isNew: Bool? = nil, now: Date = Date(), turn: UUID? = nil,
                     batch: UUID? = nil, approved: String? = nil) -> SkillOutcome {
        directory(project).save(name: name, description: description, body: body, by: by, id: id, actor: actor, isNew: isNew,
                                now: now, turn: turn, batch: batch, approved: approved)
    }

    public func setEnabled(_ name: String, _ enabled: Bool, project: String, by: SkillAuthor = .user,
                           actor: String? = nil, now: Date = Date()) -> SkillOutcome {
        directory(project).setEnabled(name, enabled, by: by, actor: actor, now: now)
    }

    public func setAllEnabled(_ enabled: Bool, project: String, by: SkillAuthor = .user,
                              actor: String? = nil, now: Date = Date()) -> SkillOutcome {
        directory(project).setAllEnabled(enabled, by: by, actor: actor, now: now)
    }

    @discardableResult public func markSeen(_ name: String, project: String) -> Bool { directory(project).markSeen(name) }

    public func delete(_ name: String, project: String, by: SkillAuthor = .user,
                       actor: String? = nil, now: Date = Date(), turn: UUID? = nil) -> SkillOutcome {
        directory(project).delete(name, by: by, actor: actor, now: now, turn: turn)
    }

    public func undo(project: String, by: SkillAuthor = .user, actor: String? = nil, now: Date = Date(), change: UUID? = nil) -> SkillOutcome {
        directory(project).undo(by: by, actor: actor, now: now, change: change)
    }

    public func undoBlock(batch: UUID, project: String) -> String? { directory(project).undoBlock(batch: batch) }
    public func undo(batch: UUID, project: String, by: SkillAuthor = .user, actor: String? = nil, now: Date = Date()) -> SkillOutcome {
        directory(project).undo(batch: batch, by: by, actor: actor, now: now)
    }
}
