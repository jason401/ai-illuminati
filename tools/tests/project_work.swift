import Foundation
import CryptoKit

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
    do { _ = try ProjectWork.acquire(binding); expect(false, "concurrent project writer refused") }
    catch { expect(ProjectWork.isBusy(error.localizedDescription), "a busy repository is told apart (TODOs retry without counting)") }
    // While one chat writes, other chats of the project still read it: opinions and meetings take no lock.
    let reading = Route.opinionView(binding, chatFolder: base.appendingPathComponent("chat").path)
    expect((try? ProjectWork.acquire(reading)) == [], "a read-only answer needs no repository lock")
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

    // A TODO's chat: after a usage limit only the AIs picked for its list (when it started) take over, never the others.
    let savedTodos = TodoStore.shared
    let todos = TodoStore(url: URL(fileURLWithPath: AccountStore.home).appendingPathComponent("handoff-todos-\(UUID().uuidString).json"))
    TodoStore.shared = todos
    defer { TodoStore.shared = savedTodos }
    let todo = try! todos.add(title: "limited", project: project, projectName: "handoff")
    try! todos.change(todo.id) { $0.state = .running; $0.room = chat.currentID; $0.workers = ["project-claude"] }
    expect(todos.current.workers(room: chat.currentID) == ["project-claude"] && todos.current.workers(room: UUID()) == nil, "a chat's workers come from the TODO running in it")
    chat.configure { $0.soloAccountID = "project-claude"; $0.lastSoloAccountID = nil }
    accounts = []
    chat.workspaceAnswer = { account, _, _, _, _ in accounts.append(account.id); return .failure(.failed("usage limit reached (429)")) }
    run()
    expect(accounts == ["project-claude"] && chat.current.turns.last?.error?.contains(L("이 TODO에 고른 AI", "picked for this TODO")) == true,
           "a TODO's work is not handed to an AI outside its pick: \(accounts) \(chat.current.turns.last?.error ?? "-")")
    print("PASS: project AI handoff (same plain chat, same dirty files, next AI continuation, old-token revocation and no forced commit, 15% rule at the start, TODO pick kept)")
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
    // security: the app's own logins stay out of reach; Claude Code's own item still passes (a made-up one, never found).
    for blocked in ["security find-generic-password -s 'AI Illuminati Google' -w", "security dump-keychain",
                    "security find-generic-password -a oauth -w", "security find-generic-password -ws 'Claude Code-credentials'",
                    "printf 'find-generic-password -s \"AI Illuminati MCP\" -w\\n' | security -i",
                    "printf 'find-generic-password -a \"z -s \"Claude Code-credentials\"\" -s \"AI Illuminati Google\" -w\\n' | security -i"] {
        let r = shell(blocked)
        expect(r.status != 0 && r.output.contains("AI Illuminati full auto"), "security shim blocks: \(blocked)")
    }
    for passed in ["security find-generic-password -s 'Claude Code-credentials-00000000' -a nobody -w",
                   "printf 'find-generic-password -a \"nobody\" -s \"Claude Code-credentials-00000000\"\\n' | security -i"] {
        expect(!shell(passed).output.contains("AI Illuminati full auto"), "security shim passes Claude Code's own item: \(passed)")
    }
    expect(AutoGuard.claudeDenied.contains("Bash(/usr/bin/security:*)"), "Claude Bash cannot call /usr/bin/security directly")

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
    expect(PeerLink.shared.tools(context: ToolContext(room: UUID(), roots: [])).isEmpty && PeerLink.shared.tools().isEmpty, "ask_ai only while a message is answered")

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
        let context = ToolContext(room: room, roots: binding.roots, asker: account)
        if prompt.contains("[Review of the changes you just made") {
            try! "Third\n".write(to: root.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
            _ = try! ProjectProcess.git(["commit", "-am", "Third"], root: root.path)
            return .success("Took point 1: README now says Third.")
        }
        if step == 0 {
            expect(PeerLink.shared.tools(context: context).contains { $0["name"] as? String == "ask_ai" }, "the lead has ask_ai")
            for _ in 0...Peer.maxAsks {
                let reply = PeerLink.shared.call("ask_ai", ["message": "My plan: edit README.md"], context: context)
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
    expect(prompts.first?.contains("[Review is on]") == true && prompts.first?.contains("ask_ai") == true && prompts.first?.contains(chat.label(codex)) == true,
           "the instruction names the reviewer and when to ask")
    expect(replies.count == Peer.maxAsks + 1 && replies.prefix(Peer.maxAsks).allSatisfy { $0.contains("Plan is fine") } && replies.last?.contains("already asked") == true
           && peerPrompts.count == Peer.maxAsks, "ask_ai answers four times per answer, then says to continue alone")
    expect(chat.current.turns.last?.peerNotes?.count == Peer.maxAsks && chat.current.turns.last?.peerNotes?.first?.text.contains("Plan is fine") == true, "each opinion shows under the answer")
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

    // Opinion: both members answer at the same time, the project read only, no review.
    nextRoute = .all
    let opinionBefore = peerPrompts.filter { $0.hasPrefix("[REVIEW]") }.count, head = git(["rev-parse", "HEAD"])
    send("Is splitting the README a good idea? What do you both think?")
    let opinion = chat.current.turns.last
    expect(opinion?.route == .opinion && opinion?.final == "Claude's view: keep it short." && opinion?.moreAnswers?.first?.text.contains("Plan is fine") == true
           && opinion?.routeNote?.contains("2") == true && opinion?.routeChoice == .all, "opinion: every member answers")
    expect(opinionViews.count == 1 && opinionViews[0].project == nil && opinionViews[0].roots.first { $0.path == root.path }?.writable != true
           && peerViews.last?.roots.allSatisfy { $0.writable != true } == true, "opinion: the project is read only for everyone")
    expect(peerPrompts.filter { $0.hasPrefix("[REVIEW]") }.count == opinionBefore && opinion?.peerNotes == nil && git(["rev-parse", "HEAD"]) == head,
           "opinion: no review, nothing changed")

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

    // Another chat or TODO is changing the project: judged work becomes an opinion (the judge is told), /w still says busy.
    let writing = chat.soloBinding(chat.currentID), held = try! ProjectWork.acquire(writing)
    expect(!held.isEmpty && ProjectWork.busy(writing), "a held project is seen as busy")
    nextRoute = .work
    let busyHead = git(["rev-parse", "HEAD"]), busyJudged = judged.count, busyViews = opinionViews.count
    send("Change README to six.")
    let rerouted = chat.current.turns.last
    expect(judged.count == busyJudged + 1 && judged.last?.contains("cannot be work") == true && rerouted?.routeChoice == .one && rerouted?.error == nil
           && rerouted?.final == "Claude's view: keep it short." && rerouted?.routeNote?.contains(L("작업 중", "is working")) == true
           && opinionViews.count == busyViews + 1 && git(["rev-parse", "HEAD"]) == busyHead, "busy project: judged work answers as one, read only, with a note")
    nextRoute = .all
    send("Should the README be split while that runs?")
    expect(chat.current.turns.last?.routeChoice == .all && chat.current.turns.last?.error == nil, "busy project: opinions still work")
    chat.draft = "/w Change README to six."; chat.send()
    let busyDeadline = Date().addingTimeInterval(30)
    while Date() < busyDeadline && (chat.anyRunning || (chat.current.turns.last?.final == nil && chat.current.turns.last?.error == nil)) { RunLoop.main.run(until: Date().addingTimeInterval(0.03)) }
    expect(chat.current.turns.last.map { ProjectWork.isBusy($0.error ?? "") } == true && git(["rev-parse", "HEAD"]) == busyHead, "busy project: work picked with /w says it is busy")
    ProjectWork.release(held)
    expect(!ProjectWork.busy(writing), "free again after release")
    nextRoute = .one

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

    // One member left: no review.
    let judgedAlone = judged.count
    chat.toggleMember(codex.id)
    step = 3
    let before = peerPrompts.count
    send("Change README once more.")
    let closing = Date().addingTimeInterval(5)   // the worker closes ask_ai just after the answer is shown
    while Date() < closing && PeerLink.shared.session(room) != nil { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    expect(prompts.last?.contains("[Review is on]") == false && prompts.last?.contains("ask_ai") == true && peerPrompts.count == before
           && PeerLink.shared.tools(context: ToolContext(room: room, roots: [])).isEmpty,
           "one member: no reviews, but ask_ai still reaches the other AI on this Mac")
    expect(judged.count == judgedAlone && chat.current.turns.last?.route == nil, "one member: nothing to sort")
    // Ask for opinions again with one member left: that member answers alone, read only, instead of failing.
    let aloneHead = git(["rev-parse", "HEAD"]), aloneViews = opinionViews.count
    if let aloneTurn = chat.current.turns.last { chat.rerun(aloneTurn, as: .all) }
    let aloneDeadline = Date().addingTimeInterval(30)
    while Date() < aloneDeadline && (chat.anyRunning || (chat.current.turns.last?.final == nil && chat.current.turns.last?.error == nil)) { RunLoop.main.run(until: Date().addingTimeInterval(0.03)) }
    let alone = chat.current.turns.last
    expect(alone?.routeChoice == .one && alone?.error == nil && alone?.final == "Claude's view: keep it short." && opinionViews.count == aloneViews + 1
           && git(["rev-parse", "HEAD"]) == aloneHead && peerPrompts.count == before, "opinions again with one member left: it answers alone, read only")
    // One member, another writer holds the project: that member answers read only instead of failing as busy.
    let aloneHeld = try! ProjectWork.acquire(chat.soloBinding(chat.currentID)), aloneBusyViews = opinionViews.count
    send("Change README to seven.")
    let aloneBusy = chat.current.turns.last
    expect(aloneBusy?.routeChoice == .one && aloneBusy?.error == nil && aloneBusy?.routeNote?.contains(L("작업 중", "is working")) == true
           && opinionViews.count == aloneBusyViews + 1 && opinionViews.last?.project == nil && git(["rev-parse", "HEAD"]) == aloneHead,
           "one member, busy project: it answers read only with a note")
    ProjectWork.release(aloneHeld)
    testRoute()
    print("PASS: review (members: lead works, the other opines and reviews read only, four asks per answer, only changes reviewed, one fix in the same turn, older review chats migrate)")
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
    try! "*.txt text\n".write(to: root.appendingPathComponent(".gitattributes"), atomically: true, encoding: .utf8)
    git(["add", ".gitattributes"]); git(["commit", "-m", "Normalize line endings"])
    try! "User\r\nedit\r\n".write(to: file, atomically: true, encoding: .utf8)
    let crlf = ProjectSnapshot.take(root: root.path)
    git(["add", "notes.txt"]); git(["commit", "-m", "Commit the CRLF edit"])
    let normalized = crlf.changes(root: root.path) ?? ""
    expect(normalized.contains("Commits made") && !normalized.contains("discarded"), "a CRLF edit committed as LF is not called discarded")
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

// create_project and + → New project: a fake gh (no network) whose "GitHub" is bare repositories in the fixture.
func testProjectCreate() {
    let base = URL(fileURLWithPath: AccountStore.home).appendingPathComponent("project-create-" + UUID().uuidString)
    let fm = FileManager.default, projects = base.appendingPathComponent("Projects"), remotes = base.appendingPathComponent("remotes")
    try! fm.createDirectory(at: projects, withIntermediateDirectories: true); try! fm.createDirectory(at: remotes, withIntermediateDirectories: true)
    try! fm.createDirectory(at: base.appendingPathComponent("Library"), withIntermediateDirectories: true)
    let fake = base.appendingPathComponent("gh")
    try! """
    #!/bin/bash
    F='\(base.path)'
    case "$1 $2" in
      "api user") [ -e "$F/logged-out" ] && { echo "You are not logged into any GitHub hosts. Run gh auth login" >&2; exit 4; }; echo tester;;
      "repo view") [ -e "$F/offline" ] && { echo "error connecting to api.github.com" >&2; exit 1; }
                   n="${3#*/}"; [ -d "$F/remotes/$n.git" ] && { echo '{"name":"'$n'"}'; exit 0; }
                   echo "GraphQL: Could not resolve to a Repository with the name '$3'. (repository)" >&2; exit 1;;
      "repo create") n="${3#*/}"; o="${3%%/*}"
                     /usr/bin/git init -q --bare "$F/remotes/$n.git" && echo "$4" > "$F/remotes/$n.visibility"
                     [ -e "$F/no-remote" ] && { echo "stopped" >&2; exit 1; }
                     /usr/bin/git remote add origin "https://github.com/$o/$n.git"
                     [ -e "$F/push-fails" ] && { echo "push failed: network" >&2; exit 1; }
                     /usr/bin/git push -q -u origin main;;
      *) echo "unexpected gh $*" >&2; exit 2;;
    esac
    """.write(to: fake, atomically: true, encoding: .utf8)
    try! fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fake.path)
    let savedCandidates = ProjectCreator.ghCandidates, savedHome = ProjectCreator.home, savedChats = ChatLink.shared.conversations
    let savedAdd = ProjectMakerLink.shared.addChat, savedTarget = ProjectCreator.pushTarget
    // "GitHub" is the fixture's bare repositories: every git here rewrites github.com/tester/ to them.
    let env = ["GIT_AUTHOR_NAME": "Fixture", "GIT_AUTHOR_EMAIL": "fixture@example.invalid", "GIT_COMMITTER_NAME": "Fixture", "GIT_COMMITTER_EMAIL": "fixture@example.invalid",
               "GIT_CONFIG_COUNT": "1", "GIT_CONFIG_KEY_0": "url.\(remotes.path)/.insteadOf", "GIT_CONFIG_VALUE_0": "https://github.com/tester/"]
    for (key, value) in env { setenv(key, value, 1) }
    ProjectCreator.pushTarget = { target, plan in target.hasPrefix(remotes.path + "/" + plan.repo) }
    defer {
        ProjectCreator.ghCandidates = savedCandidates; ProjectCreator.home = savedHome; ChatLink.shared.conversations = savedChats
        ProjectMakerLink.shared.addChat = savedAdd; ProjectCreator.pushTarget = savedTarget
        for key in env.keys { unsetenv(key) }
        try? fm.removeItem(at: base)
    }
    ProjectCreator.home = base.path
    func fails(_ work: () throws -> Any, _ text: String, _ message: String) {
        do { _ = try work(); expect(false, message) } catch { expect(error.localizedDescription.contains(text), message + ": " + error.localizedDescription) }
    }
    func remoteMain(_ name: String) -> String? { try? ProjectProcess.git(["rev-parse", "refs/heads/main"], root: remotes.appendingPathComponent(name + ".git").path) }

    // Names, places and remotes.
    expect((try? ProjectCreator.name(" my app ")) == "my-app", "spaces become -")
    for bad in ["", "새프로젝트", ".hidden", "-x", "a/b", String(repeating: "a", count: 101)] { expect((try? ProjectCreator.name(bad)) == nil, "bad name refused: \(bad)") }
    fails({ try ProjectCreator.location("/") }, "home", "outside home refused")
    fails({ try ProjectCreator.location(base.appendingPathComponent("Library").path) }, "Library", "Library refused")
    fails({ try ProjectCreator.location(base.appendingPathComponent("missing").path) }, "missing", "missing location refused")
    expect((try? ProjectCreator.location(nil)) == base.resolvingSymlinksInPath().path + "/Documents/Projects", "the default place may be missing (made with the project)")
    try! fm.createSymbolicLink(at: base.appendingPathComponent("escape"), withDestinationURL: URL(fileURLWithPath: "/tmp"))
    fails({ try ProjectCreator.location(base.appendingPathComponent("escape").path) }, "home", "a symlink out of home refused")
    let plan = ProjectCreator.Plan(folder: "/x/app", owner: "Tester", repo: "App", isPrivate: true)
    for remote in ["https://github.com/tester/app.git", "git@github.com:Tester/App.git", "ssh://git@github.com/tester/app", "https://github.com/tester/app/"] {
        expect(ProjectCreator.sameRepo(remote, plan), "same repository: \(remote)")
    }
    for remote in ["https://github.com/evil/app.git", "https://github.com/tester/app2.git", "https://gitlab.com/tester/app.git", "/tmp/app.git"] {
        expect(!ProjectCreator.sameRepo(remote, plan), "another repository: \(remote)")
    }

    // gh missing, logged out, offline: stop before any card, with what to do.
    ProjectCreator.ghCandidates = [base.appendingPathComponent("none").path]
    fails({ try ProjectCreator.prepare(name: "a", location: projects.path, isPrivate: true, token: nil) }, "brew install gh", "no gh: install hint")
    ProjectCreator.ghCandidates = [fake.path]
    fm.createFile(atPath: base.appendingPathComponent("logged-out").path, contents: Data())
    fails({ try ProjectCreator.prepare(name: "a", location: projects.path, isPrivate: true, token: nil) }, "gh auth login", "logged out: login hint")
    try! fm.removeItem(at: base.appendingPathComponent("logged-out"))
    fm.createFile(atPath: base.appendingPathComponent("offline").path, contents: Data())
    fails({ try ProjectCreator.prepare(name: "a", location: projects.path, isPrivate: true, token: nil) }, "api.github.com", "offline is not \"no such repository\"")
    try! fm.removeItem(at: base.appendingPathComponent("offline"))
    let ready = try! ProjectCreator.prepare(name: "fresh", location: projects.path, isPrivate: true, token: nil)
    expect(ready.plan == ProjectCreator.Plan(folder: projects.resolvingSymlinksInPath().path + "/fresh", owner: "tester", repo: "fresh", isPrivate: true) && !ready.resume, "plan: folder, gh account, private")
    expect(ProjectCreator.summary(ready.plan, resume: false).contains("tester/fresh (private)"), "the card shows account, name and visibility")

    // The tool: only for a known AI in an open chat; nothing made before the card is allowed.
    let room = Conversation(), account = Account(id: "maker", provider: .claude, name: "Maker", dir: nil)
    var locked = Conversation(); locked.enterpriseLock = EnterpriseLock(organization: "org", name: "Org", lockedAt: Date())
    ChatLink.shared.conversations = { [room, locked] }
    var added: [(ProjectBinding, String)] = []
    ProjectMakerLink.shared.addChat = { project, title in added.append((project, title)); return title }
    let link = ProjectMakerLink.shared
    let context = ToolContext(room: room.id, roots: [], asker: account)
    expect(link.tools().isEmpty && link.tools(context: ToolContext(room: room.id, roots: [])).isEmpty, "no tool without a known AI")
    expect(link.tools(context: ToolContext(room: locked.id, roots: [], asker: account)).isEmpty, "no tool in an Enterprise chat")
    expect(link.tools(context: context).first?["name"] as? String == "create_project", "offered in an open chat")
    ProjectCenter.shared.resume()
    func create(_ args: [String: Any], allow: Bool?) -> [String: Any] {
        let done = DispatchSemaphore(value: 0); var output: [String: Any] = [:]; var acted = false
        DispatchQueue.global().async { output = link.call("create_project", args, context: context); done.signal() }
        let limit = Date().addingTimeInterval(30)
        while done.wait(timeout: .now()) != .success && Date() < limit {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            if !acted, let allow, let card = ProjectCenter.shared.requests.first(where: { $0.room == room.id }) {
                acted = true; expect(card.detail.contains("tester/"), "card names the repository"); ProjectCenter.shared.decide(card.id, allow: allow)
            }
        }
        expect(allow == nil || acted, "a card was shown: \(output)")
        return output
    }
    var reply = create(["name": "denied", "location": projects.path], allow: false)
    expect(reply["isError"] as? Bool == true && !fm.fileExists(atPath: projects.appendingPathComponent("denied").path) && remoteMain("denied") == nil && added.isEmpty,
           "denied: no folder, no repository, no chat")
    reply = create(["name": "My App", "location": projects.path, "private": false], allow: true)
    let made = projects.appendingPathComponent("My-App").path
    expect(reply["isError"] as? Bool == false, "created: \(reply)")
    expect(remoteMain("My-App") == (try? ProjectProcess.git(["rev-parse", "HEAD"], root: made)) && remoteMain("My-App") != nil, "main is pushed")
    expect((try? String(contentsOfFile: remotes.appendingPathComponent("My-App.visibility").path, encoding: .utf8))?.contains("--public") == true, "visibility as asked")
    expect((try? String(contentsOfFile: made + "/README.md", encoding: .utf8)) == "# My-App\n", "README first commit")
    expect(added.count == 1 && added[0].0.root == URL(fileURLWithPath: made).resolvingSymlinksInPath().path && added[0].1 == "My-App", "a chat linked to the new project")
    expect((try? ProjectProcess.git(["status", "--porcelain"], root: made)) == "", "the marker stays out of the commit")
    // Asked again: the folder and the repository exist now, so it stops before a card.
    reply = create(["name": "My App", "location": projects.path, "private": false], allow: nil)
    expect(reply["isError"] as? Bool == true && added.count == 1, "an existing project is not made again")
    _ = try? ProjectProcess.git(["init", "-q", "--bare", remotes.appendingPathComponent("taken.git").path], root: base.path)
    fails({ try ProjectCreator.prepare(name: "taken", location: projects.path, isPrivate: true, token: nil) }, "already exists on GitHub", "an existing GitHub repository refused")

    // The repository was made but the push failed: asking again only pushes.
    fm.createFile(atPath: base.appendingPathComponent("push-fails").path, contents: Data())
    let retry = try! ProjectCreator.prepare(name: "retry", location: projects.path, isPrivate: true, token: nil).plan
    fails({ try ProjectCreator.create(retry, token: nil) }, "Ask again", "push failure reported")
    expect(remoteMain("retry") == nil, "nothing pushed yet")
    try! fm.removeItem(at: base.appendingPathComponent("push-fails"))
    let retryRoot = projects.resolvingSymlinksInPath().path + "/retry"
    // A pushurl to another repository: stop, even with origin itself right.
    _ = try! ProjectProcess.git(["config", "remote.origin.pushurl", "https://github.com/evil/retry.git"], root: retryRoot)
    fails({ try ProjectCreator.create(retry, token: nil) }, "pushurl", "the real push target is checked")
    _ = try! ProjectProcess.git(["config", "--unset", "remote.origin.pushurl"], root: retryRoot)
    // origin changed to another repository meanwhile: stop instead of pushing there.
    _ = try! ProjectProcess.git(["remote", "set-url", "origin", "https://github.com/evil/retry.git"], root: retryRoot)
    fails({ try ProjectCreator.create(retry, token: nil) }, "evil", "a foreign origin is never pushed to")
    _ = try! ProjectProcess.git(["remote", "set-url", "origin", "https://github.com/tester/retry.git"], root: retryRoot)
    let again = try! ProjectCreator.prepare(name: "retry", location: projects.path, isPrivate: true, token: nil)
    expect(again.resume && again.plan == retry, "the same plan continues")
    fails({ try ProjectCreator.prepare(name: "retry", location: projects.path, isPrivate: false, token: nil) }, "already exists", "another visibility is not the same plan")
    let project = try! ProjectCreator.create(again.plan, token: nil)
    expect(remoteMain("retry") == (try? ProjectProcess.git(["rev-parse", "HEAD"], root: project.root)) && (try? ProjectProcess.git(["rev-list", "--count", "HEAD"], root: project.root)) == "1",
           "pushed on retry, one commit")
    fails({ try ProjectCreator.prepare(name: "retry", location: projects.path, isPrivate: true, token: nil) }, "already exists", "once done, it is an existing project")
    // Made on GitHub but stopped before origin was added; the default place did not exist yet.
    fm.createFile(atPath: base.appendingPathComponent("no-remote").path, contents: Data())
    let late = try! ProjectCreator.prepare(name: "late", location: nil, isPrivate: true, token: nil).plan
    fails({ try ProjectCreator.create(late, token: nil) }, "Ask again", "stopped after the repository was made")
    try! fm.removeItem(at: base.appendingPathComponent("no-remote"))
    let lateProject = try! ProjectCreator.create(try! ProjectCreator.prepare(name: "late", location: nil, isPrivate: true, token: nil).plan, token: nil)
    expect(lateProject.root.hasSuffix("/Documents/Projects/late") && remoteMain("late") == (try? ProjectProcess.git(["rev-parse", "HEAD"], root: lateProject.root)),
           "origin added and pushed, default place made")
    print("PASS: new project (names and places, gh missing/logged out/offline, card first, deny makes nothing, folder + first commit + GitHub + push + linked chat, retry pushes only, foreign origin refused, Enterprise chats without it)")
}

// startTurn: a turn in a chat that is not open, started without the message box (TODO work and "Ask again"
// use it). The open chat, its draft and its pictures stay as they were; the background chat uses its own
// settings; a busy chat or three answering chats refuse; "Ask again" keeps the user's draft and is sent anyway.
func testStartTurn() {
    let model = AppModel()
    model.accounts = [Account(id: "start-claude", provider: .claude, name: "Start Claude"), Account(id: "start-codex", provider: .codex, name: "Start Codex")]
    let chat = Discussion(model: model)
    chat.configure { $0.mode = 0; $0.soloAccountID = "start-claude" }
    chat.change(chat.currentID, save: true) { $0.turns = [ChatTurn(question: "open chat")] }
    let open = chat.currentID
    chat.newConversation()
    let background = chat.currentID
    chat.configure { $0.mode = 0; $0.soloAccountID = "start-codex" }
    chat.change(background, save: true) { $0.turns = [ChatTurn(question: "earlier")] }
    chat.open(open)
    chat.draft = "half-written message"
    let gate = DispatchSemaphore(value: 0)
    var answered: [String] = []
    chat.workspaceAnswer = { account, prompt, _, _, _ in
        answered.append(account.id)
        if answered.count == 1 { gate.wait() }   // only the first turn waits (later prompts repeat it in the transcript)
        return .success("Background done.")
    }
    expect(chat.startTurn(room: background, question: "hold on") == nil, "startTurn starts a turn in a chat that is not open")
    expect(chat.currentID == open && chat.draft == "half-written message" && chat.current.turns.count == 1, "the open chat and its draft are untouched")
    expect(chat.startTurn(room: background, question: "again") != nil, "a chat still answering refuses another turn")
    let saved = chat.runningRooms
    chat.runningRooms = saved.union([UUID(), UUID()])
    expect(chat.startTurn(room: open, question: "full") != nil, "three chats answering: no fourth turn")
    chat.runningRooms = saved
    expect(chat.startTurn(room: UUID(), question: "x") != nil, "an unknown chat is refused")
    gate.signal()
    let until = Date().addingTimeInterval(15)
    while Date() < until && (chat.anyRunning || chat.conversation(background).turns.last?.final == nil) { RunLoop.main.run(until: Date().addingTimeInterval(0.03)) }
    let turn = chat.conversation(background).turns.last
    expect(turn?.question == "hold on" && turn?.final == "Background done." && answered == ["start-codex"],
           "the background chat answers with its own account: \(answered)")
    expect(chat.conversation(open).turns.count == 1 && chat.draft == "half-written message", "the open chat got no turn")
    // Ask again: sent even with a draft in the box, which stays; the request card goes away.
    let request = ProjectApproval(room: background, run: UUID(), title: "git_push", detail: "")
    ProjectCenter.shared.expired.append(request)
    chat.open(background)
    chat.draft = "my note here"
    chat.askAgain(request)
    expect(!ProjectCenter.shared.expired.contains { $0.id == request.id } && chat.draft == "my note here", "Ask again sends without taking the draft")
    let after = Date().addingTimeInterval(15)
    while Date() < after && (chat.anyRunning || chat.conversation(background).turns.count < 3) { RunLoop.main.run(until: Date().addingTimeInterval(0.03)) }
    expect(chat.conversation(background).turns.count == 3 && chat.conversation(background).turns.last?.final != nil, "Ask again started a turn in its chat")
    print("PASS: startTurn (background chat, own settings, open chat and draft untouched, busy and full refused, Ask again keeps the draft)")
}

// The way picked before sending (the chip, "/work ") and meetings (Meeting.swift), with fake answers.
func testPickedRoute() {
    let offered = RouteChoice.offered(project: true)
    expect(Route.slash("/work 고쳐줘", offered: offered)! == (.work, "고쳐줘") && Route.slash("/회의\n주제", offered: offered)! == (.meeting, "주제")
           && Route.slash("/Users/me/file 봐줘", offered: offered) == nil && Route.slash("이거 /work 해줘", offered: offered) == nil
           && Route.slash("/work", offered: offered) == nil && Route.slash("/work 고쳐", offered: RouteChoice.offered(project: false)) == nil,
           "slash: only a known word at the start, before a space; only the ways the chat offers")
    expect(RouteChoice.offered(project: false) == [.all, .meeting], "a plain chat offers everyone's views and a meeting")
    expect(Route.slash("/w 고쳐줘", offered: offered)! == (.work, "고쳐줘") && Route.slash("/M 주제", offered: offered)! == (.meeting, "주제")
           && Route.slash("/a 어때?", offered: offered)! == (.all, "어때?") && Route.slash("/opinion 어때?", offered: offered)! == (.all, "어때?")
           && Route.slash("/1 짧게", offered: offered)! == (.one, "짧게") && Route.slash("/x 뭐", offered: offered) == nil,
           "slash: short forms /w /m /a /1 and /opinion")
    expect(Route.slashMenu("/", cursor: 1, offered: offered)!.choices == [.one, .all, .work, .meeting]
           && Route.slashMenu("  /w", cursor: 4, offered: offered)! == (2, "w", [.work])
           && Route.slashMenu("/m", cursor: 2, offered: offered)!.choices == [.meeting]
           && Route.slashMenu("/work 설명", cursor: 2, offered: offered) == nil && Route.slashMenu("/w 설명", cursor: 2, offered: offered)! == (0, "w", [.work])
           && Route.slashMenu("/Users", cursor: 6, offered: offered) == nil && Route.slashMenu("/work 고쳐", cursor: 8, offered: offered) == nil
           && Route.slashMenu("이거 /w", cursor: 5, offered: offered) == nil && Route.slashMenu("/", cursor: 1, offered: []) == nil
           && Route.slashMenu("/w", cursor: 2, offered: RouteChoice.offered(project: false)) == nil
           && Route.slashMenu("/", cursor: 1, offered: RouteChoice.offered(project: false))!.choices == [.all, .meeting],
           "slash list: only while the first word after / is typed, only the ways the chat offers")
    expect(Set(Route.commands.map(\.choice)) == Set(RouteChoice.allCases) && Route.slashes.count == Route.commands.flatMap(\.words).count,
           "every way has slash words, none shared")

    let claude = Account(id: "pick-claude", provider: .claude, name: "PC"), codex = Account(id: "pick-codex", provider: .codex, name: "PG")
    let gemini = Account(id: "pick-gemini", provider: .gemini, name: "PM")
    let root = URL(fileURLWithPath: AccountStore.home).appendingPathComponent("pick-project-" + UUID().uuidString)
    try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    func git(_ args: [String]) -> String { try! ProjectProcess.git(args, root: root.path) }
    _ = git(["init", "-b", "main"]); _ = git(["config", "user.name", "Fixture"]); _ = git(["config", "user.email", "fixture@example.invalid"])
    _ = git(["remote", "add", "origin", root.path + "/unused-origin"])
    try! "One\n".write(to: root.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
    _ = git(["add", "README.md"]); _ = git(["commit", "-m", "Initial"])
    let model = AppModel()
    model.accounts = [claude, codex, gemini]
    let chat = Discussion(model: model)
    chat.configure { $0.mode = 0; $0.leadID = claude.id }
    chat.toggleMember(claude.id); chat.toggleMember(codex.id)
    chat.change(chat.currentID) { $0.workspace = WorkspaceBinding(roots: [WorkspaceRoot(path: root.path, directory: true)], project: try! ProjectProcess.inspect(root.path)) }
    let room = chat.currentID
    var judged = 0, asked: [(String, String)] = [], views: [WorkspaceBinding] = [], moderations = 0
    chat.routeJudge = { _ in judged += 1; return (.one, "Judge") }
    chat.workspaceAnswer = { account, prompt, binding, _, _ in
        asked.append((account.id, prompt)); views.append(binding)
        if prompt.contains("[MEETING RESULT]") { return .success("결론: README는 그대로 두자.\n이견: PG는 나누자고 했어.\n가자라고 하면 README를 정리할게.") }
        if prompt.contains("[MODE3 MODERATION]") {
            moderations += 1
            return .success(moderations == 1 ? #"{"action":"speak","speaker":"codex","focus":"check the README","board":"Agreed: keep"}"# : #"{"action":"finish","reason":"enough","board":"Agreed: keep"}"#)
        }
        if prompt.contains("[MODE3 SPEECH]") { return .success("TL;DR: \(account.name) view\n\n\(account.name) thinks so.") }
        if prompt.hasPrefix("[REVIEW]") { return .success("No issues") }
        if account.id == codex.id { return .success("Codex here.") }
        if !prompt.contains("[Opinion mode]") {
            try! "Two\n".write(to: root.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
            _ = try! ProjectProcess.git(["commit", "-am", "Two"], root: root.path)
        }
        return .success("Claude here.")
    }
    func wait() {
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline && (chat.anyRunning || (chat.current.turns.last?.final == nil && chat.current.turns.last?.error == nil)) {
            RunLoop.main.run(until: Date().addingTimeInterval(0.03))
        }
    }

    // The chip: work, even when the message says not to change anything; not judged; back to automatic after sending.
    chat.pickedRoute = .work
    chat.draft = "수정하지 말고 README 봐줘"; chat.send(); wait()
    let work = chat.current.turns.last
    expect(judged == 0 && work?.route == .work && work?.question == "수정하지 말고 README 봐줘" && chat.pickedRoute == nil
           && work?.routeNote?.contains(L("직접", "by you")) == true && git(["log", "-1", "--format=%s"]) == "Two",
           "chip work: works without judging, the no-change rule does not override it, then the chip is automatic again")
    // "/one " at the start: one answer, read only, and the word is not part of the message.
    chat.draft = "/one README 뭐라고 써 있어?"; chat.send(); wait()
    expect(judged == 0 && chat.current.turns.last?.routeChoice == .one && chat.current.turns.last?.question == "README 뭐라고 써 있어?", "slash one: one answer, the word removed")
    // @A @B with work: A works and B reviews (without a way picked, two @ are opinions).
    chat.pickedRoute = .work
    chat.draftMentions = [codex.id, claude.id]
    chat.draft = "@\(chat.label(codex)) @\(chat.label(claude)) README 고쳐"; chat.send(); wait()
    let pair = chat.current.turns.last
    expect(pair?.route == .work && pair?.routeNote?.contains(L("\(chat.label(codex)) 작업", "\(chat.label(codex)) works")) == true
           && pair?.routeNote?.contains(L("\(chat.label(claude)) 검수", "\(chat.label(claude)) reviews")) == true && pair?.final == "Codex here." && judged == 0,
           "@A @B + work: A works, B reviews")

    // @A + work with only B checked: B still reviews.
    chat.toggleMember(codex.id)
    chat.pickedRoute = .work
    chat.draftMentions = [codex.id]
    chat.draft = "@\(chat.label(codex)) README 고쳐"; chat.send(); wait()
    expect(chat.current.turns.last?.routeNote?.contains(L("\(chat.label(claude)) 검수", "\(chat.label(claude)) reviews")) == true && chat.current.turns.last?.final == "Codex here.",
           "@A + work: the one checked member reviews")
    chat.toggleMember(codex.id)

    // A meeting: in its own hidden chat, with the chat's members; the result comes back as the answer.
    chat.toggleMember(gemini.id)
    let turnsBefore = chat.current.turns.count, askedBefore = asked.count
    chat.pickedRoute = .meeting
    chat.draft = "README를 나눌까?"; chat.send(); wait()
    let met = chat.current.turns.last
    let meetingID = met?.meetingRoom
    let meeting = chat.conversations.first { $0.id == meetingID }
    expect(chat.current.turns.count == turnsBefore + 1 && met?.routeChoice == .meeting && met?.route == .opinion && met?.final?.contains("결론") == true
           && met?.finalBy?.contains(L("회의", "Meeting")) == true && met?.entries.isEmpty == true && chat.pickedRoute == nil,
           "meeting: the result is the answer; the speeches are not in this chat")
    expect(meeting?.meetingOf == MeetingLink(room: room, turn: met!.id) && meeting?.turns.first?.entries.filter { !$0.failed }.count == 4
           && !chat.listedConversations.contains { $0.id == meetingID } && !DeviceSync.shared.shares(meeting!)
           && !ChatLink.allowed(meeting!, asker: claude, room: room),
           "meeting: three opening views and one review in the hidden chat, not listed, synced or readable by tools")
    let meetingPrompts = asked[askedBefore...]
    expect(meetingPrompts.allSatisfy { !$0.1.contains("[Opinion mode]") } && meetingPrompts.contains { $0.1.contains("meeting-source.md") }
           && Set(meetingPrompts.map(\.0)) == [claude.id, codex.id, gemini.id]
           && views[askedBefore...].allSatisfy { $0.project == nil && $0.roots.allSatisfy { $0.writable != true || $0.path.contains(meetingID!.uuidString) } },
           "meeting: everyone knows the chat, the folders read only except the meeting's own")
    let source = try? String(contentsOf: Discussion.chatFolder(meetingID!).appendingPathComponent(Discussion.meetingSource), encoding: .utf8)
    expect(source?.contains("README 뭐라고 써 있어?") == true && source?.contains("README를 나눌까?") == true, "meeting: the chat so far is saved for it")
    let after = Discussion.transcript(chat.current.turns)
    expect(after.contains("결론: README는 그대로 두자.") && !after.contains("PM thinks so."), "later prompts carry the result only")
    expect(Route.rule(question: "가자", previous: met) == .work, "the result's offer makes 가자 work")
    let old = try? JSONDecoder().decode(ChatTurn.self, from: JSONEncoder().encode(met!))
    expect(old?.route == .opinion && old?.meetingRoom == meetingID, "a meeting turn is saved as an opinion with its room")

    // Deleting the chat deletes its meeting.
    chat.removeChats([chat.current])
    expect(!chat.conversations.contains { $0.id == meetingID }, "the meeting goes with its chat")

    // An Enterprise chat: the meeting is locked the same, and only AIs of its organization meet.
    var school = Account(id: "pick-school", provider: .claude, name: "Claude (Uni)"); school.school = true
    model.accounts = [school, codex, gemini]
    let locked = Discussion(model: model)
    let lock = Enterprise.organizations([school]).first!
    locked.configure { $0.mode = 0 }
    locked.change(locked.currentID) { $0.enterpriseLock = lock; $0.turns = [ChatTurn(question: "earlier")] }
    locked.toggleMember(school.id); locked.toggleMember(codex.id); locked.toggleMember(gemini.id)
    var lockedAsked: Set<String> = []
    locked.workspaceAnswer = { account, prompt, _, _, _ in
        lockedAsked.insert(account.id)
        if prompt.contains("[MEETING RESULT]") { return .success("결론: 됐어.") }
        if prompt.contains("[MODE3 MODERATION]") { return .success(#"{"action":"finish","reason":"enough","board":""}"#) }
        return .success("TL;DR: ok\n\nok")
    }
    expect(locked.routeChoices == [.all, .meeting], "a plain chat's chip offers everyone's views and a meeting")
    locked.draft = "/meet 정리해줘"; locked.send()
    let deadline = Date().addingTimeInterval(30)
    while Date() < deadline && (locked.anyRunning || locked.current.turns.last?.final == nil) { RunLoop.main.run(until: Date().addingTimeInterval(0.03)) }
    let lockedMeeting = locked.conversations.first { $0.id == locked.current.turns.last?.meetingRoom }
    expect(lockedMeeting?.enterpriseLock == lock && lockedAsked == [school.id] && locked.current.turns.last?.final == "결론: 됐어.",
           "Enterprise: the meeting keeps the lock and only the organization's AI meets")
    print("PASS: picked way (chip, slash, @ with work) and meetings (hidden chat, chat's context, result back, lock kept, deleted with the chat)")
}

// Members left automatic: a meeting (picked or asked for in words) gets two to four cloud AIs, two of a kind too.
func testAutoMeeting() {
    expect(Route.asksMeeting("이거 회의해줘") && Route.asksMeeting("다 같이 미팅 좀 해봐") && Route.asksMeeting("Let's hold a meeting on it")
           && !Route.asksMeeting("오늘 미팅 노트 정리해줘") && !Route.asksMeeting("회의록 봐줘") && !Route.asksMeeting("어제 회의했던 거 알려줘")
           && !Route.asksMeeting("> 회의해줘\n이건 인용이야"), "asking for a meeting in words: only an order to the AIs")
    let c1 = Account(id: "auto-c1", provider: .claude, name: "C1"), x1 = Account(id: "auto-x1", provider: .codex, name: "X1")
    let g = Account(id: "auto-g", provider: .gemini, name: "G"), c2 = Account(id: "auto-c2", provider: .claude, name: "C2")
    let x2 = Account(id: "auto-x2", provider: .codex, name: "X2"), local = Account(id: "auto-local", provider: .ollama, name: "Gemma")
    let all = [c1, x1, g, c2, x2, local]
    expect(Discussion.meetingTeam(all, usage: [:]) { _ in true }.map(\.id) == [c1.id, x1.id, g.id, c2.id],
           "auto team: one of each kind first, then a second account, four at most, no local model")
    expect(Discussion.meetingTeam([c1, local], usage: [:]) { _ in true }.map(\.id) == [c1.id], "auto team: whoever can come")
    expect(Discussion.meetingTeam(all, usage: [:]) { $0.id != x1.id && $0.id != c2.id }.map(\.id) == [c1.id, g.id, x2.id], "auto team: only AIs allowed in the chat")
    expect(Discussion.meetingTeam(all, usage: [:], picks: [x1.id: false, g.id: false, c2.id: false]) { _ in true }.map(\.id) == [c1.id, x2.id],
           "auto team: AIs switched off in Settings are left out, the others keep the default")
    expect(Discussion.meetingTeam(all, usage: [:], picks: [local.id: true, x1.id: false, x2.id: false]) { _ in true }.map(\.id) == [c1.id, g.id, local.id, c2.id],
           "auto team: a model on this Mac when switched on")
    expect(Discussion.meetingTeam(all, usage: [:], picks: [local.id: true]) { $0.provider != .ollama }.map(\.id) == [c1.id, x1.id, g.id, c2.id],
           "auto team: a local model only while it is allowed (Ollama on)")
    expect(Discussion.meetingTeam(all, usage: [:], picks: Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0.id == local.id) })) { _ in true }.map(\.id) == [local.id],
           "auto team: only a local model")
    expect(Discussion.meetingTeam(all, usage: [:], picks: Dictionary(uniqueKeysWithValues: all.map { ($0.id, false) })) { _ in true }.isEmpty,
           "auto team: everyone switched off, nobody")
    var signedOut = AIUsage(name: "X1"); signedOut.needsLogin = true
    expect(Discussion.meetingTeam([c1, x1], usage: [x1.id: signedOut], picks: [c1.id: false]) { _ in true }.isEmpty,
           "auto team: the picked AI signed out, nobody else is called")
    let keys = Discussion.speakerKeys([c1, x1, c2])
    expect(keys == [c1.id: "claude1", x1.id: "codex", c2.id: "claude2"], "speaker keys: numbered when two of a kind meet: \(keys)")
    expect(DebateDecision.parse(#"{"action":"speak","speaker":"Claude2","focus":"x"}"#, team: [c1, x1, c2])?.speaker == "claude2"
           && DebateDecision.parse(#"{"action":"speak","speaker":"claude","focus":"x"}"#, team: [c1, x1, c2]) == nil,
           "two of a kind: the moderator names one by its key")
    expect(Discussion.leastSpoken([c1], spoken: [:], last: c1.id).id == c1.id
           && Discussion.leastSpoken([c1, c2], spoken: [c1.id: 1, c2.id: 1], last: c1.id).id == c2.id, "least spoken: by account, never none")

    let model = AppModel()
    model.accounts = all
    let chat = Discussion(model: model)
    chat.configure { $0.mode = 0 }
    var asked: [String] = [], moderations = 0
    chat.workspaceAnswer = { account, prompt, _, _, _ in
        asked.append(account.id)
        if prompt.contains("[MEETING RESULT]") { return .success("결론: 둘 다 괜찮아.") }
        if prompt.contains("[MODE3 MODERATION]") {
            moderations += 1
            return .success(moderations == 1 ? #"{"action":"speak","speaker":"claude2","focus":"check it"}"# : #"{"action":"finish","reason":"enough"}"#)
        }
        return .success("TL;DR: \(account.name)\n\n\(account.name) view.")
    }
    expect(chat.memberIDs.isEmpty, "the members are automatic")
    chat.draft = "이 구조로 갈지 회의해줘"; chat.send()
    let deadline = Date().addingTimeInterval(30)
    while Date() < deadline && (chat.anyRunning || (chat.current.turns.last?.final == nil && chat.current.turns.last?.error == nil)) {
        RunLoop.main.run(until: Date().addingTimeInterval(0.03))
    }
    let turn = chat.current.turns.last
    let meeting = chat.conversations.first { $0.id == turn?.meetingRoom }
    let speeches = meeting?.turns.first?.entries.filter { !$0.failed } ?? []
    expect(turn?.meetingRoom != nil && turn?.final == "결론: 둘 다 괜찮아." && Set(asked) == [c1.id, x1.id, g.id, c2.id]
           && speeches.count == 5 && speeches.last?.speaker == chat.label(c2),
           "auto members: asked in words, four AIs meet (two Claude accounts apart) and the second Claude speaks when named: \(speeches.map(\.speaker))")
    func hold(_ chat: Discussion, _ text: String) -> ChatTurn? {
        chat.draft = text; chat.send()
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline && (chat.anyRunning || (chat.current.turns.last?.final == nil && chat.current.turns.last?.error == nil)) {
            RunLoop.main.run(until: Date().addingTimeInterval(0.03))
        }
        return chat.current.turns.last
    }
    // Several views asked for in words, in a plain chat: as many as asked, read only; a bare opinion question is one answer.
    expect(Route.askedViewers("2명 의견 들려줘") == 2 && Route.askedViewers("셋이 각자 생각 말해봐") == 3 && Route.askedViewers("2~3명 의견 줘") == 3
           && Route.askedViewers("다들 의견 줘") == Discussion.meetingMost && Route.askedViewers("What do two of you think?") == 2
           && Route.askedViewers("너희 생각은 어때?") == Discussion.meetingMost && Route.askedViewers("네 명이 얘기해봐") == 4,
           "asking several AIs for views: the number asked, or as many as can come")
    expect(Route.askedViewers("이거 어떻게 생각해?") == nil && Route.askedViewers("다들 이렇게 측정하던데 맞아?") == nil
           && Route.askedViewers("네 생각은 어때?") == nil && Route.askedViewers("저자 두 명이 쓴 논문 요약해줘") == nil
           && Route.askedViewers("> 2명 의견 줘\n이건 인용이야") == nil, "not several AIs: one AI asked, people, numbers of other things, quotes")
    var viewAsked: [(String, String)] = []
    let views = Discussion(model: model)
    views.configure { $0.mode = 0 }
    views.workspaceAnswer = { account, prompt, _, _, _ in
        viewAsked.append((account.id, prompt))
        return .success("\(account.name) view.")
    }
    let two = hold(views, "2명 의견 들려줘: A냐 B냐")
    expect(two?.routeChoice == .all && two?.meetingRoom == nil && Set(viewAsked.map(\.0)).count == 2
           && viewAsked.allSatisfy { $0.1.contains("[Opinion mode]") && !$0.1.contains("linked to the project") },
           "plain chat, 2명 의견: two AIs give views: \(viewAsked.map(\.0)) \(String(describing: two?.error))")
    viewAsked = []
    let single = hold(views, "이거 어떻게 생각해?")
    expect(single?.routeChoice != .all && viewAsked.count == 1, "plain chat, a bare opinion question: one answer: \(viewAsked.map(\.0))")
    viewAsked = []
    let everyone = hold(views, "/all 어때?")
    expect(everyone?.routeChoice == .all && Set(viewAsked.map(\.0)) == [c1.id, x1.id, g.id, c2.id],
           "plain chat, /all: up to four AIs, no local model: \(viewAsked.map(\.0))")
    // Picked in Settings → Chat: only a local model, so it answers alone; nobody picked, no answer.
    model.autoTeamPicks = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0.id == local.id) })
    viewAsked = []
    let localOnly = hold(views, "2명 의견 들려줘: A냐 B냐")
    expect(localOnly?.error == nil && viewAsked.map(\.0) == [local.id], "views: the one AI picked answers alone: \(viewAsked.map(\.0))")
    model.autoTeamPicks = Dictionary(uniqueKeysWithValues: all.map { ($0.id, false) })
    viewAsked = []
    let nobody = hold(views, "2명 의견 들려줘: A냐 B냐")
    expect(nobody?.error?.contains("자동으로 부를 AI") == true || nobody?.error?.contains("AIs picked automatically") == true, "views: nobody picked, a note")
    expect(viewAsked.isEmpty, "views: nobody picked, no AI called: \(viewAsked.map(\.0))")
    model.autoTeamPicks = [:]

    // One member checked by hand: that one meets, no AI the user did not pick.
    let one = Discussion(model: model)
    one.configure { $0.mode = 0 }
    one.toggleMember(x1.id)
    var oneAsked: Set<String> = []
    one.workspaceAnswer = { account, prompt, _, _, _ in
        oneAsked.insert(account.id)
        if prompt.contains("[MEETING RESULT]") { return .success("결론: 혼자.") }
        if prompt.contains("[MODE3 MODERATION]") { return .success(#"{"action":"finish","reason":"enough"}"#) }
        return .success("TL;DR: ok\n\nok")
    }
    let alone = hold(one, "/meet 정리해줘")
    expect(alone?.meetingRoom != nil && oneAsked == [x1.id], "one member checked: only that member meets: \(oneAsked)")

    // A model on this Mac checked by hand (or called with @) meets like any AI, though Settings leaves it out of
    // automatic picks; it is told it has no web search. With Ollama off it is left out.
    let wasLocal = model.localEnabled
    model.localEnabled = true
    model.autoTeamPicks = [local.id: false]
    var localAsked: [String: String] = [:]
    func localChat() -> Discussion {
        let chat = Discussion(model: model)
        chat.configure { $0.mode = 0 }
        chat.workspaceAnswer = { account, prompt, _, _, _ in
            if prompt.contains("[MEETING RESULT]") { return .success("결론: 같이.") }
            if prompt.contains("[MODE3 MODERATION]") { return .success(#"{"action":"finish","reason":"enough"}"#) }
            localAsked[account.id] = prompt
            return .success("TL;DR: ok\n\nok")
        }
        return chat
    }
    let checked = localChat()
    checked.toggleMember(c1.id); checked.toggleMember(local.id)
    let localMeeting = hold(checked, "/meet 정리해줘")
    expect(localMeeting?.meetingRoom != nil && Set(localAsked.keys) == [c1.id, local.id],
           "a local model checked by hand meets though switched off for automatic picks: \(localAsked.keys)")
    expect(localAsked[local.id]?.contains("You cannot search the web") == true && localAsked[local.id]?.contains("and search the web") == false
           && localAsked[c1.id]?.contains("You can search the web") == true, "a local model is told it has no web search, the others keep it")
    expect(Discussion.searchNote([]).contains("can search the web, so") && Discussion.searchNote(["gemma"]).contains("except gemma (no web search)"),
           "the moderator knows which AI cannot search")
    localAsked = [:]
    let called = localChat()
    _ = hold(called, "@젬마 @클로드 회의해줘")
    expect(localAsked.keys.contains(local.id), "a local model called with @ meets: \(localAsked.keys)")
    expect(checked.meetingMembers(room: checked.currentID, mentioned: [local.id], fallback: []).map(\.id) == [local.id],
           "a local model named for a meeting is a member")
    model.localEnabled = false
    expect(checked.meetingMembers(room: checked.currentID, mentioned: [local.id, c1.id], fallback: []).map(\.id) == [c1.id],
           "Ollama off: the local model is left out of a meeting")
    model.localEnabled = wasLocal
    model.autoTeamPicks = [:]

    // Only Gemini accounts can come (they never answer a plain chat alone): the meeting still starts.
    let g2 = Account(id: "auto-g2", provider: .gemini, name: "G2")
    let geminiModel = AppModel()
    geminiModel.accounts = [g, g2]
    let geminis = Discussion(model: geminiModel)
    geminis.configure { $0.mode = 0 }
    var geminiAsked: Set<String> = []
    geminis.workspaceAnswer = { account, prompt, _, _, _ in
        geminiAsked.insert(account.id)
        if prompt.contains("[MEETING RESULT]") { return .success("결론: 제미나이 둘.") }
        if prompt.contains("[MODE3 MODERATION]") { return .success(#"{"action":"finish","reason":"enough"}"#) }
        return .success("TL;DR: ok\n\nok")
    }
    let pair = hold(geminis, "/meet 정리해줘")
    expect(pair?.final == "결론: 제미나이 둘." && geminiAsked == [g.id, g2.id], "Gemini only: two Gemini accounts meet: \(String(describing: pair?.error))")
    print("PASS: automatic meeting members (two to four, two of a kind, asked in words, one checked member kept, Gemini only)")
}

// A documents project: a plain folder (no Git) of papers, slides and figures, worked on like a project with a backup.
func testDocumentsProject() {
    let base = URL(fileURLWithPath: AccountStore.home).appendingPathComponent("documents-fixture-" + UUID().uuidString)
    let paper = base.appendingPathComponent("Lamb Wave Paper"), repo = base.appendingPathComponent("code")
    try! FileManager.default.createDirectory(at: paper.appendingPathComponent("figures"), withIntermediateDirectories: true)
    try! FileManager.default.createDirectory(at: repo.appendingPathComponent("docs"), withIntermediateDirectories: true)
    _ = try! ProjectProcess.git(["init", "-b", "main"], root: repo.path)   // Git without origin
    try! "\\section{Results}\nThe velocity is 3.2 km/s.\n".write(to: paper.appendingPathComponent("main.tex"), atomically: true, encoding: .utf8)
    try! Data([0x50, 0x4b, 3, 4]).write(to: paper.appendingPathComponent("talk.pptx"))

    // Linking: a plain folder yes; a Git folder (also one without origin, or a folder inside it) or a top folder no.
    let project = try! ProjectProcess.documents(paper.path)
    expect(project.isDocuments && project.root == paper.resolvingSymlinksInPath().path && project.common == project.root && project.remoteURL.isEmpty,
           "a plain folder links as a documents project")
    expect((try? ProjectProcess.documents(repo.path)) == nil && (try? ProjectProcess.documents(repo.appendingPathComponent("docs").path)) == nil,
           "a Git folder (no origin) or a folder inside one is not a documents project")
    expect((try? ProjectProcess.inspect(repo.path)) == nil && ProjectProcess.isGitWorkTree(repo.path) && !ProjectProcess.isGitWorkTree(paper.path),
           "a Git folder without origin is told apart from a folder without Git")
    expect((try? ProjectProcess.documents(NSHomeDirectory())) == nil && (try? ProjectProcess.documents("/")) == nil && (try? ProjectProcess.documents(base.appendingPathComponent("missing").path)) == nil,
           "home, / and missing folders are refused")
    expect(project.protectedPaths == [project.root + "/.git"] && ProjectBinding(root: "/r", common: "/r/.git", remote: "origin", remoteURL: "").protectedPaths == ["/r/.git", "/r/.git"],
           "the sandbox protects only .git in a documents project, not the whole folder")
    // Saved chats and TODO lists from before have no kind: they stay Git projects.
    let old = try? JSONDecoder().decode(ProjectBinding.self, from: Data(#"{"root":"/r","common":"/r/.git","remote":"origin","remoteURL":"u"}"#.utf8))
    let again = try? JSONDecoder().decode(ProjectBinding.self, from: JSONEncoder().encode(project))
    expect(old != nil && old?.kind == nil && old?.isDocuments == false && again == project, "older project bindings still load; documents round-trip")

    // One writer per documents folder, also for a folder inside it.
    let binding = WorkspaceBinding(roots: [WorkspaceRoot(path: project.root, directory: true, writable: true)], project: project)
    let lease = try! ProjectWork.acquire(binding)
    expect(lease.first == project.root && ProjectWork.isHeld(project.root) && ProjectWork.isHeld(project.root + "/figures"), "the documents folder is locked while one AI writes")
    do { _ = try ProjectWork.acquire(binding); expect(false, "a second writer is refused") } catch { expect(ProjectWork.isBusy(error.localizedDescription), "a busy documents project is told apart") }
    let inner = try! ProjectProcess.documents(paper.appendingPathComponent("figures").path)
    do { _ = try ProjectWork.acquire(WorkspaceBinding(roots: [WorkspaceRoot(path: inner.root, directory: true, writable: true)], project: inner)); expect(false, "a nested documents project is refused") } catch {}
    // Other writers of the same files: a plain chat with the folder linked ("Link folder"), or a Git repository inside it.
    let plainChat = WorkspaceBinding(roots: [WorkspaceRoot(path: project.root + "/figures", directory: true, writable: true)], level: .execute)
    do { _ = try ProjectWork.acquire(plainChat); expect(false, "a plain chat cannot write inside a documents project being worked on") } catch { expect(ProjectWork.isBusy(error.localizedDescription), "told as busy") }
    let nested = paper.appendingPathComponent("analysis")
    try! FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    _ = try! ProjectProcess.git(["init", "-b", "main"], root: nested.path)
    do { _ = try ProjectWork.acquire(WorkspaceBinding(roots: [WorkspaceRoot(path: nested.path, directory: true, writable: true)], level: .execute)); expect(false, "a Git repository inside the documents folder is refused") } catch {}
    ProjectWork.release(lease)
    expect(!ProjectWork.isHeld(project.root), "released after the answer")
    try! FileManager.default.removeItem(at: nested)
    // The other way round: while a plain chat writes inside, the documents project waits; plain chats still share a folder.
    let plainLease = try! ProjectWork.acquire(plainChat), plainLease2 = try! ProjectWork.acquire(plainChat)
    expect(ProjectWork.isHeld(project.root), "a plain chat writing inside counts as busy for the TODO board")
    do { _ = try ProjectWork.acquire(binding); expect(false, "a documents project waits for a plain chat writing inside it") } catch {}
    ProjectWork.release(plainLease); ProjectWork.release(plainLease2)
    expect(!ProjectWork.isHeld(project.root), "plain chat locks are released")
    // Another app instance writing below the folder (it holds the shared lock file of every folder above it).
    func lockFile(_ path: String) -> String {
        URL(fileURLWithPath: AccountStore.supportDir).appendingPathComponent("project-locks/" + SHA256.hash(data: Data(path.utf8)).map { String(format: "%02x", $0) }.joined()).path
    }
    let other = open(lockFile(project.root), O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
    expect(other >= 0 && flock(other, LOCK_SH | LOCK_NB) == 0, "fixture holds another instance's lock")
    do { _ = try ProjectWork.acquire(binding); expect(false, "a writer below in another app instance is seen") } catch {}
    close(other)
    let free = try! ProjectWork.acquire(binding)
    expect(free.first == project.root, "free again once the other instance is done")
    let parent = open(lockFile(base.resolvingSymlinksInPath().path), O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
    expect(flock(parent, LOCK_EX | LOCK_NB) != 0, "another instance cannot take a folder above it alone")
    close(parent)
    ProjectWork.release(free)

    // No Git tools; project_run stays. The checkpoint says there is no Git.
    let run = ProjectRun(room: UUID(), binding: project, token: DebateCancellation())
    ProjectWork.register(run); run.nextAttempt()
    let context = ToolContext(room: run.room, roots: binding.roots, projectRun: run.id, projectGeneration: run.generation)
    expect(GitLink.shared.tools(context: context).compactMap { $0["name"] as? String } == ["project_run"], "a documents project offers project_run only")
    expect(GitLink.shared.call("git_status", [:], context: context)["isError"] as? Bool == true && GitLink.shared.call("git_commit", ["message": "m", "paths": ["main.tex"]], context: context)["isError"] as? Bool == true,
           "git tools are refused in a documents project")
    expect(run.checkpoint("x").contains("No Git") && !run.checkpoint("x").contains("HEAD:"), "the checkpoint has no Git state")
    ProjectWork.finish(run)

    // Work in a chat: Claude edits, ChatGPT reviews against the backup copy, the instruction is the documents one, Undo works.
    let claude = Account(id: "docs-claude", provider: .claude, name: "C"), codex = Account(id: "docs-codex", provider: .codex, name: "G")
    let model = AppModel(); model.accounts = [claude, codex]
    let chat = Discussion(model: model)
    chat.configure { $0.mode = 0; $0.leadID = claude.id }
    chat.toggleMember(claude.id); chat.toggleMember(codex.id)
    chat.change(chat.currentID) { $0.workspace = binding }
    chat.routeJudge = { _ in (.work, "Judge") }
    var prompts: [String] = [], reviews: [String] = [], reviewRoots: [[WorkspaceRoot]] = []
    chat.workspaceAnswer = { account, prompt, view, _, _ in
        if account.id == codex.id { reviews.append(prompt); reviewRoots.append(view.roots); return .success("No issues") }
        prompts.append(prompt)
        try! "\\section{Results}\nThe phase velocity is 3.2 km/s.\n".write(to: paper.appendingPathComponent("main.tex"), atomically: true, encoding: .utf8)
        try! "new figure".write(to: paper.appendingPathComponent("figures/fig1.svg"), atomically: true, encoding: .utf8)
        return .success("Edited the Results paragraph.")
    }
    chat.draft = "Results 문단 다듬어 줘"; chat.send()
    let deadline = Date().addingTimeInterval(30)
    while Date() < deadline && (chat.anyRunning || chat.current.turns.last?.final == nil) { RunLoop.main.run(until: Date().addingTimeInterval(0.03)) }
    let prompt = prompts.first ?? ""
    expect(prompt.contains("[Documents project]") && prompt.contains("Never invent references") && prompt.contains("linked documents project (no Git)")
           && !prompt.contains("Start with git_status") && !prompt.contains("git_push"), "the documents instruction replaces the Git one")
    let review = reviews.first ?? ""
    expect(review.hasPrefix("[REVIEW]") && review.contains("documents project") && review.contains("modified: main.tex") && review.contains("added: figures/fig1.svg")
           && review.contains("+The phase velocity is 3.2 km/s.") && review.contains("-The velocity is 3.2 km/s.") && !review.contains("talk.pptx"),
           "the review lists this answer's changes with a text diff against the backup")
    let turn = chat.current.turns.last
    expect(reviewRoots.first?.contains { $0.path.contains("workspace-backups") } == true, "the reviewer may read the backup copy")
    expect(turn?.workspaceChanges?.map(\.path).sorted() == [paper.appendingPathComponent("figures/fig1.svg").resolvingSymlinksInPath().path, paper.appendingPathComponent("main.tex").resolvingSymlinksInPath().path].sorted()
           && turn?.backupPath != nil && turn?.projectCommitted == false, "the changes are listed with a backup")
    if let turn { chat.undoWorkspace(turn) }
    let until = Date().addingTimeInterval(10)
    while Date() < until && chat.current.turns.last?.undone != true { RunLoop.main.run(until: Date().addingTimeInterval(0.03)) }
    expect((try? String(contentsOf: paper.appendingPathComponent("main.tex"), encoding: .utf8)) == "\\section{Results}\nThe velocity is 3.2 km/s.\n"
           && !FileManager.default.fileExists(atPath: paper.appendingPathComponent("figures/fig1.svg").path), "Undo puts the folder back")

    // TODO text for documents: no commit/push, no git status.
    var item = TodoItem(listID: UUID(), title: "Fig. 2 다시 그리기"); item.interrupted = true
    expect(!TodoScheduler.instruction(item, documents: true).contains("commit and push") && TodoScheduler.instruction(item).contains("commit and push")
           && !TodoScheduler.question(item, documents: true).contains("git status"), "a documents TODO is not told to commit or check git status")

    // create_project kind documents: a folder name with spaces, no Git.
    let savedHome = ProjectCreator.home
    ProjectCreator.home = AccountStore.home
    defer { ProjectCreator.home = savedHome }
    let folder = try! ProjectCreator.documentsFolder(name: "Poster 2026", location: base.path)
    let made = try! ProjectCreator.createDocuments(folder)
    expect(made.isDocuments && !FileManager.default.fileExists(atPath: folder + "/.git") && (try? ProjectCreator.documentsFolder(name: "../x", location: base.path)) == nil,
           "a new documents project is a plain folder")
    // Folderless projects retain their identity without exposing an internal root.
    let empty = try! ProjectCreator.createFolderless(name: "빈 프로젝트")
    let empty2 = try! ProjectCreator.createFolderless(name: "빈 프로젝트")
    let decoded = try! JSONDecoder().decode(ProjectBinding.self, from: JSONEncoder().encode(empty))
    expect(empty.isFolderless && empty.isDocuments && empty.linkedRoots.isEmpty
           && empty.root != empty2.root && decoded == empty
           && (try? ProjectProcess.current(empty)) == empty,
           "folderless projects are distinct, persist and validate without linked folders")
    let folderlessPrompt = Discussion.composeInstruction(name: "AI", provider: .codex, folders: "", drive: "", fullAccess: false, picture: "", helper: "", face: "", project: Discussion.ProjectPart(root: empty.root, fullAuto: false, rules: "", folderless: true, documents: true))
    expect(folderlessPrompt.contains("[Folderless project]") && !folderlessPrompt.contains(empty.root),
           "folderless instructions do not expose an internal directory as a linked folder")
    let workspace = SidebarProjects.moved(nil, to: empty)
    expect(workspace.roots.isEmpty && workspace.project == empty,
           "moving into a folderless project does not link its internal directory")
    let key = SidebarProjects.key(empty)
    expect(SidebarProjects.pickerName((name: "빈 프로젝트", binding: empty), among: [], board: key) == "빈 프로젝트",
           "the project picker shows the name instead of the internal UUID")
    try! ProjectInfoStore.shared.addFolders([base], to: key)
    expect(ProjectInfoStore.shared.activeFolders(key).count == 1, "folders can be added later")
    try! ProjectInfoStore.shared.removeFolder(base.resolvingSymlinksInPath().path, from: key)
    expect(ProjectInfoStore.shared.activeFolders(key).isEmpty && SidebarProjects.key(decoded) == key,
           "removing the last folder preserves project identity")
    let emptyRoom = chat.addProjectChat(empty, title: "Folderless", open: true)
    expect(chat.current.workspace?.roots.isEmpty == true, "a new folderless chat starts with no linked roots")
    let artifact = Discussion.chatFolder(emptyRoom).appendingPathComponent("result.md")
    prompts = []; reviews = []
    chat.workspaceAnswer = { account, prompt, view, _, _ in
        expect(!view.roots.contains { $0.path == empty.root }, "internal workspace is not an allowed root")
        if account.id == codex.id { reviews.append(prompt); return .success("No issues") }
        prompts.append(prompt)
        try! "Folderless result".write(to: artifact, atomically: true, encoding: .utf8)
        return .success("Saved result.md")
    }
    chat.configure { $0.mode = 0; $0.leadID = claude.id; $0.memberIDs = [claude.id, codex.id] }
    chat.draft = "Save a result in the chat folder"; chat.send()
    let emptyDeadline = Date().addingTimeInterval(30)
    while Date() < emptyDeadline && (chat.anyRunning || chat.current.turns.last?.final == nil) { RunLoop.main.run(until: Date().addingTimeInterval(0.03)) }
    expect(prompts.first?.contains("[Folderless project]") == true && FileManager.default.fileExists(atPath: artifact.path),
           "a folderless project executes and saves artifacts in the chat folder")
    expect(reviews.first?.contains("added: result.md") == true, "folderless artifacts are reviewed against the chat backup")
    if let resultTurn = chat.current.turns.last { chat.undoWorkspace(resultTurn) }
    let undoDeadline = Date().addingTimeInterval(10)
    while Date() < undoDeadline && chat.current.turns.last?.undone != true { RunLoop.main.run(until: Date().addingTimeInterval(0.03)) }
    expect(!FileManager.default.fileExists(atPath: artifact.path), "Undo removes a new folderless artifact")
    print("PASS: documents project (plain folder, not Git, one writer per folder, no git tools, documents instruction, review against the backup, Undo, TODO text, create, empty project)")
}

// Disconnecting a project's work folder: a folderless project with a new key keeps the chats, TODO lists, name,
// shared folders, links, pin and tab; every worktree root leaves the chats; the folder on disk stays.
func testDisconnectProjectFolder() {
    let base = URL(fileURLWithPath: AccountStore.home).appendingPathComponent("disconnect-fixture-" + UUID().uuidString)
    let main = base.appendingPathComponent("repo"), tree = base.appendingPathComponent("repo-wt"), shared = base.appendingPathComponent("refs"), other = base.appendingPathComponent("other")
    for url in [main, tree, shared, other] { try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
    try! "keep".write(to: main.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
    let common = main.path + "/.git"
    let first = ProjectBinding(root: main.path, common: common, remote: "origin", remoteURL: "https://github.com/x/repo.git")
    let second = ProjectBinding(root: tree.path, common: common, remote: "origin", remoteURL: "https://github.com/x/repo.git")
    let key = SidebarProjects.key(first)
    let savedTodos = TodoStore.shared
    let todos = TodoStore(url: URL(fileURLWithPath: AccountStore.home).appendingPathComponent("disconnect-todos-\(UUID().uuidString).json"))
    TodoStore.shared = todos
    defer { TodoStore.shared = savedTodos }
    let item = try! todos.add(title: "later", project: first, projectName: "repo")
    try! ProjectInfoStore.shared.addFolders([shared], to: key)
    try! ProjectInfoStore.shared.addLink(title: "Docs", url: "https://example.com", to: key)
    if !SidebarFold.shared.isPinned(key) { SidebarFold.shared.togglePin(key) }
    BoardTab.save(.todo, for: key)

    let chat = Discussion(model: AppModel())
    let a = chat.addProjectChat(first, title: "A", open: false), b = chat.addProjectChat(second, title: "B", open: false)
    chat.change(a) { $0.workspace?.roots.append(WorkspaceRoot(path: other.path, directory: true)); $0.workspace?.projectRunID = UUID() }
    let loose = chat.addProjectChat(ProjectBinding(root: other.path, common: other.path, remote: "", remoteURL: "", kind: ProjectBinding.documentsKind), title: "Other", open: false)
    expect(Set(chat.projectRoots(key)) == [main.path, tree.path] && chat.disconnectRefusal(key) == nil, "a linked project can be disconnected")

    // Refused while a chat of it answers or a TODO of it runs.
    chat.runningRooms.insert(b)
    expect(chat.disconnectRefusal(key) != nil && (try? chat.disconnectFolder(key, name: "repo")) == nil, "refused while a chat of the project answers")
    chat.runningRooms.remove(b)
    try! todos.change(item.id) { $0.state = .running }
    expect(chat.disconnectRefusal(key) != nil, "refused while a TODO of the project runs")
    try! todos.change(item.id) { $0.state = .ready }

    chat.boardProject = key
    let project = try! chat.disconnectFolder(key, name: "repo", keepReadOnly: false)
    let new = SidebarProjects.key(project)
    let chatA = chat.conversation(a), chatB = chat.conversation(b)
    expect(project.isFolderless && new != key && (try? ProjectProcess.current(project)) == project, "the project becomes a valid folderless one with a new key")
    expect(chatA.workspace?.project == project && chatB.workspace?.project == project
           && chatA.workspace?.roots.map(\.path) == [other.path] && chatB.workspace?.roots.isEmpty == true && chatA.workspace?.projectRunID == nil,
           "every worktree root leaves the chats; other linked folders stay")
    expect(chat.conversation(loose).workspace?.project?.root == other.path, "another project's chat is untouched")
    expect(todos.current.lists.first { $0.id == item.listID }?.project == project, "the TODO list moves to the folderless project")
    let info = ProjectInfoStore.shared.info(new)
    expect(info.name == "repo" && info.folders.map(\.path) == [shared.resolvingSymlinksInPath().path] && info.links.map(\.title) == ["Docs"]
           && ProjectInfoStore.shared.info(key).isEmpty, "name, shared folders and links move to the new key")
    expect(SidebarFold.shared.isPinned(new) && !SidebarFold.shared.isPinned(key) && BoardTab.saved(new) == .todo && chat.boardProject == new,
           "pin, tab and open board follow the project")
    let grouped = SidebarProjects.group(chat.listedConversations, todo: todos.current, pinned: [], names: ProjectInfoStore.shared.names).projects
    expect(grouped.filter { $0.id == new }.count == 1 && !grouped.contains { $0.id == key } && grouped.first { $0.id == new }?.name == "repo",
           "the sidebar shows one folderless project under its old name")
    expect(FileManager.default.fileExists(atPath: main.appendingPathComponent("a.txt").path), "the folder on disk stays")
    expect(chat.disconnectRefusal(new) != nil, "a folderless project has nothing to disconnect")

    // Keeping the old folder as a read-only shared folder (opt-in); refused, with nothing moved, when it would not fit.
    let third = ProjectBinding(root: tree.path, common: tree.path, remote: "", remoteURL: "", kind: ProjectBinding.documentsKind)
    let thirdRoom = chat.addProjectChat(third, title: "C", open: false)
    let many = (0..<ProjectInfoStore.maxFolders).map { base.appendingPathComponent("f\($0)") }
    for url in many { try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
    try! ProjectInfoStore.shared.addFolders(many, to: SidebarProjects.key(third))
    expect((try? chat.disconnectFolder(SidebarProjects.key(third), name: "tree", keepReadOnly: true)) == nil
           && chat.conversation(thirdRoom).workspace?.project == third && ProjectInfoStore.shared.info(SidebarProjects.key(third)).folders.count == ProjectInfoStore.maxFolders,
           "keeping the folder over the shared-folder limit is refused and nothing moves")
    for url in many { try! ProjectInfoStore.shared.removeFolder(url.resolvingSymlinksInPath().path, from: SidebarProjects.key(third)) }
    let kept = try! chat.disconnectFolder(SidebarProjects.key(third), name: "tree", keepReadOnly: true)
    expect(ProjectInfoStore.shared.info(SidebarProjects.key(kept)).folders.map(\.path) == [tree.path], "the old folder can stay as a read-only shared folder")
    SidebarFold.shared.togglePin(new)
    print("PASS: disconnect work folder (folderless with a new key, chats, TODO lists, info, pin and tab kept, worktree roots removed, refusals, keep read only)")
}
