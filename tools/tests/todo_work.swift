import Foundation
import Cocoa
import AIAccounts
import AILocalization

// TODO work (Todo.swift): the store and its order rules, task_done / task_ask, and the scheduler running TODOs
// in their own chats with fake AI answers. Every store is a file in the test folder, never the real todos.json.
private func todoProject(_ name: String) -> ProjectBinding {
    let root = URL(fileURLWithPath: AccountStore.home).appendingPathComponent(name)
    try? FileManager.default.removeItem(at: root)
    try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    func git(_ args: [String]) { _ = try! ProjectProcess.git(args, root: root.path) }
    git(["init", "-b", "main"]); git(["config", "user.name", "Fixture"]); git(["config", "user.email", "fixture@example.invalid"])
    git(["remote", "add", "origin", root.path + "/unused-origin"])
    try! "Baseline".write(to: root.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
    git(["add", "README.md"]); git(["commit", "-m", "Initial"])
    return try! ProjectProcess.inspect(root.path)
}
private func todoStoreFile(_ name: String) -> URL {
    let url = URL(fileURLWithPath: AccountStore.home).appendingPathComponent("todo-tests/\(name).json")
    try? FileManager.default.removeItem(at: url)
    return url
}

func testTodoStore() {
    let a = ProjectBinding(root: "/tmp/todo-a", common: "", remote: "", remoteURL: "")
    let b = ProjectBinding(root: "/tmp/todo-b", common: "", remote: "", remoteURL: "")
    let url = todoStoreFile("store")
    let store = TodoStore(url: url)
    let one = try! store.add(title: "one", project: a, projectName: "A")
    let two = try! store.add(title: "two", project: a, projectName: "A")
    let three = try! store.add(title: "three", project: a, projectName: "A")
    let other = try! store.add(title: "other", project: b, projectName: "B", after: [two.id])
    let free = { (_: String) in false }
    expect(store.current.lists.count == 2 && store.current.items.allSatisfy { $0.state == .draft }, "one list per project; new TODOs are drafts")
    expect(store.current.eligible(held: free).isEmpty, "drafts are never taken")
    store.startDrafts()
    // In order: only the first of A; B waits for "two" in A.
    expect(store.current.eligible(held: free).map(\.title) == ["one"], "a list in order starts its first TODO only: \(store.current.eligible(held: free).map(\.title))")
    try! store.change(one.id) { $0.state = .running }
    expect(store.current.eligible(held: free).isEmpty, "one TODO per folder at a time, and the next waits")
    try! store.change(one.id) { $0.state = .review }
    expect(store.current.eligible(held: free).map(\.title) == ["two"], "the next starts when the previous waits for the check")
    try! store.setList(store.current.lists[0].id, waitForDone: true)
    expect(store.current.eligible(held: free).isEmpty, "\"after my check\": the next waits for Done")
    store.accept(one.id)
    expect(store.current.item(one.id)?.state == .done && store.current.eligible(held: free).map(\.title) == ["two"], "Done lets the next one start")
    expect(store.current.eligible(held: { $0 == a.root }).isEmpty, "a folder a chat is writing is skipped")
    // Not in order: every ready TODO of the list may start (one at a time per folder is the scheduler's job).
    try! store.setList(store.current.lists[0].id, sequential: false)
    expect(store.current.eligible(held: free).map(\.title) == ["two", "three"], "a list without order offers all of them")
    try! store.setList(store.current.lists[0].id, sequential: true, waitForDone: false)
    // Across lists and cycles.
    try! store.change(two.id) { $0.state = .review }
    expect(store.current.eligible(held: free).map(\.title) == ["three", "other"], "a TODO in another list waits for its link: \(store.current.eligible(held: free).map(\.title))")
    do { try store.setAfter(one.id, [other.id]); expect(false, "a circle is refused") } catch { expect(error as? TodoError == .cycle, "the circle error is shown") }
    do { try store.setAfter(two.id, [three.id]); expect(false, "a circle through the list order is refused") } catch {}
    expect(store.current.item(one.id)?.after.isEmpty == true, "a refused change leaves the store as it was")
    // Order: move up and down.
    try! store.move(three.id, by: -1)
    expect(store.current.ordered(store.current.lists[0].id).map(\.title) == ["one", "three", "two"], "move changes the order")
    try! store.move(three.id, by: 1)
    // A cancelled link: the TODO needs the user, and the answer drops the link.
    try! store.change(two.id) { $0.state = .ready }
    try! store.cancel(two.id)
    expect(store.current.cancelledBlockers(store.current.item(other.id)!).map(\.title) == ["two"], "a cancelled TODO it waits for is found")
    try! store.change(other.id) { $0.state = .needsYou }
    store.answer(other.id, "go ahead")
    let answered = store.current.item(other.id)!
    expect(answered.state == .ready && answered.after.isEmpty && answered.notes.last?.text == "go ahead", "the answer makes it ready, drops the cancelled link and keeps the answer")
    expect(store.current.blockers(store.current.item(three.id)!) == [one.id], "a list in order skips a cancelled TODO above")
    // Saved, read back, and older files with missing or unknown fields.
    let again = TodoStore(url: url)
    expect(again.current == store.current, "the store reads back what it saved")
    let old = """
        {"lists":[{"id":"\(UUID().uuidString)","title":"Old","future":1}],"items":[{"id":"\(UUID().uuidString)","listID":"\(UUID().uuidString)","title":"t","extra":true}]}
        """
    let oldURL = todoStoreFile("old")
    try! FileManager.default.createDirectory(at: oldURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try! old.write(to: oldURL, atomically: true, encoding: .utf8)
    let read = TodoStore(url: oldURL).current
    expect(read.lists.first?.sequential == true && read.items.first?.state == .draft && read.version == 1, "older files: defaults for missing fields, unknown ones ignored")
    do { try store.delete(three.id) } catch { expect(false, "delete") }
    try! store.change(one.id) { $0.state = .running }
    do { try store.delete(one.id); expect(false, "a running TODO is not deleted") } catch {}
    // Added while its list is going (one running): it joins the queue as ready and is next after it; another project's list stays a draft.
    let joined = try! store.add(title: "joined", project: a, projectName: "A")
    expect(store.current.item(joined.id)?.state == .ready, "a TODO added to a running list is ready")
    let idle = try! store.add(title: "idle", project: ProjectBinding(root: "/tmp/todo-c", common: "", remote: "", remoteURL: ""), projectName: "C")
    expect(store.current.item(idle.id)?.state == .draft, "a TODO added to a list that is not going is a draft")
    // A chat letting go of a repository is announced (the scheduler wakes for the next TODO at once).
    var released = 0
    let releaseWatch = NotificationCenter.default.addObserver(forName: .projectReleased, object: nil, queue: nil) { _ in released += 1 }
    ProjectWork.release([]); ProjectWork.release(["/tmp/todo-not-held"])
    NotificationCenter.default.removeObserver(releaseWatch)
    expect(released == 1, "releasing locks is announced, releasing none is not: \(released)")
    // A save that fails changes nothing and says so (a folder stands where the file goes).
    let blockedURL = todoStoreFile("blocked")
    let blocked = TodoStore(url: blockedURL)   // read while missing, so not held; the folder comes after
    try! FileManager.default.createDirectory(at: blockedURL.appendingPathComponent("inside"), withIntermediateDirectories: true)
    do { _ = try blocked.add(title: "lost", project: a, projectName: "A"); expect(false, "a failed save is an error") } catch { expect(error is TodoError, "the save error is a TODO error: \(error)") }
    expect(blocked.current.items.isEmpty && blocked.snapshot.items.isEmpty && blocked.saveError != nil, "a failed save leaves the TODOs as they were and is shown")
    // A file this version cannot read (broken, a field that does not fit, a newer state or version, a folder that
    // cannot be opened) is held: nothing is saved over it and the board says why.
    let listText = "{\"id\":\"\(UUID().uuidString)\",\"title\":\"Keep\"}"
    for (name, text) in [("broken", "{\"lists\": ["), ("badfield", "{\"lists\":[\(listText)],\"items\":[{\"id\":\"\(UUID().uuidString)\",\"listID\":\"\(UUID().uuidString)\",\"notes\":\"oops\"}]}"),
                         ("newstate", "{\"lists\":[\(listText)],\"items\":[{\"id\":\"\(UUID().uuidString)\",\"listID\":\"\(UUID().uuidString)\",\"state\":\"someday\"}]}"),
                         ("newversion", "{\"version\":2,\"lists\":[\(listText)]}"),
                         ("nullitems", "{\"lists\":[\(listText)],\"items\":null}"),
                         ("nullstate", "{\"lists\":[\(listText)],\"items\":[{\"id\":\"\(UUID().uuidString)\",\"listID\":\"\(UUID().uuidString)\",\"state\":null}]}")] {
        let heldURL = todoStoreFile("held-" + name)
        try! FileManager.default.createDirectory(at: heldURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try! text.write(to: heldURL, atomically: true, encoding: .utf8)
        let held = TodoStore(url: heldURL)
        expect(held.locked != nil && held.saveError != nil, "\(name): the file is held and the board says so")
        do { _ = try held.add(title: "over", project: a, projectName: "A"); expect(false, "\(name): a held file refuses changes") } catch {
            expect(error as? TodoError == .locked(held.locked!), "\(name): the refusal is the held reason: \(error)")
        }
        held.startDrafts()
        expect((try? String(contentsOf: heldURL, encoding: .utf8)) == text, "\(name): the file is left byte for byte")
    }
    let unreadable = todoStoreFile("unreadable")
    try! FileManager.default.createDirectory(at: unreadable, withIntermediateDirectories: true)
    expect(TodoStore(url: unreadable).locked != nil, "a todos.json that cannot be opened is held too")
    expect(TodoStore(url: todoStoreFile("missing-\(UUID().uuidString)")).locked == nil, "only a missing file starts empty")
    let nullRoom = "{\"id\":\"\(UUID().uuidString)\",\"listID\":\"\(UUID().uuidString)\",\"room\":null,\"report\":null}"
    expect((try? JSONDecoder().decode(TodoItem.self, from: Data(nullRoom.utf8)))?.room == nil, "null in a field that may be empty is just empty")
    // Deleting a project's lists: only theirs go (TODOs and attachments), links from other lists are dropped, a running one refuses.
    let gone = TodoStore(url: todoStoreFile("delete-lists"))
    let first = try! gone.add(title: "first", project: a, projectName: "A")
    let second = try! gone.add(title: "second", project: a, projectName: "A")
    let shot = URL(fileURLWithPath: AccountStore.home).appendingPathComponent("todo-tests/shot.txt")
    try! "x".write(to: shot, atomically: true, encoding: .utf8)
    try! gone.attach(first.id, files: [shot])
    let kept = try! gone.add(title: "kept", project: b, projectName: "B", after: [second.id])
    let listA = gone.current.item(first.id)!.listID, listB = gone.current.item(kept.id)!.listID
    try! gone.change(second.id) { $0.state = .running }
    do { try gone.deleteLists([listA]); expect(false, "a running TODO keeps its list") } catch { expect(error as? TodoError == .busy && gone.current.items.count == 3, "refused while running, nothing deleted") }
    try! gone.change(second.id) { $0.state = .review }
    expect(try! gone.deleteLists([listA]) == 2, "both TODOs of the list deleted")
    expect(gone.current.lists.map(\.id) == [listB] && gone.current.items.map(\.title) == ["kept"] && gone.current.item(kept.id)?.after.isEmpty == true,
           "only the other list is left, and it no longer waits for a deleted TODO")
    expect(!FileManager.default.fileExists(atPath: gone.folder(first.id).path) && FileManager.default.fileExists(atPath: shot.path), "attachment copies go, the original stays")
    expect(TodoStore(url: gone.url).current == gone.current && (try! gone.deleteLists([])) == 0, "saved; nothing to delete is fine")
    print("PASS: TODO store (held unreadable files, drafts, joining a running list, release wakes, order and folder, gate review/done, other lists, circles refused, move, cancelled link, saved and read back, older files, failed save)")
}

func testTodoScheduler() {
    let project = todoProject("todo-project")
    let saved = TodoStore.shared
    let store = TodoStore(url: todoStoreFile("scheduler"))
    TodoStore.shared = store
    defer { TodoStore.shared = saved }
    let model = AppModel()
    model.accounts = [Account(id: "todo-claude", provider: .claude, name: "Todo Claude"), Account(id: "todo-codex", provider: .codex, name: "Todo Codex"),
                      Account(id: "todo-gemini", provider: .gemini, name: "Todo Gemini")]
    func left(_ five: Double, _ week: Double) -> AIUsage {
        var u = AIUsage(name: "x"); u.fiveHour = UsageWindow(usedPercent: 100 - five, resetsAt: nil); u.weekly = UsageWindow(usedPercent: 100 - week, resetsAt: nil); return u
    }
    model.latestUsage["todo-claude"] = left(80, 70)
    model.latestUsage["todo-codex"] = left(25, 90)   // under 30%: no TODO work, so no reviewer either
    model.latestUsage["todo-gemini"] = left(100, 100)
    let chat = Discussion(model: model)
    let open = chat.currentID
    chat.draft = "my own message"
    let scheduler = TodoScheduler(discussion: chat, store: store)
    var asked: [String] = [], toolsSeen: [String] = []
    chat.workspaceAnswer = { account, prompt, binding, _, _ in
        asked.append(account.id)
        let room = store.current.items.first { $0.state == .running }?.room ?? UUID()
        let context = ToolContext(room: room, roots: binding.roots, projectRun: binding.projectRunID, projectGeneration: binding.projectGeneration)
        toolsSeen = TaskLink.shared.tools(context: context).compactMap { $0["name"] as? String }
        var elsewhere = context; elsewhere.room = UUID()
        expect(TaskLink.shared.tools(context: elsewhere).isEmpty && TaskLink.shared.call("task_done", ["summary": "x"], context: elsewhere)["isError"] as? Bool == true,
               "task tools only in the TODO's own chat")
        let current = prompt.components(separatedBy: "[User]\n").last ?? ""
        if current.hasPrefix("TODO: first") {
            expect(prompt.contains("[TODO work]") && prompt.contains("Never publish stable") && prompt.contains("reasonable assumption"), "the TODO instructions are sent")
            let r = TaskLink.shared.call("task_done", ["summary": "Did the first", "assumptions": ["kept the API"], "files": ["a.swift"]], context: context)
            expect(r["isError"] as? Bool == false, "task_done is accepted: \(r)")
            return .success("First done.")
        }
        if current.hasPrefix("TODO: second") {
            if current.contains("Answer: use B") { _ = TaskLink.shared.call("task_done", ["summary": "Used B"], context: context); return .success("Second done.") }
            expect(prompt.contains("ask with task_ask what is unclear"), "ask first: the AI asks before changing anything")
            let tooMany = TaskLink.shared.call("task_ask", ["kind": "question", "reason": "r", "questions": [["text": "1"], ["text": "2"], ["text": "3"], ["text": "4"]]], context: context)
            expect(tooMany["isError"] as? Bool == true, "more than 3 questions are refused")
            _ = TaskLink.shared.call("task_ask", ["kind": "question", "reason": "Which way?", "questions": [["text": "A or B?", "options": ["A", "B"], "recommended": "B"]]], context: context)
            return .success("I need your decision.")
        }
        if current.hasPrefix("TODO: late") {
            // Reported, then the rest of the attempt (the review, the fixes) fails: not waiting for the check.
            _ = TaskLink.shared.call("task_done", ["summary": "Too early"], context: context)
            let now = store.current.items.first { $0.room == room }
            expect(now?.state == .running && now?.report?.summary == "Too early" && toolsSeen.contains("task_ask"), "task_done keeps the TODO running until the attempt is over")
            return .failure(.failed("review broke"))
        }
        if current.hasPrefix("TODO: secret") { _ = TaskLink.shared.call("task_done", ["summary": "Kept inside"], context: context); return .success("Done.") }
        if current.hasPrefix("TODO: flaky") { return asked.filter { $0 == account.id }.count < 99 ? .failure(.failed("network down")) : .success("") }
        return .success("Ended without a report.")
    }
    func settle(_ until: () -> Bool) {
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline && (!until() || chat.anyRunning) { RunLoop.main.run(until: Date().addingTimeInterval(0.03)); scheduler.tick() }
    }
    var notices: [String] = []
    let watcher = NotificationCenter.default.addObserver(forName: .todoNeedsUser, object: nil, queue: nil) { notices.append($0.userInfo?["title"] as? String ?? "") }
    defer { NotificationCenter.default.removeObserver(watcher) }

    let first = try! store.add(title: "first", project: project, projectName: "P", originRoom: open)
    let second = try! store.add(title: "second", project: project, projectName: "P", askFirst: true)
    scheduler.tick()
    expect(store.current.items.allSatisfy { $0.state == .draft } && !chat.anyRunning, "drafts wait for Start")
    scheduler.startNow()
    expect(store.current.item(first.id)?.state == .running && store.current.item(second.id)?.state == .ready, "Start: the first in order runs, the second waits")
    let room = store.current.item(first.id)!.room!
    expect(chat.currentID == open && chat.draft == "my own message" && chat.conversation(room).isProjectChat, "the TODO runs in its own project chat; the open chat is untouched")
    settle { store.current.item(second.id)?.state == .needsYou }
    let done = store.current.item(first.id)!
    expect(done.state == .review && done.result == "Did the first" && done.assumptions == ["kept the API"] && done.files == ["a.swift"], "task_done: waits for the check with the report")
    expect(asked.allSatisfy { $0 == "todo-claude" } && toolsSeen == ["task_done", "task_ask"], "only the account with 30% left works: \(asked) \(toolsSeen)")
    expect(chat.conversation(room).configuration?.memberIDs == ["todo-claude"], "no reviewer under 30%")
    // The second started when the first waited for the check (in order, the default gate), and asked.
    let asking = store.current.item(second.id)!
    expect(asking.question?.items.first?.recommended == "B" && asking.room != room, "task_ask: the user decides, in the second TODO's own chat")
    expect(notices.sorted() == ["first", "second"], "the result and the question are announced once: \(notices)")
    // The answer goes with the next attempt, in the same chat.
    store.answer(second.id, "use B")
    settle { store.current.item(second.id)?.state == .review }
    expect(store.current.item(second.id)?.result == "Used B" && store.current.item(second.id)?.room == asking.room, "the answer is sent and the work finishes in the same chat")
    // Change request on the first: ready again, the feedback in the next question.
    store.accept(first.id)
    expect(store.current.item(first.id)?.state == .done, "Done")
    // No report: the user decides.
    let silent = try! store.add(title: "silent", project: project, projectName: "P")
    scheduler.startNow()
    settle { store.current.item(silent.id)?.state == .needsYou }
    expect(store.current.item(silent.id)?.question?.blocked == true, "ending without task_done/task_ask asks the user")
    try! store.cancel(silent.id)
    // Errors: retried twice, then the user decides.
    let flaky = try! store.add(title: "flaky", project: project, projectName: "P")
    scheduler.startNow()
    settle { store.current.item(flaky.id)?.state == .needsYou }
    let failed = store.current.item(flaky.id)!
    expect(failed.attempts == 3 && failed.notes.filter { $0.kind == .retry }.count == 2 && failed.question?.reason.contains("network down") == true,
           "an error is retried \(TodoScheduler.maxAttempts) times, then asks: \(failed.attempts)")
    try! store.cancel(flaky.id)
    // One place stays free for the user: with two chats answering, no TODO starts.
    let waits = try! store.add(title: "later", project: project, projectName: "P")
    store.startDrafts()
    chat.runningRooms = [UUID(), UUID()]
    scheduler.tick()
    expect(store.current.item(waits.id)?.state == .ready && scheduler.waiting != nil, "one of the three places stays free for the user's chats")
    chat.runningRooms = []
    // Nobody with 30% left: it waits.
    model.latestUsage["todo-claude"] = left(20, 70)
    scheduler.tick()
    expect(store.current.item(waits.id)?.state == .ready && scheduler.waiting?.contains("30%") == true, "accounts under 30% do not take TODOs")
    model.latestUsage["todo-claude"] = left(80, 70)
    // A chat writing the repository: the TODO waits.
    let locks = try! ProjectWork.acquire(WorkspaceBinding(roots: [WorkspaceRoot(path: project.root, directory: true, writable: true)], level: .execute))
    expect(ProjectWork.isHeld(project.root), "isHeld sees the lock")
    scheduler.tick()
    expect(store.current.item(waits.id)?.state == .ready && !chat.anyRunning, "a folder in use is not started")
    ProjectWork.release(locks)
    // The app quit while it ran: ready again, and the next attempt checks git status first.
    try! store.change(waits.id) { $0.state = .running }
    scheduler.recover()
    let back = store.current.item(waits.id)!
    expect(back.state == .ready && back.interrupted && back.attempts == 1 && TodoScheduler.question(back).contains("git status"), "restart: running TODOs are ready again with a note")
    try! store.cancel(waits.id)
    // task_done, then an error later in the attempt: retried (checking what is there first), never "waits for the check".
    let late = try! store.add(title: "late", project: project, projectName: "P")
    scheduler.startNow()
    settle { store.current.item(late.id)?.state == .needsYou }
    let broke = store.current.item(late.id)!
    expect(broke.result == nil && broke.report == nil && broke.interrupted && broke.question?.reason.contains("review broke") == true, "a report before an error is not kept: \(broke.state)")
    try! store.cancel(late.id)
    // Its chat answering (the user talks in it): it stays ready without saving again and again, and waits a while.
    let queued = try! store.add(title: "queued", project: project, projectName: "P")
    store.startDrafts()
    let busyRoom = chat.addProjectChat(project, title: "q", open: false)
    try! store.change(queued.id) { $0.room = busyRoom }
    chat.runningRooms = [busyRoom]
    scheduler.held = { _ in false }   // the last attempt's folder lock may still be letting go
    scheduler.tick()
    let stamp = store.current.item(queued.id)!.updatedAt
    for _ in 0..<5 { RunLoop.main.run(until: Date().addingTimeInterval(0.03)); scheduler.tick() }
    expect(store.current.item(queued.id)?.state == .ready && store.current.item(queued.id)?.updatedAt == stamp && scheduler.waiting != nil,
           "a TODO whose chat is answering is not started and not saved again")
    chat.runningRooms = []
    scheduler.held = ProjectWork.isHeld
    try! store.cancel(queued.id)
    // A project worked on in an Enterprise chat: its TODO goes only to that organization's accounts, in a locked chat.
    model.accounts.append(Account(id: "todo-school", provider: .claude, name: "Claude (학교)"))
    model.latestUsage["todo-school"] = left(80, 50)   // less left than the personal Claude: picked only because of the lock
    _ = chat.addProjectChat(project, title: "school", open: false, lock: EnterpriseLock(organization: "학교", name: "학교", lockedAt: Date()))
    let secret = try! store.add(title: "secret", project: project, projectName: "P")
    asked = []
    scheduler.startNow()
    settle { store.current.item(secret.id)?.state == .review }
    let secretRoom = store.current.item(secret.id)?.room.map { chat.conversation($0) }
    expect(asked == ["todo-school"] && secretRoom?.enterpriseLock?.organization == "학교" && secretRoom?.configuration?.memberIDs == ["todo-school"],
           "an Enterprise project's TODO keeps the lock: \(asked)")
    print("PASS: TODO scheduler (drafts wait, own chat, 30% rule, task_done/task_ask scoped, order gate, answer resent, no report, retries, one place free, folder lock, restart, report final at the end, busy chat waits, Enterprise lock)")
}

// The sidebar by project (SidebarProjects.swift): worktrees of one repository in one folder, TODO chats and meetings
// in their place, pinned projects, folds kept per Mac, and ▶ on one project's board starting only its drafts.
func testSidebarProjects() {
    let common = "/tmp/side-repo/.git"
    let main = ProjectBinding(root: "/tmp/side-repo", common: common, remote: "origin", remoteURL: "")
    let tree = ProjectBinding(root: "/tmp/side-repo-wt", common: common, remote: "origin", remoteURL: "")
    let other = ProjectBinding(root: "/tmp/side-other", common: "/tmp/side-other/.git", remote: "origin", remoteURL: "")
    let quiet = ProjectBinding(root: "/tmp/side-quiet", common: "/tmp/side-quiet/.git", remote: "origin", remoteURL: "")
    let base = Date().addingTimeInterval(60)
    func chat(_ title: String, _ project: ProjectBinding?, minutes: Double, pinned: Bool = false) -> Conversation {
        var c = Conversation()
        c.title = title
        c.updatedAt = base.addingTimeInterval(minutes * 60)   // after the TODOs below, made now
        if let project { c.workspace = WorkspaceBinding(roots: [WorkspaceRoot(path: project.root, directory: true, writable: true)], project: project) }
        if pinned { c.pinned = true }
        return c
    }
    let a = chat("A", main, minutes: 1, pinned: true), b = chat("B", tree, minutes: 5), c = chat("C", other, minutes: 9)
    let plain = chat("plain", nil, minutes: 7), plainPinned = chat("plain pinned", nil, minutes: 2, pinned: true)
    let todoChat = chat("TODO · fix", main, minutes: 3)
    let store = TodoStore(url: todoStoreFile("sidebar"))
    let fix = try! store.add(title: "fix", project: main, projectName: "Main repo")
    try! store.change(fix.id) { $0.room = todoChat.id; $0.state = .running }
    _ = try! store.add(title: "later", project: quiet, projectName: "Quiet")
    let chats = [plain, a, b, c, plainPinned, todoChat]

    let grouped = SidebarProjects.group(chats, todo: store.current, pinned: [])
    let repo = grouped.projects.first { $0.id == common }
    expect(grouped.projects.map(\.id) == ["/tmp/side-other/.git", common, "/tmp/side-quiet/.git"],
           "folders by repository, newest first; a project with only TODOs still has one: \(grouped.projects.map(\.id))")
    expect(repo?.chats.map(\.title) == ["A", "B"] && repo?.todoRooms.map(\.title) == ["TODO · fix"] && repo?.name == "Main repo"
           && repo?.bindings.map(\.root) == ["/tmp/side-repo-wt", "/tmp/side-repo"] && repo?.lists.count == 1,
           "worktrees share the folder (each root kept), the pinned chat on top, the TODO chat apart: \(String(describing: repo))")
    expect(grouped.loose.map(\.title) == ["plain pinned", "plain"], "chats without a project stay in Pinned and Recents")
    let all = grouped.projects.flatMap { $0.chats + $0.todoRooms } + grouped.loose
    expect(all.count == chats.count && Set(all.map(\.id)).count == chats.count, "every chat shows once")
    expect(SidebarProjects.group(chats, todo: store.current, pinned: [], withLists: false).projects.map(\.id) == ["/tmp/side-other/.git", common],
           "searching: no folder for a project without a matching chat")
    expect(SidebarProjects.group(chats, todo: store.current, pinned: ["/tmp/side-quiet/.git"]).projects.first?.id == "/tmp/side-quiet/.git",
           "a pinned project comes first")
    let renamed = SidebarProjects.group(chats, todo: store.current, pinned: [], names: [common: "My app", "/tmp/side-quiet/.git": "Quiet one", "/tmp/nowhere/.git": "Gone"]).projects
    expect(renamed.first { $0.id == common }?.name == "My app" && renamed.first { $0.id == "/tmp/side-quiet/.git" }?.name == "Quiet one"
           && renamed.first { $0.id == "/tmp/side-other/.git" }?.name == grouped.projects.first { $0.id == "/tmp/side-other/.git" }?.name
           && renamed.map(\.id) == grouped.projects.map(\.id),
           "a name the user gave comes before the TODO list title and the folder name; others and the order stay: \(renamed.map(\.name))")
    let options = [(name: "My app", binding: main), (name: "My app", binding: tree), (name: "Other", binding: other)]
    expect(options.map { SidebarProjects.pickerName($0, among: options, board: nil) } == ["My app · side-repo", "My app · side-repo-wt", "Other"]
           && SidebarProjects.pickerName(options[1], among: options, board: common) == "side-repo-wt",
           "worktrees sharing a project name are told apart by their folder in the TODO project picker")
    expect(SidebarProjects.folderName(tree) == "side-repo" && SidebarProjects.key(ProjectBinding(root: "/x", common: "", remote: "", remoteURL: "")) == "/x",
           "a folder is named after its repository; no common dir falls back to the root")

    // Finished TODO chats go together (folded row); a chat with a TODO still going stays out.
    var rooms: [Conversation] = [], data = TodoData()
    for (i, state) in [TodoItem.State.done, .running, .done, .cancelled, .needsYou, .review].enumerated() {
        let room = chat("t\(i)", main, minutes: Double(20 - i))
        var item = TodoItem(listID: UUID(), title: "t\(i)")
        item.room = room.id; item.state = state
        rooms.append(room); data.items.append(item)
    }
    var again2 = TodoItem(listID: UUID(), title: "t2 again")
    again2.room = rooms[2].id; again2.state = .ready
    data.items.append(again2)
    let split = SidebarProjects.todoRooms(rooms, todo: data)
    expect(split.going.map(\.title) == ["t1", "t2", "t4", "t5"] && split.finished.map(\.title) == ["t0", "t3"],
           "finished TODO chats apart, review/needsYou and a chat with an unfinished TODO stay: \(split.going.map(\.title)) \(split.finished.map(\.title))")

    // Chats answering now go to the top of their folder (a TODO chat, a finished one, a plain chat), the rest keep their order.
    let own = [chat("p0", main, minutes: 1), chat("p1", main, minutes: 2)]
    let liftGroup = ProjectGroup(id: common, name: "x", bindings: [main], lists: [], chats: own, todoRooms: rooms, pinned: false, updatedAt: Date())
    let lifted = SidebarProjects.runningFirst(liftGroup, todo: data, running: [own[1].id, rooms[3].id, rooms[4].id])
    expect(lifted.running.map(\.title) == ["t4", "p1", "t3"] && lifted.going.map(\.title) == ["t1", "t2", "t5"]
           && lifted.chats.map(\.title) == ["p0"] && lifted.finished.map(\.title) == ["t0"],
           "answering chats first, each shown once: \(lifted.running.map(\.title)) \(lifted.going.map(\.title)) \(lifted.chats.map(\.title)) \(lifted.finished.map(\.title))")
    let idle = SidebarProjects.runningFirst(liftGroup, todo: data, running: [])
    expect(idle.running.isEmpty && idle.going.map(\.title) == split.going.map(\.title) && idle.chats.map(\.title) == ["p0", "p1"],
           "nothing answering: the folder looks as before")

    // Folds and pins are kept, in the test's own defaults; old pinned project chats pin their project once.
    let suite = "ai-illuminati-sidebar-test-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let fold = SidebarFold(defaults: defaults)
    fold.toggle("recents"); fold.toggle("project." + common)
    fold.adoptPins(chats)
    expect(fold.pinnedProjects == [common], "a pinned project chat pins its project: \(fold.pinnedProjects)")
    fold.togglePin(common)
    fold.adoptPins(chats)
    expect(fold.pinnedProjects.isEmpty, "the pins are adopted once; unpinning stays")
    expect(fold.openFinished.isEmpty, "finished TODO chats start folded")
    fold.toggleFinished(common)
    let again = SidebarFold(defaults: defaults)
    expect(again.isFolded("recents") && again.isFolded("project." + common) && !again.isFolded("pinned") && again.pinnedProjects.isEmpty
           && again.openFinished == [common], "folds, pins and the unfolded finished row come back after a restart")
    // A deleted project's fold, pin, unfolded finished row and tab are forgotten; others stay.
    again.togglePin(common); again.togglePin("other")
    defaults.set([common: "todo", "other": "info"], forKey: BoardTab.key)
    again.forget(common)
    let forgotten = SidebarFold(defaults: defaults)
    expect(!forgotten.isFolded("project." + common) && forgotten.isFolded("recents") && forgotten.pinnedProjects == ["other"] && forgotten.openFinished.isEmpty
           && defaults.dictionary(forKey: BoardTab.key)?.keys.sorted() == ["other"], "a deleted project's sidebar state is forgotten")

    // Recents and each Mac show a page; "Show more" adds one, the open chat stays listed, nothing is saved.
    struct Row: Identifiable { let id: Int }
    let rows = (0..<25).map(Row.init)
    expect(SidebarFold.listed(rows, limit: 10, open: nil).map(\.id) == Array(0..<10), "the newest page is listed")
    expect(SidebarFold.listed(rows, limit: 10, open: 20).map(\.id) == Array(0..<10) + [20], "an older open chat is listed too, alone")
    expect(SidebarFold.listed(Array(rows.prefix(3)), limit: 10, open: 1).count == 3, "a short list is listed whole")
    var folder = (0..<8).map { _ in Conversation() }; folder[0].pinned = true
    let paged = SidebarFold.listedChats(folder, limit: SidebarFold.projectPage, open: folder[7].id)
    let expected: [UUID] = [0, 1, 2, 3, 4, 5, 7].map { folder[$0].id }
    expect(paged.rows.map(\.id) == expected && paged.unpinned == 7 && paged.listed == 6,
           "a project folder lists its pinned chats, the newest page and the open chat")
    again.showMore("recents", page: SidebarFold.recentsPage); again.showMore("recents", page: SidebarFold.recentsPage)
    expect(again.limit("recents", page: SidebarFold.recentsPage) == 30 && again.limit("device.x", page: SidebarFold.devicePage) == 5,
           "Show more adds a page to that list only")
    again.showLess("recents")
    again.showMore("device.x", page: SidebarFold.devicePage)
    expect(again.limit("recents", page: SidebarFold.recentsPage) == 10 && SidebarFold(defaults: defaults).limit("device.x", page: 5) == 5,
           "Show less goes back to a page; lengths are not kept after a restart")

    // ▶ on one project's board: only its drafts become ready.
    let start = TodoStore(url: todoStoreFile("sidebar-start"))
    let mine = try! start.add(title: "mine", project: main, projectName: "Main")
    let theirs = try! start.add(title: "theirs", project: other, projectName: "Other")
    start.startDrafts(lists: [mine.listID])
    expect(start.current.item(mine.id)?.state == .ready && start.current.item(theirs.id)?.state == .draft, "one project's start leaves the other drafts")
    start.startDrafts()
    expect(start.current.item(theirs.id)?.state == .ready, "the start on every project's board takes them all")
    print("PASS: sidebar by project (worktrees in one folder, TODO chats apart, folders for TODO-only projects, pinned projects first, finished TODO chats folded together, folds and pins kept, adopted once, one project's start)")
}

// Photos and files on a TODO: copied in before saving, removed with it, refused while it runs, and given to the AI
// in its chat's folder (photos also with the message, once per chat).
func testTodoPause() {
    let a = ProjectBinding(root: "/tmp/todo-pause-a", common: "", remote: "", remoteURL: "")
    let b = ProjectBinding(root: "/tmp/todo-pause-b", common: "", remote: "", remoteURL: "")
    let url = todoStoreFile("pause")
    let store = TodoStore(url: url)
    let one = try! store.add(title: "one", project: a, projectName: "A")
    let two = try! store.add(title: "two", project: a, projectName: "A")
    let three = try! store.add(title: "three", project: a, projectName: "A")
    let other = try! store.add(title: "other", project: b, projectName: "B")
    let free = { (_: String) in false }
    let listA = one.listID
    store.startDrafts()
    try! store.change(one.id) { $0.state = .running }
    try! store.pause(lists: [listA])
    expect(TodoStore(url: url).current.list(listA)?.paused == true, "the pause is saved")
    try! store.change(one.id) { $0.state = .review }
    expect(store.current.eligible(held: free).map(\.title) == ["other"], "a paused list starts nothing; other lists go on: \(store.current.eligible(held: free).map(\.title))")
    expect(store.current.item(two.id)?.state == .ready, "paused TODOs stay ready")
    let late = try! store.add(title: "late", project: a, projectName: "A")
    expect(late.state == .draft, "a TODO added to a paused list is a draft")
    store.requestChanges(one.id, "again")
    expect(!store.current.eligible(held: free).contains { $0.id == one.id }, "a change request waits while paused")
    try! store.resume(lists: [listA])
    expect(store.current.eligible(held: free).map(\.title) == ["one", "other"], "resume goes on with the ready ones: \(store.current.eligible(held: free).map(\.title))")
    expect(store.current.item(late.id)?.state == .draft, "resume keeps drafts")

    // Stop after "two" (in order and not): "three" and "late" below it never start.
    try! store.stop(after: two.id)
    expect(TodoStore(url: url).current.list(listA)?.stopAfter == two.id, "the stop point is saved")
    try! store.setList(listA, sequential: false)
    try! store.change(late.id) { $0.state = .ready }
    expect(store.current.eligible(held: free).map(\.title) == ["one", "two", "other"], "below the stop point nothing starts: \(store.current.eligible(held: free).map(\.title))")
    try! store.move(three.id, by: -1)
    expect(store.current.eligible(held: free).map(\.title) == ["one", "three", "two", "other"], "the stop point follows the board order")
    try! store.stop(after: two.id)
    expect(store.current.list(listA)?.stopAfter == nil && store.current.eligible(held: free).count == 5, "the same TODO again lifts it")
    try! store.stop(after: two.id)
    try! store.delete(two.id)
    expect(store.current.list(listA)?.paused == true && store.current.list(listA)?.stopAfter == nil, "deleting the stop point keeps the list stopped")
    store.startDrafts(lists: [other.listID])
    expect(store.current.list(listA)?.paused == true, "▶ on another project leaves this pause")
    store.startDrafts(lists: [listA])
    expect(store.current.list(listA)?.paused == false, "▶ Start lifts the pause")
    try! store.pause()
    expect(store.current.lists.allSatisfy(\.paused) && store.current.eligible(held: free).isEmpty, "pause all")
    // Old files without the fields load as not paused.
    let old = Data(#"{"version":1,"lists":[{"id":"\#(UUID().uuidString)","title":"x","sequential":true,"waitForDone":false,"order":[]}],"items":[]}"#.utf8)
    let decoded = try! JSONDecoder().decode(TodoData.self, from: old)
    expect(decoded.lists.first?.paused == false && decoded.lists.first?.stopAfter == nil, "an old todos.json is not paused")
    print("PASS: TODO pause (list pause, stop point, resume, saved)")
}

func testTodoEdit() {
    let a = ProjectBinding(root: "/tmp/todo-edit", common: "", remote: "", remoteURL: "")
    let url = todoStoreFile("edit")
    let store = TodoStore(url: url)
    let item = try! store.add(title: "old", detail: "old details", project: a, projectName: "A")
    try! store.edit(item.id, title: "  new  ", detail: " new details ", askFirst: true)
    let now = store.current.item(item.id)!
    expect(now.title == "new" && now.detail == "new details" && now.askFirst && now.state == .draft, "a draft is edited (trimmed): \(now.title) / \(now.detail)")
    expect(TodoStore(url: url).current.item(item.id)?.title == "new", "the edit is saved")
    try! store.edit(item.id, title: "   ", detail: "x", askFirst: false)
    expect(store.current.item(item.id)?.title == "new", "an empty title changes nothing")
    try! store.change(item.id) { $0.state = .ready }
    try! store.edit(item.id, title: "ready edit", detail: "", askFirst: false)
    expect(store.current.item(item.id)?.title == "ready edit", "a ready TODO is edited too")
    for state in [TodoItem.State.running, .review, .done, .needsYou, .cancelled] {
        try! store.change(item.id) { $0.state = state }
        do { try store.edit(item.id, title: "no", detail: "", askFirst: false); expect(false, "no edit when \(state)") }
        catch { expect(error as? TodoError == .notEditable && store.current.item(item.id)?.title == "ready edit", "editing is refused when \(state)") }
    }

    // The TODO open for editing is not started; once the edit ends it is.
    try! store.change(item.id) { $0.state = .ready }
    let scheduler = TodoScheduler(discussion: Discussion(model: AppModel()), store: store)
    scheduler.held = { _ in false }
    scheduler.editing = item.id
    scheduler.tick()
    expect(store.current.item(item.id)?.state == .ready && (scheduler.waiting?.contains("edited") == true || scheduler.waiting?.contains("고치는") == true),
           "the TODO being edited is not started: \(scheduler.waiting ?? "-")")
    scheduler.editing = nil
    scheduler.tick()
    expect(scheduler.waiting?.contains("edited") != true && scheduler.waiting?.contains("고치는") != true, "once the edit ends it may start: \(scheduler.waiting ?? "-")")
    print("PASS: TODO edit (draft and ready only, trimmed, saved; refused once taken)")
}

func testTodoAttachments() {
    let project = ProjectBinding(root: "/tmp/todo-files", common: "", remote: "", remoteURL: "")
    let url = todoStoreFile("files")
    let store = TodoStore(url: url)
    let sources = URL(fileURLWithPath: AccountStore.home).appendingPathComponent("todo-tests/sources")
    try? FileManager.default.removeItem(at: sources)
    try! FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
    let note = sources.appendingPathComponent("notes.txt"), photo = sources.appendingPathComponent("shot.png")
    try! "read me".write(to: note, atomically: true, encoding: .utf8)
    let canvas = NSImage(size: NSSize(width: 8, height: 8)); canvas.lockFocus(); NSColor.red.setFill(); NSRect(x: 0, y: 0, width: 8, height: 8).fill(); canvas.unlockFocus()
    try! NSBitmapImageRep(data: canvas.tiffRepresentation!)!.representation(using: .png, properties: [:])!.write(to: photo)

    let item = try! store.add(title: "with files", detail: "see the shot", files: [note, photo], project: project, projectName: "F")
    expect(item.attachments.map(\.name) == ["notes.txt", "shot.png"] && item.attachments.map(\.image) == [false, true], "attachments are kept with names and kinds: \(item.attachments)")
    expect(item.attachments.allSatisfy { FileManager.default.fileExists(atPath: store.file(item.id, $0).path) } && FileManager.default.fileExists(atPath: note.path), "files are copied in; the originals stay")
    expect(TodoStore(url: url).current.item(item.id)?.attachments == item.attachments, "attachments are saved and read back")
    expect(TodoStore.safeName("../../.secret/x:y") == "_.._.secret_x_y" && TodoStore.safeName("...") == "file", "a name stays one plain file name: \(TodoStore.safeName("../../.secret/x:y"))")
    let long = TodoStore.safeName(String(repeating: "가", count: 120) + ".png")
    expect(long.utf8.count <= TodoStore.maxNameBytes && long.hasSuffix(".png") && (UUID().uuidString + "-" + long).utf8.count <= 255,
           "a long Korean name fits in bytes with its extension: \(long.utf8.count)")
    do { try store.attach(item.id, files: [sources]); expect(false, "a folder is refused") } catch { expect(store.current.item(item.id)?.attachments.count == 2, "a refused attachment changes nothing") }
    do { _ = try store.add(title: "many", files: Array(repeating: note, count: TodoStore.maxAttachments + 1), project: project, projectName: "F"); expect(false, "too many") } catch {}
    // Running: no changes to its files.
    try! store.change(item.id) { $0.state = .running }
    do { try store.attach(item.id, files: [note]); expect(false, "no attaching while running") } catch { expect(error as? TodoError == .busy, "attaching while running is refused") }
    do { try store.detach(item.id, item.attachments[0].id); expect(false, "no removing while running") } catch {}
    try! store.change(item.id) { $0.state = .ready }
    try! store.detach(item.id, item.attachments[0].id)
    expect(store.current.item(item.id)?.attachments.map(\.name) == ["shot.png"] && !FileManager.default.fileExists(atPath: store.file(item.id, item.attachments[0]).path), "removing an attachment removes its copy")
    try! store.attach(item.id, files: [note])

    // Delivery: into the chat's folder, listed in the question; the photo once per chat.
    let saved = TodoStore.shared
    TodoStore.shared = store
    defer { TodoStore.shared = saved }
    let chat = Discussion(model: AppModel())
    let scheduler = TodoScheduler(discussion: chat, store: store)
    let room = chat.addProjectChat(project, title: "files", open: false)
    let current = store.current.item(item.id)!
    let first = try! scheduler.deliver(current, room: room)
    expect(first.paths.count == 2 && first.paths.allSatisfy { $0.hasPrefix(Discussion.chatFolder(room).path + "/") && FileManager.default.fileExists(atPath: $0) },
           "attachments go into the TODO chat's folder: \(first.paths)")
    expect(first.images.map(\.id) == [current.attachments.first { $0.image }!.id], "the photo goes with the message, under its attachment's ID")
    let question = TodoScheduler.question(current, files: first.paths)
    expect(question.contains("see the shot") && first.paths.allSatisfy(question.contains), "the question lists where the files are")
    chat.change(room, save: false) { c in var turn = ChatTurn(question: question); turn.images = first.images; c.turns.append(turn) }
    let again = try! scheduler.deliver(current, room: room)
    expect(again.paths == first.paths && again.images.isEmpty, "a retry in the same chat reuses the copies and does not send the photo again")
    try! store.delete(item.id)
    expect(!FileManager.default.exists(store.folder(item.id)) && FileManager.default.fileExists(atPath: first.paths[0]), "deleting the TODO removes its files; the chat keeps its copies")
    print("PASS: TODO attachments (copied in, saved, safe names, limits, refused while running, removed, delivered to the chat once)")
}

private extension FileManager { func exists(_ url: URL) -> Bool { fileExists(atPath: url.path) } }

// Dragging a chat onto a project folder (SidebarProjects.moveRefusal/moved): which chats may go, and the link they get.
func testMoveChatToProject() {
    let repo = ProjectBinding(root: "/tmp/move-repo", common: "/tmp/move-repo/.git", remote: "origin", remoteURL: "")
    let other = ProjectBinding(root: "/tmp/move-other", common: "/tmp/move-other/.git", remote: "origin", remoteURL: "")
    func chat(_ title: String, _ project: ProjectBinding?) -> Conversation {
        var c = Conversation(); c.title = title
        c.turns = [ChatTurn(question: "hi")]
        if let project { c.workspace = WorkspaceBinding(roots: [WorkspaceRoot(path: project.root, directory: true, writable: true)], project: project) }
        return c
    }
    let member = chat("member", repo), plain = chat("plain", nil), elsewhere = chat("elsewhere", other)
    let todoChat = chat("TODO · x", nil)
    var data = TodoData()
    var item = TodoItem(listID: UUID(), title: "x"); item.room = todoChat.id
    data.items.append(item)
    let group = SidebarProjects.group([member, plain, elsewhere, todoChat], todo: data, pinned: []).projects.first { $0.id == repo.common }!
    func refused(_ c: Conversation, running: Bool = false, mode: Int = 0, todo: TodoData? = nil) -> Bool {
        SidebarProjects.moveRefusal(c, into: group, todo: todo ?? data, running: running, mode: mode) != nil
    }
    expect(!refused(plain) && !refused(elsewhere), "a plain chat and another project's chat can move in")
    expect(refused(member), "a chat already in the project does not move")
    expect(refused(todoChat), "a TODO's chat stays with its TODO")
    expect(refused(plain, running: true) && refused(plain, mode: 1), "not while answering, and only plain chats")
    var locked = plain; locked.enterpriseLock = EnterpriseLock(organization: "acme", name: "Acme", lockedAt: Date())
    expect(refused(locked), "an Enterprise chat does not go into an open project")

    // The link: the project's root first and writable, other linked files kept, the earlier project's root gone.
    var linked = elsewhere.workspace!
    linked.roots.append(WorkspaceRoot(path: "/tmp/notes.txt", directory: false))
    linked.projectRunID = UUID()
    let moved = SidebarProjects.moved(linked, to: repo)
    expect(moved.project == repo && moved.roots.map(\.path) == ["/tmp/move-repo", "/tmp/notes.txt"] && moved.roots[0].writable == true
           && moved.projectRunID == nil, "moved link: \(moved.roots.map(\.path))")
    expect(SidebarProjects.moved(nil, to: repo).roots.map(\.path) == ["/tmp/move-repo"], "a chat with nothing linked gets the project root")
    expect(SidebarProjects.group([SidebarProjects.moved(nil, to: repo)].map { w -> Conversation in var c = plain; c.workspace = w; return c }, todo: TodoData(), pinned: [])
           .projects.first?.id == repo.common, "the moved chat shows under the project's folder")
    print("PASS: move chat to project (who may move, the new link, shows in the folder)")
}

// The AIs picked for a project's TODOs: saved with the list (old files: automatic), only they work and review,
// never a fallback to the others, and the reason shown when none of them can.
func testTodoCrew() {
    let a = ProjectBinding(root: "/tmp/todo-crew", common: "", remote: "", remoteURL: "")
    let url = todoStoreFile("crew")
    let store = TodoStore(url: url)
    let item = try! store.add(title: "pick", project: a, projectName: "A")
    let listID = item.listID
    let old = try! JSONSerialization.data(withJSONObject: ["id": listID.uuidString, "title": "A"])
    expect(try! JSONDecoder().decode(TodoList.self, from: old).accounts.isEmpty, "an old list is automatic")
    let plain = String(data: try! TodoStore.encoder.encode(store.current.list(listID)!), encoding: .utf8)!
    expect(!plain.contains("accounts"), "automatic is not written")
    try! store.setList(listID, accounts: ["c2", "x1", "c2", ""])
    expect(TodoStore(url: url).current.list(listID)?.accounts == ["c2", "x1"], "the picked accounts are saved, once each")

    let model = AppModel()
    model.accounts = [Account(id: "c1", provider: .claude, name: "Claude One"), Account(id: "c2", provider: .claude, name: "Claude Two"),
                      Account(id: "x1", provider: .codex, name: "Codex One"), Account(id: "g1", provider: .gemini, name: "Gemini")]
    func left(_ five: Double, _ week: Double) -> AIUsage {
        var u = AIUsage(name: "x"); u.fiveHour = UsageWindow(usedPercent: 100 - five, resetsAt: nil); u.weekly = UsageWindow(usedPercent: 100 - week, resetsAt: nil); return u
    }
    model.latestUsage = ["c1": left(100, 100), "c2": left(60, 60), "x1": left(50, 50), "g1": left(100, 100)]
    let scheduler = TodoScheduler(discussion: Discussion(model: model), store: store)
    let auto = scheduler.crew()
    expect(auto?.lead.id == "c1" && auto?.reviewer?.id == "x1", "automatic: the most left works, the other kind reviews")
    let list = store.current.list(listID)!
    let picked = scheduler.crew(for: list)
    expect(picked?.lead.id == "c2" && picked?.reviewer?.id == "x1", "picked: only those work and review: \(picked.map { $0.lead.id } ?? "-")")
    try! store.setList(listID, accounts: ["c2"])
    let one = scheduler.crew(for: store.current.list(listID)!)
    expect(one?.lead.id == "c2" && one?.reviewer == nil, "one picked: it works without a review")
    model.latestUsage["c2"] = left(20, 60)
    expect(scheduler.crew(for: store.current.list(listID)!) == nil, "a picked AI under 30% waits, the others do not step in")
    expect(TodoScheduler.noCrew(["c2"], accounts: model.accounts, lock: nil).contains("30%"), "the reason is the usage")
    expect(!TodoScheduler.noCrew(["gone"], accounts: model.accounts, lock: nil).contains("30%"), "a removed account has its own reason")
    let lock = EnterpriseLock(organization: "school", name: "School", lockedAt: Date())
    expect(!TodoScheduler.noCrew(["c2"], accounts: model.accounts, lock: lock).contains("30%"), "an Enterprise lock has its own reason")

    // The scheduler: the picked AI waits; the TODO is not started by another.
    try! store.change(item.id) { $0.state = .ready }
    scheduler.held = { _ in false }
    scheduler.tick()
    expect(store.current.item(item.id)?.state == .ready && scheduler.waiting?.contains("30%") == true, "the scheduler waits for the picked AI: \(scheduler.waiting ?? "-")")
    // The picker's lock is the next TODO's, as the start uses: a finished first TODO does not decide it.
    let school = Account(id: "s1", provider: .claude, name: "Claude (학교)")
    let other = Account(id: "o1", provider: .codex, name: "ChatGPT (회사)")
    model.accounts += [school, other]
    let lockedChat = scheduler.discussion.addProjectChat(a, title: "locked", open: false, lock: EnterpriseLock(organization: Enterprise.organization(other.name), name: "회사", lockedAt: Date()))
    try! store.change(item.id) { $0.state = .done }
    let next = try! store.add(title: "next", project: a, projectName: "A", originRoom: lockedChat)
    try! store.change(next.id) { $0.state = .draft }
    expect(scheduler.lock(for: store.current.list(listID)!)?.organization == Enterprise.organization(other.name),
           "the picker uses the next TODO's lock")
    try! store.setList(listID, accounts: [])
    expect(store.current.list(listID)?.accounts.isEmpty == true, "back to automatic")
    print("PASS: TODO crew (picked AIs saved, only they work, no fallback, reasons)")
}

// Time per TODO: work (running, all attempts), waiting for the user, since the first start; the app's off time is not work.
func testTodoTime() {
    let a = ProjectBinding(root: "/tmp/todo-time", common: "", remote: "", remoteURL: "")
    let url = todoStoreFile("time")
    let store = TodoStore(url: url)
    var clock = Date(timeIntervalSince1970: 1_000_000)
    store.now = { clock }
    let item = try! store.add(title: "timed", project: a, projectName: "T")
    expect(store.current.item(item.id)?.timeLine(at: clock) == nil, "a TODO that never started shows no time")
    clock += 3600; try! store.change(item.id) { $0.state = .running }
    clock += 600; try! store.change(item.id) { $0.report = TodoReport(summary: "half") }
    expect(store.current.item(item.id)?.work(at: clock + 60) == 660, "other changes keep the running clock")
    clock += 300; try! store.change(item.id) { $0.state = .review }
    clock += 120; store.requestChanges(item.id, "more")
    clock += 60; try! store.change(item.id) { $0.state = .running }
    // Quit during the second attempt: closed at quit, the time the app is off is not counted.
    clock += 240
    let scheduler = TodoScheduler(discussion: Discussion(model: AppModel()), store: store)
    scheduler.closeClocks(); scheduler.closeClocks()
    clock += 86_400; scheduler.recover()
    var t = store.current.item(item.id)!
    expect(t.state == .ready && t.workSeconds == 1140 && t.waitSeconds == 120, "work sums both attempts, quit time is not work: \(t.workSeconds) \(t.waitSeconds)")
    clock += 60; try! store.change(item.id) { $0.state = .running }
    // A crash: the run counts up to its last saved change.
    clock += 100; try! store.change(item.id) { $0.report = TodoReport(summary: "x") }
    clock += 5000; scheduler.recover()
    t = store.current.item(item.id)!
    expect(t.workSeconds == 1240, "after a crash only the run up to its last change counts: \(t.workSeconds)")
    clock += 10; try! store.change(item.id) { $0.state = .review }
    clock += 30; store.accept(item.id)
    t = TodoStore(url: url).current.item(item.id)!
    expect(t.finishedAt == clock && t.startedAt == Date(timeIntervalSince1970: 1_003_600) && t.waitSeconds == 150, "start, finish and wait are saved: \(t.waitSeconds)")
    expect(t.timeLine(at: clock + 99_999) == L("AI 작업 20분 · 확인 기다림 2분 · 시작 후 1일 1시간", "AI work 20 min · waiting for you 2 min · since start 1 d 1 h"),
           "the line stops at done: \(t.timeLine(at: clock) ?? "-")")
    expect(TodoItem.span(30) == L("1분 미만", "<1 min") && TodoItem.span(7200) == L("2시간", "2 h"), "short and round spans")
    print("PASS: TODO time (work over attempts, waiting for you, since start, app off time not work, crash lower bound, saved)")
}

// Deleting finished TODO chats (SidebarProjects.deletable): only chats whose TODOs are all done or cancelled, never
// pinned or protected ones (running, open), and with a cutoff only those with nothing newer (chat, TODO, meeting).
func testFinishedTodoCleanup() {
    let project = ProjectBinding(root: "/tmp/clean-repo", common: "/tmp/clean-repo/.git", remote: "origin", remoteURL: "")
    let now = Date(), old = now.addingTimeInterval(-40 * 86400), cutoff = now.addingTimeInterval(-30 * 86400)
    func chat(_ title: String, updated: Date, pinned: Bool = false) -> Conversation {
        var c = Conversation(); c.title = title; c.updatedAt = updated; if pinned { c.pinned = true }; return c
    }
    let oldDone = chat("old done", updated: old), talkedLately = chat("talked lately", updated: now), mixed = chat("mixed", updated: old)
    let pinned = chat("pinned", updated: old, pinned: true), open = chat("open", updated: old), withMeeting = chat("meeting lately", updated: old)
    let freshDone = chat("fresh done", updated: old)
    let store = TodoStore(url: todoStoreFile("cleanup"))
    func todo(_ room: Conversation, _ state: TodoItem.State, finished: Date) {
        let item = try! store.add(title: room.title, project: project, projectName: "Clean")
        try! store.update { data in
            let i = data.items.firstIndex { $0.id == item.id }!
            data.items[i].room = room.id; data.items[i].state = state; data.items[i].finishedAt = finished; data.items[i].updatedAt = finished
        }
    }
    for room in [oldDone, talkedLately, pinned, open, withMeeting] { todo(room, .done, finished: old) }
    todo(mixed, .cancelled, finished: old); todo(mixed, .review, finished: old)
    todo(freshDone, .done, finished: now)
    var meeting = Conversation(); meeting.updatedAt = now
    let rooms = [oldDone, talkedLately, mixed, pinned, open, withMeeting, freshDone]
    let meetings: (UUID) -> [Conversation] = { $0 == withMeeting.id ? [meeting] : [] }
    let aged = SidebarProjects.deletable(rooms, todo: store.current, meetings: meetings, before: cutoff, protected: [open.id]).map(\.title)
    expect(aged == ["old done"], "30 days: only a chat quiet in every part (chat, TODO finish, meetings), not pinned, open or half finished: \(aged)")
    let all = SidebarProjects.deletable(rooms, todo: store.current, protected: [open.id]).map(\.title)
    expect(all == ["old done", "talked lately", "meeting lately", "fresh done"], "all: every finished, unpinned, unprotected chat: \(all)")
    expect(SidebarProjects.deletable([chat("no todo", updated: old)], todo: store.current).isEmpty, "a chat with no TODO is never a finished TODO chat")
    print("PASS: finished TODO chat cleanup (all done or cancelled, pinned and open kept, 30 days counts chat, TODO and meetings)")
}

// todo_add: any chat writes a draft TODO for a project the user names; Enterprise chats only their organization's.
func testTodoAddTool() {
    let store = TodoStore(url: todoStoreFile("add-tool"))
    let link = TodoAddLink.shared
    let savedChats = ChatLink.shared.conversations, savedStore = link.store, savedNames = link.names
    defer { ChatLink.shared.conversations = savedChats; link.store = savedStore; link.names = savedNames }
    link.store = { store }; link.names = { ["/tmp/todo-add-face": "AI Face"] }
    let app = ProjectBinding(root: "/tmp/todo-add-app", common: "", remote: "", remoteURL: "")
    let face = ProjectBinding(root: "/tmp/todo-add-face", common: "", remote: "", remoteURL: "")
    let school = ProjectBinding(root: "/tmp/todo-add-school", common: "", remote: "", remoteURL: "")
    let lock = EnterpriseLock(organization: "학교", name: "학교", lockedAt: Date())
    func chat(_ title: String, _ project: ProjectBinding?, _ lock: EnterpriseLock? = nil) -> Conversation {
        var c = Conversation(); c.title = title; var t = ChatTurn(question: title); t.askedAt = Date(); c.turns = [t]
        if let project { c.workspace = WorkspaceBinding(roots: project.linkedRoots, project: project) }
        c.enterpriseLock = lock; return c
    }
    let plain = chat("다른 얘기", nil), work = chat("앱 작업", app), faceChat = chat("얼굴", face), locked = chat("학교 일", school, lock)
    var chats = [plain, work, faceChat, locked]
    ChatLink.shared.conversations = { chats }
    let claude = Account(id: "todo-add-claude", provider: .claude, name: "Claude", dir: nil, school: false)
    func session(_ c: Conversation) -> ToolContext { ToolContext(room: c.id, roots: [], asker: claude, turn: chats.first { $0.id == c.id }?.turns.last?.id) }
    func offered(_ c: Conversation) -> String? { link.tools(context: session(c)).first { $0["name"] as? String == "todo_add" }?["description"] as? String }
    func add(_ c: Conversation, _ args: [String: Any]) -> (ok: Bool, text: String) {
        let r = link.call("todo_add", args, context: session(c))
        return (r["isError"] as? Bool == false, ((r["content"] as? [[String: Any]])?.first?["text"] as? String) ?? "")
    }

    let menu = offered(plain) ?? ""
    expect(menu.contains("AI Face") && menu.contains("todo-add-app") && !menu.contains("todo-add-school"), "a plain chat is offered the projects without a lock: \(menu)")
    expect(add(plain, ["title": "아이디어"]).text.contains("not linked to a project") && store.current.items.isEmpty, "no project named in an unlinked chat: ask, add nothing")
    let idea = add(plain, ["title": "  얼굴에 날씨 표정 추가\n둘째 줄", "detail": "다른 대화에서 나온 아이디어", "project": "ai face"])
    let item = store.current.items.first
    expect(idea.ok && item?.title == "얼굴에 날씨 표정 추가" && item?.state == .draft && item?.originRoom == plain.id
           && store.current.list(item!.listID)?.project?.root == face.root, "named by its name from another chat: a one-line draft on that board, card in the asking chat")
    expect(add(plain, ["title": "얼굴에 날씨 표정 추가 ", "project": "AI Face"]).text.contains("Already") && store.current.items.count == 1, "the same open TODO is not added twice")
    expect(!add(plain, ["title": "x", "project": "todo-add-school"]).ok && !add(plain, ["title": "x", "project": "nothing"]).ok && store.current.items.count == 1,
           "an Enterprise project or an unknown one is refused")
    // A running list: the tool's TODO still waits for Start (the board's would join the queue).
    let running = try! store.add(title: "진행 중", project: app, projectName: "App")
    store.startDrafts(); try! store.change(running.id) { $0.state = .running }
    expect(add(work, ["title": "후속 작업"]).ok && store.current.items.first { $0.title == "후속 작업" }?.state == .draft
           && store.current.items.first { $0.title == "후속 작업" }?.originRoom == work.id, "this chat's project by default, a draft even in a running list")
    expect(add(chat("경로", nil), ["title": "y", "project": "/tmp/todo-add-app/"]).ok == false, "a chat that is not in the app gets no tool")
    chats.append(chat("경로", nil)); let byPath = chats.last!
    expect(add(byPath, ["title": "경로로", "project": "/tmp/todo-add-app/"]).ok, "a folder path picks the project too")
    // Enterprise: only its organization's projects, with the lock.
    let lockedMenu = offered(locked) ?? ""
    expect(lockedMenu.contains("todo-add-school") && !lockedMenu.contains("AI Face"), "an Enterprise chat sees only its organization's projects")
    expect(!add(locked, ["title": "개인 쪽", "project": "AI Face"]).ok, "an Enterprise chat cannot write to a personal project")
    // The list was made without a lock (from the board) and only the chat on the project is locked: shown, so it can be written.
    let schoolList = try! store.add(title: "보드에서", project: school, projectName: "School")
    expect(store.current.list(schoolList.listID)?.lock == nil, "fixture: the school list starts without a lock")
    expect(add(locked, ["title": "학교 과제"]).ok && store.current.lists.first { $0.project?.root == school.root }?.lock?.organization == "학교", "the Enterprise project's list takes the chat's lock")
    expect(!add(plain, ["title": "개인에서", "project": "/tmp/todo-add-school"]).ok, "once locked, a personal chat still cannot write to it")
    let otherOrg = chat("다른 회사", school, EnterpriseLock(organization: "회사", name: "회사", lockedAt: Date())); chats.append(otherOrg)
    expect(!add(otherOrg, ["title": "다른 조직"]).ok, "another organization's chat cannot write to a list locked for this one")
    // Only while the newest message is being answered.
    let earlier = session(plain)
    if let i = chats.firstIndex(where: { $0.id == plain.id }) { chats[i].turns[0].answeredAt = Date() }
    expect(offered(plain) == nil && !add(plain, ["title": "늦게"]).ok, "once the answer is done the tool closes")
    if let i = chats.firstIndex(where: { $0.id == plain.id }) { chats[i].turns.append(ChatTurn(question: "다음")) }
    expect(link.call("todo_add", ["title": "옛 세션", "project": "AI Face"], context: earlier)["isError"] as? Bool == true, "an earlier answer's session adds nothing")
    print("PASS: todo_add (any chat, by name or path, drafts only, no repeats, Enterprise apart, only for the newest answer)")
}

// todo_drafts / todo_edit: the AI reads and rewrites drafts only, within the projects its chat may write.
func testTodoEditTool() {
    let store = TodoStore(url: todoStoreFile("edit-tool"))
    let link = TodoAddLink.shared
    let savedChats = ChatLink.shared.conversations, savedStore = link.store, savedNames = link.names
    defer { ChatLink.shared.conversations = savedChats; link.store = savedStore; link.names = savedNames }
    link.store = { store }; link.names = { [:] }
    let app = ProjectBinding(root: "/tmp/todo-edit-app", common: "", remote: "", remoteURL: "")
    let school = ProjectBinding(root: "/tmp/todo-edit-school", common: "", remote: "", remoteURL: "")
    let lock = EnterpriseLock(organization: "학교", name: "학교", lockedAt: Date())
    func chat(_ title: String, _ project: ProjectBinding?, _ lock: EnterpriseLock? = nil) -> Conversation {
        var c = Conversation(); c.title = title; var t = ChatTurn(question: title); t.askedAt = Date(); c.turns = [t]
        if let project { c.workspace = WorkspaceBinding(roots: project.linkedRoots, project: project) }
        c.enterpriseLock = lock; return c
    }
    let work = chat("앱 작업", app), locked = chat("학교 일", school, lock)
    let chats = [work, locked]
    ChatLink.shared.conversations = { chats }
    let claude = Account(id: "todo-edit-claude", provider: .claude, name: "Claude", dir: nil, school: false)
    func session(_ c: Conversation) -> ToolContext { ToolContext(room: c.id, roots: [], asker: claude, turn: c.turns.last?.id) }
    func run(_ c: Conversation, _ tool: String, _ args: [String: Any]) -> (ok: Bool, text: String) {
        let r = link.call(tool, args, context: session(c))
        return (r["isError"] as? Bool == false, ((r["content"] as? [[String: Any]])?.first?["text"] as? String) ?? "")
    }

    let draft = try! store.add(title: "초안", detail: "처음 설명", project: app, projectName: "App")
    let ready = try! store.add(title: "준비됨", project: app, projectName: "App")
    try! store.change(ready.id) { $0.state = .ready }
    let schoolDraft = try! store.add(title: "학교 초안", project: school, projectName: "School", lock: lock)
    let names = Set(link.tools(context: session(work)).compactMap { $0["name"] as? String })
    expect(names.isSuperset(of: ["todo_add", "todo_drafts", "todo_edit"]), "the edit tools are offered with todo_add: \(names)")
    let listed = run(work, "todo_drafts", [:])
    expect(listed.ok && listed.text.contains(draft.id.uuidString) && listed.text.contains("처음 설명") && !listed.text.contains(ready.id.uuidString)
           && !listed.text.contains(schoolDraft.id.uuidString), "drafts of this chat's project only, with id and detail: \(listed.text)")
    let edited = run(work, "todo_edit", ["id": draft.id.uuidString, "detail": "고친 설명", "ask_first": true])
    let after = store.current.item(draft.id)
    expect(edited.ok && after?.title == "초안" && after?.detail == "고친 설명" && after?.askFirst == true && after?.state == .draft,
           "only the given fields change, and it stays a draft")
    expect(run(work, "todo_edit", ["id": draft.id.uuidString, "title": "새 제목\n둘째 줄"]).ok && store.current.item(draft.id)?.title == "새 제목", "a title is one line")
    expect(!run(work, "todo_edit", ["id": draft.id.uuidString, "title": "  "]).ok && store.current.item(draft.id)?.title == "새 제목", "an empty title is refused")
    expect(!run(work, "todo_edit", ["id": draft.id.uuidString]).ok, "nothing to change is refused")
    let notDraft = run(work, "todo_edit", ["id": ready.id.uuidString, "title": "바꿈"])
    expect(!notDraft.ok && notDraft.text.contains("not a draft") && store.current.item(ready.id)?.title == "준비됨", "a ready TODO cannot be changed")
    expect(!run(work, "todo_edit", ["id": schoolDraft.id.uuidString, "title": "바꿈"]).ok && store.current.item(schoolDraft.id)?.title == "학교 초안",
           "a personal chat cannot change an Enterprise project's draft")
    expect(run(locked, "todo_edit", ["id": schoolDraft.id.uuidString, "title": "학교 수정"]).ok && store.current.item(schoolDraft.id)?.title == "학교 수정",
           "its organization's chat can")
    expect((try? store.editDraft(schoolDraft.id, title: "x", detail: nil, askFirst: nil, organization: nil)) == nil, "the store checks the lock too")
    // Long details are not cut, too long ones refused; more than 30 drafts come by offset.
    let long = String(repeating: "가", count: 9000)
    try! store.change(draft.id) { $0.detail = long }
    expect(run(work, "todo_edit", ["id": draft.id.uuidString, "detail": long + "끝"]).ok == false && store.current.item(draft.id)?.detail == long, "a detail over the limit is refused, not cut")
    expect(run(work, "todo_edit", ["id": draft.id.uuidString, "detail": "앞" + long.dropFirst()]).ok && store.current.item(draft.id)?.detail.count == 9000, "a board detail longer than 8000 is kept whole")
    for n in 0..<31 { _ = try! store.add(title: "많은 초안 \(n)", project: app, projectName: "App", fromAI: true) }   // drafts although a TODO is ready
    let first = run(work, "todo_drafts", [:]), second = run(work, "todo_drafts", ["offset": 30])
    expect(first.text.contains("offset 30") && !first.text.contains("많은 초안 30") && second.text.contains("많은 초안 30") && second.text.contains("많은 초안 29"), "the next drafts by offset")
    print("PASS: todo_drafts/todo_edit (drafts only, given fields only, Enterprise apart, long details whole, offset)")
}
