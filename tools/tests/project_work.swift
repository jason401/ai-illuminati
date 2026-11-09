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
    RunLoop.main.run(until: Date().addingTimeInterval(0.1))
    let note = ProjectCenter.shared.expired.filter { $0.run == run.id }
    expect(note.map(\.title) == ["Expired"] && note.first?.deadline != nil && ProjectCenter.shared.requests.isEmpty, "timed-out approval leaves one Ask-again note, not a waiting card")
    ProjectCenter.shared.dismiss(note.first!.id)
    expect(ProjectCenter.shared.expired.isEmpty, "dismissing the note removes it")
    // Deciding twice (card and approval window at once) counts once; denied requests leave no timeout note.
    let twice = DispatchSemaphore(value: 0); var twiceAnswer: Bool?
    DispatchQueue.global().async { twiceAnswer = ProjectCenter.shared.approve(ProjectApproval(room: run.room, run: run.id, title: "Twice", detail: "fixture"), token: run.attempt, deadline: Date().addingTimeInterval(10)); twice.signal() }
    var twiceAt = Date().addingTimeInterval(5)
    while ProjectCenter.shared.requests.isEmpty && Date() < twiceAt { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    if let card = ProjectCenter.shared.requests.first { ProjectCenter.shared.decide(card.id, allow: false); ProjectCenter.shared.decide(card.id, allow: true) }
    twiceAt = Date().addingTimeInterval(5)
    while twice.wait(timeout: .now()) != .success && Date() < twiceAt { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    RunLoop.main.run(until: Date().addingTimeInterval(0.1))
    expect(twiceAnswer == false && ProjectCenter.shared.requests.isEmpty && ProjectCenter.shared.expired.isEmpty, "first decision wins; a second click is ignored")
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
    let stoppedRecord = ((try? JSONSerialization.jsonObject(with: Data(contentsOf: RunTimings.file(root.path)))) as? [String: Any])?["long"] as? [[String: Any]]
    expect(stoppedRecord?.last?["outcome"] as? String == "stopped" && stoppedRecord?.last?["exit"] == nil, "a stopped command is recorded as stopped")
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
            // The AI shows its steps; a bad list and another room are refused.
            expect(PlanLink.shared.tools(context: oldContext!).first?["name"] as? String == "work_plan" && PlanLink.shared.tools().isEmpty, "work_plan is scoped to the live project attempt")
            expect(PlanLink.shared.call("work_plan", ["steps": [["text": "x", "status": "maybe"]]], context: oldContext!)["isError"] as? Bool == true, "work_plan refuses an unknown status")
            var elsewhere = oldContext!; elsewhere.room = UUID()
            expect(PlanLink.shared.call("work_plan", ["steps": [["text": "x", "status": "todo"]]], context: elsewhere)["isError"] as? Bool == true, "work_plan refuses another chat")
            let shown = PlanLink.shared.call("work_plan", ["steps": [["text": "Read code", "status": "done"], ["text": "Write fix", "status": "doing"], ["text": "Run tests", "status": "todo"]],
                                                           "note": "found a second bug"], context: oldContext!)
            expect(shown["isError"] as? Bool == false, "work_plan accepts the steps: \(shown)")
            // Claude's TodoWrite does not replace a list made with work_plan.
            let run = ProjectWork.get(binding.projectRunID)!
            expect(!run.setPlan([WorkStep(text: "todo list", status: .todo)], note: nil, generation: run.generation, tool: false), "TodoWrite is ignored once work_plan was used")
            do { _ = try ProjectWork.acquire(binding); expect(false, "other writers cannot enter during an AI turn") } catch {}
            return .failure(.failed("usage limit reached (429)"))
        }
        expect((try! String(contentsOf: file, encoding: .utf8)) == "partial work" && prompt.contains("Usage exhausted"), "next AI receives unfinished file and verified checkpoint")
        expect(GitLink.shared.call("git_status", [:], context: oldContext!)["isError"] as? Bool == true, "old AI capability is revoked before next AI starts")
        expect(prompt.contains("[done] Read code\n[doing] Write fix\n[todo] Run tests"), "next AI gets the work plan in the checkpoint")
        expect(PlanLink.shared.call("work_plan", ["steps": [["text": "stale", "status": "done"]]], context: oldContext!)["isError"] as? Bool == true, "the old AI cannot change the plan after the handoff")
        try! "completed work".write(to: file, atomically: true, encoding: .utf8)
        return .success("Project continued.")
    }
    chat.draft = "Continue this project."; chat.send()
    let deadline = Date().addingTimeInterval(30)
    while Date() < deadline && (chat.anyRunning || chat.current.turns.last?.projectCommitted == nil) { RunLoop.main.run(until: Date().addingTimeInterval(0.03)) }
    expect(accounts == ["project-claude", "project-codex"] && chat.current.turns.last?.final == "Project continued.", "plain-chat project hands off Claude to Codex within the same turn")
    expect((try! String(contentsOf: file, encoding: .utf8)) == "completed work", "working tree survives handoff without forced commit or pull")
    expect(chat.current.turns.last?.plan?.map(\.text) == ["Read code", "Write fix", "Run tests"] && chat.current.turns.last?.planNote == "found a second bug"
           && chat.current.turns.last?.lastActivityAt != nil, "the plan and the last activity stay on the turn being answered")
    expect((try! ProjectProcess.git(["log", "--oneline"], root: root.path)).split(separator: "\n").count == 1, "handoff never fabricates a checkpoint commit")

    // Not picked by hand: the same 15% rule as a plain chat. The last account (Codex) has 10% of its 5-hour limit
    // left, so Claude starts; with enough left it keeps going.
    func left(_ five: Double) -> AIUsage { var u = AIUsage(name: "u"); u.fiveHour = UsageWindow(usedPercent: 100 - five, resetsAt: nil); u.weekly = UsageWindow(usedPercent: 20, resetsAt: nil); return u }
    model.latestUsage = ["project-claude": left(70), "project-codex": left(10)]
    chat.configure { $0.soloAccountID = nil; $0.lastSoloAccountID = "project-codex" }
    accounts = []
    chat.workspaceAnswer = { account, _, _, _, _ in accounts.append(account.id); return .success("Picked.") }
    func run() {
        chat.draft = "Next step."; chat.send()
        let until = Date().addingTimeInterval(30)
        while Date() < until && (chat.anyRunning || chat.current.turns.last?.final == nil) { RunLoop.main.run(until: Date().addingTimeInterval(0.03)) }
    }
    run()
    expect(accounts == ["project-claude"], "project work: the last account under 15% is not started")
    model.latestUsage["project-codex"] = left(60)
    chat.configure { $0.lastSoloAccountID = "project-codex" }
    accounts = []; run()
    expect(accounts == ["project-codex"], "project work: the last account keeps going with 15% or more left")
    print("PASS: project AI handoff (same plain chat, same dirty files, next AI continuation, old-token revocation and no forced commit, 15% rule at the start)")
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
    // Who reviews: the other kind of AI (in an Enterprise chat, of its organization); the same kind only when there is no other.
    let claude = Account(id: "peer-claude", provider: .claude, name: "C"), codex = Account(id: "peer-codex", provider: .codex, name: "G")
    var schoolCodex = Account(id: "peer-codex-school", provider: .codex, name: "GS"); schoolCodex.school = true
    let gsLock = EnterpriseLock(organization: "gs", name: "GS", lockedAt: Date())
    let claude2 = Account(id: "peer-claude-2", provider: .claude, name: "C2"), gemini = Account(id: "peer-gemini", provider: .gemini, name: "Gem")
    expect(Peer.choose(asker: claude, picked: nil, accounts: [claude, codex, gemini], usage: [:], lock: nil)?.id == codex.id, "Claude's reviewer is ChatGPT")
    expect(Peer.choose(asker: codex, picked: nil, accounts: [claude, codex], usage: [:], lock: nil)?.id == claude.id, "ChatGPT's reviewer is Claude")
    expect(Peer.choose(asker: claude, picked: nil, accounts: [claude, codex, schoolCodex], usage: [:], lock: gsLock)?.id == schoolCodex.id, "Enterprise chats keep an Enterprise reviewer of their organization")
    expect(Peer.choose(asker: claude, picked: claude2.id, accounts: [claude, claude2, codex], usage: [:], lock: nil)?.id == codex.id, "a picked reviewer of the same kind gives way to the other kind")
    expect(Peer.choose(asker: claude, picked: nil, accounts: [claude, claude2], usage: [:], lock: nil)?.id == claude2.id, "same kind only when there is no other")
    expect(Peer.choose(asker: claude, picked: nil, accounts: [claude, gemini], usage: [:], lock: nil) == nil, "nobody else: no reviewer")
    expect(Peer.noIssues("No issues.") && Peer.noIssues("**문제 없음**") && !Peer.noIssues("No issues except one: a crash"), "a clean review is recognised")
    // Older chat files and other Macs' copies have none of the new fields.
    let oldConfig = try? JSONDecoder().decode(ChatConfiguration.self, from: Data(#"{"mode":0,"order":["claude"],"participants":["claude"],"leader":"claude"}"#.utf8))
    expect(oldConfig != nil && oldConfig?.memberIDs == nil && oldConfig?.leadID == nil, "older chat settings still load (no members)")
    // A chat that had review on: its worker and its reviewer become the two members.
    var reviewed = ChatConfiguration(); reviewed.soloAccountID = claude.id; reviewed.peerReview = true
    expect(Discussion.migratedMembers(reviewed, accounts: [claude, claude2, codex], lock: nil) == [claude.id, codex.id], "review on: the other kind of AI joins as a member")
    reviewed.peerAccountID = claude2.id
    expect(Discussion.migratedMembers(reviewed, accounts: [claude, claude2, codex], lock: nil) == [claude.id, claude2.id], "the reviewer picked by hand joins")
    reviewed.memberIDs = [codex.id]
    expect(Discussion.migratedMembers(reviewed, accounts: [claude, codex], lock: nil) == [codex.id], "members saved since then win")
    var turn = ChatTurn(question: "q"); turn.peerNotes = [.init(round: 1, speaker: "G", text: "ok", failed: false)]
    let again = try? JSONDecoder().decode(ChatTurn.self, from: JSONEncoder().encode(turn))
    expect(again?.peerNotes?.first?.text == "ok", "review notes are saved with the turn")
    expect(PeerLink.shared.tools(context: ToolContext(room: UUID(), roots: [])).isEmpty && PeerLink.shared.tools().isEmpty, "ask_peer only in a chat with reviewers")

    // A project chat with Claude and ChatGPT as members: Claude leads; ChatGPT gives opinions and reviews changes, read only.
    let root = URL(fileURLWithPath: AccountStore.home).appendingPathComponent("peer-project-" + UUID().uuidString)
    try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    func git(_ args: [String]) -> String { try! ProjectProcess.git(args, root: root.path) }
    _ = git(["init", "-b", "main"]); _ = git(["config", "user.name", "Fixture"]); _ = git(["config", "user.email", "fixture@example.invalid"])
    _ = git(["remote", "add", "origin", root.path + "/unused-origin"])
    try! "Baseline\n".write(to: root.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
    _ = git(["add", "README.md"]); _ = git(["commit", "-m", "Initial"])
    // The user's own unfinished file is not part of any answer's changes.
    try! "mine\n".write(to: root.appendingPathComponent("user-notes.txt"), atomically: true, encoding: .utf8)
    let model = AppModel()
    model.accounts = [claude, codex]
    let chat = Discussion(model: model)
    chat.configure { $0.mode = 0; $0.leadID = claude.id }
    chat.toggleMember(claude.id); chat.toggleMember(codex.id)
    chat.change(chat.currentID) { $0.workspace = WorkspaceBinding(roots: [WorkspaceRoot(path: root.path, directory: true)], project: try! ProjectProcess.inspect(root.path)) }
    expect(chat.crew(project: true).map { $0.lead == claude.id && $0.others == [codex.id] } == true, "the lead works, the other member reviews")
    let room = chat.currentID
    var prompts: [String] = [], peerPrompts: [String] = [], peerViews: [WorkspaceBinding] = [], replies: [String] = []
    var step = 0, verdict = "1. README.md:1 says Second; the user asked for Third."
    var judged: [String] = [], nextRoute = RouteChoice.work, opinionViews: [WorkspaceBinding] = []
    chat.routeJudge = { prompt in judged.append(prompt); return (nextRoute, "Judge") }
    chat.workspaceAnswer = { account, prompt, binding, _, _ in
        if prompt.contains("[Opinion mode]") && account.id == claude.id { opinionViews.append(binding); return .success("Claude's view: keep it short.") }
        if account.id == codex.id {
            peerPrompts.append(prompt); peerViews.append(binding)
            return .success(prompt.hasPrefix("[REVIEW]") ? verdict : "Plan is fine, but add a test.")
        }
        prompts.append(prompt)
        let context = ToolContext(room: room, roots: binding.roots)
        if prompt.contains("[Review of the changes you just made") {
            try! "Third\n".write(to: root.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
            _ = try! ProjectProcess.git(["commit", "-am", "Third"], root: root.path)
            return .success("Took point 1: README now says Third.")
        }
        if step == 0 {
            expect(PeerLink.shared.tools(context: context).contains { $0["name"] as? String == "ask_peer" }, "the lead has ask_peer")
            for _ in 0..<3 {
                let reply = PeerLink.shared.call("ask_peer", ["message": "My plan: edit README.md"], context: context)
                replies.append(((reply["content"] as? [[String: Any]])?.first?["text"] as? String) ?? "")
            }
        } else {
            try! "Second \(step)\n".write(to: root.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
            _ = try! ProjectProcess.git(["commit", "-am", "Second"], root: root.path)
        }
        return .success("Done \(step).")
    }
    func send(_ text: String) {
        chat.draft = text; chat.send()
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline && (chat.anyRunning || chat.current.turns.last?.final == nil) { RunLoop.main.run(until: Date().addingTimeInterval(0.03)) }
    }
    send("What does the README say?")
    expect(prompts.first?.contains("[Review is on]") == true && prompts.first?.contains("ask_peer") == true && prompts.first?.contains(chat.label(codex)) == true,
           "the instruction names the reviewer and when to ask")
    expect(replies.count == 3 && replies[0].contains("Plan is fine") && replies[1].contains("Plan is fine") && replies[2].contains("already asked") && peerPrompts.count == 2,
           "ask_peer answers twice per answer, then says to continue alone")
    expect(chat.current.turns.last?.peerNotes?.count == 2 && chat.current.turns.last?.peerNotes?.first?.text.contains("Plan is fine") == true, "each opinion shows under the answer")
    expect(peerPrompts.allSatisfy { !$0.hasPrefix("[REVIEW]") } && prompts.count == 1, "a question that changes nothing is not reviewed")
    expect(chat.configuration.lastSoloAccountID == claude.id, "the lead is kept")

    // A change: ChatGPT reviews this answer's commit (not the user's file); Claude fixes what is right, once.
    step = 1
    send("Change README to Second.")
    let review = peerPrompts.last ?? ""
    expect(review.hasPrefix("[REVIEW]") && review.contains("+Second 1") && review.contains("Change README to Second.") && !review.contains("user-notes.txt"),
           "the review reads only what this answer changed")
    expect(peerViews.allSatisfy { $0.project == nil && $0.face == false && $0.roots.allSatisfy { $0.writable != true } }, "the reviewer only reads, with no tools of its own")
    let fix = prompts.last ?? ""
    expect(fix.contains("[Review of the changes you just made") && fix.contains("README.md:1 says Second") && fix.contains("Done 1."), "the lead gets the findings and its own reply")
    let last = chat.current.turns.last
    expect(last?.final?.contains("Done 1.") == true && last?.final?.contains("README now says Third") == true && git(["log", "-1", "--format=%s"]) == "Third",
           "the fix is made in the same turn and shown after the first reply")
    expect(last?.peerNotes?.count == 1 && last?.peerNotes?.first?.headline?.contains("README.md:1") == true && peerPrompts.filter { $0.hasPrefix("[REVIEW]") }.count == 1,
           "one review card, and no second review after the fix")
    expect(last?.plan?.map(\.status) == [.done, .done] && last?.plan?.first?.text.contains(chat.label(codex)) == true, "the app's review and fix steps end done")

    // A clean review: no fix pass.
    step = 2; verdict = "No issues"
    let asked = prompts.count
    send("Change README again.")
    expect(prompts.count == asked + 1 && chat.current.turns.last?.final == "Done 2." && chat.current.turns.last?.peerNotes?.first?.failed == false, "no issues: the answer stands")
    expect(chat.current.turns.last?.plan?.map(\.status) == [.done], "a clean review: one done review step, no fix step")

    expect(judged.count == 3 && judged[1].contains("Change README to Second.") && judged[1].contains("What does the README say?")
           && chat.current.turns.last?.route == .work && chat.current.turns.last?.routeNote?.contains("Judge") == true
           && prompts.last?.contains("[Work mode]") == true,
           "every message is sorted first, with the one before it; work is shown with who judged and told it may be wrong")

    // Opinion: both members answer at the same time, the project read only, no ask_peer and no review.
    nextRoute = .all
    let opinionBefore = peerPrompts.filter { $0.hasPrefix("[REVIEW]") }.count, head = git(["rev-parse", "HEAD"])
    send("Is splitting the README a good idea? What do you both think?")
    let opinion = chat.current.turns.last
    expect(opinion?.route == .opinion && opinion?.final == "Claude's view: keep it short." && opinion?.moreAnswers?.first?.text.contains("Plan is fine") == true
           && opinion?.routeNote?.contains("2") == true && opinion?.routeChoice == .all, "opinion: every member answers")
    expect(opinionViews.count == 1 && opinionViews[0].project == nil && opinionViews[0].roots.first { $0.path == root.path }?.writable != true
           && peerViews.last?.roots.allSatisfy { $0.writable != true } == true, "opinion: the project is read only for everyone")
    expect(peerPrompts.filter { $0.hasPrefix("[REVIEW]") }.count == opinionBefore && opinion?.peerNotes == nil && git(["rev-parse", "HEAD"]) == head,
           "opinion: no ask_peer, no review, nothing changed")

    // "가자" after the opinions: work, and the lead reads both opinions.
    nextRoute = .work; step = 4
    send("가자")
    expect(chat.current.turns.last?.route == .work && prompts.last?.contains("Claude's view: keep it short.") == true && prompts.last?.contains("Plan is fine") == true,
           "go: the lead works with every opinion in the transcript")

    // Run again as opinions: the same message, no judging.
    let judgedBefore = judged.count
    let pending = ChatImage(conversationID: chat.currentID, name: "pending.png")
    chat.draft = "half written"; chat.pendingImages = [pending]
    if let goTurn = chat.current.turns.last { chat.rerun(goTurn, as: .all) }
    expect(chat.draft == "half written" && chat.pendingImages.map(\.id) == [pending.id] && chat.current.turns.last?.images == nil,
           "run again keeps the message being written and its pictures in the box")
    chat.pendingImages = []
    let deadline = Date().addingTimeInterval(30)
    while Date() < deadline && (chat.anyRunning || chat.current.turns.last?.final == nil) { RunLoop.main.run(until: Date().addingTimeInterval(0.03)) }
    expect(chat.current.turns.last?.question == "가자" && chat.current.turns.last?.route == .opinion && judged.count == judgedBefore
           && chat.current.turns.last?.routeNote?.contains(L("직접", "by you")) == true, "run again in the other mode: forced, not judged")

    // One: only the lead answers, read only, nothing reviewed; "Ask the others too" sends it again to everyone, with its pictures.
    nextRoute = .one
    let oneViews = opinionViews.count, onePeers = peerPrompts.count, oneHead = git(["rev-parse", "HEAD"])
    let photo = ChatImage(conversationID: chat.currentID, name: "photo.png")
    chat.pendingImages = [photo]
    send("Does the README still say Third?")
    let one = chat.current.turns.last
    expect(one?.routeChoice == .one && one?.route == .opinion && one?.routeOne == true && one?.final == "Claude's view: keep it short." && one?.moreAnswers == nil
           && peerPrompts.count == onePeers && opinionViews.count == oneViews + 1 && opinionViews.last?.project == nil && git(["rev-parse", "HEAD"]) == oneHead
           && one?.routeNote?.contains(chat.label(claude)) == true, "one: only the lead answers, read only, the other member is not asked")
    if let oneTurn = one { chat.rerun(oneTurn, as: .all) }
    let oneDeadline = Date().addingTimeInterval(30)
    while Date() < oneDeadline && (chat.anyRunning || chat.current.turns.last?.final == nil) { RunLoop.main.run(until: Date().addingTimeInterval(0.03)) }
    let everyone = chat.current.turns.last
    expect(everyone?.question == "Does the README still say Third?" && everyone?.routeChoice == .all && everyone?.moreAnswers?.first?.text.contains("Plan is fine") == true
           && everyone?.images?.map(\.id) == [photo.id] && chat.pendingImages.isEmpty, "ask the others too: everyone answers the same message, with its pictures")

    // @ two members: their opinions, read only, not judged; @ one: that one works, not judged.
    let pickedJudged = judged.count, pickedViews = opinionViews.count, pickedReviews = peerPrompts.filter { $0.hasPrefix("[REVIEW]") }.count, pickedHead = git(["rev-parse", "HEAD"])
    chat.draftMentions = [claude.id, codex.id]
    send("@\(chat.label(claude)) @\(chat.label(codex)) Should the README be split?")
    let picked = chat.current.turns.last
    expect(judged.count == pickedJudged && picked?.route == .opinion && picked?.routeChoice == .all && picked?.mentions == [claude.id, codex.id]
           && picked?.routeNote?.contains("2") == true && picked?.routeNote?.contains(L("직접", "by you")) == true, "@ two: opinions, not judged")
    expect(Set([picked?.final ?? ""] + (picked?.moreAnswers?.map(\.text) ?? [])) == ["Claude's view: keep it short.", "Plan is fine, but add a test."],
           "@ two: both answer")
    expect(opinionViews.count == pickedViews + 1 && opinionViews.last?.project == nil && opinionViews.last?.roots.first { $0.path == root.path }?.writable != true
           && peerViews.last?.roots.allSatisfy { $0.writable != true } == true && peerPrompts.filter { $0.hasPrefix("[REVIEW]") }.count == pickedReviews
           && picked?.peerNotes == nil && git(["rev-parse", "HEAD"]) == pickedHead, "@ two: the project is read only, nothing reviewed or changed")
    step = 5
    chat.draftMentions = [claude.id]
    send("@\(chat.label(claude)) Change README to five.")
    expect(judged.count == pickedJudged && chat.current.turns.last?.route == nil && chat.current.turns.last?.final == "Done 5."
           && git(["log", "-1", "--format=%s"]) == "Second", "@ one: that AI works, not judged")

    // One member left: no ask_peer, no review.
    let judgedAlone = judged.count
    chat.toggleMember(codex.id)
    step = 3
    let before = peerPrompts.count
    send("Change README once more.")
    expect(prompts.last?.contains("[Review is on]") == false && peerPrompts.count == before && PeerLink.shared.tools(context: ToolContext(room: room, roots: [])).isEmpty,
           "one member: no ask_peer and no reviews")
    expect(judged.count == judgedAlone && chat.current.turns.last?.route == nil, "one member: nothing to sort")
    // Ask for opinions again with one member left: that member answers alone, read only, instead of failing.
    let aloneHead = git(["rev-parse", "HEAD"]), aloneViews = opinionViews.count
    if let aloneTurn = chat.current.turns.last { chat.rerun(aloneTurn, as: .all) }
    let aloneDeadline = Date().addingTimeInterval(30)
    while Date() < aloneDeadline && (chat.anyRunning || (chat.current.turns.last?.final == nil && chat.current.turns.last?.error == nil)) { RunLoop.main.run(until: Date().addingTimeInterval(0.03)) }
    let alone = chat.current.turns.last
    expect(alone?.routeChoice == .one && alone?.error == nil && alone?.final == "Claude's view: keep it short." && opinionViews.count == aloneViews + 1
           && git(["rev-parse", "HEAD"]) == aloneHead && peerPrompts.count == before, "opinions again with one member left: it answers alone, read only")
    testRoute()
    print("PASS: review (members: lead works, the other opines and reviews read only, two asks per answer, only changes reviewed, one fix in the same turn, older review chats migrate)")
}

func testRoute() {
    expect(Route.parse("WORK") == .work && Route.parse(" one.") == .one && Route.parse("ALL") == .all && Route.parse("Opinion") == .all
           && Route.parse("ONE, not ALL") == nil && Route.parse("NONE") == nil && Route.parse("음") == nil, "the sorter's word is read, whole words only")
    let prompt = Route.prompt(question: "수정하지 말고 의견만", history: [])
    expect(prompt.contains("수정하지 말고 의견만") && prompt.contains("ONE") && prompt.contains("ALL") && prompt.contains("가자") && !prompt.contains("[Last answer]")
           && prompt.contains("forbids changes"), "the sorter gets the message and the rules")
    var offered = ChatTurn(question: "버튼 고칠 수 있어?"); offered.final = String(repeating: "설명. ", count: 1000) + "괜찮으시면 \"가자\"라고 해 주세요."
    let long = Route.prompt(question: String(repeating: "가", count: 5000) + "끝\n> 예전 지시", history: [ChatTurn(question: "첫 질문"), offered])
    expect(long.contains("- 첫 질문") && long.contains("가자\"라고 해 주세요.") && long.contains("끝") && long.contains("(quoted) 예전 지시") && long.count < 9000,
           "long texts keep their start and end; quotes are marked")
    expect(Route.rule(question: "가자", previous: offered) == .work && Route.rule(question: "가자", previous: ChatTurn(question: "q")) == nil
           && Route.rule(question: "좋네!", previous: offered) == .one && Route.rule(question: "버튼 고쳐줘", previous: offered) == nil, "fixed rules: go after an offer, plain agreement")
    expect(Route.adjust(.work, question: "읽어만 봐") == .one && Route.adjust(.one, question: "어떻게 생각해?") == .all && Route.adjust(.work, question: "고쳐줘") == .work,
           "after the judge: no work when told not to change, views for everyone")
    let claude = Account(id: "route-claude", provider: .claude, name: "C")
    var asked = 0
    func decide(_ local: String?, _ member: String?, judge: Account? = claude) -> (RouteChoice, String?) {
        let r = Route.decide(local: { local.flatMap(Route.parse) }, localName: "Gemma", judge: judge, ask: { _ in asked += 1; return member }, label: { $0.name })
        return (r.route, r.by)
    }
    expect(decide("WORK", "ALL") == (.work, "Gemma") && asked == 0, "Gemma judges first; no AI is asked")
    expect(decide(nil, "ONE") == (.one, "C") && asked == 1, "no Gemma: the member judges")
    expect(decide("maybe", "ALL") == (.all, "C"), "Gemma's unclear reply: the member judges")
    expect(decide(nil, nil) == (.all, nil) && decide(nil, "WORK", judge: nil) == (.all, nil), "nobody can judge: everyone answers")
    expect(Discussion.routeNote(.one, by: "Gemma", names: ["Claude"]).contains("Claude") && Discussion.routeNote(.all, by: nil, names: ["A", "B"]).contains("2"), "the label says who answers")
    let chatFolder = "/chat/files"
    let binding = WorkspaceBinding(roots: [WorkspaceRoot(path: chatFolder, directory: true, writable: true), WorkspaceRoot(path: "/repo", directory: true, writable: true)],
                                   level: .execute, project: nil, face: true)
    let view = Route.opinionView(binding, chatFolder: chatFolder)
    expect(view.roots[0].writable == true && view.roots[1].writable != true && view.level == .view && view.project == nil && view.face == true, "opinion view: only the chat folder is writable")
    var turn = ChatTurn(question: "q"); turn.route = .opinion; turn.routeNote = "Opinion"
    let again = try? JSONDecoder().decode(ChatTurn.self, from: JSONEncoder().encode(turn))
    var plain = ChatTurn(question: "q"); plain.route = nil
    let older = try? JSONDecoder().decode(ChatTurn.self, from: JSONEncoder().encode(plain))
    var single = ChatTurn(question: "q"); single.route = .opinion; single.routeOne = true
    let savedOne = try? JSONDecoder().decode(ChatTurn.self, from: JSONEncoder().encode(single))
    expect(again?.route == .opinion && again?.routeNote == "Opinion" && again?.routeChoice == .all && older != nil && older?.route == nil && older?.routeChoice == nil
           && savedOne?.routeChoice == .one && savedOne?.route == .opinion, "the route is saved with the turn (one as opinion plus routeOne); turns without one still load")
    print("PASS: route (one, all or work; Gemma first, then the member, else all; opinion view read only)")
}

// The review sees a user's uncommitted change that the answer put back to HEAD.
func testProjectSnapshot() {
    let root = URL(fileURLWithPath: AccountStore.home).appendingPathComponent("snapshot-project")
    try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    func git(_ args: [String]) { _ = try! ProjectProcess.git(args, root: root.path) }
    git(["init", "-b", "main"]); git(["config", "user.name", "Fixture"]); git(["config", "user.email", "fixture@example.invalid"])
    let file = root.appendingPathComponent("notes.txt")
    try! "Baseline".write(to: file, atomically: true, encoding: .utf8)
    git(["add", "notes.txt"]); git(["commit", "-m", "Initial"])
    try! "User edit".write(to: file, atomically: true, encoding: .utf8)
    let start = ProjectSnapshot.take(root: root.path)
    expect(start.changes(root: root.path) == nil, "nothing to review when the answer changed nothing")
    git(["checkout", "--", "notes.txt"])
    let review = start.changes(root: root.path) ?? ""
    expect(review.contains("discarded") && review.contains("notes.txt"), "a user change put back to HEAD is in the review")
    let gone = root.appendingPathComponent("gone.txt")
    try! "Old".write(to: gone, atomically: true, encoding: .utf8)
    git(["add", "gone.txt"]); git(["commit", "-m", "Add gone"])
    try! "User edit".write(to: file, atomically: true, encoding: .utf8)
    try! FileManager.default.removeItem(at: gone)
    let before = ProjectSnapshot.take(root: root.path)
    git(["add", "-A"]); git(["commit", "-m", "Commit the user's edit and deletion"])
    let kept = before.changes(root: root.path) ?? ""
    expect(kept.contains("Commits made") && !kept.contains("discarded"), "a user change committed by the answer is not called discarded")
    print("PASS: project snapshot (discarded user changes; committed ones are not)")
}

// Step times (A) and project_run's "[n/m] name" stages with their record (C).
func testWorkTiming() {
    let t0 = Date(timeIntervalSince1970: 1000), t1 = t0.addingTimeInterval(60), t2 = t0.addingTimeInterval(130)
    var steps = WorkStep.timed([WorkStep(text: "Fix", status: .doing), WorkStep(text: "Test", status: .todo)], after: [], now: t0)
    expect(steps[0].started == t0 && steps[0].ended == nil && steps[1].started == nil, "a step starts when it becomes doing")
    steps = WorkStep.timed([WorkStep(text: "Fix", status: .done), WorkStep(text: "Docs", status: .todo), WorkStep(text: "Test", status: .doing)], after: steps, now: t1)
    expect(steps[0].started == t0 && steps[0].ended == t1 && steps[1].started == nil && steps[2].started == t1, "times follow the same text, not the position")
    steps[2].sub = "test [1/2] a"
    steps = WorkStep.timed([WorkStep(text: "Fix", status: .done), WorkStep(text: "Test", status: .blocked)], after: steps, now: t2)
    expect(steps[0].ended == t1 && steps[1].ended == t2 && steps[1].sub == nil, "a finished step keeps its end and loses its stage line")
    steps = WorkStep.timed([WorkStep(text: "Fix", status: .done), WorkStep(text: "Test", status: .doing)], after: steps, now: t2.addingTimeInterval(5))
    expect(steps[1].started == t1 && steps[1].ended == nil, "blocked then doing again counts on")
    let old = try? JSONDecoder().decode(WorkStep.self, from: Data(#"{"text":"x","status":"done"}"#.utf8))
    expect(old == WorkStep(text: "x", status: .done) && old?.started == nil, "steps saved before times decode without times")
    expect(RunProgress.stage("[7/9] Compile app tests")! == (7, 9, "Compile app tests") && RunProgress.stage("[0/3] x") == nil && RunProgress.stage("[4/3] x") == nil
           && RunProgress.stage("[1/3]") == nil && RunProgress.stage("[a/b] x") == nil && RunProgress.stage("1/3 x") == nil && RunProgress.stage("[1/0] x") == nil,
           "only well-formed [n/m] name lines are stages")
    expect(RunProgress.outcome(timedOut: true, stopped: true) == "timeout" && RunProgress.outcome(timedOut: false, stopped: true) == "stopped"
           && RunProgress.outcome(timedOut: false, stopped: false) == "error", "a time limit, a stop and a command that could not run are told apart")

    let base = URL(fileURLWithPath: AccountStore.home).appendingPathComponent("timing-fixture-" + UUID().uuidString)
    let root = base.appendingPathComponent("repo"), origin = base.appendingPathComponent("origin.git")
    try! FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    func git(_ args: [String], at folder: URL? = nil) -> String { try! ProjectProcess.git(args, root: (folder ?? base).path) }
    _ = git(["init", "--bare", origin.path]); _ = git(["init", "-b", "main", root.path])
    _ = git(["config", "user.name", "Fixture"], at: root); _ = git(["config", "user.email", "fixture@example.invalid"], at: root)
    _ = git(["remote", "add", "origin", origin.path], at: root)
    // Stage lines arrive split across writes and on both pipes; the last line has no newline.
    let script = "import sys,time\nw=sys.stdout.write\nw('[1/2] Com'); sys.stdout.flush(); time.sleep(0.2); w('pile\\nnoise 3/4 x\\n'); sys.stdout.flush(); time.sleep(0.3)\nsys.stderr.write('[2/2] Run\\r\\n'); sys.stderr.flush(); time.sleep(0.3); w('[9/2] bad')"
    let config: [String: Any] = ["version": 1, "commands": ["test": ["executable": "/usr/bin/python3", "args": ["-c", script]], "fail": ["executable": "/bin/sh", "args": ["-c", "echo '[1/1] Only'; exit 3"]]]]
    try! JSONSerialization.data(withJSONObject: config).write(to: root.appendingPathComponent(".ai-illuminati.json"))
    _ = git(["add", "."], at: root); _ = git(["commit", "-m", "Initial"], at: root); _ = git(["push", "-u", "origin", "main"], at: root)
    let selected = try! ProjectProcess.inspect(root.path)
    let binding = WorkspaceBinding(roots: [WorkspaceRoot(path: root.path, directory: true, writable: true)], project: selected)
    let run = ProjectRun(room: UUID(), binding: selected, token: DebateCancellation(), fullAuto: true)
    ProjectWork.register(run); run.nextAttempt()
    defer { ProjectWork.finish(run) }
    let context = ToolContext(room: run.room, roots: binding.roots, projectRun: run.id, projectGeneration: run.generation)
    let lock = NSLock(); var shown: [String?] = [], notes: [String] = []
    run.onPlan = { all, _ in lock.lock(); if shown.last != .some(all[1].sub) { shown.append(all[1].sub) }; lock.unlock() }
    run.onNote = { log in lock.lock(); notes = log; lock.unlock() }
    run.setPlan([WorkStep(text: "Edit", status: .done), WorkStep(text: "Test", status: .doing)], note: nil, generation: run.generation, tool: true)
    let reply = GitLink.shared.call("project_run", ["name": "test"], context: context)
    lock.lock(); let seen = shown; lock.unlock()
    expect(reply["isError"] as? Bool == false && seen == [nil, "test [1/2] Compile", "test [2/2] Run", nil], "stages show under the doing step, then clear: \(seen)")
    var all = (try? JSONSerialization.jsonObject(with: Data(contentsOf: RunTimings.file(root.path)))) as? [String: Any]
    let entry = (all?["test"] as? [[String: Any]])?.last, stages = entry?["stages"] as? [[String: Any]]
    expect(entry?["outcome"] as? String == "ok" && entry?["exit"] as? Int == 0 && stages?.map { $0["name"] as? String } == ["Compile", "Run"]
           && ((stages?[0]["seconds"] as? Double) ?? 0) >= 0.2 && ((entry?["seconds"] as? Double) ?? 0) >= 0.7, "the run and its stages are recorded: \(String(describing: entry))")
    // No doing step: the stage goes to the work log instead.
    run.setPlan([WorkStep(text: "Edit", status: .done), WorkStep(text: "Test", status: .done)], note: nil, generation: run.generation, tool: true)
    _ = GitLink.shared.call("project_run", ["name": "fail"], context: context)
    lock.lock(); let logged = notes; lock.unlock()
    all = (try? JSONSerialization.jsonObject(with: Data(contentsOf: RunTimings.file(root.path)))) as? [String: Any]
    expect(logged.contains("fail [1/1] Only") && (all?["fail"] as? [[String: Any]])?.last?["outcome"] as? String == "failed"
           && (all?["fail"] as? [[String: Any]])?.last?["exit"] as? Int == 3 && (all?["test"] as? [[String: Any]])?.count == 1, "without a doing step the stage is noted; a failure is recorded as failed")
    print("PASS: work timing (step times by text, [n/m] stages under the doing step, split lines, recorded runs and failures)")
}
