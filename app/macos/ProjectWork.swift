import Cocoa
import CryptoKit
import Darwin

struct ProjectBinding: Codable, Equatable {
    var root: String
    var common: String
    var remote: String
    var remoteURL: String
}

// All privileged commands use fixed argv, closed stdin, bounded output and a cancellable process group.
enum ProjectProcess {
    struct Reply { var status: Int32; var output: String }
    static func run(_ executable: String, _ args: [String], cwd: String, token: DebateCancellation? = nil,
                    deadline: Date = Date().addingTimeInterval(60)) throws -> Reply {
        if token?.isCancelled == true { throw MaterialReader.error("Project operation cancelled.") }
        let p = Process(), out = Pipe(), err = Pipe(), lock = NSLock(), done = DispatchGroup()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        p.arguments = [WorkspaceInvocation.resources.appendingPathComponent("project_process.py").path, executable] + args
        p.currentDirectoryURL = URL(fileURLWithPath: cwd)
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_TERMINAL_PROMPT"] = "0"; environment["GIT_SSH_COMMAND"] = "/usr/bin/ssh -o BatchMode=yes"
        environment["AI_ILLUMINATI_PROJECT_PROCESS"] = "1"
        p.environment = environment; p.standardInput = FileHandle.nullDevice; p.standardOutput = out; p.standardError = err
        var captured = Data()
        for pipe in [out, err] {
            done.enter()
            DispatchQueue.global().async {
                while true {
                    let data = pipe.fileHandleForReading.availableData
                    if data.isEmpty { break }
                    lock.lock(); captured.append(data.prefix(max(0, 240_000 - captured.count))); lock.unlock()
                }
                done.leave()
            }
        }
        do { try p.run() } catch {
            out.fileHandleForWriting.closeFile(); err.fileHandleForWriting.closeFile()
            throw MaterialReader.error("Could not start project command.")
        }
        token?.attach(p)
        defer { token?.detach(p); kill(-p.processIdentifier, SIGKILL) }
        while p.isRunning {
            if token?.isCancelled == true || Date() >= deadline {
                DebateCancellation.end(p); p.waitUntilExit()
                _ = done.wait(timeout: .now() + 2)
                throw MaterialReader.error("Project command stopped or timed out; inspect Git state before retrying.")
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        kill(-p.processIdentifier, SIGKILL) // Remove background writers even after their parent has exited.
        guard done.wait(timeout: .now() + 3) == .success else { throw MaterialReader.error("Project child process did not finish.") }
        guard token?.isCancelled != true, Date() < deadline else { throw MaterialReader.error("Project command stopped or timed out.") }
        lock.lock(); let text = String(decoding: captured, as: UTF8.self); lock.unlock()
        return Reply(status: p.terminationStatus, output: String(text.prefix(60_000)))
    }
    static func git(_ args: [String], root: String, token: DebateCancellation? = nil, timeout: TimeInterval = 60) throws -> String {
        let reply = try run("/usr/bin/git", ["--literal-pathspecs", "-c", "core.hooksPath=/dev/null", "-c", "core.fsmonitor=false", "-c", "submodule.recurse=false"] + args,
                            cwd: root, token: token, deadline: Date().addingTimeInterval(timeout))
        guard reply.status == 0 else { throw MaterialReader.error("git failed (\(reply.status)): \(reply.output)") }
        return reply.output.trimmingCharacters(in: .newlines)
    }
    static func inspect(_ path: String) throws -> ProjectBinding {
        let root = try git(["rev-parse", "--show-toplevel"], root: path)
        let canonical = URL(fileURLWithPath: root).resolvingSymlinksInPath().standardizedFileURL.path
        guard canonical == URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path else { throw MaterialReader.error("Link the repository's top-level folder.") }
        let common = try git(["rev-parse", "--git-common-dir"], root: canonical)
        let commonURL = (common.hasPrefix("/") ? URL(fileURLWithPath: common) : URL(fileURLWithPath: canonical).appendingPathComponent(common)).resolvingSymlinksInPath().standardizedFileURL.path
        let remote = try git(["remote", "get-url", "origin"], root: canonical)
        guard URLComponents(string: remote)?.password == nil else { throw MaterialReader.error("Remove embedded credentials from the Git remote URL first.") }
        return ProjectBinding(root: canonical, common: commonURL, remote: "origin", remoteURL: remote)
    }
}

struct ProjectApproval: Identifiable {
    let id = UUID()
    var room: UUID
    var run: UUID
    var title: String
    var detail: String
}
final class ProjectCenter: ObservableObject {
    static let shared = ProjectCenter()
    @Published var requests: [ProjectApproval] = []
    @Published var events: [UUID: [String]] = [:]
    private let lock = NSLock()
    private var decisions: [UUID: Bool] = [:]
    private var accepting = true
    private var approvalEpoch = 0
    func resume() { lock.lock(); accepting = true; lock.unlock() }
    func decide(_ id: UUID, allow: Bool) { guard requests.contains(where: { $0.id == id }) else { return }; lock.lock(); decisions[id] = allow; lock.unlock(); requests.removeAll { $0.id == id } }
    func note(_ room: UUID, _ text: String) {
        DispatchQueue.main.async { self.events[room, default: []].append(text); self.events[room] = Array(self.events[room, default: []].suffix(20)) }
    }
    func approve(_ request: ProjectApproval, token: DebateCancellation, deadline: Date) -> Bool {
        lock.lock(); let enabled = accepting, epoch = approvalEpoch; lock.unlock()
        guard enabled else { return false }
        DispatchQueue.main.async {
            self.lock.lock(); let current = self.accepting && self.approvalEpoch == epoch; self.lock.unlock()
            if current { self.requests.append(request) }
        }
        defer {
            lock.lock(); decisions.removeValue(forKey: request.id); lock.unlock()
            DispatchQueue.main.async { self.requests.removeAll { $0.id == request.id } }
        }
        while !token.isCancelled && Date() < deadline {
            lock.lock(); let answer = decisions[request.id], current = accepting && approvalEpoch == epoch; lock.unlock()
            if !current { return false }
            if let answer { return answer }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return false
    }
    func cancel(room: UUID? = nil) {
        if room == nil { lock.lock(); accepting = false; approvalEpoch += 1; lock.unlock() }
        let selected = requests.filter { room == nil || $0.room == room }
        for request in selected { decide(request.id, allow: false) }
    }
}

// A turn owns the repo, not a model. New generations revoke the previous AI's capabilities at handoff.
final class ProjectRun {
    let id = UUID(), room: UUID, binding: ProjectBinding, outer: DebateCancellation
    let started = Date()
    let deadline = Date().addingTimeInterval(3600)
    private let clock = NSLock()
    private var waitingSince: Date?
    private var waited: TimeInterval = 0
    func beginApproval() { clock.lock(); waitingSince = Date(); clock.unlock() }
    func endApproval() { clock.lock(); if let date = waitingSince { waited += Date().timeIntervalSince(date) }; waitingSince = nil; clock.unlock() }
    var activeExpired: Bool { clock.lock(); defer { clock.unlock() }; return Date().timeIntervalSince(started) - waited - (waitingSince.map { Date().timeIntervalSince($0) } ?? 0) > 2700 }
    private(set) var generation = 0
    var attempt = DebateCancellation()
    private let lifecycle = NSLock()
    private var ended = false
    func stop() { lifecycle.lock(); ended = true; lifecycle.unlock(); attempt.cancel() }
    var committed = false, pushed = false
    var initialDirty: Set<String> = []
    let operations = NSRecursiveLock()
    init(room: UUID, binding: ProjectBinding, token: DebateCancellation) {
        self.room = room; self.binding = binding; self.outer = token
        let status = (try? ProjectProcess.git(["status", "--porcelain", "-z"], root: binding.root)) ?? ""
        initialDirty = Set(status.split(separator: "\0").map { String($0.dropFirst(3)) })
        Thread.detachNewThread { [self] in
            while true {
                lifecycle.lock(); let finished = ended; lifecycle.unlock()
                if finished { break }
                if outer.isCancelled || Date() >= deadline || activeExpired { attempt.cancel(); break }
                Thread.sleep(forTimeInterval: 0.05)
            }
        }
    }
    func nextAttempt() { attempt.cancel(); operations.lock(); defer { operations.unlock() }; ToolHub.shared.revoke(project: id); generation += 1; attempt = DebateCancellation(); if outer.isCancelled || Date() >= deadline || activeExpired { attempt.cancel() } }
    var cancelled: Bool { outer.isCancelled || attempt.isCancelled || Date() >= deadline || activeExpired }
    func validate(_ generation: Int) throws {
        guard !cancelled, generation == self.generation else { throw MaterialReader.error("Project capability expired or operation cancelled.") }
        guard try ProjectProcess.inspect(binding.root) == binding else { throw MaterialReader.error("Project repository or remote changed. Reconnect it first.") }
    }
    func checkpoint(_ note: String) -> String {
        let head = (try? ProjectProcess.git(["rev-parse", "HEAD"], root: binding.root)) ?? ""
        let status = (try? ProjectProcess.git(["status", "--short"], root: binding.root)) ?? ""
        let diff = (try? ProjectProcess.git(["diff", "--no-ext-diff", "--no-textconv", "--stat"], root: binding.root)) ?? ""
        let text = "Project: \(binding.root)\n\(note)\nHEAD: \(head)\n\(status)\n\(diff)\nCommitted: \(committed); pushed: \(pushed). Preserve unfinished files. Do not pull a dirty tree."
        let base = URL(fileURLWithPath: AccountStore.supportDir).appendingPathComponent("project-work", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? text.write(to: base.appendingPathComponent(id.uuidString + ".txt"), atomically: true, encoding: .utf8)
        return text
    }
}

enum ProjectWork {
    private static let mutex = NSLock()
    private static var held: [String: Int32] = [:]
    private static var runs: [UUID: ProjectRun] = [:]
    static var active: Bool { mutex.lock(); defer { mutex.unlock() }; return !runs.isEmpty }
    static func get(_ id: UUID?) -> ProjectRun? { mutex.lock(); defer { mutex.unlock() }; return id.flatMap { runs[$0] } }
    static func register(_ run: ProjectRun) { mutex.lock(); runs[run.id] = run; mutex.unlock() }
    static func finish(_ run: ProjectRun) { run.stop(); run.operations.lock(); defer { run.operations.unlock() }; ToolHub.shared.revoke(project: run.id); mutex.lock(); runs.removeValue(forKey: run.id); mutex.unlock() }
    static func acquire(_ binding: WorkspaceBinding?) throws -> [String] {
        guard let binding else { return [] }
        var common = Set<String>()
        for root in binding.roots where root.directory && (root.writable == true || binding.level != .view) {
            if let path = try? ProjectProcess.git(["rev-parse", "--git-common-dir"], root: root.path) {
                common.insert((path.hasPrefix("/") ? URL(fileURLWithPath: path) : URL(fileURLWithPath: root.path).appendingPathComponent(path)).resolvingSymlinksInPath().standardizedFileURL.path)
            }
        }
        mutex.lock(); defer { mutex.unlock() }
        var acquired: [String] = []
        do {
            for path in common.sorted() {
                guard held[path] == nil else { throw MaterialReader.error("Another AI is writing this repository. Wait until it finishes.") }
                let base = URL(fileURLWithPath: AccountStore.supportDir).appendingPathComponent("project-locks")
                try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
                let name = SHA256.hash(data: Data(path.utf8)).map { String(format: "%02x", $0) }.joined()
                let fd = open(base.appendingPathComponent(name).path, O_CREAT | O_RDWR | O_CLOEXEC, S_IRUSR | S_IWUSR)
                guard fd >= 0 else { throw MaterialReader.error("Could not create repository lock.") }
                guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { close(fd); throw MaterialReader.error("Repository is busy in another app instance.") }
                held[path] = fd; acquired.append(path)
            }
            return acquired
        } catch { for path in acquired { if let fd = held.removeValue(forKey: path) { close(fd) } }; throw error }
    }
    static func release(_ paths: [String]) { mutex.lock(); defer { mutex.unlock() }; for path in paths { if let fd = held.removeValue(forKey: path) { close(fd) } } }
}

final class GitLink: ToolProvider {
    static let shared = GitLink()
    var active: Bool { ProjectWork.active }
    func tools() -> [[String: Any]] { [] } // Scoped tools must never be exposed globally.
    func tools(context: ToolContext) -> [[String: Any]] {
        guard let run = ProjectWork.get(context.projectRun), run.room == context.room, context.projectGeneration == run.generation, !run.cancelled else { return [] }
        let string: [String: Any] = ["type": "string"]
        func tool(_ name: String, _ description: String, _ props: [String: Any] = [:], _ required: [String] = []) -> [String: Any] {
            ["name": name, "description": description, "inputSchema": ["type": "object", "properties": props, "required": required, "additionalProperties": false]]
        }
        return [tool("git_status", "Read linked project status and branch."), tool("git_diff", "Read staged or unstaged diff; never executes external diff tools.", ["staged": ["type": "boolean"]]), tool("git_log", "Recent project commits."),
                tool("git_pull", "Fast-forward only, clean worktree required. Never stash/reset."),
                tool("git_commit", "Commit only explicit relative paths; existing user changes require approval.", ["message": string, "paths": ["type": "array", "items": string]], ["message", "paths"]),
                tool("git_push", "Push current main/feature branch; never stable or force."),
                tool("git_publish_stable", "Publish an exact main SHA to stable after the user's approval card."),
                tool("git_branch", "Create a new branch from a clean tree.", ["name": string], ["name"]), tool("git_switch", "Switch an existing branch with a clean tree.", ["name": string], ["name"]),
                tool("project_run", "Run a named command from .ai-illuminati.json after user approval. Never pass shell commands.", ["name": string], ["name"])]
    }
    func call(_ name: String, _ arguments: [String: Any], context: ToolContext) -> [String: Any] {
        guard let run = ProjectWork.get(context.projectRun), run.room == context.room, let generation = context.projectGeneration else { return ToolHub.failure("No project capability.") }
        run.operations.lock(); defer { run.operations.unlock() }
        do {
            try run.validate(generation)
            _ = run.checkpoint("Starting \(name); inspect remote state if interrupted.")
            let output = try execute(name, arguments, run, generation)
            _ = run.checkpoint("\(name) completed")
            ProjectCenter.shared.note(run.room, name + " → " + String(output.prefix(180)))
            return ["content": [["type": "text", "text": output]], "isError": false]
        } catch { _ = run.checkpoint(name + " failed: " + String(error.localizedDescription.prefix(500))); ProjectCenter.shared.note(run.room, name + " failed"); return ToolHub.failure(error.localizedDescription) }
    }
    private func execute(_ name: String, _ args: [String: Any], _ run: ProjectRun, _ generation: Int) throws -> String {
        func git(_ argv: [String], timeout: TimeInterval = 120) throws -> String { try run.validate(generation); return try ProjectProcess.git(argv, root: run.binding.root, token: run.attempt, timeout: min(timeout, run.deadline.timeIntervalSinceNow)) }
        func clean() throws { guard try git(["status", "--porcelain"]).isEmpty else { throw MaterialReader.error("Working tree is not clean; preserve edits and do not pull/switch/stash.") } }
        func approve(_ title: String, _ detail: String) throws {
            run.beginApproval(); defer { run.endApproval() }
            guard ProjectCenter.shared.approve(ProjectApproval(room: run.room, run: run.id, title: title, detail: detail), token: run.attempt, deadline: min(run.deadline, Date().addingTimeInterval(900))) else { throw MaterialReader.error("Project approval refused or cancelled.") }
            try run.validate(generation)
        }
        switch name {
        case "git_status": return try git(["status", "--short", "--branch"])
        case "git_log": return try git(["log", "-10", "--oneline"])
        case "git_diff": return try git(["diff", "--no-ext-diff", "--no-textconv"] + ((args["staged"] as? Bool == true) ? ["--cached"] : []))
        case "git_pull": try clean(); return try git(["pull", "--ff-only", "--no-rebase"], timeout: 180)
        case "git_commit":
            guard let message = args["message"] as? String, !message.isEmpty, message.count <= 4000,
                  let paths = args["paths"] as? [String], !paths.isEmpty, paths.count <= 500 else { throw MaterialReader.error("Provide a commit message and explicit paths.") }
            for path in paths {
                guard !path.hasPrefix("/"), !path.split(separator: "/").contains(".."), !path.split(separator: "/").contains(".git"), !path.isEmpty else { throw MaterialReader.error("Invalid commit path.") }
                let resolved = URL(fileURLWithPath: run.binding.root).appendingPathComponent(path).resolvingSymlinksInPath().path
                guard resolved.hasPrefix(run.binding.root + "/") else { throw MaterialReader.error("Commit path leaves the project.") }
            }
            let diff = try git(["diff", "--no-ext-diff", "--no-textconv", "HEAD", "--"] + paths)
            if paths.contains(where: { path in run.initialDirty.contains(where: { dirty in path == "." || dirty == path || dirty.hasPrefix(path + "/") }) }) { try approve("기존 변경 포함 / Include existing edits", diff) }
            let result = try git(["add", "--"] + paths) + "\n" + git(["commit", "--only", "-m", message, "--"] + paths)
            run.committed = true; return result
        case "git_push":
            let branch = try git(["branch", "--show-current"])
            guard branch == "main" || branch.hasPrefix("feature/") || branch.hasPrefix("codex/") || branch.hasPrefix("fix/") else { throw MaterialReader.error("Push supports main or a feature/fix/codex branch. Use the publish tool for stable.") }
            let sha = try git(["rev-parse", "HEAD"])
            let result = try git(["push", run.binding.remote, sha + ":refs/heads/" + branch], timeout: 180)
            run.pushed = true; return result + "\nPushed " + sha
        case "git_publish_stable":
            try clean()
            let sha = try git(["rev-parse", "refs/heads/main"])
            let summary = try git(["log", "-8", "--oneline", sha])
            try approve("stable 배포 / Publish stable", run.binding.root + "\n" + run.binding.remoteURL + "\nExact SHA: " + sha + "\n" + summary)
            let result = try git(["push", run.binding.remote, sha + ":refs/heads/stable"], timeout: 180)
            run.pushed = true; return result + "\nPublished " + sha
        case "git_branch", "git_switch":
            try clean()
            guard let branch = args["name"] as? String, !["stable", "HEAD", "master"].contains(branch), !branch.hasPrefix("-"), branch.count < 200 else { throw MaterialReader.error("Invalid or protected branch.") }
            _ = try git(["check-ref-format", "--branch", branch])
            return try git(name == "git_branch" ? ["switch", "-c", branch] : ["switch", branch])
        case "project_run":
            guard let selected = args["name"] as? String else { throw MaterialReader.error("Choose a registered command name.") }
            let url = URL(fileURLWithPath: run.binding.root).appendingPathComponent(".ai-illuminati.json")
            guard url.resolvingSymlinksInPath().path.hasPrefix(run.binding.root + "/") else { throw MaterialReader.error("Project config leaves the repository.") }
            guard let data = try? Data(contentsOf: url) else {
                throw MaterialReader.error("No .ai-illuminati.json in the project yet. Create it with {\"version\":1,\"commands\":{\"\(selected)\":{\"executable\":\"/absolute/path\",\"args\":[...]}}} and call project_run again; the user approves the exact command.")
            }
            guard data.count < 64_000, let config = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let commands = config["commands"] as? [String: [String: Any]], let command = commands[selected],
                  let exe = command["executable"] as? String, exe.hasPrefix("/"), let argv = command["args"] as? [String] else { throw MaterialReader.error("Unknown or invalid named project command. Add it to .ai-illuminati.json (absolute executable, args array) and call project_run again.") }
            let status = try git(["status", "--short"])
            let tree = try WorkspaceBackup.stamps([WorkspaceRoot(path: run.binding.root, directory: true)])
            try approve("프로젝트 실행 / Run project command", "Runs outside the AI sandbox as your user.\n" + run.binding.root + "\n" + exe + " " + argv.joined(separator: " ") + "\n" + status)
            guard try Data(contentsOf: url) == data, try WorkspaceBackup.stamps([WorkspaceRoot(path: run.binding.root, directory: true)]) == tree else { throw MaterialReader.error("Command changed after approval. Request it again.") }
            let reply = try ProjectProcess.run(exe, argv, cwd: run.binding.root, token: run.attempt, deadline: min(run.deadline, Date().addingTimeInterval(2700)))
            return "exit=\(reply.status)\n" + reply.output
        default: throw MaterialReader.error("Unknown project tool.")
        }
    }
}
