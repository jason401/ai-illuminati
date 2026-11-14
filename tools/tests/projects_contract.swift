import Foundation
import Combine
import AIAccounts
import AIRuntime
import AIWorkspace
import AIProjects
// contract needs: app resources

// The promises of Projects (AIProjects), checked from outside with only its public API and a fake chat side
// (`TodoChats`): the TODO state changes the scheduler owns (an error is retried before anything after it starts, a
// busy repository is not counted, the user decides after the retries, a report waits for the check) and their order
// against the repository lock (the next TODO starts only once the lock is let go, woken by its release), the TODO file
// format, the repository lock, the scoped tools, and the work binding. Run with AI_ILLUMINATI_TEST_HOME set to an empty
// folder and AI_ILLUMINATI_TEST_RESOURCES to app/resources (run_mode2.sh). No real CLI, home, Keychain or network.
func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fatalError("FAIL: " + message) }
}
let fm = FileManager.default
let home = ProcessInfo.processInfo.environment["AI_ILLUMINATI_TEST_HOME"] ?? ""
expect(!home.isEmpty && AccountStore.home == home, "the projects test needs its own home")
let base = URL(fileURLWithPath: home).appendingPathComponent("projects").resolvingSymlinksInPath()
let repo = base.appendingPathComponent("repo")   // a plain folder: its lock is the folder's own
try! fm.createDirectory(at: repo, withIntermediateDirectories: true)
let project = ProjectBinding(root: repo.path, common: "", remote: "", remoteURL: "")
func pump(_ seconds: Double = 0.1) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }

// The chat side, as the scheduler sees it. `events` records what happened in order.
final class FakeChats: TodoChats {
    let changed = PassthroughSubject<Void, Never>()
    var answering: Set<UUID> = [] { didSet { changed.send(()) } }
    var answeringChanged: AnyPublisher<Void, Never> { changed.eraseToAnyPublisher() }
    var maxAnswering = 3
    var importing = false
    var chats: [ProjectChatSummary] = []
    var endings: [UUID: TodoTurnEnd] = [:]
    var events: [String] = []
    var titles: [UUID: String] = [:]
    var questions: [String] = []
    let lead = Account(id: "lead", provider: .claude, name: "Lead")
    func crew(lock: EnterpriseLock?, allowed: [String]) -> (lead: Account, reviewer: Account?)? { (lead, nil) }
    func noCrew(_ allowed: [String], lock: EnterpriseLock?) -> String { "nobody" }
    func addChat(_ project: ProjectBinding, title: String, lock: EnterpriseLock?) -> UUID {
        let id = UUID()
        chats.append(ProjectChatSummary(id: id, updatedAt: Date(), project: project, lock: lock, enterprise: false, openTurn: nil))
        titles[id] = title
        return id
    }
    func setCrew(room: UUID, members: [String], lead: String) {}
    func folder(_ room: UUID) -> URL { base.appendingPathComponent("chats/" + room.uuidString) }
    func sentPhotos(_ room: UUID) -> Set<UUID> { [] }
    func start(room: UUID, question: String, photos: [TodoPhoto], review: Bool, extra: String) -> String? {
        events.append("start " + (question.split(separator: "\n").first.map(String.init) ?? "")); questions.append(question)
        answering.insert(room)
        return nil
    }
    func ended(_ room: UUID) -> TodoTurnEnd { endings[room] ?? TodoTurnEnd() }
    func stop(_ room: UUID) { events.append("stop"); answering.remove(room) }
}

let store = TodoStore(url: base.appendingPathComponent("todos.json"))
let chats = FakeChats()
let scheduler = TodoScheduler(chats: chats, store: store)
let released = NotificationCenter.default.addObserver(forName: .projectReleased, object: nil, queue: nil) { _ in chats.events.append("released") }
scheduler.start()   // wakes on chats answering, on the board and on a repository's release

// Two TODOs in one list in order: B waits for A.
let a = try! store.add(title: "A", project: project, projectName: "P")
let b = try! store.add(title: "B", project: project, projectName: "P")
pump()
expect(chats.events.isEmpty, "drafts wait for Start")
scheduler.startNow()
pump()
expect(chats.events == ["start TODO: A"] && store.current.item(a.id)?.state == .running && store.current.item(b.id)?.state == .ready,
       "Start: the first in order runs, the next waits: \(chats.events)")
let roomA = store.current.item(a.id)!.room!
expect(chats.titles[roomA] == "TODO · A", "the TODO gets a chat of its own")

// Retry: A's answer fails while its chat holds the repository. A is ready again (one attempt counted, a retry note)
// and starts again before B, even though B would be free.
let held = try! ProjectWork.acquire(WorkspaceBinding(roots: [WorkspaceRoot(path: repo.path, directory: true, writable: true)], level: .execute))
expect(ProjectWork.isHeld(repo.path), "the chat's lock holds the folder")
chats.endings[roomA] = TodoTurnEnd(error: "network down")
chats.answering.remove(roomA)
pump()
var now = store.current.item(a.id)!
expect(now.attempts == 1 && now.notes.last?.kind == .retry && now.lastError == "network down", "an error is counted and noted: \(now.attempts)")
expect(chats.events == ["start TODO: A"] && now.state == .ready, "nothing starts while the repository is held: \(chats.events)")
// Let go: the release wakes the scheduler (no tick here), and A comes before B.
ProjectWork.release(held)
pump()
expect(chats.events == ["start TODO: A", "released", "start TODO: A"], "the release starts the retry first, not the next TODO: \(chats.events)")
now = store.current.item(a.id)!
expect(now.room == roomA && chats.questions.last?.contains("network down") == true, "the retry runs in the same chat and is told the error")

// A busy repository (another chat writing) is not the TODO's fault: no attempt counted, no note.
chats.endings[roomA] = TodoTurnEnd(error: ProjectWork.busyEnglish)
chats.answering.remove(roomA)
pump()
now = store.current.item(a.id)!
expect(now.attempts == 1 && now.notes.filter { $0.kind == .retry }.count == 1, "a busy repository does not count: \(now.attempts)")
expect(chats.events.suffix(1) == ["start TODO: A"] && now.state == .running, "and it is tried again: \(chats.events)")

// The retries run out: the user decides. With "next after my check" B (after it, in order) does not start;
// without it B would go on (A is passed, B waits for nothing).
try! store.setList(a.listID, waitForDone: true)
for _ in 0..<TodoScheduler.maxAttempts {
    chats.endings[roomA] = TodoTurnEnd(error: "still down")
    chats.answering.remove(roomA)
    pump()
}
now = store.current.item(a.id)!
expect(now.state == .needsYou && now.attempts == TodoScheduler.maxAttempts + 1 && now.question?.reason.contains("still down") == true,
       "after \(TodoScheduler.maxAttempts) retries the user decides: \(now.state) \(now.attempts)")
expect(!chats.events.contains("start TODO: B") && store.current.item(b.id)?.state == .ready, "B waits while A needs the user, after my check")
var going = store.current
going.lists[going.lists.firstIndex { $0.id == a.listID }!].waitForDone = false
expect(going.blockers(going.item(b.id)!).isEmpty, "without it a question does not hold B")

// The user's answer: ready again with the answer, attempts back to 0. This time A reports while its chat still holds
// the repository: A waits for the check, B may start, but only after the lock is let go.
store.answer(a.id, "try once more")
try! store.setList(a.listID, waitForDone: false)
let lock = try! ProjectWork.acquire(WorkspaceBinding(roots: [WorkspaceRoot(path: repo.path, directory: true, writable: true)], level: .execute))
pump()
expect(store.current.item(a.id)?.state == .ready && store.current.item(a.id)?.attempts == 0, "the answer makes it ready again")
ProjectWork.release(lock)
pump()
expect(chats.events.suffix(2) == ["released", "start TODO: A"], "the answered TODO starts after the release: \(chats.events)")
let lock2 = try! ProjectWork.acquire(WorkspaceBinding(roots: [WorkspaceRoot(path: repo.path, directory: true, writable: true)], level: .execute))
try! store.change(a.id) { var report = TodoReport(); report.summary = "done it"; report.files = ["a.txt"]; $0.report = report }
chats.endings[roomA] = TodoTurnEnd()
chats.answering.remove(roomA)
pump()
now = store.current.item(a.id)!
expect(now.state == .review && now.result == "done it" && now.report == nil && now.files == ["a.txt"], "a report waits for the check once the chat ended: \(now.state)")
expect(!chats.events.contains("start TODO: B"), "the next TODO waits for the repository lock")
ProjectWork.release(lock2)
pump()
expect(chats.events.suffix(2) == ["released", "start TODO: B"], "the lock's release starts the next TODO: \(chats.events)")
let roomB = store.current.item(b.id)!.room!
expect(roomB != roomA && store.current.item(b.id)?.state == .running, "the next TODO runs in a chat of its own")

// The scheduler's cancel stops the chat; the TODO is cancelled.
scheduler.cancel(b.id)
expect(chats.events.last == "stop" && store.current.item(b.id)?.state == .cancelled, "Stop cancels a running TODO and stops its chat")

// One answering place stays free for the user: with two chats answering, nothing starts.
let c = try! store.add(title: "C", project: project, projectName: "P")
store.accept(a.id)
chats.answering = [UUID(), UUID()]
store.startDrafts()
scheduler.tick()
expect(store.current.item(c.id)?.state == .ready && scheduler.waiting != nil, "one of the places stays free for the user")
chats.answering = []
pump()
expect(chats.events.last == "start TODO: C", "a free place starts it")

// The saved file: pretty, sorted keys, the TODO's known keys; it reads back the same.
let text = try! String(contentsOf: store.url, encoding: .utf8)
expect(text.contains("\n  \"items\" : [") && text.contains("\"lists\" : [") && text.range(of: "\"items\"")!.lowerBound < text.range(of: "\"lists\"")!.lowerBound
       && text.contains("\"version\" : 1"), "todos.json keeps its shape")
expect(TodoStore(url: store.url).current == store.current, "todos.json reads back")

// After a quit: running TODOs are ready again, interrupted, one attempt counted.
let reread = TodoStore(url: store.url)
let after = TodoScheduler(chats: FakeChats(), store: reread)
after.recover()
expect(reread.current.item(c.id)?.state == .ready && reread.current.item(c.id)?.interrupted == true && reread.current.item(c.id)?.attempts == 1,
       "restart: a running TODO is ready again and checks what is left")
// An unreadable file is held, never written over.
let broken = base.appendingPathComponent("broken.json")
try! "{\"version\": 1, \"items\": [{\"id\": 1}]}".write(to: broken, atomically: true, encoding: .utf8)
let held2 = TodoStore(url: broken)
expect(held2.locked != nil && (try? held2.add(title: "x", project: project, projectName: "P")) == nil
       && (try! String(contentsOf: broken, encoding: .utf8)).contains("\"id\": 1"), "an unreadable todos.json is held")

// The repository lock: a second writer of the same folder is refused with the busy text; the release lets it in.
let first = try! ProjectWork.acquire(WorkspaceBinding(roots: [WorkspaceRoot(path: repo.path, directory: true, writable: true)], level: .execute, project: ProjectBinding(root: repo.path, common: repo.path, remote: "", remoteURL: "", kind: ProjectBinding.documentsKind)))
do { _ = try ProjectWork.acquire(WorkspaceBinding(roots: [WorkspaceRoot(path: repo.path, directory: true, writable: true)], level: .execute)); expect(false, "a second writer is refused") }
catch { expect(ProjectWork.isBusy(error.localizedDescription), "the refusal is the busy text: \(error.localizedDescription)") }
ProjectWork.release(first, notify: false)
expect(!ProjectWork.isHeld(repo.path), "released")

// Scoped tools: work_plan, task_done/task_ask and the Git tools only for the live attempt of the run's own chat.
let documents = ProjectBinding(root: repo.path, common: repo.path, remote: "", remoteURL: "", kind: ProjectBinding.documentsKind)
let todoRoom = store.current.item(c.id)!.room!
try! store.change(c.id) { $0.state = .running }
let run = ProjectRun(room: todoRoom, binding: documents, token: DebateCancellation())
ProjectWork.register(run)
var revoked: [UUID] = []
let savedRevoke = ProjectWork.revokeTools
ProjectWork.revokeTools = { revoked.append($0) }
run.nextAttempt()
expect(revoked == [run.id], "a new attempt ends the earlier attempt's tool sessions")
let context = ToolContext(room: todoRoom, roots: [], projectRun: run.id, projectGeneration: run.generation)
var stale = context; stale.projectGeneration = run.generation - 1
var elsewhere = context; elsewhere.room = UUID()
func names(_ p: ToolProvider, _ c: ToolContext) -> [String] { p.tools(context: c).compactMap { $0["name"] as? String } }
let savedShared = TodoStore.shared
TodoStore.shared = store
expect(names(PlanLink.shared, context) == ["work_plan"] && names(TaskLink.shared, context) == ["task_done", "task_ask"] && names(GitLink.shared, context) == ["project_run"],
       "the live attempt gets its tools (documents: project_run only)")
let scoped: [ToolProvider] = [PlanLink.shared, TaskLink.shared, GitLink.shared]
expect(scoped.allSatisfy { names($0, stale).isEmpty && names($0, elsewhere).isEmpty && $0.tools().isEmpty },
       "an earlier attempt, another chat and the global list get none")
let done = TaskLink.shared.call("task_done", ["summary": "ok", "files": ["f"]], context: context)
expect(done["isError"] as? Bool == false && store.current.item(c.id)?.report?.summary == "ok", "task_done keeps the report with the attempt")
expect(TaskLink.shared.call("task_done", ["summary": "ok"], context: elsewhere)["isError"] as? Bool == true, "another chat cannot report")
let plan = PlanLink.shared.call("work_plan", ["steps": [["text": "one", "status": "doing"]]], context: context)
expect(plan["isError"] as? Bool == false && "\(plan)".contains("Plan shown: 0/1 done."), "work_plan shows the steps: \(plan)")
run.endAttempt()
expect(revoked == [run.id, run.id] && names(PlanLink.shared, context).isEmpty, "an ended attempt has no tools and its sessions end")
ProjectWork.finish(run)
expect(!ProjectWork.active && names(TaskLink.shared, context).isEmpty && revoked.count == 3, "a finished run is gone and its sessions end")
ProjectWork.revokeTools = savedRevoke
TodoStore.shared = savedShared

// The work binding: execute, writable only in the project's root and the chat's folder.
let chatFolder = base.appendingPathComponent("chat").path
let linked = WorkspaceBinding(roots: [WorkspaceRoot(path: repo.path, directory: true), WorkspaceRoot(path: chatFolder, directory: true), WorkspaceRoot(path: "/tmp/shared", directory: true, writable: true)], project: documents)
let work = ProjectWork.workBinding(linked, project: documents, chatFolder: chatFolder, run: run)
expect(work.level == .execute && work.roots.map(\.writable) == [true, true, nil] && work.projectRunID == run.id, "work binding: \(work.roots.map(\.writable))")

// Linking and moving a chat's project, the AI's stream plan, a project's TODO lock (C0, moved down from the chat side).
do {
    let code = ProjectBinding(root: "/tmp/code", common: "/tmp/code/.git", remote: "origin", remoteURL: "", kind: nil)
    let mine = WorkspaceBinding(roots: [WorkspaceRoot(path: "/tmp/notes", directory: true), WorkspaceRoot(path: "/tmp/code", directory: true)])
    let linked = ProjectWork.linking(mine, to: code, first: false)
    expect(linked.roots.map(\.path) == ["/tmp/notes", "/tmp/code"] && linked.roots[1].writable == nil && linked.project == code, "a code project already linked keeps its place")
    let fresh = ProjectWork.linking(nil, to: code, first: false)
    expect(fresh.roots.map(\.path) == ["/tmp/code"] && fresh.roots[0].writable == true, "a chat with nothing gets the root, writable")
    let docs = ProjectWork.linking(mine, to: documents, first: true)
    expect(docs.roots.first?.path == documents.root && docs.roots.first?.writable == true && docs.roots.filter { $0.path == documents.root }.count == 1 && docs.project == documents, "a documents project's root leads")
    var running = linked; running.projectRunID = UUID(); running.projectGeneration = 3
    let moved = ProjectWork.moving(running, to: documents)
    expect(moved.roots.map(\.path) == [documents.root, "/tmp/notes"] && moved.project == documents && moved.projectRunID == nil && moved.projectGeneration == nil, "moved: the old root goes, no run stays")

    let planRun = ProjectRun(room: UUID(), binding: documents, token: DebateCancellation())
    var shown: [WorkStep] = []
    planRun.onPlan = { steps, _ in shown = steps }
    let todo: [[String: Any]] = [["content": "read", "status": "completed"], ["content": "write", "status": "in_progress"]]
    expect(planRun.setPlan(todos: todo, generation: planRun.generation) && shown.map(\.text) == ["read", "write"] && shown.map(\.status) == [.done, .doing], "the stream's task list becomes the plan")
    expect(!planRun.setPlan(todos: "nonsense", generation: planRun.generation) && shown.count == 2, "an unreadable list changes nothing")
    expect(!planRun.setPlan(todos: todo, generation: planRun.generation + 1), "another attempt's list is ignored")

    let lockStore = TodoStore(url: base.appendingPathComponent("lock-todos.json"))
    let personal = EnterpriseLock(organization: "personal", name: "Personal", lockedAt: Date())
    try? lockStore.lockProject(code.groupKey, name: "Code", project: code, lock: personal)
    expect(lockStore.current.lists.count == 1 && lockStore.current.lists[0].lock?.organization == "personal" && lockStore.current.lists[0].project == code, "a project with no list gets a locked one")
    try? lockStore.lockProject(code.groupKey, name: "Code", project: code, lock: EnterpriseLock(organization: "work", name: "W", lockedAt: Date()))
    expect(lockStore.current.lists.count == 1 && lockStore.current.lists[0].lock?.organization == "personal", "a list keeps the lock it has")
}


// The screen's publish entry point uses a real approval and only a temporary local remote.
do {
    let root = base.appendingPathComponent("publish")
    let remote = base.appendingPathComponent("remote.git")
    try fm.createDirectory(at: root, withIntermediateDirectories: true)
    func git(_ args: [String]) throws -> String { try ProjectProcess.git(args, root: root.path) }
    _ = try git(["init", "--bare", remote.path])
    _ = try git(["init", "-b", "main"])
    _ = try git(["config", "user.name", "Test"])
    _ = try git(["config", "user.email", "test@example.invalid"])
    _ = try git(["remote", "add", "origin", remote.path])
    _ = try git(["commit", "--allow-empty", "-m", "first"])
    _ = try git(["push", "-u", "origin", "main"])
    let binding = try ProjectProcess.inspect(root.path)
    let sha = try git(["rev-parse", "main"])
    let room = UUID()
    func publish(allow: Bool) -> (String?, String?) {
        let lock = NSLock()
        var done = false, value: String?, problem: String?
        DispatchQueue.global().async {
            do { let result = try GitLink.shared.publishStable(binding, room: room, onWaiting: { _ in })
                lock.lock(); value = result; lock.unlock()
            } catch { lock.lock(); problem = error.localizedDescription; lock.unlock() }
            lock.lock(); done = true; lock.unlock()
        }
        let deadline = Date().addingTimeInterval(15)
        var sawCard = false
        while Date() < deadline {
            pump(0.02)
            if let request = ProjectCenter.shared.requests.first(where: { $0.room == room }) {
                expect(request.detail.contains("Exact SHA: " + sha), "the card pins the exact main SHA")
                expect(ProjectWork.isHeld(root.path), "approval keeps the repository locked")
                expect((try? git(["ls-remote", "origin", "refs/heads/stable"])) == "", "nothing published before approval")
                sawCard = true
                ProjectCenter.shared.decide(request.id, allow: allow)
            }
            lock.lock(); let finished = done; lock.unlock()
            if finished { break }
        }
        lock.lock(); let finished = done, result = value, error = problem; lock.unlock()
        expect(finished && sawCard, "publish finishes through a visible approval")
        expect(!ProjectWork.isHeld(root.path), "publish releases the lock on success and refusal")
        return (result, error)
    }
    let denied = publish(allow: false)
    expect(denied.0 == nil && denied.1 != nil, "refusal does not publish")
    expect((try? git(["ls-remote", "origin", "refs/heads/stable"])) == "", "stable stays absent after refusal")
    let allowed = publish(allow: true)
    expect(allowed.0?.contains("Published " + sha) == true && allowed.1 == nil, "first stable publication succeeds")
    expect((try? git(["ls-remote", "origin", "refs/heads/stable"]))?.hasPrefix(sha) == true, "remote stable is exactly the approved SHA")
    let same = try GitLink.shared.publishStable(binding, room: room, onWaiting: { _ in })
    expect(!same.contains("Published ") && ProjectCenter.shared.requests.isEmpty, "already published needs no approval")
    try "dirty".write(to: root.appendingPathComponent("dirty.txt"), atomically: true, encoding: .utf8)
    do { _ = try GitLink.shared.publishStable(binding, room: room, onWaiting: { _ in }); expect(false, "dirty tree must fail") }
    catch { expect(!ProjectWork.isHeld(root.path), "dirty refusal releases the lock") }
    let held = try ProjectWork.acquire(WorkspaceBinding(roots: [WorkspaceRoot(path: root.path, directory: true, writable: true)], level: .execute, project: binding))
    do { _ = try GitLink.shared.publishStable(binding, room: room, onWaiting: { _ in }); expect(false, "second publish must fail") }
    catch { expect(ProjectWork.isBusy(error.localizedDescription), "second publish respects repository lock") }
    ProjectWork.release(held, notify: false)
} catch { fatalError("publish contract: \(error)") }

// The screen's pull: fast-forward main only, clean tree, main checked out, repository lock released.
do {
    let remote = base.appendingPathComponent("remote.git"), clone = base.appendingPathComponent("pull-clone")
    func git(_ args: [String], _ dir: URL) throws -> String { try ProjectProcess.git(args, root: dir.path) }
    _ = try git(["clone", "-q", remote.path, clone.path], base)
    _ = try git(["config", "user.name", "Test"], clone); _ = try git(["config", "user.email", "test@example.invalid"], clone)
    let publisher = base.appendingPathComponent("publish")
    _ = try git(["commit", "--allow-empty", "-m", "newer"], publisher); _ = try git(["push", "-q", "origin", "main"], publisher)
    let binding = try ProjectProcess.inspect(clone.path)
    try "dirty".write(to: clone.appendingPathComponent("dirty.txt"), atomically: true, encoding: .utf8)
    do { _ = try GitLink.shared.pullMain(binding); expect(false, "dirty pull must fail") }
    catch { expect(!ProjectWork.isHeld(clone.path) && fm.fileExists(atPath: clone.appendingPathComponent("dirty.txt").path), "dirty pull keeps the edit and releases the lock") }
    try fm.removeItem(at: clone.appendingPathComponent("dirty.txt"))
    _ = try git(["switch", "-q", "-c", "fix/z"], clone)
    do { _ = try GitLink.shared.pullMain(binding); expect(false, "pull on another branch must fail") } catch {}
    _ = try git(["switch", "-q", "main"], clone)
    let held = try ProjectWork.acquire(WorkspaceBinding(roots: [WorkspaceRoot(path: clone.path, directory: true, writable: true)], level: .execute, project: binding))
    do { _ = try GitLink.shared.pullMain(binding); expect(false, "pull must wait for the lock") }
    catch { expect(ProjectWork.isBusy(error.localizedDescription), "pull respects the repository lock") }
    ProjectWork.release(held, notify: false)
    _ = try GitLink.shared.pullMain(binding)
    let pulled = try git(["rev-parse", "HEAD"], clone), pushed = try git(["rev-parse", "HEAD"], publisher)
    expect(pulled == pushed && !ProjectWork.isHeld(clone.path), "pull fast-forwards main and releases the lock")
    _ = try git(["commit", "--allow-empty", "-m", "local"], clone)
    _ = try git(["commit", "--allow-empty", "-m", "other"], publisher); _ = try git(["push", "-q", "origin", "main"], publisher)
    do { _ = try GitLink.shared.pullMain(binding); expect(false, "diverged pull must fail") }
    catch { expect(try! git(["log", "-1", "--format=%s"], clone) == "local", "diverged: ff-only leaves main as it was") }
} catch { fatalError("pull contract: \(error)") }

print("PASS: Projects promises (TODO retry, busy repository, the user after retries, report on the check, next start after the lock's release, cancel, a free place, restart, todos.json, repository lock, scoped tools, work binding)")
exit(0)
