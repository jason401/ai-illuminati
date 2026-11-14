import Foundation
import Combine
import Cocoa
import AIAccounts
import AILocalization
@testable import AIRuntime
import AIWorkspace
@testable import AIProjects
@testable import AIChat

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
    // A question does not hold the list: the next one goes on, but not with "after my check", and an "after" link waits.
    try! store.change(two.id) { $0.state = .needsYou }
    expect(store.current.eligible(held: free).isEmpty, "\"after my check\": the next waits for the answer too")
    try! store.setList(store.current.lists[0].id, waitForDone: false)
    expect(store.current.eligible(held: free).map(\.title) == ["three"], "the next starts while the previous waits for an answer; a link to it waits: \(store.current.eligible(held: free).map(\.title))")
    store.answer(two.id, "yes")
    expect(store.current.eligible(held: free).map(\.title) == ["two"], "answered, it is next again and the order holds: \(store.current.eligible(held: free).map(\.title))")
    try! store.setList(store.current.lists[0].id, waitForDone: true)
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
    model.latestUsage["todo-codex"] = left(5, 90)   // under 10%: no TODO work, so no reviewer either
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
    expect(asked.allSatisfy { $0 == "todo-claude" } && toolsSeen == ["task_done", "task_ask"], "only the account with 10% left works: \(asked) \(toolsSeen)")
    expect(chat.conversation(room).configuration?.memberIDs == ["todo-claude"], "no reviewer under 10%")
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
    // Nobody with 10% left: it waits.
    model.latestUsage["todo-claude"] = left(5, 70)
    scheduler.tick()
    expect(store.current.item(waits.id)?.state == .ready && scheduler.waiting?.contains("10%") == true, "accounts under 10% do not take TODOs")
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
    print("PASS: TODO scheduler (drafts wait, own chat, 10% rule, task_done/task_ask scoped, order gate, answer resent, no report, retries, one place free, folder lock, restart, report final at the end, busy chat waits, Enterprise lock)")
}

// The order of TODO state changes through the app (Discussion as TodoChats, the project chat's own repository lock):
// an error is retried in the same chat before the next TODO, the next one starts only once the chat that worked on the
// repository has let it go, and nothing here calls tick: the chats finishing and the lock's release wake the scheduler.
// The same promises without the app: projects_contract.swift.
func testTodoOrder() {
    let project = todoProject("todo-order")
    let saved = TodoStore.shared
    let store = TodoStore(url: todoStoreFile("order"))
    TodoStore.shared = store
    defer { TodoStore.shared = saved }
    let model = AppModel()
    model.accounts = [Account(id: "order-claude", provider: .claude, name: "Order Claude")]
    var u = AIUsage(name: "x"); u.fiveHour = UsageWindow(usedPercent: 10, resetsAt: nil); u.weekly = UsageWindow(usedPercent: 10, resetsAt: nil)
    model.latestUsage["order-claude"] = u
    let chat = Discussion(model: model)
    let scheduler = TodoScheduler(discussion: chat, store: store)
    var events: [String] = [], failures = ["Repository is busy in another app instance.", "flaky network"]
    let watcher = NotificationCenter.default.addObserver(forName: .projectReleased, object: nil, queue: nil) { _ in events.append("released") }
    defer { NotificationCenter.default.removeObserver(watcher) }
    let a = try! store.add(title: "order A", project: project, projectName: "O")
    let b = try! store.add(title: "order B", project: project, projectName: "O")
    chat.workspaceAnswer = { _, prompt, binding, _, _ in
        let current = prompt.components(separatedBy: "[User]\n").last ?? ""
        let title = current.hasPrefix("TODO: order A") ? "A" : current.hasPrefix("TODO: order B") ? "B" : "?"
        events.append(title + (ProjectWork.isHeld(project.root) ? " (held)" : " (not held)"))
        let room = store.current.items.first { $0.state == .running }?.room ?? UUID()
        let context = ToolContext(room: room, roots: binding.roots, projectRun: binding.projectRunID, projectGeneration: binding.projectGeneration)
        // First another app instance holds the repository (not the TODO's fault), then a real error.
        if title == "A" && !failures.isEmpty { return .failure(.failed(failures.removeFirst())) }
        if title == "B" { events.append("A was " + (store.current.item(a.id)?.state.rawValue ?? "-")) }
        _ = TaskLink.shared.call("task_done", ["summary": "did " + title], context: context)
        return .success("Done " + title + ".")
    }
    scheduler.start()
    store.startDrafts()   // the board's change wakes the scheduler too
    let deadline = Date().addingTimeInterval(30)
    while Date() < deadline && !(store.current.item(b.id)?.state == .review && !chat.anyRunning) { RunLoop.main.run(until: Date().addingTimeInterval(0.03)) }
    let works = events.filter { $0 != "released" }
    expect(works == ["A (held)", "A (held)", "A (held)", "B (held)", "A was review"], "A, its retries, then B, each while its chat holds the repository: \(events)")
    // Every start comes after the release of the work before it.
    let starts = events.indices.filter { events[$0].hasSuffix("(held)") }
    expect(starts.count == 4 && zip(starts, starts.dropFirst()).allSatisfy { events[$0.0 + 1..<$0.1].contains("released") }, "each next start follows a release: \(events)")
    let first = store.current.item(a.id)!
    expect(first.state == .review && first.attempts == 1 && first.notes.filter { $0.kind == .retry }.count == 1 && first.result == "did A",
           "A: the busy repository is not counted, the error is (one retry noted), then it waits for the check: \(first.attempts)")
    expect(store.current.item(b.id)?.result == "did B" && store.current.item(b.id)?.room != first.room, "B in a chat of its own")
    print("PASS: TODO order through the app (a busy repository not counted, retry first in the same chat, next only after the repository is let go, woken without tick)")
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

// A list in order with drafts among ready TODOs: the ready ones go top to bottom, skipping the drafts (the board's
// one-click draft/ready capsule is setReady); dragging is move(_:before:) inside the list.
func testTodoMixedOrder() {
    let p = ProjectBinding(root: "/tmp/todo-mixed", common: "", remote: "", remoteURL: "")
    let other = ProjectBinding(root: "/tmp/todo-mixed-other", common: "", remote: "", remoteURL: "")
    let store = TodoStore(url: todoStoreFile("mixed"))
    let free = { (_: String) in false }
    let a = try! store.add(title: "A", project: p, projectName: "P")
    let b = try! store.add(title: "B", project: p, projectName: "P")
    let c = try! store.add(title: "C", project: p, projectName: "P")
    let elsewhere = try! store.add(title: "elsewhere", project: other, projectName: "O")
    let list = a.listID
    func order() -> [UUID] { store.current.ordered(list).map(\.id) }
    func blockers(_ id: UUID) -> [UUID] { store.current.blockers(store.current.item(id)!) }
    func eligible() -> [String] { store.current.eligible(held: free).map(\.title) }
    try! store.setReady(a.id, true); try! store.setReady(c.id, true)
    expect(store.current.item(b.id)?.state == .draft && blockers(c.id) == [a.id], "C waits for A, not for the draft B above it: \(blockers(c.id))")
    expect(eligible() == ["A"], "A first: \(eligible())")
    try! store.change(a.id) { $0.state = .running }
    expect(eligible().isEmpty, "C waits while A runs")
    try! store.change(a.id) { $0.state = .review }
    expect(eligible() == ["C"], "C starts after A although B, a draft, is between: \(eligible())")
    // B made ready while A still runs: B waits for A, and C now waits for B (the user's order holds).
    try! store.change(a.id) { $0.state = .running }
    try! store.setReady(b.id, true)
    expect(blockers(b.id) == [a.id] && blockers(c.id) == [b.id], "B waits for A, C for B: \(blockers(b.id)) \(blockers(c.id))")
    try! store.change(a.id) { $0.state = .review }
    expect(eligible() == ["B"], "B goes next: \(eligible())")
    try! store.setReady(b.id, false)
    expect(store.current.item(b.id)?.state == .draft && eligible() == ["C"], "back to draft: skipped again")
    // setReady only for a draft or a ready one.
    try! store.change(a.id) { $0.state = .running }
    do { try store.setReady(a.id, false); expect(false, "setReady on a running TODO is refused") } catch { expect(store.current.item(a.id)?.state == .running, "a running TODO stays running") }
    try! store.change(a.id) { $0.state = .review }
    // The stop point still holds by board order, also after a draft.
    try! store.stop(after: b.id)
    expect(store.current.stopped(store.current.item(c.id)!) && eligible().isEmpty, "stop after the draft B: C below it does not start")
    try! store.stop(after: b.id)
    expect(eligible() == ["C"], "the stop point lifted")
    // Circles through the order that skips drafts are still refused.
    do { try store.setAfter(a.id, [c.id]); expect(false, "A after C while C waits for A is a circle") } catch { expect(error as? TodoError == .cycle, "the circle error") }
    expect(store.current.item(a.id)?.after.isEmpty == true, "a refused circle changes nothing")

    // move(_:before:): in front of a TODO, to the end, a running one too, never into another list.
    try! store.move(c.id, before: a.id)
    expect(order() == [c.id, a.id, b.id], "in front of A: \(order())")
    try! store.move(c.id, before: nil)
    expect(order() == [a.id, b.id, c.id], "to the end")
    try! store.move(a.id, before: c.id)
    expect(order() == [b.id, a.id, c.id], "in front of C")
    try! store.move(a.id, before: a.id)
    expect(order() == [b.id, a.id, c.id], "in front of itself: nothing changes")
    try! store.change(a.id) { $0.state = .running }
    try! store.move(a.id, before: b.id)
    expect(order() == [a.id, b.id, c.id] && store.current.item(a.id)?.state == .running, "a running TODO may move (its place only)")
    do { try store.move(a.id, before: elsewhere.id); expect(false, "not into another list") } catch { expect(order() == [a.id, b.id, c.id], "another list's TODO is refused") }
    try! store.change(a.id) { $0.state = .review }
    try! store.setAfter(c.id, [a.id])
    do { try store.move(c.id, before: a.id); expect(false, "a move that makes a circle is refused") }
    catch { expect(error as? TodoError == .cycle && order() == [a.id, b.id, c.id], "the circle is refused and the order kept: \(order())") }
    expect(TodoStore(url: store.url).current.ordered(list).map(\.id) == order(), "the new order is saved")
    print("PASS: TODO mixed order (ready ones skip drafts, setReady, stop point, circles, move before)")
}

// The chat side for testTodoStartRace: `meanwhile` runs while the scheduler is between reading a TODO and starting it
// (where todo_edit on the tool thread or the board may change it).
private final class RaceChats: TodoChats {
    let changed = PassthroughSubject<Void, Never>()
    var answering: Set<UUID> = []
    var answeringChanged: AnyPublisher<Void, Never> { changed.eraseToAnyPublisher() }
    var maxAnswering = 3
    var importing = false
    var chats: [ProjectChatSummary] = []
    var questions: [String] = []
    var meanwhile: (() -> Void)?
    let base: URL
    init(base: URL) { self.base = base }
    func crew(lock: EnterpriseLock?, allowed: [String]) -> (lead: Account, reviewer: Account?)? { (Account(id: "race-lead", provider: .claude, name: "Lead"), nil) }
    func noCrew(_ allowed: [String], lock: EnterpriseLock?) -> String { "nobody" }
    func addChat(_ project: ProjectBinding, title: String, lock: EnterpriseLock?) -> UUID {
        let id = UUID()
        chats.append(ProjectChatSummary(id: id, updatedAt: Date(), project: project, lock: lock, enterprise: false, openTurn: nil))
        meanwhile?(); meanwhile = nil
        return id
    }
    func setCrew(room: UUID, members: [String], lead: String) {}
    func folder(_ room: UUID) -> URL { base.appendingPathComponent(room.uuidString) }
    func sentPhotos(_ room: UUID) -> Set<UUID> { [] }
    func start(room: UUID, question: String, photos: [TodoPhoto], review: Bool, extra: String) -> String? { questions.append(question); answering.insert(room); return nil }
    func ended(_ room: UUID) -> TodoTurnEnd { TodoTurnEnd() }
    func stop(_ room: UUID) { answering.remove(room) }
}

// A TODO changed while the scheduler starts it: never started with the old text, never started as a draft; the
// chat made for it is kept for the next try.
func testTodoStartRace() {
    let p = ProjectBinding(root: "/tmp/todo-race", common: "", remote: "", remoteURL: "")
    let store = TodoStore(url: todoStoreFile("race"))
    let chats = RaceChats(base: URL(fileURLWithPath: AccountStore.home).appendingPathComponent("todo-race-chats"))
    let scheduler = TodoScheduler(chats: chats, store: store)
    scheduler.held = { _ in false }
    let item = try! store.add(title: "old title", project: p, projectName: "P")
    try! store.setReady(item.id, true)
    chats.meanwhile = { _ = try! store.editForAI(item.id, title: "new title", detail: nil, askFirst: nil, organization: nil) }
    scheduler.tick()
    let room = store.current.item(item.id)?.room
    expect(chats.questions.isEmpty && store.current.item(item.id)?.state == .ready && room != nil, "changed meanwhile: not started with the old text")
    scheduler.tick()
    expect(chats.questions.count == 1 && chats.questions[0].contains("new title") && !chats.questions[0].contains("old title")
           && store.current.item(item.id)?.state == .running && store.current.item(item.id)?.room == room, "the next try sends the new text in the same chat")
    let second = try! store.add(title: "second", project: ProjectBinding(root: "/tmp/todo-race-2", common: "", remote: "", remoteURL: ""), projectName: "Q")
    try! store.setReady(second.id, true)
    chats.meanwhile = { try! store.setReady(second.id, false) }
    scheduler.tick()
    expect(store.current.item(second.id)?.state == .draft && chats.questions.count == 1, "made a draft meanwhile: not started")
    print("PASS: TODO start race (changed or made a draft while starting: not started with the old state)")
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
    expect(first.photos.map(\.id) == [current.attachments.first { $0.image }!.id], "the photo goes with the message, under its attachment's ID")
    let question = TodoScheduler.question(current, files: first.paths)
    expect(question.contains("see the shot") && first.paths.allSatisfy(question.contains), "the question lists where the files are")
    // The chat side sends it as a picture of that chat, under the same ID (TodoChatsApp `start`).
    let images = first.photos.compactMap { try? ImageStore.importImage(Data(contentsOf: $0.file), name: $0.name, conversationID: room, id: $0.id) }
    expect(images.map(\.id) == first.photos.map(\.id), "the photo becomes the chat's picture under the attachment's ID")
    chat.change(room, save: false) { c in var turn = ChatTurn(question: question); turn.images = images; c.turns.append(turn) }
    let again = try! scheduler.deliver(current, room: room)
    expect(again.paths == first.paths && again.photos.isEmpty, "a retry in the same chat reuses the copies and does not send the photo again")
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
    let discussion = Discussion(model: model)
    let scheduler = TodoScheduler(discussion: discussion, store: store)
    let auto = scheduler.crew()
    expect(auto?.lead.id == "c1" && auto?.reviewer?.id == "x1", "automatic: the most left works, the other kind reviews")
    let list = store.current.list(listID)!
    let picked = scheduler.crew(for: list)
    expect(picked?.lead.id == "c2" && picked?.reviewer?.id == "x1", "picked: only those work and review: \(picked.map { $0.lead.id } ?? "-")")
    try! store.setList(listID, accounts: ["c2"])
    let one = scheduler.crew(for: store.current.list(listID)!)
    expect(one?.lead.id == "c2" && one?.reviewer == nil, "one picked: it works without a review")
    model.latestUsage["c2"] = left(5, 60)
    expect(scheduler.crew(for: store.current.list(listID)!) == nil, "a picked AI under 10% waits, the others do not step in")
    expect(TodoScheduler.noCrew(["c2"], accounts: model.accounts, lock: nil).contains("10%"), "the reason is the usage")
    expect(!TodoScheduler.noCrew(["gone"], accounts: model.accounts, lock: nil).contains("10%"), "a removed account has its own reason")
    let lock = EnterpriseLock(organization: "school", name: "School", lockedAt: Date())
    expect(!TodoScheduler.noCrew(["c2"], accounts: model.accounts, lock: lock).contains("10%"), "an Enterprise lock has its own reason")

    // The scheduler: the picked AI waits; the TODO is not started by another.
    try! store.change(item.id) { $0.state = .ready }
    scheduler.held = { _ in false }
    scheduler.tick()
    expect(store.current.item(item.id)?.state == .ready && scheduler.waiting?.contains("10%") == true, "the scheduler waits for the picked AI: \(scheduler.waiting ?? "-")")
    // The picker's lock is the next TODO's, as the start uses: a finished first TODO does not decide it.
    let school = Account(id: "s1", provider: .claude, name: "Claude (학교)")
    let other = Account(id: "o1", provider: .codex, name: "ChatGPT (회사)")
    model.accounts += [school, other]
    let lockedChat = discussion.addProjectChat(a, title: "locked", open: false, lock: EnterpriseLock(organization: Enterprise.organization(other.name), name: "회사", lockedAt: Date()))
    try! store.change(item.id) { $0.state = .done }
    let next = try! store.add(title: "next", project: a, projectName: "A", originRoom: lockedChat)
    try! store.change(next.id) { $0.state = .draft }
    expect(scheduler.lock(for: store.current.list(listID)!)?.organization == Enterprise.organization(other.name),
           "the picker uses the next TODO's lock")
    try! store.setList(listID, accounts: [])
    expect(store.current.list(listID)?.accounts.isEmpty == true, "back to automatic")
    print("PASS: TODO crew (picked AIs saved, only they work, no fallback, reasons)")
}

// The TODO bar near a reset (AutoPick.need/surplus): lower only for TODOs and only close to a reset, never above 10%;
// chats keep 10%; the most surplus works first; the waiting text says the bar in use. Fixed `now`, made-up readings only.
func testTodoUsageBar() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    func window(_ left: Double, in seconds: TimeInterval?) -> UsageWindow { UsageWindow(usedPercent: 100 - left, resetsAt: seconds.map { now.addingTimeInterval($0) }) }
    func weekNeed(_ days: Double?, _ purpose: AutoPick.Purpose = .todo) -> Double {
        AutoPick.need(window: window(50, in: days.map { $0 * 86400 }), kind: .weekly, purpose: purpose, now: now)
    }
    expect(weekNeed(3) == 10 && weekNeed(2) == 10 && weekNeed(1) == 5 && weekNeed(0.5) == 3 && weekNeed(nil) == 10, "weekly bar: 3 d 10, 2 d 10, 1 d 5, half a day 3, no reset 10")
    expect(AutoPick.need(window: nil, kind: .weekly, purpose: .todo, now: now) == 10 && weekNeed(-0.1) == 10, "no window or a reset already past: 10")
    func fiveNeed(_ minutes: Double) -> Double { AutoPick.need(window: window(50, in: minutes * 60), kind: .fiveHour, purpose: .todo, now: now) }
    expect(fiveNeed(61) == 10 && fiveNeed(59) == 3, "5-hour bar: 61 min 10, 59 min 3")
    expect(weekNeed(0.5, .chat) == 10 && AutoPick.need(window: window(50, in: 600), kind: .fiveHour, purpose: .chat, now: now) == 10, "chats keep 10%")
    expect(AutoPick.need(window: window(50, in: 43200), kind: .weekly, purpose: .todo, now: now, checkedAt: now.addingTimeInterval(-1800)) == 10
           && AutoPick.need(window: window(50, in: 43200), kind: .weekly, purpose: .todo, now: now, checkedAt: now.addingTimeInterval(-1700)) == 3,
           "a reading 30 minutes old keeps 10%")

    func usage(five: Double = 100, week: Double, resetIn: TimeInterval?) -> AIUsage {
        var u = AIUsage(name: "u"); u.fiveHour = window(five, in: 4 * 3600); u.weekly = window(week, in: resetIn); return u
    }
    // Just the bar left passes (>=); a bit less does not; a chat still needs 10%.
    expect(AutoPick.enough(usage(week: 3, resetIn: 43200), purpose: .todo, now: now) && !AutoPick.enough(usage(week: 2.9, resetIn: 43200), purpose: .todo, now: now)
           && !AutoPick.enough(usage(week: 3, resetIn: 43200), purpose: .chat, now: now), "exactly the bar passes; chats still need 10%")
    let a = Account(id: "bar-a", provider: .claude, name: "Claude A"), b = Account(id: "bar-b", provider: .codex, name: "Codex B")
    var levels = ["bar-a": usage(week: 70, resetIn: 43200), "bar-b": usage(week: 72, resetIn: 5 * 86400)]
    expect(AutoPick.surplus(usage: levels["bar-a"], purpose: .todo, now: now) == 67 && AutoPick.surplus(usage: levels["bar-b"], purpose: .todo, now: now) == 62, "surplus 67 and 62")
    let crew = AutoPick.todoCrew([b, a], usage: levels, lock: nil, allowed: [], now: now)
    expect(crew?.lead.id == "bar-a" && crew?.reviewer?.id == "bar-b", "the most surplus works first (close reset, much left)")
    levels["bar-b"] = usage(week: 67 + 10, resetIn: 5 * 86400)   // same surplus: the most weekly left
    expect(AutoPick.todoCrew([a, b], usage: levels, lock: nil, allowed: [], now: now)?.lead.id == "bar-b", "same surplus: the most weekly left first")
    levels = ["bar-a": usage(week: 4, resetIn: 43200), "bar-b": usage(week: 8, resetIn: 5 * 86400)]
    expect(AutoPick.todoCrew([a, b], usage: levels, lock: nil, allowed: [], now: now).map { $0.lead.id == "bar-a" && $0.reviewer == nil } == true, "4% left half a day before the reset takes a TODO; 8% five days before does not")
    expect(AutoPick.choose([a, b], usage: levels, lock: nil, current: nil)?.id == "bar-b", "a chat is not lowered: nobody has 10%, the most left answers as before")

    // The waiting text shows the lowest bar of the accounts that could take it, from the function.
    let bar = AutoPick.todoBar([a, b], usage: ["bar-a": usage(week: 1, resetIn: 86400), "bar-b": usage(week: 1, resetIn: 5 * 86400)], now: now)
    expect(bar.percent == "5%" && bar.note.contains("1"), "the bar in use: \(bar.percent)\(bar.note)")
    let text = TodoScheduler.noCrew([], accounts: [a, b], lock: nil, percent: bar.percent, note: bar.note)
    expect(text.contains("5%") && text.contains(bar.note), "the waiting text says it: \(text)")
    expect(AutoPick.todoBar([a, b], usage: ["bar-a": usage(week: 1, resetIn: nil)], now: now).percent == "10%", "no reset time: 10%")
    print("PASS: TODO usage bar near a reset (need, surplus order, chats unchanged, waiting text)")
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

// todo_list / todo_edit: the AI reads the board in order and changes what is not running, within the projects its chat may write.
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
    expect(names.isSuperset(of: ["todo_add", "todo_list", "todo_edit"]) && !names.contains("todo_drafts"), "the edit tools are offered with todo_add: \(names)")
    let editHelp = link.tools(context: session(work)).first { $0["name"] as? String == "todo_edit" }?["description"] as? String ?? ""
    expect(editHelp.contains("Never on your own") && editHelp.contains("when the user asks"), "todo_edit is only for what the user asks")
    let listed = run(work, "todo_list", [:])
    expect(listed.ok && listed.text.contains(draft.id.uuidString) && listed.text.contains("처음 설명") && listed.text.contains(ready.id.uuidString)
           && listed.text.contains("state: ready") && listed.text.contains("state: draft") && listed.text.contains("place: 2")
           && !listed.text.contains(schoolDraft.id.uuidString), "this chat's project only, in order with id, state and detail: \(listed.text)")
    expect(listed.text.range(of: draft.id.uuidString)!.lowerBound < listed.text.range(of: ready.id.uuidString)!.lowerBound, "in the board's order")
    let edited = run(work, "todo_edit", ["id": draft.id.uuidString, "detail": "고친 설명", "ask_first": true])
    let after = store.current.item(draft.id)
    expect(edited.ok && after?.title == "초안" && after?.detail == "고친 설명" && after?.askFirst == true && after?.state == .draft,
           "only the given fields change, and it stays a draft")
    // Ready ones too, and state / before.
    expect(run(work, "todo_edit", ["id": ready.id.uuidString, "title": "준비 수정"]).ok && store.current.item(ready.id)?.title == "준비 수정"
           && store.current.item(ready.id)?.state == .ready, "a ready TODO is changed and stays ready")
    expect(run(work, "todo_edit", ["id": ready.id.uuidString, "state": "draft"]).ok && store.current.item(ready.id)?.state == .draft, "state draft")
    expect(run(work, "todo_edit", ["id": ready.id.uuidString, "state": "ready"]).ok && store.current.item(ready.id)?.state == .ready, "state ready")
    expect(!run(work, "todo_edit", ["id": ready.id.uuidString, "state": "running"]).ok && store.current.item(ready.id)?.state == .ready, "only draft or ready")
    let appList = store.current.item(draft.id)!.listID
    expect(run(work, "todo_edit", ["id": ready.id.uuidString, "before": draft.id.uuidString]).ok
           && store.current.ordered(appList).map(\.id) == [ready.id, draft.id], "before puts it in front of that TODO")
    expect(run(work, "todo_edit", ["id": ready.id.uuidString, "before": "end"]).ok
           && store.current.ordered(appList).map(\.id) == [draft.id, ready.id], "before end puts it last")
    expect(!run(work, "todo_edit", ["id": ready.id.uuidString, "before": schoolDraft.id.uuidString]).ok
           && store.current.ordered(appList).map(\.id) == [draft.id, ready.id], "before must be on the same board")
    try! store.change(ready.id) { $0.state = .running }
    let busy = run(work, "todo_edit", ["id": ready.id.uuidString, "before": draft.id.uuidString])
    expect(!busy.ok && busy.text.contains("running") && store.current.ordered(appList).map(\.id) == [draft.id, ready.id], "a running TODO is not changed, not even moved")
    expect(!run(work, "todo_edit", ["id": ready.id.uuidString, "title": "x"]).ok && store.current.item(ready.id)?.title == "준비 수정", "nor its text")
    expect((try? store.editForAI(ready.id, title: nil, detail: nil, askFirst: nil, before: .some(nil), organization: nil)) == nil, "the store refuses a running one too")
    for state in [TodoItem.State.review, .needsYou, .done, .cancelled] {
        try! store.change(ready.id) { $0.state = state }
        let text = run(work, "todo_edit", ["id": ready.id.uuidString, "title": "바꿈"])
        expect(!text.ok && store.current.item(ready.id)?.title == "준비 수정", "\(state): its text is not changed")
        expect(!run(work, "todo_edit", ["id": ready.id.uuidString, "state": "ready"]).ok && store.current.item(ready.id)?.state == state, "\(state): nor its state")
        expect(run(work, "todo_edit", ["id": ready.id.uuidString, "before": draft.id.uuidString]).ok && store.current.ordered(appList).first?.id == ready.id, "\(state): it may move")
        try! store.move(ready.id, before: nil)
    }
    let hidden = run(work, "todo_list", [:]), shownDone = run(work, "todo_list", ["include_done": true])
    expect(!hidden.text.contains(ready.id.uuidString) && shownDone.text.contains(ready.id.uuidString) && shownDone.text.contains("state: cancelled"), "done/cancelled only with include_done")
    try! store.change(ready.id) { $0.state = .ready }
    expect(run(work, "todo_edit", ["id": draft.id.uuidString, "title": "새 제목\n둘째 줄"]).ok && store.current.item(draft.id)?.title == "새 제목", "a title is one line")
    expect(!run(work, "todo_edit", ["id": draft.id.uuidString, "title": "  "]).ok && store.current.item(draft.id)?.title == "새 제목", "an empty title is refused")
    expect(!run(work, "todo_edit", ["id": draft.id.uuidString]).ok, "nothing to change is refused")
    expect(!run(work, "todo_edit", ["id": schoolDraft.id.uuidString, "title": "바꿈"]).ok && store.current.item(schoolDraft.id)?.title == "학교 초안",
           "a personal chat cannot change an Enterprise project's draft")
    expect(!run(work, "todo_edit", ["id": schoolDraft.id.uuidString, "state": "ready"]).ok && store.current.item(schoolDraft.id)?.state == .draft,
           "nor make it ready")
    expect(!run(locked, "todo_edit", ["id": ready.id.uuidString, "title": "바꿈"]).ok && store.current.item(ready.id)?.title == "준비 수정",
           "an Enterprise chat cannot change a personal project's TODO")
    expect(run(locked, "todo_edit", ["id": schoolDraft.id.uuidString, "title": "학교 수정"]).ok && store.current.item(schoolDraft.id)?.title == "학교 수정",
           "its organization's chat can")
    expect((try? store.editForAI(schoolDraft.id, title: "x", detail: nil, askFirst: nil, organization: nil)) == nil, "the store checks the lock too")
    expect((try? store.editForAI(schoolDraft.id, title: nil, detail: nil, askFirst: nil, before: .some(nil), organization: "다른 곳")) == nil, "another organization too")
    // Long details are not cut, too long ones refused; more than 30 drafts come by offset.
    let long = String(repeating: "가", count: 9000)
    try! store.change(draft.id) { $0.detail = long }
    expect(run(work, "todo_edit", ["id": draft.id.uuidString, "detail": long + "끝"]).ok == false && store.current.item(draft.id)?.detail == long, "a detail over the limit is refused, not cut")
    expect(run(work, "todo_edit", ["id": draft.id.uuidString, "detail": "앞" + long.dropFirst()]).ok && store.current.item(draft.id)?.detail.count == 9000, "a board detail longer than 8000 is kept whole")
    for n in 0..<31 { _ = try! store.add(title: "많은 초안 \(n)", project: app, projectName: "App", fromAI: true) }   // drafts although a TODO is ready
    let first = run(work, "todo_list", [:]), second = run(work, "todo_list", ["offset": 30])
    expect(first.text.contains("offset 30") && !first.text.contains("많은 초안 30") && second.text.contains("많은 초안 30") && second.text.contains("많은 초안 29"), "the next drafts by offset")
    // state "done": from any state when the user asks; another chat's running work is stopped, the TODO chat's own answer just ends.
    var stopped: [UUID] = []
    let savedStop = link.stopChat
    link.stopChat = { stopped.append($0) }
    defer { link.stopChat = savedStop }
    let finish = try! store.add(title: "끝낼 것", project: app, projectName: "App", fromAI: true)
    expect(editHelp.contains("\"done\" only when the user asks"), "done is only for the user's word")
    expect(!run(work, "todo_edit", ["id": finish.id.uuidString, "state": "done", "title": "x"]).ok && store.current.item(finish.id)?.state == .draft
           && store.current.item(finish.id)?.title == "끝낼 것", "done goes alone")
    for state in [TodoItem.State.draft, .ready, .needsYou, .review, .cancelled] {
        try! store.change(finish.id) { $0.state = state; $0.question = TodoQuestion(blocked: true, reason: "q") }
        let r = run(work, "todo_edit", ["id": finish.id.uuidString, "state": "done"])
        expect(r.ok && store.current.item(finish.id)?.state == .done && store.current.item(finish.id)?.question == nil, "\(state): todo_edit marks it done: \(r.text)")
    }
    let again = run(work, "todo_edit", ["id": finish.id.uuidString, "state": "done"])
    expect(again.ok && again.text.contains("already done"), "already done: nothing changes")
    let elsewhere = UUID()
    try! store.change(finish.id) { $0.state = .running; $0.room = elsewhere }
    let fromOther = run(work, "todo_edit", ["id": finish.id.uuidString, "state": "done"])
    expect(fromOther.ok && store.current.item(finish.id)?.state == .done && stopped == [elsewhere] && fromOther.text.contains("stopped"),
           "a running TODO marked done from another chat: its chat is stopped: \(fromOther.text)")
    try! store.change(finish.id) { $0.state = .running; $0.room = work.id }
    let fromOwn = run(work, "todo_edit", ["id": finish.id.uuidString, "state": "done"])
    expect(fromOwn.ok && store.current.item(finish.id)?.state == .done && stopped == [elsewhere] && fromOwn.text.contains("task_done"),
           "in the TODO's own chat the answer is not stopped, it just ends: \(fromOwn.text)")
    expect(!run(work, "todo_edit", ["id": schoolDraft.id.uuidString, "state": "done"]).ok && store.current.item(schoolDraft.id)?.state == .draft,
           "a personal chat cannot mark an Enterprise TODO done")
    expect(!run(locked, "todo_edit", ["id": ready.id.uuidString, "state": "done"]).ok && store.current.item(ready.id)?.state == .ready,
           "an Enterprise chat cannot mark a personal TODO done")
    expect((try? store.markDone(schoolDraft.id, organization: .some(nil))) == nil && store.current.item(schoolDraft.id)?.state == .draft, "the store checks the lock too")
    expect(run(locked, "todo_edit", ["id": schoolDraft.id.uuidString, "state": "done"]).ok && store.current.item(schoolDraft.id)?.state == .done,
           "its organization's chat can")
    print("PASS: todo_list/todo_edit (board order and states, draft and ready text, state/before, running refused, others only move, Enterprise apart, long details whole, offset, done from any state)")
}

// The chat side for testTodoMarkDone: chats answer until stopped; a stopped chat's turn ended with an error.
private final class DoneChats: TodoChats {
    let changed = PassthroughSubject<Void, Never>()
    var answering: Set<UUID> = []
    var answeringChanged: AnyPublisher<Void, Never> { changed.eraseToAnyPublisher() }
    var maxAnswering = 5
    var importing = false
    var chats: [ProjectChatSummary] = []
    var started: [UUID] = [], stopped: [UUID] = []
    func crew(lock: EnterpriseLock?, allowed: [String]) -> (lead: Account, reviewer: Account?)? { (Account(id: "done-lead", provider: .claude, name: "Lead"), nil) }
    func noCrew(_ allowed: [String], lock: EnterpriseLock?) -> String { "nobody" }
    func addChat(_ project: ProjectBinding, title: String, lock: EnterpriseLock?) -> UUID { UUID() }
    func setCrew(room: UUID, members: [String], lead: String) {}
    func folder(_ room: UUID) -> URL { URL(fileURLWithPath: AccountStore.home).appendingPathComponent("todo-done-chats/" + room.uuidString) }
    func sentPhotos(_ room: UUID) -> Set<UUID> { [] }
    func start(room: UUID, question: String, photos: [TodoPhoto], review: Bool, extra: String) -> String? { started.append(room); answering.insert(room); return nil }
    func ended(_ room: UUID) -> TodoTurnEnd { TodoTurnEnd(error: "Stopped by the user") }
    func stop(_ room: UUID) { stopped.append(room); answering.remove(room) }
}

// [Mark as done] from any state: question, report and stand-ins cleared, the clocks closed; a running TODO is saved done
// and then its chat stops, so settle does not turn it back; the TODO below it and one waiting by "after" start.
func testTodoMarkDone() {
    let p = ProjectBinding(root: "/tmp/todo-markdone", common: "", remote: "", remoteURL: "")
    let q = ProjectBinding(root: "/tmp/todo-markdone-2", common: "", remote: "", remoteURL: "")
    let store = TodoStore(url: todoStoreFile("mark-done"))
    var clock = Date(timeIntervalSince1970: 3_000_000)
    store.now = { clock }
    let chats = DoneChats()
    let scheduler = TodoScheduler(chats: chats, store: store)
    scheduler.held = { _ in false }
    let states = ProjectBinding(root: "/tmp/todo-markdone-states", common: "", remote: "", remoteURL: "")
    for state in [TodoItem.State.draft, .ready, .needsYou, .review, .cancelled] {
        let item = try! store.add(title: "s-\(state)", project: states, projectName: "S")
        try! store.change(item.id) { t in
            t.state = state; t.question = TodoQuestion(blocked: true, reason: "q"); t.report = TodoReport(summary: "r"); t.unreported = true; t.standIns = 1
        }
        let set = clock
        clock += 60
        try! scheduler.markDone(item.id)
        let t = store.current.item(item.id)!
        // A cancelled one keeps its finishing time (clock's rule: finished once, done or cancelled).
        expect(t.state == .done && t.question == nil && t.report == nil && !t.unreported && t.standIns == 0 && t.finishedAt == (state == .cancelled ? set : clock) && t.stateSince == clock,
               "\(state): marked done at once with everything cleared")
        if state == .needsYou || state == .review { expect(t.waitSeconds == 60, "\(state): its waiting time is kept: \(t.waitSeconds)") }
        clock += 60
        try! scheduler.markDone(item.id)
        expect(store.current.item(item.id) == t, "\(state): done again changes nothing")
    }
    expect(chats.stopped.isEmpty && chats.started.isEmpty, "no chat stopped or started for TODOs that do not run")
    expect(TodoStore(url: store.url).current.items.allSatisfy { $0.state == .done }, "saved")

    // Running: A runs, B below it waits in order, C on another project waits for A by an "after" link.
    let a = try! store.add(title: "A", project: p, projectName: "P")
    let b = try! store.add(title: "B", project: p, projectName: "P")
    let c = try! store.add(title: "C", project: q, projectName: "Q", after: [a.id])
    scheduler.startNow()
    expect(store.current.item(a.id)?.state == .running && store.current.item(b.id)?.state == .ready && store.current.item(c.id)?.state == .ready
           && chats.started.count == 1, "A runs, B and C wait for it")
    let room = store.current.item(a.id)!.room!
    clock += 120
    expect((try? store.markDone(a.id)) == nil && store.current.item(a.id)?.state == .running, "the store alone refuses a running TODO")
    try! scheduler.markDone(a.id)
    let done = store.current.item(a.id)!
    expect(done.state == .done && chats.stopped == [room] && done.workSeconds == 120 && done.finishedAt == clock, "the chat is stopped and A is done, its work time kept")
    scheduler.tick()   // settle sees the stopped chat's error: A is not running any more, so it stays done
    let after = store.current.item(a.id)!
    expect(after.state == .done && after.attempts == 0 && after.lastError == nil && !after.notes.contains { $0.kind == .retry }, "settle does not overwrite it: \(after.state)")
    expect(store.current.item(b.id)?.state == .running && store.current.item(c.id)?.state == .running && chats.started.count == 3,
           "the TODO below and the one waiting by \"after\" start")
    print("PASS: mark done (every state at once, cleared and timed, done twice nothing; running: saved, chat stopped, settle passes it; B and C go on)")
}

// The chat side for testTodoStandIn: records what the AI answering in the user's place is asked; `reply` answers at
// once, or nil keeps `done` for later (the user may answer first).
private final class StandInChats: TodoChats {
    let changed = PassthroughSubject<Void, Never>()
    var answering: Set<UUID> = []
    var answeringChanged: AnyPublisher<Void, Never> { changed.eraseToAnyPublisher() }
    var maxAnswering = 3
    var importing = false
    var chats: [ProjectChatSummary] = []
    var briefs: [String] = []
    var questions: [String] = []
    var reply: TodoStandInReply? = TodoStandInReply(by: "Codex", text: "ANSWER: B, it is easy to undo")
    var later: ((TodoStandInReply) -> Void)?
    var tokens: [DebateCancellation] = []
    var wrote: Set<UUID> = []   // rooms where the user wrote since the question
    func crew(lock: EnterpriseLock?, allowed: [String]) -> (lead: Account, reviewer: Account?)? { (Account(id: "standin-lead", provider: .claude, name: "Lead"), nil) }
    func noCrew(_ allowed: [String], lock: EnterpriseLock?) -> String { "nobody" }
    func addChat(_ project: ProjectBinding, title: String, lock: EnterpriseLock?) -> UUID { UUID() }
    func setCrew(room: UUID, members: [String], lead: String) {}
    func folder(_ room: UUID) -> URL { URL(fileURLWithPath: AccountStore.home).appendingPathComponent("todo-standin-chats/" + room.uuidString) }
    func sentPhotos(_ room: UUID) -> Set<UUID> { [] }
    func start(room: UUID, question: String, photos: [TodoPhoto], review: Bool, extra: String) -> String? { questions.append(question); return nil }
    func ended(_ room: UUID) -> TodoTurnEnd { TodoTurnEnd() }
    func stop(_ room: UUID) {}
    func userWrote(_ room: UUID, since: Date) -> Bool { wrote.contains(room) }
    func standIn(room: UUID, brief: String, token: DebateCancellation, done: @escaping (TodoStandInReply) -> Void) {
        briefs.append(brief); tokens.append(token)
        if let reply { done(reply) } else { later = done }
    }
}

// A question unanswered for 30 minutes: another AI answers in the user's place, once until the user answers; blocked
// questions, lists that turned it off and declined answers wait for the user; an answer that comes after the user's is dropped.
func testTodoStandIn() {
    let p = ProjectBinding(root: "/tmp/todo-standin", common: "", remote: "", remoteURL: "")
    let store = TodoStore(url: todoStoreFile("standin"))
    var clock = Date(timeIntervalSince1970: 2_000_000)
    store.now = { clock }
    let chats = StandInChats()
    let scheduler = TodoScheduler(chats: chats, store: store)
    scheduler.held = { _ in false }
    let question = TodoQuestion(blocked: false, reason: "Which layout?", items: [.init(text: "Layout", options: ["A", "B"], recommended: "B")])
    func ask(_ id: UUID, _ q: TodoQuestion = question) { try! store.change(id) { $0.state = .needsYou; $0.room = $0.room ?? UUID(); $0.question = q } }
    let item = try! store.add(title: "layout", project: p, projectName: "S")
    expect(store.current.list(item.listID)?.standIn == true, "on by default")
    ask(item.id)
    clock += 29 * 60; scheduler.tick()
    expect(chats.briefs.isEmpty, "not before 30 minutes")
    clock += 2 * 60; scheduler.tick()
    var t = store.current.item(item.id)!
    expect(chats.briefs.count == 1 && chats.briefs[0].contains("Which layout?") && chats.briefs[0].contains("recommended: B"), "after 30 minutes another AI is asked the question")
    expect(t.state != .needsYou && t.standIns == 1 && t.notes.last?.by == "Codex" && t.notes.last?.text == "B, it is easy to undo", "its answer goes on: \(t.state)")
    expect(chats.questions.last?.contains("Codex") == true && chats.questions.last?.contains("B, it is easy to undo") == true, "the next attempt is told who answered")
    expect(TodoStore(url: store.url).current.item(item.id)?.notes.last?.by == "Codex", "who answered is saved")
    // Asked again before the user said anything: the user decides this time.
    ask(item.id, TodoQuestion(blocked: false, reason: "And the color?", items: [.init(text: "Color")]))
    clock += 3600; scheduler.tick()
    expect(chats.briefs.count == 1 && store.current.standInDue(store.current.item(item.id)!) == nil, "once until the user answers")
    store.answer(item.id, "red")
    expect(store.current.item(item.id)?.standIns == 0, "the user's answer allows it again")

    // Blocked, or turned off for the list: the user decides.
    let blocked = try! store.add(title: "blocked", project: ProjectBinding(root: "/tmp/todo-standin-2", common: "", remote: "", remoteURL: ""), projectName: "S2")
    ask(blocked.id, TodoQuestion(blocked: true, reason: "Needs approval"))
    let off = try! store.add(title: "off", project: ProjectBinding(root: "/tmp/todo-standin-3", common: "", remote: "", remoteURL: ""), projectName: "S3")
    try! store.setList(off.listID, standIn: false)
    ask(off.id)
    clock += 3600; scheduler.tick()
    expect(chats.briefs.count == 1, "blocked questions and lists that turned it off wait for the user")

    // Declined: it keeps waiting, with why; not asked again.
    try! store.setList(off.listID, standIn: true)
    chats.reply = TodoStandInReply(by: "Codex", text: "DECLINE: only the user knows the budget")
    clock += 60; scheduler.tick()
    t = store.current.item(off.id)!
    expect(chats.briefs.count == 2 && t.state == .needsYou && t.standIns == 1 && t.notes.last?.kind == .system && t.notes.last?.text.contains("budget") == true, "a decline waits for the user")
    clock += 3600; scheduler.tick()
    expect(chats.briefs.count == 2, "a declined question is not asked again")
    expect(TodoScheduler.standInAnswer("I think B").answer == nil && TodoScheduler.standInAnswer("answer: B").answer == "B", "only a reply that starts with ANSWER: answers")

    // Nobody could be asked: tried again 30 minutes later, not at every tick.
    let later = try! store.add(title: "later", project: ProjectBinding(root: "/tmp/todo-standin-4", common: "", remote: "", remoteURL: ""), projectName: "S4")
    ask(later.id)
    chats.reply = TodoStandInReply(error: "No AI is free")
    clock += 31 * 60; scheduler.tick()
    expect(chats.briefs.count == 3 && store.current.item(later.id)?.standIns == 0, "a failed ask is not counted")
    clock += 60; scheduler.tick()
    expect(chats.briefs.count == 3, "and not tried again at once")
    // The user answers while the other AI is still thinking: its answer is dropped.
    chats.reply = nil
    clock += 30 * 60; scheduler.tick()
    expect(chats.briefs.count == 4 && chats.later != nil, "tried again after 30 minutes")
    expect(scheduler.standingIn == [later.id] && !chats.tokens[3].isCancelled, "the card can show that another AI answers now")
    store.answer(later.id, "mine")
    scheduler.tick()
    expect(chats.tokens[3].isCancelled && scheduler.standingIn.isEmpty, "the user's answer stops the AI still answering")
    chats.later?(TodoStandInReply(by: "Codex", text: "ANSWER: theirs"))
    t = store.current.item(later.id)!
    expect(t.notes.last?.text == "mine" && t.notes.allSatisfy { $0.by == nil } && t.standIns == 0, "an answer after the user's is dropped")

    // Asked again in the same words before the late answer came (no tick between): it is not the question it answered.
    let again = try! store.add(title: "again", project: ProjectBinding(root: "/tmp/todo-standin-5", common: "", remote: "", remoteURL: ""), projectName: "S5")
    ask(again.id)
    clock += 31 * 60; scheduler.tick()
    expect(chats.briefs.count == 5 && scheduler.standingIn.contains(again.id), "asked")
    let late = chats.later
    store.answer(again.id, "A")
    try! store.change(again.id) { $0.state = .running }
    ask(again.id, TodoQuestion(blocked: false, reason: question.reason, items: question.items))
    late?(TodoStandInReply(by: "Codex", text: "ANSWER: B"))
    t = store.current.item(again.id)!
    expect(t.state == .needsYou && t.question?.reason == "Which layout?" && t.notes.allSatisfy { $0.by == nil } && t.standIns == 0, "a late answer to the same words is dropped")
    scheduler.tick()
    expect(chats.briefs.count == 5, "the new question waits its own 30 minutes")

    // A late failure for an old question does not hold back the new one's stand-in.
    clock += 31 * 60; scheduler.tick()
    expect(chats.briefs.count == 6, "the new question is asked after its 30 minutes")
    let failed = chats.later
    clock += 60
    store.answer(again.id, "A again")
    try! store.change(again.id) { $0.state = .running }
    ask(again.id, TodoQuestion(blocked: false, reason: "Which font?", items: [.init(text: "Font", options: ["X", "Y"])]))
    clock += 3 * 60
    failed?(TodoStandInReply(error: "No AI is free"))
    clock += 29 * 60; scheduler.tick()
    expect(chats.briefs.count == 7 && chats.briefs[6].contains("Which font?"), "the retry of the old question is not the new one's")

    // The user wrote in the TODO's chat since it asked: nobody answers for them.
    chats.reply = TodoStandInReply(by: "Codex", text: "ANSWER: B")
    let here = try! store.add(title: "here", project: ProjectBinding(root: "/tmp/todo-standin-6", common: "", remote: "", remoteURL: ""), projectName: "S6")
    ask(here.id)
    chats.wrote.insert(store.current.item(here.id)!.room!)
    clock += 31 * 60; scheduler.tick()
    expect(chats.briefs.count == 7 && store.current.item(here.id)?.state == .needsYou, "a user message in the chat holds the stand-in")
    // Stopping the TODO stops a stand-in that runs.
    chats.wrote = []; chats.reply = nil
    clock += 60; scheduler.tick()
    expect(chats.briefs.count == 8 && scheduler.standingIn.contains(here.id), "asked once the chat is quiet")
    scheduler.cancel(here.id)
    expect(chats.tokens[7].isCancelled && !scheduler.standingIn.contains(here.id), "Stop cancels it")

    // A question saved before it had an id gets one; a saved id stays.
    let saved = try! JSONSerialization.jsonObject(with: JSONEncoder().encode(question)) as! [String: Any]
    expect(saved["id"] as? String == question.id.uuidString && (try! JSONDecoder().decode(TodoQuestion.self, from: JSONEncoder().encode(question))) == question, "the id is saved")
    var bare = saved; bare.removeValue(forKey: "id")
    let older = try! JSONDecoder().decode(TodoQuestion.self, from: JSONSerialization.data(withJSONObject: bare))
    expect(older.reason == question.reason && older.items == question.items && older.id != question.id, "an older question gets a new id")

    // An older file without the setting: on.
    var data = TodoData(); data.lists = [TodoList(title: "old", project: p)]
    var json = try! JSONSerialization.jsonObject(with: TodoStore.encoder.encode(data)) as! [String: Any]
    var lists = json["lists"] as! [[String: Any]]; lists[0].removeValue(forKey: "standIn"); json["lists"] = lists
    let old = try! TodoStore.decoder.decode(TodoData.self, from: JSONSerialization.data(withJSONObject: json))
    expect(old.lists[0].standIn, "an older list gets it on")
    print("PASS: TODO stand-in answer (30 minutes, once until the user answers, blocked/off/declined wait, failure retried later, late answer dropped, stopped when no longer wanted, same words asked again, retry per question, user in the chat, card state)")
}

// A message written in a TODO's own chat (TodoScheduler.chatMessage through Discussion.send): it answers the question,
// asks for changes or makes a draft ready, and the next attempt starts in the same chat with that message first, never a
// plain turn the TODO does not know about; messages queued while it ran go the same way; a done TODO's chat is a plain chat.
func testTodoChatMessage() {
    let project = todoProject("todo-chat-message")
    let saved = TodoStore.shared, savedScheduler = TodoScheduler.shared
    let store = TodoStore(url: todoStoreFile("chat-message"))
    TodoStore.shared = store
    let model = AppModel()
    model.accounts = [Account(id: "chatmsg-claude", provider: .claude, name: "Chat Claude")]
    var u = AIUsage(name: "x"); u.fiveHour = UsageWindow(usedPercent: 10, resetsAt: nil); u.weekly = UsageWindow(usedPercent: 10, resetsAt: nil)
    model.latestUsage["chatmsg-claude"] = u
    let chat = Discussion(model: model)
    let scheduler = TodoScheduler(discussion: chat, store: store)
    TodoScheduler.shared = scheduler
    defer { TodoStore.shared = saved; TodoScheduler.shared = savedScheduler }
    var asks: [String] = [], askReply = ""
    chat.workspaceAnswer = { _, prompt, binding, _, _ in
        let current = prompt.components(separatedBy: "[User]\n").last ?? ""
        asks.append(current)
        guard current.contains("TODO: chatty") else { return .success("You're welcome.") }
        let room = store.current.items.first { $0.state == .running }?.room ?? UUID()
        let context = ToolContext(room: room, roots: binding.roots, projectRun: binding.projectRunID, projectGeneration: binding.projectGeneration)
        func done(_ summary: String) -> Result<String, Answerer.Failure> { _ = TaskLink.shared.call("task_done", ["summary": summary], context: context); return .success(summary) }
        if current.hasPrefix("and docs") { return done("Docs too") }
        if current.hasPrefix("add docs") { return done("Docs") }
        if current.hasPrefix("TODO: chatty") && current.contains("later please") { return done("Later") }
        if current.hasPrefix("add tests") { Thread.sleep(forTimeInterval: 0.3); return done("Added tests") }
        if current.hasPrefix("use B") { return done("Used B") }
        let r = TaskLink.shared.call("task_ask", ["kind": "question", "reason": "Which way?", "questions": [["text": "A or B?", "options": ["A", "B"]]]], context: context)
        askReply = ((r["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
        return .success("I need your decision.")
    }
    func settle(_ until: () -> Bool) {
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline && (!until() || chat.anyRunning) { RunLoop.main.run(until: Date().addingTimeInterval(0.03)) }
    }
    func say(_ text: String) { chat.draft = text; chat.send() }
    scheduler.start()
    let item = try! store.add(title: "chatty", project: project, projectName: "C")
    store.startDrafts()
    settle { store.current.item(item.id)?.state == .needsYou }
    let room = store.current.item(item.id)!.room!
    expect(askReply.contains("on the TODO card or in this chat"), "task_ask says where the user answers: \(askReply)")
    chat.open(room)
    expect(chat.currentID == room, "the TODO's chat is open")

    // needsYou: the message is the answer, and the next attempt starts here at once with it first.
    var turns = chat.conversation(room).turns.count
    say("use B")
    var t = store.current.item(item.id)!
    expect(t.state == .running && t.question == nil && t.notes.last?.kind == .answer && t.notes.last?.text == "use B" && chat.draft.isEmpty, "the answer goes to the TODO: \(t.state)")
    expect(chat.conversation(room).turns.count == turns + 1 && chat.conversation(room).turns.last?.question.hasPrefix("use B") == true
           && chat.conversation(room).turns.last?.question.contains("TODO: chatty") == true, "one turn, the TODO's attempt, shows the message first")
    settle { store.current.item(item.id)?.state == .review }
    t = store.current.item(item.id)!
    expect(t.result == "Used B" && t.standIns == 0 && store.current.standInDue(t) == nil, "the attempt ends in review, and no stand-in is due: \(t.state)")
    expect(chat.conversation(room).turns.count == turns + 1, "no plain turn besides it")

    // review: a change request; a message sent while it runs waits and goes to the TODO too when the attempt ends.
    turns = chat.conversation(room).turns.count
    say("add tests")
    expect(store.current.item(item.id)?.state == .running && store.current.item(item.id)?.notes.last?.kind == .feedback, "a message on a result is a change request")
    say("and docs")
    expect(chat.conversation(room).queued?.count == 1, "sent while the TODO runs, it waits")
    settle { store.current.item(item.id)?.result == "Docs too" && store.current.item(item.id)?.state == .review }
    t = store.current.item(item.id)!
    expect(t.state == .review && t.result == "Docs too" && t.notes.last?.text == "and docs" && chat.conversation(room).queued == nil, "the queued message is the next change request: \(t.result ?? "-")")
    expect(chat.conversation(room).turns.count == turns + 2 && !asks.contains { $0.hasPrefix("and docs") && !$0.contains("TODO: chatty") }, "two attempts, no plain turn")

    // draft (or ready): a note, ready, started.
    try! store.change(item.id) { $0.state = .draft }
    say("add docs")
    settle { store.current.item(item.id)?.result == "Docs" }
    t = store.current.item(item.id)!
    expect(t.state == .review && t.notes.last?.kind == .feedback && t.notes.last?.text == "add docs", "a draft's chat message makes it ready and it runs: \(t.state)")

    // It may not start now (its list is paused): the message waits on the TODO, said in the message box, no turn.
    try! store.pause(lists: [t.listID])
    turns = chat.conversation(room).turns.count
    say("later please")
    t = store.current.item(item.id)!
    let waitTurn = chat.conversation(room).turns.last
    expect(t.state == .ready && t.notes.last?.text == "later please" && !chat.anyRunning && chat.conversation(room).turns.count == turns + 1
           && waitTurn?.question == "later please" && waitTurn?.final != nil && ChatStore.loadAll().first { $0.id == room }?.turns.last?.question == "later please",
           "a TODO that cannot start keeps the message, and the chat shows and saves it: \(t.state)")
    try! store.resume(lists: [t.listID])
    settle { store.current.item(item.id)?.result == "Later" }
    let later = chat.conversation(room).turns.last?.question ?? ""
    expect(store.current.item(item.id)?.state == .review && later.hasPrefix("TODO: chatty") && later.contains("later please"), "it starts once it may, the message in its notes, not shown twice")

    // Not saved (the TODO file cannot be written): the message stays in the box and nothing changes.
    try! store.change(item.id) { $0.state = .needsYou; $0.question = TodoQuestion(blocked: true, reason: "r") }
    let dir = store.url.deletingLastPathComponent()
    try! FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: dir.path)
    say("lost?")
    try! FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
    expect(chat.draft == "lost?" && chat.attachmentError != nil && store.current.item(item.id)?.state == .needsYou && !chat.anyRunning, "a failed save keeps the message: \(chat.draft)")
    chat.draft = ""; chat.attachmentError = nil
    try! store.change(item.id) { $0.state = .review; $0.question = nil }

    // done: a plain chat again.
    store.accept(item.id)
    turns = chat.conversation(room).turns.count
    say("thanks")
    settle { chat.conversation(room).turns.last?.final != nil }
    expect(store.current.item(item.id)?.state == .done && chat.conversation(room).turns.count == turns + 1 && chat.conversation(room).turns.last?.question == "thanks",
           "a done TODO's chat answers as a plain chat: \(store.current.item(item.id)?.state.rawValue ?? "-")")
    print("PASS: TODO chat messages (answer, change request, draft made ready, queued message, waits when it cannot start, done is plain)")
}
