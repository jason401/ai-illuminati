import Foundation
import CryptoKit
import AIAccounts

public struct WorkspaceChange: Codable, Identifiable, Equatable {
    public var id: String { path }
    public var path: String
    public var kind: String
    public init(path: String, kind: String) {
        self.path = path; self.kind = kind
    }
}
public struct WorkspaceBackup: Codable {
    public struct Stamp: Codable, Equatable { public var kind: String; var digest: String }
    public var directory: String
    public var roots: [WorkspaceRoot]
    public var before: [String: Stamp]
    var after: [String: Stamp]?
    public var changes: [WorkspaceChange] = []
    var gitStates: [String] = []
    var gitHeads: [String: String]? = nil
    var restored = false
    // Files only in the cloud when the backup was made: not copied, so Undo cannot bring them back
    // (the cloud's own version history and trash can).
    public var cloud: [String]?
    var created: Date? = nil        // when the backup was made (older backups: the folder's date)
    var trimmed: Bool? = nil        // the copy keeps only what the answer changed (trim())
    public static var base: URL { URL(fileURLWithPath: AccountStore.supportDir).appendingPathComponent("workspace-backups") }
    // Where the chats are saved (the app's ChatStore.dir; a test checks both are the same): a backup whose chat is gone goes.
    static var chats: String { AccountStore.supportDir + "/chats" }

    // Deleting a chat removes its backups: the copies under workspace-backups/<room> and the
    // refs/ai-illuminati/<run> markers this app added to linked git folders. Linked folders themselves
    // and any other git refs are left alone.
    public static func purgeRoom(_ room: UUID) throws {
        let fm = FileManager.default
        let folder = base.appendingPathComponent(room.uuidString)
        guard fm.fileExists(atPath: folder.path) else { return }
        for run in (try? fm.contentsOfDirectory(atPath: folder.path)) ?? [] {
            guard let runID = UUID(uuidString: run),
                  let data = try? Data(contentsOf: folder.appendingPathComponent(run).appendingPathComponent("complete.json")),
                  let backup = try? JSONDecoder().decode(WorkspaceBackup.self, from: data) else { continue }
            for root in backup.roots where root.directory {
                _ = try? WorkspaceBackup.run("/usr/bin/git", ["-C", root.path, "update-ref", "-d", "refs/ai-illuminati/" + runID.uuidString])
            }
        }
        try fm.removeItem(at: folder)
    }
    public static func digest(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        var hash = SHA256()
        while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty { hash.update(data: data) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    // A file is compared by size and modification time, read from its metadata only. Reading every byte
    // (as before) made big folders slow and downloaded every cloud-only file (Google Drive, iCloud).
    static let datalessFlag: UInt32 = 0x4000_0000   // SF_DATALESS: only in the cloud, not downloaded
    static var treatAsCloud: Set<String> = []        // tests only: paths to handle as cloud-only
    static func entry(_ file: URL) throws -> (Stamp, cloud: Bool) {
        var info = stat()
        guard lstat(file.path, &info) == 0 else { throw WorkspaceError.make("파일 정보를 읽지 못했습니다: " + file.path) }
        switch info.st_mode & S_IFMT {
        case S_IFLNK: return (Stamp(kind: "link", digest: try FileManager.default.destinationOfSymbolicLink(atPath: file.path)), false)
        case S_IFDIR: return (Stamp(kind: "directory", digest: ""), false)
        case S_IFREG:
            let modified = Int64(info.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(info.st_mtimespec.tv_nsec)
            return (Stamp(kind: "file", digest: "\(info.st_size):\(modified)"), info.st_flags & datalessFlag != 0 || treatAsCloud.contains(file.standardizedFileURL.path))
        default: throw WorkspaceError.make("백업할 수 없는 특수 파일: " + file.path)
        }
    }
    public static func stamps(_ roots: [WorkspaceRoot]) throws -> [String: Stamp] { try survey(roots).stamps }
    // The refs/ai-illuminati/<run> markers are the app's own: making or deleting one (a new backup, pruning)
    // must not count as a change to the folder, or it would block Undo of the backups that are kept.
    static func isAppRef(_ key: String) -> Bool {
        guard let slash = key.firstIndex(of: "/") else { return false }
        let rest = key[key.index(after: slash)...]
        return rest == ".git/refs/ai-illuminati" || rest.hasPrefix(".git/refs/ai-illuminati/")
    }
    static func comparable(_ stamps: [String: Stamp]) -> [String: Stamp] { stamps.filter { !isAppRef($0.key) } }
    /// Every entry under the roots ("<root index>/<relative path>") and the files that are only in the cloud.
    static func survey(_ roots: [WorkspaceRoot]) throws -> (stamps: [String: Stamp], cloud: Set<String>) {
        var result: [String: Stamp] = [:], cloud: Set<String> = []
        for (index, root) in roots.enumerated() {
            let url = URL(fileURLWithPath: root.path).standardizedFileURL
            guard FileManager.default.fileExists(atPath: root.path) || (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true else { continue }
            func add(_ file: URL, _ key: String) throws {
                let (stamp, onlyCloud) = try entry(file)
                result[key] = stamp
                if onlyCloud { cloud.insert(key) }
            }
            try add(url, "\(index)/")
            if root.directory, let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isSymbolicLinkKey]) {
                for case let file as URL in e {
                    let relative = file.standardizedFileURL.path
                    let key = "\(index)/" + String(relative.dropFirst(url.path.count + 1))
                    if isAppRef(key) { e.skipDescendants(); continue }
                    try add(file, key)
                    if (try? file.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true { e.skipDescendants() }
                }
            }
        }
        return (result, cloud)
    }
    // Copies one root entry by entry (APFS clones: no extra space until a file changes), leaving out the
    // keys in `skip` (cloud-only files are not downloaded for the backup).
    static func copyTree(_ source: URL, _ destination: URL, key: String, skip: Set<String>) throws {
        func copyOne(_ from: URL, _ to: URL, _ stamp: Stamp) throws {
            switch stamp.kind {
            case "directory": try FileManager.default.createDirectory(at: to, withIntermediateDirectories: true)
            case "link": try FileManager.default.createSymbolicLink(atPath: to.path, withDestinationPath: stamp.digest)
            default:
                try FileManager.default.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
                if clonefile(from.path, to.path, UInt32(CLONE_NOFOLLOW)) != 0 {
                    guard copyfile(from.path, to.path, nil, copyfile_flags_t(COPYFILE_ALL | COPYFILE_NOFOLLOW)) == 0 else {
                        throw WorkspaceError.make("백업 복사 실패: " + from.path)
                    }
                }
            }
        }
        try copyOne(source, destination, try entry(source).0)
        guard try entry(source).0.kind == "directory", let e = FileManager.default.enumerator(at: source, includingPropertiesForKeys: [.isSymbolicLinkKey]) else { return }
        for case let file as URL in e {
            let relative = String(file.standardizedFileURL.path.dropFirst(source.standardizedFileURL.path.count + 1))
            let (stamp, _) = try entry(file)
            if stamp.kind == "link" { e.skipDescendants() }
            if key.hasSuffix("/"), isAppRef(key + relative) { e.skipDescendants(); continue }
            if skip.contains(key + relative) { continue }
            try copyOne(file, destination.appendingPathComponent(relative), stamp)
        }
    }
    @discardableResult static func run(_ executable: String, _ arguments: [String]) throws -> String {
        let process = Process(), out = Pipe()
        process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
        process.standardOutput = out; process.standardError = FileHandle.nullDevice
        try process.run(); let data = out.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw WorkspaceError.make("작업 실패: " + URL(fileURLWithPath: executable).lastPathComponent) }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    public static func begin(_ binding: WorkspaceBinding, room: UUID, runID: UUID) throws -> WorkspaceBackup {
        // A backup must not be placed inside its own source, and roots may not overlap.
        let paths = binding.roots.map { URL(fileURLWithPath: $0.path).resolvingSymlinksInPath().path }
        for (i, path) in paths.enumerated() {
            guard path != "/", !base.path.hasPrefix(path + "/"), path != base.path else { throw WorkspaceError.make("백업 위치를 포함하는 상위 폴더 대신 실제 작업 폴더를 연결하세요.") }
            for (j, other) in paths.enumerated() where i != j {
                guard path != other && !path.hasPrefix(other + "/") else { throw WorkspaceError.make("중복·중첩된 연결 폴더를 정리하세요.") }
            }
        }
        let folder = base.appendingPathComponent(room.uuidString).appendingPathComponent(runID.uuidString)
        protect(folder.path)   // until finish(): cleanup leaves it alone
        var made = false
        defer { if !made { release(folder.path) } }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let (before, cloud) = try survey(binding.roots)
        for (i, root) in binding.roots.enumerated() {
            try copyTree(URL(fileURLWithPath: root.path), folder.appendingPathComponent(String(i)), key: "\(i)/", skip: cloud)
        }
        let copiedRoots = binding.roots.enumerated().map { WorkspaceRoot(path: folder.appendingPathComponent(String($0.offset)).path, directory: $0.element.directory) }
        let copied = try stamps(copiedRoots), current = try stamps(binding.roots)
        let expected = before.filter { !cloud.contains($0.key) }
        guard copied == expected, current == before else {
            let difference = Set(expected.keys).union(copied.keys).filter { expected[$0] != copied[$0] }.sorted().prefix(5).joined(separator: ", ")
            throw WorkspaceError.make("백업 검증 실패로 쓰기를 시작하지 않았습니다: " + difference)
        }
        var backup = WorkspaceBackup(directory: folder.path, roots: binding.roots, before: before)
        backup.created = Date()
        backup.cloud = cloud.isEmpty ? nil : cloud.sorted()
        for root in binding.roots where root.directory {
            if let top = try? run("/usr/bin/git", ["-C", root.path, "rev-parse", "--show-toplevel"]), URL(fileURLWithPath: top).resolvingSymlinksInPath().path == root.path {
                let head = (try? run("/usr/bin/git", ["-C", root.path, "rev-parse", "HEAD"])) ?? "unborn"
                if backup.gitHeads == nil { backup.gitHeads = [:] }
                backup.gitHeads?[root.path] = head
                if let commit = try? run("/usr/bin/git", ["-C", root.path, "stash", "create", "AI Illuminati backup"]), !commit.isEmpty {
                    try run("/usr/bin/git", ["-C", root.path, "update-ref", "refs/ai-illuminati/" + runID.uuidString, commit])
                    backup.gitStates.append(root.path + ": " + commit)
                } else { backup.gitStates.append(root.path + ": " + head) }
            }
        }
        try backup.save()
        made = true
        prune(room: room, keep: keepPerChat)
        return backup
    }

    // Old backups go by age and count (cleanUp): when a turn ends, at launch and once a day, over every chat.
    // Deleting a backup takes away that answer's Undo, so these are kept:
    // a backup still in use (protect: from begin to finish, and while it restores), and for each set of linked
    // folders the newest finished backup at any age (its Undo may still work), unless its chat is gone.
    // A backup that never finished (stopped answer) may hold the only copy of what was there, so only age and
    // count take it.
    public struct Policy: Equatable {
        public var days: Int
        public var perChat: Int
        public init(days: Int, perChat: Int) {
            self.days = days; self.perChat = perChat
        }
        static let daysKey = "backupKeepDays", perChatKey = "backupKeepPerChat"
        public static let standard = Policy(days: 14, perChat: 5)
        public static var current: Policy {
            get {
                let d = UserDefaults.app
                return Policy(days: max(1, d.object(forKey: daysKey) as? Int ?? standard.days),
                              perChat: max(1, d.object(forKey: perChatKey) as? Int ?? standard.perChat))
            }
            set { UserDefaults.app.set(max(1, newValue.days), forKey: daysKey); UserDefaults.app.set(max(1, newValue.perChat), forKey: perChatKey) }
        }
    }
    static var keepPerChat: Int { Policy.current.perChat }
    public struct CleanUpResult: Equatable { public var removed = 0; public var trimmed = 0; public var bytes: Int64 = 0 }

    // Kept by the run's folder name (a UUID): the same folder may be reached by paths spelled differently (/tmp, /private/tmp).
    private static let protectLock = NSLock()
    private static var protected: [String: Int] = [:]
    private static func runName(_ directory: String) -> String { URL(fileURLWithPath: directory).lastPathComponent }
    private static var claimed: Set<String> = []   // being deleted or trimmed by cleanup
    // false while cleanup has the backup: Undo must not start on a copy that is going away.
    @discardableResult static func protect(_ directory: String) -> Bool {
        protectLock.lock(); defer { protectLock.unlock() }
        let name = runName(directory)
        guard !claimed.contains(name) else { return false }
        protected[name, default: 0] += 1
        return true
    }
    // Cleanup takes a backup only when nothing uses it, in the same lock that protect() takes,
    // so a check and an Undo starting cannot cross.
    private static func claim(_ directory: String) -> Bool {
        protectLock.lock(); defer { protectLock.unlock() }
        let name = runName(directory)
        guard protected[name] == nil, !claimed.contains(name) else { return false }
        claimed.insert(name)
        return true
    }
    private static func unclaim(_ directory: String) { protectLock.lock(); claimed.remove(runName(directory)); protectLock.unlock() }
    static func release(_ directory: String) {
        protectLock.lock(); defer { protectLock.unlock() }
        let name = runName(directory)
        if let n = protected[name] { protected[name] = n > 1 ? n - 1 : nil }
    }
    static func isProtected(_ directory: String) -> Bool { protectLock.lock(); defer { protectLock.unlock() }; return protected[runName(directory)] != nil }

    private struct Run { var url: URL; var room: String; var created: Date; var backup: WorkspaceBackup? }
    private static func runs(in room: URL) -> [Run] {
        let fm = FileManager.default
        return ((try? fm.contentsOfDirectory(at: room, includingPropertiesForKeys: [.creationDateKey, .contentModificationDateKey])) ?? [])
            .filter { UUID(uuidString: $0.lastPathComponent) != nil }
            .map { url in
                let backup = (try? Data(contentsOf: url.appendingPathComponent("complete.json"))).flatMap { try? JSONDecoder().decode(WorkspaceBackup.self, from: $0) }
                let values = try? url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
                let created = backup?.created ?? values?.creationDate ?? values?.contentModificationDate ?? .distantPast
                return Run(url: url, room: room.lastPathComponent, created: created, backup: backup)
            }
            .sorted { $0.created > $1.created }
    }
    // Removes one backup and its refs/ai-illuminati/<run> markers; never one in use.
    private static func remove(_ run: Run, into result: inout CleanUpResult) {
        guard claim(run.url.path) else { return }
        defer { unclaim(run.url.path) }
        for root in run.backup?.roots ?? [] where root.directory { deleteRef(root.path, run.url.lastPathComponent) }
        let size = DiskUsage.of(run.url).allocated
        if (try? FileManager.default.removeItem(at: run.url)) != nil { result.removed += 1; result.bytes += size }
    }
    // A loose ref is a file under .git/refs/ai-illuminati, which stamps leave out. Once Git has packed it,
    // deleting it rewrites .git/packed-refs, a change that would block Undo of the folder's other backups:
    // such a ref waits (pending-refs.json) until the folder has no backups left (sweepRefs).
    static var pendingRefs: URL { base.appendingPathComponent("pending-refs.json") }
    private static func deleteRef(_ root: String, _ run: String) {
        let git = URL(fileURLWithPath: root).appendingPathComponent(".git")
        let loose = git.appendingPathComponent("refs/ai-illuminati/" + run)
        var isDirectory: ObjCBool = false
        let inside = FileManager.default.fileExists(atPath: git.path, isDirectory: &isDirectory) && isDirectory.boolValue
        if inside, !FileManager.default.fileExists(atPath: loose.path),
           (try? WorkspaceBackup.run("/usr/bin/git", ["-C", root, "rev-parse", "--verify", "-q", "refs/ai-illuminati/" + run])) == nil { return }   // none was made (clean folder)
        if !inside || FileManager.default.fileExists(atPath: loose.path) {
            _ = try? WorkspaceBackup.run("/usr/bin/git", ["-C", root, "update-ref", "-d", "refs/ai-illuminati/" + run])
        } else {
            var pending = (try? JSONDecoder().decode(Set<String>.self, from: Data(contentsOf: pendingRefs))) ?? []
            if pending.insert(root).inserted { try? JSONEncoder().encode(pending).write(to: pendingRefs, options: .atomic) }
        }
    }
    // Folders with packed refs waiting: once none of their backups is left, their refs of gone backups go.
    private static func sweepRefs(_ remaining: [Run]) {
        guard var pending = try? JSONDecoder().decode(Set<String>.self, from: Data(contentsOf: pendingRefs)) else { return }
        let used = Set(remaining.flatMap { $0.backup?.roots.map(\.path) ?? [] })
        let kept = Set(remaining.map { $0.url.lastPathComponent })
        for root in pending where !used.contains(root) {
            let names = (try? WorkspaceBackup.run("/usr/bin/git", ["-C", root, "for-each-ref", "--format=%(refname)", "refs/ai-illuminati/"])) ?? ""
            for ref in names.split(separator: "\n").map(String.init) where !kept.contains(String(ref.dropFirst("refs/ai-illuminati/".count))) && !isProtected(String(ref.dropFirst("refs/ai-illuminati/".count))) {
                _ = try? WorkspaceBackup.run("/usr/bin/git", ["-C", root, "update-ref", "-d", ref])
            }
            pending.remove(root)
        }
        if pending.isEmpty { try? FileManager.default.removeItem(at: pendingRefs) }
        else { try? JSONEncoder().encode(pending).write(to: pendingRefs, options: .atomic) }
    }
    // The newest finished backup of each set of linked folders: kept at any age (its Undo may still work).
    private static func newestPerFolders(_ runs: [Run]) -> Set<String> {
        var newest: Set<String> = [], seen: Set<[String]> = []
        for run in runs.sorted(by: { $0.created > $1.created }) {
            guard let backup = run.backup, backup.after != nil, !backup.restored else { continue }
            if seen.insert(backup.roots.map(\.path)).inserted { newest.insert(run.url.path) }
        }
        return newest
    }
    private static let cleanLock = NSLock()

    // Within one chat only, by count: the cleanup a new backup does at once.
    static func prune(room: UUID, keep: Int) {
        cleanLock.lock(); defer { cleanLock.unlock() }
        var result = CleanUpResult()
        // Only this chat's backups are read, so the newest per set of folders is this chat's: it keeps more, never less.
        let list = runs(in: base.appendingPathComponent(room.uuidString)), newest = newestPerFolders(list)
        for run in list.dropFirst(keep) where !newest.contains(run.url.path) { remove(run, into: &result) }
    }

    @discardableResult public static func cleanUp(_ policy: Policy = .current, now: Date = Date()) -> CleanUpResult {
        cleanLock.lock(); defer { cleanLock.unlock() }
        let fm = FileManager.default
        var result = CleanUpResult()
        let rooms = ((try? fm.contentsOfDirectory(at: base, includingPropertiesForKeys: nil)) ?? []).filter { UUID(uuidString: $0.lastPathComponent) != nil }
        // A chat folder that cannot be read says nothing about which chats are gone.
        let chats = (try? fm.contentsOfDirectory(atPath: chats)).map(Set.init)
        var all: [Run] = [], remaining: [Run] = []
        for room in rooms {
            let list = runs(in: room)
            let age = (try? room.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? now
            if let chats, !chats.contains(room.lastPathComponent + ".json"), now.timeIntervalSince(age) > 86_400 {
                for run in list {
                    remove(run, into: &result)
                    if fm.fileExists(atPath: run.url.path) { remaining.append(run) }
                }
                if (try? fm.contentsOfDirectory(atPath: room.path))?.isEmpty == true { try? fm.removeItem(at: room) }
                continue
            }
            all += list
        }
        let newest = newestPerFolders(all)
        let limit = TimeInterval(policy.days) * 86_400
        for (_, list) in Dictionary(grouping: all, by: \.room) {
            for (i, run) in list.sorted(by: { $0.created > $1.created }).enumerated() {
                guard !isProtected(run.url.path) else { remaining.append(run); continue }
                let old = now.timeIntervalSince(run.created) > limit
                let broken = run.backup == nil && now.timeIntervalSince(run.created) > 86_400   // a backup that failed while being made
                if !newest.contains(run.url.path), i >= policy.perChat || old || broken || run.backup?.restored == true {
                    remove(run, into: &result)
                    if FileManager.default.fileExists(atPath: run.url.path) { remaining.append(run) }
                    continue
                }
                remaining.append(run)
                if var backup = run.backup, backup.after != nil, backup.trimmed != true, claim(run.url.path) {
                    // Backups from before trim() existed: keep only what their answer changed.
                    defer { unclaim(run.url.path) }
                    let size = DiskUsage.of(run.url).allocated
                    if (try? backup.trim()) != nil { result.trimmed += 1; result.bytes += max(0, size - DiskUsage.of(run.url).allocated) }
                }
            }
        }
        sweepRefs(remaining)
        return result
    }

    // The app turns automatic cleanup on (tests do not, so they are not raced). Runs on a background queue.
    static var automatic = false
    private static let cleanQueue = DispatchQueue(label: "ai-illuminati.backup-cleanup", qos: .utility)
    private static var pending = false
    static func cleanUpSoon() {
        guard automatic else { return }
        protectLock.lock(); let queued = pending; pending = true; protectLock.unlock()
        guard !queued else { return }
        cleanQueue.asyncAfter(deadline: .now() + 2) {
            protectLock.lock(); pending = false; protectLock.unlock()
            cleanUp()
        }
    }
    private static var daily: Timer?
    public static func startAutomaticCleanUp() {
        automatic = true
        cleanUpSoon()
        daily = Timer.scheduledTimer(withTimeInterval: 86_400, repeats: true) { _ in cleanUpSoon() }
    }

    // After finish(): the copy keeps only the entries Undo puts back (changed ones that existed before),
    // so a backup costs about what the answer changed instead of the whole folder. Directories are made
    // again by restore() and need no copy.
    mutating func trim() throws {
        guard let after, trimmed != true, !restored else { return }
        let before = Self.comparable(self.before), now = Self.comparable(after)
        let cloudKeys = Set(cloud ?? [])
        let needed = Set(before.keys.filter { before[$0] != now[$0] && before[$0]?.kind != "directory" && !cloudKeys.contains($0) })
        let fm = FileManager.default
        for i in roots.indices {
            let top = URL(fileURLWithPath: directory).appendingPathComponent(String(i))
            let rootKey = "\(i)/"
            guard let kind = try? Self.entry(top).0.kind else { continue }
            if kind != "directory" {
                if !needed.contains(rootKey) { try fm.removeItem(at: top) }
                continue
            }
            var files: [URL] = [], folders: [URL] = []
            guard let e = fm.enumerator(at: top, includingPropertiesForKeys: [.isSymbolicLinkKey]) else { continue }
            for case let file as URL in e {
                let key = rootKey + String(file.standardizedFileURL.path.dropFirst(top.standardizedFileURL.path.count + 1))
                let stamp = try Self.entry(file).0
                if stamp.kind == "directory" { folders.append(file); continue }
                if stamp.kind == "link" { e.skipDescendants() }
                if !needed.contains(key) { files.append(file) }
            }
            for file in files { try fm.removeItem(at: file) }
            for folder in folders.sorted(by: { $0.path.count > $1.path.count }) where (try? fm.contentsOfDirectory(atPath: folder.path))?.isEmpty == true {
                try fm.removeItem(at: folder)
            }
        }
        trimmed = true
        try save()
    }
    func save() throws {
        let url = URL(fileURLWithPath: directory).appendingPathComponent("complete.json")
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    public mutating func finish() throws {
        defer { Self.release(directory) }
        after = try Self.stamps(roots)
        changes = Set(before.keys).union(after!.keys).sorted().compactMap { key in
            guard before[key] != after![key], !key.contains("/.git/") && !key.hasSuffix("/.git") else { return nil }
            let parts = key.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
            guard let i = Int(parts[0]), i < roots.count else { return nil }
            let path = roots[i].path + (parts.count > 1 && !parts[1].isEmpty ? "/" + parts[1] : "")
            let kind = before[key] == nil ? "added" : after![key] == nil ? "deleted" : "modified"
            return WorkspaceChange(path: path, kind: (cloud ?? []).contains(key) ? "cloud-" + kind : kind)
        }
        try save()
        try? trim()
        Self.cleanUpSoon()
    }
    public static func load(_ path: String) throws -> WorkspaceBackup {
        let url = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        guard url.path.hasPrefix(base.resolvingSymlinksInPath().path + "/") else { throw WorkspaceError.make("앱 소유 백업이 아닙니다.") }
        return try JSONDecoder().decode(Self.self, from: Data(contentsOf: url.appendingPathComponent("complete.json")))
    }
    // Puts back only what the answer changed, entry by entry (the rest of the folder, including files
    // only in the cloud, is left alone). Refuses when anything changed after the answer.
    public mutating func restore() throws {
        for (root, head) in gitHeads ?? [:] {
            guard (try? Self.run("/usr/bin/git", ["-C", root, "rev-parse", "HEAD"])) == head else { throw WorkspaceError.make("Git HEAD changed after this backup. Use a new correction commit instead of file Undo.") }
        }
        guard Self.protect(directory) else { throw WorkspaceError.make("이 백업은 지금 정리 중이라 되돌릴 수 없습니다.") }
        defer { Self.release(directory) }
        let before = Self.comparable(self.before)
        guard !restored, let after = after.map(Self.comparable), Self.comparable(try Self.stamps(roots)) == after else { throw WorkspaceError.make("작업 후 다른 변경이 있어 자동으로 덮어쓰지 않았습니다. 백업과 현재 파일을 먼저 비교하세요.") }
        let manager = FileManager.default
        let cloudKeys = Set(cloud ?? [])
        let changed = Set(before.keys).union(after.keys).filter { before[$0] != after[$0] && !cloudKeys.contains($0) }
        func url(_ key: String, in base: String? = nil) -> URL? {
            let parts = key.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
            guard let i = Int(parts[0]), i < roots.count else { return nil }
            let rest = parts.count > 1 ? String(parts[1]) : ""
            let top = base.map { URL(fileURLWithPath: $0).appendingPathComponent(String(i)) } ?? URL(fileURLWithPath: roots[i].path)
            return rest.isEmpty ? top : top.appendingPathComponent(rest)
        }
        // Added entries go first, deepest first; then the old ones come back, shallowest first.
        for key in changed.filter({ before[$0] == nil }).sorted(by: { $0.count > $1.count }) {
            if let target = url(key), manager.fileExists(atPath: target.path) || (try? manager.destinationOfSymbolicLink(atPath: target.path)) != nil {
                try manager.removeItem(at: target)
            }
        }
        for key in changed.filter({ before[$0] != nil }).sorted(by: { $0.count < $1.count }) {
            guard let target = url(key), let source = url(key, in: directory), let stamp = before[key] else { continue }
            let present = manager.fileExists(atPath: target.path) || (try? manager.destinationOfSymbolicLink(atPath: target.path)) != nil
            if stamp.kind == "directory" {
                if present, (try? Self.entry(target).0.kind) != "directory" { try manager.removeItem(at: target) }
                try manager.createDirectory(at: target, withIntermediateDirectories: true)
                continue
            }
            if present { try manager.removeItem(at: target) }
            try Self.copyTree(source, target, key: key, skip: [])
        }
        let now = Self.comparable(try Self.stamps(roots))
        let lost = Set(before.keys).union(after.keys).filter { cloudKeys.contains($0) && before[$0] != after[$0] }
        guard Set(now.keys).union(before.keys).subtracting(lost).allSatisfy({ now[$0] == before[$0] }) else {
            throw WorkspaceError.make("복원 결과가 백업과 일치하지 않습니다.")
        }
        restored = true; try save()
    }
}
