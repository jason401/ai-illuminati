import Foundation
import Combine
import AILocalization
import AIWorkspace
import AIProjects

// Project info's read-only branch view: every local and origin branch with its role, nearest tag, last commit and how
// far it is from origin and from stable. It only reads refs; the refresh button runs one `git fetch` (never on open) and,
// when that finds main behind origin/main, offers to pull it (the user presses the button; never automatic).
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
    var hidden = 0                // branches past the read limit (not read at all)
    var stableName: String?       // the deployed stable compared against (origin/stable, else stable)
    var mainName: String?
    var pending: GitCounts?       // main (ahead) against stable (behind = commits only stable has)
    var fetched: Date?            // the last fetch (FETCH_HEAD), so origin values are as of then
    var error: String?            // the last refresh or read failed; the rows are what could be read
}

enum GitBranches {
    static let remote = "origin", limit = 200   // read up to limit
    // --prune drops origin/* refs whose branch was deleted on the remote, even without fetch.prune; local branches stay.
    static let fetchArgs = ["fetch", "-q", "--prune", remote]

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
    static func read(root: String, git: ([String]) throws -> String) -> GitBranchReport {
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
        // Each worktree has its own FETCH_HEAD (in its own Git folder, not the shared one).
        if let path = try? git(["rev-parse", "--git-path", "FETCH_HEAD"]), !path.isEmpty {
            let fetchHead = path.hasPrefix("/") ? path : here + "/" + path
            report.fetched = (try? FileManager.default.attributesOfItem(atPath: fetchHead))?[.modificationDate] as? Date
        }
        return report
    }

    // What the refresh offers for local main against origin/main; nil when there is nothing to pull.
    enum PullOffer: Equatable { case pull(Int), dirty(Int), diverged(GitCounts), otherBranch(Int) }
    static func pullOffer(_ report: GitBranchReport, dirty: Bool) -> PullOffer? {
        guard let main = report.rows.first(where: { !$0.remote && $0.branch == "main" }), let c = main.origin, c.behind > 0 else { return nil }
        if !main.current { return .otherBranch(c.behind) }
        if c.ahead > 0 { return .diverged(c) }   // ff-only would fail
        return dirty ? .dirty(c.behind) : .pull(c.behind)
    }
    static func offerText(_ offer: PullOffer) -> String {
        switch offer {
        case .pull(let n): return L("origin/main에 새 커밋 \(n)개가 있어요. 최신 main을 받을까요?", "origin/main has \(n) new commits. Pull the latest main?")
        case .dirty(let n): return L("origin/main에 새 커밋 \(n)개가 있지만, 커밋하지 않은 변경이 있어 받을 수 없어요.", "origin/main has \(n) new commits, but there are uncommitted changes, so it cannot pull.")
        case .diverged(let c): return L("main이 origin/main과 갈라졌어요 (올리지 않은 커밋 \(c.ahead)개, 받지 않은 커밋 \(c.behind)개). 직접 정리해야 해요.",
                                        "main and origin/main have diverged (\(c.ahead) not pushed, \(c.behind) not pulled); sort it out by hand.")
        case .otherBranch(let n): return L("origin/main에 새 커밋 \(n)개가 있어요. 지금 이 폴더는 main이 아니라 여기서는 받지 않아요.", "origin/main has \(n) new commits; this folder is not on main, so it does not pull here.")
        }
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
}

// The simple overview: one line per branch name (local and origin together), the main ones first with what they are
// for, and the rest grouped by kind (AI worktrees, trial/, …) so a long list of side branches reads as a few lines.
struct GitBranchLine: Equatable, Identifiable {
    enum Place: Equatable { case both, localOnly, originOnly }
    var branch: String
    var role: GitBranchRow.Role
    var place: Place
    var sync: GitCounts?      // local against origin when both have it
    var version: String?
    var date: Date?
    var current = false
    var worktree: String?
    var id: String { branch }
}

struct GitBranchGroup: Equatable, Identifiable {
    var key: String           // "worktree-agent-", "trial/", "" (others)
    var lines: [GitBranchLine]
    var id: String { key }
    var latest: Date? { lines.compactMap(\.date).max() }
}

extension GitBranches {
    // Version and date come from one ref: origin for the release branch (what installed apps get), else the local one.
    static func lines(_ report: GitBranchReport) -> [GitBranchLine] {
        var order: [String] = [], local: [String: GitBranchRow] = [:], remote: [String: GitBranchRow] = [:]
        for row in report.rows {
            if local[row.branch] == nil && remote[row.branch] == nil { order.append(row.branch) }
            if row.remote { remote[row.branch] = row } else { local[row.branch] = row }
        }
        return order.map { branch in
            let l = local[branch], r = remote[branch]
            let source = (GitBranches.role(branch) == .deploy ? r ?? l : l ?? r)!
            return GitBranchLine(branch: branch, role: source.role,
                                 place: l == nil ? .originOnly : r != nil || l!.onOrigin ? .both : .localOnly,
                                 sync: l?.origin, version: source.version, date: source.date,
                                 current: l?.current == true || r?.current == true, worktree: l?.worktree ?? r?.worktree)
        }
    }
    // The branches shown on their own line: stable, main and the checked-out one.
    static func main(_ lines: [GitBranchLine]) -> [GitBranchLine] { lines.filter { $0.role == .deploy || $0.role == .beta || $0.current } }
    static func groups(_ lines: [GitBranchLine]) -> [GitBranchGroup] {
        var order: [String] = [], found: [String: [GitBranchLine]] = [:]
        for line in lines where !(line.role == .deploy || line.role == .beta || line.current) {
            let key = line.branch.hasPrefix("worktree-agent-") ? "worktree-agent-"
                : line.branch.firstIndex(of: "/").map { String(line.branch[...$0]) } ?? ""
            if found[key] == nil { order.append(key) }
            found[key, default: []].append(line)
        }
        // Named kinds first, the leftovers last.
        return (order.filter { !$0.isEmpty } + order.filter(\.isEmpty)).map { GitBranchGroup(key: $0, lines: found[$0]!) }
    }

    // What a branch (or a group of them) is used for.
    static func purpose(_ line: GitBranchLine) -> String {
        switch line.role {
        case .deploy: return L("설치된 앱이 받아 가는 배포본", "What installed apps update to")
        case .beta: return L("개발한 것이 모이는 곳", "Where finished work lands")
        default: return line.current ? L("지금 이 폴더에서 작업 중", "Checked out in this folder") : L("작업용 브랜치", "Work branch")
        }
    }
    static func purpose(_ group: GitBranchGroup) -> String {
        switch group.key {
        case "worktree-agent-": return L("AI 병렬 작업용 임시 브랜치", "Temporary branches for parallel AI work")
        case "trial/": return L("시험 작업", "Trials")
        case "feature/", "fix/", "codex/": return L("작업 중", "In progress")
        case "": return L("기타 브랜치", "Other branches")
        default: return L("\(group.key) 브랜치", "\(group.key) branches")
        }
    }
    static func place(_ place: GitBranchLine.Place) -> String {
        switch place {
        case .both: return L("이 Mac과 \(remote)", "this Mac and \(remote)")
        case .localOnly: return L("이 Mac에만", "this Mac only")
        case .originOnly: return L("\(remote)에만", "\(remote) only")
        }
    }
    static func place(_ group: GitBranchGroup) -> String {
        let places = Set(group.lines.map(\.place))
        return places.count == 1 ? place(places.first!) : L("이 Mac·\(remote) 섞임", "mixed: this Mac and \(remote)")
    }
    static func sync(_ line: GitBranchLine) -> String? {
        guard line.place == .both, let c = line.sync, c.ahead > 0 || c.behind > 0 else { return nil }
        var parts: [String] = []
        if c.ahead > 0 { parts.append(L("올리지 않은 커밋 \(c.ahead)개", "\(c.ahead) not pushed")) }
        if c.behind > 0 { parts.append(L("받지 않은 커밋 \(c.behind)개", "\(c.behind) not pulled")) }
        return parts.joined(separator: " · ")
    }
    // How the branches are used, when the project releases from stable.
    static func flow(_ report: GitBranchReport) -> String? {
        guard report.stableName != nil, report.mainName != nil else { return nil }
        return L("작업 브랜치 → main에 합침(베타) → stable로 올림(배포)", "work branches → merged into main (beta) → pushed to stable (release)")
    }
}

// Reports per project folder, read in the background (each git call has a short limit) so the screen never waits.
final class GitBranchStore: ObservableObject {
    static let shared = GitBranchStore()
    @Published private(set) var reports: [String: GitBranchReport] = [:]
    @Published private(set) var busy: Set<String> = []
    @Published private(set) var publishing: Set<String> = []
    @Published private(set) var publishMessages: [String: String] = [:]
    @Published private(set) var publishRooms: [String: UUID] = [:]
    @Published private(set) var offers: [String: GitBranches.PullOffer] = [:]   // set by a refresh only
    @Published private(set) var pulling: Set<String> = []
    @Published private(set) var pullMessages: [String: String] = [:]

    func dismissOffer(_ root: String) { offers[root] = nil }
    func pull(_ binding: ProjectBinding) {
        let root = binding.root
        guard !pulling.contains(root) else { return }
        pulling.insert(root); pullMessages[root] = L("main 받는 중…", "Pulling main…")
        DispatchQueue.global(qos: .userInitiated).async {
            let message: String
            do {
                _ = try GitLink.shared.pullMain(binding)
                message = L("최신 main을 받았어요. 소스만 바뀌었으니, 실행 중인 앱에 반영하려면 다시 빌드해야 해요.",
                            "Pulled the latest main. Only the source changed; rebuild to update the running app.")
            } catch {
                message = L("받지 못했어요: ", "Could not pull: ") + error.localizedDescription
            }
            DispatchQueue.main.async {
                self.pullMessages[root] = message; self.pulling.remove(root); self.offers[root] = nil
                self.load(binding)
            }
        }
    }

    func publish(_ binding: ProjectBinding, room: UUID) {
        let root = binding.root
        guard !publishing.contains(root) else { return }
        publishing.insert(root); publishRooms[root] = room
        publishMessages[root] = L("배포할 변경 확인 중…", "Checking changes to publish…")
        // Approval may wait for minutes; keep the branch-reading queue free.
        DispatchQueue.global(qos: .userInitiated).async {
            let message: String
            do {
                let result = try GitLink.shared.publishStable(binding, room: room) { waiting in
                    DispatchQueue.main.async {
                        self.publishMessages[root] = waiting ? L("변경을 확인하고 아래에서 승인해 주세요.", "Review the changes and approve below.")
                            : L("stable에 배포 중…", "Publishing to stable…")
                    }
                }
                if let line = result.components(separatedBy: "\n").last, line.hasPrefix("Published ") {
                    message = L("배포 완료 · ", "Published · ") + String(line.dropFirst(10).prefix(12))
                } else { message = result }
            } catch {
                message = L("배포하지 못했어요: ", "Could not publish: ") + error.localizedDescription
            }
            DispatchQueue.main.async {
                self.publishMessages[root] = message; self.publishing.remove(root)
                for request in ProjectCenter.shared.expired where request.room == room && request.title == "stable 배포 / Publish stable" && request.detail.hasPrefix(root + "\n") {
                    ProjectCenter.shared.dismiss(request.id)
                }
                self.load(binding, fetch: true)
            }
        }
    }

    @Published var expanded: Set<String> = []   // folders whose whole branch list is shown
    private let queue = DispatchQueue(label: "ai-illuminati.git-branches", qos: .userInitiated)

    // Local values only, unless `fetch`: then `git fetch --prune origin` first; when that fails the local values still show.
    func load(_ binding: ProjectBinding, fetch: Bool = false) {
        let root = binding.root
        guard !busy.contains(root) else { return }
        busy.insert(root)
        queue.async {
            var failed: String?
            if fetch {
                do { _ = try ProjectProcess.git(GitBranches.fetchArgs, root: root, timeout: 30) }
                catch { failed = L("새로 가져오지 못했어요. 마지막으로 가져온 값이에요.", "Could not fetch; showing the last fetched values.") }
            }
            var report = GitBranches.read(root: root) {
                try ProjectProcess.git($0, root: root, timeout: 10)
            }
            if let failed { report.error = report.error ?? failed }
            // Only a successful refresh asks; a plain read only drops an offer that no longer applies (pulled elsewhere).
            let offer = fetch && failed == nil
                ? GitBranches.pullOffer(report, dirty: (try? ProjectProcess.git(["status", "--porcelain"], root: root, timeout: 10)).map { !$0.isEmpty } ?? true)
                : nil
            DispatchQueue.main.async {
                self.reports[root] = report; self.busy.remove(root)
                if fetch { self.offers[root] = offer; self.pullMessages[root] = nil }
                else if GitBranches.pullOffer(report, dirty: false) == nil { self.offers[root] = nil }
            }
        }
    }
}
