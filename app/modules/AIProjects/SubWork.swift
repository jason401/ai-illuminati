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
    static func ownsGoalTree(_ tree: Tree, common: String, token: DebateCancellation?) -> Bool {
        let prefix = "todo-goal/"
        guard tree.branch.hasPrefix(prefix) else { return false }
        func real(_ path: String) -> String { URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path }
        let own = real(folder(common: common, name: "goal-" + tree.branch.dropFirst(prefix.count)))
        return FileManager.default.fileExists(atPath: tree.path) && real(tree.path) == own && ProjectWork.commonDir(tree.path) == common
            && (try? git(["rev-parse", "--show-toplevel"], tree.path, token)).map(real) == own
            && (try? git(["branch", "--show-current"], tree.path, token)) == tree.branch
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
        // The parent resolved, the last part as it is: the same text for a folder that is there and one that is gone.
        func real(_ folder: String) -> String {
            let url = URL(fileURLWithPath: folder)
            return url.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL.appendingPathComponent(url.lastPathComponent).path
        }
        let mine = real(path)
        return try ProjectWork.withRefs(binding.root, token: token) {
            if try reply(["rev-parse", "-q", "--verify", "refs/heads/" + name], binding.root, token).status == 0 {
                guard config("todogoal") == id else { throw ProjectError.make("The branch belongs to another Goal or was not made by the app: " + name) }
                var base = config("todogoalbase") ?? ""
                if base.isEmpty {
                    // Stopped between making the branch and recording it: taken only while the branch is still exactly the
                    // start it was about to be made from (a branch made later by hand from elsewhere is not).
                    guard let pending = config("todogoalpending"), (try? git(["rev-parse", "--verify", "refs/heads/" + name + "^{commit}"], binding.root, token)) == pending else {
                        throw ProjectError.make("The branch belongs to another Goal or was not made by the app: " + name)
                    }
                    _ = try git(["config", key + "todogoalbase", pending], binding.root, token)
                    _ = try? git(["config", "--unset", key + "todogoalpending"], binding.root, token)
                    base = pending
                }
                var listed: String?, current: String?
                for field in paths(try git(["worktree", "list", "--porcelain", "-z"], binding.root, token)) {
                    if field.hasPrefix("worktree ") { current = String(field.dropFirst(9)) }
                    else if field == "branch refs/heads/" + name { listed = current }
                }
                if let listed, real(listed) != mine { throw ProjectError.make("The Goal's branch is checked out elsewhere: " + listed) }
                if FileManager.default.fileExists(atPath: path) {
                    // The folder must be this repository's work tree on the Goal's branch, not only a folder Git once listed.
                    let top = try? git(["rev-parse", "--show-toplevel"], path, token)
                    guard listed != nil, top.map(real) == mine, ProjectWork.commonDir(path) == common,
                          (try? git(["branch", "--show-current"], path, token)) == name else {
                        throw ProjectError.make("The Goal's work tree folder exists but is not its work tree: " + path)
                    }
                    return Tree(path: mine, branch: name, base: base)
                }
                // Removed by hand: added again on the branch. Only this Goal's own entry is replaced (-f), no prune of others.
                try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
                _ = try git(["worktree", "add"] + (listed == nil ? [] : ["-f"]) + [mine, name], binding.root, token, timeout: 300)
                return Tree(path: mine, branch: name, base: base)
            }
            guard !FileManager.default.fileExists(atPath: path) else { throw ProjectError.make("The Goal's work tree folder already exists: " + path) }
            let remoteRef = "refs/remotes/\(binding.remote)/\(target)"
            _ = try git(["fetch", "--no-tags", binding.remote, "+refs/heads/\(target):\(remoteRef)"], binding.root, token, timeout: 180)
            let base = try git(["rev-parse", "--verify", remoteRef + "^{commit}"], binding.root, token)
            // The Goal id and the start it is about to be made from go first, the base only once the branch is there: a
            // stop in between leaves no record that a branch made later from elsewhere could pass.
            _ = try? git(["config", "--unset", key + "todogoalbase"], binding.root, token)
            _ = try git(["config", key + "todogoal", id], binding.root, token)
            _ = try git(["config", key + "todogoalpending", base], binding.root, token)
            try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            _ = try git(["worktree", "add", "--no-track", "-b", name, mine, base], binding.root, token, timeout: 300)
            _ = try git(["config", key + "todogoalbase", base], binding.root, token)
            _ = try? git(["config", "--unset", key + "todogoalpending"], binding.root, token)
            return Tree(path: mine, branch: name, base: base)
        }
    }

    // A Milestone's integration stopped on conflicts: the Goal's work tree is left mid-merge with the markers (a Fix Step
    // resolves and commits them there), `files` the unmerged paths, `remote` the fetched SHA being merged in.
    public struct Conflict: LocalizedError, Equatable {
        public var files: [String], remote: String
        public var errorDescription: String? {
            L("원격 최신 커밋과 합치다 충돌이 났어요. Goal 작업 폴더에 충돌 상태로 남겨 뒀어요: ", "Merging the newest remote commit conflicted; the Goal's work tree is left in that state: ")
                + files.joined(separator: ", ")
        }
    }

    // A Milestone's push candidate (TODO structure 07): fetches the remote `target` branch and merges its SHA into the Goal's
    // branch in the Goal's own work tree; the resulting HEAD is the candidate, `base` the remote SHA its review and push are
    // measured from (base...candidate, then a fast-forward push). Merge, not rebase: the Steps' commits keep their SHAs (no
    // rewritten history in the tree a Step may still name), a conflict stops once in one state a Fix Step resolves with one
    // commit instead of once per replayed commit, and the candidate still descends from `base`. The main work tree and its
    // branch are never touched. A conflict throws `Conflict` and leaves the merge as it is; called again then, it reports the
    // same files without starting anything. Up to date already: HEAD as it is.
    public static func integrate(_ binding: ProjectBinding, _ tree: Tree, target: String, token: DebateCancellation? = nil) throws -> (base: String, candidate: String) {
        let common = try project(binding)
        guard tree.branch.hasPrefix("todo-goal/") else { throw ProjectError.make("Not a Goal branch: " + tree.branch) }
        guard !binding.remote.isEmpty, !target.hasPrefix("-"), (try? git(["check-ref-format", "--branch", target], binding.root, token)) == target else {
            throw ProjectError.make("A remote and a valid target branch are required for a Goal.")
        }
        // Only the Goal's own folder as SubWork.goal makes it: a user's checkout on a todo-goal/ branch is never merged in.
        guard ownsGoalTree(tree, common: common, token: token) else { throw ProjectError.make("The Goal's work tree is missing or not on " + tree.branch) }
        let held: [String]
        do { held = try ProjectWork.acquire(WorkspaceBinding(roots: [WorkspaceRoot(path: tree.path, directory: true, writable: true)], level: .execute)) }
        catch where ProjectWork.isBusy(error.localizedDescription) { throw fail("Step이 아직 Goal 작업 폴더를 쓰고 있어요. 끝난 뒤 다시 해 주세요.", "A Step is still writing the Goal's work tree; try again once it ends.") }
        defer { ProjectWork.release(held, notify: false) }
        return try ProjectWork.withRefs(binding.root, token: token) {
            guard ownsGoalTree(tree, common: common, token: token) else { throw ProjectError.make("The Goal's work tree is missing or not on " + tree.branch) }
            let remoteRef = "refs/remotes/\(binding.remote)/\(target)"
            // The whole NUL list from a file: the shared Git output is trimmed and capped, a Fix Step needs every name as it is.
            func unmerged() throws -> [String] {
                let file = NSTemporaryDirectory() + "goal-unmerged-" + UUID().uuidString
                defer { try? FileManager.default.removeItem(atPath: file) }
                let r = try reply(["diff", "-z", "--name-only", "--diff-filter=U", "--output=" + file], tree.path, token)
                guard r.status == 0, let data = FileManager.default.contents(atPath: file) else { throw ProjectError.make("git diff failed: " + r.output) }
                return data.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
            }
            if try merging(tree.path, token) {
                // Left from an earlier conflict: the same state again, nothing new started.
                let files = try unmerged(), head = (try? git(["rev-parse", "--verify", "MERGE_HEAD"], tree.path, token)) ?? ""
                if !files.isEmpty { throw Conflict(files: files, remote: head) }
                throw fail("Goal 작업 폴더의 충돌을 해결했지만 merge 커밋이 아직 없어요. 먼저 커밋해 주세요.", "The Goal's conflicts are resolved but the merge is not committed yet; commit it first.")
            }
            try clean(tree.path, token, "Goal 작업 폴더에 커밋하지 않은 변경이 있어 통합하지 않았어요. 먼저 커밋해 주세요.",
                      "The Goal's work tree has uncommitted changes; commit them before integrating.")
            _ = try git(["fetch", "--no-tags", binding.remote, "+refs/heads/\(target):\(remoteRef)"], binding.root, token, timeout: 180)
            let remote = try git(["rev-parse", "--verify", remoteRef + "^{commit}"], binding.root, token)
            if try !isAncestor(remote, "HEAD", tree.path, token) {
                let message = "Merge \(binding.remote)/\(target) (\(remote.prefix(10))) into \(tree.branch)"
                // Explicit, so merge.ff, merge.squash or the branch's mergeOptions cannot turn it into no commit or a refusal.
                let result = try started(["merge", "--ff", "--commit", "--no-squash", "--no-edit", "-m", message, remote], tree.path, token)
                if result.status != 0 {
                    let files = try unmerged()
                    if !files.isEmpty { throw Conflict(files: files, remote: remote) }
                    if try merging(tree.path, token) { _ = try? git(["merge", "--abort"], tree.path, token) }
                    throw ProjectError.make(L("원격 최신 커밋과 합치다 예상과 달리 실패해 방금 시작한 merge만 되돌렸어요: ", "Merging the newest remote commit failed unexpectedly; only that merge was aborted: ") + result.output)
                }
            }
            let candidate = try git(["rev-parse", "HEAD"], tree.path, token)
            guard try !merging(tree.path, token), try isAncestor(remote, candidate, tree.path, token) else {
                throw ProjectError.make("The Goal's HEAD does not contain the remote SHA after merging: " + remote)
            }
            return (remote, candidate)
        }
    }

    // TODO structure 10. The Milestone runner saves this candidate on the TODO when it returns.
    public static func testMilestone(_ binding: ProjectBinding, _ tree: Tree, candidate: inout TodoItem.MilestoneCandidate,
                                     room: UUID, fullAuto: Bool, token: DebateCancellation, onLine: ((String) -> Void)? = nil) throws {
        try testMilestone(binding, tree, candidate: &candidate, room: room, fullAuto: fullAuto, token: token, extra: [:], onLine: onLine)
    }

    static func testMilestone(_ binding: ProjectBinding, _ tree: Tree, candidate: inout TodoItem.MilestoneCandidate,
                              room: UUID, fullAuto: Bool, token: DebateCancellation, extra: [String: String],
                              onLine: ((String) -> Void)? = nil) throws {
        candidate.clearTest()
        guard let sha = candidate.candidateSHA, candidate.reviewedSHA == sha else {
            throw fail("후보 SHA의 리뷰가 먼저 필요해요.", "Review the candidate SHA before running its full test.")
        }
        candidate.setPhase(.test)
        let common = try project(binding), root = tree.path
        func checkTree() throws {
            guard ownsGoalTree(tree, common: common, token: token),
                  try git(["rev-parse", "HEAD"], root, token) == sha else {
                throw fail("Goal 작업 폴더의 HEAD가 후보 SHA와 달라요.", "The Goal work tree's HEAD differs from the candidate SHA.")
            }
            guard try git(["status", "--porcelain", "--untracked-files=all", "--ignore-submodules=none"], root, token).isEmpty,
                  try !merging(root, token) else {
                throw fail("Goal 작업 폴더에 커밋하지 않은 변경이 있어요.", "The Goal work tree has uncommitted changes.")
            }
        }
        // The Goal's HEAD and branch logs also show recorded moves that end back on the candidate.
        func reflogs() throws -> [String] {
            let logs = try ["HEAD", "refs/heads/" + tree.branch].map { try git(["reflog", "show", "--format=%H", $0], root, token) }
            guard !logs.contains(where: \.isEmpty) else {
                throw fail("Goal의 HEAD 변경 이력을 확인할 수 없어요.", "Could not verify the Goal's HEAD history.")
            }
            return logs
        }
        let homeKey = "AI_ILLUMINATI_TEST_HOME"
        // Start with the suite's defaults, including no golden fixture writes to an inherited path.
        let overrides = Set(ProcessInfo.processInfo.environment.keys).union(extra.keys).filter {
            ($0.hasPrefix("AI_ILLUMINATI_TEST_") && $0 != homeKey) || $0 == "AI_ILLUMINATI_WRITE_GOLDEN"
        }.sorted()
        let args = overrides.flatMap { ["-u", $0] } + ["/bin/zsh", "-f", StepTests.script]
        if !fullAuto {
            try checkTree()
            let request = ProjectApproval(room: room, run: UUID(), title: L("Milestone 전체 테스트", "Milestone full test"),
                                          detail: L("리뷰한 후보의 스크립트를 사용자 권한으로 실행해요.", "Runs the reviewed candidate's script as your user.")
                                          + "\n" + root + "\n" + sha + "\n/bin/zsh -f " + StepTests.script)
            guard ProjectCenter.shared.approve(request, token: token, deadline: Date().addingTimeInterval(900)) else {
                throw fail("Milestone 전체 테스트 실행을 승인받지 못했어요.", "Running the Milestone's full test was not approved.")
            }
        }
        try holding(tree) {
            let deadline = Date().addingTimeInterval(2700)
            try ProjectWork.oneRun(root, until: deadline, token: token,
                                   waiting: { onLine?(L("이 저장소의 다른 명령이 끝나길 기다리는 중", "Waiting for another command in this repository")) }) {
                let logs = try reflogs()
                try checkTree()
                let home = FileManager.default.temporaryDirectory.appendingPathComponent("ai-milestone-" + UUID().uuidString)
                try FileManager.default.createDirectory(at: home, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                defer { try? FileManager.default.removeItem(at: home) }
                let environment = extra.merging([homeKey: home.path]) { _, isolated in isolated }
                let result = try ProjectProcess.run("/usr/bin/env", args, cwd: root, token: token, deadline: deadline, guarded: true,
                                                    extra: environment, onLine: onLine)
                guard result.status == 0 else {
                    throw fail("Milestone 전체 테스트 실패 (exit \(result.status))", "Milestone full test failed (exit \(result.status))")
                }
                try checkTree()
                guard try reflogs() == logs, !token.isCancelled else {
                    throw fail("테스트 중에 Goal HEAD가 바뀌었거나 실행이 취소됐어요.", "The Goal's HEAD moved during the test or the run was cancelled.")
                }
                candidate.recordTest(for: sha)
            }
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
