import Foundation
import AIAccounts
import AIWorkspace

// The promises of Workspace (AIWorkspace), checked from outside with only its public API: the folder rules each CLI
// gets (Claude, Codex) per level, full access with AutoGuard's denied list (every entry), the bridge's manifest and
// when it asks for the app's tool gateway, AutoGuard's environment and shims, the backup before writes and its Undo,
// the saved shapes (a chat's `workspace`, a backup's complete.json) and disk sizes. Run with AI_ILLUMINATI_TEST_HOME
// set to an empty folder (run_mode2.sh). No real CLI, home, Keychain or network is used; Gemini is left out (it reads
// agy's settings in the user's home).
func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fatalError("FAIL: " + message) }
}
let fm = FileManager.default
let home = ProcessInfo.processInfo.environment["AI_ILLUMINATI_TEST_HOME"] ?? ""
expect(!home.isEmpty && AccountStore.home == home, "the workspace test needs its own home")
let base = URL(fileURLWithPath: home).appendingPathComponent("work").resolvingSymlinksInPath()
let folder = base.appendingPathComponent("folder"), session = base.appendingPathComponent("session")
try! fm.createDirectory(at: folder.appendingPathComponent("sub"), withIntermediateDirectories: true)
try! fm.createDirectory(at: session, withIntermediateDirectories: true)
try! "one".write(to: folder.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
try! "two".write(to: folder.appendingPathComponent("sub/b.txt"), atomically: true, encoding: .utf8)
let root = WorkspaceRoot(path: folder.path, directory: true)
let claudeBase = ["-p", "x", "--tools", "", "--allowedTools", "Read", "--mcp-config", "{}", "--safe-mode"]
let codexBase = ["exec", "-C", "/somewhere", "-c", "sandbox_mode=\"read-only\"", "--sandbox", "read-only"]
var asked = 0
let gateway: WorkspaceTools = { _ in asked += 1; return WorkspaceToolLink(socket: "/tmp/tools.sock", session: "key") }
func value(_ args: [String], after flag: String) -> String? { args.firstIndex(of: flag).map { args[$0 + 1] } }
func manifest(_ args: [String]) -> (path: String, object: [String: Any]) {
    let config = try! JSONSerialization.jsonObject(with: Data(value(args, after: "--mcp-config")!.utf8)) as! [String: Any]
    let server = (config["mcpServers"] as! [String: Any])["illuminati"] as! [String: Any]
    let path = (server["args"] as! [String])[1]
    return (path, try! JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as! [String: Any])
}

// AutoGuard's denied Claude commands in full access: the whole list, in order. One entry less must fail here.
let denied = "Bash(git push:*),Bash(git filter-branch:*),Bash(git filter-repo:*),Bash(/usr/bin/git push:*),Bash(gh repo delete:*),Bash(/bin/rm:*),Bash(git clean:*),Bash(/usr/bin/security:*)"
var full = WorkspaceBinding(roots: [root]); full.fullAccess = true
expect(full.fullAccessActive, "full access is on for a plain chat that asks for it")
let fullClaude = try! WorkspaceInvocation(binding: full, room: UUID()).arguments(provider: .claude, original: claudeBase, directory: session, web: false, tools: gateway)
expect(value(fullClaude, after: "--disallowedTools") == denied, "full access denies exactly AutoGuard's commands: \(value(fullClaude, after: "--disallowedTools") ?? "none")")
expect(value(fullClaude, after: "--permission-mode") == "bypassPermissions" && value(fullClaude, after: "--tools") == "default"
       && !fullClaude.contains("--allowedTools") && !fullClaude.contains("--safe-mode") && !fullClaude.contains("--restricted")
       && value(fullClaude, after: "--add-dir") == folder.path && value(fullClaude, after: "--setting-sources") == "",
       "full access: every tool, no prompts, the folder added, no personal settings")
let fullCodex = try! WorkspaceInvocation(binding: full, room: UUID()).arguments(provider: .codex, original: codexBase, directory: session, web: false, tools: gateway)
expect(fullCodex.contains("sandbox_mode=\"danger-full-access\"") && fullCodex.contains("approval_policy=\"never\"")
       && !fullCodex.contains("--sandbox") && value(fullCodex, after: "-C") == session.path, "Codex full access: no sandbox, runs in the session folder")

// View: read tools only, no Bash, no writes, no sandbox settings; Codex read only.
let view = WorkspaceBinding(roots: [root])
let viewClaude = try! WorkspaceInvocation(binding: view, room: UUID()).arguments(provider: .claude, original: claudeBase, directory: session, web: false, tools: gateway)
expect(value(viewClaude, after: "--tools") == "Read,Grep,Glob" && value(viewClaude, after: "--allowedTools") == "Read,Grep,Glob,mcp__illuminati__*"
       && value(viewClaude, after: "--permission-mode") == "dontAsk" && viewClaude.contains("--restricted") && !viewClaude.contains("--settings")
       && !viewClaude.contains("--disallowedTools") && !viewClaude.contains("--safe-mode"), "view: Claude reads only: \(viewClaude)")
let webClaude = try! WorkspaceInvocation(binding: view, room: UUID()).arguments(provider: .claude, original: claudeBase, directory: session, web: true, tools: gateway)
expect(value(webClaude, after: "--tools") == "Read,Grep,Glob,WebSearch,WebFetch", "web adds only the web tools")
let viewCodex = try! WorkspaceInvocation(binding: view, room: UUID()).arguments(provider: .codex, original: codexBase, directory: session, web: false, tools: gateway)
expect(viewCodex.contains("sandbox_mode=\"read-only\"") && viewCodex.contains("features.shell_tool=false") && viewCodex.contains("web_search=\"disabled\"")
       && viewCodex.contains("sandbox_workspace_write.network_access=false") && viewCodex.filter { $0.hasPrefix("sandbox_mode=") }.count == 1,
       "view: Codex read only, no shell, no web, old sandbox options replaced")
// The chat's own folder may change in view (writable root): Edit only there.
let own = base.appendingPathComponent("own"); try! fm.createDirectory(at: own, withIntermediateDirectories: true)
let ownClaude = try! WorkspaceInvocation(binding: WorkspaceBinding(roots: [root, WorkspaceRoot(path: own.path, directory: true, writable: true)]), room: UUID())
    .arguments(provider: .claude, original: claudeBase, directory: session, web: false, tools: gateway)
expect(value(ownClaude, after: "--allowedTools") == "Read,Grep,Glob,mcp__illuminati__*,Edit(/\(own.path)/**)", "view: only the chat's own folder is editable")

// Writing needs a finished backup of exactly these folders first.
let room = UUID()
var execute = WorkspaceBinding(roots: [root], level: .execute)
do {
    _ = try WorkspaceInvocation(binding: execute, room: room, readOnly: false).arguments(provider: .claude, original: claudeBase, directory: session, web: false, tools: gateway)
    expect(false, "writing without a backup is refused")
} catch { expect(error.localizedDescription.contains("백업"), "the refusal names the backup: \(error.localizedDescription)") }
var backup = try! WorkspaceBackup.begin(execute, room: room, runID: UUID())
let exe = try! WorkspaceInvocation(binding: execute, room: room, readOnly: false, backupPath: backup.directory)
    .arguments(provider: .claude, original: claudeBase, directory: session, web: false, tools: gateway)
expect(value(exe, after: "--tools") == "Read,Grep,Glob,Edit,Write,Bash" && value(exe, after: "--allowedTools") == "Read,Grep,Glob,mcp__illuminati__*,Edit,Write,Bash",
       "execute: edit and Bash")
let settings = try! JSONSerialization.jsonObject(with: Data(value(exe, after: "--settings")!.utf8)) as! [String: Any]
let sandbox = settings["sandbox"] as! [String: Any], files = sandbox["filesystem"] as! [String: Any]
expect(sandbox["enabled"] as? Bool == true && sandbox["allowUnsandboxedCommands"] as? Bool == false && files["allowWrite"] as? [String] == [folder.path],
       "execute: Bash in the sandbox, writes only in the linked folder")
// A project's Git data is never written, even in execute.
let common = base.path + "/common.git"
execute.project = ProjectBinding(root: folder.path, common: common, remote: "origin", remoteURL: "https://example.invalid/r.git")
let project = try! WorkspaceInvocation(binding: execute, room: room, readOnly: false, backupPath: backup.directory)
    .arguments(provider: .claude, original: claudeBase, directory: session, web: false, tools: gateway)
let projectSettings = try! JSONSerialization.jsonObject(with: Data(value(project, after: "--settings")!.utf8)) as! [String: Any]
let deny = (projectSettings["permissions"] as! [String: Any])["deny"] as! [String]
expect(((projectSettings["sandbox"] as! [String: Any])["filesystem"] as! [String: Any])["denyWrite"] as? [String] == [common, folder.path + "/.git"]
       && deny.contains("Edit(/\(folder.path)/.git/**)") && deny.contains("Write(/\(folder.path)/.git)") && deny.contains("Edit(/\(common)/**)"), "execute: the project's Git data is denied: \(deny)")
let codexExe = try! WorkspaceInvocation(binding: WorkspaceBinding(roots: [root], level: .execute), room: room, readOnly: false, backupPath: backup.directory)
    .arguments(provider: .codex, original: codexBase, directory: session, web: false, tools: gateway)
expect(codexExe.contains("sandbox_mode=\"workspace-write\"") && codexExe.contains("features.shell_tool=true")
       && codexExe.contains("sandbox_workspace_write.writable_roots=[\"\(folder.path)\"]"), "Codex execute: writes only in the linked folder")

// The bridge's manifest: private, the folders and level, and the tool gateway only when this chat offers tools.
asked = 0
let plain = manifest(viewClaude)
expect(plain.object["level"] as? String == "view" && plain.object["project"] as? Bool == false && plain.object["tools"] == nil,
       "a plain folder chat gets no tool gateway")
expect((try! fm.attributesOfItem(atPath: plain.path)[.posixPermissions] as! NSNumber).intValue == 0o600, "the manifest is private")
let roots = plain.object["roots"] as! [[String: Any]]
expect(roots.count == 1 && roots[0]["path"] as? String == folder.path && roots[0]["directory"] as? Bool == true && roots[0]["writable"] == nil, "the manifest names the folder")
_ = try! WorkspaceInvocation(binding: view, room: UUID()).arguments(provider: .claude, original: claudeBase, directory: session, web: false, tools: gateway)
expect(asked == 0, "the gateway is not asked when the chat offers no tools")
var face = view; face.face = true
let faced = manifest(try! WorkspaceInvocation(binding: face, room: UUID()).arguments(provider: .claude, original: claudeBase, directory: session, web: false, tools: gateway))
expect(asked == 1 && faced.object["tools"] as? String == "/tmp/tools.sock" && faced.object["toolSession"] as? String == "key", "a chat with tools gets the gateway")
var side = view; side.origin = .side
_ = try! WorkspaceInvocation(binding: side, room: UUID()).arguments(provider: .claude, original: claudeBase, directory: session, web: false, tools: gateway)
expect(asked == 2, "a side AI gets the gateway (for ask_ai)")
let none = manifest(try! WorkspaceInvocation(binding: face, room: UUID()).arguments(provider: .claude, original: claudeBase, directory: session, web: false, tools: { _ in nil }))
expect(none.object["tools"] == nil, "no gateway running: no tools in the manifest")

// AutoGuard's environment: its shims first on PATH, no Git/GitHub credentials, no SSH agent.
let env = FullAutoGuard.environment(["PATH": "/usr/bin:/bin", "GH_TOKEN": "x", "GITHUB_TOKEN": "y", "GH_ENTERPRISE_TOKEN": "z", "SSH_AUTH_SOCK": "/tmp/agent", "KEEP": "1"])
let shims = AccountStore.supportDir + "/auto-guard/bin"
expect(env["PATH"] == shims + ":/usr/bin:/bin" && env["KEEP"] == "1", "AutoGuard's shims come first on PATH")
expect(["GH_TOKEN", "GITHUB_TOKEN", "GH_ENTERPRISE_TOKEN", "SSH_AUTH_SOCK"].allSatisfy { env[$0] == nil }, "tokens and the SSH agent are removed")
expect(env["GIT_CONFIG_COUNT"] == "2" && env["GIT_CONFIG_KEY_0"] == "credential.helper" && env["GIT_CONFIG_VALUE_0"] == ""
       && env["GIT_CONFIG_KEY_1"] == "credential.https://github.com.helper" && env["GIT_CONFIG_VALUE_1"] == ""
       && env["GIT_TERMINAL_PROMPT"] == "0" && env["GIT_ASKPASS"] == "/usr/bin/false" && env["SSH_ASKPASS"] == "/usr/bin/false"
       && env["GIT_SSH_COMMAND"] == "/usr/bin/ssh -o BatchMode=yes -o IdentitiesOnly=yes -i /dev/null"
       && env["GH_CONFIG_DIR"] == AccountStore.supportDir + "/auto-guard/gh-empty", "no Git credential helper, prompt, SSH key or GitHub login")
for name in ["git", "rm", "security"] {
    let mode = (try? fm.attributesOfItem(atPath: shims + "/" + name)[.posixPermissions] as? NSNumber)?.intValue
    expect(mode == 0o700, "the \(name) shim is there and private")
}
func shell(_ command: String) -> (status: Int32, output: String) {
    let p = Process(), out = Pipe(); p.executableURL = URL(fileURLWithPath: "/bin/bash"); p.arguments = ["-c", command]
    p.environment = env; p.currentDirectoryURL = folder; p.standardOutput = out; p.standardError = out
    try! p.run(); let data = out.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
    return (p.terminationStatus, String(decoding: data, as: UTF8.self))
}
for blocked in ["git push origin main", "git -C . push --force", "git filter-branch", "git -c a=b filter-repo"] {
    let r = shell(blocked)
    expect(r.status != 0 && r.output.contains("git_push"), "the git shim refuses: \(blocked)")
}
expect(shell("git --version").status == 0, "other git commands pass")
for blocked in ["security find-generic-password -s 'AI Illuminati Google' -w", "security dump-keychain"] {
    let r = shell(blocked)
    expect(r.status != 0 && r.output.contains("AI Illuminati full auto"), "the security shim refuses: \(blocked)")
}
let scratch = fm.temporaryDirectory.appendingPathComponent("ws-contract-" + UUID().uuidString)
try! "x".write(to: scratch, atomically: true, encoding: .utf8)
expect(shell("rm '\(scratch.path)'").status == 0 && !fm.fileExists(atPath: scratch.path), "rm deletes temporary files normally")
expect(shell("rm '\(scratch.path)'").status != 0 && shell("rm -f '\(scratch.path)'").status == 0, "rm keeps missing-file and -f semantics")

// Backup and Undo: what the answer changed is listed, and Undo puts back exactly that.
try! "changed".write(to: folder.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
try! "new".write(to: folder.appendingPathComponent("c.txt"), atomically: true, encoding: .utf8)
try! fm.removeItem(at: folder.appendingPathComponent("sub/b.txt"))
try! backup.finish()
expect(backup.changes.map { "\($0.kind) \($0.path.replacingOccurrences(of: folder.path, with: ""))" }.sorted() == ["added /c.txt", "deleted /sub/b.txt", "modified /a.txt"],
       "the backup lists what changed: \(backup.changes)")
var loaded = try! WorkspaceBackup.load(backup.directory)
expect(loaded.changes == backup.changes && loaded.roots == [root], "a finished backup reads back")
expect((try! fm.attributesOfItem(atPath: backup.directory + "/complete.json")[.posixPermissions] as! NSNumber).intValue == 0o600, "complete.json is private")
try! loaded.restore()
expect((try? String(contentsOf: folder.appendingPathComponent("a.txt"), encoding: .utf8)) == "one"
       && (try? String(contentsOf: folder.appendingPathComponent("sub/b.txt"), encoding: .utf8)) == "two"
       && !fm.fileExists(atPath: folder.appendingPathComponent("c.txt").path), "Undo puts back what the answer changed")
do { var again = try WorkspaceBackup.load(backup.directory); try again.restore(); expect(false, "an Undo runs once") } catch {}
// Undo refuses when the folder changed after the answer.
var second = try! WorkspaceBackup.begin(WorkspaceBinding(roots: [root], level: .write), room: room, runID: UUID())
try! "answer".write(to: folder.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
try! second.finish()
try! "user".write(to: folder.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
do { try second.restore(); expect(false, "Undo over a later change is refused") }
catch { expect((try? String(contentsOf: folder.appendingPathComponent("a.txt"), encoding: .utf8)) == "user", "a refused Undo writes nothing") }
do { _ = try WorkspaceBackup.load(base.path); expect(false, "only the app's own backups load") } catch {}
// A backup must not hold its own location, and linked folders may not overlap.
do { _ = try WorkspaceBackup.begin(WorkspaceBinding(roots: [root, WorkspaceRoot(path: folder.path + "/sub", directory: true)]), room: room, runID: UUID()); expect(false, "nested folders are refused") } catch {}
do { _ = try WorkspaceBackup.begin(WorkspaceBinding(roots: [WorkspaceRoot(path: home, directory: true)]), room: room, runID: UUID()); expect(false, "a folder holding the backups is refused") } catch {}
// Deleting a chat removes its backups.
try! WorkspaceBackup.purgeRoom(room)
expect(!fm.fileExists(atPath: WorkspaceBackup.base.appendingPathComponent(room.uuidString).path), "a deleted chat's backups go")

// Saved shapes. A chat's `workspace` (chats/<id>.json): the same keys, absent fields left out.
var saved = WorkspaceBinding(roots: [WorkspaceRoot(path: "/p", directory: true, writable: true), WorkspaceRoot(path: "/f.txt", directory: false)], level: .write)
saved.project = ProjectBinding(root: "/p", common: "/p/.git", remote: "origin", remoteURL: "https://example.invalid/p.git", kind: "documents")
saved.fullAuto = false; saved.projectGeneration = 3
let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
let golden = #"{"fullAuto":false,"level":"write","project":{"common":"/p/.git","kind":"documents","remote":"origin","remoteURL":"https://example.invalid/p.git","root":"/p"},"projectGeneration":3,"roots":[{"directory":true,"path":"/p","writable":true},{"directory":false,"path":"/f.txt"}]}"#
expect(String(decoding: try! encoder.encode(saved), as: UTF8.self) == golden, "a chat's workspace keeps its saved keys: \(String(decoding: try! encoder.encode(saved), as: UTF8.self))")
// An older chat's workspace (before project, full auto and the rest; `level` was always saved): read with the defaults.
let old = try! JSONDecoder().decode(WorkspaceBinding.self, from: Data(#"{"roots":[{"path":"/old","directory":true}],"level":"view"}"#.utf8))
expect(old.level == .view && old.project == nil && old.fullAuto == nil && old.roots == [WorkspaceRoot(path: "/old", directory: true)] && !old.fullAccessActive,
       "an older workspace reads with the defaults")
expect(try! JSONDecoder().decode([WorkspaceLevel].self, from: Data(#"["view","write","execute"]"#.utf8)) == [.view, .write, .execute]
       && (try? JSONDecoder().decode(ToolOrigin.self, from: Data(#""side""#.utf8))) == .side, "levels and origins keep their raw values")
// An older backup's complete.json (before created, trimmed, cloud and git heads) still loads.
let oldFolder = WorkspaceBackup.base.appendingPathComponent(UUID().uuidString).appendingPathComponent(UUID().uuidString)
try! fm.createDirectory(at: oldFolder, withIntermediateDirectories: true)
try! #"{"directory":"\#(oldFolder.path)","roots":[{"path":"/x","directory":true}],"before":{"0/a":{"kind":"file","digest":"d"}},"changes":[{"path":"/x/a","kind":"modified"}],"gitStates":[],"restored":false}"#
    .write(to: oldFolder.appendingPathComponent("complete.json"), atomically: true, encoding: .utf8)
let older = try! WorkspaceBackup.load(oldFolder.path)
expect(older.changes == [WorkspaceChange(path: "/x/a", kind: "modified")] && older.before["0/a"]?.kind == "file" && older.cloud == nil, "an older backup reads")

// Disk sizes: a hard link counts once, across calls with the same `seen`.
let sized = base.appendingPathComponent("sized"); try! fm.createDirectory(at: sized, withIntermediateDirectories: true)
try! Data(count: 10_000).write(to: sized.appendingPathComponent("one"))
try! fm.linkItem(at: sized.appendingPathComponent("one"), to: sized.appendingPathComponent("two"))
let size = DiskUsage.of(sized)
expect(size.files == 1 && size.logical == 10_000 && size.allocated > 0 && size.unreadable == 0, "a hard link counts once: \(size)")
var seen = Set<DiskUsage.FileID>()
_ = DiskUsage.of(sized.appendingPathComponent("one"), seen: &seen)
expect(DiskUsage.of(sized.appendingPathComponent("two"), seen: &seen).files == 0, "the same file is not counted again across calls")
expect(DiskUsage.of(base.appendingPathComponent("missing")).unreadable == 1, "a missing path counts as unreadable")

// What another AI of the chat sees (C0, moved down from the chat): consulted and side read only without face or project;
// an opinion writes only in the chat's folder; a meeting's folder comes first and writable.
do {
    let project = ProjectBinding(root: "/tmp/p", common: "/tmp/p/.git", remote: "origin", remoteURL: "", kind: nil)
    let full = WorkspaceBinding(roots: [WorkspaceRoot(path: "/tmp/p", directory: true, writable: true), WorkspaceRoot(path: "/tmp/chat", directory: true, writable: true),
                                        WorkspaceRoot(path: "/tmp/f.txt", directory: false, writable: true)],
                                level: .execute, project: project, projectRunID: UUID(), projectGeneration: 2, fullAccess: true, face: true)
    let asked = full.consulted, side = full.side
    expect(asked.roots.map(\.path) == full.roots.map(\.path) && asked.roots.allSatisfy { $0.writable == nil } && asked.roots.map(\.directory) == [true, true, false]
           && asked.project == nil && asked.projectRunID == nil && asked.level == .view && asked.face == false && asked.origin == .consulted, "consulted: every folder read only, no tools")
    expect(side.roots.map(\.writable) == asked.roots.map(\.writable) && side.face == false && side.origin == .side, "side: the same view, as a side answer")
    let opinion = full.opinion(chatFolder: "/tmp/chat")
    expect(opinion.roots.map(\.writable) == [nil, true, nil] && opinion.project == nil && opinion.projectRunID == nil && opinion.projectGeneration == nil
           && opinion.level == .view && opinion.fullAccess == nil && opinion.face == true, "opinion: only the chat's folder writable")
    let meeting = full.meeting(folder: "/tmp/chat")
    expect(meeting.roots.map(\.path) == ["/tmp/chat", "/tmp/p", "/tmp/f.txt"] && meeting.roots.map(\.writable) == [true, nil, nil]
           && meeting.face == nil && meeting.origin == .consulted && meeting.project == nil, "meeting: its folder first and writable, the rest read only")
}

print("PASS: workspace contract")
