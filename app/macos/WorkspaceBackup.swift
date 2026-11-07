import Foundation
import CryptoKit

struct WorkspaceChange: Codable, Identifiable, Equatable {
    var id: String { path }
    var path: String
    var kind: String
}
struct WorkspaceBackup: Codable {
    struct Stamp: Codable, Equatable { var kind: String; var digest: String }
    var directory: String
    var roots: [WorkspaceRoot]
    var before: [String: Stamp]
    var after: [String: Stamp]?
    var changes: [WorkspaceChange] = []
    var gitStates: [String] = []
    var gitHeads: [String: String]? = nil
    var restored = false
    // Files only in the cloud when the backup was made: not copied, so Undo cannot bring them back
    // (the cloud's own version history and trash can).
    var cloud: [String]?
    static var base: URL { URL(fileURLWithPath: AccountStore.supportDir).appendingPathComponent("workspace-backups") }

    // Deleting a chat removes its backups: the copies under workspace-backups/<room> and the
    // refs/ai-illuminati/<run> markers this app added to linked git folders. Linked folders themselves
    // and any other git refs are left alone.
    static func purgeRoom(_ room: UUID) throws {
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
    static func digest(_ url: URL) throws -> String {
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
        guard lstat(file.path, &info) == 0 else { throw MaterialReader.error("파일 정보를 읽지 못했습니다: " + file.path) }
        switch info.st_mode & S_IFMT {
        case S_IFLNK: return (Stamp(kind: "link", digest: try FileManager.default.destinationOfSymbolicLink(atPath: file.path)), false)
        case S_IFDIR: return (Stamp(kind: "directory", digest: ""), false)
        case S_IFREG:
            let modified = Int64(info.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(info.st_mtimespec.tv_nsec)
            return (Stamp(kind: "file", digest: "\(info.st_size):\(modified)"), info.st_flags & datalessFlag != 0 || treatAsCloud.contains(file.standardizedFileURL.path))
        default: throw MaterialReader.error("백업할 수 없는 특수 파일: " + file.path)
        }
    }
    static func stamps(_ roots: [WorkspaceRoot]) throws -> [String: Stamp] { try survey(roots).stamps }
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
                    try add(file, "\(index)/" + String(relative.dropFirst(url.path.count + 1)))
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
                        throw MaterialReader.error("백업 복사 실패: " + from.path)
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
            if skip.contains(key + relative) { continue }
            try copyOne(file, destination.appendingPathComponent(relative), stamp)
        }
    }
    @discardableResult static func run(_ executable: String, _ arguments: [String]) throws -> String {
        let process = Process(), out = Pipe()
        process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
        process.standardOutput = out; process.standardError = FileHandle.nullDevice
        try process.run(); let data = out.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw MaterialReader.error("작업 실패: " + URL(fileURLWithPath: executable).lastPathComponent) }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    static func begin(_ binding: WorkspaceBinding, room: UUID, runID: UUID) throws -> WorkspaceBackup {
        // A backup must not be placed inside its own source, and roots may not overlap.
        let paths = binding.roots.map { URL(fileURLWithPath: $0.path).resolvingSymlinksInPath().path }
        for (i, path) in paths.enumerated() {
            guard path != "/", !base.path.hasPrefix(path + "/"), path != base.path else { throw MaterialReader.error("백업 위치를 포함하는 상위 폴더 대신 실제 작업 폴더를 연결하세요.") }
            for (j, other) in paths.enumerated() where i != j {
                guard path != other && !path.hasPrefix(other + "/") else { throw MaterialReader.error("중복·중첩된 연결 폴더를 정리하세요.") }
            }
        }
        let folder = base.appendingPathComponent(room.uuidString).appendingPathComponent(runID.uuidString)
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
            throw MaterialReader.error("백업 검증 실패로 쓰기를 시작하지 않았습니다: " + difference)
        }
        var backup = WorkspaceBackup(directory: folder.path, roots: binding.roots, before: before)
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
        prune(room: room, keep: keepPerChat)
        return backup
    }

    // Each chat keeps its newest backups only (older answers can no longer be undone).
    static let keepPerChat = 20
    static func prune(room: UUID, keep: Int) {
        let fm = FileManager.default
        let folder = base.appendingPathComponent(room.uuidString)
        let runs = ((try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
            .filter { UUID(uuidString: $0.lastPathComponent) != nil }
            .sorted { (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? .distantPast) ?? .distantPast
                    > (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? .distantPast) ?? .distantPast }
        for run in runs.dropFirst(keep) {
            if let data = try? Data(contentsOf: run.appendingPathComponent("complete.json")),
               let old = try? JSONDecoder().decode(WorkspaceBackup.self, from: data) {
                for root in old.roots where root.directory {
                    _ = try? WorkspaceBackup.run("/usr/bin/git", ["-C", root.path, "update-ref", "-d", "refs/ai-illuminati/" + run.lastPathComponent])
                }
            }
            try? fm.removeItem(at: run)
        }
    }
    func save() throws {
        let url = URL(fileURLWithPath: directory).appendingPathComponent("complete.json")
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    mutating func finish() throws {
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
    }
    static func load(_ path: String) throws -> WorkspaceBackup {
        let url = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        guard url.path.hasPrefix(base.resolvingSymlinksInPath().path + "/") else { throw MaterialReader.error("앱 소유 백업이 아닙니다.") }
        return try JSONDecoder().decode(Self.self, from: Data(contentsOf: url.appendingPathComponent("complete.json")))
    }
    // Puts back only what the answer changed, entry by entry (the rest of the folder, including files
    // only in the cloud, is left alone). Refuses when anything changed after the answer.
    mutating func restore() throws {
        for (root, head) in gitHeads ?? [:] {
            guard (try? Self.run("/usr/bin/git", ["-C", root, "rev-parse", "HEAD"])) == head else { throw MaterialReader.error("Git HEAD changed after this backup. Use a new correction commit instead of file Undo.") }
        }
        guard !restored, let after, try Self.stamps(roots) == after else { throw MaterialReader.error("작업 후 다른 변경이 있어 자동으로 덮어쓰지 않았습니다. 백업과 현재 파일을 먼저 비교하세요.") }
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
        let now = try Self.stamps(roots)
        let lost = Set(before.keys).union(after.keys).filter { cloudKeys.contains($0) && before[$0] != after[$0] }
        guard Set(now.keys).union(before.keys).subtracting(lost).allSatisfy({ now[$0] == before[$0] }) else {
            throw MaterialReader.error("복원 결과가 백업과 일치하지 않습니다.")
        }
        restored = true; try save()
    }
}
