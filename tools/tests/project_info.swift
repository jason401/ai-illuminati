import Foundation
import AIAccounts
import AILocalization
import AIWorkspace
@testable import AIProjects
@testable import AIChat

// Project info (ProjectInfo.swift): the folders, files and links kept for a whole project, the file that is never
// overwritten when it cannot be read, and every chat of the project reading them read only.
func testProjectInfo() {
    let base = URL(fileURLWithPath: AccountStore.home).appendingPathComponent("project-info-tests")
    try? FileManager.default.removeItem(at: base)
    try! FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    let docs = base.appendingPathComponent("docs"), notes = base.appendingPathComponent("notes.txt"), alias = base.appendingPathComponent("docs-alias")
    try! FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
    try! "notes".write(to: notes, atomically: true, encoding: .utf8)
    try! FileManager.default.createSymbolicLink(at: alias, withDestinationURL: docs)
    let file = base.appendingPathComponent("project-info.json")
    let key = "/tmp/info-repo/.git"

    let store = ProjectInfoStore(url: file)
    let added = try! store.addFolders([docs, notes, alias, base.appendingPathComponent("gone")], to: key)
    let docsPath = docs.resolvingSymlinksInPath().path, notesPath = notes.resolvingSymlinksInPath().path
    expect(added == 2 && store.info(key).folders.map(\.path) == [docsPath, notesPath], "folders and files added once, a symlink as what it points at, a missing path skipped: \(store.info(key).folders)")
    expect(store.info(key).folders.map(\.directory) == [true, false], "folder or file kept")
    let link = try! store.addLink(title: "Design\ndoc", url: " example.com/spec ", to: key)
    expect(link.title == "Designdoc" && link.url == "https://example.com/spec", "a link is one line, https added: \(link)")
    for bad in ["javascript:alert(1)", "file:///etc/passwd", "ftp://x.org", "not a link"] {
        expect((try? store.addLink(title: "", url: bad, to: key)) == nil, "refused link: \(bad)")
    }
    expect(try! store.addLink(title: "", url: "https://example.com/spec", to: key).title == "example.com" && store.info(key).links.count == 1, "the same address is kept once; no title = the host")
    let reread = ProjectInfoStore(url: file)
    expect(reread.current == store.current, "saved and read back")
    try! store.removeFolder(notesPath, from: key)
    try! store.removeLink(link.id, from: key)
    expect(store.info(key).folders.map(\.path) == [docsPath] && store.info(key).links.isEmpty, "unlinked")
    expect(FileManager.default.fileExists(atPath: notes.path), "unlinking leaves the file")

    // The project's own name: one line, at most 80 characters, kept with the folders; empty gives the folder its name back.
    try! store.rename(key, to: "  Paper\n draft  ")
    expect(store.info(key).name == "Paper draft" && store.names[key] == "Paper draft", "renamed, one line: \(String(describing: store.info(key).name))")
    expect(ProjectInfoStore(url: file).info(key).name == "Paper draft", "the name is saved")
    expect(ProjectInfoStore.cleanName(String(repeating: "가", count: 100))?.count == 80 && ProjectInfoStore.cleanName(" \t ") == nil, "long names cut, blank is none")
    try! store.rename(key, to: "")
    expect(store.info(key).name == nil && store.names[key] == nil && store.info(key).folders.map(\.path) == [docsPath], "an empty name resets it, the folders stay")
    let named = "/tmp/only-named/.git"
    try! store.rename(named, to: "Named")
    try! store.rename(named, to: " ")
    expect(store.current.projects[named] == nil, "a project with nothing left is dropped from the file")
    // A deleted project: its name, folders and links go; other projects stay.
    try! store.rename(named, to: "Other")
    try! store.forget(key)
    expect(store.current.projects[key] == nil && store.names[named] == "Other" && ProjectInfoStore(url: file).current.projects[key] == nil, "a deleted project's info is forgotten, others stay")
    try! store.forget(key)
    try! store.forget(named)
    _ = try! store.addFolders([docs], to: key)

    // A file it cannot read (broken, or from a newer app) is left as it is, and changes are refused.
    for raw in ["{ broken", #"{"version": 99, "projects": {}}"#,
                #"{"version": 1, "projects": {"k": {"folders": [{"path": "/x", "directory": "yes"}], "links": []}}}"#,
                #"{"version": 1, "projects": {"k": {"folders": [], "links": [{"title": "a"}]}}}"#] {
        try! raw.write(to: file, atomically: true, encoding: .utf8)
        let held = ProjectInfoStore(url: file)
        expect(held.saveError != nil && (try? held.addLink(title: "", url: "https://a.org", to: key)) == nil && (try? held.rename(key, to: "x")) == nil,
               "unreadable file: changes refused (\(raw))")
        expect((try? String(contentsOf: file, encoding: .utf8)) == raw, "unreadable file left as it is")
    }
    // A file that is there but cannot be opened is held too, never started over empty.
    try! FileManager.default.removeItem(at: file)
    try! FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)   // a folder in its place: reading fails
    let unopened = ProjectInfoStore(url: file)
    expect(unopened.saveError != nil && (try? unopened.addLink(title: "", url: "https://a.org", to: key)) == nil, "a file that cannot be opened: changes refused")
    try! FileManager.default.removeItem(at: file)
    expect(ProjectInfoStore(url: file).saveError == nil, "no file yet: starts empty")
    let old = base.appendingPathComponent("old.json")
    try! #"{"projects": {"k": {"links": [{"id": "6F9619FF-8B86-D011-B42D-00C04FC964FF", "title": "a", "url": "https://a.org"}]}}}"#.write(to: old, atomically: true, encoding: .utf8)
    let partial = ProjectInfoStore(url: old)
    expect(partial.saveError == nil && partial.info("k").links.count == 1 && partial.info("k").folders.isEmpty, "missing fields read as empty")

    // Git remotes on the web: never with a password, only web addresses.
    expect(ProjectInfoStore.webURL("git@github.com:jason/app.git")?.absoluteString == "https://github.com/jason/app", "ssh remote")
    expect(ProjectInfoStore.webURL("https://user:secret@github.com/jason/app.git")?.absoluteString == "https://github.com/jason/app", "credentials dropped")
    expect(ProjectInfoStore.webURL("ssh://git@github.com/jason/app.git")?.absoluteString == "https://github.com/jason/app", "ssh:// remote")
    expect(ProjectInfoStore.webURL("/Users/me/origin") == nil && ProjectInfoStore.webURL("file:///x") == nil, "local remotes have no web page")

    // Every chat of the project reads them at the time of the answer, read only; a path the chat itself links keeps its access.
    let saved = ProjectInfoStore.shared
    defer { ProjectInfoStore.shared = saved }
    ProjectInfoStore.shared = ProjectInfoStore(url: file)
    let repo = ProjectBinding(root: base.appendingPathComponent("repo").path, common: key, remote: "origin", remoteURL: "")
    let mine = base.appendingPathComponent("mine")
    try! FileManager.default.createDirectory(at: mine, withIntermediateDirectories: true)
    try! ProjectInfoStore.shared.addFolders([docs, notes, mine], to: key)
    try! ProjectInfoStore.shared.addLink(title: "Spec", url: "https://example.com/spec", to: key)
    let m = AppModel(); m.sharedFolders = []
    let d = Discussion(model: m)
    var chat = Conversation(); chat.turns = [ChatTurn(question: "hi")]
    chat.workspace = WorkspaceBinding(roots: [WorkspaceRoot(path: repo.root, directory: true, writable: true), WorkspaceRoot(path: mine.path, directory: true)], project: repo)
    var other = Conversation(); other.turns = [ChatTurn(question: "hi")]
    d.conversations = [chat, other]
    try! FileManager.default.removeItem(at: notes)   // gone: listed on the tab, not given to the AI
    let binding = d.soloBinding(chat.id)
    let docsRoot = binding.roots.first { $0.path == docsPath }
    expect(docsRoot != nil && docsRoot?.writable != true, "a project folder is given to the chat, read only")
    expect(!binding.roots.contains { $0.path == notesPath }, "a missing project file is not given to the AI")
    expect(binding.roots.filter { $0.path == mine.path }.count == 1 && binding.roots.first { $0.path == mine.path }?.writable == true, "the chat's own link keeps its access, once")
    expect(!d.soloBinding(other.id).roots.contains { $0.path == docsPath }, "a chat outside the project does not get them")
    let told = Discussion.soloFolders(binding, shared: [], project: repo.root)
    expect(told.contains(docsPath + " (project folder, shared by every chat of this project — read only)"), "the AI is told what the folder is: \(told)")
    expect(told.contains("[Project links") && told.contains("- Spec: https://example.com/spec"), "and the project's links")

    // Rules files shown on the tab are the ones the AIs read: at the root, not a folder, not a symlink out of it.
    let rulesRoot = base.appendingPathComponent("rules-repo"), outside = base.appendingPathComponent("outside.md")
    try! FileManager.default.createDirectory(at: rulesRoot.appendingPathComponent("CLAUDE.md"), withIntermediateDirectories: true)
    try! "# rules".write(to: rulesRoot.appendingPathComponent("AGENTS.md"), atomically: true, encoding: .utf8)
    expect(ProjectRules.files(root: rulesRoot.path).map(\.lastPathComponent) == ["AGENTS.md"], "AGENTS.md found, a folder named CLAUDE.md skipped")
    // One budget for all rules files: a full AGENTS.md leaves CLAUDE.md out, and the tab is told so.
    try! FileManager.default.removeItem(at: rulesRoot.appendingPathComponent("CLAUDE.md"))
    try! String(repeating: "a", count: 40_000).write(to: rulesRoot.appendingPathComponent("AGENTS.md"), atomically: true, encoding: .utf8)
    try! "# claude".write(to: rulesRoot.appendingPathComponent("CLAUDE.md"), atomically: true, encoding: .utf8)
    let budget = ProjectRules.read(root: rulesRoot.path)
    expect(budget.parts.count == 2 && budget.parts[0].cut && budget.parts[0].sent?.isEmpty == false && budget.parts[1].sent == nil, "AGENTS.md cut, CLAUDE.md not sent")
    expect(budget.prompt.hasSuffix("[Project rules truncated]") && !budget.prompt.contains("# claude") && budget.prompt.count < ProjectRules.limit + 40, "the prompt holds what the parts say")
    try! "short".write(to: rulesRoot.appendingPathComponent("AGENTS.md"), atomically: true, encoding: .utf8)
    let both = ProjectRules.read(root: rulesRoot.path)
    expect(both.parts.map(\.sent) == ["short", "# claude"] && both.parts.allSatisfy { !$0.cut } && both.prompt == "\n[Project rules: AGENTS.md]\nshort\n[Project rules: CLAUDE.md]\n# claude", "both sent whole: \(both.prompt)")
    try! FileManager.default.removeItem(at: rulesRoot.appendingPathComponent("CLAUDE.md"))
    try! FileManager.default.removeItem(at: rulesRoot.appendingPathComponent("AGENTS.md"))
    try! "secret".write(to: outside, atomically: true, encoding: .utf8)
    try! FileManager.default.createSymbolicLink(at: rulesRoot.appendingPathComponent("AGENTS.md"), withDestinationURL: outside)
    expect(ProjectRules.files(root: rulesRoot.path).isEmpty, "a rules symlink out of the project is not read")
    print("PASS: project info (folders, files, links, unreadable file kept, read only in every chat of the project, rules files)")
}

// Project info's branch view (GitBranches.swift): roles, nearest tag, origin and stable distances, the summary line,
// worktrees, and the app's backup refs hidden. Read from a throwaway repository with its own bare "origin".
func testGitBranches() {
    expect(GitBranches.version("v0.2.0-5-gabc1234") == "v0.2.0+5" && GitBranches.version("v0.2.0-0-gabc1234") == "v0.2.0"
           && GitBranches.version("release-1-2-3-g1a2b") == "release-1-2+3" && GitBranches.version("") == nil, "describe → version")
    expect(GitBranches.counts("3\t0") == GitCounts(ahead: 3, behind: 0) && GitBranches.counts("x") == nil, "left/right counts")
    expect(GitBranches.role("stable") == .deploy && GitBranches.role("main") == .beta && GitBranches.role("codex/a") == .work
           && GitBranches.role("fix/b") == .work && GitBranches.role("feature/c") == .work && GitBranches.role("dev") == .other, "roles")

    let base = URL(fileURLWithPath: AccountStore.home).appendingPathComponent("git-branch-tests")
    try? FileManager.default.removeItem(at: base)
    try! FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    let bare = base.appendingPathComponent("origin.git").path, repo = base.appendingPathComponent("repo").path, tree = base.appendingPathComponent("tree").path
    @discardableResult func sh(_ args: [String], in dir: String) -> String {
        let p = Process(), out = Pipe()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = ["-c", "user.name=T", "-c", "user.email=t@example.invalid", "-c", "commit.gpgsign=false", "-c", "tag.gpgsign=false", "-c", "init.defaultBranch=main"] + args
        p.currentDirectoryURL = URL(fileURLWithPath: dir); p.standardOutput = out; p.standardError = FileHandle.nullDevice
        p.environment = ["HOME": base.path, "GIT_CONFIG_NOSYSTEM": "1", "PATH": "/usr/bin:/bin"]
        try! p.run(); let data = out.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
        expect(p.terminationStatus == 0, "git \(args.joined(separator: " "))")
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    sh(["init", "-q", "--bare", bare], in: base.path)
    sh(["init", "-q", repo], in: base.path)
    sh(["remote", "add", "origin", bare], in: repo)
    func commit(_ message: String) { sh(["commit", "-q", "--allow-empty", "-m", message], in: repo) }
    commit("first"); sh(["tag", "v0.1.0"], in: repo)
    commit("second"); sh(["push", "-q", "origin", "main:stable"], in: repo)
    commit("third"); commit("fourth"); sh(["push", "-q", "origin", "main"], in: repo)
    commit("local only")                                            // main is 1 ahead of origin/main
    sh(["branch", "feature/x"], in: repo)                           // not on origin
    sh(["worktree", "add", "-q", "-b", "fix/y", tree], in: repo)
    sh(["update-ref", "refs/ai-illuminati/backup", "HEAD"], in: repo)
    sh(["fetch", "-q", "origin"], in: repo)

    let report = GitBranches.read(root: repo) { args in sh(args, in: repo) }
    let names = report.rows.map(\.name)
    expect(names.first == "origin/stable" && names.dropFirst().prefix(2) == ["main", "origin/main"], "stable, main first, local before origin: \(names)")
    expect(Set(names) == ["origin/stable", "main", "origin/main", "feature/x", "fix/y"], "local + origin branches, no backup ref, no origin/HEAD: \(names)")
    let main = report.rows.first { $0.ref == "refs/heads/main" }!, originMain = report.rows.first { $0.ref == "refs/remotes/origin/main" }!
    expect(main.current && !originMain.current && main.subject == "local only" && main.sha.count >= 7 && main.date != nil, "current main and its commit: \(main)")
    expect(main.version == "v0.1.0+4" && report.rows.first { $0.name == "origin/stable" }!.version == "v0.1.0+1", "nearest tag +N: \(String(describing: main.version))")
    expect(main.origin == GitCounts(ahead: 1, behind: 0) && main.stable == GitCounts(ahead: 3, behind: 0) && originMain.stable == GitCounts(ahead: 2, behind: 0), "distances")
    expect(report.rows.first { $0.branch == "feature/x" }!.onOrigin == false, "a branch origin does not have")
    expect(report.rows.first { $0.branch == "fix/y" }!.worktree == "tree", "checked out in another worktree")
    expect(report.stableName == "origin/stable" && report.mainName == "origin/main" && report.pending == GitCounts(ahead: 2, behind: 0) && report.fetched != nil, "summary uses origin")
    expect(GitBranches.summary(report)?.contains("2") == true, "summary text")
    // The overview: one line per name, stable/main/current on their own, the rest grouped by kind.
    let lines = GitBranches.lines(report)
    expect(lines.map(\.branch) == ["stable", "main", "feature/x", "fix/y"], "one line per name: \(lines.map(\.branch))")
    let mainLine = lines.first { $0.branch == "main" }!
    expect(mainLine.place == .both && mainLine.current && mainLine.sync == GitCounts(ahead: 1, behind: 0) && mainLine.version == "v0.1.0+4"
           && GitBranches.sync(mainLine) != nil, "main merged from local and origin: \(mainLine)")
    // The refresh's pull offer: only for local main behind origin/main.
    expect(GitBranches.pullOffer(report, dirty: false) == nil, "ahead only: nothing to pull")
    func withMain(_ c: GitCounts, current: Bool = true) -> GitBranchReport {
        var r = report; let i = r.rows.firstIndex { $0.ref == "refs/heads/main" }!
        r.rows[i].origin = c; r.rows[i].current = current; return r
    }
    expect(GitBranches.pullOffer(withMain(GitCounts(ahead: 0, behind: 2)), dirty: false) == .pull(2)
           && GitBranches.pullOffer(withMain(GitCounts(ahead: 0, behind: 2)), dirty: true) == .dirty(2)
           && GitBranches.pullOffer(withMain(GitCounts(ahead: 1, behind: 2)), dirty: false) == .diverged(GitCounts(ahead: 1, behind: 2))
           && GitBranches.pullOffer(withMain(GitCounts(ahead: 0, behind: 2), current: false), dirty: false) == .otherBranch(2)
           && GitBranches.pullOffer(withMain(GitCounts(ahead: 0, behind: 0)), dirty: false) == nil, "pull offers")
    expect(GitBranches.offerText(.pull(2)).contains("2"), "offer text")
    var behind = report                                             // a local stable behind origin: the line shows origin's
    behind.rows.append(GitBranchRow(ref: "refs/heads/stable", branch: "stable", remote: false, date: .distantPast, version: "v0.0.1"))
    let stableLine = GitBranches.lines(behind).first { $0.branch == "stable" }!
    expect(stableLine.place == .both && stableLine.version == "v0.1.0+1" && stableLine.date != .distantPast, "release line from origin: \(stableLine)")
    expect(lines.first!.place == .originOnly && lines.first { $0.branch == "feature/x" }!.place == .localOnly, "where each lives")
    expect(GitBranches.main(lines).map(\.branch) == ["stable", "main"] && GitBranches.flow(report) != nil, "main lines and flow")
    let side = GitBranches.groups(lines + ["worktree-agent-a1", "worktree-agent-b2", "trial/z", "dev"].map {
        GitBranchLine(branch: $0, role: GitBranches.role($0), place: .localOnly, date: Date(timeIntervalSince1970: 100)) })
    expect(side.map(\.key) == ["feature/", "fix/", "worktree-agent-", "trial/", ""] && side[2].lines.count == 2
           && GitBranches.place(side[2]) == GitBranches.place(.localOnly) && side[2].latest != nil, "side branches grouped, others last: \(side.map(\.key))")

    // From the worktree, its own branch is the current one; up to date once stable catches up.
    sh(["push", "-q", "origin", "origin/main:refs/heads/stable"], in: repo); sh(["fetch", "-q", "origin"], in: tree)
    let fromTree = GitBranches.read(root: tree) { args in sh(args, in: tree) }
    expect(fromTree.rows.first { $0.branch == "fix/y" }!.current && fromTree.rows.first { $0.ref == "refs/heads/main" }!.worktree == "repo", "worktree view")
    expect(fromTree.fetched != nil && fromTree.fetched != report.fetched, "a worktree's last fetch is its own FETCH_HEAD")
    expect(fromTree.pending == GitCounts(ahead: 0, behind: 0) && GitBranches.summary(fromTree) == L("배포 최신 상태", "Release is up to date"), "up to date")
    // A branch deleted on origin leaves the list after a refresh; the local branch of the same name stays.
    sh(["push", "-q", "origin", "feature/x"], in: repo); sh(["fetch", "-q", "origin"], in: repo)
    let other = base.appendingPathComponent("other").path         // its own clone: a worktree would share repo's origin/* refs
    sh(["clone", "-q", bare, other], in: base.path); sh(["push", "-q", "origin", "--delete", "feature/x"], in: other)
    expect(GitBranches.read(root: repo) { args in sh(args, in: repo) }.rows.contains { $0.name == "origin/feature/x" }, "deleted elsewhere: still listed before the refresh")
    expect(GitBranches.fetchArgs.contains("--prune"), "refresh prunes: \(GitBranches.fetchArgs)")
    sh(GitBranches.fetchArgs, in: repo)
    let pruned = GitBranches.read(root: repo) { args in sh(args, in: repo) }.rows
    expect(!pruned.contains { $0.name == "origin/feature/x" } && pruned.contains { $0.branch == "feature/x" && $0.ref == "refs/heads/feature/x" }, "pruned origin ref, kept local branch: \(pruned.map(\.name))")
    // Not a repository: an error, no rows; no stable: said so.
    let none = GitBranches.read(root: base.path) { _ in throw MaterialReader.error("no git") }
    expect(none.rows.isEmpty && none.error != nil && GitBranches.summary(none) == nil, "no repository")
    try? FileManager.default.removeItem(at: base)
    print("PASS: Git branches (overview lines and groups, roles, nearest tag +N, origin and stable distances, summary, worktrees, backup refs hidden, deleted origin branches pruned, no repository)")
}
