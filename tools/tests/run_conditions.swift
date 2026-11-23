import Foundation
import AIAccounts
@testable import AIRuntime
import AIWorkspace
import AIProjects
import AISpaces
@testable import AIChat

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
    let guarded = saved.keys.filter {
        $0 == "CLAUDE_CODE_FORWARD_SUBAGENT_TEXT" || ["GIT_", "GH_", "GITHUB_", "SSH_", "AI_ILLUMINATI_PROJECT"].contains(where: $0.hasPrefix)
    }
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
    // Meetings, votes and several views ask with hard: true, through the plain hook (debateAnswer) or a folder.
    for account in accounts where account.provider == .claude {
        for binding in [nil, WorkspaceBinding(roots: folder)] {
            var launches: [Answerer.Launch] = []
            Answerer.launchForTests = { launch in launches.append(launch); return .success("captured") }
            _ = chat.requestDebate(account, "Say hi.", 60, DebateCancellation(), hard: true, workspace: binding)
            _ = chat.requestDebate(account, "Say hi.", 60, DebateCancellation(), workspace: binding)
            let levels = launches.map { launch in launch.arguments.firstIndex(of: "--effort").map { launch.arguments[$0 + 1] } ?? "none" }
            expect(levels == ["high", "medium"], "requestDebate hard: high, then medium again (\(binding == nil ? "plain" : "folder")): \(levels)")
        }
    }
    // Project work the way ProjectChat starts it (write and execute, its own backup, a session), Claude and Codex
    // (the only project workers), the chat's full auto off and on. The tool answers at once; nothing else runs.
    // soloBinding carries the chat's switch (it dropped it until 2026-11-23, so "off" still ran full auto).
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
                   && work.contains("env+: AI_ILLUMINATI_PROJECT_PROCESS=\"1\"") && work.contains("env-: GH_TOKEN") == kind.hasSuffix("on")
                   && (provider == "codex" || work.contains("arg: \"$TEST_HOME/run-conditions-project-claude-\(kind.hasSuffix("on"))\"")),
                   "\(provider) \(kind): ProjectChat's run is wrapped, guarded only when on, and gets its project (Codex full access names no folder)")
        }
    }
    for kind in ["plain", "folder", "project-on"] {
        expect(block("codex " + kind).contains("arg: \"mcp_servers.gpt.enabled=false\""), "codex \(kind): AI Face's own server is turned off")
    }
    expect(block("claude project-on").contains("arg: \"bypassPermissions\"") && block("claude project-off").contains("arg: \"--restricted\"")
           && !block("claude project-off").contains("bypassPermissions"), "claude: full access on and off give their own permissions")
    expect(block("codex project-on").contains("sandbox_mode=\\\"danger-full-access\\\"") && block("codex project-off").contains("sandbox_mode=\\\"read-only\\\""),
           "codex: full access on and off give their own sandbox")
    // The chat's full auto switch reaches project work: off = the limited tool, no AutoGuard; on = as before.
    let chatOff = block("claude project-chat-off"), chatOn = block("claude project-chat-on")
    expect(chatOff.contains("arg: \"--restricted\"") && !chatOff.contains("bypassPermissions") && !chatOff.contains("auto-guard")
           && chatOn.contains("arg: \"bypassPermissions\"") && chatOn.contains("auto-guard"), "claude: the project chat's full auto off and on give their own permissions")
    let codexChatOff = block("codex project-chat-off"), codexChatOn = block("codex project-chat-on")
    expect(!codexChatOff.contains("danger-full-access") && codexChatOff.contains("sandbox_mode=\\\"workspace-write\\\"") && !codexChatOff.contains("auto-guard")
           && codexChatOn.contains("sandbox_mode=\\\"danger-full-access\\\"") && codexChatOn.contains("auto-guard"), "codex: the project chat's full auto off and on give their own sandbox")
    expect(blocks.filter { $0.hasPrefix("ollama ") }.allSatisfy { !$0.contains("exec:") }, "the local model starts no command line tool")
    // Thinking on Auto: project work and its runs think hard, every other call medium.
    for (provider, high, medium) in [("claude", "arg: \"--effort\"\narg: \"high\"", "arg: \"--effort\"\narg: \"medium\""),
                                     ("codex", "arg: \"model_reasoning_effort=\\\"high\\\"\"", "arg: \"model_reasoning_effort=\\\"medium\\\"\""),
                                     ("gemini", "arg: \"--effort\"\narg: \"high\"", "arg: \"--effort\"\narg: \"medium\"")] {
        for (kind, work) in [("plain", false), ("folder", false), ("folder-full", false), ("project-off", true), ("project-on", true),
                             ("project-chat-off", true), ("project-chat-on", true)] where !block(provider + " " + kind).isEmpty {
            let text = block(provider + " " + kind)
            expect(text.contains(work ? high : medium) && !text.contains(work ? medium : high),
                   "\(provider) \(kind): Auto thinks \(work ? "high" : "medium")")
        }
    }
    // Then everything else, byte for byte.
    let golden = (try? String(contentsOfFile: "tools/tests/run_conditions.golden", encoding: .utf8)) ?? "(missing)"
    if captured != golden {
        let mine = captured.components(separatedBy: "\n"), theirs = golden.components(separatedBy: "\n")
        let first = (0..<min(mine.count, theirs.count)).first { mine[$0] != theirs[$0] } ?? min(mine.count, theirs.count)
        expect(false, "launches differ from run_conditions.golden at line \(first + 1): got \(mine.indices.contains(first) ? mine[first] : "(end)") / golden \(theirs.indices.contains(first) ? theirs[first] : "(end)")")
    }
    print("PASS: launches per provider and folder kind match the golden file (arguments, environment, process group); each guard checked alone")
    testCapabilityLaunches()
}

private func testCapabilityLaunches() {
    let root = URL(fileURLWithPath: AccountStore.home).appendingPathComponent("capability-run-root")
    try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let room = UUID(), runID = UUID()
    let roots = [WorkspaceRoot(path: root.path, directory: true, writable: true)]
    let binding = WorkspaceBinding(roots: roots, level: .execute, projectRunID: runID)
    let backup = try! WorkspaceBackup.begin(binding, room: room, runID: runID)
    let invocation = WorkspaceInvocation(binding: binding, room: room, readOnly: false, backupPath: backup.directory)
    func value(_ args: [String], _ option: String) -> String {
        args.firstIndex(of: option).map { args[$0 + 1] } ?? ""
    }
    func capture(_ account: Account, _ workspace: WorkspaceInvocation? = nil, web: Bool = true,
                 session: NativeSessionCall? = nil, screen: Bool = false,
                 inspect: @escaping (Answerer.Launch) -> Void = { _ in }) -> [String] {
        var args: [String] = []
        Answerer.launchForTests = { started in
            args = started.arguments
            inspect(started)
            return .success("captured")
        }
        defer { Answerer.launchForTests = nil }
        let result = Answerer.ask(account, prompt: "Say hi.", web: web, session: session, run: .app(account, workspace, screen: screen))
        if case .failure(let error) = result { expect(false, "capability launch failed: \(error)") }
        return args
    }
    for provider in [Account.Provider.claude, .codex] {
        let account = Account(id: "rc-capability-\(provider)-\(UUID())", provider: provider, name: "Capabilities", dir: root.path)
        let control = Account(id: "rc-control-\(provider)-\(UUID())", provider: provider, name: "Control", dir: root.path)
        let screenNames: Set<String> = ["mac_windows", "mac_screenshot"]
        func screenManifest(_ args: [String]) -> [String: Any] {
            let paths: [String]
            if provider == .claude {
                let config = (try? JSONSerialization.jsonObject(with: Data(value(args, "--mcp-config").utf8))) as? [String: Any]
                let servers = config?["mcpServers"] as? [String: [String: Any]]
                paths = servers?["illuminati"]?["args"] as? [String] ?? []
            } else {
                let prefix = "mcp_servers.illuminati.args="
                let list = args.first { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) } ?? "[]"
                paths = (try? JSONDecoder().decode([String].self, from: Data(list.utf8))) ?? []
            }
            guard let path = paths.last, let bytes = FileManager.default.contents(atPath: path) else { return [:] }
            return (try? JSONSerialization.jsonObject(with: bytes) as? [String: Any]) ?? [:]
        }
        func listed(_ manifest: [String: Any]) -> Set<String> {
            guard let session = manifest["toolSession"] as? String else { return [] }
            let result = ToolHub.shared.handle(["session": session, "op": "tools"])
            let tools = result["tools"] as? [[String: Any]] ?? []
            return Set(tools.compactMap { $0["name"] as? String })
        }
        for rule in [CapabilityRule.off, .ask, .on] {
            AICapabilities.set(rule, for: account, .screen)
            var plain: [String: Any] = [:]
            _ = capture(account, web: false, screen: true) { launch in
                plain = screenManifest(launch.arguments)
                expect(listed(plain) == (rule == .on ? screenNames : []), "\(provider): plain tools with screen \(rule)")
                guard rule == .on else {
                    expect(plain.isEmpty, "\(provider): no plain bridge with screen \(rule)")
                    return
                }
                expect(plain["appToolsOnly"] as? Bool == true, "plain screen bridge has no file tools")
                if provider == .claude {
                    expect(Set(value(launch.arguments, "--allowedTools").split(separator: ",")) ==
                           ["mcp__illuminati__mac_screenshot", "mcp__illuminati__mac_windows"]
                           && value(launch.arguments, "--tools").isEmpty && launch.arguments.contains("--strict-mcp-config")
                           && launch.arguments.contains("--no-session-persistence")
                           && launch.environment["CLAUDE_CODE_DISABLE_AUTO_MEMORY"] == "1",
                           "Claude plain launch allows only screen tools and disables auto memory")
                } else {
                    expect(value(launch.arguments, "--sandbox") == "read-only" && launch.arguments.contains("--ephemeral")
                           && launch.arguments.contains("features.shell_tool=false"),
                           "Codex plain screen launch stays read-only and ephemeral with no shell")
                }
            }
            expect(listed(plain).isEmpty, "plain screen access expires when the answer returns")
            for workspace in [WorkspaceInvocation(binding: WorkspaceBinding(roots: roots), room: room), invocation] {
                _ = capture(account, workspace, screen: true) { launch in
                    let manifest = screenManifest(launch.arguments)
                    expect(listed(manifest).intersection(screenNames) == (rule == .on ? screenNames : []),
                           "\(provider): workspace tools with screen \(rule)")
                    expect(manifest["appToolsOnly"] == nil, "workspace bridge retains its linked file tools")
                }
            }
        }
        expect(RunConditions.app(account).screenTools == nil && RunConditions.app(account, invocation).screenTools == nil,
               "\(provider): background calls have no screen access even when the account enables it")
        let chat = Discussion(model: AppModel())
        let own = WorkspaceRoot(path: Discussion.chatFolder(chat.currentID).path, directory: true, writable: true)
        let spaces = WorkspaceRoot(path: SpaceStore.root.path, directory: true, writable: true)
        let builtIn = WorkspaceBinding(roots: [own, spaces], face: true)
        var keptBuiltIn = false
        Answerer.launchForTests = { launch in
            let manifest = screenManifest(launch.arguments)
            let writable = (manifest["roots"] as? [[String: Any]] ?? [])
                .filter { $0["writable"] as? Bool == true }.compactMap { $0["path"] as? String }
            keptBuiltIn = Set(writable) == [own.path, spaces.path] && screenNames.isSubset(of: listed(manifest))
            return .success("captured")
        }
        _ = chat.requestDebate(account, "Say hi.", 60, DebateCancellation(), workspace: builtIn, screen: true)
        expect(keptBuiltIn, "\(provider): screen viewing keeps the chat and Spaces folders writable")

        let image = root.appendingPathComponent("screen-attachment.png")
        try! Data([0x89, 0x50, 0x4e, 0x47]).write(to: image)
        chat.activeImages = [image]
        chat.pictureAnswer = { _, _, _, _, _, _ in
            expect(false, "the attachment answer hook must not bypass the screen bridge")
            return .success("unexpected")
        }
        var attached = false
        Answerer.launchForTests = { launch in
            let args = launch.arguments
            let hasImage = provider == .claude ? value(args, "--input-format") == "stream-json" : value(args, "--image") == image.path
            attached = hasImage && listed(screenManifest(args)) == screenNames
            return .success("captured")
        }
        _ = chat.requestDebate(account, "Look at the attachment.", 60, DebateCancellation(), screen: true)
        Answerer.launchForTests = nil
        expect(attached, "\(provider): an attached picture can be sent with the screen-only bridge")
        AICapabilities.set(.off, for: account, .screen)
        for terminal in [true, false] {
            for web in [true, false] {
                AICapabilities.set(terminal ? .on : .off, for: account, .terminal)
                AICapabilities.set(web ? .on : .off, for: account, .web)
                let label = "\(provider), terminal \(terminal), web \(web)"
                let args = capture(account, invocation) { launch in
                    expect(launch.processGroup && launch.environment["AI_ILLUMINATI_PROJECT_PROCESS"] == "1",
                           "\(label): project process stays cancellable")
                    expect((launch.environment["GH_CONFIG_DIR"] == AccountStore.supportDir + "/auto-guard/gh-empty") == terminal,
                           "\(label): AutoGuard goes with full native access")
                }
                if provider == .claude {
                    let tools = value(args, "--tools").split(separator: ",")
                    let allowed = value(args, "--allowedTools").split(separator: ",")
                    let denied = value(args, "--disallowedTools").split(separator: ",")
                    expect(args.contains("bypassPermissions") == terminal && args.contains("--restricted") == !terminal,
                           "\(label): account selects Claude's access mode")
                    expect((tools.contains("default") || tools.contains("Bash")) == terminal && !allowed.contains("Bash"),
                           "\(label): Bash is absent even from the limited execute run")
                    for name: Substring in ["WebSearch", "WebFetch"] {
                        expect(terminal ? denied.contains(name) == !web : tools.contains(name) == web && allowed.contains(name) == web,
                               "\(label): Claude web tool \(name) follows the account")
                    }
                } else {
                    let sandbox = terminal ? "danger-full-access" : "workspace-write"
                    expect(args.contains("sandbox_mode=\"\(sandbox)\"") && args.contains("features.shell_tool=\(terminal)"),
                           "\(label): Codex sandbox and shell follow the account")
                    expect(args.contains("web_search=\"\(web ? "live" : "disabled")\"") && args.contains("--search") == web,
                           "\(label): Codex web setting and global search flag agree")
                }
            }
        }
        let plain = capture(account)
        let session = NativeSessionCall(id: UUID().uuidString, resume: true, directory: root)
        let resumed = capture(account, session: session)
        if provider == .claude {
            expect([plain, resumed].allSatisfy { value($0, "--tools").isEmpty && !$0.contains("WebSearch,WebFetch") },
                   "Claude: web off also reaches plain and resumed calls")
        } else {
            expect([plain, resumed].allSatisfy { $0.contains("features.shell_tool=false") && $0.contains("web_search=\"disabled\"") && !$0.contains("--search") },
                   "Codex: terminal and web off also reach plain and resumed calls")
        }

        AICapabilities.set(.ask, for: account, .terminal)
        AICapabilities.set(.ask, for: account, .web)
        let asked = capture(account, invocation)
        let enabled = capture(control, invocation)
        if provider == .claude {
            expect([asked, enabled].allSatisfy { $0.contains("bypassPermissions") && !value($0, "--disallowedTools").contains("WebSearch") },
                   "Claude: Ask acts like On and a second account keeps the default")
        } else {
            expect([asked, enabled].allSatisfy { $0.contains("sandbox_mode=\"danger-full-access\"") && $0.contains("web_search=\"live\"") },
                   "Codex: Ask acts like On and a second account keeps the default")
        }
        let view = capture(account, WorkspaceInvocation(binding: WorkspaceBinding(roots: roots), room: room))
        expect(provider == .claude ? !value(view, "--tools").contains("Bash") && !view.contains("bypassPermissions")
               : view.contains("features.shell_tool=false") && !view.contains("sandbox_mode=\"danger-full-access\""),
               "\(provider): account setting adds no terminal to a plain view")
    }

    let gemini = Account(id: "rc-gemini-capability-\(UUID())", provider: .gemini, name: "Gemini")
    AICapabilities.set(.off, for: gemini, .web)
    AICapabilities.set(.off, for: gemini, .terminal)
    expect(RunConditions.app(gemini).beforeStart == nil, "Gemini: web off skips writing the global allow rule")
    let settingsURL = URL(fileURLWithPath: AccountStore.home + "/.gemini/antigravity-cli/settings.json")
    let existing = try? Data(contentsOf: settingsURL)
    let settings = Data(#"{"toolPermission":"always-proceed","permissions":{"allow":["command(ls)"],"deny":["write_file(/example)"]}}"#.utf8)
    try! FileManager.default.createDirectory(at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try! settings.write(to: settingsURL, options: .atomic)
    defer {
        if let existing { try? existing.write(to: settingsURL, options: .atomic) }
        else { try? FileManager.default.removeItem(at: settingsURL) }
    }
    let args = capture(gemini, invocation) { launch in
        let file = launch.directory.appendingPathComponent(".agents/hooks.json")
        let data = try! Data(contentsOf: file)
        let hooks = try! JSONSerialization.jsonObject(with: data) as! [String: [String: [[String: Any]]]]
        let preTool = hooks["illuminati-capabilities"]?["PreToolUse"]?.first
        let matcher = preTool?["matcher"] as? String ?? ""
        let handlers = preTool?["hooks"] as? [[String: String]]
        expect(value(launch.arguments, "--add-dir") == launch.directory.path && handlers?.first?["type"] == "command",
               "Gemini: the declared workspace root contains the command hook")
        expect(["search_web", "read_url_content", "run_command"].allSatisfy { matcher.split(separator: "|").contains(Substring($0)) },
               "Gemini: the per-run hook denies search, URL reads and commands")
    }
    let override = Data(value(args, "--settings").utf8)
    let object = (try? JSONSerialization.jsonObject(with: override)) as? [String: [String: [String]]]
    let deny = object?["permissions"]?["deny"] ?? []
    expect(["command(*)", "read_url(*)", "write_file(/example)"].allSatisfy { deny.contains($0) }
           && object?["permissions"]?["allow"] == ["command(ls)"] && (try? Data(contentsOf: settingsURL)) == settings,
           "Gemini: an account with pre-approved commands can launch with session-only deny rules")
    _ = capture(gemini) { launch in
        let dirs = zip(launch.arguments, launch.arguments.dropFirst()).compactMap { $0 == "--add-dir" ? $1 : nil }
        expect(dirs == [launch.directory.path, Answerer.chatDir],
               "Gemini: plain chat keeps its previous workspace next to the hook root")
    }
    expect(value(args, "-p").contains("웹 검색과 웹 페이지 읽기는 이 실행에서 꺼져 있어요.")
           && value(args, "-p").contains("터미널 명령(run_command)은 이 실행에서 막혀 있고"),
           "Gemini: tool guidance reflects both account switches")
}
