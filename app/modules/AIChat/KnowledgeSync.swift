import Foundation
import Combine
import AIAccounts
import AIProjects

// "Sync skills & memory" (연동 1/3): global skills, user memory and the skills' on/off state go to the folder
// DeviceSync uses (iCloud Drive/AI Illuminati Sync by default), on their own switch (DeviceSyncSettings.syncsKnowledge):
//   <folder>/knowledge/host.json                         the Mac that holds the knowledge review meetings: the first
//                                                        one to turn this on (never overwritten)
//   <folder>/knowledge/<deviceID>/changes.jsonl          one KnowledgeChange per add, modify, delete (tombstone),
//                                                        enable and disable, with the hash it was made on
//   <folder>/knowledge/<deviceID>/skills/<id>/SKILL.md   each skill as this Mac last wrote it
//   <folder>/knowledge/<deviceID>/state.json             what the lines add up to: a pass writes only the difference
// Each Mac writes only its own folder. Project skills and project memory stay on their Mac (projects differ per Mac).
// Enterprise skills go too (DeviceSync's includeSchool is for chats); user memory is never saved from Enterprise chats.
// Without state.json (the first pass) everything goes out once as `add` lines marked `initial`.
// A pass compares the stores with state.json, so changes made while it was off or the app was closed go out too;
// who made a change comes from the skills' history and from MemoryItem/MemoryChange.meeting.

struct KnowledgeChange: Codable, Equatable {
    enum Kind: String, Codable { case skill, memory, profile }
    enum Op: String, Codable { case add, modify, delete, enable, disable }
    var kind: Kind
    var op: Op
    var id: String          // the skill's or fact's UUID; "profile" for the profile
    var at: Date
    var by: SkillAuthor
    var base: String?       // the hash it was made on (nil: new)
    var hash: String?       // the hash after it (nil: deleted)
    var name: String?       // a skill's name (its text is skills/<id>/SKILL.md)
    var enabled: Bool?      // a skill's on/off after it
    var text: String?       // a fact's or the profile's text after it
    var initial: Bool?      // part of the first full export
    var device: String
}

struct KnowledgeState: Codable, Equatable {
    struct Skill: Codable, Equatable { var name: String; var hash: String; var enabled: Bool }
    var skills: [String: Skill] = [:]
    var memory: [String: String] = [:]   // fact id → text hash
    var profile: String?                 // nil: no profile
}

struct KnowledgeHost: Codable, Equatable {
    var device: String
    var name: String
    var since: Date
}

final class KnowledgeSync {
    static let shared = KnowledgeSync(sync: DeviceSync.shared)

    // Where a pass writes, worked out on the main thread (DeviceSync's settings live there); nil: off or no folder.
    struct Target { var folder: URL; var name: String }

    let deviceID: String
    private let sync: DeviceSync
    private let skills: SkillStore
    private let memory: () -> MemoryData
    private let io = DispatchQueue(label: "knowledge-sync")
    private var subscriptions: [AnyCancellable] = []
    private var scheduled: DispatchWorkItem?
    static let delay: TimeInterval = 3   // several changes in a row become one pass

    init(sync: DeviceSync, skills: SkillStore = .shared, memory: @escaping () -> MemoryData = { MemoryStore.shared.snapshot }) {
        self.sync = sync
        self.deviceID = sync.deviceID
        self.skills = skills
        self.memory = memory
    }

    static func folder(_ sync: URL) -> URL { sync.appendingPathComponent("knowledge") }
    static func hostFile(_ sync: URL) -> URL { folder(sync).appendingPathComponent("host.json") }
    func myFolder(_ sync: URL) -> URL { Self.folder(sync).appendingPathComponent(deviceID) }

    var target: Target? {
        guard sync.settings.syncsKnowledge, sync.folderAvailable else { return nil }
        return Target(folder: sync.folder, name: sync.deviceName)
    }

    // The app only (DeviceSync.start): a pass after skill, memory or settings changes.
    func start() {
        guard subscriptions.isEmpty else { return }
        subscriptions = [
            skills.$revision.dropFirst().sink { [weak self] _ in self?.schedule() },
            MemoryStore.shared.$data.dropFirst().sink { [weak self] _ in self?.schedule() },
            sync.$settings.sink { [weak self] _ in DispatchQueue.main.async { self?.schedule() } },   // after didSet
        ]
    }

    private func schedule() {
        scheduled?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, let target = self.target else { return }
            self.io.async { self.pass(target) }
        }
        scheduled = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.delay, execute: work)
    }

    // One pass now (tests; the app goes through schedule): the number of lines written, nil when off or not written.
    @discardableResult
    func syncNow(now: Date = Date()) -> Int? {
        guard let target else { return nil }
        return io.sync { pass(target, now: now) }
    }

    @discardableResult
    private func pass(_ target: Target, now: Date = Date()) -> Int? {
        let fm = FileManager.default
        let mine = myFolder(target.folder)
        do { try fm.createDirectory(at: mine.appendingPathComponent("skills"), withIntermediateDirectories: true) } catch { return nil }
        claimHost(target, now: now)
        let stateFile = mine.appendingPathComponent("state.json")
        let old = (try? Data(contentsOf: stateFile)).flatMap { try? Self.decoder().decode(KnowledgeState.self, from: $0) }
        let initial: Bool? = old == nil ? true : nil
        let was = old ?? KnowledgeState()
        var state = KnowledgeState()
        var lines: [KnowledgeChange] = []
        func line(_ kind: KnowledgeChange.Kind, _ op: KnowledgeChange.Op, _ id: String, at: Date, by: SkillAuthor, base: String?,
                  hash: String?, name: String? = nil, enabled: Bool? = nil, text: String? = nil) {
            lines.append(KnowledgeChange(kind: kind, op: op, id: id, at: at, by: by, base: base, hash: hash, name: name,
                                         enabled: enabled, text: text, initial: initial, device: deviceID))
        }
        func skillFolder(_ id: String) -> URL { mine.appendingPathComponent("skills").appendingPathComponent(id) }

        // Skills: the file first, so a line never names a SKILL.md that is not there.
        let history = skills.history(), listed = skills.list()
        for summary in listed {
            // One that cannot be read now stays as it was written, not a delete.
            let id = summary.id.uuidString
            guard let detail = skills.read(summary.name) else { state.skills[id] = was.skills[id]; continue }
            let text = detail.document.render()
            let current = KnowledgeState.Skill(name: summary.name, hash: SkillDocument.hash(text), enabled: detail.record.enabled)
            let before = was.skills[id]
            let file = skillFolder(id).appendingPathComponent("SKILL.md")
            if before?.hash != current.hash || !fm.fileExists(atPath: file.path) {
                do {
                    try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try Data(text.utf8).write(to: file, options: .atomic)
                } catch { if let before { state.skills[id] = before }; continue }
            }
            state.skills[id] = current
            let (by, at) = Self.author(summary, detail.record, history)
            if before?.hash != current.hash {
                line(.skill, before == nil ? .add : .modify, id, at: at, by: by, base: before?.hash, hash: current.hash, name: current.name, enabled: current.enabled)
            }
            if let before, before.enabled != current.enabled {
                line(.skill, current.enabled ? .enable : .disable, id, at: at, by: by, base: current.hash, hash: current.hash, name: current.name, enabled: current.enabled)
            }
        }
        let tombstones = skills.tombstones()
        for (id, before) in was.skills.sorted(by: { $0.key < $1.key }) where state.skills[id] == nil {
            // An unreadable skills.json lists nothing: without a tombstone, an empty list is not taken as every skill deleted.
            guard !listed.isEmpty || tombstones.contains(where: { $0.id.uuidString == id }) else { state.skills[id] = before; continue }
            let deleted = history.last { entry in entry.items.contains { $0.after == nil && $0.before?.record.id.uuidString == id } }
            let at = tombstones.last { $0.id.uuidString == id }?.deletedAt ?? deleted?.at ?? now
            line(.skill, .delete, id, at: at, by: deleted?.by ?? .user, base: before.hash, hash: nil, name: before.name)
            try? fm.removeItem(at: skillFolder(id))
        }

        // Memory: the profile and each fact. A fact without `meeting` is the user's, typed or asked for (Memory.swift).
        let data = memory()
        let profile = data.profile.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : data.profile
        state.profile = profile.map { SkillDocument.hash($0) }
        if state.profile != was.profile {
            line(.profile, profile == nil ? .delete : was.profile == nil ? .add : .modify, "profile", at: now, by: .user,
                 base: was.profile, hash: state.profile, text: profile)
        }
        for item in data.items {
            let id = item.id.uuidString, hash = SkillDocument.hash(item.text)
            state.memory[id] = hash
            guard let before = was.memory[id] else {
                line(.memory, .add, id, at: item.createdAt, by: item.meeting == nil ? .user : .meeting, base: nil, hash: hash, text: item.text)
                continue
            }
            guard before != hash else { continue }
            let change = data.history.last { $0.old.id == item.id && $0.new == item.text }
            line(.memory, .modify, id, at: change?.at ?? now, by: change?.meeting == nil ? .user : .meeting, base: before, hash: hash, text: item.text)
        }
        for (id, before) in was.memory.sorted(by: { $0.key < $1.key }) where state.memory[id] == nil {
            let change = data.history.last { $0.old.id.uuidString == id && $0.new == nil }
            line(.memory, .delete, id, at: change?.at ?? now, by: change?.meeting == nil ? .user : .meeting, base: before, hash: nil)
        }

        // The lines, then the state they add up to: a pass cut short repeats its lines rather than losing them.
        if !lines.isEmpty {
            let encoder = Self.encoder(); encoder.outputFormatting = [.sortedKeys]
            var chunk = Data()
            for change in lines { guard let row = try? encoder.encode(change) else { continue }; chunk.append(row); chunk.append(10) }
            guard Self.append(chunk, to: mine.appendingPathComponent("changes.jsonl")) else { return nil }
        }
        if old == nil || state != was {
            guard let encoded = try? Self.encoder().encode(state), (try? encoded.write(to: stateFile, options: .atomic)) != nil else { return nil }
        }
        return lines.count
    }

    // Who made the skill as it is now: its latest history line; an edit outside the app is the user's.
    static func author(_ summary: SkillSummary, _ record: SkillRecord, _ history: [SkillHistoryEntry]) -> (SkillAuthor, Date) {
        if summary.externallyModified { return (.user, record.updatedAt) }
        let latest = history.last { entry in entry.items.contains { $0.after?.record.id == record.id } }
        return latest.map { ($0.by, $0.at) } ?? (record.createdBy, record.updatedAt)
    }

    // The first Mac to turn this on holds the review meetings; a host.json already there stays as it is.
    private func claimHost(_ target: Target, now: Date) {
        let file = Self.hostFile(target.folder)
        guard !FileManager.default.fileExists(atPath: file.path),
              let data = try? Self.encoder().encode(KnowledgeHost(device: deviceID, name: target.name, since: now)) else { return }
        try? data.write(to: file, options: .withoutOverwriting)
    }

    static func host(_ sync: URL) -> KnowledgeHost? {
        (try? Data(contentsOf: hostFile(sync))).flatMap { try? decoder().decode(KnowledgeHost.self, from: $0) }
    }

    private static func append(_ chunk: Data, to file: URL) -> Bool {
        if !FileManager.default.fileExists(atPath: file.path) { return (try? chunk.write(to: file, options: .atomic)) != nil }
        guard let handle = try? FileHandle(forWritingTo: file) else { return false }
        defer { try? handle.close() }
        do { try handle.seekToEnd(); try handle.write(contentsOf: chunk); return true } catch { return false }
    }

    static func encoder() -> JSONEncoder { DeviceSync.encoder() }
    static func decoder() -> JSONDecoder { DeviceSync.decoder() }
}
