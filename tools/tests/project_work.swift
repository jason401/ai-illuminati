import Foundation

func testProjectWork() {
    let base = URL(fileURLWithPath: AccountStore.home).appendingPathComponent("project-fixture-" + UUID().uuidString)
    try! FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    let root = base.appendingPathComponent("repo"), origin = base.appendingPathComponent("origin.git")
    func git(_ args: [String], at folder: URL? = nil) -> String { try! ProjectProcess.git(args, root: (folder ?? base).path) }
    _ = git(["init", "--bare", origin.path]); _ = git(["init", "-b", "main", root.path])
    _ = git(["config", "user.name", "Fixture"], at: root); _ = git(["config", "user.email", "fixture@example.invalid"], at: root)
    _ = git(["remote", "add", "origin", origin.path], at: root)
    func write(_ name: String, _ text: String) { try! text.write(to: root.appendingPathComponent(name), atomically: true, encoding: .utf8) }
    write("README.md", "First\n"); write("user.txt", "User baseline\n")
    _ = git(["add", "."], at: root); _ = git(["commit", "-m", "Initial"], at: root); _ = git(["push", "-u", "origin", "main"], at: root)
    let selected = try! ProjectProcess.inspect(root.path)
    let binding = WorkspaceBinding(roots: [WorkspaceRoot(path: root.path, directory: true, writable: true)], project: selected)
    let lease = try! ProjectWork.acquire(binding)
    defer { ProjectWork.release(lease) }
    do { _ = try ProjectWork.acquire(binding); expect(false, "concurrent project writer refused") } catch {}
    write("user.txt", "Existing user edit\n"); _ = git(["add", "user.txt"], at: root)
    let outer = DebateCancellation(), run = ProjectRun(room: UUID(), binding: selected, token: outer)
    ProjectWork.register(run); run.nextAttempt()
    defer { ProjectWork.finish(run) }
    var context = ToolContext(room: run.room, roots: binding.roots, projectRun: run.id, projectGeneration: run.generation)
    let provider = GitLink.shared
    var reported: [String] = []
    run.onNote = { reported = $0 }
    func call(_ name: String, _ args: [String: Any] = [:]) -> [String: Any] { provider.call(name, args, context: context) }
    func ok(_ name: String, _ args: [String: Any] = [:]) -> String {
        let reply = call(name, args)
        expect(reply["isError"] as? Bool == false, "project tool succeeds: \(name) \(reply)")
        return (reply["content"] as! [[String: Any]])[0]["text"] as! String
    }
    expect(!provider.tools(context: context).isEmpty && provider.tools().isEmpty, "Git tools are scoped, never global")
    expect(provider.tools(context: ToolContext(room: UUID(), roots: binding.roots, projectRun: run.id, projectGeneration: run.generation)).isEmpty, "another room cannot use project scope")
    expect(call("git_pull")["isError"] as? Bool == true, "dirty pull refused")
    write("README.md", "AI edit\n")
    _ = ok("git_commit", ["message": "AI change", "paths": ["README.md"]])
    expect(git(["diff", "--cached", "--name-only"], at: root) == "user.txt", "commit preserves unrelated user staging")
    _ = ok("git_push")
    expect(run.log.count == 3 && run.log[0] == "git_pull failed" && run.log[1].hasPrefix("git_commit → ") && run.log[2].hasPrefix("git_push → ") && reported == run.log,
           "project tools land in this turn's work log, failures included")
    let pushed = git(["rev-parse", "refs/heads/main"], at: origin)
    expect(pushed == git(["rev-parse", "HEAD"], at: root) && run.committed && run.pushed, "app records real commit and push")
    expect(call("git_commit", ["message": "bad", "paths": ["../outside"]])["isError"] as? Bool == true, "traversal commit refused")
    expect(call("git_switch", ["name": "stable"])["isError"] as? Bool == true, "direct stable switch refused")
    expect(call("git_force_push")["isError"] as? Bool == true, "force push tool not provided")
    let previous = context
    run.nextAttempt(); context.projectGeneration = run.generation
    expect(provider.call("git_status", [:], context: previous)["isError"] as? Bool == true, "handoff revokes previous generation")
    expect(ok("git_status").contains("user.txt"), "next AI inherits dirty worktree")
    // Complete the preserved user change explicitly outside app tools for a clean publishing fixture.
    _ = git(["commit", "-m", "User edit"], at: root)
    func approved(_ name: String, _ args: [String: Any] = [:], allow: Bool = true, onCard: (() -> Void)? = nil) -> [String: Any] {
        let done = DispatchSemaphore(value: 0); var output: [String: Any] = [:]; var acted = false
        DispatchQueue.global().async { output = call(name, args); done.signal() }
        let limit = Date().addingTimeInterval(15)
        while done.wait(timeout: .now()) != .success && Date() < limit {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            if !acted, let request = ProjectCenter.shared.requests.first(where: { $0.run == run.id }) {
                acted = true; onCard?(); ProjectCenter.shared.decide(request.id, allow: allow)
            }
        }
        expect(acted && !output.isEmpty, "approval card and tool complete")
        return output
    }
    let sha = git(["rev-parse", "HEAD"], at: root)
    let published = approved("git_publish_stable", onCard: {
        write("README.md", "Newer main after approval shown\n")
        _ = git(["add", "README.md"], at: root); _ = git(["commit", "-m", "Later main"], at: root)
    })
    expect(published["isError"] as? Bool == false && git(["rev-parse", "refs/heads/stable"], at: origin) == sha, "stable publishes approved SHA, not main changed during approval")
    let denied = approved("git_publish_stable", allow: false)
    expect(denied["isError"] as? Bool == true && git(["rev-parse", "refs/heads/stable"], at: origin) == sha, "denied deployment leaves stable unchanged")
    let config = #"{"version":1,"commands":{"test":{"executable":"/usr/bin/python3","args":["-c","print('fixture command')"]}}}"#
    write(".ai-illuminati.json", config)
    expect(approved("project_run", ["name": "test"])["isError"] as? Bool == false, "named command runs after approval")
    expect(call("project_run", ["name": "not-registered"])["isError"] as? Bool == true, "unknown command cannot run")
    expect(approved("project_run", ["name": "test"], onCard: { write(".ai-illuminati.json", config + " ") })["isError"] as? Bool == true, "command mutation invalidates approval")
    write(".ai-illuminati.json", config)
    expect(approved("project_run", ["name": "test"], allow: false)["isError"] as? Bool == true, "denied command never starts")
    let expired = ProjectCenter.shared.approve(ProjectApproval(room: run.room, run: run.id, title: "Expired", detail: "fixture"), token: run.attempt, deadline: Date())
    expect(!expired, "approval timeout refuses execution")
    // Exercise the real Python stdio bridge and app socket beyond the old 15-second timeout.
    write(".ai-illuminati.json", #"{"version":1,"commands":{"delayed":{"executable":"/usr/bin/python3","args":["-c","import time; time.sleep(16); print('long command fixture')"]}}}"#)
    let capability = ToolHub.shared.register(room: run.room, roots: binding.roots, projectRun: run.id, generation: run.generation)
    let manifest = base.appendingPathComponent("bridge.json")
    let object: [String: Any] = ["roots": [["path": root.path, "directory": true]], "level": "view", "cache": base.appendingPathComponent("cache").path, "extractor": WorkspaceInvocation.resources.appendingPathComponent("WorkspaceDocument").path, "tools": ToolHub.socketPath, "toolSession": capability]
    try! JSONSerialization.data(withJSONObject: object).write(to: manifest)
    let client = base.appendingPathComponent("client.py")
    try! """
    import subprocess, sys, json
    p = subprocess.Popen([sys.executable, sys.argv[1], sys.argv[2]], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
    def request(i, method, params=None):
        p.stdin.write(json.dumps({'jsonrpc':'2.0','id':i,'method':method,'params':params or {}})+'\\n'); p.stdin.flush()
        return json.loads(p.stdout.readline())['result']
    request(1, 'initialize')
    names = [t['name'] for t in request(2, 'tools/list')['tools']]
    assert 'git_status' in names
    result = request(3, 'tools/call', {'name':'project_run','arguments':{'name':'delayed'}})
    print(json.dumps(result))
    p.stdin.close(); p.wait(timeout=5)
    """.write(to: client, atomically: true, encoding: .utf8)
    let bridgeDone = DispatchSemaphore(value: 0); var bridgeResult = ""; var bridgeApproved = false
    DispatchQueue.global().async {
        bridgeResult = (try? ProjectProcess.run("/usr/bin/python3", [client.path, WorkspaceInvocation.resources.appendingPathComponent("workspace_mcp.py").path, manifest.path], cwd: root.path, token: run.attempt, deadline: Date().addingTimeInterval(40)).output) ?? "bridge failed"
        bridgeDone.signal()
    }
    let bridgeDeadline = Date().addingTimeInterval(45)
    while bridgeDone.wait(timeout: .now()) != .success && Date() < bridgeDeadline {
        RunLoop.main.run(until: Date().addingTimeInterval(0.03))
        if let card = ProjectCenter.shared.requests.first(where: { $0.run == run.id }) { bridgeApproved = true; ProjectCenter.shared.decide(card.id, allow: true) }
    }
    expect(bridgeApproved && bridgeResult.contains("long command fixture") && !bridgeResult.contains("timed out"), "long project tool survives Python bridge timeout and approval")
    // Stop must kill background writers, not merely the foreground build process.
    let startedFile = root.appendingPathComponent("process-started"), leakedFile = root.appendingPathComponent("orphan-wrote")
    let childCode = "import time,pathlib; time.sleep(2); pathlib.Path(" + String(reflecting: leakedFile.path) + ").write_text('leaked')"
    let parentCode = "import subprocess,sys,time,pathlib; subprocess.Popen([sys.executable,'-c'," + String(reflecting: childCode) + "]); pathlib.Path(" + String(reflecting: startedFile.path) + ").write_text('ready'); time.sleep(30)"
    let longConfig: [String: Any] = ["version": 1, "commands": ["long": ["executable": "/usr/bin/python3", "args": ["-c", parentCode]]]]
    try! JSONSerialization.data(withJSONObject: longConfig).write(to: root.appendingPathComponent(".ai-illuminati.json"))
    let stoppedDone = DispatchSemaphore(value: 0); var stoppedResult: [String: Any] = [:]
    DispatchQueue.global().async { stoppedResult = call("project_run", ["name": "long"]); stoppedDone.signal() }
    let stopDeadline = Date().addingTimeInterval(15)
    while !FileManager.default.fileExists(atPath: startedFile.path) && Date() < stopDeadline {
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        if let card = ProjectCenter.shared.requests.first(where: { $0.run == run.id }) { ProjectCenter.shared.decide(card.id, allow: true) }
    }
    expect(FileManager.default.fileExists(atPath: startedFile.path), "approved background-writer fixture started")
    outer.cancel()
    while stoppedDone.wait(timeout: .now()) != .success && Date() < stopDeadline { RunLoop.main.run(until: Date().addingTimeInterval(0.03)) }
    let verifyUntil = Date().addingTimeInterval(2.2)
    while Date() < verifyUntil { RunLoop.main.run(until: Date().addingTimeInterval(0.03)) }
    expect(stoppedResult["isError"] as? Bool == true && !FileManager.default.fileExists(atPath: leakedFile.path), "Stop kills foreground and background project writers")
    outer.cancel()
    for _ in 0..<50 where !run.attempt.isCancelled { Thread.sleep(forTimeInterval: 0.02) }
    expect(run.attempt.isCancelled && call("git_status")["isError"] as? Bool == true, "outer Stop cancels current AI and tool capability")
    print("PASS: plain-chat projects (repo locks, scoped tools, selective commits, push, dirty handoff, exact-SHA approval, named command approval and Stop)")
}

func testProjectHandoff() {
    let root = URL(fileURLWithPath: AccountStore.home).appendingPathComponent("handoff-project")
    try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    func git(_ args: [String]) { _ = try! ProjectProcess.git(args, root: root.path) }
    git(["init", "-b", "main"]); git(["config", "user.name", "Fixture"]); git(["config", "user.email", "fixture@example.invalid"])
    git(["remote", "add", "origin", root.path + "/unused-origin"])
    try! "Baseline".write(to: root.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
    git(["add", "README.md"]); git(["commit", "-m", "Initial"])
    let project = try! ProjectProcess.inspect(root.path)
    let model = AppModel()
    model.accounts = [Account(id: "project-claude", provider: .claude, name: "Fixture Claude"), Account(id: "project-codex", provider: .codex, name: "Fixture Codex")]
    model.schoolOnlyHandoff = false
    let chat = Discussion(model: model)
    chat.configure { $0.mode = 0; $0.soloAccountID = "project-claude" }
    chat.change(chat.currentID) { $0.workspace = WorkspaceBinding(roots: [WorkspaceRoot(path: root.path, directory: true)], project: project) }
    let file = root.appendingPathComponent("unfinished.txt")
    var accounts: [String] = [], oldContext: ToolContext?
    chat.workspaceAnswer = { account, prompt, binding, _, _ in
        accounts.append(account.id)
        if account.id == "project-claude" {
            try! "partial work".write(to: file, atomically: true, encoding: .utf8)
            oldContext = ToolContext(room: chat.currentID, roots: binding.roots, projectRun: binding.projectRunID, projectGeneration: binding.projectGeneration)
            do { _ = try ProjectWork.acquire(binding); expect(false, "other writers cannot enter during an AI turn") } catch {}
            return .failure(.failed("usage limit reached (429)"))
        }
        expect((try! String(contentsOf: file, encoding: .utf8)) == "partial work" && prompt.contains("Usage exhausted"), "next AI receives unfinished file and verified checkpoint")
        expect(GitLink.shared.call("git_status", [:], context: oldContext!)["isError"] as? Bool == true, "old AI capability is revoked before next AI starts")
        try! "completed work".write(to: file, atomically: true, encoding: .utf8)
        return .success("Project continued.")
    }
    chat.draft = "Continue this project."; chat.send()
    let deadline = Date().addingTimeInterval(30)
    while Date() < deadline && (chat.anyRunning || chat.current.turns.last?.projectCommitted == nil) { RunLoop.main.run(until: Date().addingTimeInterval(0.03)) }
    expect(accounts == ["project-claude", "project-codex"] && chat.current.turns.last?.final == "Project continued.", "plain-chat project hands off Claude to Codex within the same turn")
    expect((try! String(contentsOf: file, encoding: .utf8)) == "completed work", "working tree survives handoff without forced commit or pull")
    expect((try! ProjectProcess.git(["log", "--oneline"], root: root.path)).split(separator: "\n").count == 1, "handoff never fabricates a checkpoint commit")
    print("PASS: project AI handoff (same plain chat, same dirty files, next AI continuation, old-token revocation and no forced commit)")
}

func testFullAuto() {
    let base = URL(fileURLWithPath: AccountStore.home).appendingPathComponent("auto-fixture-" + UUID().uuidString)
    try! FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    let root = base.appendingPathComponent("repo"), origin = base.appendingPathComponent("origin.git")
    func git(_ args: [String], at folder: URL? = nil) -> String { try! ProjectProcess.git(args, root: (folder ?? base).path) }
    _ = git(["init", "--bare", origin.path]); _ = git(["init", "-b", "main", root.path])
    _ = git(["config", "user.name", "Fixture"], at: root); _ = git(["config", "user.email", "fixture@example.invalid"], at: root)
    _ = git(["remote", "add", "origin", origin.path], at: root)
    try! "{\"version\":1,\"commands\":{\"hello\":{\"executable\":\"/bin/echo\",\"args\":[\"hi\"]}}}".write(to: root.appendingPathComponent(".ai-illuminati.json"), atomically: true, encoding: .utf8)
    _ = git(["add", "."], at: root); _ = git(["commit", "-m", "Initial"], at: root); _ = git(["push", "-u", "origin", "main"], at: root)
    let selected = try! ProjectProcess.inspect(root.path)
    var binding = WorkspaceBinding(roots: [WorkspaceRoot(path: root.path, directory: true, writable: true)], project: selected)

    // Environment: shims first on PATH, no Git/GitHub credentials.
    let env = AutoGuard.environment(["PATH": "/usr/bin:/bin", "GH_TOKEN": "x", "SSH_AUTH_SOCK": "/tmp/agent"])
    expect(env["PATH"]!.hasPrefix(AutoGuard.folder.path) && env["GH_TOKEN"] == nil && env["SSH_AUTH_SOCK"] == nil
           && env["GIT_CONFIG_VALUE_0"] == "" && env["GIT_CONFIG_KEY_1"] == "credential.https://github.com.helper" && env["GH_CONFIG_DIR"] != nil,
           "full auto environment drops Git and GitHub credentials")
    func shell(_ command: String) -> ProjectProcess.Reply {
        let p = Process(), out = Pipe(); p.executableURL = URL(fileURLWithPath: "/bin/bash"); p.arguments = ["-c", command]
        p.environment = env; p.currentDirectoryURL = root; p.standardOutput = out; p.standardError = out
        try! p.run(); let data = out.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
        return ProjectProcess.Reply(status: p.terminationStatus, output: String(decoding: data, as: UTF8.self))
    }
    let push = shell("git -C . push --force origin main")
    expect(push.status != 0 && push.output.contains("git_push"), "git shim refuses push (use the app's git_push)")
    expect(shell("git status --short").status == 0, "other git commands still work")
    let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("auto-rm-" + UUID().uuidString)
    try! "x".write(to: scratch, atomically: true, encoding: .utf8)
    expect(shell("rm -f '\(scratch.path)'").status == 0 && !FileManager.default.fileExists(atPath: scratch.path), "rm deletes temporary files normally")
    expect(shell("rm '\(scratch.path)'").status != 0 && shell("rm -f '\(scratch.path)'").status == 0, "rm keeps missing-file and -f semantics")

    // CLI options: no prompts, no sandbox, Git push denied.
    expect(binding.isFullAuto && !binding.fullAccessActive && !WorkspaceBinding(roots: []).isFullAuto, "linked folders are full auto by default; access opens only during a run")
    binding.fullAuto = false; expect(!binding.isFullAuto, "full auto can be turned off per chat")
    binding.fullAuto = nil; binding.level = .execute; binding.projectRunID = UUID()
    let room = UUID()
    let backup = try! WorkspaceBackup.begin(WorkspaceBinding(roots: binding.roots, level: .write), room: room, runID: binding.projectRunID!)
    let invocation = WorkspaceInvocation(binding: binding, room: room, readOnly: false, backupPath: backup.directory)
    let dir = base.appendingPathComponent("session"); try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let claude = try! invocation.arguments(provider: .claude, original: ["-p", "x", "--tools", "", "--mcp-config", "{}"], directory: dir, web: false)
    expect(claude.contains("bypassPermissions") && claude.contains("default") && !claude.contains("--restricted") && !claude.contains("--settings")
           && claude.contains { $0.contains("Bash(git push:*)") }, "Claude full auto: all tools, no prompts, no sandbox, push denied")
    let codex = try! invocation.arguments(provider: .codex, original: ["exec", "-C", dir.path, "x"], directory: dir, web: false)
    expect(codex.contains("sandbox_mode=\"danger-full-access\"") && codex.contains("web_search=\"live\"") && !codex.contains { $0.contains("network_access=false") },
           "Codex full auto: full access with network")

    // No approval card for registered commands; stable publishing keeps its card.
    let run = ProjectRun(room: UUID(), binding: selected, token: DebateCancellation(), fullAuto: true)
    expect(run.deadline.timeIntervalSinceNow > 8 * 3600 && run.activeLimit == 8 * 3600, "full auto runs up to 8 hours")
    ProjectWork.register(run); run.nextAttempt()
    defer { ProjectWork.finish(run) }
    let context = ToolContext(room: run.room, roots: binding.roots, projectRun: run.id, projectGeneration: run.generation)
    let reply = GitLink.shared.call("project_run", ["name": "hello"], context: context)
    let text = ((reply["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
    expect(reply["isError"] as? Bool == false && text.contains("hi") && ProjectCenter.shared.requests.isEmpty, "full auto runs registered commands without a card")
    let done = DispatchSemaphore(value: 0); var published: [String: Any] = [:]
    DispatchQueue.global().async { published = GitLink.shared.call("git_publish_stable", [:], context: context); done.signal() }
    var carded = false
    let limit = Date().addingTimeInterval(15)
    while done.wait(timeout: .now()) != .success && Date() < limit {
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        if !carded, let request = ProjectCenter.shared.requests.first(where: { $0.run == run.id }) { carded = true; ProjectCenter.shared.decide(request.id, allow: false) }
    }
    expect(carded && published["isError"] as? Bool == true && (try? ProjectProcess.git(["rev-parse", "--verify", "refs/heads/stable"], root: origin.path)) == nil,
           "full auto still asks before publishing stable; refusal publishes nothing")
    let note = Discussion.fullAutoNote
    expect(!note.contains("will not answer") && !note.contains("Do not publish stable") && note.contains("git_publish_stable") && note.contains("card"),
           "full auto lets a requested stable publish reach its card")
    expect(Discussion.projectFaceRule(face: true, active: true, moods: ["happy"]).contains("<face>MOOD</face>")
           && Discussion.projectFaceRule(face: true, active: false, moods: ["happy"]).isEmpty
           && Discussion.projectFaceRule(face: false, active: true, moods: ["happy"]).isEmpty,
           "project turns ask for a face tag when AI Face is connected")
    let folders = Discussion.soloFolders(WorkspaceBinding(roots: [WorkspaceRoot(path: "/chat", directory: true, writable: true),
                                                                  WorkspaceRoot(path: "/shared", directory: true),
                                                                  WorkspaceRoot(path: "/repo", directory: true, writable: true)]),
                                         shared: ["/shared"], project: "/repo")
    func compose(_ project: Discussion.ProjectPart?) -> String {
        Discussion.composeInstruction(name: "Claude", provider: .claude, folders: folders, drive: "[Drive rule]", fullAccess: false,
                                      picture: "[Picture rule]", helper: "", face: "[Face rule]", project: project)
    }
    let plain = compose(nil)
    let projectText = compose(.init(root: "/repo", fullAuto: true, rules: "[Project rules: AGENTS.md]\nTabs."))
    expect(["[Folders]", "/shared (shared folder — read only)", "[Drive rule]", "[Picture rule]", "[Face rule]", "search the web", "language of the user"]
            .allSatisfy { plain.contains($0) && projectText.contains($0) },
           "project work gets everything a plain chat gets (shared folders, web, Drive, pictures, face)")
    expect(projectText.contains("/repo (linked Git project") && projectText.contains("git_status") && projectText.contains(Discussion.fullAutoNote)
            && projectText.contains("Tabs.") && !projectText.contains("not code") && !projectText.contains("Do not run commands")
            && !projectText.contains("Markdown file in the chat folder") && !plain.contains("git_status") && plain.contains("Do not run commands"),
           "only project work adds the Git steps; plain-only lines stay out of it")
    expect(projectText.hasSuffix("[Face rule]") && !projectText.contains("\n\n"), "the face rule ends the instruction, without blank lines")
    print("PASS: full auto (no cards for commands, 8 hours, stable still asks, no Git credentials, git push blocked, rm to Trash outside temp)")
}

func testPeerReview() {
    // Who reviews: the other kind of AI on the chat's side; the same kind only when there is no other.
    let claude = Account(id: "peer-claude", provider: .claude, name: "C"), codex = Account(id: "peer-codex", provider: .codex, name: "G")
    var schoolCodex = Account(id: "peer-codex-school", provider: .codex, name: "GS"); schoolCodex.school = true
    let claude2 = Account(id: "peer-claude-2", provider: .claude, name: "C2"), gemini = Account(id: "peer-gemini", provider: .gemini, name: "Gem")
    expect(Peer.choose(asker: claude, picked: nil, accounts: [claude, codex, gemini], usage: [:], school: nil)?.id == codex.id, "Claude's reviewer is ChatGPT")
    expect(Peer.choose(asker: codex, picked: nil, accounts: [claude, codex], usage: [:], school: nil)?.id == claude.id, "ChatGPT's reviewer is Claude")
    expect(Peer.choose(asker: claude, picked: nil, accounts: [claude, codex, schoolCodex], usage: [:], school: true)?.id == schoolCodex.id, "Enterprise chats keep an Enterprise reviewer")
    expect(Peer.choose(asker: claude, picked: claude2.id, accounts: [claude, claude2, codex], usage: [:], school: nil)?.id == codex.id, "a picked reviewer of the same kind gives way to the other kind")
    expect(Peer.choose(asker: claude, picked: nil, accounts: [claude, claude2], usage: [:], school: nil)?.id == claude2.id, "same kind only when there is no other")
    expect(Peer.choose(asker: claude, picked: nil, accounts: [claude, gemini], usage: [:], school: nil) == nil, "nobody else: no reviewer")
    let now = Date()
    let soon = Peer.nextReview(after: now, random: 0).timeIntervalSince(now), late = Peer.nextReview(after: now, random: 1).timeIntervalSince(now)
    expect(soon == 40 * 60 && late == 80 * 60, "random review comes 40 to 80 minutes later")
    expect(Peer.shortStat(" 6 files changed, 150 insertions(+), 60 deletions(-)") == (6, 210) && Peer.shortStat(" 1 file changed, 1 deletion(-)") == (1, 1), "diff size")
    expect(Peer.noIssues("No issues.") && Peer.noIssues("**문제 없음**") && !Peer.noIssues("No issues except one: a crash"), "a clean review is recognised")
    // Older chat files and other Macs' copies have none of the new fields.
    let oldConfig = try? JSONDecoder().decode(ChatConfiguration.self, from: Data(#"{"mode":0,"order":["claude"],"participants":["claude"],"leader":"claude"}"#.utf8))
    expect(oldConfig != nil && oldConfig?.peerReview == nil && oldConfig?.pendingReview == nil, "older chat settings still load (review off)")
    var turn = ChatTurn(question: "q"); turn.peerNotes = [.init(round: 1, speaker: "G", text: "ok", failed: false)]
    let again = try? JSONDecoder().decode(ChatTurn.self, from: JSONEncoder().encode(turn))
    expect(again?.peerNotes?.first?.text == "ok", "review notes are saved with the turn")
    expect(PeerLink.shared.tools(context: ToolContext(room: UUID(), roots: [])).isEmpty && PeerLink.shared.tools().isEmpty, "ask_peer only in a chat with review on")

    // A project chat with review on: Claude asks, ChatGPT answers read only; a due review follows the next answer.
    let root = URL(fileURLWithPath: AccountStore.home).appendingPathComponent("peer-project-" + UUID().uuidString)
    try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    func git(_ args: [String]) -> String { try! ProjectProcess.git(args, root: root.path) }
    _ = git(["init", "-b", "main"]); _ = git(["config", "user.name", "Fixture"]); _ = git(["config", "user.email", "fixture@example.invalid"])
    _ = git(["remote", "add", "origin", root.path + "/unused-origin"])
    try! "Baseline\n".write(to: root.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
    _ = git(["add", "README.md"]); _ = git(["commit", "-m", "Initial"])
    let model = AppModel()
    model.accounts = [claude, codex]
    model.schoolOnlyHandoff = false
    let chat = Discussion(model: model)
    chat.configure { $0.mode = 0; $0.soloAccountID = claude.id; $0.peerReview = true }
    chat.change(chat.currentID) { $0.workspace = WorkspaceBinding(roots: [WorkspaceRoot(path: root.path, directory: true)], project: try! ProjectProcess.inspect(root.path)) }
    let room = chat.currentID
    var prompts: [String] = [], peerPrompts: [String] = [], peerViews: [WorkspaceBinding] = [], replies: [String] = []
    var step = 0
    chat.workspaceAnswer = { account, prompt, binding, _, _ in
        if account.id == codex.id {
            peerPrompts.append(prompt); peerViews.append(binding)
            return .success(prompt.hasPrefix("[REVIEW]") ? "1. README.md:1 says Second; the user asked for Third." : "Plan is fine, but add a test.")
        }
        prompts.append(prompt)
        let context = ToolContext(room: room, roots: binding.roots)
        if step == 0 {
            expect(PeerLink.shared.tools(context: context).contains { $0["name"] as? String == "ask_peer" }, "review on: the answering AI has ask_peer")
            for _ in 0..<3 {
                let reply = PeerLink.shared.call("ask_peer", ["message": "My plan: edit README.md"], context: context)
                replies.append(((reply["content"] as? [[String: Any]])?.first?["text"] as? String) ?? "")
            }
        } else if step == 1 {
            try! "Second\n".write(to: root.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
            _ = try! ProjectProcess.git(["commit", "-am", "Second"], root: root.path)
        }
        return .success("Done \(step).")
    }
    func send(_ text: String, until done: () -> Bool) {
        chat.draft = text; chat.send()
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline && (chat.anyRunning || !done()) { RunLoop.main.run(until: Date().addingTimeInterval(0.03)) }
    }
    send("Edit the README.") { chat.configuration.nextReviewAt != nil }
    expect(prompts.first?.contains("[Review is on]") == true && prompts.first?.contains("ask_peer") == true && prompts.first?.contains(chat.label(codex)) == true,
           "the instruction names the reviewer and when to ask")
    expect(replies.count == 3 && replies[0].contains("Plan is fine") && replies[1].contains("Plan is fine") && replies[2].contains("already asked") && peerPrompts.count == 2,
           "ask_peer answers twice per answer, then says to continue alone")
    expect(peerViews.allSatisfy { $0.project == nil && $0.face == false && $0.roots.allSatisfy { $0.writable != true } }, "the other AI only reads, with no tools of its own")
    expect(peerPrompts.first?.contains("Edit the README.") == true && peerPrompts.first?.contains("My plan: edit README.md") == true, "the other AI sees the user's message and the plan")
    expect(chat.current.turns.last?.peerNotes?.count == 2 && chat.current.turns.last?.peerNotes?.first?.text.contains("Plan is fine") == true, "each opinion shows under the answer")
    expect(chat.configuration.nextReviewAt != nil && chat.configuration.pendingReview == nil && peerPrompts.allSatisfy { !$0.hasPrefix("[REVIEW]") }, "first answer only schedules the random review")

    // The review is due and there is a new commit: the other AI reviews the diff and its findings wait for the next answer.
    step = 1
    chat.change(room, save: true) { $0.configuration?.nextReviewAt = Date().addingTimeInterval(-1) }
    send("Change README to Second.") { chat.configuration.pendingReview != nil }
    let review = peerPrompts.last ?? ""
    expect(review.hasPrefix("[REVIEW]") && review.contains("+Second") && review.contains("Second"), "random review reads the commits since the last review")
    expect(chat.configuration.pendingReview?.contains("README.md:1") == true && chat.configuration.lastReviewSHA == git(["rev-parse", "HEAD"])
           && (chat.configuration.nextReviewAt ?? .distantPast) > Date().addingTimeInterval(39 * 60), "review findings are kept, and the next review is 40–80 minutes away")
    let card = chat.current.turns.last?.peerNotes?.last
    expect(card?.failed == false && card?.text.contains("README.md:1") == true && card?.headline?.contains("README.md:1") == true, "the review shows as a card under the answer")

    step = 2
    send("Anything else?") { chat.current.turns.last?.final != nil && !chat.anyRunning }
    expect(prompts.last?.contains("[Review of the recent work by") == true && prompts.last?.contains("README.md:1") == true && chat.configuration.pendingReview == nil,
           "the next answer gets the findings once, to judge itself")

    // Review off: no tool, no rule, no review.
    chat.configure { $0.peerReview = nil }
    step = 3
    let before = peerPrompts.count
    send("Thanks.") { chat.current.turns.last?.final != nil && !chat.anyRunning }
    expect(prompts.last?.contains("[Review is on]") == false && peerPrompts.count == before && PeerLink.shared.tools(context: ToolContext(room: room, roots: [])).isEmpty,
           "review off: no ask_peer and no reviews")
    print("PASS: review (ask_peer both ways, read-only other AI, two asks per answer, random review of new commits, findings handed on once, older files load)")
}
