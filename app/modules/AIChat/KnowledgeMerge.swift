import Foundation
import CryptoKit
import AIAccounts
import AILocalization
import AIProjects

// "Sync skills & memory" 2/3: the other Macs' changes come in, and one Mac holds the reviews.
// Each pass first reads the sync folder (io queue), applies on the main thread what this Mac has not applied yet, then
// writes this Mac's own folder (KnowledgeSync.pass). This Mac keeps, in <support>/knowledge-sync.json, how many lines of
// each other Mac it applied, so an old line is never taken for a new change.
// Whether a change goes on top of what this Mac has is decided by the hashes: every line says the hash it was made on
// (base) and the one after it, so all the lines of all Macs form each item's history. A change made on what this Mac has
// (or on an older version of it) applies; one this Mac already went past is skipped; one made beside this Mac's own
// change, both from the same older version, is a conflict:
// - one side by the user, the other by an AI or a review: the user's stays, the other's text goes to the candidate inbox
//   so the next review looks at it again;
// - both by the user, or both not: the latest stays for now and the other goes to the inbox as a "conflict merge"
//   candidate with both versions, for the review to make one of them. The user is not asked to pick.
// Both Macs decide the same way (the same rule on the same two lines) and make the same candidate (its id comes from the
// two hashes), so they end up alike. A deleted item never comes back: a tombstone line or this Mac's own delete beats
// any change made beside it (that change's text goes to the inbox), except an AI's or a review's delete beside the user's
// change: the user's change stays (on the Mac that deleted it, a skill comes back under a new id, its old id an alias).
// On/off goes the same way, the latest switch winning, the user's over an AI's.
// The candidate inbox (global one only) goes to <folder>/knowledge/<deviceID>/candidates.jsonl: the review Mac adds the
// other Macs' pending candidates to its own inbox, and every Mac takes a further state (waiting, applied, dropped) from
// the others, so the review's outcome reaches the Mac that proposed it.
// The review Mac is host.json's (KnowledgeSync.claimHost); when it has not passed for 7 days (device.json's `at`), the
// Mac that turned sync on first among those seen in that week takes over and rewrites host.json.

// This Mac only: <support>/knowledge-sync.json.
struct KnowledgeCursor: Codable, Equatable {
    var read: [String: Int] = [:]      // another Mac → how many of its lines are applied
    var alias: [String: String] = [:]  // "skill:<its id>" → this Mac's item made on both Macs before they synced
    var conflicts: [KnowledgeCandidate]?   // candidates of lines read but not in the inbox yet (written with `read`)
}

// <folder>/knowledge/<deviceID>/device.json: the Mac and when it last passed (at most hourly).
struct KnowledgeDevice: Codable, Equatable {
    var name: String
    var since: Date   // first pass: the earliest one takes over a review Mac that went quiet
    var at: Date
}

// One read of the sync folder: the other Macs' lines and what goes with them, and this Mac's own.
struct KnowledgeRemote {
    struct Mac {
        var id: String
        var name: String
        var lines: [KnowledgeChange?]          // complete lines in order; nil: a line that does not decode
        var skills: [String: String] = [:]     // SKILL.md of the skills its unread lines name
        var candidates: [KnowledgeCandidate] = []
        var info: KnowledgeDevice?
    }
    var others: [Mac] = []
    var mine: [KnowledgeChange] = []
    var myState: KnowledgeState?
    var myInfo: KnowledgeDevice?
    var myCandidates: Data?
    var host: String?          // the review Mac (nil: none yet, this pass claims it)
    var takeOver = false       // the review Mac went quiet and this Mac is next
}

extension KnowledgeSync {
    static let quiet: TimeInterval = 7 * 86_400   // a review Mac without a pass this long is taken over
    static let heartbeat: TimeInterval = 3_600
    static let syncedMeeting = UUID(uuidString: "5C000000-0000-4000-8000-000000000000")!   // a fact a review made on another Mac

    var cursorFile: URL { local.appendingPathComponent("knowledge-sync.json") }

    func loadCursor() -> KnowledgeCursor {
        (try? Data(contentsOf: cursorFile)).flatMap { try? Self.decoder().decode(KnowledgeCursor.self, from: $0) } ?? KnowledgeCursor()
    }

    @discardableResult
    func saveCursor(_ cursor: KnowledgeCursor) -> Bool {
        try? FileManager.default.createDirectory(at: local, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard let data = try? Self.encoder().encode(cursor) else { return false }
        return (try? data.write(to: cursorFile, options: .atomic)) != nil
    }

    // MARK: Reading (io queue)

    func read(_ target: Target, now: Date) -> KnowledgeRemote {
        let fm = FileManager.default, root = Self.folder(target.folder)
        let cursor = loadCursor()
        var remote = KnowledgeRemote()
        let mine = myFolder(target.folder)
        remote.mine = Self.lines(mine.appendingPathComponent("changes.jsonl")).compactMap { $0 }
        remote.myState = (try? Data(contentsOf: mine.appendingPathComponent("state.json"))).flatMap { try? Self.decoder().decode(KnowledgeState.self, from: $0) }
        remote.myInfo = Self.info(mine)
        remote.myCandidates = try? Data(contentsOf: mine.appendingPathComponent("candidates.jsonl"))
        let entries = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        var hosts: [KnowledgeHost] = []
        for entry in entries {
            let name = entry.lastPathComponent
            if name.hasPrefix("host"), name.hasSuffix(".json") {   // host.json, and copies iCloud made of two Macs' writes
                DeviceSync.download(entry)
                if let host = (try? Data(contentsOf: entry)).flatMap({ try? Self.decoder().decode(KnowledgeHost.self, from: $0) }) { hosts.append(host) }
                continue
            }
            guard name != deviceID, !name.hasPrefix("."), (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
            let changes = entry.appendingPathComponent("changes.jsonl"), shared = entry.appendingPathComponent("candidates.jsonl")
            let infoFile = entry.appendingPathComponent("device.json")
            [changes, shared, infoFile].forEach(DeviceSync.download)
            let info = Self.info(entry)
            var mac = KnowledgeRemote.Mac(id: name, name: info?.name ?? name, lines: Self.lines(changes), info: info)
            for line in mac.lines.dropFirst(min(cursor.read[name] ?? 0, mac.lines.count)).compactMap({ $0 })
            where line.kind == .skill && line.hash != nil && mac.skills[line.id] == nil {
                let file = entry.appendingPathComponent("skills").appendingPathComponent(line.id).appendingPathComponent("SKILL.md")
                DeviceSync.download(file)
                mac.skills[line.id] = try? String(contentsOf: file, encoding: .utf8)
            }
            mac.candidates = ((try? Data(contentsOf: shared)) ?? Data()).split(separator: 10)
                .compactMap { try? Self.decoder().decode(KnowledgeCandidate.self, from: Data($0)) }
            remote.others.append(mac)
        }
        var devices = Dictionary(remote.others.compactMap { mac in mac.info.map { (mac.id, $0) } }, uniquingKeysWith: { a, _ in a })
        devices[deviceID] = KnowledgeDevice(name: target.name, since: remote.myInfo?.since ?? now, at: now)
        (remote.host, remote.takeOver) = Self.reviewHost(hosts, devices: devices, me: deviceID, now: now)
        return remote
    }

    // Complete lines only: a last line still being written is read next time.
    static func lines(_ file: URL) -> [KnowledgeChange?] {
        guard let data = try? Data(contentsOf: file), !data.isEmpty else { return [] }
        var rows = data.split(separator: 10, omittingEmptySubsequences: false)
        rows.removeLast()   // after the last newline: empty, or a line not ended yet
        return rows.map { $0.isEmpty ? nil : try? decoder().decode(KnowledgeChange.self, from: Data($0)) }
    }

    static func info(_ folder: URL) -> KnowledgeDevice? {
        (try? Data(contentsOf: folder.appendingPathComponent("device.json"))).flatMap { try? decoder().decode(KnowledgeDevice.self, from: $0) }
    }

    // host.json's Mac while it passed in the last week; else the Mac seen in that week that turned sync on first (ties: the
    // smaller id), which takes over. Two Macs that claimed at once (iCloud keeps both files): the earlier claim.
    static func reviewHost(_ hosts: [KnowledgeHost], devices: [String: KnowledgeDevice], me: String, now: Date) -> (String?, Bool) {
        guard let claimed = hosts.min(by: { ($0.since, $0.device) < ($1.since, $1.device) }) else { return (nil, false) }
        let seen = max(devices[claimed.device]?.at ?? claimed.since, claimed.since)
        if claimed.device == me || now.timeIntervalSince(seen) <= quiet { return (claimed.device, false) }
        let next = devices.filter { $0.key == me || now.timeIntervalSince($0.value.at) <= quiet }
            .min { ($0.value.since, $0.key) < ($1.value.since, $1.key) }?.key ?? me
        return (next, next == me)
    }

    // MARK: Applying (main thread)

    // Applies the other Macs' unread lines and their candidate rows; returns this Mac's inbox rows to share (nil: unreadable).
    func merge(_ remote: KnowledgeRemote, now: Date) -> [KnowledgeCandidate]? {
        let cursor = loadCursor()
        var merger = Merger(sync: self, remote: remote, cursor: cursor, now: now)
        for mac in remote.others.sorted(by: { $0.id < $1.id }) {
            let start = min(cursor.read[mac.id] ?? 0, mac.lines.count)
            // Per item, its unread lines: the last change of its text and the last switch decide.
            var order: [String] = [], first: [String: Int] = [:]
            var content: [String: KnowledgeChange] = [:], toggle: [String: KnowledgeChange] = [:]
            for (i, line) in mac.lines.enumerated().dropFirst(start) {
                guard let line else { continue }
                let key = line.kind.rawValue + ":" + line.id
                if first[key] == nil { first[key] = i; order.append(key) }
                switch line.op {
                case .enable, .disable: toggle[key] = line
                case .add: content[key] = line; toggle[key] = line
                case .modify: content[key] = line
                case .delete: content[key] = line; toggle[key] = nil
                }
            }
            var stop = mac.lines.count
            for key in order where !merger.apply(content[key], toggle: toggle[key], from: mac) { stop = min(stop, first[key]!) }
            merger.cursor.read[mac.id] = stop
        }
        // The candidates go into the cursor file with the lines they came from, then into the inbox: a quit or an inbox that
        // cannot be written in between leaves them there for the next pass, not lost with the lines already read.
        let pending = (cursor.conflicts ?? []) + merger.conflicts.filter { row in !(cursor.conflicts ?? []).contains { $0.id == row.id } }
        merger.cursor.conflicts = pending.isEmpty ? nil : pending
        if merger.cursor != cursor { saveCursor(merger.cursor) }
        if !pending.isEmpty, candidates.merge(pending, adding: true) { merger.cursor.conflicts = nil; saveCursor(merger.cursor) }
        // Other Macs' rows: their state everywhere; their pending ones into the review Mac's inbox.
        let host = remote.host == nil || remote.host == deviceID
        let rows = remote.others.flatMap { mac in mac.candidates.map { row -> KnowledgeCandidate in
            var row = row; row.origin = row.origin ?? mac.id; return row
        } }
        if !rows.isEmpty { _ = candidates.merge(rows, adding: host) }
        guard let inbox = candidates.globalRows() else { return nil }
        let before = Set((remote.myCandidates ?? Data()).split(separator: 10)
            .compactMap { try? Self.decoder().decode(KnowledgeCandidate.self, from: Data($0)) }.map(\.id))
        let mine = shareable()
        return inbox.filter { $0.origin != nil || mine.contains($0.id) || before.contains($0.id) }
    }

    // A conflict's candidate: the same id on both Macs, from the item and the two versions.
    static func stableID(_ text: String) -> UUID {
        var b = Array(SHA256.hash(data: Data(text.utf8)).prefix(16))
        b[6] = (b[6] & 0x0f) | 0x50; b[8] = (b[8] & 0x3f) | 0x80
        return UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7], b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]))
    }

    // Which of two versions made from the same older one stays: the user's over an AI's or a review's, else the later,
    // else the smaller Mac id. Both Macs compare the same two, so both keep the same one.
    static func wins(_ a: (by: SkillAuthor, at: Date, device: String), over b: (by: SkillAuthor, at: Date, device: String)) -> Bool {
        if (a.by == .user) != (b.by == .user) { return a.by == .user }
        if a.at != b.at { return a.at > b.at }
        return a.device < b.device
    }
}

// One merge: the history graph of every item, the tombstones, and the changes it makes.
private struct Merger {
    struct Version { var by: SkillAuthor; var at: Date; var device: String; var mac: String; var hash: String
                     var name = "", description = "", body = "", text = ""
                     var tuple: (by: SkillAuthor, at: Date, device: String) { (by, at, device) } }
    let sync: KnowledgeSync
    let remote: KnowledgeRemote
    var cursor: KnowledgeCursor
    let now: Date
    var conflicts: [KnowledgeCandidate] = []
    private var parents: [String: [String: Set<String>]] = [:]   // item → hash → the hashes it was made on
    private var deleted: Set<String> = []                        // items with a tombstone
    private var made: [String: [String: Date]] = [:]             // item → hash → when its latest line made it
    private var userMade: [String: Set<String>] = [:]            // item → the hashes a user's add or modify made
    private var mineLast: [String: KnowledgeChange] = [:]        // this Mac's last line per item
    static let none = "-"                                        // the hash of "nothing" (a profile cleared)

    init(sync: KnowledgeSync, remote: KnowledgeRemote, cursor: KnowledgeCursor, now: Date) {
        self.sync = sync; self.remote = remote; self.cursor = cursor; self.now = now
        for line in remote.mine { mineLast[line.kind.rawValue + ":" + line.id] = line }
        var removed: [String: Date] = [:], added: [String: Date] = [:], kept: Set<String> = []
        let all = (remote.mine.map(Optional.some) + remote.others.flatMap(\.lines)).compactMap { $0 }
        for line in all {
            let key = local(line.kind, line.id)
            guard line.op == .add || line.op == .modify || (line.kind == .profile && line.op == .delete) else { continue }
            let hash = line.hash ?? Self.none
            made[key, default: [:]][hash] = max(made[key]?[hash] ?? line.at, line.at)
            if line.by == .user, line.kind != .profile { userMade[key, default: []].insert(hash) }
            // A line without a base (an add) has no parent: "nothing" as its parent would make a cleared profile look older.
            if let base = line.base { parents[key, default: [:]][hash, default: []].insert(base) }
        }
        for line in all {
            let key = local(line.kind, line.id)
            if line.kind != .profile, line.op == .delete {
                if overruled(line, key) { kept.insert(key) } else { removed[key] = max(removed[key] ?? line.at, line.at) }
            }
            if line.op == .add { added[key] = max(added[key] ?? line.at, line.at) }
        }
        // A tombstone holds unless the item was added again later (Undo brings a deleted fact back under its id).
        deleted = Set(removed.filter { key, at in (added[key] ?? .distantPast) <= at }.keys)
        for t in sync.skills.tombstones() where !kept.contains("skill:" + t.id.uuidString) && !kept.contains(local(.skill, t.id.uuidString)) {
            deleted.insert("skill:" + t.id.uuidString)
        }
    }

    // An AI's or a review's delete made beside the user's change (one it did not see): the user's change stays.
    func overruled(_ line: KnowledgeChange, _ key: String) -> Bool {
        guard line.op == .delete, line.kind != .profile, line.by != .user, let base = line.base else { return false }
        return userMade[key]?.contains { $0 != base && !isAncestor($0, of: base, key) } == true
    }

    func local(_ kind: KnowledgeChange.Kind, _ id: String) -> String {
        let key = kind.rawValue + ":" + id
        return cursor.alias[key] ?? key
    }

    // Whether `a` is `b` or one of the versions `b` was made from.
    func isAncestor(_ a: String, of b: String, _ key: String, extra: [String: String] = [:]) -> Bool {
        var seen: Set<String> = [], queue = [b]
        while let h = queue.popLast() {
            if h == a { return true }
            guard seen.insert(h).inserted else { continue }
            queue += parents[key]?[h] ?? []
            if let e = extra[h] { queue.append(e) }
        }
        return false
    }

    // Whether this Mac already went past `theirs`: it is one of the versions `mine` was made from. An edit undone
    // (X → Y → X) makes each the other's ancestor; then the later of the two decides, so a late X → Y does not undo the undo.
    func behind(_ theirs: String, at: Date, mine: String, mineAt: () -> Date, _ key: String, extra: [String: String]) -> Bool {
        guard isAncestor(theirs, of: mine, key, extra: extra) else { return false }
        guard isAncestor(mine, of: theirs, key, extra: extra) else { return true }
        return max(made[key]?[mine] ?? .distantPast, mineAt()) >= at
    }

    // false: not applied yet (a SKILL.md not here or not matching its line, a store not writable): read again next time.
    mutating func apply(_ content: KnowledgeChange?, toggle: KnowledgeChange?, from mac: KnowledgeRemote.Mac) -> Bool {
        guard let line = content ?? toggle else { return true }
        switch line.kind {
        case .skill: return skill(content, toggle: toggle, from: mac)
        case .memory: return content.map { fact($0, from: mac) } ?? true
        case .profile: return content.map { profile($0) } ?? true
        }
    }

    // MARK: Skills

    private mutating func skill(_ content: KnowledgeChange?, toggle: KnowledgeChange?, from mac: KnowledgeRemote.Mac) -> Bool {
        let skills = sync.skills
        let id = (content ?? toggle)!.id
        var key = local(.skill, id)
        func current() -> SkillDetail? {
            let wanted = String(key.dropFirst("skill:".count))
            return skills.list().first { $0.id.uuidString == wanted }.flatMap { skills.read($0.name) }
        }
        var detail = current()
        var created = false
        if let line = content {
            if line.op == .delete {
                guard let here = detail, !overruled(line, key) else { return true }
                let hash = Self.hash(here)
                if hash != line.base, !isAncestor(hash, of: line.base ?? Self.none, key, extra: unexported(key, hash)) {
                    // Changed here since: the delete still goes (a deleted skill never comes back), the change to the inbox;
                    // unless the user changed it and an AI deleted it (the change's line, once written, overrules it everywhere).
                    let ours = version(here, key)
                    if ours.by == .user, line.by != .user { return true }
                    lost(.skill, key, kept: nil, lost: ours, by: line, from: mac)
                }
                return Self.done(skills.delete(here.name, by: line.by, now: line.at)) || Self.done(skills.delete(here.name, by: .user, now: line.at))
            }
            if deleted.contains(key) { return true }
            // This Mac's own delete not written out yet: decided next pass, once its line is there to weigh against this one.
            if detail == nil, remote.myState?.skills[String(key.dropFirst("skill:".count))] != nil { return false }
            guard let text = mac.skills[id], let hash = line.hash, SkillDocument.hash(text) == hash else { return false }
            guard let doc = SkillDocument.parse(text) else { return true }
            if detail == nil, let same = skills.read(doc.name) {
                // Made on both Macs before they synced: one skill, under this Mac's id.
                cursor.alias["skill:" + id] = "skill:" + same.id.uuidString
                key = "skill:" + same.id.uuidString
                detail = same
            }
            let theirs = Merger.Version(by: line.by, at: line.at, device: mac.id, mac: mac.name, hash: hash,
                                        name: doc.name, description: doc.description, body: doc.body)
            if let here = detail {
                let mine = Self.hash(here)
                let extra = unexported(key, mine)
                if mine == hash || behind(hash, at: line.at, mine: mine, mineAt: { version(here, key).at }, key, extra: extra) {
                    // Already here, or this Mac went past it.
                } else if isAncestor(mine, of: hash, key, extra: extra) {
                    guard save(theirs, over: here) else { return false }
                } else {
                    let ours = version(here, key)
                    if KnowledgeSync.wins(theirs.tuple, over: ours.tuple) {
                        guard save(theirs, over: here) else { return false }
                        lost(.skill, key, kept: theirs, lost: ours, by: line, from: mac)
                    } else {
                        lost(.skill, key, kept: ours, lost: theirs, by: line, from: mac)
                    }
                }
            } else {
                let outcome = skills.save(name: doc.name, description: doc.description, body: doc.body, by: line.by,
                                          id: UUID(uuidString: id), now: line.at)
                if case .refused = outcome {
                    guard skills.tombstones().contains(where: { $0.id.uuidString == id }) else { return false }
                    // Deleted here by an AI beside the user's change (else `deleted` skipped it): SkillDirectory does not take
                    // a deleted id again, so it comes back under a new one, the old id its alias.
                    guard Self.done(skills.save(name: doc.name, description: doc.description, body: doc.body, by: line.by, now: line.at)),
                          let back = skills.read(doc.name) else { return false }
                    cursor.alias["skill:" + id] = "skill:" + back.id.uuidString
                    key = "skill:" + back.id.uuidString
                }
                created = true
            }
            detail = current()
        }
        // On/off: the later switch, the user's over an AI's; a skill just added takes the other Mac's.
        guard let line = toggle, let enabled = line.enabled, let here = detail ?? current(), here.record.enabled != enabled else { return true }
        if !created {
            guard line.op != .add, let summary = skills.list().first(where: { $0.id == here.record.id }) else { return true }
            let (by, at) = KnowledgeSync.author(summary, here.record, skills.history(), toggle: true)
            guard KnowledgeSync.wins((line.by, line.at, mac.id), over: (by, at, sync.deviceID)) else { return true }
        }
        return Self.done(skills.setEnabled(here.name, enabled, by: line.by, now: line.at))
            || Self.done(skills.setEnabled(here.name, enabled, by: .user, now: line.at))
    }

    private func save(_ v: Version, over here: SkillDetail) -> Bool {
        Self.done(sync.skills.save(name: v.name, description: v.description, body: v.body, by: v.by, id: here.record.id,
                                   now: v.at, approved: here.record.contentHash))
    }

    static func done(_ outcome: SkillOutcome) -> Bool {
        switch outcome { case .saved, .updated, .deleted: return true; default: return false }
    }

    static func hash(_ detail: SkillDetail) -> String { SkillDocument.hash(detail.document.render()) }

    // This Mac's change not written out yet: the version state.json last had → the one here now.
    private func unexported(_ key: String, _ hash: String) -> [String: String] {
        let id = String(key.split(separator: ":", maxSplits: 1).last ?? "")
        let was = key.hasPrefix("skill:") ? remote.myState?.skills[id]?.hash : remote.myState?.memory[id]
        guard let was, was != hash else { return [:] }
        return [hash: was]
    }

    // Who made the version here, and when: this Mac's line for it, else the store's history (as the next pass writes it).
    private func version(_ here: SkillDetail, _ key: String) -> Version {
        let hash = Self.hash(here)
        var by: SkillAuthor, at: Date
        if let line = mineLast[key], line.hash == hash { by = line.by; at = line.at }
        else if let summary = sync.skills.list().first(where: { $0.id == here.record.id }) {
            (by, at) = KnowledgeSync.author(summary, here.record, sync.skills.history(), toggle: false)
        } else { (by, at) = (here.record.createdBy, here.record.updatedAt) }
        return Version(by: by, at: at, device: sync.deviceID, mac: L("이 Mac", "this Mac"), hash: hash,
                       name: here.name, description: here.document.description, body: here.document.body)
    }

    // MARK: Memory

    private mutating func fact(_ line: KnowledgeChange, from mac: KnowledgeRemote.Mac) -> Bool {
        guard let data = sync.memory() else { return false }
        var key = local(.memory, line.id)
        func id(_ key: String) -> String { String(key.dropFirst("memory:".count)) }
        var here = data.items.first { $0.id.uuidString == id(key) }
        let meeting: UUID? = line.by == .meeting ? KnowledgeSync.syncedMeeting : nil
        // A fact this Mac removed and has not written out yet is a tombstone too.
        let pendingDelete = here == nil && remote.myState?.memory[id(key)] != nil
        if line.op == .delete {
            guard let item = here, !overruled(line, key) else { return true }
            let hash = SkillDocument.hash(item.text)
            if hash != line.base, !isAncestor(hash, of: line.base ?? Self.none, key, extra: unexported(key, hash)) {
                let ours = factVersion(item, key, data)
                if ours.by == .user, line.by != .user { return true }
                lost(.memory, key, kept: nil, lost: ours, by: line, from: mac)
            }
            return sync.updateMemory { data in
                guard let i = data.items.firstIndex(where: { $0.id == item.id }) else { return }
                data.history.append(MemoryChange(old: data.items[i], new: nil, at: line.at, meeting: meeting))
                data.items.remove(at: i)
                Self.trim(&data)
            }
        }
        if pendingDelete, !deleted.contains(key) { return false }   // weighed next pass, against its line
        guard !deleted.contains(key), let text = line.text, let hash = line.hash else { return true }
        if here == nil, let same = data.items.first(where: { $0.text.lowercased() == text.lowercased() }) {
            cursor.alias["memory:" + line.id] = "memory:" + same.id.uuidString
            key = "memory:" + same.id.uuidString
            here = same
        }
        let theirs = Version(by: line.by, at: line.at, device: mac.id, mac: mac.name, hash: hash, text: text)
        guard let item = here else {
            guard let uuid = UUID(uuidString: line.id) else { return true }
            return sync.updateMemory { data in
                guard !data.items.contains(where: { $0.id == uuid }) else { return }
                data.items.append(MemoryItem(id: uuid, text: text, createdAt: line.at, meeting: meeting))
            }
        }
        let mine = SkillDocument.hash(item.text), extra = unexported(key, mine)
        func put(_ v: Version) -> Bool {
            sync.updateMemory { data in
                guard let i = data.items.firstIndex(where: { $0.id == item.id }) else { return }
                data.history.append(MemoryChange(old: data.items[i], new: v.text, at: v.at, meeting: v.by == .meeting ? KnowledgeSync.syncedMeeting : nil))
                data.items[i].text = v.text
                data.items[i].meeting = v.by == .meeting ? KnowledgeSync.syncedMeeting : nil
                Self.trim(&data)
            }
        }
        if mine == hash || behind(hash, at: line.at, mine: mine, mineAt: { factVersion(item, key, data).at }, key, extra: extra) { return true }
        if isAncestor(mine, of: hash, key, extra: extra) { return put(theirs) }
        let ours = factVersion(item, key, data)
        if KnowledgeSync.wins(theirs.tuple, over: ours.tuple) {
            guard put(theirs) else { return false }
            lost(.memory, key, kept: theirs, lost: ours, by: line, from: mac)
        } else {
            lost(.memory, key, kept: ours, lost: theirs, by: line, from: mac)
        }
        return true
    }

    private func factVersion(_ item: MemoryItem, _ key: String, _ data: MemoryData) -> Version {
        let hash = SkillDocument.hash(item.text)
        let by: SkillAuthor, at: Date
        if let line = mineLast[key], line.hash == hash { by = line.by; at = line.at }
        else {
            by = item.meeting == nil ? .user : .meeting
            at = data.history.last { $0.old.id == item.id && $0.new == item.text }?.at ?? item.createdAt
        }
        return Version(by: by, at: at, device: sync.deviceID, mac: L("이 Mac", "this Mac"), hash: hash, text: item.text)
    }

    static func trim(_ data: inout MemoryData) {
        if data.history.count > MemoryStore.maxHistory { data.history.removeFirst(data.history.count - MemoryStore.maxHistory) }
    }

    // The profile: the user's on both Macs, so a conflict keeps the later one (no candidate: a review changes facts only).
    private func profile(_ line: KnowledgeChange) -> Bool {
        guard let data = sync.memory() else { return false }
        let text = data.profile.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : data.profile
        let mine = text.map { SkillDocument.hash($0) } ?? Self.none, theirs = line.hash ?? Self.none
        var extra: [String: String] = [:]
        if let was = remote.myState.map({ $0.profile ?? Self.none }), was != mine { extra[mine] = was }
        let key = "profile:profile"
        let at = mineLast[key].flatMap { $0.hash ?? Self.none == mine ? $0.at : nil } ?? now
        if mine == theirs || behind(theirs, at: line.at, mine: mine, mineAt: { at }, key, extra: extra) { return true }
        // Never set here: take it. Cleared here (a line or a clear not written yet) or set: the later one, as on the other Mac.
        let cleared = mine == Self.none && (extra[mine] != nil || mineLast[key].map { $0.hash == nil } == true)
        if mine != Self.none || cleared, !isAncestor(mine, of: theirs, key, extra: extra) {
            guard KnowledgeSync.wins((.user, line.at, line.device), over: (.user, at, sync.deviceID)) else { return true }
        }
        return sync.updateMemory { $0.profile = line.text ?? "" }
    }

    // MARK: Candidates

    // The version that did not stay goes to the inbox for the next review (by `kept`: what is saved now, nil: deleted).
    private mutating func lost(_ kind: KnowledgeCandidate.Kind, _ key: String, kept: Version?, lost: Version,
                               by line: KnowledgeChange, from mac: KnowledgeRemote.Mac) {
        let id = KnowledgeSync.stableID("knowledge-conflict|" + key + "|" + [kept?.hash ?? "deleted", lost.hash].sorted().joined(separator: "|"))
        guard !conflicts.contains(where: { $0.id == id }) else { return }
        let where_ = "\(lost.mac) (\(lost.by.rawValue))"
        let evidence: String
        var content: [String: String]
        switch kind {
        case .skill: content = ["name": lost.name, "description": lost.description, "body": lost.body, "scope": "global"]
        case .memory: content = ["text": lost.text]
        }
        if let kept {
            let keptWhere = "\(kept.mac) (\(kept.by.rawValue))"
            if kind == .skill { content["replaces"] = kept.name } else { content["replaces_id"] = String(key.dropFirst("memory:".count)) }
            let keptText = kind == .skill ? String(kept.body.prefix(1_500)) : kept.text
            if (kept.by == .user) != (lost.by == .user) {
                evidence = L("두 Mac에서 같은 항목이 따로 바뀌었어요. 사용자가 고친 쪽(\(keptWhere))을 적용했고, 이 AI 쪽 내용(\(where_))은 버렸어요. 쓸 만한 부분이 있으면 지금 저장된 것에 합쳐 주세요.",
                             "Both Macs changed this item separately. The user's version (\(keptWhere)) was applied and this AI version (\(where_)) was set aside. Merge anything useful into the saved one.")
            } else {
                evidence = L("충돌 병합: 두 Mac에서 같은 항목이 따로 바뀌어 더 최근 것(\(keptWhere))을 임시로 두었어요. 이 후보(\(where_))와 지금 저장된 버전을 하나로 합쳐 modify해 주세요.\n지금 저장된 버전:\n\(keptText)",
                             "Conflict merge: both Macs changed this item separately; the later one (\(keptWhere)) stays for now. Merge this candidate (\(where_)) and the saved version into one with modify.\nSaved version:\n\(keptText)")
            }
        } else {
            evidence = L("다른 Mac에서 지운 항목을 이 사이 \(where_)에서 고쳤어요. 지운 것은 되살리지 않았어요; 고친 내용이 쓸모 있으면 새로 add해 주세요.",
                         "Another Mac deleted this item while \(where_) changed it. It was not brought back; add the change anew if it is useful.")
        }
        let names = [mac.name, L("이 Mac", "this Mac")].joined(separator: " ↔ ")
        conflicts.append(KnowledgeCandidate(id: id, kind: kind, content: content, evidence: evidence, accountID: "sync",
                                            accountName: L("Mac 동기화", "Mac sync") + " (\(names))", chatID: id, turnID: id,
                                            todoID: nil, createdAt: now, state: .pending, origin: "sync"))
    }
}
