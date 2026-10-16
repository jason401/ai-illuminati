import Foundation
import CryptoKit

struct WorkspaceChange: Codable, Identifiable {
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
    var restored = false
    static var base: URL { URL(fileURLWithPath: AccountStore.supportDir).appendingPathComponent("workspace-backups") }
    static func digest(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        var hash = SHA256()
        while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty { hash.update(data: data) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    static func stamps(_ roots: [WorkspaceRoot]) throws -> [String: Stamp] {
        var result: [String: Stamp] = [:]
        for (index, root) in roots.enumerated() {
            let url = URL(fileURLWithPath: root.path).standardizedFileURL
            guard FileManager.default.fileExists(atPath: root.path) || (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true else { continue }
            func add(_ file: URL, _ key: String) throws {
                let info = try file.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey])
                if info.isSymbolicLink == true { result[key] = Stamp(kind: "link", digest: try FileManager.default.destinationOfSymbolicLink(atPath: file.path)) }
                else if info.isDirectory == true { result[key] = Stamp(kind: "directory", digest: "") }
                else if info.isRegularFile == true { result[key] = Stamp(kind: "file", digest: try digest(file)) }
                else { throw MaterialReader.error("백업할 수 없는 특수 파일: " + file.path) }
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
        return result
    }
    @discardableResult static func run(_ executable: String, _ arguments: [String]) throws -> String {
        let process = Process(), out = Pipe()
        process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
        process.standardOutput = out; process.standardError = FileHandle.nullDevice
        try process.run(); let data = out.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw MaterialReader.error("작업 실패: " + URL(fileURLWithPath: executable).lastPathComponent) }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    static func clone(_ source: URL, _ destination: URL) throws {
        do { try run("/bin/cp", ["-c", "-p", "-R", source.path, destination.path]) }
        catch {
            if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
            try FileManager.default.copyItem(at: source, to: destination)
        }
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
        let before = try stamps(binding.roots)
        for (i, root) in binding.roots.enumerated() { try clone(URL(fileURLWithPath: root.path), folder.appendingPathComponent(String(i))) }
        let copiedRoots = binding.roots.enumerated().map { WorkspaceRoot(path: folder.appendingPathComponent(String($0.offset)).path, directory: $0.element.directory) }
        let copied = try stamps(copiedRoots), current = try stamps(binding.roots)
        guard copied == before, current == before else {
            let difference = Set(before.keys).union(copied.keys).filter { before[$0] != copied[$0] }.sorted().prefix(5).joined(separator: ", ")
            throw MaterialReader.error("백업 검증 실패로 쓰기를 시작하지 않았습니다: " + difference)
        }
        var backup = WorkspaceBackup(directory: folder.path, roots: binding.roots, before: before)
        for root in binding.roots where root.directory {
            if let top = try? run("/usr/bin/git", ["-C", root.path, "rev-parse", "--show-toplevel"]), URL(fileURLWithPath: top).resolvingSymlinksInPath().path == root.path {
                let head = (try? run("/usr/bin/git", ["-C", root.path, "rev-parse", "HEAD"])) ?? "unborn"
                if let commit = try? run("/usr/bin/git", ["-C", root.path, "stash", "create", "AI Illuminati backup"]), !commit.isEmpty {
                    try run("/usr/bin/git", ["-C", root.path, "update-ref", "refs/ai-illuminati/" + runID.uuidString, commit])
                    backup.gitStates.append(root.path + ": " + commit)
                } else { backup.gitStates.append(root.path + ": " + head) }
            }
        }
        try backup.save()
        return backup
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
            return WorkspaceChange(path: path, kind: before[key] == nil ? "added" : after![key] == nil ? "deleted" : "modified")
        }
        try save()
    }
    static func load(_ path: String) throws -> WorkspaceBackup {
        let url = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        guard url.path.hasPrefix(base.resolvingSymlinksInPath().path + "/") else { throw MaterialReader.error("앱 소유 백업이 아닙니다.") }
        return try JSONDecoder().decode(Self.self, from: Data(contentsOf: url.appendingPathComponent("complete.json")))
    }
    mutating func restore() throws {
        guard !restored, let after, try Self.stamps(roots) == after else { throw MaterialReader.error("작업 후 다른 변경이 있어 자동으로 덮어쓰지 않았습니다. 백업과 현재 파일을 먼저 비교하세요.") }
        let manager = FileManager.default
        var staged: [(URL, URL, URL)] = []
        var switched: [(URL, URL, Bool)] = []
        do {
            for (i, root) in roots.enumerated() {
                let original = URL(fileURLWithPath: root.path)
                let stage = original.deletingLastPathComponent().appendingPathComponent(".illuminati-restore-" + UUID().uuidString)
                let old = original.deletingLastPathComponent().appendingPathComponent(".illuminati-before-restore-" + UUID().uuidString)
                try Self.clone(URL(fileURLWithPath: directory).appendingPathComponent(String(i)), stage)
                staged.append((original, stage, old))
            }
            for (original, stage, old) in staged {
                let exists = manager.fileExists(atPath: original.path)
                if exists { try manager.moveItem(at: original, to: old) }
                switched.append((original, old, exists))
                try manager.moveItem(at: stage, to: original)
            }
            guard try Self.stamps(roots) == before else { throw MaterialReader.error("복원 해시가 백업과 일치하지 않습니다.") }
        } catch {
            for (original, old, existed) in switched.reversed() {
                if manager.fileExists(atPath: original.path) { try? manager.removeItem(at: original) }
                if existed { try? manager.moveItem(at: old, to: original) }
            }
            for (_, stage, _) in staged { try? manager.removeItem(at: stage) }
            throw error
        }
        for (_, _, old) in staged { try? manager.removeItem(at: old) }
        restored = true; try save()
    }
}
