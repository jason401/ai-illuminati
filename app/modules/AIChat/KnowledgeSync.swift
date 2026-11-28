import Foundation
import Combine
import AIAccounts
import AIProjects

// "Sync skills & memory" (연동 1/3): global skills, user memory and the skills' on/off state go to the folder
// DeviceSync uses (iCloud Drive/AI Illuminati Sync by default), on their own switch (DeviceSyncSettings.syncsKnowledge):
//   <folder>/knowledge/host.json                         the Mac that holds the knowledge review meetings: the first
//                                                        one to turn this on, until it is quiet for a week (KnowledgeMerge.swift)
//   <folder>/knowledge/<deviceID>/device.json            this Mac's name, when it started syncing and last passed
//   <folder>/knowledge/<deviceID>/candidates.jsonl       its global candidate inbox, for the review Mac
//   <folder>/knowledge/<deviceID>/changes.jsonl          one KnowledgeChange per add, modify, delete (tombstone),
//                                                        enable and disable, with the hash it was made on
//   <folder>/knowledge/<deviceID>/skills/<id>/SKILL.md   each skill as this Mac last wrote it
//   <folder>/knowledge/<deviceID>/state.json             what the lines add up to: a pass writes only the difference
// Each Mac writes only its own folder (and host.json); it applies the other Macs' lines itself (KnowledgeMerge.swift). Project skills and project memory stay on their Mac (projects differ per Mac).
// Enterprise skills go too (DeviceSync's includeSchool is for chats); user memory is never saved from Enterprise chats.
// Without state.json (the first pass) everything goes out once as `add` lines marked `initial`.
// A pass compares the stores with state.json, so changes made while it was off or the app was closed go out too;
// who made a change comes from the skills' history and from MemoryItem/MemoryChange.meeting. Changes in one pass are
// merged (A→B→C is one A→C line; added and deleted before a pass, no line): the folder carries state, not keystrokes.

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
    let skills: SkillStore
    let memory: () -> MemoryData?   // nil: memory.json could not be read (not the same as empty)
    let updateMemory: ((inout MemoryData) -> Void) -> Bool
    let candidates: KnowledgeCandidates
    let local: URL                  // this Mac's own record of what it read (KnowledgeMerge.swift)
    // The global inbox candidates proposed here that may go to the other Macs (set by the app: chat there, not Enterprise).
    var shareable: () -> Set<UUID> = { [] }
    private let io = DispatchQueue(label: "knowledge-sync")
    private var subscriptions: [AnyCancellable] = []
    private var timer: Timer?
    private var activation: NSObjectProtocol?
    private var scheduled: DispatchWorkItem?
    private let lock = NSLock()
    private var allowed = false   // the switch as the io queue sees it: turned off, a pass already queued writes nothing
    private var hostCache: String?   // the review Mac as the last pass found it
    static let delay: TimeInterval = 3   // several changes in a row become one pass
    static let retry: TimeInterval = 60  // iCloud Drive away or a write failed: try again

    init(sync: DeviceSync, skills: SkillStore = .shared, memory: @escaping () -> MemoryData? = { MemoryStore.shared.readableSnapshot },
         updateMemory: @escaping ((inout MemoryData) -> Void) -> Bool = { MemoryStore.shared.update($0) },
         candidates: KnowledgeCandidates = .shared, local: URL = URL(fileURLWithPath: AccountStore.supportDir)) {
        self.sync = sync
        self.deviceID = sync.deviceID
        self.skills = skills
        self.memory = memory
        self.updateMemory = updateMemory
        self.candidates = candidates
        self.local = local
    }

    static func folder(_ sync: URL) -> URL { sync.appendingPathComponent("knowledge") }
    static func hostFile(_ sync: URL) -> URL { folder(sync).appendingPathComponent("host.json") }
    func myFolder(_ sync: URL) -> URL { Self.folder(sync).appendingPathComponent(deviceID) }

    var target: Target? {
        guard sync.settings.syncsKnowledge, sync.folderAvailable else { return nil }
        return Target(folder: sync.folder, name: sync.deviceName)
    }

    // The app only (DeviceSync.start): a pass after skill, memory or settings changes, at DeviceSync's scan interval and
    // when the app comes forward (the other Macs' changes come in then); only the review Mac holds the reviews.
    func start(discussion: Discussion) {
        guard subscriptions.isEmpty else { return }
        shareable = { [weak discussion] in
            guard let discussion else { return [] }
            return Set(KnowledgeReviewLink.eligible(discussion).filter { !$0.inProject && $0.row.origin == nil }.map(\.row.id))
        }
        KnowledgeReviewLink.isReviewHost = { [weak self] in self?.isReviewHost ?? true }
        let ticker = Timer(timeInterval: DeviceSync.interval, repeats: true) { [weak self] _ in self?.wake() }
        ticker.tolerance = 30
        RunLoop.main.add(ticker, forMode: .common)
        timer = ticker
        activation = NotificationCenter.default.addObserver(forName: Notification.Name("NSApplicationDidBecomeActiveNotification"), object: nil, queue: .main) { [weak self] _ in
            self?.wake()
        }
        subscriptions = [
            skills.$revision.dropFirst().sink { [weak self] _ in self?.schedule() },
            MemoryStore.shared.$data.dropFirst().sink { [weak self] _ in self?.schedule() },
            sync.$settings.sink { [weak self] settings in
                if !settings.syncsKnowledge { self?.allow(false) }   // at once, before a queued pass runs
                DispatchQueue.main.async { self?.schedule() }        // after didSet
            },
        ]
    }

    // This Mac holds the knowledge reviews: always with sync off; with it on, while host.json names it (or nobody yet).
    // Not known before the first pass: no review until then.
    var isReviewHost: Bool {
        guard sync.settings.syncsKnowledge else { return true }
        lock.lock(); defer { lock.unlock() }
        return hostCache == deviceID
    }

    private func wake() { if sync.settings.syncsKnowledge, scheduled == nil { schedule() } }

    private func allow(_ on: Bool) { lock.lock(); allowed = on; lock.unlock() }
    private var isAllowed: Bool { lock.lock(); defer { lock.unlock() }; return allowed }

    private func schedule(after delay: TimeInterval = KnowledgeSync.delay) {
        scheduled?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.scheduled = nil
            guard let target = self.target else { return self.retryLater() }   // on but no folder: iCloud Drive may come back
            self.allow(true)
            // Read the folder (io), apply the other Macs' changes (main: the stores and the inbox live there), write this Mac's.
            self.io.async {
                let remote = self.read(target, now: Date())
                DispatchQueue.main.async {
                    guard self.target != nil, self.isAllowed else { return }
                    let shared = self.merge(remote, now: Date())
                    let memory = self.memory()   // read now, while it is on
                    self.io.async {
                        if self.pass(target, memory: memory, remote: remote, shared: shared) == nil { DispatchQueue.main.async { self.retryLater() } }
                    }
                }
            }
        }
        scheduled = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    // Main thread: only while it is on, and never in place of a pass already waiting.
    private func retryLater() {
        guard sync.settings.syncsKnowledge, scheduled == nil else { return }
        schedule(after: Self.retry)
    }

    // One pass now (tests; the app goes through schedule): the number of lines written, nil when off or not all written.
    @discardableResult
    func syncNow(now: Date = Date()) -> Int? {
        guard let target else { return nil }
        allow(true)
        let remote = io.sync { read(target, now: now) }
        let shared = merge(remote, now: now)
        let memory = self.memory()
        return io.sync { pass(target, memory: memory, remote: remote, shared: shared, now: now) }
    }

    @discardableResult
    private func pass(_ target: Target, memory data: MemoryData?, remote: KnowledgeRemote, shared: [KnowledgeCandidate]?, now: Date = Date()) -> Int? {
        guard isAllowed else { return nil }
        let fm = FileManager.default
        let mine = myFolder(target.folder)
        do { try fm.createDirectory(at: mine.appendingPathComponent("skills"), withIntermediateDirectories: true) } catch { return nil }
        if remote.takeOver { takeOver(target, now: now) } else if remote.host == nil { claimHost(target, now: now) }
        // A takeover holds only once host.json says so: else the old review Mac, back, would hold reviews too.
        let host = remote.takeOver ? (Self.host(target.folder)?.device == deviceID ? deviceID : nil) : remote.host ?? Self.host(target.folder)?.device
        lock.lock(); hostCache = host; lock.unlock()
        heartbeat(mine, name: target.name, info: remote.myInfo, now: now)
        if let shared { share(shared, to: mine, was: remote.myCandidates) }
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
        var incomplete = false

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
                } catch { if let before { state.skills[id] = before }; incomplete = true; continue }
            }
            state.skills[id] = current
            if before?.hash != current.hash {
                let (by, at) = Self.author(summary, detail.record, history, toggle: false)
                line(.skill, before == nil ? .add : .modify, id, at: at, by: by, base: before?.hash, hash: current.hash, name: current.name, enabled: current.enabled)
            }
            if let before, before.enabled != current.enabled {
                let (by, at) = Self.author(summary, detail.record, history, toggle: true)
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
        // An unreadable memory.json stays as it was written, not every fact deleted.
        if let data {
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
        } else { state.memory = was.memory; state.profile = was.profile }

        // The lines, then the state they add up to: a pass cut short repeats its lines rather than losing them.
        guard isAllowed else { return nil }
        if !lines.isEmpty {
            let encoder = Self.encoder(); encoder.outputFormatting = [.sortedKeys]
            var chunk = Data()
            for change in lines { guard let row = try? encoder.encode(change) else { continue }; chunk.append(row); chunk.append(10) }
            guard Self.append(chunk, to: mine.appendingPathComponent("changes.jsonl")) else { return nil }
        }
        if old == nil || state != was {
            guard let encoded = try? Self.encoder().encode(state), (try? encoded.write(to: stateFile, options: .atomic)) != nil else { return nil }
        }
        return incomplete ? nil : lines.count
    }

    // Who made the skill's text (or its on/off) as it is now: the latest history line that changed that, so an AI's
    // edit stays the AI's when the user then turns the skill off. An edit outside the app is the user's.
    static func author(_ summary: SkillSummary, _ record: SkillRecord, _ history: [SkillHistoryEntry], toggle: Bool) -> (SkillAuthor, Date) {
        if summary.externallyModified && !toggle { return (.user, record.updatedAt) }
        let latest = history.last { entry in entry.items.contains { item in
            guard let after = item.after?.record, after.id == record.id else { return false }
            let before = item.before?.record
            return toggle ? before?.enabled != after.enabled : before?.contentHash != after.contentHash || before?.name != after.name
        } }
        return latest.map { ($0.by, $0.at) } ?? (record.createdBy, record.updatedAt)
    }

    // The first Mac to turn this on holds the review meetings; a host.json already there stays as it is.
    private func claimHost(_ target: Target, now: Date) {
        let file = Self.hostFile(target.folder)
        guard !FileManager.default.fileExists(atPath: file.path),
              let data = try? Self.encoder().encode(KnowledgeHost(device: deviceID, name: target.name, since: now)) else { return }
        try? data.write(to: file, options: .withoutOverwriting)
    }

    // The review Mac went quiet for a week: this Mac, next in line, holds the reviews from now on.
    private func takeOver(_ target: Target, now: Date) {
        guard let data = try? Self.encoder().encode(KnowledgeHost(device: deviceID, name: target.name, since: now)) else { return }
        try? data.write(to: Self.hostFile(target.folder), options: .atomic)
    }

    // device.json: when this Mac last passed (hourly at most, so iCloud Drive is not kept busy), and since when it syncs.
    private func heartbeat(_ mine: URL, name: String, info: KnowledgeDevice?, now: Date) {
        if let info, info.name == name, now.timeIntervalSince(info.at) < Self.heartbeat, info.at <= now { return }
        let next = KnowledgeDevice(name: name, since: info?.since ?? now, at: now)
        if let data = try? Self.encoder().encode(next) { try? data.write(to: mine.appendingPathComponent("device.json"), options: .atomic) }
    }

    // candidates.jsonl: this Mac's global inbox rows the other Macs see, written only when it changed.
    private func share(_ rows: [KnowledgeCandidate], to mine: URL, was: Data?) {
        let encoder = Self.encoder(); encoder.outputFormatting = [.sortedKeys]
        var data = Data()
        for row in rows { guard let line = try? encoder.encode(row) else { continue }; data.append(line); data.append(10) }
        guard data != was ?? Data() else { return }
        try? data.write(to: mine.appendingPathComponent("candidates.jsonl"), options: .atomic)
    }

    static func host(_ sync: URL) -> KnowledgeHost? {
        (try? Data(contentsOf: hostFile(sync))).flatMap { try? decoder().decode(KnowledgeHost.self, from: $0) }
    }

    // A last line cut short by an earlier write is ended first, so the next line is not glued onto it.
    static func append(_ chunk: Data, to file: URL) -> Bool {
        if !FileManager.default.fileExists(atPath: file.path) { return (try? chunk.write(to: file, options: .atomic)) != nil }
        guard let handle = try? FileHandle(forUpdating: file) else { return false }
        defer { try? handle.close() }
        do {
            let end = try handle.seekToEnd()
            var chunk = chunk
            if end > 0 {
                try handle.seek(toOffset: end - 1)
                if try handle.read(upToCount: 1) != Data([10]) { chunk.insert(10, at: 0) }
                try handle.seekToEnd()
            }
            try handle.write(contentsOf: chunk); return true
        } catch { return false }
    }

    static func encoder() -> JSONEncoder { DeviceSync.encoder() }
    static func decoder() -> JSONDecoder { DeviceSync.decoder() }
}
