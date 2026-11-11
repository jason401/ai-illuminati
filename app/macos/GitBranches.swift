import Foundation
import Combine

// Project info's read-only branch view: every local and origin branch with its role, nearest tag, last commit and how
// far it is from origin and from stable. It only reads refs; the refresh button runs one `git fetch` (never on open).
// The app's own backups (refs/ai-illuminati/*) are not branches and are never listed.
struct GitCounts: Equatable { var ahead: Int; var behind: Int }

struct GitBranchRow: Equatable, Identifiable {
    enum Role: Equatable { case deploy, beta, work, other }
    var ref: String           // refs/heads/main, refs/remotes/origin/main
    var branch: String        // main (without origin/)
    var remote: Bool
    var sha = "", subject = "", date: Date?
    var version: String?      // nearest tag, "+N" when the branch is N commits past it
    var current = false       // checked out in the project's folder
    var worktree: String?     // another worktree that has it checked out
    var origin: GitCounts?    // a local branch against origin/<same name>
    var onOrigin = true       // false: a local branch origin does not have
    var stable: GitCounts?    // main against the deployed stable
    var id: String { ref }
    var name: String { remote ? GitBranches.remote + "/" + branch : branch }
    var role: Role { GitBranches.role(branch) }
}

struct GitBranchReport: Equatable {
    var rows: [GitBranchRow] = []
    var hidden = 0                // branches past the shown limit
    var stableName: String?       // the deployed stable compared against (origin/stable, else stable)
    var mainName: String?
    var pending: GitCounts?       // main (ahead) against stable (behind = commits only stable has)
    var fetched: Date?            // the last fetch (FETCH_HEAD), so origin values are as of then
    var error: String?            // the last refresh or read failed; the rows are what could be read
}

enum GitBranches {
    static let remote = "origin", limit = 40

    static func role(_ branch: String) -> GitBranchRow.Role {
        if branch == "stable" { return .deploy }
        if branch == "main" { return .beta }
        return ["feature/", "fix/", "codex/"].contains(where: branch.hasPrefix) ? .work : .other
    }
    static func label(_ role: GitBranchRow.Role) -> String? {
        switch role {
        case .deploy: return L("배포", "Release")
        case .beta: return L("베타·개발", "Beta · dev")
        case .work: return L("작업 중", "In progress")
        case .other: return nil
        }
    }

    // `git describe --tags --long`: v0.2.0-5-gabc1234 → v0.2.0+5, v0.2.0-0-g… → v0.2.0 (tags may contain "-").
    static func version(_ described: String) -> String? {
        var parts = described.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "-")
        guard parts.count >= 3, parts.removeLast().hasPrefix("g"), let n = Int(parts.removeLast()) else { return nil }
        let tag = parts.joined(separator: "-")
        return tag.isEmpty ? nil : n == 0 ? tag : "\(tag)+\(n)"
    }
    // `rev-list --left-right --count a...b`: commits only in a, only in b.
    static func counts(_ text: String) -> GitCounts? {
        let n = text.split(whereSeparator: { $0 == "\t" || $0 == " " || $0 == "\n" }).compactMap { Int($0) }
        return n.count == 2 ? GitCounts(ahead: n[0], behind: n[1]) : nil
    }
    // `worktree list --porcelain`: the folder each branch is checked out in.
    static func worktrees(_ text: String) -> [String: String] {
        var found: [String: String] = [:], path: String?
        for line in text.components(separatedBy: "\n") {
            if line.hasPrefix("worktree ") { path = String(line.dropFirst(9)) }
            else if line.hasPrefix("branch "), let path { found[String(line.dropFirst(7))] = path }
        }
        return found
    }
    static func canonical(_ path: String) -> String { URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path }

    // Reads the branches of the repository at `root` with `git` (arguments → output, throws on failure).
    static func read(root: String, common: String? = nil, git: ([String]) throws -> String) -> GitBranchReport {
        var report = GitBranchReport()
        let listing: String
        do {
            listing = try git(["for-each-ref", "--format=%(refname)%00%(objectname:short)%00%(committerdate:unix)%00%(symref)%00%(subject)",
                               "refs/heads/", "refs/remotes/\(remote)/"])
        } catch { report.error = L("브랜치를 읽지 못했어요.", "Could not read the branches."); return report }
        let local = "refs/heads/", origin = "refs/remotes/\(remote)/"
        var rows: [GitBranchRow] = []
        for line in listing.components(separatedBy: "\n") {
            let f = line.components(separatedBy: "\u{0}")
            guard f.count >= 5, f[3].isEmpty else { continue }   // origin/HEAD is a pointer, not a branch
            let ref = f[0], isLocal = ref.hasPrefix(local)
            guard isLocal || ref.hasPrefix(origin), !ref.hasPrefix("refs/ai-illuminati/") else { continue }
            let branch = String(ref.dropFirst(isLocal ? local.count : origin.count))
            rows.append(GitBranchRow(ref: ref, branch: branch, remote: !isLocal, sha: f[1], subject: f[4...].joined(separator: " "),
                                     date: Double(f[2]).map { Date(timeIntervalSince1970: $0) }))
        }
        let refs = Set(rows.map(\.ref))
        // The project's folder and its other worktrees share these refs; each one has its own checked-out branch.
        let here = canonical(root)
        for (ref, path) in worktrees((try? git(["worktree", "list", "--porcelain"])) ?? "") {
            guard let i = rows.firstIndex(where: { $0.ref == ref }) else { continue }
            if canonical(path) == here { rows[i].current = true } else { rows[i].worktree = (path as NSString).lastPathComponent }
        }
        if !rows.contains(where: \.current), let head = try? git(["symbolic-ref", "-q", "HEAD"]), let i = rows.firstIndex(where: { $0.ref == head }) {
            rows[i].current = true
        }
        func best(_ branch: String) -> String? { [origin + branch, local + branch].first(where: refs.contains) }
        let stable = best("stable"), main = best("main")
        report.stableName = stable.map { $0.hasPrefix(origin) ? "\(remote)/stable" : "stable" }
        report.mainName = main.map { $0.hasPrefix(origin) ? "\(remote)/main" : "main" }
        if let stable, let main { report.pending = (try? git(["rev-list", "--left-right", "--count", "\(main)...\(stable)"])).flatMap(counts) }

        // Most important first: stable, main, the checked-out one, then the newest; local before origin.
        let checkedOut = Set(rows.filter(\.current).map(\.branch))
        func rank(_ r: GitBranchRow) -> Int { r.role == .deploy ? 0 : r.role == .beta ? 1 : checkedOut.contains(r.branch) ? 2 : 3 }
        let newest = Dictionary(rows.map { ($0.branch, $0.date ?? .distantPast) }, uniquingKeysWith: max)
        rows.sort { a, b in
            if a.branch != b.branch {
                let (ra, rb) = (rank(a), rank(b))
                return ra != rb ? ra < rb : newest[a.branch]! != newest[b.branch]! ? newest[a.branch]! > newest[b.branch]! : a.branch < b.branch
            }
            return !a.remote && b.remote
        }
        report.hidden = max(0, rows.count - limit)
        rows = Array(rows.prefix(limit))
        for i in rows.indices {
            let ref = rows[i].ref
            rows[i].version = (try? git(["describe", "--tags", "--long", ref])).flatMap(version)
            if !rows[i].remote {
                if refs.contains(origin + rows[i].branch) {
                    rows[i].origin = (try? git(["rev-list", "--left-right", "--count", "\(ref)...\(origin + rows[i].branch)"])).flatMap(counts)
                } else { rows[i].onOrigin = false }
            }
            if rows[i].branch == "main", let stable { rows[i].stable = (try? git(["rev-list", "--left-right", "--count", "\(ref)...\(stable)"])).flatMap(counts) }
        }
        report.rows = rows
        let fetchHead = URL(fileURLWithPath: common ?? (here + "/.git")).appendingPathComponent("FETCH_HEAD").path
        report.fetched = (try? FileManager.default.attributesOfItem(atPath: fetchHead))?[.modificationDate] as? Date
        return report
    }

    // The one line on top of the list.
    static func summary(_ report: GitBranchReport) -> String? {
        guard let main = report.mainName, let stable = report.stableName else {
            return report.rows.isEmpty ? nil : report.stableName == nil ? L("stable 브랜치가 없어요 (배포 브랜치 없음).", "No stable branch (nothing released from a branch).") : nil
        }
        guard let c = report.pending else { return nil }
        var text = c.ahead > 0 ? L("배포 대기 중: \(main)이 \(stable)보다 \(c.ahead)커밋 앞서 있어요", "Waiting to release: \(main) is \(c.ahead) commits ahead of \(stable)")
                               : L("배포 최신 상태", "Release is up to date")
        if c.behind > 0 { text += L(" (\(stable)에만 있는 커밋 \(c.behind)개)", " (\(c.behind) commits only on \(stable))") }
        return text
    }

    // What the row's branch is ahead of or behind.
    static func differences(_ row: GitBranchRow, stable: String?) -> [String] {
        var out: [String] = []
        if let s = row.stable, let stable {
            if s.ahead > 0 { out.append(L("\(stable)보다 \(s.ahead)커밋 앞섬", "\(s.ahead) ahead of \(stable)")) }
            if s.behind > 0 { out.append(L("\(stable)보다 \(s.behind)커밋 뒤처짐", "\(s.behind) behind \(stable)")) }
            if s.ahead == 0 && s.behind == 0 { out.append(L("\(stable)와 같음", "same as \(stable)")) }
        }
        if !row.remote {
            if !row.onOrigin { out.append(L("\(remote)에 없음", "not on \(remote)")) }
            else if let o = row.origin {
                if o.ahead > 0 { out.append(L("로컬이 \(remote)보다 \(o.ahead)커밋 앞섬", "local \(o.ahead) ahead of \(remote)")) }
                if o.behind > 0 { out.append(L("로컬이 \(remote)보다 \(o.behind)커밋 뒤처짐", "local \(o.behind) behind \(remote)")) }
                if o.ahead == 0 && o.behind == 0 { out.append(L("\(remote)와 같음", "same as \(remote)")) }
            }
        }
        return out
    }
}

// Reports per project folder, read in the background (each git call has a short limit) so the screen never waits.
final class GitBranchStore: ObservableObject {
    static let shared = GitBranchStore()
    @Published private(set) var reports: [String: GitBranchReport] = [:]
    @Published private(set) var busy: Set<String> = []
    private let queue = DispatchQueue(label: "ai-illuminati.git-branches", qos: .userInitiated)

    // Local values only, unless `fetch`: then `git fetch origin` first; when that fails the local values still show.
    func load(_ binding: ProjectBinding, fetch: Bool = false) {
        let root = binding.root
        guard !busy.contains(root) else { return }
        busy.insert(root)
        queue.async {
            var failed: String?
            if fetch {
                do { _ = try ProjectProcess.git(["fetch", "-q", GitBranches.remote], root: root, timeout: 30) }
                catch { failed = L("새로 가져오지 못했어요. 마지막으로 가져온 값이에요.", "Could not fetch; showing the last fetched values.") }
            }
            var report = GitBranches.read(root: root, common: binding.common.isEmpty ? nil : binding.common) {
                try ProjectProcess.git($0, root: root, timeout: 10)
            }
            if let failed { report.error = report.error ?? failed }
            DispatchQueue.main.async { self.reports[root] = report; self.busy.remove(root) }
        }
    }
}
