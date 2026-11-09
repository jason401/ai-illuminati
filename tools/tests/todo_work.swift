import Foundation

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
        {"lists":[{"id":"\(UUID().uuidString)","title":"Old","future":1}],"items":[{"id":"\(UUID().uuidString)","listID":"\(UUID().uuidString)","title":"t","state":"someday","extra":true}]}
        """
    let oldURL = todoStoreFile("old")
    try! FileManager.default.createDirectory(at: oldURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try! old.write(to: oldURL, atomically: true, encoding: .utf8)
    let read = TodoStore(url: oldURL).current
    expect(read.lists.first?.sequential == true && read.items.first?.state == .draft && read.version == 1, "older files: defaults for missing fields, unknown ones ignored")
    do { try store.delete(three.id) } catch { expect(false, "delete") }
    try! store.change(one.id) { $0.state = .running }
    do { try store.delete(one.id); expect(false, "a running TODO is not deleted") } catch {}
    // A save that fails changes nothing and says so (a folder stands where the file goes).
    let blockedURL = todoStoreFile("blocked")
    try! FileManager.default.createDirectory(at: blockedURL.appendingPathComponent("inside"), withIntermediateDirectories: true)
    let blocked = TodoStore(url: blockedURL)
    do { _ = try blocked.add(title: "lost", project: a, projectName: "A"); expect(false, "a failed save is an error") } catch { expect(error is TodoError, "the save error is a TODO error: \(error)") }
    expect(blocked.current.items.isEmpty && blocked.snapshot.items.isEmpty && blocked.saveError != nil, "a failed save leaves the TODOs as they were and is shown")
    print("PASS: TODO store (drafts, order and folder, gate review/done, other lists, circles refused, move, cancelled link, saved and read back, older files, failed save)")
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
