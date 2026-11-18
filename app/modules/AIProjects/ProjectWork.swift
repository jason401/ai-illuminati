import Cocoa
import CryptoKit
import Darwin
import AIAccounts
import AILocalization
import AIRuntime
import AIWorkspace

// The same NSError as the folder rules' (domain Materials, code 1): callers show the text as it is.
enum ProjectError {
    static func make(_ text: String) -> NSError { NSError(domain: "Materials", code: 1, userInfo: [NSLocalizedDescriptionKey: text]) }
}
// A failed tool call, as the tool gateway sends it back to the AI.
enum ProjectTools {
    static func failure(_ text: String) -> [String: Any] { ["content": [["type": "text", "text": text]], "isError": true] }
}
extension ProjectBinding {
    // One project across its worktrees (the Git common folder; else the root): the sidebar folder, TODO locks, project info.
    public var groupKey: String { common.isEmpty ? root : common }
}

// All privileged commands use fixed argv, closed stdin, bounded output and a cancellable process group.
public enum ProjectProcess {
    public struct Reply { public var status: Int32; public var output: String }
    public static func run(_ executable: String, _ args: [String], cwd: String, token: DebateCancellation? = nil,
                    deadline: Date = Date().addingTimeInterval(60), guarded: Bool = false, extra: [String: String] = [:],
                    onLine: ((String) -> Void)? = nil) throws -> Reply {
        if token?.isCancelled == true { throw ProjectError.make("Project operation cancelled.") }
        let p = Process(), out = Pipe(), err = Pipe(), lock = NSLock(), done = DispatchGroup()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        p.arguments = [WorkspaceInvocation.resources.appendingPathComponent("project_process.py").path, executable] + args
        p.currentDirectoryURL = URL(fileURLWithPath: cwd)
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_TERMINAL_PROMPT"] = "0"; environment["GIT_SSH_COMMAND"] = "/usr/bin/ssh -o BatchMode=yes"
        environment["AI_ILLUMINATI_PROJECT_PROCESS"] = "1"
        if guarded { environment = FullAutoGuard.environment(environment) }
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
            throw ProjectError.make("Could not start project command.")
        }
        token?.attach(p)
        defer { token?.detach(p); kill(-p.processIdentifier, SIGKILL) }
        while p.isRunning {
            if token?.isCancelled == true || Date() >= deadline {
                DebateCancellation.end(p); p.waitUntilExit()
                _ = done.wait(timeout: .now() + 2)
                throw ProjectError.make("Project command stopped or timed out; inspect Git state before retrying.")
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        kill(-p.processIdentifier, SIGKILL) // Remove background writers even after their parent has exited.
        guard done.wait(timeout: .now() + 3) == .success else { throw ProjectError.make("Project child process did not finish.") }
        guard token?.isCancelled != true, Date() < deadline else { throw ProjectError.make("Project command stopped or timed out.") }
        lock.lock(); let text = String(decoding: captured, as: UTF8.self); lock.unlock()
        return Reply(status: p.terminationStatus, output: String(text.prefix(60_000)))
    }
    // A named Step command may execute project code. Keep its descendants inside the same write boundary as the Step.
    static func runStep(_ executable: String, _ args: [String], project: ProjectBinding, token: DebateCancellation,
                        deadline: Date, onLine: @escaping (String) -> Void) throws -> Reply {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("ai-step-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: scratch) }
        // Seatbelt matches physical paths, including the /private prefix skipped by Foundation for /tmp.
        func physical(_ path: String) throws -> String {
            guard let resolved = realpath(path, nil) else { throw ProjectError.make("Could not resolve Step sandbox path: " + path) }
            defer { free(resolved) }
            return String(cString: resolved)
        }
        let root = try physical(project.root), temp = try physical(scratch.path)
        let gitFile = try physical(project.root + "/.git"), common = try physical(project.common)
        let profile = """
        (version 1)
        (allow default)
        (deny network* mach-lookup appleevent-send)
        (deny file-write*
            (require-not (require-any (subpath (param "STEP_ROOT")) (subpath (param "STEP_TEMP")) (literal "/dev/null"))))
        (deny file-write* (subpath (param "STEP_GIT")) (subpath (param "STEP_COMMON")))
        """
        return try run("/usr/bin/sandbox-exec", ["-D", "STEP_ROOT=" + root, "-D", "STEP_TEMP=" + temp,
                       "-D", "STEP_GIT=" + gitFile, "-D", "STEP_COMMON=" + common,
                       "-p", profile, executable] + args, cwd: project.root, token: token, deadline: deadline,
                       guarded: true, extra: ["TMPDIR": temp, "TMPPREFIX": temp + "/zsh"], onLine: onLine)   // zsh's here-documents: TMPPREFIX, not TMPDIR
    }
    public static func git(_ args: [String], root: String, token: DebateCancellation? = nil, timeout: TimeInterval = 60) throws -> String {
        let reply = try gitReply(args, root: root, token: token, timeout: timeout)
        guard reply.status == 0 else { throw ProjectError.make("git failed (\(reply.status)): \(reply.output)") }
        return reply.output.trimmingCharacters(in: .newlines)
    }
    // The same command with its exit status, for Git answers that use it (merge-tree's 1 = conflicts, is-ancestor's 1 = no).
    static func gitReply(_ args: [String], root: String, token: DebateCancellation? = nil, timeout: TimeInterval = 60) throws -> Reply {
        try run("/usr/bin/git", ["--literal-pathspecs", "-c", "core.hooksPath=/dev/null", "-c", "core.fsmonitor=false", "-c", "submodule.recurse=false"] + args,
                cwd: root, token: token, deadline: Date().addingTimeInterval(timeout))
    }
    public static func inspect(_ path: String) throws -> ProjectBinding {
        let root = try git(["rev-parse", "--show-toplevel"], root: path)
        let canonical = URL(fileURLWithPath: root).resolvingSymlinksInPath().standardizedFileURL.path
        guard canonical == URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path else { throw ProjectError.make("Link the repository's top-level folder.") }
        let common = try git(["rev-parse", "--git-common-dir"], root: canonical)
        let commonURL = (common.hasPrefix("/") ? URL(fileURLWithPath: common) : URL(fileURLWithPath: canonical).appendingPathComponent(common)).resolvingSymlinksInPath().standardizedFileURL.path
        let remote = try git(["remote", "get-url", "origin"], root: canonical)
        guard URLComponents(string: remote)?.password == nil else { throw ProjectError.make("Remove embedded credentials from the Git remote URL first.") }
        return ProjectBinding(root: canonical, common: commonURL, remote: "origin", remoteURL: remote)
    }
    // A documents project: a folder that is not inside a Git work tree (a Git folder is linked as a code project).
    // Not the home folder, a top folder or the app's own data, so a backup before each answer stays reasonable.
    public static func documents(_ path: String) throws -> ProjectBinding {
        let canonical = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
        var folder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: canonical, isDirectory: &folder), folder.boolValue else {
            throw ProjectError.make(L("문서 폴더가 없어요: ", "The documents folder does not exist: ") + canonical)
        }
        let home = URL(fileURLWithPath: NSHomeDirectory()).resolvingSymlinksInPath().standardizedFileURL.path
        let support = URL(fileURLWithPath: AccountStore.supportDir).resolvingSymlinksInPath().standardizedFileURL.path
        let top = ["/", "/Users", "/Volumes", "/Applications", "/System", "/Library", home, home + "/Documents", home + "/Desktop", home + "/Downloads", home + "/Library"]
        guard !top.contains(canonical), canonical.split(separator: "/").count >= 2,
              support != canonical, !support.hasPrefix(canonical + "/"), !canonical.hasPrefix(support + "/") else {
            throw ProjectError.make(L("너무 큰 폴더예요. 논문·발표 하나의 폴더를 골라 주세요.", "That folder is too big. Pick the folder of one paper or talk."))
        }
        if isGitWorkTree(canonical) {
            throw ProjectError.make(L("이 폴더는 Git 저장소 안에 있어요. 코드 프로젝트로 연결하거나 Git 밖의 폴더를 골라 주세요.",
                                         "This folder is inside a Git repository. Link it as a code project, or pick a folder outside Git."))
        }
        return ProjectBinding(root: canonical, common: canonical, remote: "", remoteURL: "", kind: ProjectBinding.documentsKind)
    }
    // Inside a Git work tree (also one without origin, or a subfolder of one). Any other git error: not Git.
    static func isGitWorkTree(_ path: String) -> Bool {
        (try? git(["rev-parse", "--is-inside-work-tree"], root: path)) == "true"
    }
    // The binding as it is now on disk, for the check before each tool call: documents stay documents only while
    // the folder exists and is still not Git.
    static func current(_ binding: ProjectBinding) throws -> ProjectBinding {
        if binding.isFolderless {
            let parent = URL(fileURLWithPath: AccountStore.supportDir).appendingPathComponent("folderless-projects").resolvingSymlinksInPath().path
            let url = URL(fileURLWithPath: binding.root)
            var directory: ObjCBool = false
            guard url.deletingLastPathComponent().path == parent,
                  UUID(uuidString: url.lastPathComponent) != nil,
                  url.resolvingSymlinksInPath().path == binding.root,
                  binding.common == binding.root, binding.remote.isEmpty, binding.remoteURL.isEmpty,
                  FileManager.default.fileExists(atPath: binding.root, isDirectory: &directory), directory.boolValue else {
                throw ProjectError.make("Invalid folderless project workspace.")
            }
            return binding
        }
        return binding.isDocuments ? try documents(binding.root) : try inspect(binding.root)
    }
}

public struct ProjectApproval: Identifiable {
    public let id = UUID()
    public var room: UUID
    var run: UUID
    public var title: String
    public var detail: String
    public var created = Date()
    public var deadline: Date?
    public var alwaysAllow: (() -> Void)? = nil   // an outside MCP tool: the card also offers "Always allow"
    // A project_run card: the command line, and its CommandIdentity key, so a sub-room's request for the very same command
    // can be allowed once for its split (docs/SUBROOM_PLAN.md 7).
    public var command: String? = nil
    public var same: String? = nil
    public init(room: UUID, run: UUID, title: String, detail: String, created: Date = Date(), deadline: Date? = nil, alwaysAllow: (() -> Void)? = nil) {
        self.room = room; self.run = run; self.title = title; self.detail = detail; self.created = created; self.deadline = deadline; self.alwaysAllow = alwaysAllow
    }
}
// One list for every place that shows approvals: the chat card, the banner, the menu bar, the approval
// window and the macOS notification all follow `requests`, so deciding in one place clears them all.
public final class ProjectCenter: ObservableObject {
    public static let shared = ProjectCenter()
    @Published public var requests: [ProjectApproval] = []
    // Requests that ran out of time (counted as refused); the chat keeps a note with Ask again until dismissed.
    @Published public var expired: [ProjectApproval] = []
    public func dismiss(_ id: UUID) { expired.removeAll { $0.id == id } }
    private let lock = NSLock()
    private var decisions: [UUID: Bool] = [:]
    private var accepting = true
    private var approvalEpoch = 0
    public func resume() { lock.lock(); accepting = true; lock.unlock() }
    public func decide(_ id: UUID, allow: Bool) { guard requests.contains(where: { $0.id == id }) else { return }; lock.lock(); decisions[id] = allow; lock.unlock(); requests.removeAll { $0.id == id } }
    // Asked on the requesting thread before a card is shown: true means the user already allowed this very request
    // (a sub-room's command allowed for its split). No card then.
    public var preapproved: ((ProjectApproval) -> Bool)?
    public func approve(_ request: ProjectApproval, token: DebateCancellation, deadline: Date) -> Bool {
        lock.lock(); let enabled = accepting, epoch = approvalEpoch, given = preapproved; lock.unlock()
        guard enabled else { return false }
        if let given, given(request) { return true }
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
    public func cancel(room: UUID? = nil) {
        if room == nil { lock.lock(); accepting = false; approvalEpoch += 1; lock.unlock() }
        let selected = requests.filter { room == nil || $0.room == room }
        for request in selected { decide(request.id, allow: false) }
        expired.removeAll { room == nil || $0.room == room }
    }
}

// A turn owns the repo, not a model. New generations revoke the previous AI's capabilities at handoff.
public final class ProjectRun {
    public let id = UUID(), room: UUID, binding: ProjectBinding, outer: DebateCancellation
    let started = Date()
    // Full auto runs while the user is away: up to 8 hours instead of 1 (45 minutes active).
    let fullAuto: Bool
    // A sub-room's turn (docs/SUBROOM_PLAN.md 4): it works on its own sub/ branch, so its Git tools leave out push, pull,
    // publish and branch changes; the app merges its reported commit.
    public var isSubRoom = false
    public let deadline: Date
    var activeLimit: TimeInterval { fullAuto ? 8 * 3600 : 2700 }
    private let clock = NSLock()
    private var waitingSince: Date?
    private var waited: TimeInterval = 0
    func beginApproval() { clock.lock(); waitingSince = Date(); let report = onWaiting; clock.unlock(); report?(true) }
    func endApproval() { clock.lock(); if let date = waitingSince { waited += Date().timeIntervalSince(date) }; waitingSince = nil; let report = onWaiting; clock.unlock(); report?(false) }
    public var onWaiting: ((Bool) -> Void)?   // the chat shows "waiting for approval" while a card waits
    public var activeExpired: Bool { clock.lock(); defer { clock.unlock() }; return Date().timeIntervalSince(started) - waited - (waitingSince.map { Date().timeIntervalSince($0) } ?? 0) > activeLimit }
    public private(set) var generation = 0
    public var attempt = DebateCancellation()
    private let lifecycle = NSLock()
    private var ended = false
    func stop() { lifecycle.lock(); ended = true; lifecycle.unlock(); attempt.cancel() }
    public var committed = false, pushed = false
    // A project turn pushes once, after the review and its fixes: git_push only asks for it, and the chat calls
    // GitLink.pushDeferred when the turn ends well. Without a successful end the commits stay local (a TODO retries).
    private var defersPush = false
    public var deferPush: Bool {
        get { defersPush }
        set { defersPush = newValue && !isStep }
    }
    public var isStep: Bool { stepBranch != nil }
    private let stepBranch: String?
    fileprivate var stepLease: [String] = []
    public internal(set) var pushWanted = false
    // Tool results for this turn's work log; the chat shows them under the reply, not above the chat.
    public var onNote: (([String]) -> Void)?
    private var notes: [String] = []
    public var log: [String] { clock.lock(); defer { clock.unlock() }; return notes }
    public func note(_ text: String) { clock.lock(); notes = Array((notes + [text]).suffix(50)); let report = onNote, all = notes; clock.unlock(); report?(all) }
    // The work plan the chat shows: the AI's steps (work_plan, or Claude's own TodoWrite until work_plan is used),
    // then the steps the app runs itself (review, applying it). A new AI after a usage limit gets it in the checkpoint.
    public var onPlan: (([WorkStep], String?) -> Void)?
    private var aiSteps: [WorkStep] = [], appSteps: [WorkStep] = [], planNote: String?, planByTool = false
    var plan: [WorkStep] { clock.lock(); defer { clock.unlock() }; return aiSteps + appSteps }
    // The AI's own task list as its stream sent it (StreamParser's `.todos`, Claude's TodoWrite): read here, so the chat
    // hands it on without knowing its shape (C0). Nothing readable: no change.
    @discardableResult
    public func setPlan(todos: Any?, generation: Int) -> Bool {
        guard let steps = PlanLink.todos(todos) else { return false }
        return setPlan(steps, note: nil, generation: generation, tool: false)
    }
    // From an old attempt (another generation) or TodoWrite once work_plan was used: ignored.
    @discardableResult
    public func setPlan(_ steps: [WorkStep], note: String?, generation: Int, tool: Bool) -> Bool {
        clock.lock()
        guard generation == self.generation, tool || !planByTool else { clock.unlock(); return false }
        if tool { planByTool = true }
        aiSteps = WorkStep.timed(Array(steps.prefix(20)), after: aiSteps); planNote = note.flatMap { $0.isEmpty ? nil : String($0.prefix(200)) }
        let report = onPlan, all = aiSteps + appSteps, why = planNote
        clock.unlock(); report?(all, why); return true
    }
    public func setAppStep(_ i: Int, _ text: String, _ status: WorkStep.Status) {
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
    public convenience init(room: UUID, binding: ProjectBinding, token: DebateCancellation, fullAuto: Bool = false) {
        self.init(room: room, binding: binding, token: token, fullAuto: fullAuto, stepBranch: nil)
    }
    fileprivate init(room: UUID, binding: ProjectBinding, token: DebateCancellation, fullAuto: Bool, stepBranch: String?) {
        self.room = room; self.binding = binding; self.outer = token; self.fullAuto = fullAuto; self.stepBranch = stepBranch
        deadline = Date().addingTimeInterval(fullAuto ? 8 * 3600 + 600 : 3600)
        let status = binding.isDocuments ? "" : (try? ProjectProcess.git(["status", "--porcelain", "-z"], root: binding.root)) ?? ""
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
    public func nextAttempt() { attempt.cancel(); operations.lock(); defer { operations.unlock() }; ProjectWork.revokeTools(id); generation += 1; attempt = DebateCancellation(); if outer.isCancelled || Date() >= deadline || activeExpired { attempt.cancel() } }
    // An attempt is over: its commands and the AI's programs finish, and its tool sessions end, before another AI can write.
    public func endAttempt() { attempt.cancel(); ProjectWork.revokeTools(id) }
    var cancelled: Bool { outer.isCancelled || attempt.isCancelled || Date() >= deadline || activeExpired }
    public func validate(_ generation: Int) throws {
        guard !cancelled, generation == self.generation else { throw ProjectError.make("Project capability expired or operation cancelled.") }
        guard try ProjectProcess.current(binding) == binding else { throw ProjectError.make("Project repository or remote changed. Reconnect it first.") }
        if let stepBranch {
            let head = try ProjectProcess.gitReply(["symbolic-ref", "--quiet", "HEAD"], root: binding.root, token: attempt)
            guard head.status == 0 || (head.status == 1 && head.output.isEmpty) else {
                throw ProjectError.make(L("Step의 HEAD를 확인하지 못했어요.", "Could not read the Step's HEAD.") + "\n" + head.output)
            }
            guard head.status == 0, head.output.trimmingCharacters(in: .newlines) == "refs/heads/" + stepBranch else {
                throw ProjectError.make(L("Step은 Goal 브랜치에서만 실행할 수 있어요.", "A Step can only run on its Goal branch."))
            }
        }
    }
    public func checkpoint(_ note: String) -> String {
        if binding.isFolderless {
            let text = "Folderless project. No core folder or Git repository is linked. Artifacts belong in the chat folder.\n" + note + WorkStep.summary(plan)
            save(checkpoint: text)
            return text
        }
        if binding.isDocuments {
            let text = "Documents project: \(binding.root)\n\(note)\nNo Git: the app backed the folder up before this answer (Undo). Keep unfinished files; do not redo finished steps." + WorkStep.summary(plan)
            save(checkpoint: text)
            return text
        }
        let head = (try? ProjectProcess.git(["rev-parse", "HEAD"], root: binding.root)) ?? ""
        let status = (try? ProjectProcess.git(["status", "--short"], root: binding.root)) ?? ""
        let diff = (try? ProjectProcess.git(["diff", "--no-ext-diff", "--no-textconv", "--stat"], root: binding.root)) ?? ""
        let text = "Project: \(binding.root)\n\(note)\nHEAD: \(head)\n\(status)\n\(diff)\nCommitted: \(committed); pushed: \(pushed)\(pushWanted && !pushed ? " (push requested; the app pushes at the end of this turn)" : ""). Preserve unfinished files. Do not pull a dirty tree." + WorkStep.summary(plan)
        save(checkpoint: text)
        return text
    }
    private func save(checkpoint text: String) {
        let base = URL(fileURLWithPath: AccountStore.supportDir).appendingPathComponent("project-work", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? text.write(to: base.appendingPathComponent(id.uuidString + ".txt"), atomically: true, encoding: .utf8)
    }
}

public enum ProjectWork {
    private static let mutex = NSLock()
    private static var held: [String: Int32] = [:]
    private static var runs: [UUID: ProjectRun] = [:]
    // Ends the tool sessions of a run's earlier attempts (ToolHub sets it when it starts; before that there are none).
    private static var revoker: (UUID) -> Void = { _ in }
    public static var revokeTools: (UUID) -> Void {
        get { mutex.lock(); defer { mutex.unlock() }; return revoker }
        set { mutex.lock(); revoker = newValue; mutex.unlock() }
    }
    // Another chat holds the folder (TodoScheduler.settle retries without counting an attempt).
    public static let busyKorean = "다른 AI가 지금 이 폴더를 고치는 중이에요. 끝나면 다시 시켜 주세요. 회의(/m)나 의견(/a, /1)은 지금도 돼요."
    public static let busyEnglish = "Another AI is changing this folder now. Ask again when it finishes; a meeting (/m) or opinions (/a, /1) work now."
    // Also the texts saved before the lock went per work tree (chat turns, todos.json errors).
    private static let busyBefore = ["다른 AI가 지금 이 프로젝트를 고치는 중이에요.", "Another AI is changing this project now.", "Another AI is writing", "Repository is busy", "Folder is busy"]
    public static func isBusy(_ error: String) -> Bool {
        error.contains(busyKorean) || error.contains(busyEnglish) || busyBefore.contains { error.contains($0) }
    }
    public static var active: Bool { mutex.lock(); defer { mutex.unlock() }; return !runs.isEmpty }
    static func get(_ id: UUID?) -> ProjectRun? { mutex.lock(); defer { mutex.unlock() }; return id.flatMap { runs[$0] } }
    // The project turn a tool call belongs to, while that AI's attempt is current (another module's tools: sub-rooms).
    public static func run(for context: ToolContext) -> ProjectRun? {
        guard let run = get(context.projectRun), run.room == context.room, context.projectGeneration == run.generation, !run.cancelled else { return nil }
        return run
    }
    // What the working AI gets: write and execute, writable only in the project's root and the chat's own folder.
    public static func workBinding(_ binding: WorkspaceBinding, project: ProjectBinding, chatFolder: String, run: ProjectRun) -> WorkspaceBinding {
        var workspace = binding
        workspace.level = .execute
        workspace.roots = binding.roots.map { WorkspaceRoot(path: $0.path, directory: $0.directory, writable: ($0.path == project.root || $0.path == chatFolder) ? true : nil) }
        workspace.projectRunID = run.id
        return workspace
    }
    // The Goal runner supplies the tree from SubWork.goal. The Step owns its lease through finish().
    public static func startStep(_ tree: SubWork.Tree, in binding: WorkspaceBinding, chatFolder: String,
                                 room: UUID, token: DebateCancellation) throws -> (run: ProjectRun, workspace: WorkspaceBinding) {
        guard let source = binding.project, !source.isDocuments else { throw ProjectError.make("A Step requires a Git project.") }
        let project = try ProjectProcess.inspect(tree.path)
        let chatPath = canonical(chatFolder)
        guard project.common == source.common,
              project.remote == source.remote, project.remoteURL == source.remoteURL,
              tree.branch.range(of: "^todo-goal/[0-9a-f]{8}$", options: .regularExpression) != nil,
              project.root == canonical(SubWork.folder(common: source.common, name: "goal-" + tree.branch.suffix(8))),
              !overlaps(project.root, source.root), !overlaps(chatPath, source.root),
              !overlaps(chatPath, project.root) else {
            throw ProjectError.make(L("이 프로젝트의 Goal worktree가 필요해요.", "This project’s Goal worktree is required."))
        }
        let goalRoot = WorkspaceRoot(path: project.root, directory: true, writable: true)
        let lease = try acquire(WorkspaceBinding(roots: [goalRoot], level: .write))
        let run = ProjectRun(room: room, binding: project, token: token, fullAuto: binding.isFullAuto, stepBranch: tree.branch)
        run.stepLease = lease
        do { try run.validate(run.generation) }
        catch { finish(run); throw error }

        var workspace = binding
        workspace.project = project
        workspace.roots.removeAll { canonical($0.path) == project.root }
        if !workspace.roots.contains(where: { canonical($0.path) == source.root }) {
            workspace.roots.append(WorkspaceRoot(path: source.root, directory: true))
        }
        workspace.roots.append(goalRoot)
        workspace = workBinding(workspace, project: project, chatFolder: chatFolder, run: run)
        workspace.level = .write
        workspace.fullAccess = false; workspace.fullAuto = false
        return (run, workspace)
    }
    // A chat linking `project` (the + menu): its root writable, added after the folders linked already (a code project) or
    // put first (`first`: a documents project, whose root then leads); the chat's other folders stay.
    public static func linking(_ workspace: WorkspaceBinding?, to project: ProjectBinding, first: Bool) -> WorkspaceBinding {
        var binding = workspace ?? WorkspaceBinding(roots: [])
        let root = WorkspaceRoot(path: project.root, directory: true, writable: true)
        if first {
            binding.roots.removeAll { $0.path == project.root }
            binding.roots.insert(root, at: 0)
        } else if !binding.roots.contains(where: { $0.path == project.root }) {
            binding.roots.append(root)
        }
        binding.project = project
        return binding
    }
    // A chat moved into `project` (the sidebar): the old project's root goes, the new one's linked roots come first, and
    // no earlier project run stays attached.
    public static func moving(_ workspace: WorkspaceBinding?, to project: ProjectBinding) -> WorkspaceBinding {
        var binding = workspace ?? WorkspaceBinding(roots: [])
        let old = binding.project?.root
        binding.roots.removeAll { $0.path == old || $0.path == project.root }
        binding.roots.insert(contentsOf: project.linkedRoots, at: 0)
        binding.project = project
        binding.projectRunID = nil; binding.projectGeneration = nil
        return binding
    }
    public static func register(_ run: ProjectRun) { mutex.lock(); runs[run.id] = run; mutex.unlock() }
    public static func finish(_ run: ProjectRun) {
        run.stop()
        run.operations.lock()
        revokeTools(run.id)
        mutex.lock(); runs.removeValue(forKey: run.id); mutex.unlock()
        let lease = run.stepLease; run.stepLease = []
        run.operations.unlock()
        release(lease)
    }
    // Writers of folders without Git (a documents project's folder, or a folder linked to a plain chat) must not overlap a
    // documents project: a documents folder is taken alone, with nothing inside or around it being written. Plain linked
    // folders may still be written by several chats at once, as before. Across app instances the same rule holds through
    // lock files: an exclusive one for the folder and shared ones for every folder above it (a writer below or above
    // a documents folder then fails to lock); a plain folder around a documents folder is only seen inside this app.
    private static var documentsHeld: Set<String> = []
    private static var plainHeld: [String: Int] = [:]
    private static var leases: [String: (plain: [String], files: [Int32])] = [:]
    private static func overlaps(_ a: String, _ b: String) -> Bool { a == b || a.hasPrefix(b + "/") || b.hasPrefix(a + "/") }
    private static func ancestors(_ path: String) -> [String] {
        var result: [String] = [], current = (path as NSString).deletingLastPathComponent
        while !current.isEmpty && current != "/" { result.append(current); current = (current as NSString).deletingLastPathComponent }
        return result + ["/"]
    }
    // Lock files are named by the SHA-256 of their key: a folder's path (a documents folder, or a shared lock above a
    // writer), "worktree:" + a Git work tree, "refs:" + a Git common dir, "run:" + a common dir (project_run); the prefixes keep them apart.
    private static func lockFile(_ key: String, _ operation: Int32, wait: TimeInterval = 0, token: DebateCancellation? = nil, busy: String = "Folder is busy in another app instance.") throws -> Int32 {
        let base = URL(fileURLWithPath: AccountStore.supportDir).appendingPathComponent("project-locks")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let name = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        let fd = open(base.appendingPathComponent(name).path, O_CREAT | O_RDWR | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw ProjectError.make("Could not create repository lock.") }
        let until = Date().addingTimeInterval(wait)
        while flock(fd, operation | LOCK_NB) != 0 {
            guard Date() < until, token?.isCancelled != true else { close(fd); throw ProjectError.make(busy) }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return fd
    }
    private static func canonical(_ path: String) -> String { URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path }
    // The Git work tree a folder belongs to (`--show-toplevel`): one writer each, so two work trees of one repository are
    // written at the same time. nil: not in Git. Inside a `.git` folder (no top level) the folder itself.
    static func workTree(_ path: String) -> String? {
        if let top = try? ProjectProcess.git(["rev-parse", "--show-toplevel"], root: path), !top.isEmpty { return canonical(top) }
        return commonDir(path) == nil ? nil : canonical(path)
    }
    static func commonDir(_ root: String) -> String? {
        guard let path = try? ProjectProcess.git(["rev-parse", "--git-common-dir"], root: root) else { return nil }
        return canonical(path.hasPrefix("/") ? path : URL(fileURLWithPath: root).appendingPathComponent(path).path)
    }
    public static func acquire(_ binding: WorkspaceBinding?) throws -> [String] {
        guard let binding else { return [] }
        let support = canonical(AccountStore.supportDir)
        var trees = Set<String>(), plain = Set<String>()
        for root in binding.roots where root.directory && (root.writable == true || binding.level != .view) {
            if let tree = workTree(root.path) { trees.insert(tree) }
            else {
                let path = canonical(root.path)
                if path != support && !path.hasPrefix(support + "/") { plain.insert(path) }   // a chat's own folder overlaps nothing
            }
        }
        // A documents project has no Git: its folder is the lock.
        let documents = binding.project.flatMap { $0.isDocuments ? $0.root : nil }
        if let documents { trees.insert(documents); plain.remove(documents) }
        let busy = ProjectError.make(L(busyKorean, busyEnglish))
        mutex.lock(); defer { mutex.unlock() }
        var acquired: [String] = [], files: [Int32] = []
        do {
            for path in trees.sorted() {
                guard held[path] == nil else { throw busy }
                if path == documents {
                    if held.keys.contains(where: { overlaps($0, path) }) || plainHeld.keys.contains(where: { overlaps($0, path) }) { throw busy }
                } else if documentsHeld.contains(where: { overlaps($0, path) }) { throw busy }
                held[path] = try lockFile(path == documents ? path : "worktree:" + path, LOCK_EX); acquired.append(path)
                if path == documents { documentsHeld.insert(path) }
                for folder in ancestors(path) + (path == documents ? [] : [path]) { files.append(try lockFile(folder, LOCK_SH)) }
            }
            for path in plain.sorted() {
                guard !documentsHeld.contains(where: { overlaps($0, path) }) else { throw busy }
                for folder in [path] + ancestors(path) { files.append(try lockFile(folder, LOCK_SH)) }
            }
        } catch {
            for path in acquired { if let fd = held.removeValue(forKey: path) { close(fd) }; documentsHeld.remove(path) }
            for fd in files { close(fd) }
            throw error
        }
        guard !plain.isEmpty || !files.isEmpty else { return acquired }
        for path in plain { plainHeld[path, default: 0] += 1 }
        let token = Self.leasePrefix + UUID().uuidString
        leases[token] = (Array(plain), files)
        return acquired + [token]
    }
    static let leasePrefix = "lease:"
    // A chat is writing this folder's work tree now (TODO work waits instead of failing on acquire); another work tree of
    // the same repository being written does not count.
    public static func isHeld(_ root: String) -> Bool {
        guard let tree = workTree(root) else {
            // No Git: a documents project's folder, or one inside or around it, or that folder being written by a plain chat.
            mutex.lock(); defer { mutex.unlock() }
            return documentsHeld.contains { overlaps($0, root) } || plainHeld.keys.contains { overlaps($0, root) } || held[root] != nil
        }
        mutex.lock(); defer { mutex.unlock() }
        return held[tree] != nil || documentsHeld.contains { overlaps($0, root) }
    }
    // The short refs lock: the app's Git commands that change what every work tree of a repository shares (branches and
    // switching, merges, fetch/pull/push, the work tree list) run one at a time per repository, also across app instances,
    // each waiting up to `wait` seconds. Nobody holds it through a turn, so no turn waits on another and nothing is
    // upgraded from shared to exclusive. Commits stay outside it: each work tree has its own index and HEAD, and Git locks
    // each ref itself. Taken again on the thread that holds it, it is held already (a merge of several commands).
    static func withRefs<T>(_ root: String, wait: TimeInterval = 60, token: DebateCancellation? = nil, _ body: () throws -> T) throws -> T {
        guard let common = commonDir(root) else { return try body() }
        let key = "refs:" + common, mine = Thread.current.threadDictionary
        if mine[key] != nil { return try body() }
        let fd = try lockFile(key, LOCK_EX, wait: wait, token: token,
                              busy: L("다른 Git 작업(브랜치·push·pull)이 이 저장소에서 끝나지 않아 기다리다 멈췄어요. 잠시 뒤 다시 해 주세요.",
                                      "Another Git action (branch, push, pull) on this repository did not finish in time; try again shortly."))
        mine[key] = true
        defer { mine.removeObject(forKey: key); close(fd) }
        return try body()
    }
    static let refCommands: Set<String> = ["switch", "checkout", "branch", "merge", "fetch", "pull", "push", "worktree", "tag", "update-ref", "remote", "gc", "prune"]
    // GitLink's one way to Git: a command that changes shared refs takes the refs lock while it runs; reads and commits do not.
    static func git(_ args: [String], root: String, token: DebateCancellation? = nil, timeout: TimeInterval = 60) throws -> String {
        guard let command = args.first, refCommands.contains(command), !args.contains("--show-current") else { return try ProjectProcess.git(args, root: root, token: token, timeout: timeout) }
        let start = Date()
        return try withRefs(root, wait: min(60, timeout), token: token) {
            try ProjectProcess.git(args, root: root, token: token, timeout: max(1, timeout - Date().timeIntervalSince(start)))
        }
    }
    // project_run runs one at a time per repository, across its work trees and app instances: tests of sub-rooms at once
    // were slow and shared one test cache lock (test-cache.lock). The others wait in line until their deadline or a stop.
    static func oneRun<T>(_ root: String, until deadline: Date, token: DebateCancellation?, waiting: () -> Void, _ body: () throws -> T) throws -> T {
        guard let common = commonDir(root) else { return try body() }
        let key = "run:" + common
        let fd: Int32
        if let free = try? lockFile(key, LOCK_EX) { fd = free } else {
            waiting()
            fd = try lockFile(key, LOCK_EX, wait: max(0, deadline.timeIntervalSinceNow), token: token,
                              busy: L("이 저장소의 다른 project_run이 끝나지 않아 기다리다 멈췄어요.", "Another project_run in this repository did not finish in time."))
        }
        defer { close(fd) }
        return try body()
    }
    // Another writer holds what this binding would write (in this app or another instance); tries the lock and gives it back.
    public static func busy(_ binding: WorkspaceBinding?) -> Bool {
        do { release(try acquire(binding), notify: false); return false } catch { return isBusy(error.localizedDescription) }
    }
    public static func release(_ paths: [String], notify: Bool = true) {
        mutex.lock()
        for path in paths {
            if let lease = leases.removeValue(forKey: path) {
                for fd in lease.files { close(fd) }
                for folder in lease.plain { plainHeld[folder, default: 1] -= 1; if plainHeld[folder] == 0 { plainHeld.removeValue(forKey: folder) } }
            } else if let fd = held.removeValue(forKey: path) {
                close(fd); documentsHeld.remove(path)
            }
        }
        mutex.unlock()
        // Also a plain chat's folders: a documents TODO may be waiting for them.
        if notify && !paths.isEmpty { NotificationCenter.default.post(name: .projectReleased, object: nil) }
    }
}

extension Notification.Name {
    // A chat stopped writing a repository (TodoScheduler looks for the next TODO).
    public static let projectReleased = Notification.Name("AIIlluminatiProjectReleased")
}

public struct WorkStep: Codable, Equatable {
    public enum Status: String, Codable { case todo, doing, done, blocked }
    public var text: String
    public var status: Status
    // Set by the app, not the AI: when the step became doing and when it ended (older chats: nil, no time shown).
    public var started: Date?
    public var ended: Date?
    // While a project_run command runs in this step: its current "[n/m] name" line and since when.
    public var sub: String?
    public var subStarted: Date?
    public init(text: String, status: Status) { self.text = text; self.status = status }
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
public final class PlanLink: ToolProvider {
    public static let shared = PlanLink()
    public var active: Bool { ProjectWork.active }
    public func tools() -> [[String: Any]] { [] }
    private func live(_ context: ToolContext) -> ProjectRun? {
        guard let run = ProjectWork.get(context.projectRun), run.room == context.room, context.projectGeneration == run.generation, !run.cancelled else { return nil }
        return run
    }
    public func tools(context: ToolContext) -> [[String: Any]] {
        guard live(context) != nil else { return [] }
        let step: [String: Any] = ["type": "object", "properties": ["text": ["type": "string"], "status": ["type": "string", "enum": ["todo", "doing", "done", "blocked"]]],
                                   "required": ["text", "status"], "additionalProperties": false]
        return [["name": "work_plan",
                 "description": "Show the user your step list for this task (replaces the previous list). Call it first when the work has 3 or more steps and again whenever a step starts or ends. Short steps in the user's language. Mark a test step done only after the tests pass.",
                 "inputSchema": ["type": "object", "properties": ["steps": ["type": "array", "items": step, "maxItems": 20],
                                                                   "note": ["type": "string", "description": "Why the list changed, e.g. a failing test added a step"]],
                                 "required": ["steps"], "additionalProperties": false]]]
    }
    public func call(_ name: String, _ arguments: [String: Any], context: ToolContext) -> [String: Any] {
        guard name == "work_plan" else { return ProjectTools.failure("Unknown tool: " + name) }
        guard let run = live(context), let generation = context.projectGeneration else { return ProjectTools.failure("No live project work for this plan.") }
        guard let steps = Self.steps(arguments["steps"]) else { return ProjectTools.failure("steps must be 1-20 items of {text, status: todo|doing|done|blocked}.") }
        guard run.setPlan(steps, note: arguments["note"] as? String, generation: generation, tool: true) else { return ProjectTools.failure("This plan belongs to an earlier attempt.") }
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
    public static func todos(_ value: Any?) -> [WorkStep]? {
        guard let items = value as? [[String: Any]], !items.isEmpty else { return nil }
        let steps = items.compactMap { item -> WorkStep? in
            guard let text = item["content"] as? String, !text.isEmpty else { return nil }
            let status: WorkStep.Status = item["status"] as? String == "completed" ? .done : item["status"] as? String == "in_progress" ? .doing : .todo
            return WorkStep(text: String(text.prefix(200)), status: status)
        }
        return steps.isEmpty ? nil : Array(steps.prefix(20))
    }
}

public final class GitLink: ToolProvider {
    public static let shared = GitLink()
    public var active: Bool { ProjectWork.active }
    public func tools() -> [[String: Any]] { [] } // Scoped tools must never be exposed globally.
    public func tools(context: ToolContext) -> [[String: Any]] {
        guard let run = ProjectWork.get(context.projectRun), run.room == context.room, context.projectGeneration == run.generation, !run.cancelled else { return [] }
        let string: [String: Any] = ["type": "string"]
        func tool(_ name: String, _ description: String, _ props: [String: Any] = [:], _ required: [String] = []) -> [String: Any] {
            ["name": name, "description": description, "inputSchema": ["type": "object", "properties": props, "required": required, "additionalProperties": false]]
        }
        if run.binding.isFolderless { return [] }
        let run_ = tool("project_run", "Run a named command from .ai-illuminati.json after user approval. Never pass shell commands.", ["name": string], ["name"])
        if run.binding.isDocuments { return [run_] }   // no Git in a documents project
        let all = [tool("git_status", "Read linked project status and branch."), tool("git_diff", "Read staged or unstaged diff; never executes external diff tools.", ["staged": ["type": "boolean"]]), tool("git_log", "Recent project commits."),
                tool("git_pull", "Fast-forward only, clean worktree required. Never stash/reset."),
                tool("git_commit", "Commit only explicit relative paths; existing user changes require approval.", ["message": string, "paths": ["type": "array", "items": string]], ["message", "paths"]),
                tool("git_push", "Push current main/feature branch; never stable or force."),
                tool("git_publish_stable", "Publish an exact main SHA to stable after the user's approval card."),
                tool("git_branch", "Create a new branch from a clean tree.", ["name": string], ["name"]), tool("git_switch", "Switch an existing branch with a clean tree.", ["name": string], ["name"]),
                run_]
        return run.isSubRoom || run.isStep ? all.filter { !Self.localOnlyDenied.contains($0["name"] as? String ?? "") } : all
    }
    // Sub-rooms and Steps keep their commits on their assigned local branch.
    private static let localOnlyDenied: Set<String> = ["git_pull", "git_push", "git_publish_stable", "git_branch", "git_switch"]
    public func call(_ name: String, _ arguments: [String: Any], context: ToolContext) -> [String: Any] {
        guard let run = ProjectWork.get(context.projectRun), run.room == context.room, let generation = context.projectGeneration else { return ProjectTools.failure("No project capability.") }
        run.operations.lock(); defer { run.operations.unlock() }
        do {
            try run.validate(generation)
            _ = run.checkpoint("Starting \(name); inspect remote state if interrupted.")
            let output = try execute(name, arguments, run, generation)
            _ = run.checkpoint("\(name) completed")
            run.note(name + " → " + String(output.prefix(180)))
            return ["content": [["type": "text", "text": output]], "isError": false]
        } catch { _ = run.checkpoint(name + " failed: " + String(error.localizedDescription.prefix(500))); run.note(name + " failed"); return ProjectTools.failure(error.localizedDescription) }
    }
    // The end of a project turn: the push its git_push asked for, with the same branch rules, on a fresh attempt (the
    // AI's attempts are over). nil: nothing was asked. Throws when the push fails; the commits stay local.
    public func pushDeferred(_ run: ProjectRun) throws -> String? {
        guard !run.isStep else { throw ProjectError.make(L("Step에서는 지연 push가 금지돼요.", "A Step cannot push at the end of its turn.")) }
        guard run.deferPush, run.pushWanted else { return nil }
        run.nextAttempt()
        defer { run.endAttempt() }
        run.operations.lock(); defer { run.operations.unlock() }
        let generation = run.generation
        do {
            try run.validate(generation)
            _ = run.checkpoint("Starting the turn's push; inspect remote state if interrupted.")
            let output = try execute("git_push", [:], run, generation, app: true)
            _ = run.checkpoint("Turn push completed")
            run.note(L("push (리뷰 후 한 번) → ", "push (once, after the review) → ") + String(output.prefix(180)))
            return output
        } catch { _ = run.checkpoint("Turn push failed: " + String(error.localizedDescription.prefix(500))); run.note(L("push 실패", "push failed")); throw error }
    }
    // The project screen uses the same approval and publish path as the scoped tool, without an AI turn.
    // Call off the main thread: approval waits while the main thread displays the card.
    public func publishStable(_ binding: ProjectBinding, room: UUID, onWaiting: @escaping (Bool) -> Void) throws -> String {
        guard !binding.isDocuments, !binding.isFolderless else { throw ProjectError.make("A Git project is required.") }
        let workspace = WorkspaceBinding(roots: [WorkspaceRoot(path: binding.root, directory: true, writable: true)], level: .execute, project: binding)
        let held = try ProjectWork.acquire(workspace)
        defer { ProjectWork.release(held) }
        let run = ProjectRun(room: room, binding: binding, token: DebateCancellation())
        run.onWaiting = onWaiting
        defer { ProjectWork.finish(run) }
        try run.validate(run.generation)
        return try execute("git_publish_stable", [:], run, run.generation)
    }
    // The project screen's "pull main" after a refresh found new commits: the repository lock (no pull in the middle of an
    // AI's work) and git_pull's rules (fast-forward only, clean tree, never stash/reset), only with main checked out.
    // Call off the main thread.
    public func pullMain(_ binding: ProjectBinding) throws -> String {
        guard !binding.isDocuments, !binding.isFolderless, !binding.remote.isEmpty else { throw ProjectError.make("A Git project is required.") }
        let workspace = WorkspaceBinding(roots: [WorkspaceRoot(path: binding.root, directory: true, writable: true)], level: .execute, project: binding)
        let held = try ProjectWork.acquire(workspace)
        defer { ProjectWork.release(held) }
        func git(_ argv: [String], timeout: TimeInterval = 30) throws -> String { try ProjectWork.git(argv, root: binding.root, timeout: timeout) }
        guard try git(["branch", "--show-current"]) == "main" else { throw ProjectError.make(L("main이 체크아웃되어 있지 않아 받지 않았어요.", "main is not checked out; nothing pulled.")) }
        guard try git(["status", "--porcelain"]).isEmpty else { throw ProjectError.make(L("커밋하지 않은 변경이 있어 받지 않았어요.", "There are uncommitted changes; nothing pulled.")) }
        return try git(["pull", "--ff-only", "--no-rebase", binding.remote, "main"], timeout: 180)
    }
    // The remote target branch is no longer the Milestone's base: the candidate went back to integration (TODO structure 07)
    // on `remote`, and its review and full test start over.
    struct MilestoneRemoteMoved: LocalizedError, Equatable {
        var remote: String
        var errorDescription: String? {
            L("원격 대상 branch가 리뷰한 기준에서 앞서 나가 push하지 않았어요. 새 원격 커밋과 다시 통합해요: ", "The remote target branch moved past the reviewed base; nothing pushed. Integrating the new remote commit again: ") + remote
        }
    }
    // The push did not go through (network, timeout, the hook) and the remote target branch is still the base: the candidate
    // stays verified in the push phase, and the next run starts again from the push (TODO structure 13).
    struct MilestonePushPending: LocalizedError, Equatable {
        var reason: String
        var errorDescription: String? {
            L("Milestone push가 끝나지 않았어요. 후보와 기준이 그대로라 push부터 다시 해요: ", "The Milestone's push did not finish; the candidate and base are unchanged, so it retries from the push: ") + reason
        }
    }
    // TODO structure 12 (off until 16): a Milestone's push. Only the candidate SHA its review and full test both passed, only
    // while the remote target branch (never the Goal branch) is still the base they were measured from, as that exact SHA to
    // refs/heads/<target>: a fast-forward, never forced (no +, no --force*; a non-fast-forward is the remote's refusal). Unlike
    // the app's other Git commands the repository's pre-push hook runs as is (the candidate's .githooks, else its
    // core.hooksPath), from the Goal's tree so it checks the candidate itself. Throws MilestoneRemoteMoved after resetting the
    // candidate when the remote moved on; any other refusal leaves it as it was.
    // TODO structure 13: the outcome is what the remote holds, not the push's reply. Before pushing and after any failure
    // (a lost reply, a timeout, an app that quit mid-push and runs this again) the remote target branch is read again: one
    // that contains the candidate is a push already done (phase confirmation), one still at the base retries from the push
    // (MilestonePushPending), any other commit sends it back to integration (MilestoneRemoteMoved).
    static func pushMilestone(_ binding: ProjectBinding, _ tree: SubWork.Tree, candidate: inout TodoItem.MilestoneCandidate,
                              token: DebateCancellation? = nil) throws -> String {
        func refuse(_ korean: String, _ english: String) -> Error { ProjectError.make(L("Milestone push 거부: ", "Milestone push refused: ") + L(korean, english)) }
        guard TodoData.goalPath else { throw refuse("Goal 경로가 아직 꺼져 있어요.", "the Goal path is still off.") }
        func git(_ args: [String], _ root: String = binding.root, timeout: TimeInterval = 120) throws -> ProjectProcess.Reply {
            try ProjectProcess.gitReply(["-c", "core.quotePath=false"] + args, root: root, token: token, timeout: timeout)
        }
        func value(_ args: [String], _ root: String = binding.root) throws -> String {
            let r = try git(args, root)
            guard r.status == 0 else { throw ProjectError.make("git failed (\(r.status)): " + r.output) }
            return r.output.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let target = candidate.branch
        guard !binding.isDocuments, !binding.isFolderless, !binding.remote.isEmpty, let common = ProjectWork.commonDir(binding.root),
              tree.branch.hasPrefix("todo-goal/"), !target.hasPrefix("todo-goal/"), !target.hasPrefix("-"),
              (try? value(["check-ref-format", "--branch", target])) == target else {
            throw refuse("Goal 작업 폴더와 원격 대상 branch(Goal branch가 아닌)가 필요해요.", "a Goal work tree and a remote target branch (not the Goal branch) are required.")
        }
        guard let sha = candidate.candidateSHA, candidate.reviewedSHA == sha, candidate.testedSHA == sha else {
            throw refuse("후보 SHA가 리뷰한 SHA, 전체 테스트한 SHA와 같지 않아요.", "the candidate SHA is not both the reviewed and the fully tested SHA.")
        }
        candidate.setPhase(.push)
        let held: [String]
        do { held = try ProjectWork.acquire(WorkspaceBinding(roots: [WorkspaceRoot(path: tree.path, directory: true, writable: true)], level: .execute)) }
        catch where ProjectWork.isBusy(error.localizedDescription) { throw refuse("Step이 아직 Goal 작업 폴더를 쓰고 있어요.", "a Step is still writing the Goal's work tree.") }
        defer { ProjectWork.release(held, notify: false) }
        let tracking = "refs/remotes/\(binding.remote)/\(target)"
        func remoteNow() throws -> String {
            try ProjectWork.withRefs(binding.root, token: token) {
                // Unreachable (network), timed out or stopped: nothing is known, so the candidate waits in the push phase
                // for the next run, whether the fetch failed or threw.
                let fetch: ProjectProcess.Reply
                do { fetch = try git(["fetch", "--no-tags", binding.remote, "+refs/heads/\(target):\(tracking)"], timeout: 180) }
                catch { throw MilestonePushPending(reason: error.localizedDescription) }
                guard fetch.status == 0 else {
                    throw MilestonePushPending(reason: L("원격 대상 branch를 확인하지 못했어요: ", "could not read the remote target branch: ") + fetch.output)
                }
                let fetched = try value(["rev-parse", "--verify", tracking + "^{commit}"])
                // A separate push URL (pushurl, pushInsteadOf) is where the branch moves: its SHA must be the one checked.
                let pushURL = try value(["remote", "get-url", "--push", binding.remote])
                if pushURL != (try value(["remote", "get-url", binding.remote])) {
                    let line = try value(["ls-remote", "--", pushURL, "refs/heads/" + target])
                    guard line.split(separator: "\t").first.map(String.init) == fetched else {
                        throw refuse("push 주소의 대상 branch가 fetch한 SHA와 달라요.", "the target branch at the push URL differs from the fetched SHA.")
                    }
                }
                return fetched
            }
        }
        func moved(_ remote: String) -> Error {
            candidate = TodoItem.MilestoneCandidate(branch: target, baseSHA: remote)
            return MilestoneRemoteMoved(remote: remote)
        }
        // On the remote: the candidate itself or a later commit on top of it (pushed by someone after it landed).
        func landed(_ remote: String) -> Bool { remote == sha || (try? git(["merge-base", "--is-ancestor", sha, remote]).status) == 0 }
        let remote = try remoteNow()
        if landed(remote) { candidate.setPhase(.confirmation); return "Already on \(binding.remote)/\(target): " + sha }   // an earlier push that was not recorded
        guard remote == candidate.baseSHA else { throw moved(remote) }
        guard try git(["merge-base", "--is-ancestor", remote, sha]).status == 0 else {
            throw refuse("후보가 원격 기준 SHA에서 fast-forward되지 않아요.", "the candidate is not a fast-forward of the remote base SHA.")
        }
        // The hook runs in the Goal's tree, so that tree must be the candidate exactly.
        guard SubWork.ownsGoalTree(tree, common: common, token: token), try value(["rev-parse", "HEAD"], tree.path) == sha,
              try value(["status", "--porcelain", "--untracked-files=all", "--ignore-submodules=none"], tree.path).isEmpty,
              try git(["rev-parse", "-q", "--verify", "MERGE_HEAD"], tree.path).status != 0 else {
            throw refuse("Goal 작업 폴더가 후보 SHA 그대로가 아니에요.", "the Goal's work tree is not exactly the candidate SHA.")
        }
        // Without ProjectProcess.gitReply's core.hooksPath=/dev/null. The candidate's .githooks/pre-push, when it has one, runs
        // whatever core.hooksPath says (it may be /dev/null or another folder) and must be runnable; otherwise the configured hooks.
        let required = tree.path + "/.githooks/pre-push"
        var hooks: [String] = []
        if FileManager.default.fileExists(atPath: required) {
            guard FileManager.default.isExecutableFile(atPath: required) else {
                throw refuse("후보의 .githooks/pre-push를 실행할 수 없어요.", "the candidate's .githooks/pre-push is not executable.")
            }
            hooks = ["-c", "core.hooksPath=.githooks"]
        }
        // Only the target branch: no tags (push.followTags) and no submodules go along.
        let result: ProjectProcess.Reply
        do {
            result = try ProjectProcess.run("/usr/bin/git", ["--literal-pathspecs", "-c", "core.fsmonitor=false", "-c", "submodule.recurse=false"] + hooks
                                            + ["push", "--no-recurse-submodules", "--no-follow-tags", binding.remote, sha + ":refs/heads/" + target],
                                            cwd: tree.path, token: token, deadline: Date().addingTimeInterval(1800))
        } catch { result = ProjectProcess.Reply(status: -1, output: error.localizedDescription) }   // stopped or timed out: maybe pushed
        guard result.status == 0 else {
            // Judged by the remote: landed after all (the reply was lost), moved on meanwhile (back to integration), or
            // still the base or unreadable (the push phase again; the hook's refusal is one of those too).
            let failed = "exit \(result.status): " + result.output
            guard let now = try? remoteNow() else { throw MilestonePushPending(reason: failed) }
            if landed(now) { candidate.setPhase(.confirmation); return result.output + "\nAlready on \(binding.remote)/\(target): " + sha }
            if now != candidate.baseSHA { throw moved(now) }
            throw MilestonePushPending(reason: failed)
        }
        candidate.setPhase(.confirmation)
        return result.output + "\nPushed " + sha + " to " + binding.remote + "/" + target
    }
    // TODO structure 11: a Goal's commits reach the remote only as the SHA its Milestone reviewed and fully tested. A plain
    // chat that merged a todo-goal/ branch into its HEAD (a common commit not on the remote) or cherry-picked from it (the
    // same patch, --cherry-mark) is refused unless HEAD is exactly that SHA for this branch. Branches without the app's
    // Goal record are not Goals; no Goal branch: nothing changes.
    static func goalGuard(_ binding: ProjectBinding, branch: String, head: String, git: ([String]) throws -> String,
                          verified: (UUID, String) -> Set<String> = { goal, branch in
                              Set(TodoStore.shared.current.items.compactMap { item in
                                  item.role == .milestone && item.goal == goal && item.milestoneCandidate?.branch == branch ? item.milestoneCandidate?.verifiedSHA : nil
                              })
                          }) throws {
        let goals = try git(["for-each-ref", "--format=%(refname:short)", "refs/heads/todo-goal/"]).split(separator: "\n").map(String.init)
        guard !goals.isEmpty else { return }
        // Measured from the target branch as the remote has it now: a stale tracking ref or another branch's ref would
        // hide or invent Goal commits. A branch not on the remote yet (or no answer): everything the remote is known to have.
        let tracking = "refs/remotes/\(binding.remote)/\(branch)"
        let fetched = (try? git(["fetch", "--no-tags", binding.remote, "+refs/heads/\(branch):\(tracking)"])) != nil
        let remote = fetched ? ["--not", tracking] : ["--not", "--remotes=" + binding.remote]
        for goal in goals {
            guard let id = (try? git(["config", "--get", "branch." + goal + ".todogoal"])).flatMap(UUID.init(uuidString:)) else { continue }
            let common = (try? git(["merge-base", "--all", head, "refs/heads/" + goal])) ?? ""
            let merged = try common.split(separator: "\n").contains { try !git(["rev-list", "-n", "1", String($0)] + remote).isEmpty }
            let picked = try !merged && git(["rev-list", "--cherry-mark", "--right-only", "--no-merges", "refs/heads/" + goal + "..." + head] + remote)
                .split(separator: "\n").contains { $0.hasPrefix("=") }
            guard merged || picked, !verified(id, branch).contains(head) else { continue }
            throw ProjectError.make(L("\(goal)의 커밋이 push 범위에 있지만 이 HEAD는 그 Milestone이 리뷰와 전체 테스트를 통과한 SHA가 아니에요. Goal 커밋은 Milestone만 올릴 수 있으니 합친 커밋을 빼고 다시 push하세요.",
                                      "Commits of \(goal) are in this push, but this HEAD is not the SHA its Milestone reviewed and fully tested. Only the Milestone pushes a Goal's commits; take the merged commits out and push again."))
        }
    }
    private func execute(_ name: String, _ args: [String: Any], _ run: ProjectRun, _ generation: Int, app: Bool = false) throws -> String {
        func git(_ argv: [String], timeout: TimeInterval = 120) throws -> String { try run.validate(generation); return try ProjectWork.git(argv, root: run.binding.root, token: run.attempt, timeout: min(timeout, run.deadline.timeIntervalSinceNow)) }
        func clean() throws { guard try git(["status", "--porcelain"]).isEmpty else { throw ProjectError.make("Working tree is not clean; preserve edits and do not pull/switch/stash.") } }
        func approve(_ title: String, _ detail: String, command: String? = nil, same: String? = nil) throws {
            run.beginApproval(); defer { run.endApproval() }
            let deadline = min(run.deadline, Date().addingTimeInterval(900))
            var asked = ProjectApproval(room: run.room, run: run.id, title: title, detail: detail)
            asked.command = command; asked.same = same
            guard ProjectCenter.shared.approve(asked, token: run.attempt, deadline: deadline) else {
                // 15 minutes unanswered counts as no: the user is away. The chat keeps a note with Ask again.
                if Date() >= deadline, !run.attempt.isCancelled { throw ProjectError.make("Project approval timed out after 15 minutes; treated as refused. Stop and tell the user they can ask again.") }
                throw ProjectError.make("Project approval refused or cancelled.")
            }
            try run.validate(generation)
        }
        if run.binding.isDocuments && name != "project_run" { throw ProjectError.make("This is a documents project without Git; there are no git tools. The app backed the folder up before this answer.") }
        if run.isStep && Self.localOnlyDenied.contains(name) {
            throw ProjectError.make(L("Step에서 \(name)은 사용할 수 없어요. Goal 브랜치에 로컬로 커밋하세요.", "\(name) is unavailable in a Step. Commit locally on the Goal branch."))
        }
        if run.isSubRoom && Self.localOnlyDenied.contains(name) { throw ProjectError.make("A sub-room has no \(name): it commits on its own branch and reports with sub_report; the main room merges and pushes.") }
        switch name {
        case "git_status": return try git(["status", "--short", "--branch"])
        case "git_log": return try git(["log", "-10", "--oneline"])
        case "git_diff": return try git(["diff", "--no-ext-diff", "--no-textconv"] + ((args["staged"] as? Bool == true) ? ["--cached"] : []))
        case "git_pull": try clean(); return try git(["pull", "--ff-only", "--no-rebase"], timeout: 180)
        case "git_commit":
            guard let message = args["message"] as? String, !message.isEmpty, message.count <= 4000,
                  let paths = args["paths"] as? [String], !paths.isEmpty, paths.count <= 500 else { throw ProjectError.make("Provide a commit message and explicit paths.") }
            for path in paths {
                guard !path.hasPrefix("/"), !path.split(separator: "/").contains(".."), !path.split(separator: "/").contains(".git"), !path.isEmpty else { throw ProjectError.make("Invalid commit path.") }
                let resolved = URL(fileURLWithPath: run.binding.root).appendingPathComponent(path).resolvingSymlinksInPath().path
                guard resolved.hasPrefix(run.binding.root + "/") else { throw ProjectError.make("Commit path leaves the project.") }
            }
            let diff = try git(["diff", "--no-ext-diff", "--no-textconv", "HEAD", "--"] + paths)
            if !run.fullAuto, paths.contains(where: { path in run.initialDirty.contains(where: { dirty in path == "." || dirty == path || dirty.hasPrefix(path + "/") }) }) { try approve("기존 변경 포함 / Include existing edits", diff) }
            // A merge left for the AI to resolve (delegate_resync, or its own merge): Git refuses a partial commit then, so
            // the resolved files are added and the merge is committed whole, only once no file is left unmerged.
            if (try? ProjectWork.git(["rev-parse", "-q", "--verify", "MERGE_HEAD"], root: run.binding.root)) != nil {
                // `git add` marks a file resolved even with its markers left, so they are looked for first.
                let marked = paths.filter { path in
                    let text = (try? String(contentsOfFile: run.binding.root + "/" + path, encoding: .utf8)) ?? ""
                    return text.split(separator: "\n").contains { $0.hasPrefix("<<<<<<< ") || $0.hasPrefix(">>>>>>> ") }
                }
                guard marked.isEmpty else { throw ProjectError.make("These files still have conflicts; resolve and include them: " + marked.joined(separator: ", ")) }
                _ = try git(["add", "--"] + paths)
                let unmerged = try git(["diff", "--name-only", "--diff-filter=U"])
                guard unmerged.isEmpty else { throw ProjectError.make("These files still have conflicts; resolve and include them: " + unmerged.replacingOccurrences(of: "\n", with: ", ")) }
                let result = try git(["commit", "--no-edit", "-m", message])
                run.committed = true; return result
            }
            let result = try git(["add", "--"] + paths) + "\n" + git(["commit", "--only", "-m", message, "--"] + paths)
            run.committed = true; return result
        case "git_push":
            let branch = try git(["branch", "--show-current"])
            guard branch == "main" || branch.hasPrefix("feature/") || branch.hasPrefix("codex/") || branch.hasPrefix("fix/") else { throw ProjectError.make("Push supports main or a feature/fix/codex branch. Use the publish tool for stable.") }
            let sha = try git(["rev-parse", "HEAD"])
            try Self.goalGuard(run.binding, branch: branch, head: sha, git: { try git($0) })
            if run.deferPush && !app {
                run.pushWanted = true
                return "Push requested. The app pushes HEAD of " + branch + " once, after the review and your fixes, when this turn ends; do not push any other way. Commit later fixes as usual; nothing else is needed for the push."
            }
            let result = try git(["push", run.binding.remote, sha + ":refs/heads/" + branch], timeout: 180)
            run.pushed = true; return result + "\nPushed " + sha
        case "git_publish_stable":
            try clean()
            _ = try git(["fetch", "--prune", run.binding.remote], timeout: 180)
            let sha = try git(["rev-parse", "refs/heads/main"])
            let stable = "refs/remotes/" + run.binding.remote + "/stable"
            let previous = try git(["for-each-ref", "--format=%(objectname)", stable])
            if previous == sha { return L("이미 배포된 커밋이에요.", "This commit is already published.") }
            guard try previous.isEmpty || git(["rev-list", "--count", sha + ".." + previous]) == "0" else {
                throw ProjectError.make(L("stable에 main에 없는 커밋이 있어 배포할 수 없어요.", "Stable has commits missing from main; cannot publish."))
            }
            let range = previous.isEmpty ? sha : previous + ".." + sha
            let summary = try git(["log", "-20", "--oneline", range])
            let changes = previous.isEmpty ? "" : try git(["diff", "--no-ext-diff", "--no-textconv", "--stat", previous, sha])
            try approve("stable 배포 / Publish stable", run.binding.root + "\n" + run.binding.remoteURL + "\nExact SHA: " + sha + "\n" + summary + "\n" + changes)
            try clean()
            let result = try git(["push", run.binding.remote, sha + ":refs/heads/stable"], timeout: 180)
            run.pushed = true; return result + "\nPublished " + sha
        case "git_branch", "git_switch":
            try clean()
            guard let asked = args["name"] as? String, !asked.hasPrefix("-"), asked.count < 200 else { throw ProjectError.make("Invalid or protected branch.") }
            // The rules hold for the name Git resolves too: "@{-1}" may be stable or a sub/ branch checked out before.
            let branch = try git(["check-ref-format", "--branch", asked])
            for candidate in [asked, branch] {
                guard !["stable", "HEAD", "master"].contains(candidate), !candidate.hasPrefix("-") else { throw ProjectError.make("Invalid or protected branch.") }
                // sub/… are the app's branches for a sub-room's work tree: only the app makes, merges and removes them.
                guard !candidate.hasPrefix("sub/") else { throw ProjectError.make("sub/ branches belong to the app's sub-rooms; this chat cannot create or switch to them.") }
            }
            return try git(name == "git_branch" ? ["switch", "-c", branch] : ["switch", branch])
        case "project_run":
            guard let selected = args["name"] as? String else { throw ProjectError.make("Choose a registered command name.") }
            let url = URL(fileURLWithPath: run.binding.root).appendingPathComponent(".ai-illuminati.json")
            guard url.resolvingSymlinksInPath().path.hasPrefix(run.binding.root + "/") else { throw ProjectError.make("Project config leaves the repository.") }
            guard let data = try? Data(contentsOf: url) else {
                throw ProjectError.make("No .ai-illuminati.json in the project yet. Create it with {\"version\":1,\"commands\":{\"\(selected)\":{\"executable\":\"/absolute/path\",\"args\":[...]}}} and call project_run again; the user approves the exact command.")
            }
            guard data.count < 64_000, let config = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let commands = config["commands"] as? [String: [String: Any]], let command = commands[selected],
                  let exe = command["executable"] as? String, exe.hasPrefix("/"), let argv = command["args"] as? [String] else { throw ProjectError.make("Unknown or invalid named project command. Add it to .ai-illuminati.json (absolute executable, args array) and call project_run again.") }
            let status = run.binding.isDocuments ? "" : try git(["status", "--short"])
            let tree = try WorkspaceBackup.stamps([WorkspaceRoot(path: run.binding.root, directory: true)])
            if run.fullAuto { run.note("project_run (full auto): " + exe + " " + argv.joined(separator: " ")) }
            else {
                let line = exe + " " + argv.joined(separator: " ")
                let scope = run.isStep ? "Runs in the Goal worktree sandbox." : "Runs outside the AI sandbox as your user."
                try approve("프로젝트 실행 / Run project command", scope + "\n" + run.binding.root + "\n" + line + "\n" + status,
                            command: selected + ": " + line, same: CommandIdentity.key(executable: exe, args: argv, tree: run.binding.root, config: data, permission: run.isStep ? "step" : "user"))
            }
            guard try Data(contentsOf: url) == data, try WorkspaceBackup.stamps([WorkspaceRoot(path: run.binding.root, directory: true)]) == tree else { throw ProjectError.make("Command changed after approval. Request it again.") }
            // "[n/m] name" lines show under the current step; their times go to project-timings for later estimates.
            let progress = RunProgress(command: selected) { text in if !run.setSub(text) { run.note(text) } }
            defer { run.setSub(nil) }
            let deadline = min(run.deadline, Date().addingTimeInterval(2700))
            do {
                let reply = try ProjectWork.oneRun(run.binding.root, until: deadline, token: run.attempt,
                                                   waiting: { run.note(L("project_run: 이 저장소의 다른 명령이 끝나길 기다리는 중", "project_run: waiting for another command in this repository")) }) {
                    if run.isStep {
                        try run.validate(generation)
                        return try ProjectProcess.runStep(exe, argv, project: run.binding, token: run.attempt, deadline: deadline, onLine: progress.line)
                    }
                    return try ProjectProcess.run(exe, argv, cwd: run.binding.root, token: run.attempt, deadline: deadline, guarded: run.fullAuto, onLine: progress.line)
                }
                RunTimings.record(root: run.binding.root, command: selected, progress.finish(reply.status == 0 ? "ok" : "failed", exit: reply.status))
                return "exit=\(reply.status)\n" + reply.output
            } catch {
                RunTimings.record(root: run.binding.root, command: selected, progress.finish(RunProgress.outcome(timedOut: Date() >= deadline || run.activeExpired, stopped: run.outer.isCancelled || run.attempt.isCancelled), exit: nil))
                throw error
            }
        default: throw ProjectError.make("Unknown project tool.")
        }
    }
}

// "The same command" for an approval given once for a split (docs/SUBROOM_PLAN.md 7): the executable's real path, the
// arguments, the work tree, the bytes of .ai-illuminati.json and the permission it runs with, not the command's name.
// What the command may run is hashed too, so a changed one asks again: every script in the work tree (by its ending or
// the executable bit) and every file in the folders of the files the command names (tools/tests/ for run_mode2.sh).
// A tree too large to read gets a key of its own: never the same, so it is asked each time.
enum CommandIdentity {
    static let scriptEndings: Set<String> = ["sh", "zsh", "bash", "command", "py", "rb", "pl", "js", "mjs", "json", "toml", "yaml", "yml", "mk"]
    static let skipped: Set<String> = [".git", "node_modules", ".build", "build", "dist", "DerivedData", "__pycache__"]
    static func key(executable: String, args: [String], tree: String, config: Data, permission: String, mostFiles: Int = 20_000) -> String {
        func sha(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
        let fm = FileManager.default
        let root = URL(fileURLWithPath: tree).resolvingSymlinksInPath().standardizedFileURL.path
        var parts = [URL(fileURLWithPath: executable).resolvingSymlinksInPath().path, root, permission, sha(config), String(args.count)] + args
        // The folders of the in-tree files the command names: all their files count.
        var folders: [String] = []
        for arg in [executable] + args {
            let path = URL(fileURLWithPath: arg.hasPrefix("/") ? arg : root + "/" + arg).resolvingSymlinksInPath().standardizedFileURL.path
            var directory: ObjCBool = false
            guard path.hasPrefix(root + "/"), fm.fileExists(atPath: path, isDirectory: &directory) else { continue }
            folders.append(directory.boolValue ? path + "/" : (path as NSString).deletingLastPathComponent + "/")
        }
        guard let walk = fm.enumerator(at: URL(fileURLWithPath: root), includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .fileSizeKey]) else {
            return UUID().uuidString
        }
        var files: [String] = [], bytes = 0
        for case let url as URL in walk {
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .fileSizeKey])
            if values?.isDirectory == true { if skipped.contains(url.lastPathComponent) { walk.skipDescendants() }; continue }
            guard values?.isRegularFile == true else { continue }
            let path = url.standardizedFileURL.path
            guard scriptEndings.contains(url.pathExtension.lowercased()) || folders.contains(where: { path.hasPrefix($0) }) || fm.isExecutableFile(atPath: path) else { continue }
            files.append(path); bytes += values?.fileSize ?? 0
            if files.count > mostFiles || bytes > 400_000_000 { return UUID().uuidString }
        }
        for path in files.sorted() {
            guard let data = fm.contents(atPath: path) else { return UUID().uuidString }
            parts.append(String(path.dropFirst(root.count)) + ":" + sha(data))
        }
        return sha(Data(parts.joined(separator: "\u{0}").utf8))
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
