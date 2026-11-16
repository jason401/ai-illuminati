import Foundation
import AIAccounts
import AILocalization
@testable import AIRuntime
@testable import AIWorkspace
@testable import AIProjects
@testable import AIChat

/// Failures in the middle of an answer, with a fake CLI in place of claude (Answerer.toolForTests), no answer hooks:
/// the CLI killed while it writes, out of usage, the network gone, a time-out, the account switched, the app quitting.
/// After each one the reply so far and the chat stay in chats/<id>.json, the chat no longer shows "answering", the
/// failure says it can be tried again, and trying again continues from what was written. Project work keeps a record of
/// the files it changed, so they can be undone, also when the app quit in the middle.
private struct FakeCLI {
    let dir: URL
    let script: URL
    struct Call { var who: String; var prompt: String }
    init(_ name: String) {
        let fm = FileManager.default
        dir = URL(fileURLWithPath: AccountStore.home).appendingPathComponent(name)
        try? fm.removeItem(at: dir)
        try! fm.createDirectory(at: dir.appendingPathComponent("calls"), withIntermediateDirectories: true)
        // A rule: "if" text in the prompt (and "who", the account folder's name), then "write" a file, stream "chunks"
        // (each a text delta, "pause" seconds apart) and "end": finish (the whole text), kill (SIGKILL itself), limit
        // (Claude's usage-limit result), network (a connection error), hang (sleep until stopped).
        try! #"""
        import sys, json, os, time, signal
        D = sys.argv[1]; args = sys.argv[2:]
        if '--input-format' in args:
            prompt = ''.join(b.get('text', '') for b in json.loads(sys.stdin.readline())['message']['content'])
        else: prompt = sys.stdin.read()
        who = os.path.basename(os.environ.get('CLAUDE_CONFIG_DIR', ''))
        rule = {'chunks': ['TL;DR: ok\nok'], 'end': 'finish'}
        for r in json.load(open(D + '/rules.json')):
            if r.get('who', who) == who and r['if'] in prompt: rule = r; break
        json.dump({'who': who, 'prompt': prompt}, open('%s/calls/%f-%d.json' % (D, time.time(), os.getpid()), 'w'))
        if 'write' in rule: open(rule['write']['file'], 'w').write(rule['write']['text'])
        sid = args[args.index('--session-id') + 1] if '--session-id' in args else args[args.index('--resume') + 1] if '--resume' in args else ''
        stream = 'stream-json' in args
        def out(o): sys.stdout.write(json.dumps(o) + '\n'); sys.stdout.flush()
        if stream: out({'type': 'stream_event', 'event': {'type': 'message_start'}})
        for piece in rule['chunks']:
            if stream: out({'type': 'stream_event', 'event': {'type': 'content_block_delta', 'delta': {'type': 'text_delta', 'text': piece}}})
            time.sleep(rule.get('pause', 0.25))
        end = rule.get('end', 'finish')
        if end == 'kill': os.kill(os.getpid(), signal.SIGKILL)
        if end == 'hang': time.sleep(120); sys.exit(1)
        if end == 'network':
            sys.stderr.write('API Error: Connection error. (ECONNRESET)\n'); sys.exit(1)
        if end == 'limit':
            out({'type': 'result', 'session_id': sid, 'is_error': True, 'result': 'Claude AI usage limit reached|1900000000'}); sys.exit(1)
        if stream: out({'type': 'stream_event', 'event': {'type': 'message_stop'}})
        text = ''.join(rule['chunks'])
        if '--output-format' in args: out({'type': 'result', 'session_id': sid, 'is_error': False, 'result': text})
        else: print(text)
        """#.write(to: dir.appendingPathComponent("fake.py"), atomically: true, encoding: .utf8)
        script = dir.appendingPathComponent("cli")
        try! "#!/bin/sh\nexec /usr/bin/python3 -I '\(dir.path)/fake.py' '\(dir.path)' \"$@\"\n".write(to: script, atomically: true, encoding: .utf8)
        try! fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
    }
    func rules(_ list: [[String: Any]]) {
        try! JSONSerialization.data(withJSONObject: list).write(to: dir.appendingPathComponent("rules.json"))
        let calls = dir.appendingPathComponent("calls")
        for file in (try? FileManager.default.contentsOfDirectory(atPath: calls.path)) ?? [] { try? FileManager.default.removeItem(at: calls.appendingPathComponent(file)) }
    }
    func calls() -> [Call] {
        let calls = dir.appendingPathComponent("calls")
        return ((try? FileManager.default.contentsOfDirectory(atPath: calls.path)) ?? []).sorted().compactMap { name in
            guard let data = try? Data(contentsOf: calls.appendingPathComponent(name)),
                  let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            return Call(who: o["who"] as? String ?? "", prompt: o["prompt"] as? String ?? "")
        }
    }
    // The fake in place of the CLI for `body`; the project process marker is set aside as in chat_cli.swift.
    func use(_ body: () -> Void) {
        let marker = ProcessInfo.processInfo.environment["AI_ILLUMINATI_PROJECT_PROCESS"]
        unsetenv("AI_ILLUMINATI_PROJECT_PROCESS")
        Answerer.toolForTests = script.path
        defer {
            Answerer.toolForTests = nil
            if let marker { setenv("AI_ILLUMINATI_PROJECT_PROCESS", marker, 1) }
        }
        body()
    }
}

private func wait(_ seconds: TimeInterval = 30, _ until: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline { if until() { return true }; RunLoop.main.run(until: Date().addingTimeInterval(0.03)) }
    return until()
}

// What chats/<id>.json holds now (not the chat in memory).
private func onDisk(_ id: UUID) -> Conversation? { ChatStore.loadAll().first { $0.id == id } }

private func failureProject(_ name: String) -> ProjectBinding {
    let root = URL(fileURLWithPath: AccountStore.home).appendingPathComponent(name)
    try? FileManager.default.removeItem(at: root)
    try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    func git(_ args: [String]) { _ = try! ProjectProcess.git(args, root: root.path) }
    git(["init", "-b", "main"]); git(["config", "user.name", "Fixture"]); git(["config", "user.email", "fixture@example.invalid"])
    git(["remote", "add", "origin", root.path + "/unused-origin"])
    try! "Baseline\n".write(to: root.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
    git(["add", "README.md"]); git(["commit", "-m", "Initial"])
    return try! ProjectProcess.inspect(root.path)
}

func testFailureRecovery() {
    let fake = FakeCLI("failure-cli")
    let a = Account(id: "fail-a", provider: .claude, name: "Claude A", dir: AccountStore.accountsDir + "/fail-a")
    let b = Account(id: "fail-b", provider: .claude, name: "Claude B", dir: AccountStore.accountsDir + "/fail-b")
    let model = AppModel()
    model.sharedFolders = []
    let savedTimeout = Discussion.soloTimeout
    defer { Discussion.soloTimeout = savedTimeout }
    // Every finding at once, so a run before the fixes lists them all.
    var problems: [String] = []
    func check(_ ok: Bool, _ what: String) { if !ok { problems.append(what) } }
    func send(_ chat: Discussion, _ text: String) {
        chat.draft = text; chat.send()
        _ = wait(60) { !chat.anyRunning && (chat.current.turns.last?.final != nil || chat.current.turns.last?.error != nil) }
    }
    // After a failure: kept in memory and on disk, not answering, and the chat says it can be tried again.
    func failedKeeping(_ chat: Discussion, _ part: String, _ name: String) -> ChatTurn? {
        let turn = chat.current.turns.last, saved = onDisk(chat.currentID)?.turns.last
        check(turn?.status == "" && turn?.partial == nil && !chat.anyRunning, "\(name): the chat still shows it answering: '\(turn?.status ?? "")'")
        check(turn?.error != nil, "\(name): no failure shown")
        check(turn?.final?.contains(part) == true && turn?.cutOff == true, "\(name): the reply so far is lost: final \(turn?.final ?? "nil") error \(turn?.error ?? "nil")")
        check(saved?.final?.contains(part) == true && saved?.cutOff == true && saved?.status == "", "\(name): chats/<id>.json lost the reply so far or still says answering")
        check(turn?.error?.contains(L("다시 시도", "Try again")) == true, "\(name): the failure does not say it can be tried again: \(turn?.error ?? "nil")")
        return turn
    }

    fake.use {
        // 1. The CLI killed while it writes: the reply so far stays, and Try again continues from it.
        model.accounts = [a]
        let chat = Discussion(model: model)
        chat.configure { $0.mode = 0; $0.soloAccountID = a.id }
        fake.rules([["if": "unfinished reply, cut off", "chunks": ["TL;DR: whole\nThe whole answer."]],
                    ["if": "Kill me", "chunks": ["Part one. ", "Part two."], "end": "kill"]])
        send(chat, "Kill me while you write.")
        if let killed = failedKeeping(chat, "Part one. Part two.", "killed") {
            fake.rules([["if": "unfinished reply, cut off", "chunks": ["TL;DR: whole\nThe whole answer."]]])
            chat.retry(killed)
            _ = wait(60) { !chat.anyRunning && chat.current.turns.count == 2 && (chat.current.turns.last?.final != nil || chat.current.turns.last?.error != nil) }
            let again = chat.current.turns.last, prompt = fake.calls().last?.prompt ?? ""
            check(chat.current.turns.count == 2 && again?.question == killed.question && again?.final?.contains("The whole answer.") == true && again?.cutOff == nil && again?.error == nil,
                  "killed: Try again does not answer the same message: \(again?.final ?? again?.error ?? "nothing")")
            check(prompt.contains("Part one. Part two.") && prompt.contains("unfinished reply, cut off"), "killed: Try again does not see the reply so far")
        }

        // 2. The network gone and 3. a time-out: the same.
        let net = Discussion(model: model)
        net.configure { $0.mode = 0; $0.soloAccountID = a.id }
        fake.rules([["if": "Network", "chunks": ["Net part."], "end": "network"]])
        send(net, "Network drops now.")
        let dropped = failedKeeping(net, "Net part.", "network")
        check(dropped?.error?.contains("Connection error") == true, "network: the reason is not shown: \(dropped?.error ?? "nil")")
        Discussion.soloTimeout = 4
        let slow = Discussion(model: model)
        slow.configure { $0.mode = 0; $0.soloAccountID = a.id }
        fake.rules([["if": "Time out", "chunks": ["Slow part."], "end": "hang"]])
        send(slow, "Time out please.")
        let late = failedKeeping(slow, "Slow part.", "time-out")
        check(late?.error?.contains(L("시간 안에", "timed out")) == true, "time-out: the reason is not shown: \(late?.error ?? "nil")")
        Discussion.soloTimeout = savedTimeout

        // 4. Out of usage: another account continues from the reply so far; with none left the reply so far stays.
        model.accounts = [a, b]
        let limit = Discussion(model: model)
        limit.configure { $0.mode = 0; $0.soloAccountID = a.id }
        fake.rules([["who": "fail-a", "if": "Limit", "chunks": ["Half from A."], "end": "limit"],
                    ["who": "fail-b", "if": "Limit", "chunks": ["TL;DR: full\nFull from B."]]])
        send(limit, "Limit test.")
        let handed = limit.current.turns.last, bPrompt = fake.calls().first { $0.who == "fail-b" }?.prompt ?? ""
        check(handed?.final?.contains("Full from B.") == true && handed?.finalBy == limit.label(b) && handed?.error == nil && handed?.status == "",
              "limit: another account does not take over: \(handed?.final ?? handed?.error ?? "nothing")")
        check(bPrompt.contains("Half from A."), "limit: the next account does not get the reply so far")
        check(handed?.orderNote?.contains(limit.label(a)) == true, "limit: the hand-over is not shown")
        model.accounts = [a]
        let alone = Discussion(model: model)
        alone.configure { $0.mode = 0; $0.soloAccountID = a.id }
        fake.rules([["if": "Limit", "chunks": ["Half from A."], "end": "limit"]])
        send(alone, "Limit test, alone.")
        _ = failedKeeping(alone, "Half from A.", "limit, nobody left")
        // The account taking over fails before it writes anything: A's reply so far still stays.
        model.accounts = [a, b]
        let twice = Discussion(model: model)
        twice.configure { $0.mode = 0; $0.soloAccountID = a.id }
        fake.rules([["who": "fail-a", "if": "Limit", "chunks": ["Half from A."], "end": "limit"],
                    ["who": "fail-b", "if": "Limit", "chunks": [], "end": "network"]])
        send(twice, "Limit test, then the network.")
        _ = failedKeeping(twice, "Half from A.", "limit, then the next account fails")

        // Text after the last save, then a long silence (a tool, the network): still saved within the save interval.
        model.accounts = [a]
        let quiet = Discussion(model: model)
        quiet.configure { $0.mode = 0; $0.soloAccountID = a.id }
        let quietRoom = quiet.currentID
        fake.rules([["if": "Quiet", "chunks": ["First. ", "Second."], "pause": 0.3, "end": "hang"]])
        quiet.draft = "Quiet after this."; quiet.send()
        check(wait(10) { onDisk(quietRoom)?.turns.last?.partial?.contains("Second.") == true }, "quiet: text after the last save is never saved while nothing more comes")
        quiet.stopDebate()
        _ = wait(30) { !quiet.anyRunning }

        // 5. The account switched while it answers (the chat hides its account chip then, so in Settings: the answering
        // account removed or signed out): the answer still lands in its turn under its own account, saved; the next
        // message goes to the account left.
        model.accounts = [a, b]
        let switched = Discussion(model: model)
        switched.configure { $0.mode = 0; $0.soloAccountID = a.id }
        fake.rules([["who": "fail-a", "if": "Switch", "chunks": ["TL;DR: a\n", "Done ", "by A."], "pause": 0.6],
                    ["who": "fail-b", "if": "After", "chunks": ["TL;DR: b\nB here."]]])
        switched.draft = "Switch while answering."; switched.send()
        check(wait { switched.current.turns.last?.partial?.contains("Done") == true }, "switch: no reply so far shown")
        switched.configure { $0.soloAccountID = b.id }   // refused while it answers, as the hidden chip
        check(switched.configuration.soloAccountID == a.id, "switch: the chat's account changed under the answer")
        model.accounts = [b]
        _ = wait(60) { !switched.anyRunning }
        let first = switched.current.turns.last
        check(first?.final?.contains("Done by A.") == true && first?.finalBy == switched.label(a) && first?.status == ""
              && onDisk(switched.currentID)?.turns.last?.final?.contains("Done by A.") == true,
              "switch: the answer under way is lost or credited wrongly: \(first?.final ?? first?.error ?? "nothing") by \(first?.finalBy ?? "")")
        send(switched, "After the switch.")
        check(switched.current.turns.last?.finalBy == switched.label(b), "switch: the next message is not answered by the new account")

        // 6. The app quits while it answers, and starts again: the reply so far is on disk while it is written and at
        // quit, and the chat after the restart is not answering, keeps it and says it can be tried again.
        model.accounts = [a]
        let quitting = Discussion(model: model)
        quitting.configure { $0.mode = 0; $0.soloAccountID = a.id }
        let room = quitting.currentID
        fake.rules([["if": "Quit", "chunks": ["Before quit. ", "More text."], "pause": 3, "end": "hang"]])
        quitting.draft = "Quit the app now."; quitting.send()
        check(wait(10) { onDisk(room)?.turns.last?.partial?.contains("Before quit.") == true }, "quit: the reply so far is not saved while it is written")
        check(wait(10) { quitting.current.turns.last?.partial?.contains("More text.") == true }, "quit: the second part never came")
        quitting.cancelAll()   // what applicationWillTerminate does; the app ends before anything else runs
        check(onDisk(room)?.turns.last?.partial?.contains("More text.") == true, "quit: the latest reply so far is not saved at quit")
        let relaunched = Discussion(model: model)
        let back = relaunched.conversation(room).turns.last, backOnDisk = onDisk(room)?.turns.last
        check(back?.status == "" && back?.partial == nil && back?.final?.contains("More text.") == true && back?.cutOff == true,
              "restart: the chat still shows it answering or lost the reply: '\(back?.status ?? "")' \(back?.final ?? "nil")")
        check(back?.error?.contains(L("다시 시도", "Try again")) == true, "restart: the chat does not say it stopped and can be tried again: \(back?.error ?? "nil")")
        check(backOnDisk?.status == "" && backOnDisk?.cutOff == true, "restart: the recovered turn is not saved")
        _ = wait(30) { !quitting.anyRunning }

        // 7. Project work: a CLI killed after changing a file keeps the reply so far and the list of changed files, and
        // Undo puts the file back; after a quit in the middle the restarted chat finds the changes too.
        let project = failureProject("failure-project")
        let readme = project.root + "/README.md"
        let work = Discussion(model: model)
        work.configure { $0.mode = 0; $0.leadID = a.id }
        work.toggleMember(a.id)
        work.change(work.currentID) { $0.workspace = WorkspaceBinding(roots: [WorkspaceRoot(path: project.root, directory: true)], project: project) }
        fake.rules([["if": "Edit README", "write": ["file": readme, "text": "Half done\n"], "chunks": ["Editing README."], "end": "kill"]])
        send(work, "Edit README please.")
        if let broken = failedKeeping(work, "Editing README.", "project killed") {
            check(broken.workspaceChanges?.contains { $0.path == readme } == true && broken.backupPath != nil, "project killed: the changed file is not listed: \(broken.workspaceChanges ?? [])")
            work.undoWorkspace(broken)
            _ = wait { !work.anyRunning }
            check((try? String(contentsOfFile: readme, encoding: .utf8)) == "Baseline\n", "project killed: Undo does not put the file back")
        }
        let crashing = Discussion(model: model)
        crashing.configure { $0.mode = 0; $0.leadID = a.id }
        crashing.toggleMember(a.id)
        crashing.change(crashing.currentID) { $0.workspace = WorkspaceBinding(roots: [WorkspaceRoot(path: project.root, directory: true)], project: project) }
        let crashRoom = crashing.currentID
        fake.rules([["if": "Rewrite README", "write": ["file": readme, "text": "Half again\n"], "chunks": ["Rewriting."], "pause": 0.5, "end": "hang"]])
        crashing.draft = "Rewrite README now."; crashing.send()
        check(wait(15) { onDisk(crashRoom)?.turns.last?.partial?.contains("Rewriting.") == true && onDisk(crashRoom)?.turns.last?.backupPath != nil },
              "project quit: the reply so far is not saved while it works")
        crashing.cancelAll()
        let reopened = Discussion(model: model)
        let found = reopened.conversation(crashRoom).turns.last
        check(found?.status == "" && found?.cutOff == true && found?.workspaceChanges?.contains { $0.path == readme } == true,
              "project quit: after the restart the changed file is not listed (no Undo): \(found?.workspaceChanges ?? []) '\(found?.status ?? "")'")
        _ = wait(30) { !crashing.anyRunning }
        reopened.open(crashRoom)
        if let found { reopened.undoWorkspace(found) }
        _ = wait { !reopened.anyRunning }
        check((try? String(contentsOfFile: readme, encoding: .utf8)) == "Baseline\n", "project quit: Undo after the restart does not put the file back")
    }
    expect(problems.isEmpty, "failure recovery:\n- " + problems.joined(separator: "\n- "))
    print("PASS: failures in the middle of an answer (killed, network, time-out, out of usage, account switched, app quit) keep the reply so far and the changed files, show the failure and can be tried again")
}

/// The TODO board after the same failures: a killed CLI is retried (the board shows ready with the reason) and after
/// the retries asks the user; a TODO whose app quit is ready again and its chat no longer answering.
func testTodoFailureRecovery() {
    let fake = FakeCLI("todo-failure-cli")
    let project = failureProject("todo-failure-project")
    let notes = project.root + "/NOTES.md"
    let saved = TodoStore.shared
    let url = URL(fileURLWithPath: AccountStore.home).appendingPathComponent("todo-tests/failure.json")
    try? FileManager.default.removeItem(at: url)
    let store = TodoStore(url: url)
    TodoStore.shared = store
    defer { TodoStore.shared = saved }
    let a = Account(id: "todo-fail-a", provider: .claude, name: "Todo A", dir: AccountStore.accountsDir + "/todo-fail-a")
    let model = AppModel()
    model.sharedFolders = []
    model.accounts = [a]
    var usage = AIUsage(name: "x"); usage.fiveHour = UsageWindow(usedPercent: 20, resetsAt: nil); usage.weekly = UsageWindow(usedPercent: 30, resetsAt: nil)
    model.latestUsage[a.id] = usage
    var problems: [String] = []
    func check(_ ok: Bool, _ what: String) { if !ok { problems.append(what) } }
    fake.use {
        let chat = Discussion(model: model)
        let scheduler = TodoScheduler(discussion: chat, store: store)
        func settle(_ until: () -> Bool) {
            let deadline = Date().addingTimeInterval(90)
            while Date() < deadline && (!until() || chat.anyRunning) { RunLoop.main.run(until: Date().addingTimeInterval(0.03)); scheduler.tick() }
        }
        fake.rules([["if": "TODO: crash", "write": ["file": notes, "text": "half\n"], "chunks": ["Started the notes."], "end": "kill"]])
        let crash = try! store.add(title: "crash", project: project, projectName: "P")
        scheduler.startNow()
        // The first attempt failed: ready again with the reason, not left running.
        settle { let i = store.current.item(crash.id); return i?.state != .running && (i?.attempts ?? 0) >= 1 }
        let retried = store.current.item(crash.id)
        check(retried?.state == .ready || retried?.state == .needsYou, "todo killed: the board still shows it running: \(retried?.state.rawValue ?? "")")
        check(retried?.notes.contains { $0.kind == .retry } == true && retried?.lastError != nil, "todo killed: the board does not say why it is retried")
        if retried?.state == .ready {
            let badge = retried.flatMap(TodoScheduler.retrying)
            check(badge?.label == L("다시 시도 1/2", "Retry 1 of 2") && badge?.why.isEmpty == false, "todo killed: the board row shows no Retry badge: \(badge?.label ?? "none")")
        }
        settle { store.current.item(crash.id)?.state == .needsYou }
        let parked = store.current.item(crash.id)
        check(parked?.state == .needsYou && parked?.question?.kind == .failed && parked?.question?.reason.isEmpty == false, "todo killed: after the retries it does not ask the user")
        if let room = parked?.room {
            let turns = chat.conversation(room).turns
            check(turns.allSatisfy { $0.status == "" }, "todo killed: a turn of its chat still shows it answering")
            check(turns.first?.final?.contains("Started the notes.") == true && turns.first?.cutOff == true, "todo killed: its chat lost the reply so far")
            check(turns.first?.workspaceChanges?.contains { $0.path == notes } == true, "todo killed: its chat does not list the half-made file")
            let later = fake.calls().dropFirst().first?.prompt ?? ""
            check(later.contains("Started the notes.") && later.contains("ended with an error"), "todo killed: the retry does not see the previous attempt")
        }
        try! store.cancel(crash.id)

        // The app quits while a TODO runs: after the restart the TODO is ready again and its chat not answering.
        fake.rules([["if": "TODO: quit", "write": ["file": notes, "text": "half again\n"], "chunks": ["Writing notes."], "pause": 0.5, "end": "hang"]])
        let quit = try! store.add(title: "quit", project: project, projectName: "P")
        scheduler.startNow()
        let room = store.current.item(quit.id)?.room
        check(room != nil && wait(15) { room.flatMap { onDisk($0)?.turns.last?.partial?.contains("Writing notes.") } == true },
              "todo quit: the reply so far is not saved while it works")
        chat.cancelAll()
        let relaunched = Discussion(model: model)
        let again = TodoScheduler(discussion: relaunched, store: store)
        again.recover()
        let item = store.current.item(quit.id)
        check(item?.state == .ready && item?.interrupted == true, "todo quit: not ready again after the restart: \(item?.state.rawValue ?? "")")
        check(item.flatMap(TodoScheduler.retrying)?.why.contains(L("앱이 꺼져서", "The app quit")) == true, "todo quit: the board row does not say the app quit during it")
        if let room {
            let turn = relaunched.conversation(room).turns.last
            check(turn?.status == "" && turn?.cutOff == true && turn?.workspaceChanges?.contains { $0.path == notes } == true,
                  "todo quit: its chat still answers or lost the reply and the changed file: '\(turn?.status ?? "")' \(turn?.workspaceChanges ?? [])")
        }
        try! store.cancel(quit.id)
        _ = wait(30) { !chat.anyRunning }
    }
    expect(problems.isEmpty, "TODO failure recovery:\n- " + problems.joined(separator: "\n- "))
    print("PASS: TODO board after failures (a killed CLI retried with its reason, then asks; after a quit ready again, its chat not answering, the changed files listed)")
}
