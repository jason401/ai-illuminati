import Foundation
import AIAccounts
import AIChatRecords
import AILocalization
import AIRuntime
import AIWorkspace
@testable import AIProjects
@testable import AIChat

// Sub-rooms (docs/SUBROOM_PLAN.md, P2) with fake AIs: the main room's AI splits, the sub-rooms' AIs commit and report,
// the main room merges and pushes and the app cleans up; approval by card or by full auto; refusals; the join turn once;
// Stop going down to the sub-rooms; what a restart finds; project_run one at a time per repository.
func testDelegate() {
    // Sub-rooms are an experimental switch, off unless the user turns it on (Settings ▸ Chat).
    expect(!DelegateLink.enabled, "sub-rooms are off by default")
    UserDefaults.app.set(true, forKey: DelegateLink.enabledKey)
    defer { UserDefaults.app.removeObject(forKey: DelegateLink.enabledKey) }
    func text(_ reply: [String: Any]) -> String { ((reply["content"] as? [[String: Any]])?.first?["text"] as? String) ?? "" }
    func failed(_ reply: [String: Any]) -> Bool { reply["isError"] as? Bool == true }
    func names(_ tools: [[String: Any]]) -> [String] { tools.compactMap { $0["name"] as? String } }
    @discardableResult func spin(_ seconds: TimeInterval, until done: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline && !done() { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        return done()
    }
    let base = URL(fileURLWithPath: AccountStore.home).appendingPathComponent("delegate-" + UUID().uuidString.prefix(8)).resolvingSymlinksInPath()
    try! FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    func git(_ args: [String], at folder: String) -> String { try! ProjectProcess.git(args, root: folder) }
    func write(_ text: String, _ name: String, in folder: String) {
        let url = URL(fileURLWithPath: folder).appendingPathComponent(name)
        try! FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try! text.write(to: url, atomically: true, encoding: .utf8)
    }
    // A repository with an origin, three files and (optionally) registered commands.
    func fixture(_ name: String, commands: String? = nil) -> ProjectBinding {
        let root = base.appendingPathComponent(name).path, origin = base.appendingPathComponent(name + ".git").path
        _ = git(["init", "-q", "--bare", origin], at: base.path); _ = git(["init", "-q", "-b", "main", root], at: base.path)
        _ = git(["config", "user.name", "Fixture"], at: root); _ = git(["config", "user.email", "fixture@example.invalid"], at: root)
        _ = git(["remote", "add", "origin", origin], at: root)
        write("a\n", "a.txt", in: root); write("b\n", "src/b.txt", in: root); write("one\ntwo\n", "shared.txt", in: root)
        if let commands { write(commands, ".ai-illuminati.json", in: root) }
        _ = git(["add", "-A"], at: root); _ = git(["commit", "-q", "-m", "Initial"], at: root); _ = git(["push", "-q", "-u", "origin", "main"], at: root)
        return try! ProjectProcess.inspect(root)
    }

    // Owned files: equal, a folder and a file in it, a glob and what it matches overlap; different files do not.
    func part(_ n: Int, _ owned: [String]) -> Split.Part { Split.Part(n: n, room: UUID(), goal: "g", owned: owned, forbidden: [], interfaces: "", done: "d") }
    expect(Split.overlap("src/", "src/b.txt") && Split.overlap("src", "src/b.txt") && Split.overlap("src/*.swift", "src/x.swift") && Split.overlap("a.txt", "./a.txt")
           && Split.overlap("src/a.swift", "src/./a.swift") && Split.overlap("src//a.swift", "src/a.swift")
           && Split.overlap("src/*/a.swift", "src/foo/") && Split.overlap("src/foo/", "src/*/a.swift")
           && !Split.overlap("a.txt", "a.txt2") && !Split.overlap("src/", "docs/") && !Split.overlap("src/*.swift", "docs/x.swift"), "owned paths overlap by file, folder and glob")
    expect(Split.refusal([part(1, ["a.txt"]), part(2, ["src/"])]) == nil && Split.refusal([part(1, ["src/"]), part(2, ["src/b.txt"])])?.contains("both own") == true
           && Split.refusal([part(1, ["a"]), part(2, ["b"]), part(3, ["c"])]) != nil && Split.refusal([part(1, ["../x"])]) != nil && Split.refusal([part(1, [])]) != nil,
           "a plan with overlapping files, three parts, paths leaving the repository or no files is refused")

    let claude = Account(id: "dl-claude", provider: .claude, name: "DC"), codex = Account(id: "dl-codex", provider: .codex, name: "DX")
    let model = AppModel()
    model.accounts = [claude, codex]
    let chat = Discussion(model: model)
    expect(DelegateLink.shared.host === chat, "the chats' host serves the sub-room tools")
    let lock = NSLock()
    // Each repository's fake AI: (account, prompt, context, token) → reply. Sub-rooms are found by their work tree.
    var scripts: [String: (Account, String, ToolContext, DebateCancellation) -> Result<String, Answerer.Failure>] = [:]
    var mains: [String: UUID] = [:]
    func room(for root: String) -> (main: UUID, room: UUID, sub: Bool)? {
        lock.lock(); let known = mains; lock.unlock()
        if let main = known[root] { return (main, main, false) }
        for (_, main) in known {
            for split in SplitStore.shared.splits(main) { if let p = split.parts.first(where: { $0.tree?.path == root }) { return (main, p.room, true) } }
        }
        return nil
    }
    var subScript: (Account, String, ToolContext, String, DebateCancellation) -> Result<String, Answerer.Failure> = { _, _, _, _, _ in .success("?") }
    chat.workspaceAnswer = { account, prompt, binding, token, _ in
        let root = binding.project?.root ?? ""
        guard let found = room(for: root) else { return .success("unknown room") }
        let context = ToolContext(room: found.room, roots: binding.roots, projectRun: binding.projectRunID, projectGeneration: binding.projectGeneration, asker: account)
        if found.sub { lock.lock(); let script = subScript; lock.unlock(); return script(account, prompt, context, root, token) }
        lock.lock(); let script = scripts[root]; lock.unlock()
        return script?(account, prompt, context, token) ?? .success("no script")
    }
    func mainRoom(_ project: ProjectBinding, fullAuto: Bool) -> UUID {
        let id = chat.addProjectChat(project, title: "main " + (project.root as NSString).lastPathComponent, open: false)
        chat.configure(room: id) { $0.mode = 0; $0.soloAccountID = claude.id }
        if !fullAuto { chat.change(id, save: true) { $0.workspace?.fullAuto = false } }
        lock.lock(); mains[project.root] = id; lock.unlock()
        return id
    }
    // A sub-room's usual work: change its own file, commit through the app's git_commit, report.
    func doPart(_ context: ToolContext, root: String) -> String {
        let n = root.hasSuffix("-1") ? 1 : 2
        write("part \(n)\n", n == 1 ? "a.txt" : "src/new.txt", in: root)
        let committed = GitLink.shared.call("git_commit", ["message": "Part \(n)", "paths": [n == 1 ? "a.txt" : "src/new.txt"]], context: context)
        return failed(committed) ? "commit failed: \(committed)" : text(DelegateLink.shared.call("sub_report", ["summary": "did part \(n)", "tests": "quick tests pass"], context: context))
    }
    let plan: [String: Any] = ["parts": [["goal": "Change a.txt", "owned": ["a.txt"], "forbidden": ["shared.txt"], "interfaces": "none", "done": "a.txt says part 1"],
                                         ["goal": "Add src/new.txt", "owned": ["src/"], "done": "src/new.txt exists"]], "why": "two independent files"]

    // 1) Full auto: split into two, both report, the main room merges both and pushes; the app removes the work trees.
    let auto = fixture("auto")
    let autoRoom = mainRoom(auto, fullAuto: true)
    var seen: [String: String] = [:], subTools: [[String]] = [], subGit: [[String]] = [], subPlan: [String] = []
    subScript = { _, _, context, root, _ in
        let mine = names(DelegateLink.shared.tools(context: context)), gitTools = names(GitLink.shared.tools(context: context))
        let again = DelegateLink.shared.call("delegate_plan", plan, context: context)
        lock.lock(); subTools.append(mine); subGit.append(gitTools); subPlan.append(failed(again) ? text(again) : "ALLOWED"); lock.unlock()
        return .success(doPart(context, root: root))
    }
    scripts[auto.root] = { _, _, context, _ in
        let tools = names(DelegateLink.shared.tools(context: context))
        let overlap = DelegateLink.shared.call("delegate_plan", ["parts": [["goal": "x", "owned": ["src/"], "done": "d"], ["goal": "y", "owned": ["src/b.txt"], "done": "d"]]], context: context)
        let opened = DelegateLink.shared.call("delegate_plan", plan, context: context)
        let twice = DelegateLink.shared.call("delegate_plan", plan, context: context)
        var result = ""
        for _ in 0..<6 { result = text(DelegateLink.shared.call("delegate_result", ["wait_seconds": 20], context: context)); if !result.contains("Still running") { break } }
        let m1 = text(DelegateLink.shared.call("git_merge_sub", ["n": 1], context: context)), m2 = text(DelegateLink.shared.call("git_merge_sub", ["n": 2], context: context))
        let pushed = text(GitLink.shared.call("git_push", [:], context: context))
        lock.lock()
        seen = ["tools": tools.joined(separator: ","), "overlap": failed(overlap) ? text(overlap) : "ALLOWED", "opened": text(opened), "twice": failed(twice) ? text(twice) : "ALLOWED",
                "result": result, "m1": m1, "m2": m2, "push": pushed]
        lock.unlock()
        return .success("merged")
    }
    expect(chat.startTurn(room: autoRoom, question: "split it", forced: .work) == nil, "the main room's turn starts")
    expect(spin(120) { !chat.anyRunning && chat.conversation(autoRoom).turns.last?.answeredAt != nil }, "the full auto flow ends within 120 s")
    lock.lock(); let a = seen, subsSaw = subTools, subsGit = subGit, subsPlan = subPlan; lock.unlock()
    expect(a["tools"] == "delegate_plan,delegate_status,delegate_result,delegate_message,delegate_cancel,delegate_resync,git_merge_sub", "the main room's tools: \(a["tools"] ?? "")")
    expect(a["overlap"]?.contains("both own") == true, "overlapping owned files are refused: \(a["overlap"] ?? "")")
    expect(a["opened"]?.contains("approved automatically") == true && a["twice"]?.contains("one split at a time") == true, "full auto approves at once; one split at a time: \(a)")
    expect(subsSaw.count == 2 && subsSaw.allSatisfy { $0 == ["sub_report", "sub_blocked"] }, "sub-rooms get only sub_report and sub_blocked: \(subsSaw)")
    expect(subsGit.allSatisfy { !$0.contains("git_push") && !$0.contains("git_pull") && !$0.contains("git_switch") && !$0.contains("git_publish_stable") && $0.contains("git_commit") },
           "sub-rooms have no push, pull, switch or publish: \(subsGit)")
    expect(subsPlan.count == 2 && subsPlan.allSatisfy { $0.contains("cannot split again") }, "a sub-room's delegate_plan is refused: \(subsPlan)")
    expect(a["result"]?.contains("[reported]") == true && a["result"]?.contains("did part 1") == true && a["result"]?.contains("quick tests pass") == true,
           "delegate_result brings the reports: \(a["result"] ?? "")")
    expect(a["m1"]?.contains("Merged sub-room 1") == true && a["m2"]?.contains("Merged sub-room 2") == true, "both merge: \(a["m1"] ?? "") / \(a["m2"] ?? "")")
    let autoSplit = SplitStore.shared.splits(autoRoom).first
    let log = git(["log", "--format=%s", "-5"], at: auto.root)
    expect(log.contains("Merge sub/\(autoSplit?.id ?? "?")/1") && log.contains("Merge sub/\(autoSplit?.id ?? "?")/2")
           && (try! String(contentsOfFile: auto.root + "/a.txt", encoding: .utf8)) == "part 1\n" && FileManager.default.fileExists(atPath: auto.root + "/src/new.txt"),
           "main has both parts as merge commits: \(log)")
    expect(git(["rev-parse", "HEAD"], at: auto.root) == git(["rev-parse", "refs/heads/main"], at: base.path + "/auto.git"), "pushed once at the turn's end")
    expect(autoSplit?.closed == true && autoSplit?.parts.allSatisfy { $0.removed && $0.state == .merged } == true && autoSplit?.auto == true
           && git(["worktree", "list", "--porcelain"], at: auto.root).components(separatedBy: "worktree ").count == 2
           && git(["for-each-ref", "refs/heads/sub/"], at: auto.root).isEmpty, "after the push the work trees and branches are gone, the split closed")
    let autoCard = chat.conversation(autoRoom).turns.first?.peerNotes?.first { $0.headline?.hasPrefix(L("하위 작업 나눔", "Work split")) == true }
    expect(autoCard?.headline?.contains(L("자동 승인됨", "approved automatically")) == true && autoCard?.text.contains("a.txt") == true, "the card records the automatic approval")
    let subRooms = chat.conversations.filter { $0.subOf?.room == autoRoom }
    expect(subRooms.count == 2 && subRooms.allSatisfy { $0.meetingOf?.room == autoRoom } && !chat.listedConversations.contains { $0.subOf != nil }
           && chat.conversation(autoRoom).turns.count == 1, "the sub-rooms hang under the main room like meetings; no join turn (the main room waited)")

    // 2) Not full auto: the split waits for the user's card; a refusal splits nothing. Approved, the main room's answer ends
    //    at once; when both sub-rooms ended the app gives it the join turn, once.
    let card = fixture("card")
    let cardRoom = mainRoom(card, fullAuto: false)
    subScript = { _, _, context, root, _ in .success(doPart(context, root: root)) }
    var refused = "", approved = "", joined = ""
    scripts[card.root] = { _, prompt, context, _ in
        if prompt.contains("[Sub-rooms ended]") {
            let merged = [1, 2].map { text(DelegateLink.shared.call("git_merge_sub", ["n": $0], context: context)) }
            _ = GitLink.shared.call("git_push", [:], context: context)
            lock.lock(); joined = merged.joined(separator: " | "); lock.unlock()
            return .success("joined")
        }
        let first = DelegateLink.shared.call("delegate_plan", plan, context: context)
        let second = DelegateLink.shared.call("delegate_plan", plan, context: context)
        lock.lock(); refused = text(first); approved = text(second); lock.unlock()
        return .success("split and left")
    }
    expect(chat.startTurn(room: cardRoom, question: "split it", forced: .work) == nil, "the second main room starts")
    var asked: [ProjectApproval] = []
    for allow in [false, true] {
        spin(30) { ProjectCenter.shared.requests.contains { $0.room == cardRoom } }
        guard let request = ProjectCenter.shared.requests.first(where: { $0.room == cardRoom }) else { break }
        asked.append(request)
        if !allow { expect(SplitStore.shared.splits(cardRoom).isEmpty, "nothing is recorded while the card waits") }
        ProjectCenter.shared.decide(request.id, allow: allow)
    }
    expect(asked.count == 2 && asked.allSatisfy { $0.title.contains("Split into sub-rooms") && $0.detail.contains("src/") }, "without full auto each split waits for a card")
    expect(spin(120) { !chat.anyRunning && chat.conversation(cardRoom).turns.count == 2 && chat.conversation(cardRoom).turns.last?.answeredAt != nil }, "the join turn ran within 120 s")
    lock.lock(); let r = refused, ok = approved, j = joined; lock.unlock()
    expect(r.contains("refused") && ok.contains("approved by the user"), "refused, then approved: \(r) / \(ok)")
    let cardTurns = chat.conversation(cardRoom).turns
    expect(cardTurns.count == 2 && cardTurns[1].question == L("하위 작업 결과가 도착했어요. 합쳐 주세요.", "The sub-rooms' results have arrived. Please merge them.")
           && j.contains("Merged sub-room 1") && j.contains("Merged sub-room 2"), "the join turn merged both: \(j)")
    let cardSplit = SplitStore.shared.splits(cardRoom).first
    expect(cardSplit?.joinAdded == true && cardSplit?.auto == false && cardSplit?.closed == true, "join turn marked, approved by the user, cleaned up after the push")
    cardRoomCheck: do {
        guard let subRoom = cardSplit?.parts.first?.room else { break cardRoomCheck }
        chat.splitTurnEnded(subRoom, stopped: false); chat.checkJoin(cardRoom)
        spin(1) { false }
        expect(chat.conversation(cardRoom).turns.count == 2 && !chat.anyRunning, "a second end or check adds no second join turn")
    }
    expect(chat.conversation(cardRoom).turns.first?.peerNotes?.contains { $0.headline == L("하위 작업 나눔 · ", "Work split · ") + L("승인됨", "approved") } == true,
           "the card says the user approved it")

    // 3) Stop goes down: the main room waits in delegate_result, its sub-rooms work; Stop stops them all, the work trees stay
    //    and no join turn comes. Continue runs them again (then the join turn), Discard removes what is left.
    let stop = fixture("stop")
    let stopRoom = mainRoom(stop, fullAuto: true)
    var slow = true, stopWaited = ""
    subScript = { _, _, context, root, token in
        lock.lock(); let wait = slow; lock.unlock()
        if wait {
            let end = Date().addingTimeInterval(60)
            while !token.isCancelled && Date() < end { Thread.sleep(forTimeInterval: 0.02) }
            return .failure(.failed("Cancelled"))
        }
        return .success(doPart(context, root: root))
    }
    scripts[stop.root] = { _, prompt, context, _ in
        if prompt.contains("[Sub-rooms ended]") { return .success("seen") }
        _ = DelegateLink.shared.call("delegate_plan", plan, context: context)
        let waited = text(DelegateLink.shared.call("delegate_result", ["wait_seconds": 60], context: context))
        lock.lock(); stopWaited = waited; lock.unlock()
        return .failure(.failed("Cancelled"))
    }
    expect(chat.startTurn(room: stopRoom, question: "split it", forced: .work) == nil, "the third main room starts")
    expect(spin(30) { SplitStore.shared.splits(stopRoom).first?.parts.allSatisfy { $0.live && $0.state == .running } == true }, "both sub-rooms answer")
    let stopSubs = SplitStore.shared.splits(stopRoom).first?.parts.map(\.room) ?? []
    expect(stopSubs.allSatisfy { chat.runningRooms.contains($0) } && chat.runningRooms.contains(stopRoom), "three chats answer: main and two sub-rooms")
    chat.open(stopRoom)
    chat.stopDebate()
    expect(spin(30) { !chat.anyRunning }, "Stop ends the main room and its sub-rooms")
    spin(0.5) { false }
    let stopped = SplitStore.shared.splits(stopRoom).first
    expect(stopped?.paused == true && stopped?.parts.allSatisfy { $0.state == .cancelled && !$0.live && $0.tree.map { FileManager.default.fileExists(atPath: $0.path) } == true } == true,
           "the sub-rooms stopped, their work trees stay")
    expect(chat.conversation(stopRoom).turns.count == 1 && chat.conversation(stopRoom).turns[0].peerNotes?.contains { $0.headline == L("하위방 멈춤 · 작업 폴더는 남김", "Sub-rooms stopped · work trees kept") } == true,
           "a card says so; no join turn after a stop")
    lock.lock(); slow = false; lock.unlock()
    chat.resumeSplit(stopRoom, stopped?.id ?? "")
    expect(spin(120) { !chat.anyRunning && chat.conversation(stopRoom).turns.count == 2 && chat.conversation(stopRoom).turns.last?.answeredAt != nil },
           "Continue runs the parts again; then the join turn")
    expect(SplitStore.shared.splits(stopRoom).first?.parts.allSatisfy { $0.state == .reported } == true, "both reported after Continue")
    let problems = chat.discardSplit(stopRoom, stopped?.id ?? "")
    let discarded = SplitStore.shared.splits(stopRoom).first
    expect(problems.isEmpty && discarded?.closed == true && discarded?.parts.allSatisfy { $0.removed && !FileManager.default.fileExists(atPath: $0.tree?.path ?? "/") } == true
           && git(["for-each-ref", "refs/heads/sub/"], at: stop.root).isEmpty, "Discard removes the work trees and branches: \(problems)")

    // Places: sub-rooms waiting for one keep it from other chats and TODOs.
    let saved = chat.runningRooms
    chat.subWaiting = [(UUID(), "waiting")]
    chat.runningRooms = saved.union((saved.count..<(Discussion.maxRunning - 1)).map { _ in UUID() })
    let other = chat.addProjectChat(stop, title: "other", open: false)
    expect(chat.startTurn(room: other, question: "x") != nil && chat.maxAnswering == Discussion.maxRunning - 1, "a place kept for a sub-room is not another chat's or a TODO's")
    chat.subWaiting = []; chat.runningRooms = saved

    // 4) A restart: no split goes on by itself; each leftover is a card on its main room, once.
    let moved = mainRoom(fixture("moved"), fullAuto: true)
    let left = fixture("left"), leftRoom = mainRoom(left, fullAuto: true)
    let half = fixture("half"), halfRoom = mainRoom(half, fullAuto: true)
    for id in [moved, leftRoom, halfRoom] { chat.change(id, save: true) { $0.turns = [ChatTurn(question: "earlier")] } }
    func tree(_ binding: ProjectBinding, _ split: String, _ n: Int) -> SubWork.Tree { try! SubWork.create(binding, split: split, n: n) }
    // "left": 1 was running (tree there), 2's folder is gone, 3's folder is there but Git forgot it; a day old.
    let t1 = tree(left, "lft", 1), t2 = tree(left, "lft", 2)
    try! FileManager.default.removeItem(atPath: t2.path)
    let t3 = tree(left, "lf3", 1)
    for entry in (try? FileManager.default.contentsOfDirectory(atPath: (left.common as NSString).appendingPathComponent("worktrees"))) ?? [] {
        let gitdir = (try? String(contentsOfFile: left.common + "/worktrees/" + entry + "/gitdir", encoding: .utf8)) ?? ""
        if gitdir.contains("lf3-1") { try! FileManager.default.removeItem(atPath: left.common + "/worktrees/" + entry) }
    }
    // "half": 1 merged into main and pushed but not cleaned; a merge left half done in main.
    let h1 = tree(half, "hlf", 1)
    write("half part\n", "a.txt", in: h1.path); _ = git(["add", "-A"], at: h1.path); _ = git(["commit", "-q", "-m", "Half part"], at: h1.path)
    let h1sha = git(["rev-parse", "HEAD"], at: h1.path)
    _ = try! SubWork.merge(half, h1, sha: h1sha, owned: ["a.txt"], reported: true)
    _ = git(["push", "-q", "origin", "main"], at: half.root)
    _ = git(["switch", "-q", "-c", "side"], at: half.root); write("side\n", "shared.txt", in: half.root); _ = git(["commit", "-qam", "side"], at: half.root)
    _ = git(["switch", "-q", "main"], at: half.root); write("main\n", "shared.txt", in: half.root); _ = git(["commit", "-qam", "main"], at: half.root)
    _ = try? ProjectProcess.git(["merge", "side"], root: half.root)
    func record(_ id: String, _ main: UUID, _ binding: ProjectBinding, _ parts: [Split.Part], created: Date = Date()) {
        var split = Split(id: id, room: main, repo: binding.root, common: binding.common, auto: true, parts: parts); split.created = created
        SplitStore.shared.update(main) { $0.append(split) }
    }
    func recorded(_ n: Int, _ t: SubWork.Tree?, _ state: Split.State, sha: String? = nil) -> Split.Part {
        var p = part(n, ["f\(n)"]); p.tree = t; p.state = state; p.live = state == .running; p.sha = sha; return p
    }
    record("lft", leftRoom, left, [recorded(1, t1, .running), recorded(2, t2, .ready)], created: Date().addingTimeInterval(-2 * 86_400))
    record("lf3", leftRoom, left, [recorded(1, t3, .reported)])
    record("hlf", halfRoom, half, [recorded(1, h1, .reported, sha: h1sha)])
    let gone = ProjectBinding(root: base.appendingPathComponent("nowhere").path, common: "/nowhere/.git", remote: "origin", remoteURL: "")
    record("lst", moved, gone, [recorded(1, nil, .running)])
    let found = chat.recoverSplits(known: [leftRoom, halfRoom, moved])
    let all = found.joined(separator: "\n")
    expect(all.contains(L("다시 시작해서 하위방 1이 멈췄어요", "restarted, so sub-room 1 stopped")) && all.contains(L("하위방 2의 작업 폴더가 사라졌어요", "Sub-room 2's work tree folder is gone"))
           && all.contains(L("Git이 작업 폴더로 알지 못해요", "Git does not list it as a work tree")) && all.contains(L("하루 넘게", "over a day")),
           "a stopped part, a folder gone, a folder Git forgot and a split over a day old: \(found)")
    expect(all.contains(L("끝나지 않은 merge", "merge left half done")) && all.contains(L("정리 전에 앱이 꺼졌어요", "quit before cleaning up")) && all.contains(L("저장소를 찾을 수 없어요", "repository was not found")),
           "a half-done merge, merged and pushed but not cleaned (cleaned now), a moved repository: \(found)")
    let afterLeft = SplitStore.shared.split(leftRoom, "lft"), afterHalf = SplitStore.shared.split(halfRoom, "hlf")
    expect(afterLeft?.parts[0].state == .cancelled && afterLeft?.paused == true && FileManager.default.fileExists(atPath: t1.path) && !chat.anyRunning,
           "the running part is stopped, not continued; its tree stays")
    expect(afterHalf?.closed == true && afterHalf?.parts[0].removed == true && !FileManager.default.fileExists(atPath: h1.path), "the pushed part was cleaned up")
    expect(chat.conversation(leftRoom).turns[0].peerNotes?.contains { $0.headline?.contains("lft") == true } == true
           && chat.conversation(moved).turns[0].peerNotes?.contains { $0.text.contains(L("저장소를 찾을 수 없어요", "repository was not found")) } == true, "the findings are cards on the main rooms")
    expect(chat.recoverSplits(known: [leftRoom, halfRoom, moved]).isEmpty, "a second start shows no card twice")
    _ = try? ProjectProcess.git(["merge", "--abort"], root: half.root)

    // A resync's conflict is resolved and committed with git_commit (a whole merge commit), then reported; a split whose
    // tree was never saved (the app quit right after making it) is still discarded with its folder and branch.
    let rs = fixture("resync"), rsRoom = mainRoom(rs, fullAuto: true)
    let r1 = tree(rs, "rsy", 1), r2 = tree(rs, "rsy", 2)
    write("one\nTWO by 1\n", "shared.txt", in: r1.path); _ = git(["commit", "-qam", "r1"], at: r1.path)
    write("one\ntwo by 2\n", "shared.txt", in: r2.path); _ = git(["commit", "-qam", "r2"], at: r2.path)
    _ = try! SubWork.merge(rs, r1, sha: git(["rev-parse", "HEAD"], at: r1.path), owned: ["shared.txt"], reported: true)
    expect(try! SubWork.resync(rs, r2) == ["shared.txt"], "the resync leaves a conflict")
    let subRun = ProjectRun(room: UUID(), binding: try! ProjectProcess.inspect(r2.path), token: DebateCancellation(), fullAuto: true)
    subRun.isSubRoom = true; ProjectWork.register(subRun); subRun.nextAttempt()
    let subContext = ToolContext(room: subRun.room, roots: [], projectRun: subRun.id, projectGeneration: subRun.generation)
    let early = GitLink.shared.call("git_commit", ["message": "Resolve", "paths": ["shared.txt"]], context: subContext)
    write("one\nTWO by 1 and 2\n", "shared.txt", in: r2.path)
    let resolved = GitLink.shared.call("git_commit", ["message": "Resolve", "paths": ["shared.txt"]], context: subContext)
    ProjectWork.finish(subRun)
    expect(failed(early) && text(early).contains("still have conflicts") && !failed(resolved) && (try? SubWork.report(r2)) != nil
           && git(["rev-list", "--parents", "-n", "1", "HEAD"], at: r2.path).split(separator: " ").count == 3,
           "conflict markers are refused, the resolved merge commits whole and can be reported: \(early) / \(resolved)")
    let lostTree = tree(rs, "nos", 1)
    record("nos", rsRoom, rs, [recorded(1, nil, .creating)])
    expect(chat.discardSplit(rsRoom, "nos").isEmpty && !FileManager.default.fileExists(atPath: lostTree.path)
           && git(["for-each-ref", "refs/heads/sub/nos/"], at: rs.root).isEmpty && SplitStore.shared.split(rsRoom, "nos")?.closed == true,
           "a work tree the record never got is discarded too")

    // project_run: one at a time per repository, across its work trees; the second waits in line.
    let queue = fixture("queue", commands: "{\"version\":1,\"commands\":{\"slow\":{\"executable\":\"/bin/sleep\",\"args\":[\"1\"]}}}")
    let qt = tree(queue, "que", 1)
    let runs = [ProjectRun(room: UUID(), binding: queue, token: DebateCancellation(), fullAuto: true),
                ProjectRun(room: UUID(), binding: try! ProjectProcess.inspect(qt.path), token: DebateCancellation(), fullAuto: true)]
    for run in runs { ProjectWork.register(run); run.nextAttempt() }
    let began = Date(), group = DispatchGroup()
    var exits: [String] = []
    for run in runs {
        group.enter()
        DispatchQueue.global().async {
            let reply = GitLink.shared.call("project_run", ["name": "slow"], context: ToolContext(room: run.room, roots: [], projectRun: run.id, projectGeneration: run.generation))
            lock.lock(); exits.append(text(reply)); lock.unlock(); group.leave()
        }
    }
    group.wait()
    let took = Date().timeIntervalSince(began)
    expect(exits.count == 2 && exits.allSatisfy { $0.hasPrefix("exit=0") } && took >= 1.9 && runs.contains { $0.log.contains { $0.contains("waiting for another command") || $0.contains("다른 명령이 끝나길") } },
           "the second project_run waited for the first: \(took) s, \(exits)")
    for run in runs { ProjectWork.finish(run) }

    for id in [autoRoom, cardRoom, stopRoom, leftRoom, halfRoom, moved, rsRoom] { try? FileManager.default.removeItem(at: SplitStore.folder.appendingPathComponent(id.uuidString + ".json")) }
    try? FileManager.default.removeItem(at: base)
    print("PASS: sub-rooms (split → report → merge → push → cleanup, full auto approves at once and the card waits otherwise, overlapping files and a sub-room's split refused, join turn once, Stop goes down and Continue/Discard, restart cards, project_run in line)")
}

// Sub-room screens (docs/SUBROOM_PLAN.md 1, 7; P3): "the same command" for an approval given for a split, a sub-room's
// requests gathered in its main room and allowed for the split, the sidebar's badge and fold, messages kept on the card.
func testSubRoomScreens() {
    func text(_ reply: [String: Any]) -> String { ((reply["content"] as? [[String: Any]])?.first?["text"] as? String) ?? "" }
    @discardableResult func spin(_ seconds: TimeInterval, until done: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline && !done() { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        return done()
    }
    let base = URL(fileURLWithPath: AccountStore.home).appendingPathComponent("subscreens-" + UUID().uuidString.prefix(8)).resolvingSymlinksInPath()
    let fm = FileManager.default
    try! fm.createDirectory(at: base.appendingPathComponent("tree/tools"), withIntermediateDirectories: true)
    let tree = base.appendingPathComponent("tree").path, other = base.appendingPathComponent("other").path
    try! fm.createDirectory(atPath: other, withIntermediateDirectories: true)
    let config = Data("{\"version\":1,\"commands\":{\"test\":{\"executable\":\"/bin/zsh\",\"args\":[\"tools/t.sh\"]}}}".utf8)
    try! "echo ok\n".write(toFile: tree + "/tools/t.sh", atomically: true, encoding: .utf8)
    try! fm.createSymbolicLink(atPath: base.appendingPathComponent("zsh-link").path, withDestinationPath: "/bin/zsh")
    func key(_ exe: String = "/bin/zsh", args: [String] = ["tools/t.sh"], tree root: String = tree, config data: Data = config, permission: String = "user") -> String {
        CommandIdentity.key(executable: exe, args: args, tree: root, config: data, permission: permission)
    }
    let first = key()
    expect(first == key() && first == key(base.appendingPathComponent("zsh-link").path), "the same command has the same key, also through a link to the executable")
    expect(first != key("/bin/sh") && first != key(args: ["tools/t.sh", "-v"]) && first != key(tree: other) && first != key(config: Data("{}".utf8))
           && first != key(permission: "guarded") && key(args: ["a", "b"]) != key(args: ["a b"]),
           "another executable, argument, work tree, config or permission is another command")
    try! "echo changed\n".write(toFile: tree + "/tools/t.sh", atomically: true, encoding: .utf8)
    expect(key() != first && key(args: [tree + "/tools/t.sh"]) != key(args: [tree + "/tools/t.sh", "x"]), "an edited script is another command (asked again)")
    // A script the approved one calls, elsewhere in the tree, and a file beside the named script count too; other sources do not.
    try! fm.createDirectory(atPath: tree + "/scripts", withIntermediateDirectories: true); try! fm.createDirectory(atPath: tree + "/src", withIntermediateDirectories: true)
    try! "echo inner\n".write(toFile: tree + "/scripts/inner.sh", atomically: true, encoding: .utf8)
    try! "let a = 1\n".write(toFile: tree + "/src/a.swift", atomically: true, encoding: .utf8)
    try! "data\n".write(toFile: tree + "/tools/data.txt", atomically: true, encoding: .utf8)
    let before = key()
    try! "echo inner changed\n".write(toFile: tree + "/scripts/inner.sh", atomically: true, encoding: .utf8)
    let calledChanged = key()
    try! "data changed\n".write(toFile: tree + "/tools/data.txt", atomically: true, encoding: .utf8)
    let besideChanged = key()
    try! "let a = 2\n".write(toFile: tree + "/src/a.swift", atomically: true, encoding: .utf8)
    expect(before != calledChanged && calledChanged != besideChanged && besideChanged == key(), "a called script or a file beside the named one changed: asked again; an edited source is not")
    expect(CommandIdentity.key(executable: "/bin/zsh", args: [], tree: tree, config: config, permission: "user", mostFiles: 1)
           != CommandIdentity.key(executable: "/bin/zsh", args: [], tree: tree, config: config, permission: "user", mostFiles: 1), "a tree too large to read is never the same")

    // A sub-room's project_run in a chat without full auto: its card is gathered in the main room; "allow during this
    // split" lets the same command through without a card, an edited script asks again.
    let repo = base.appendingPathComponent("repo").path
    func git(_ args: [String]) { _ = try! ProjectProcess.git(args, root: repo) }
    try! fm.createDirectory(atPath: repo + "/tools", withIntermediateDirectories: true)
    _ = try! ProjectProcess.git(["init", "-q", "-b", "main", repo], root: base.path)
    git(["config", "user.name", "Fixture"]); git(["config", "user.email", "fixture@example.invalid"])
    try! "{\"version\":1,\"commands\":{\"quick\":{\"executable\":\"/bin/zsh\",\"args\":[\"tools/q.sh\"]}}}".write(toFile: repo + "/.ai-illuminati.json", atomically: true, encoding: .utf8)
    try! "echo quick\n".write(toFile: repo + "/tools/q.sh", atomically: true, encoding: .utf8)
    git(["add", "-A"]); git(["commit", "-q", "-m", "Initial"])
    _ = try! ProjectProcess.git(["init", "-q", "--bare", repo + ".git"], root: base.path); git(["remote", "add", "origin", repo + ".git"])
    let binding = try! ProjectProcess.inspect(repo)
    let chat = Discussion(model: AppModel())
    var main = Conversation(); main.title = "main"; main.turns = [ChatTurn(question: "split it")]
    let link = SubRoomLink(room: main.id, split: "scr", n: 1)
    var sub = Conversation(); sub.title = "sub 1"; sub.subOf = link; sub.meetingOf = MeetingLink(room: main.id, turn: main.turns[0].id)
    chat.conversations = [main, sub]
    var part = Split.Part(n: 1, room: sub.id, goal: "Sidebar rows", owned: ["app/x.swift"], forbidden: [], interfaces: "", done: "tests pass")
    part.state = .running; part.live = true; part.started = Date().addingTimeInterval(-12 * 60)
    part.tree = SubWork.Tree(path: repo, branch: "sub/scr/1", base: "")
    var two = Split.Part(n: 2, room: UUID(), goal: "Cards", owned: ["app/y.swift"], forbidden: [], interfaces: "", done: "tests pass")
    two.state = .reported; two.sha = "abc1234def"
    SplitStore.shared.update(main.id) { $0 = [Split(id: "scr", room: main.id, repo: repo, common: binding.common, auto: false, parts: [part, two])] }
    spin(2) { chat.splitRecords[main.id]?.first?.parts.count == 2 }
    expect(chat.splitBadge(main.id, requests: []) == .working(1), "a split with one sub-room answering shows \"1 working\": \(String(describing: chat.splitBadge(main.id, requests: [])))")
    expect(chat.childrenShown(main.id) && chat.subRooms(of: main.id).map(\.id) == [sub.id], "an open split's sub-rooms show under the main room")
    chat.toggleChildren(main.id)
    expect(!chat.childrenShown(main.id), "the user folds them"); chat.toggleChildren(main.id)

    let run = ProjectRun(room: sub.id, binding: binding, token: DebateCancellation())
    run.isSubRoom = true
    ProjectWork.register(run); run.nextAttempt(); DelegateLink.shared.register(run, link)
    func runQuick() -> (wait: () -> String, done: () -> Bool) {
        var reply: String?
        let lock = NSLock()
        DispatchQueue.global().async {
            let r = text(GitLink.shared.call("project_run", ["name": "quick"], context: ToolContext(room: run.room, roots: [], projectRun: run.id, projectGeneration: run.generation)))
            lock.lock(); reply = r; lock.unlock()
        }
        func current() -> String? { lock.lock(); defer { lock.unlock() }; return reply }
        return ({ spin(20) { current() != nil }; return current() ?? "" }, { current() != nil })
    }
    func asked() -> ProjectApproval? { ProjectCenter.shared.requests.first { $0.room == sub.id } }
    let once = runQuick()
    spin(10) { asked() != nil }
    let card = asked()
    expect(card?.command == "quick: /bin/zsh tools/q.sh" && card?.same != nil && chat.gatheredApprovals(main.id, ProjectCenter.shared.requests).map(\.id) == card.map { [$0.id] }
           && chat.splitBadge(main.id, requests: ProjectCenter.shared.requests) == .waiting && chat.approvalHome(sub.id) == main.id,
           "a sub-room's command request is gathered in its main room with its command and key")
    if let card { chat.allowForSplit(card) }
    expect(once.wait().hasPrefix("exit=0") && SplitStore.shared.split(main.id, "scr")?.allowed == card?.same.map { [$0] }, "allowed for the split: it runs and the key is kept")
    let again = runQuick()
    expect(again.wait().hasPrefix("exit=0") && asked() == nil, "the same command again runs without a card")
    try! "echo edited\n".write(toFile: repo + "/tools/q.sh", atomically: true, encoding: .utf8)
    let edited = runQuick()
    expect(spin(10) { asked() != nil } && !edited.done(), "an edited script asks again")
    if let card = asked() { ProjectCenter.shared.decide(card.id, allow: false) }
    expect(edited.wait().contains("refused"), "refused on its card")
    DelegateLink.shared.unregister(run); ProjectWork.finish(run)
    expect(!DelegateLink.shared.preapproved(ProjectApproval(room: sub.id, run: UUID(), title: "", detail: "")), "a request without a key is never allowed ahead")

    // A message from the card is kept as "→ sent"; the badge says done once every part reported.
    chat.runningRooms.insert(sub.id)
    expect(chat.messageSub(link, "Use the name SubRoomRow", from: "[From the user] ") != nil
           && SplitStore.shared.split(main.id, "scr")?.parts.first?.sent == ["Use the name SubRoomRow"], "a message to a sub-room is kept on the card")
    chat.runningRooms.remove(sub.id)
    SplitStore.shared.changePart(link) { $0.state = .reported; $0.live = false; $0.finished = Date() }
    spin(2) { chat.splitRecords[main.id]?.first?.parts.first?.state == .reported }
    expect(chat.splitBadge(main.id, requests: []) == .done && chat.splitRecords[main.id]?.first?.parts.allSatisfy(\.mergeable) == true, "every part reported: done, ready to merge 2/2")
    SplitStore.shared.change(main.id, "scr") { $0.closed = true }
    spin(2) { chat.openSplits(main.id).isEmpty }
    expect(chat.childrenShown(main.id), "unfolded by the user, they stay")
    chat.childrenOpen.remove(main.id)
    expect(!chat.childrenShown(main.id), "an ended split folds into the chat row's chip")

    try? fm.removeItem(at: SplitStore.folder.appendingPathComponent(main.id.uuidString + ".json"))
    try? fm.removeItem(at: base)
    print("PASS: sub-room screens (same command key, gathered approvals allowed for the split, badge, fold, messages)")
}
