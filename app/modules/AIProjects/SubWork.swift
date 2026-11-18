import Foundation
import CryptoKit
import Darwin
import AIAccounts
import AILocalization
import AIRuntime
import AIWorkspace

// A sub-room's Git work (docs/SUBROOM_PLAN.md 3 and 5): the app makes its work tree outside the repository, merges what
// it reported into the main work tree and removes the tree once that is pushed. Every step that changes refs or the work
// tree list runs inside the repository's refs lock. Never stash, reset or force: a step that cannot go safely stops and
// says why, and only a merge the app itself has just started is aborted. The one exception is the user's own Discard.
public enum SubWork {
    // One sub-room's work tree: its folder, its local branch sub/<split>/<n> and the main HEAD it started from.
    public struct Tree: Codable, Equatable {
        public var path: String, branch: String, base: String
        public init(path: String, branch: String, base: String) { self.path = path; self.branch = branch; self.base = base }
    }
    // What a merge found: `merged` is the new main HEAD (nil: conflicts, nothing merged), `conflicts` the files the check
    // found against `head` (the main HEAD it checked), `outside` the changed files outside the sub-room's owned ones (a warning).
    public struct Merge: Equatable {
        public var merged: String?
        public var conflicts: [String], outside: [String], head: String
    }
    // …/AI Illuminati/worktrees/<repo hash>/<split>-<n>: outside the repository, so the main room's writable root never
    // contains a sub-room's files. Under a test home in tests (AccountStore.supportDir).
    static func folder(common: String, split: String, n: Int) -> String { folder(common: common, name: "\(split)-\(n)") }
    static func folder(common: String, name: String) -> String {
        let hash = SHA256.hash(data: Data(common.utf8)).map { String(format: "%02x", $0) }.joined().prefix(16)
        return URL(fileURLWithPath: AccountStore.supportDir).appendingPathComponent("worktrees").appendingPathComponent(String(hash))
            .appendingPathComponent(name).path
    }
    static func branch(split: String, n: Int) -> String { "sub/\(split)/\(n)" }

    private static func fail(_ korean: String, _ english: String) -> Error { ProjectError.make(L(korean, english)) }
    private static func git(_ args: [String], _ root: String, _ token: DebateCancellation?, timeout: TimeInterval = 120) throws -> String {
        try ProjectProcess.git(["-c", "core.quotePath=false"] + args, root: root, token: token, timeout: timeout)
    }
    private static func reply(_ args: [String], _ root: String, _ token: DebateCancellation?, timeout: TimeInterval = 120) throws -> ProjectProcess.Reply {
        try ProjectProcess.gitReply(["-c", "core.quotePath=false"] + args, root: root, token: token, timeout: timeout)
    }
    // Paths from -z output: NUL apart, as they are (a tab, newline or quote in a name is not escaped).
    private static func paths(_ text: String) -> [String] { text.split(separator: "\0").map(String.init).filter { !$0.isEmpty } }
    private static func isAncestor(_ a: String, _ b: String, _ root: String, _ token: DebateCancellation?) throws -> Bool {
        let r = try reply(["merge-base", "--is-ancestor", a, b], root, token)
        guard r.status <= 1 else { throw ProjectError.make("git merge-base failed: " + r.output) }
        return r.status == 0
    }
    private static func merging(_ root: String, _ token: DebateCancellation?) throws -> Bool {
        try reply(["rev-parse", "-q", "--verify", "MERGE_HEAD"], root, token).status == 0
    }
    // A merge the app starts (no merge was in progress: `clean` checked). Stopped or timed out midway, the merge it may have
    // left is aborted without the token, which is cancelled by then; the error still goes back.
    private static func started(_ args: [String], _ root: String, _ token: DebateCancellation?) throws -> ProjectProcess.Reply {
        do { return try reply(args, root, token) }
        catch { if (try? merging(root, nil)) == true { _ = try? git(["merge", "--abort"], root, nil) }; throw error }
    }
    private static func clean(_ root: String, _ token: DebateCancellation?, _ korean: String, _ english: String) throws {
        guard try git(["status", "--porcelain"], root, token).isEmpty, try !merging(root, token) else { throw fail(korean, english) }
    }
    private static func project(_ binding: ProjectBinding) throws -> String {
        guard !binding.isDocuments, !binding.isFolderless, let common = ProjectWork.commonDir(binding.root) else { throw ProjectError.make("A Git project is required.") }
        return common
    }
    // The sub-room's work tree lock, held while the app changes that tree: a sub-room still writing (here or in another
    // app instance) makes the step stop instead.
    private static func holding<T>(_ tree: Tree, _ body: () throws -> T) throws -> T {
        let held: [String]
        do { held = try ProjectWork.acquire(WorkspaceBinding(roots: [WorkspaceRoot(path: tree.path, directory: true, writable: true)], level: .execute)) }
        catch where ProjectWork.isBusy(error.localizedDescription) { throw fail("하위방이 아직 이 작업 폴더를 쓰고 있어요. 끝난 뒤 다시 해 주세요.", "The sub-room is still writing its work tree; try again once it ends.") }
        defer { ProjectWork.release(held, notify: false) }
        return try body()
    }

    // A new work tree for sub-room n of a split, on branch sub/<split>/<n> from the main HEAD. Only from a clean main work
    // tree (the start must be exactly what is committed). The caller holds the main work tree (its turn).
    public static func create(_ binding: ProjectBinding, split: String, n: Int, token: DebateCancellation? = nil) throws -> Tree {
        guard split.range(of: "^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$", options: .regularExpression) != nil, (1...9).contains(n) else {
            throw ProjectError.make("Invalid split id or sub-room number.")
        }
        let common = try project(binding), path = folder(common: common, split: split, n: n), name = branch(split: split, n: n)
        return try ProjectWork.withRefs(binding.root, token: token) {
            try clean(binding.root, token, "메인 작업 폴더에 커밋하지 않은 변경이 있어 나누지 않았어요. 먼저 커밋해 주세요.",
                      "The main work tree has uncommitted changes; commit them before splitting.")
            guard !FileManager.default.fileExists(atPath: path) else { throw ProjectError.make("The sub-room's work tree folder already exists: " + path) }
            guard try reply(["rev-parse", "-q", "--verify", "refs/heads/" + name], binding.root, token).status != 0 else { throw ProjectError.make("The branch already exists: " + name) }
            let base = try git(["rev-parse", "--verify", "HEAD^{commit}"], binding.root, token)
            try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            _ = try git(["worktree", "add", "-b", name, path, base], binding.root, token, timeout: 300)
            return Tree(path: URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path, branch: name, base: base)
        }
    }

    // A Goal's work tree (TODO Step/Milestone): branch todo-goal/<first 8 of the Goal id> in worktrees/<repo hash>/goal-<8>,
    // started from the remote's `target` branch as fetched now, not the local HEAD: commits of plain chats not pushed yet
    // stay out of the Goal. The same Goal gets the same tree back, also after a restart (the Goal id and start are kept in
    // the branch's Git config); a folder removed by hand is added again on the branch. Main's own state does not matter.
    public static func goal(_ binding: ProjectBinding, goal: UUID, target: String, token: DebateCancellation? = nil) throws -> Tree {
        let common = try project(binding), id = goal.uuidString.lowercased(), short = String(id.prefix(8)), name = "todo-goal/" + short
        let path = folder(common: common, name: "goal-" + short)
        guard !binding.remote.isEmpty, !target.hasPrefix("-"), (try? git(["check-ref-format", "--branch", target], binding.root, token)) == target else {
            throw ProjectError.make("A remote and a valid target branch are required for a Goal.")
        }
        let key = "branch." + name + "."
        func config(_ field: String) -> String? { try? git(["config", "--get", key + field], binding.root, token) }
        func resolved() -> String { URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path }
        return try ProjectWork.withRefs(binding.root, token: token) {
            if try reply(["rev-parse", "-q", "--verify", "refs/heads/" + name], binding.root, token).status == 0 {
                guard config("todogoal") == id, let base = config("todogoalbase") else { throw ProjectError.make("The branch belongs to another Goal or was not made by the app: " + name) }
                var listed: String?, current: String?
                for field in paths(try git(["worktree", "list", "--porcelain", "-z"], binding.root, token)) {
                    if field.hasPrefix("worktree ") { current = String(field.dropFirst(9)) }
                    else if field == "branch refs/heads/" + name { listed = current }
                }
                if let listed, FileManager.default.fileExists(atPath: listed) {
                    guard URL(fileURLWithPath: listed).resolvingSymlinksInPath().standardizedFileURL.path == resolved() else { throw ProjectError.make("The Goal's branch is checked out elsewhere: " + listed) }
                    return Tree(path: resolved(), branch: name, base: base)
                }
                guard !FileManager.default.fileExists(atPath: path) else { throw ProjectError.make("The Goal's work tree folder exists but is not its work tree: " + path) }
                _ = try git(["worktree", "prune"], binding.root, token)
                try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
                _ = try git(["worktree", "add", path, name], binding.root, token, timeout: 300)
                return Tree(path: resolved(), branch: name, base: base)
            }
            guard !FileManager.default.fileExists(atPath: path) else { throw ProjectError.make("The Goal's work tree folder already exists: " + path) }
            let remoteRef = "refs/remotes/\(binding.remote)/\(target)"
            _ = try git(["fetch", "--no-tags", binding.remote, "+refs/heads/\(target):\(remoteRef)"], binding.root, token, timeout: 180)
            let base = try git(["rev-parse", "--verify", remoteRef + "^{commit}"], binding.root, token)
            // Kept before the branch exists: a branch without them is never taken for this Goal's.
            _ = try git(["config", key + "todogoal", id], binding.root, token)
            _ = try git(["config", key + "todogoalbase", base], binding.root, token)
            try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            _ = try git(["worktree", "add", "--no-track", "-b", name, path, base], binding.root, token, timeout: 300)
            return Tree(path: resolved(), branch: name, base: base)
        }
    }

    // Removes the work tree and its branch, only once its work is in the main HEAD and pushed (the remote-tracking ref of the
    // main work tree's branch contains the branch's tip) and the tree has nothing uncommitted. Otherwise both stay.
    public static func remove(_ binding: ProjectBinding, _ tree: Tree, token: DebateCancellation? = nil) throws {
        _ = try project(binding)
        guard tree.branch.hasPrefix("sub/") else { throw ProjectError.make("Not a sub-room branch: " + tree.branch) }
        try holding(tree) {
            try ProjectWork.withRefs(binding.root, token: token) {
                let tip = try git(["rev-parse", "--verify", "refs/heads/" + tree.branch + "^{commit}"], binding.root, token)
                let current = try git(["branch", "--show-current"], binding.root, token)
                guard !current.isEmpty, !binding.remote.isEmpty,
                      try reply(["rev-parse", "-q", "--verify", "refs/remotes/\(binding.remote)/\(current)"], binding.root, token).status == 0,
                      try isAncestor(tip, "HEAD", binding.root, token), try isAncestor(tip, "refs/remotes/\(binding.remote)/\(current)", binding.root, token) else {
                    throw fail("하위 작업이 아직 합쳐지거나 push되지 않아 작업 폴더를 남겨 뒀어요.", "The sub-room's work is not merged and pushed yet; its work tree stays.")
                }
                if FileManager.default.fileExists(atPath: tree.path) {
                    try clean(tree.path, token, "하위 작업 폴더에 커밋하지 않은 변경이 있어 남겨 뒀어요.", "The sub-room's work tree has uncommitted changes; it stays.")
                    _ = try git(["worktree", "remove", tree.path], binding.root, token)
                } else { _ = try git(["worktree", "prune"], binding.root, token) }
                _ = try git(["branch", "-d", tree.branch], binding.root, token)
                // The repository's folder under worktrees/ goes with its last tree (rmdir: only when empty).
                _ = rmdir((tree.path as NSString).deletingLastPathComponent)
            }
        }
    }

    // Merges what a sub-room reported (`sha`, recorded at sub_report) into the main work tree. `reported`: the split record
    // says the sub-room reported and its turn ended. Refuses an SHA that does not descend from the tree's start or is not on
    // its branch, a sub-room still writing, a main work tree that is not clean. Checks conflicts against the main HEAD as it
    // is now (`merge-tree --write-tree`, nothing touched), so a second sub-room is checked after the first was merged; with
    // conflicts nothing is merged and the files are returned. Files changed outside `owned` (paths, folders or globs) are
    // only reported. The caller holds the main work tree (its turn).
    public static func merge(_ binding: ProjectBinding, _ tree: Tree, sha asked: String, owned: [String], reported: Bool,
                             token: DebateCancellation? = nil) throws -> Merge {
        _ = try project(binding)
        guard reported else { throw fail("하위방이 아직 보고하지 않았어요.", "The sub-room has not reported yet.") }
        guard asked.range(of: "^[0-9a-f]{7,64}$", options: .regularExpression) != nil else { throw ProjectError.make("Give the reported commit SHA.") }
        return try holding(tree) {
            try ProjectWork.withRefs(binding.root, token: token) {
                guard let sha = try? git(["rev-parse", "--verify", asked + "^{commit}"], binding.root, token) else { throw ProjectError.make("Unknown commit: " + asked) }
                guard sha != tree.base, try isAncestor(tree.base, sha, binding.root, token) else {
                    throw fail("보고한 커밋이 하위방의 출발 커밋 뒤에 이어지지 않아 합치지 않았어요.", "The reported commit does not descend from the sub-room's start; not merged.")
                }
                guard try isAncestor(sha, "refs/heads/" + tree.branch, binding.root, token) else {
                    throw fail("보고한 커밋이 하위방 브랜치에 없어 합치지 않았어요.", "The reported commit is not on the sub-room's branch; not merged.")
                }
                try clean(binding.root, token, "메인 작업 폴더에 커밋하지 않은 변경이 있어 합치지 않았어요. 먼저 커밋해 주세요.",
                          "The main work tree has uncommitted changes; commit them before merging.")
                let head = try git(["rev-parse", "HEAD"], binding.root, token)
                // Only the sub-room's own changes: from where it meets the main HEAD (after a resync, the main it took in).
                let changed = paths(try git(["diff", "-z", "--name-only", "--no-renames", head + "..." + sha], binding.root, token))
                let outside = changed.filter { path in !owned.contains { owns($0, path) } }
                if try isAncestor(sha, head, binding.root, token) { return Merge(merged: head, conflicts: [], outside: outside, head: head) }
                let check = try reply(["merge-tree", "--write-tree", "-z", "--name-only", "--no-messages", head, sha], binding.root, token)
                guard check.status <= 1 else { throw ProjectError.make("git merge-tree failed: " + check.output) }
                if check.status == 1 {
                    var seen = Set<String>()
                    let files = paths(check.output).dropFirst().filter { seen.insert($0).inserted }
                    return Merge(merged: nil, conflicts: Array(files), outside: outside, head: head)
                }
                let message = "Merge \(tree.branch) (\(sha.prefix(10)))"
                let result = try started(["merge", "--no-ff", "--no-edit", "-m", message, sha], binding.root, token)
                if result.status != 0 {
                    // The check passed but Git did not: undo only the merge just started (no reset, no stash).
                    if try merging(binding.root, token) { _ = try? git(["merge", "--abort"], binding.root, token) }
                    throw ProjectError.make(L("합치기가 예상과 달리 실패해 방금 시작한 merge만 되돌렸어요: ", "The merge failed unexpectedly; only the merge just started was aborted: ") + result.output)
                }
                return Merge(merged: try git(["rev-parse", "HEAD"], binding.root, token), conflicts: [], outside: outside, head: head)
            }
        }
    }
    static func owns(_ owned: String, _ path: String) -> Bool {
        let pattern = owned.hasPrefix("./") ? String(owned.dropFirst(2)) : owned
        if pattern.isEmpty { return false }
        if pattern.hasSuffix("/") { return path.hasPrefix(pattern) }
        return path == pattern || path.hasPrefix(pattern + "/") || (pattern.contains("*") && fnmatch(pattern, path, 0) == 0)
    }

    // sub_report: what the sub-room reports is its work tree's HEAD, only when everything is committed (no merge left half
    // done) on its own branch after its start. Returns that SHA and the files it changed since the start.
    public static func report(_ tree: Tree, token: DebateCancellation? = nil) throws -> (sha: String, changed: [String]) {
        try clean(tree.path, token, "커밋하지 않은 변경이 있어요. git_commit으로 먼저 커밋한 뒤 보고해 주세요.",
                  "There are uncommitted changes; commit them with git_commit, then report.")
        guard try git(["branch", "--show-current"], tree.path, token) == tree.branch else { throw ProjectError.make("The sub-room's work tree is not on " + tree.branch) }
        let head = try git(["rev-parse", "HEAD"], tree.path, token)
        guard head != tree.base, try isAncestor(tree.base, head, tree.path, token) else {
            throw fail("출발 커밋 뒤에 새 커밋이 없어요. 먼저 커밋해 주세요.", "No commit after the start yet; commit first.")
        }
        return (head, paths(try git(["diff", "-z", "--name-only", "--no-renames", tree.base + "..." + head], tree.path, token)))
    }

    // What is left of sub-room n of a split, for the app's check after a restart: its folder, where Git lists a work tree on
    // its branch (nil: none), whether the folder and the branch are there and a merge was left half done in it.
    public struct Leftover: Equatable {
        public var path: String, listed: String?, exists: Bool, branch: Bool, merging: Bool
    }
    public static func leftover(_ binding: ProjectBinding, split: String, n: Int) throws -> Leftover {
        let common = try project(binding), name = branch(split: split, n: n)
        let path = URL(fileURLWithPath: folder(common: common, split: split, n: n)).resolvingSymlinksInPath().standardizedFileURL.path
        var listed: String?, current: String?
        for field in paths(try git(["worktree", "list", "--porcelain", "-z"], binding.root, nil)) {
            if field.hasPrefix("worktree ") { current = String(field.dropFirst(9)) }
            else if field == "branch refs/heads/" + name { listed = current }
        }
        let exists = FileManager.default.fileExists(atPath: path)
        let branch = try reply(["rev-parse", "-q", "--verify", "refs/heads/" + name], binding.root, nil).status == 0
        return Leftover(path: path, listed: listed, exists: exists, branch: branch, merging: exists && (try? merging(path, nil)) == true)
    }
    // A merge left half done in the main work tree (MERGE_HEAD): the user finishes or aborts it, never the app on its own.
    public static func halfMerged(_ binding: ProjectBinding) -> Bool { (try? merging(binding.root, nil)) == true }

    // "Discard" on the user's card: the sub-room's work tree and branch go, also with work never merged (only when it is
    // not being written). Its last commit is returned, so it can still be found (git branch <name> <sha>) until Git cleans up.
    public static func discard(_ binding: ProjectBinding, _ tree: Tree, token: DebateCancellation? = nil) throws -> String? {
        _ = try project(binding)
        guard tree.branch.hasPrefix("sub/") else { throw ProjectError.make("Not a sub-room branch: " + tree.branch) }
        return try holding(tree) {
            try ProjectWork.withRefs(binding.root, token: token) {
                let tip = try? git(["rev-parse", "--verify", "refs/heads/" + tree.branch + "^{commit}"], binding.root, token)
                if FileManager.default.fileExists(atPath: tree.path) { _ = try git(["worktree", "remove", "--force", tree.path], binding.root, token) }
                else { _ = try git(["worktree", "prune"], binding.root, token) }
                if tip != nil { _ = try git(["branch", "-D", tree.branch], binding.root, token) }
                _ = rmdir((tree.path as NSString).deletingLastPathComponent)
                return tip
            }
        }
    }

    // delegate_resync: merges the main HEAD into the sub-room's branch in its work tree, so it can resolve conflicts itself
    // (it has no pull or switch). Conflict markers stay for the sub-room; returns the conflicted files (empty: merged
    // cleanly or already up to date). The sub-room's tree must be clean and not being written.
    public static func resync(_ binding: ProjectBinding, _ tree: Tree, token: DebateCancellation? = nil) throws -> [String] {
        _ = try project(binding)
        return try holding(tree) {
            try ProjectWork.withRefs(binding.root, token: token) {
                try clean(tree.path, token, "하위 작업 폴더에 커밋하지 않은 변경이 있어 최신 메인을 넣지 않았어요.",
                          "The sub-room's work tree has uncommitted changes; main was not merged into it.")
                guard try git(["branch", "--show-current"], tree.path, token) == tree.branch else { throw ProjectError.make("The sub-room's work tree is not on " + tree.branch) }
                let main = try git(["rev-parse", "HEAD"], binding.root, token)
                let result = try started(["merge", "--no-ff", "--no-edit", "-m", "Merge main (\(main.prefix(10))) into \(tree.branch)", main], tree.path, token)
                if result.status == 0 { return [] }
                let conflicts = paths(try git(["diff", "-z", "--name-only", "--diff-filter=U"], tree.path, token))
                if conflicts.isEmpty {
                    if try merging(tree.path, token) { _ = try? git(["merge", "--abort"], tree.path, token) }
                    throw ProjectError.make(L("최신 메인을 넣다가 예상과 달리 실패해 방금 시작한 merge만 되돌렸어요: ", "Merging main into the sub-room failed unexpectedly; only that merge was aborted: ") + result.output)
                }
                return conflicts
            }
        }
    }
}
