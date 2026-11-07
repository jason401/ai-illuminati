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
    binding.fullAuto = true; binding.level = .execute; binding.projectRunID = UUID()
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
    print("PASS: full auto (no cards for commands, 8 hours, stable still asks, no Git credentials, git push blocked, rm to Trash outside temp)")
}
