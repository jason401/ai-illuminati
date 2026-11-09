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
                    deadline: Date = Date().addingTimeInterval(60), guarded: Bool = false, extra: [String: String] = [:],
                    onLine: ((String) -> Void)? = nil) throws -> Reply {
        if token?.isCancelled == true { throw MaterialReader.error("Project operation cancelled.") }
        let p = Process(), out = Pipe(), err = Pipe(), lock = NSLock(), done = DispatchGroup()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        p.arguments = [WorkspaceInvocation.resources.appendingPathComponent("project_process.py").path, executable] + args
        p.currentDirectoryURL = URL(fileURLWithPath: cwd)
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_TERMINAL_PROMPT"] = "0"; environment["GIT_SSH_COMMAND"] = "/usr/bin/ssh -o BatchMode=yes"
        environment["AI_ILLUMINATI_PROJECT_PROCESS"] = "1"
        if guarded { environment = AutoGuard.environment(environment) }
        environment.merge(extra) { $1 }
        p.environment = environment; p.standardInput = FileHandle.nullDevice; p.standardOutput = out; p.standardError = err
        var captured = Data()
        for pipe in [out, err] {
            done.enter()
            DispatchQueue.global().async {
                var partial = Data()  // onLine: this pipe's unfinished line, bounded
                while true {
                    let data = pipe.fileHandleForReading.availableData
                    if data.isEmpty { break }
                    lock.lock(); captured.append(data.prefix(max(0, 240_000 - captured.count))); lock.unlock()
                    guard let onLine else { continue }
                    partial.append(data)
                    while let end = partial.firstIndex(of: 10) {
                        onLine(String(decoding: partial[partial.startIndex..<end], as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
                        partial.removeSubrange(partial.startIndex...end)
                    }
                    if partial.count > 4096 { partial.removeAll() }
                }
                if let onLine, !partial.isEmpty { onLine(String(decoding: partial, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)) }
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
    var created = Date()
    var deadline: Date?
}
// One list for every place that shows approvals: the chat card, the banner, the menu bar, the approval
// window and the macOS notification all follow `requests`, so deciding in one place clears them all.
final class ProjectCenter: ObservableObject {
    static let shared = ProjectCenter()
    @Published var requests: [ProjectApproval] = []
    // Requests that ran out of time (counted as refused); the chat keeps a note with Ask again until dismissed.
    @Published var expired: [ProjectApproval] = []
    func dismiss(_ id: UUID) { expired.removeAll { $0.id == id } }
    private let lock = NSLock()
    private var decisions: [UUID: Bool] = [:]
    private var accepting = true
    private var approvalEpoch = 0
    func resume() { lock.lock(); accepting = true; lock.unlock() }
    func decide(_ id: UUID, allow: Bool) { guard requests.contains(where: { $0.id == id }) else { return }; lock.lock(); decisions[id] = allow; lock.unlock(); requests.removeAll { $0.id == id } }
    func approve(_ request: ProjectApproval, token: DebateCancellation, deadline: Date) -> Bool {
        lock.lock(); let enabled = accepting, epoch = approvalEpoch; lock.unlock()
        guard enabled else { return false }
        var request = request
        request.deadline = deadline
        DispatchQueue.main.async {
            self.lock.lock(); let current = self.accepting && self.approvalEpoch == epoch; self.lock.unlock()
            if current { self.expired.removeAll { $0.room == request.room }; self.requests.append(request) }
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
        if !token.isCancelled {
            DispatchQueue.main.async {
                self.lock.lock(); let current = self.accepting && self.approvalEpoch == epoch; self.lock.unlock()
                if current { self.expired.append(request) }
            }
        }
        return false
    }
    func cancel(room: UUID? = nil) {
        if room == nil { lock.lock(); accepting = false; approvalEpoch += 1; lock.unlock() }
        let selected = requests.filter { room == nil || $0.room == room }
        for request in selected { decide(request.id, allow: false) }
        expired.removeAll { room == nil || $0.room == room }
    }
}

// A turn owns the repo, not a model. New generations revoke the previous AI's capabilities at handoff.
final class ProjectRun {
    let id = UUID(), room: UUID, binding: ProjectBinding, outer: DebateCancellation
    let started = Date()
    // Full auto runs while the user is away: up to 8 hours instead of 1 (45 minutes active).
    let fullAuto: Bool
    let deadline: Date
    var activeLimit: TimeInterval { fullAuto ? 8 * 3600 : 2700 }
    private let clock = NSLock()
    private var waitingSince: Date?
    private var waited: TimeInterval = 0
    func beginApproval() { clock.lock(); waitingSince = Date(); let report = onWaiting; clock.unlock(); report?(true) }
    func endApproval() { clock.lock(); if let date = waitingSince { waited += Date().timeIntervalSince(date) }; waitingSince = nil; let report = onWaiting; clock.unlock(); report?(false) }
    var onWaiting: ((Bool) -> Void)?   // the chat shows "waiting for approval" while a card waits
    var activeExpired: Bool { clock.lock(); defer { clock.unlock() }; return Date().timeIntervalSince(started) - waited - (waitingSince.map { Date().timeIntervalSince($0) } ?? 0) > activeLimit }
    private(set) var generation = 0
    var attempt = DebateCancellation()
    private let lifecycle = NSLock()
    private var ended = false
    func stop() { lifecycle.lock(); ended = true; lifecycle.unlock(); attempt.cancel() }
    var committed = false, pushed = false
    // Tool results for this turn's work log; the chat shows them under the reply, not above the chat.
    var onNote: (([String]) -> Void)?
    private var notes: [String] = []
    var log: [String] { clock.lock(); defer { clock.unlock() }; return notes }
    func note(_ text: String) { clock.lock(); notes = Array((notes + [text]).suffix(50)); let report = onNote, all = notes; clock.unlock(); report?(all) }
    // The work plan the chat shows: the AI's steps (work_plan, or Claude's own TodoWrite until work_plan is used),
    // then the steps the app runs itself (review, applying it). A new AI after a usage limit gets it in the checkpoint.
    var onPlan: (([WorkStep], String?) -> Void)?
    private var aiSteps: [WorkStep] = [], appSteps: [WorkStep] = [], planNote: String?, planByTool = false
    var plan: [WorkStep] { clock.lock(); defer { clock.unlock() }; return aiSteps + appSteps }
    // From an old attempt (another generation) or TodoWrite once work_plan was used: ignored.
    @discardableResult
    func setPlan(_ steps: [WorkStep], note: String?, generation: Int, tool: Bool) -> Bool {
        clock.lock()
        guard generation == self.generation, tool || !planByTool else { clock.unlock(); return false }
        if tool { planByTool = true }
        aiSteps = WorkStep.timed(Array(steps.prefix(20)), after: aiSteps); planNote = note.flatMap { $0.isEmpty ? nil : String($0.prefix(200)) }
        let report = onPlan, all = aiSteps + appSteps, why = planNote
        clock.unlock(); report?(all, why); return true
    }
    func setAppStep(_ i: Int, _ text: String, _ status: WorkStep.Status) {
        clock.lock()
        let step = WorkStep(text: text, status: status)
        if appSteps.indices.contains(i) { appSteps[i] = WorkStep.timed([step], after: [appSteps[i]])[0] } else { appSteps.append(WorkStep.timed([step], after: [])[0]) }
        let report = onPlan, all = aiSteps + appSteps, why = planNote
        clock.unlock(); report?(all, why)
    }
    // project_run's "[n/m] name" lines, shown under the AI's current step. Without one: false (the caller notes it).
    @discardableResult
    func setSub(_ text: String?) -> Bool {
        clock.lock()
        guard let i = aiSteps.firstIndex(where: { $0.status == .doing }) ?? (text == nil ? aiSteps.firstIndex { $0.sub != nil } : nil) else { clock.unlock(); return false }
        if aiSteps[i].sub == text { clock.unlock(); return true }
        aiSteps[i].sub = text; aiSteps[i].subStarted = text == nil ? nil : Date()
        let report = onPlan, all = aiSteps + appSteps, why = planNote
        clock.unlock(); report?(all, why); return true
    }
    var initialDirty: Set<String> = []
    let operations = NSRecursiveLock()
    init(room: UUID, binding: ProjectBinding, token: DebateCancellation, fullAuto: Bool = false) {
        self.room = room; self.binding = binding; self.outer = token; self.fullAuto = fullAuto
        deadline = Date().addingTimeInterval(fullAuto ? 8 * 3600 + 600 : 3600)
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
        let text = "Project: \(binding.root)\n\(note)\nHEAD: \(head)\n\(status)\n\(diff)\nCommitted: \(committed); pushed: \(pushed). Preserve unfinished files. Do not pull a dirty tree." + WorkStep.summary(plan)
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
    // A chat is writing this repository now (TODO work waits instead of failing on acquire).
    static func isHeld(_ root: String) -> Bool {
        guard let path = try? ProjectProcess.git(["rev-parse", "--git-common-dir"], root: root) else { return false }
        let common = (path.hasPrefix("/") ? URL(fileURLWithPath: path) : URL(fileURLWithPath: root).appendingPathComponent(path)).resolvingSymlinksInPath().standardizedFileURL.path
        mutex.lock(); defer { mutex.unlock() }
        return held[common] != nil
    }
    static func release(_ paths: [String]) {
        mutex.lock()
        for path in paths { if let fd = held.removeValue(forKey: path) { close(fd) } }
        mutex.unlock()
        if !paths.isEmpty { NotificationCenter.default.post(name: .projectReleased, object: nil) }
    }
}

extension Notification.Name {
    // A chat stopped writing a repository (TodoScheduler looks for the next TODO).
    static let projectReleased = Notification.Name("AIIlluminatiProjectReleased")
}

struct WorkStep: Codable, Equatable {
    enum Status: String, Codable { case todo, doing, done, blocked }
    var text: String
    var status: Status
    // Set by the app, not the AI: when the step became doing and when it ended (older chats: nil, no time shown).
    var started: Date?
    var ended: Date?
    // While a project_run command runs in this step: its current "[n/m] name" line and since when.
    var sub: String?
    var subStarted: Date?
    init(text: String, status: Status) { self.text = text; self.status = status }
    // work_plan replaces the whole list: a step keeps its times only from the earlier step with the same text.
    static func timed(_ steps: [WorkStep], after old: [WorkStep], now: Date = Date()) -> [WorkStep] {
        var unused = old
        return steps.map { step in
            var step = step
            if let i = unused.firstIndex(where: { $0.text == step.text }) {
                let before = unused.remove(at: i)
                step.started = before.started; step.ended = before.ended
                if step.status == .doing { step.sub = before.sub; step.subStarted = before.subStarted }
            }
            switch step.status {
            case .doing: if step.started == nil || step.ended != nil { step.started = step.started ?? now; step.ended = nil }
            case .done, .blocked: if step.started != nil, step.ended == nil { step.ended = now }
            case .todo: step.started = nil; step.ended = nil
            }
            if step.status != .doing { step.sub = nil; step.subStarted = nil }
            return step
        }
    }
    // For the checkpoint the next AI reads: "[done] Read the code" one per line.
    static func summary(_ steps: [WorkStep]) -> String {
        steps.isEmpty ? "" : "\nWork plan so far (continue from the first step not done; update it with work_plan):\n"
            + steps.map { "[\($0.status.rawValue)] " + $0.text }.joined(separator: "\n")
    }
}

// work_plan: the project AI's step list, shown above its reply. Only for the live attempt of a project turn.
final class PlanLink: ToolProvider {
    static let shared = PlanLink()
    var active: Bool { ProjectWork.active }
    func tools() -> [[String: Any]] { [] }
    private func live(_ context: ToolContext) -> ProjectRun? {
        guard let run = ProjectWork.get(context.projectRun), run.room == context.room, context.projectGeneration == run.generation, !run.cancelled else { return nil }
        return run
    }
    func tools(context: ToolContext) -> [[String: Any]] {
        guard live(context) != nil else { return [] }
        let step: [String: Any] = ["type": "object", "properties": ["text": ["type": "string"], "status": ["type": "string", "enum": ["todo", "doing", "done", "blocked"]]],
                                   "required": ["text", "status"], "additionalProperties": false]
        return [["name": "work_plan",
                 "description": "Show the user your step list for this task (replaces the previous list). Call it first when the work has 3 or more steps and again whenever a step starts or ends. Short steps in the user's language. Mark a test step done only after the tests pass.",
                 "inputSchema": ["type": "object", "properties": ["steps": ["type": "array", "items": step, "maxItems": 20],
                                                                   "note": ["type": "string", "description": "Why the list changed, e.g. a failing test added a step"]],
                                 "required": ["steps"], "additionalProperties": false]]]
    }
    func call(_ name: String, _ arguments: [String: Any], context: ToolContext) -> [String: Any] {
        guard name == "work_plan" else { return ToolHub.failure("Unknown tool: " + name) }
        guard let run = live(context), let generation = context.projectGeneration else { return ToolHub.failure("No live project work for this plan.") }
        guard let steps = Self.steps(arguments["steps"]) else { return ToolHub.failure("steps must be 1-20 items of {text, status: todo|doing|done|blocked}.") }
        guard run.setPlan(steps, note: arguments["note"] as? String, generation: generation, tool: true) else { return ToolHub.failure("This plan belongs to an earlier attempt.") }
        return ["content": [["type": "text", "text": "Plan shown: \(steps.filter { $0.status == .done }.count)/\(steps.count) done."]], "isError": false]
    }
    static func steps(_ value: Any?) -> [WorkStep]? {
        guard let items = value as? [[String: Any]], (1...20).contains(items.count) else { return nil }
        var steps: [WorkStep] = []
        for item in items {
            let text = (item["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, let status = (item["status"] as? String).flatMap(WorkStep.Status.init(rawValue:)) else { return nil }
            steps.append(WorkStep(text: String(text.prefix(200)), status: status))
        }
        return steps
    }
    // Claude's own TodoWrite list (full auto): pending / in_progress / completed.
    static func todos(_ value: Any?) -> [WorkStep]? {
        guard let items = value as? [[String: Any]], !items.isEmpty else { return nil }
        let steps = items.compactMap { item -> WorkStep? in
            guard let text = item["content"] as? String, !text.isEmpty else { return nil }
            let status: WorkStep.Status = item["status"] as? String == "completed" ? .done : item["status"] as? String == "in_progress" ? .doing : .todo
            return WorkStep(text: String(text.prefix(200)), status: status)
        }
        return steps.isEmpty ? nil : Array(steps.prefix(20))
    }
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
            run.note(name + " → " + String(output.prefix(180)))
            return ["content": [["type": "text", "text": output]], "isError": false]
        } catch { _ = run.checkpoint(name + " failed: " + String(error.localizedDescription.prefix(500))); run.note(name + " failed"); return ToolHub.failure(error.localizedDescription) }
    }
    private func execute(_ name: String, _ args: [String: Any], _ run: ProjectRun, _ generation: Int) throws -> String {
        func git(_ argv: [String], timeout: TimeInterval = 120) throws -> String { try run.validate(generation); return try ProjectProcess.git(argv, root: run.binding.root, token: run.attempt, timeout: min(timeout, run.deadline.timeIntervalSinceNow)) }
        func clean() throws { guard try git(["status", "--porcelain"]).isEmpty else { throw MaterialReader.error("Working tree is not clean; preserve edits and do not pull/switch/stash.") } }
        func approve(_ title: String, _ detail: String) throws {
            run.beginApproval(); defer { run.endApproval() }
            let deadline = min(run.deadline, Date().addingTimeInterval(900))
            guard ProjectCenter.shared.approve(ProjectApproval(room: run.room, run: run.id, title: title, detail: detail), token: run.attempt, deadline: deadline) else {
                // 15 minutes unanswered counts as no: the user is away. The chat keeps a note with Ask again.
                if Date() >= deadline, !run.attempt.isCancelled { throw MaterialReader.error("Project approval timed out after 15 minutes; treated as refused. Stop and tell the user they can ask again.") }
                throw MaterialReader.error("Project approval refused or cancelled.")
            }
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
            if !run.fullAuto, paths.contains(where: { path in run.initialDirty.contains(where: { dirty in path == "." || dirty == path || dirty.hasPrefix(path + "/") }) }) { try approve("기존 변경 포함 / Include existing edits", diff) }
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
            if run.fullAuto { run.note("project_run (full auto): " + exe + " " + argv.joined(separator: " ")) }
            else { try approve("프로젝트 실행 / Run project command", "Runs outside the AI sandbox as your user.\n" + run.binding.root + "\n" + exe + " " + argv.joined(separator: " ") + "\n" + status) }
            guard try Data(contentsOf: url) == data, try WorkspaceBackup.stamps([WorkspaceRoot(path: run.binding.root, directory: true)]) == tree else { throw MaterialReader.error("Command changed after approval. Request it again.") }
            // "[n/m] name" lines show under the current step; their times go to project-timings for later estimates.
            let progress = RunProgress(command: selected) { text in if !run.setSub(text) { run.note(text) } }
            defer { run.setSub(nil) }
            let deadline = min(run.deadline, Date().addingTimeInterval(2700))
            do {
                let reply = try ProjectProcess.run(exe, argv, cwd: run.binding.root, token: run.attempt, deadline: deadline, guarded: run.fullAuto,
                                                   onLine: progress.line)
                RunTimings.record(root: run.binding.root, command: selected, progress.finish(reply.status == 0 ? "ok" : "failed", exit: reply.status))
                return "exit=\(reply.status)\n" + reply.output
            } catch {
                RunTimings.record(root: run.binding.root, command: selected, progress.finish(RunProgress.outcome(timedOut: Date() >= deadline || run.activeExpired, stopped: run.outer.isCancelled || run.attempt.isCancelled), exit: nil))
                throw error
            }
        default: throw MaterialReader.error("Unknown project tool.")
        }
    }
}

// One project_run command's "[n/m] name" lines (the test and build scripts print them before each stage).
final class RunProgress {
    let command: String
    private let show: (String) -> Void
    private let lock = NSLock(), start = Date()
    private var open = true, current: (name: String, at: Date)?, stages: [[String: Any]] = []
    init(command: String, show: @escaping (String) -> Void) { self.command = command; self.show = show }
    // A stage line is shown as "test [5/9] Compile app tests". Lines after the command ended are ignored.
    func line(_ line: String) {
        guard let (n, total, name) = Self.stage(line) else { return }
        lock.lock(); defer { lock.unlock() }
        guard open else { return }
        let now = Date()
        if let current { stages.append(["name": current.name, "seconds": (now.timeIntervalSince(current.at) * 10).rounded() / 10]) }
        current = (name, now)
        show("\(command) [\(n)/\(total)] \(name)")  // under the lock, so no stage appears after finish
    }
    static func stage(_ line: String) -> (Int, Int, String)? {
        guard line.hasPrefix("["), let close = line.firstIndex(of: "]") else { return nil }
        let count = line[line.index(after: line.startIndex)..<close].split(separator: "/")
        let name = line[line.index(after: close)...].trimmingCharacters(in: .whitespaces)
        guard count.count == 2, let n = Int(count[0]), let total = Int(count[1]), total >= 1, total <= 100, (1...total).contains(n), !name.isEmpty else { return nil }
        return (n, total, String(name.prefix(80)))
    }
    // A command that threw: out of time (its own or the turn's), stopped (the user, or a handoff), or it could not run.
    static func outcome(timedOut: Bool, stopped: Bool) -> String { timedOut ? "timeout" : stopped ? "stopped" : "error" }
    func finish(_ outcome: String, exit: Int32?) -> [String: Any] {
        lock.lock(); defer { lock.unlock() }
        let now = Date()
        if let current, open { stages.append(["name": current.name, "seconds": (now.timeIntervalSince(current.at) * 10).rounded() / 10]) }
        open = false; current = nil
        var entry: [String: Any] = ["at": ISO8601DateFormatter().string(from: start), "seconds": (now.timeIntervalSince(start) * 10).rounded() / 10,
                                    "outcome": outcome, "stages": stages]
        if let exit { entry["exit"] = Int(exit) }
        return entry
    }
}

// project-timings/<sha256 of the project root>.json: {"test": [last 20 runs], "build": [...]}, for a later "usually about 4 min".
enum RunTimings {
    private static let lock = NSLock()
    static func file(_ root: String) -> URL {
        let name = SHA256.hash(data: Data(root.utf8)).map { String(format: "%02x", $0) }.joined()
        return URL(fileURLWithPath: AccountStore.supportDir).appendingPathComponent("project-timings", isDirectory: true).appendingPathComponent(name + ".json")
    }
    static func record(root: String, command: String, _ entry: [String: Any]) {
        lock.lock(); defer { lock.unlock() }
        let url = file(root)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var all = (try? Data(contentsOf: url)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        all[command] = Array(((all[command] as? [[String: Any]]) ?? []) + [entry]).suffix(20).map { $0 }
        if let data = try? JSONSerialization.data(withJSONObject: all, options: [.sortedKeys]) { try? data.write(to: url, options: .atomic) }
    }
}

// Full auto (the user is away): the AI gets every tool without approval cards, but cannot destroy the backups.
// - No Git or GitHub credentials in its environment: pushes go through git_push (main/feature, never force)
//   and git_publish_stable (always an approval card). A `git` shim refuses push and history rewrites.
// - An `rm` shim moves files to the Trash instead of deleting them (temporary folders are deleted normally).
// Limits: a deliberate script could still call /bin/rm or read Keychain items; this guards mistakes, not malice.
enum AutoGuard {
    static let claudeDenied = ["Bash(git push:*)", "Bash(git filter-branch:*)", "Bash(git filter-repo:*)", "Bash(/usr/bin/git push:*)",
                               "Bash(gh repo delete:*)", "Bash(/bin/rm:*)", "Bash(git clean:*)"]
    static var folder: URL { URL(fileURLWithPath: AccountStore.supportDir).appendingPathComponent("auto-guard", isDirectory: true) }

    static let gitShim = """
    #!/bin/bash
    # AI Illuminati full auto: Git without push or history rewrites. Use the app's git_push tool.
    i=1; sub=""
    while [ $i -le $# ]; do
      a="${!i}"
      case "$a" in
        -C|-c|--git-dir|--work-tree|--namespace|--exec-path) i=$((i+2)); continue;;
        -*) i=$((i+1)); continue;;
        *) sub="$a"; break;;
      esac
    done
    case "$sub" in
      push|filter-branch|filter-repo|send-pack)
        echo "AI Illuminati full auto: 'git $sub' is blocked here. Use the git_push tool (main or feature branches; stable needs the user's approval)." >&2
        exit 1;;
    esac
    exec /usr/bin/git "$@"
    """

    static let rmShim = """
    #!/bin/bash
    # AI Illuminati full auto: rm moves files to the Trash (recoverable). Temporary folders are deleted normally.
    force=0; ended=0; files=()
    for a in "$@"; do
      if [ $ended -eq 0 ] && [ "$a" = "--" ]; then ended=1; continue; fi
      if [ $ended -eq 0 ] && [ "${a#-}" != "$a" ] && [ "$a" != "-" ]; then case "$a" in *f*) force=1;; esac; continue; fi
      files+=("$a")
    done
    tmp="${TMPDIR:-/tmp}"; status=0
    for f in "${files[@]}"; do
      if [ ! -e "$f" ] && [ ! -L "$f" ]; then
        [ $force -eq 1 ] || { echo "rm: $f: No such file or directory" >&2; status=1; }
        continue
      fi
      full="$(cd "$(dirname "$f")" 2>/dev/null && pwd -P)/$(basename "$f")"
      case "$full" in
        /tmp/*|/private/tmp/*|/var/folders/*|/private/var/folders/*|"${tmp%/}"/*) /bin/rm -rf -- "$f" || status=1; continue;;
      esac
      if [ -x /usr/bin/trash ]; then /usr/bin/trash "$f" >/dev/null 2>&1 || status=1
      else mkdir -p "$HOME/.Trash" && mv -- "$f" "$HOME/.Trash/$(basename "$f").$(date +%s).$$" || status=1; fi
    done
    exit $status
    """

    static func environment(_ base: [String: String]) -> [String: String] {
        var env = base
        let bin = folder.appendingPathComponent("bin", isDirectory: true)
        let gh = folder.appendingPathComponent("gh-empty", isDirectory: true)
        let fm = FileManager.default
        try? fm.createDirectory(at: bin, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? fm.createDirectory(at: gh, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        for (name, text) in [("git", gitShim), ("rm", rmShim)] {
            let url = bin.appendingPathComponent(name)
            if (try? String(contentsOf: url, encoding: .utf8)) != text {
                try? text.write(to: url, atomically: true, encoding: .utf8)
            }
            try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        }
        env["PATH"] = bin.path + ":" + (base["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin")
        // No credentials: an empty helper list, no prompts, no SSH keys, and an empty GitHub CLI login.
        env["GIT_CONFIG_COUNT"] = "2"; env["GIT_CONFIG_KEY_0"] = "credential.helper"; env["GIT_CONFIG_VALUE_0"] = ""
        env["GIT_CONFIG_KEY_1"] = "credential.https://github.com.helper"; env["GIT_CONFIG_VALUE_1"] = ""
        env["GIT_TERMINAL_PROMPT"] = "0"; env["GIT_ASKPASS"] = "/usr/bin/false"; env["SSH_ASKPASS"] = "/usr/bin/false"
        env["GIT_SSH_COMMAND"] = "/usr/bin/ssh -o BatchMode=yes -o IdentitiesOnly=yes -i /dev/null"
        env["GH_CONFIG_DIR"] = gh.path
        for key in ["GH_TOKEN", "GITHUB_TOKEN", "GH_ENTERPRISE_TOKEN", "SSH_AUTH_SOCK"] { env.removeValue(forKey: key) }
        return env
    }
}
