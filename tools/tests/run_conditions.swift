import Foundation
import AIAccounts
@testable import AIRuntime

// What each AI's command line tool is started with (program, arguments, environment, folder, process group),
// captured through the app's own way in (Discussion.requestDebate) and compared with run_conditions.golden.
// Nothing is started: Answerer.launchForTests takes the launch. Kinds per provider:
//   plain (no folder), folder (linked folder, view), folder-full (fullAccess on a plain chat: AutoGuard alone),
//   project-off / project-on (project work, full auto off / on: the 8 combinations with the local model).
// Gemini has no "plain" here: without a folder it adds web rules to agy's settings in the real home.
// Write a new golden file only on purpose: AI_ILLUMINATI_WRITE_GOLDEN=<path> (then compare the diff by hand).
func runConditionsCapture() -> String {
    let home = AccountStore.home
    let resources = ProcessInfo.processInfo.environment["AI_ILLUMINATI_TEST_RESOURCES"] ?? "/no-resources"
    let root = URL(fileURLWithPath: home).appendingPathComponent("run-conditions-root")
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    // A Codex account folder whose config has AI Face's server: the app turns it off for each run.
    let codexDir = URL(fileURLWithPath: home).appendingPathComponent("run-conditions-codex")
    try? FileManager.default.createDirectory(at: codexDir, withIntermediateDirectories: true)
    try? "[mcp_servers.gpt]\ncommand = \"python3\"\nargs = [\"/x/ai_face_mcp.py\"]\n".write(to: codexDir.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)
    let accounts = [Account(id: "rc-claude", provider: .claude, name: "Claude", dir: home + "/run-conditions-claude"),
                    Account(id: "rc-codex", provider: .codex, name: "ChatGPT", dir: codexDir.path),
                    Account(id: "rc-gemini", provider: .gemini, name: "Gemini"),
                    Account(id: "rc-local", provider: .ollama, name: "Gemma 4 E4B", model: "gemma4:e4b")]
    let model = AppModel()
    model.accounts = accounts
    model.sharedFolders = []
    let chat = Discussion(model: model)
    let wasLocal = UserDefaults.app.object(forKey: "localEnabled")
    UserDefaults.app.set(false, forKey: "localEnabled")   // the local model never starts Ollama here
    // The same starting environment wherever the test runs (also inside a project run, which already has the guards):
    // no Git, GitHub or SSH settings, a plain PATH, and two credentials the guard must take away.
    let saved = ProcessInfo.processInfo.environment
    let guarded = saved.keys.filter { ["GIT_", "GH_", "GITHUB_", "SSH_", "AI_ILLUMINATI_PROJECT"].contains(where: $0.hasPrefix) }
    for key in guarded { unsetenv(key) }
    setenv("PATH", "/usr/bin:/bin", 1); setenv("GH_TOKEN", "test-token", 1); setenv("SSH_AUTH_SOCK", "/tmp/test-agent", 1)
    defer {
        UserDefaults.app.set(wasLocal, forKey: "localEnabled"); Answerer.launchForTests = nil
        for key in ["PATH", "GH_TOKEN", "SSH_AUTH_SOCK"] + guarded { if let value = saved[key] { setenv(key, value, 1) } else { unsetenv(key) } }
    }

    let folder = [WorkspaceRoot(path: root.path, directory: true)]
    var full = WorkspaceBinding(roots: folder); full.fullAccess = true
    var off = WorkspaceBinding(roots: folder, level: .execute, projectRunID: UUID(), projectGeneration: 1); off.fullAuto = false
    let on = WorkspaceBinding(roots: folder, level: .execute, projectRunID: UUID(), projectGeneration: 1)
    let kinds: [(String, WorkspaceBinding?)] = [("plain", nil), ("folder", WorkspaceBinding(roots: folder)), ("folder-full", full),
                                                ("project-off", off), ("project-on", on)]
    expect(!off.fullAccessActive && on.fullAccessActive && full.fullAccessActive && full.projectRunID == nil, "the capture covers full access on and off")

    // Paths also as JSON writes them inside a JSON argument ("\/tmp\/…").
    func clean(_ text: String, cli: String) -> String {
        var text = text
        for (path, name) in [(cli, "<cli>"), (resources, "$RESOURCES"), (home, "$TEST_HOME")] where !path.isEmpty {
            text = text.replacingOccurrences(of: path, with: name).replacingOccurrences(of: path.replacingOccurrences(of: "/", with: "\\/"), with: name)
        }
        return text.replacingOccurrences(of: "[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}", with: "<uuid>", options: .regularExpression)
    }
    func line(_ value: String) -> String {
        String(data: try! JSONSerialization.data(withJSONObject: [value], options: [.withoutEscapingSlashes]), encoding: .utf8)!.dropFirst().dropLast().description
    }
    // A JSON argument (Claude's --mcp-config) with its keys sorted: the app's dictionary order changes every run.
    func sorted(_ argument: String) -> String {
        guard argument.hasPrefix("{"), let object = try? JSONSerialization.jsonObject(with: Data(argument.utf8)),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return argument }
        return String(data: data, encoding: .utf8)!
    }
    var out = ""
    func describe(_ launch: Answerer.Launch, _ account: Account) -> String {
        // The environment as a change of the account's own (that one is AIAccounts' promise).
        let base = account.environment
        var out = "exec: " + clean(launch.executable, cli: launch.cli) + "\n"
        for argument in launch.arguments { out += "arg: " + line(clean(sorted(argument), cli: launch.cli)) + "\n" }
        out += "dir: " + clean(launch.directory.path, cli: launch.cli) + "\n"
        out += "group: \(launch.processGroup)\n"
        for key in Set(base.keys).union(launch.environment.keys).sorted() where base[key] != launch.environment[key] {
            guard var value = launch.environment[key] else { out += "env-: \(key)\n"; continue }
            if let old = base[key], !old.isEmpty { value = value.replacingOccurrences(of: old, with: "${\(key)}") }
            out += "env+: \(key)=" + line(clean(value, cli: launch.cli)) + "\n"
        }
        return out
    }
    for account in accounts {
        for (kind, binding) in kinds where !(account.provider == .gemini && binding == nil) {
            var launches: [Answerer.Launch] = []
            Answerer.launchForTests = { launch in launches.append(launch); return .success("captured") }
            let result = chat.requestDebate(account, "Say hi.", 60, DebateCancellation(), workspace: binding)
            out += "== \(account.provider.rawValue) \(kind)\n"
            switch result {
            case .success(let text): out += "result: \(text)\n"
            case .failure: out += "result: failure\n"   // its text follows the app language
            }
            for launch in launches { out += describe(launch, account) }
        }
    }
    // Project work the way ProjectChat starts it (write and execute, its own backup, a session), Claude and Codex
    // (the only project workers), the chat's full auto off and on. The tool answers at once; nothing else runs.
    // Found 2026-11-11, before R0 too: soloBinding rebuilds the binding without `fullAuto`, so "off" still runs full
    // auto here. The golden file keeps what the app does; changing it is a separate decision.
    for account in accounts where account.provider == .claude || account.provider == .codex {
        for fullAuto in [false, true] {
            let root = URL(fileURLWithPath: home).appendingPathComponent("run-conditions-project-\(account.provider.rawValue)-\(fullAuto)")
            try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            func git(_ args: [String]) { _ = try! ProjectProcess.git(args, root: root.path) }
            git(["init", "-b", "main"]); git(["config", "user.name", "Fixture"]); git(["config", "user.email", "fixture@example.invalid"])
            git(["remote", "add", "origin", root.path + "/unused-origin"])
            try! "Baseline".write(to: root.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
            git(["add", "README.md"]); git(["commit", "-m", "Initial"])
            let projectModel = AppModel()
            projectModel.accounts = [account]
            let work = Discussion(model: projectModel)
            work.configure { $0.mode = 0; $0.soloAccountID = account.id }
            var binding = WorkspaceBinding(roots: [WorkspaceRoot(path: root.path, directory: true)], project: try! ProjectProcess.inspect(root.path))
            binding.fullAuto = fullAuto
            work.change(work.currentID) { $0.workspace = binding }
            var launches: [Answerer.Launch] = []
            Answerer.launchForTests = { launch in launches.append(launch); return .success("captured") }
            work.draft = "Say hi."; work.send()
            let deadline = Date().addingTimeInterval(30)
            while Date() < deadline && (work.anyRunning || work.current.turns.last?.projectCommitted == nil) { RunLoop.main.run(until: Date().addingTimeInterval(0.03)) }
            out += "== \(account.provider.rawValue) project-chat-\(fullAuto ? "on" : "off")\nresult: \(work.current.turns.last?.final ?? "none")\n"
            for launch in launches { out += describe(launch, account) }
        }
    }
    return out
}

func testRunConditions() {
    let captured = runConditionsCapture()
    if let path = ProcessInfo.processInfo.environment["AI_ILLUMINATI_WRITE_GOLDEN"] {
        try! captured.write(toFile: path, atomically: true, encoding: .utf8)
        print("wrote \(path)")
    }
    // agy's web rule is the app's own step (it writes agy's real settings, so it is only looked at, never run here):
    // plain Gemini chat gets it, linked folders and the other tools do not.
    let plainGemini = Account(id: "rc-gemini", provider: .gemini, name: "Gemini")
    expect(RunConditions.app(plainGemini).beforeStart != nil, "plain Gemini chat adds agy's web rule before it starts")
    expect(RunConditions.app(Account(id: "rc-claude", provider: .claude, name: "Claude")).beforeStart == nil
           && RunConditions.app(Account(id: "rc-codex", provider: .codex, name: "Codex")).beforeStart == nil, "only Gemini gets the web rule")
    // Each guard on its own, so a lost layer cannot hide behind another one.
    let blocks = captured.components(separatedBy: "== ").filter { !$0.isEmpty }
    func block(_ name: String) -> String { blocks.first { $0.hasPrefix(name + "\n") } ?? "" }
    for provider in ["claude", "codex", "gemini"] {
        let projectOn = block(provider + " project-on"), projectOff = block(provider + " project-off")
        let folderFull = block(provider + " folder-full"), folder = block(provider + " folder")
        expect(projectOn.contains("env+: PATH=\"$TEST_HOME/Library/Application Support/AI Illuminati/auto-guard/bin:${PATH}\"")
               && [projectOn, folderFull].allSatisfy { $0.contains("env+: GH_CONFIG_DIR=") && $0.contains("env-: GH_TOKEN") && $0.contains("env-: SSH_AUTH_SOCK") },
               "\(provider): full access runs with AutoGuard's environment (no GitHub token, no SSH agent)")
        expect(!projectOff.contains("auto-guard") && !folder.contains("auto-guard"), "\(provider): without full access no AutoGuard environment")
        for project in [projectOn, projectOff] {
            expect(project.contains("exec: /usr/bin/python3\narg: \"$RESOURCES/project_process.py\"\narg: \"<cli>\"") && project.contains("group: true")
                   && project.contains("env+: AI_ILLUMINATI_PROJECT_PROCESS=\"1\""), "\(provider): project work runs in its own process group")
        }
        for plain in [folder, folderFull] {
            expect(plain.contains("exec: <cli>") && plain.contains("group: false") && !plain.contains("AI_ILLUMINATI_PROJECT_PROCESS"), "\(provider): a chat folder runs the tool itself")
        }
    }
    for provider in ["claude", "codex"] {
        for kind in ["project-chat-off", "project-chat-on"] {
            let work = block(provider + " " + kind)
            expect(work.contains("exec: /usr/bin/python3\narg: \"$RESOURCES/project_process.py\"\narg: \"<cli>\"") && work.contains("group: true")
                   && work.contains("env+: AI_ILLUMINATI_PROJECT_PROCESS=\"1\"") && work.contains("env-: GH_TOKEN")
                   && (provider == "codex" || work.contains("arg: \"$TEST_HOME/run-conditions-project-claude-\(kind.hasSuffix("on"))\"")),
                   "\(provider) \(kind): ProjectChat's run is wrapped, guarded and gets its project (Codex full access names no folder)")
        }
    }
    for kind in ["plain", "folder", "project-on"] {
        expect(block("codex " + kind).contains("arg: \"mcp_servers.gpt.enabled=false\""), "codex \(kind): AI Face's own server is turned off")
    }
    expect(block("claude project-on").contains("arg: \"bypassPermissions\"") && block("claude project-off").contains("arg: \"--restricted\"")
           && !block("claude project-off").contains("bypassPermissions"), "claude: full access on and off give their own permissions")
    expect(block("codex project-on").contains("sandbox_mode=\\\"danger-full-access\\\"") && block("codex project-off").contains("sandbox_mode=\\\"read-only\\\""),
           "codex: full access on and off give their own sandbox")
    expect(blocks.filter { $0.hasPrefix("ollama ") }.allSatisfy { !$0.contains("exec:") }, "the local model starts no command line tool")
    // Then everything else, byte for byte.
    let golden = (try? String(contentsOfFile: "tools/tests/run_conditions.golden", encoding: .utf8)) ?? "(missing)"
    if captured != golden {
        let mine = captured.components(separatedBy: "\n"), theirs = golden.components(separatedBy: "\n")
        let first = (0..<min(mine.count, theirs.count)).first { mine[$0] != theirs[$0] } ?? min(mine.count, theirs.count)
        expect(false, "launches differ from run_conditions.golden at line \(first + 1): got \(mine.indices.contains(first) ? mine[first] : "(end)") / golden \(theirs.indices.contains(first) ? theirs[first] : "(end)")")
    }
    print("PASS: launches per provider and folder kind match the golden file (arguments, environment, process group); each guard checked alone")
}
