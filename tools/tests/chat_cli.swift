import Foundation
import AIAccounts
import AILocalization
@testable import AIRuntime
@testable import AIWorkspace
import AIProjects
@testable import AIChat

/// C1: the chat (AIChat) through the app with a fake CLI in place of claude and codex (Answerer.toolForTests), no
/// answer hooks: each AI's answer is a real process started by Answerer with the app's run conditions (ChatApp.run).
/// ask_ai goes from the answering CLI through the app's tool socket (ToolHub → PeerLink) to the other AI's CLI; a meeting
/// runs in its hidden chat and comes back as the answer; a work answer is reviewed by the other member and fixed once.
func testChatThroughCLI() {
    let fm = FileManager.default
    let fake = URL(fileURLWithPath: AccountStore.home).appendingPathComponent("chat-cli")
    try? fm.removeItem(at: fake)
    try! fm.createDirectory(at: fake.appendingPathComponent("calls"), withIntermediateDirectories: true)
    // The fake answers by the first rule whose text is in the prompt (rules.json); a rule may call ask_ai through the
    // tool session the app gave this answer (its manifest, from --mcp-config) or commit a change. Each call is logged.
    try! #"""
    import sys, json, os, socket, subprocess, time
    D = sys.argv[1]; args = sys.argv[2:]
    prompt = sys.stdin.read()
    who = 'codex' if 'exec' in args else 'claude'
    reply, ask, commit = 'TL;DR: ok\nok', None, None
    for r in json.load(open(D + '/rules.json')):
        if r.get('who', who) == who and r['if'] in prompt:
            reply, ask, commit = r['then'], r.get('ask'), r.get('commit'); break
    asked = None
    if ask:
        config = json.loads(args[args.index('--mcp-config') + 1])
        manifest = json.load(open(config['mcpServers']['illuminati']['args'][1]))
        here = os.getcwd(); os.chdir(os.path.dirname(manifest['tools']))   # a short path: AF_UNIX takes about 100 bytes
        s = socket.socket(socket.AF_UNIX); s.connect(os.path.basename(manifest['tools'])); os.chdir(here)
        s.sendall((json.dumps({'session': manifest['toolSession'], 'op': 'call', 'name': 'ask_ai', 'arguments': ask}) + '\n').encode())
        data = b''
        while not data.endswith(b'\n'):
            chunk = s.recv(65536)
            if not chunk: break
            data += chunk
        asked = json.loads(data)['content'][0]['text']
        reply += '\n' + asked
    if commit:
        open(commit['file'], 'w').write(commit['text'])
        subprocess.run(['/usr/bin/git', '-C', commit['root'], 'commit', '-qam', commit['message']], check=True)
    sid = args[args.index('--session-id') + 1] if '--session-id' in args else args[args.index('--resume') + 1] if '--resume' in args else ''
    json.dump({'who': who, 'prompt': prompt, 'args': args, 'asked': asked}, open('%s/calls/%f-%d.json' % (D, time.time(), os.getpid()), 'w'))
    if who == 'codex': open(args[args.index('-o') + 1], 'w').write(reply)
    elif '--output-format' in args: print(json.dumps({'type': 'result', 'session_id': sid, 'is_error': False, 'result': reply}))
    else: print(reply)
    """#.write(to: fake.appendingPathComponent("fake.py"), atomically: true, encoding: .utf8)
    let script = fake.appendingPathComponent("cli")
    try! "#!/bin/sh\nexec /usr/bin/python3 -I '\(fake.path)/fake.py' '\(fake.path)' \"$@\"\n".write(to: script, atomically: true, encoding: .utf8)
    try! fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
    let marker = ProcessInfo.processInfo.environment["AI_ILLUMINATI_PROJECT_PROCESS"]
    unsetenv("AI_ILLUMINATI_PROJECT_PROCESS")
    Answerer.toolForTests = script.path
    defer {
        Answerer.toolForTests = nil
        if let marker { setenv("AI_ILLUMINATI_PROJECT_PROCESS", marker, 1) }
    }
    struct Call { var who: String; var prompt: String; var args: [String]; var asked: String? }
    func rules(_ list: [[String: Any]]) {
        try! JSONSerialization.data(withJSONObject: list).write(to: fake.appendingPathComponent("rules.json"))
        for file in (try? fm.contentsOfDirectory(atPath: fake.appendingPathComponent("calls").path)) ?? [] {
            try? fm.removeItem(at: fake.appendingPathComponent("calls").appendingPathComponent(file))
        }
    }
    func calls() -> [Call] {
        let dir = fake.appendingPathComponent("calls")
        return ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).sorted().compactMap { name in
            guard let data = try? Data(contentsOf: dir.appendingPathComponent(name)),
                  let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            return Call(who: o["who"] as? String ?? "", prompt: o["prompt"] as? String ?? "", args: o["args"] as? [String] ?? [], asked: o["asked"] as? String)
        }
    }
    let claude = Account(id: "cli-claude", provider: .claude, name: "Claude", dir: AccountStore.accountsDir + "/cli-claude")
    let codex = Account(id: "cli-codex", provider: .codex, name: "ChatGPT", dir: AccountStore.accountsDir + "/cli-codex")
    let model = AppModel()
    model.accounts = [claude, codex]
    model.sharedFolders = []
    func send(_ chat: Discussion, _ text: String) {
        chat.draft = text; chat.send()
        let deadline = Date().addingTimeInterval(90)
        while Date() < deadline && (chat.anyRunning || (chat.current.turns.last?.final == nil && chat.current.turns.last?.error == nil)) {
            RunLoop.main.run(until: Date().addingTimeInterval(0.03))
        }
    }

    // ask_ai: Claude answers a plain chat and asks from its own CLI; the app's tool socket routes it to the other kind (Codex),
    // which is asked read only and cannot ask on; the reply goes back into Claude's answer and shows as a card.
    let plain = Discussion(model: model)
    plain.configure { $0.mode = 0; $0.soloAccountID = claude.id }
    rules([["who": "codex", "if": "[SECOND OPINION]", "then": "Yes, 2+2 is 4."],
           ["who": "claude", "if": "Is 2+2 4", "then": "TL;DR: checked\nI asked.", "ask": ["message": "Is 2+2 4?", "purpose": "fact_check"]]])
    send(plain, "Is 2+2 4? Check with another AI.")
    let asked = plain.current.turns.last, askCalls = calls()
    let second = askCalls.first { $0.who == "codex" }
    expect(askCalls.map(\.who).sorted() == ["claude", "codex"] && askCalls.first { $0.who == "claude" }?.asked?.contains("Yes, 2+2 is 4.") == true,
           "ask_ai: Claude's CLI asks through the app's tool socket and gets Codex's reply: \(askCalls.map { ($0.who, $0.asked ?? "") }) \(asked?.final ?? asked?.error ?? "no answer")")
    expect(second?.prompt.hasPrefix("[SECOND OPINION]") == true && second?.prompt.contains("Is 2+2 4?") == true
           && second?.args.contains { $0.contains("sandbox_mode=\"read-only\"") } == true && second?.prompt.contains("cannot ask other AIs") == true,
           "ask_ai: Codex is asked the question read only and told it cannot ask on")
    expect(asked?.final?.contains("I asked.") == true && asked?.final?.contains("Yes, 2+2 is 4.") == true && asked?.finalBy == plain.label(claude)
           && asked?.peerNotes?.first?.text.contains("Yes, 2+2 is 4.") == true && asked?.peerNotes?.first?.speaker == plain.label(codex),
           "ask_ai: the answer carries the reply, and the reply shows under it as Codex's card: \(asked?.final ?? "") by \(asked?.finalBy ?? "") notes \(asked?.peerNotes?.map { ($0.speaker, $0.accountID ?? "", $0.text) } ?? [])")

    // A meeting: both members meet in a hidden chat (their own CLI calls), the result comes back as the answer.
    let meet = Discussion(model: model)
    meet.configure { $0.mode = 0 }
    meet.toggleMember(claude.id); meet.toggleMember(codex.id)
    rules([["if": "[MEETING RESULT]", "then": "결론: 그대로 두자.\n이견: 없음."],
           ["if": "[MODE3 MODERATION]", "then": #"{"action":"finish","reason":"enough","board":"Agreed: keep"}"#],
           ["if": "[MODE3 SPEECH]", "then": "TL;DR: keep it\n\nKeep it as it is."]])
    meet.pickedRoute = .meeting
    send(meet, "README를 나눌까?")
    let met = meet.current.turns.last, meetCalls = calls()
    let hidden = meet.conversations.first { $0.id == met?.meetingRoom }
    expect(met?.routeChoice == .meeting && met?.final?.contains("결론: 그대로 두자.") == true && met?.entries.isEmpty == true
           && hidden?.meetingOf?.turn == met?.id && !meet.listedConversations.contains { $0.id == hidden?.id },
           "meeting: the result is the answer, the speeches stay in the hidden chat: \(met?.final ?? met?.error ?? "nothing")")
    expect(Set(meetCalls.map(\.who)) == ["claude", "codex"] && meetCalls.contains { $0.prompt.contains("[MEETING RESULT]") }
           && meetCalls.contains { $0.prompt.contains(Discussion.meetingSource) },
           "meeting: both members speak through their CLIs, knowing the chat, and one writes the result")
    expect(hidden?.turns.first?.entries.filter { !$0.failed }.isEmpty == false, "meeting: the speeches are kept in the hidden chat")

    // The review: Claude works in a project and commits, Codex reviews exactly that change read only, Claude fixes once.
    let root = URL(fileURLWithPath: AccountStore.home).appendingPathComponent("chat-cli-project")
    try? fm.removeItem(at: root)
    try! fm.createDirectory(at: root, withIntermediateDirectories: true)
    func git(_ args: [String]) -> String { try! ProjectProcess.git(args, root: root.path) }
    _ = git(["init", "-b", "main"]); _ = git(["config", "user.name", "Fixture"]); _ = git(["config", "user.email", "fixture@example.invalid"])
    _ = git(["remote", "add", "origin", root.path + "/unused-origin"])
    try! "One\n".write(to: root.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
    _ = git(["add", "README.md"]); _ = git(["commit", "-m", "Initial"])
    let work = Discussion(model: model)
    work.configure { $0.mode = 0; $0.leadID = claude.id }
    work.toggleMember(claude.id); work.toggleMember(codex.id)
    work.change(work.currentID) { $0.workspace = WorkspaceBinding(roots: [WorkspaceRoot(path: root.path, directory: true)], project: try! ProjectProcess.inspect(root.path)) }
    let readme = root.appendingPathComponent("README.md").path
    rules([["who": "codex", "if": "[REVIEW]", "then": "1. README.md:1 says Second; the user asked for Third."],
           ["who": "claude", "if": "[Review of the changes you just made", "then": "Took point 1: README now says Third.\nReview: taken 1, left 0",
            "commit": ["file": readme, "text": "Third\n", "root": root.path, "message": "Third"]],
           ["who": "claude", "if": "Change README to Third.", "then": "Done.",
            "commit": ["file": readme, "text": "Second\n", "root": root.path, "message": "Second"]]])
    work.pickedRoute = .work
    send(work, "Change README to Third.")
    let fixed = work.current.turns.last, workCalls = calls()
    let review = workCalls.first { $0.who == "codex" && $0.prompt.hasPrefix("[REVIEW]") }
    expect(fixed?.route == .work && git(["log", "-1", "--format=%s"]) == "Third"
           && fixed?.final?.contains("Done.") == true && fixed?.final?.contains("README now says Third") == true,
           "review: the work, its review and the fix in one turn: \(fixed?.final ?? fixed?.error ?? "nothing")")
    expect(review?.prompt.contains("+Second") == true && review?.prompt.contains("Change README to Third.") == true
           && review?.args.contains { $0.contains("sandbox_mode=\"read-only\"") } == true && workCalls.filter { $0.prompt.hasPrefix("[REVIEW]") }.count == 1,
           "review: Codex reads only this answer's change, read only, once")
    expect(fixed?.peerNotes?.first?.headline?.contains(L("지적 1개 → 반영 1개 / 안 반영 0개", "1 point → 1 taken / 0 left")) == true
           && fixed?.plan?.map(\.status) == [.done, .done], "review: the card counts what was taken, the review and fix steps end done")
    print("PASS: the chat through a fake CLI (ask_ai from the CLI through the tool socket to the other AI, a meeting in its hidden chat, a reviewed work answer fixed once)")
}
