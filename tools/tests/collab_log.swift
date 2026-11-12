import Foundation
import AIAccounts
import AILocalization
@testable import AIRuntime
import AIWorkspace
@testable import AIChat

// The collaboration setting (off / show and go / on its own) and the collaboration log (CollabLog.swift).
func testCollabLog() {
    func text(_ reply: [String: Any]) -> String { ((reply["content"] as? [[String: Any]])?.first?["text"] as? String) ?? "" }
    func names(_ tools: [[String: Any]]) -> [String] { tools.compactMap { $0["name"] as? String } }
    let claude = Account(id: "collab-claude", provider: .claude, name: "C"), codex = Account(id: "collab-codex", provider: .codex, name: "G")
    expect(AppModel(persist: false).collaboration == .notify, "collaboration: show and go by default")
    expect(CollabMode.allCases.map(\.title) == [L("끔", "Off"), L("알리고 진행", "Show and go"), L("알아서", "On its own")], "three choices, in both languages")

    // Small talk is only greetings and thanks; a short request is not.
    expect(["안녕", "안녕하세요!", "고마워요 ㅎㅎ", "thanks!", "ok", "Hi"].allSatisfy(CollabLog.smallTalk)
           && !["이거 고쳐", "fix this", "2+2는?", "안녕하세요, 이 논문 요약해 주세요"].contains(where: CollabLog.smallTalk), "small talk: greetings and thanks only")
    expect(["다른 AI한테도 물어봐", "회의해 줘", "Can you ask another AI?", "hold a meeting on this"].allSatisfy(CollabLog.asksOthers)
           && !CollabLog.asksOthers("회의록 정리해 줘") && !CollabLog.asksOthers("이 코드 고쳐"), "the user asking for other AIs or a meeting")

    // <ai-taken>: what the asking AI took from each call, never shown.
    let tagged = Peer.taken("Answer.\n<ai-taken>1=yes, 2 = partly, 3:no</ai-taken>\n")
    expect(tagged.text == "Answer." && tagged.calls == [1: "yes", 2: "partly", 3: "no"], "the tag is read per call and taken out")
    expect(Peer.taken("Answer.\n<ai-tak").text == "Answer." && Peer.taken("Answer.\n<ai-taken>1=y").text == "Answer.", "a tag still arriving is not shown")
    expect(Peer.taken("a < b").text == "a < b" && Peer.taken("No tag.").calls.isEmpty, "other text stays")
    expect(Discussion.extractState("Reply.\n<ai-taken>1=yes</ai-taken>\n<chat-state>s</chat-state>").reply == "Reply."
           && Discussion.extractState("Reply.\n<chat-state>s</chat-state>\n<ai-taken>1=yes</ai-taken>").state == "s", "hidden before or after the chat state")

    // The log: lines in the app's data folder (a throwaway home in tests), several writers at once, trimmed by size.
    let chatID = UUID()
    DispatchQueue.concurrentPerform(iterations: 40) { n in
        CollabLog.add(CollabEvent(kind: .ask, chat: chatID, from: claude.id, to: [codex.id], purpose: "opinion", call: n))
    }
    expect(CollabLog.events().filter { $0.chat == chatID }.count == 40, "40 writers at once: 40 whole lines")
    expect(CollabLog.file.path.hasPrefix(AccountStore.supportDir) && !CollabLog.file.path.hasPrefix(NSHomeDirectory() + "/Library/Application Support/AI Illuminati"),
           "the log lives in the (test) app data folder")
    let size = CollabLog.maxBytes
    CollabLog.maxBytes = 2000
    for n in 0..<40 { CollabLog.add(CollabEvent(kind: .ask, chat: chatID, call: 100 + n)) }
    CollabLog.maxBytes = size
    let trimmed = CollabLog.events().filter { $0.chat == chatID }
    expect(trimmed.count < 40 && trimmed.last?.call == 139, "past the size limit the older half goes, the newest stays")
    let summary = CollabLog.summary([
        CollabEvent(kind: .ask, chat: chatID, failed: 1, smallTalk: true), CollabEvent(kind: .ask, chat: chatID), CollabEvent(kind: .meeting, chat: chatID),
        CollabEvent(kind: .outcome, chat: chatID, outcome: "yes"), CollabEvent(kind: .outcome, chat: chatID, outcome: "unknown"),
        CollabEvent(kind: .review, chat: chatID, failed: 0, points: 3), CollabEvent(kind: .review, chat: chatID, failed: 0, points: 0), CollabEvent(kind: .review, chat: chatID, points: 2, taken: 1, left: 1),
        CollabEvent(kind: .reviewed, chat: chatID, points: 3, taken: 2, left: 1), CollabEvent(kind: .request, chat: chatID, priorCalls: 0)])
    expect(summary == CollabLog.Summary(asks: 2, meetings: 1, failedAsks: 1, smallTalk: 1, yes: 1, partly: 0, no: 0, unknown: 1, reviews: 3, points: 5, taken: 3, left: 2,
                                        requests: 1, requestsAfterNone: 1), "the summary counts calls, outcomes, review points (also older review lines), small talk and the user's requests")
    expect(CollabLog.line(CollabLog.Summary()) == L("아직 기록이 없어요.", "Nothing recorded yet."), "empty log line")

    // The tool by mode: off keeps only ask_peer (two calls, to the reviewer); otherwise ask_ai with call numbers.
    let room = UUID(), turn = UUID(), member = ToolContext(room: room, roots: [], asker: claude, turn: turn)
    var asked = 0
    let legacy = PeerLink.Session(room: room, turn: turn, review: true) { _, _ in asked += 1; return "view" }
    legacy.mode = .off
    PeerLink.shared.open(legacy)
    expect(names(PeerLink.shared.tools(context: member)) == ["ask_peer"] && ConveneLink.shared.tools(context: member).isEmpty, "off: only ask_peer, no meetings")
    expect(PeerLink.shared.call("ask_ai", ["message": "x"], context: member)["isError"] as? Bool == true && asked == 0, "off: ask_ai is refused")
    expect(text(PeerLink.shared.call("ask_peer", ["message": "plan"], context: member)) == "view", "off: ask_peer works as before")
    _ = PeerLink.shared.call("ask_peer", ["message": "again"], context: member)
    expect(text(PeerLink.shared.call("ask_peer", ["message": "third"], context: member)).contains("already asked") && asked == Peer.legacyAsks, "off: two calls per answer")
    PeerLink.shared.close(legacy)
    let fresh = PeerLink.Session(room: room, turn: turn) { _, _ in "view" }
    PeerLink.shared.open(fresh)
    expect(names(PeerLink.shared.tools(context: member)) == ["ask_ai"] && PeerLink.shared.call("ask_peer", ["message": "x"], context: member)["isError"] as? Bool == true,
           "on: ask_ai, not ask_peer")
    expect(text(PeerLink.shared.call("ask_ai", ["message": "x"], context: member)) == "[ask_ai call 1]\nview"
           && text(PeerLink.shared.call("ask_ai", ["message": "y"], context: member)).hasPrefix("[ask_ai call 2]"), "each result starts with its call number")
    expect(PeerLink.shared.unreported(fresh, asker: claude.id) == 1...2 && PeerLink.shared.unreported(fresh, asker: claude.id) == nil, "each call's outcome is logged once")
    PeerLink.shared.close(fresh)
    expect(Peer.rule(peers: ["G"]).contains("<ai-taken>") && !Peer.legacyRule(peer: "G").contains("ask_ai") && Peer.legacyRule(peer: "G").contains("ask_peer"),
           "the rule asks for the tag; the old rule names only ask_peer")

    // Off: ask_peer asks only this work's reviewer; a reviewer that cannot answer means nobody, not another AI.
    let claude2 = Account(id: "collab-claude-2", provider: .claude, name: "C2")
    let offModel = AppModel(persist: false)
    offModel.accounts = [claude, codex, claude2]; offModel.collaboration = .off
    let offChat = Discussion(model: offModel)
    offChat.configure { $0.mode = 0 }
    var offAsked: [String] = []
    offChat.workspaceAnswer = { account, _, _, _, _ in offAsked.append(account.id); return .success("ok") }
    var work = WorkspaceBinding(roots: [])
    work.project = ProjectBinding(root: "/tmp/collab-none", common: "", remote: "", remoteURL: "")
    expect(offChat.beginPeer(id: offChat.currentID, index: 0, question: "q", binding: work, cancellation: DebateCancellation()) == nil, "off without reviewers: no session")
    let offSession = offChat.beginPeer(id: offChat.currentID, index: 0, question: "q", reviewers: [codex.id], binding: work, cancellation: DebateCancellation())
    let offContext = ToolContext(room: offChat.currentID, roots: [], asker: claude, turn: offSession?.turn)
    // Tools run on the tool server's thread in the app; the answers check the chat on the main thread, so it must stay free.
    func call(_ tool: String, _ message: String, _ context: ToolContext) -> String {
        var reply: String?
        DispatchQueue.global().async { let r = text(PeerLink.shared.call(tool, ["message": message], context: context)); DispatchQueue.main.async { reply = r } }
        let deadline = Date().addingTimeInterval(10)
        while reply == nil && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        expect(reply != nil, "\(tool) answered in time")
        return reply ?? ""
    }
    _ = call("ask_peer", "plan", offContext)
    expect(offAsked == [codex.id], "off: ask_peer asks the reviewer")
    var signedOut = AIUsage(name: "u"); signedOut.needsLogin = true
    offModel.latestUsage[codex.id] = signedOut
    let none = call("ask_peer", "again", offContext)
    expect(none.contains("No other AI") && offAsked == [codex.id], "off: the reviewer signed out, nobody else is asked")
    offChat.endPeer(offSession)
    // An answer that ends without saying what it took (failed or stopped): its calls are logged as unknown.
    offModel.collaboration = .notify; offModel.latestUsage = [:]
    let open = offChat.beginPeer(id: offChat.currentID, index: 0, question: "q", binding: WorkspaceBinding(roots: []), cancellation: DebateCancellation())
    _ = call("ask_ai", "x", ToolContext(room: offChat.currentID, roots: [], asker: claude, turn: open?.turn))
    offChat.endPeer(open)
    let ended = CollabLog.events().filter { $0.chat == offChat.currentID }
    expect(ended.filter { $0.kind == .outcome }.map(\.outcome) == ["unknown"] && ended.first { $0.kind == .outcome }?.from == claude.id
           && ended.first { $0.kind == .ask && $0.purpose == "ask_peer" }?.to == [codex.id], "unreported calls end as unknown; ask_peer is logged")

    // Through a real send.
    func run(_ mode: CollabMode, _ message: String, ask: Bool) -> (chat: Discussion, tools: [String], instruction: String) {
        let model = AppModel(persist: false)
        model.accounts = [claude, codex]
        model.collaboration = mode
        let chat = Discussion(model: model)
        chat.configure { $0.mode = 0 }
        var tools: [String] = [], instruction = ""
        let lock = NSLock()
        chat.workspaceAnswer = { account, prompt, binding, _, _ in
            if prompt.hasPrefix("[SECOND OPINION]") { return .success("Looks right.") }
            let context = ToolContext(room: chat.currentID, roots: binding.roots, asker: account, origin: binding.origin ?? .member)
            lock.lock(); instruction = prompt; tools = names(ToolHub.shared.handle(["session": ToolHub.shared.register(room: chat.currentID, roots: [], asker: account), "op": "tools"])["tools"] as? [[String: Any]] ?? []); lock.unlock()
            guard ask else { return .success("Hello.") }
            let reply = PeerLink.shared.call("ask_ai", ["message": "SECRET-QUESTION-TEXT", "purpose": "fact_check"], context: context)
            return .success("Checked: " + text(reply) + "\n<ai-taken>1=partly</ai-taken>")
        }
        chat.draft = message; chat.send()
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline && (chat.anyRunning || chat.current.turns.last?.final == nil) { RunLoop.main.run(until: Date().addingTimeInterval(0.03)) }
        let closing = Date().addingTimeInterval(5)
        while Date() < closing && PeerLink.shared.session(chat.currentID) != nil { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        return (chat, tools, instruction)
    }
    let off = run(.off, "이거 맞아?", ask: true)
    expect(!off.tools.contains("ask_ai") && !off.tools.contains("convene_meeting") && !off.tools.contains("ask_peer") && !off.instruction.contains("[Asking other AIs]"),
           "off, a plain chat: no collaboration tools and no rule")
    expect(off.chat.current.turns.last?.peerNotes == nil, "off: nothing was asked")
    let auto = run(.auto, "이 숫자 맞아?", ask: true)
    let last = auto.chat.current.turns.last
    expect(auto.tools.contains("ask_ai") && auto.tools.contains("convene_meeting"), "on its own: the new tools")
    expect(last?.peerFolded == true && last?.peerNotes?.count == 1, "on its own: the card is kept, folded")
    expect(last?.final?.contains("Checked:") == true && last?.final?.contains("ai-taken") == false, "the tag is not shown")
    let logged = CollabLog.events().filter { $0.chat == auto.chat.currentID }
    let ask = logged.first { $0.kind == .ask }, outcome = logged.first { $0.kind == .outcome }
    // Short checks: one long chain of optionals takes the type checker a long time.
    expect(ask?.mode == "auto" && ask?.purpose == "fact_check" && ask?.call == 1, "the ask is logged: mode, why, which call")
    expect(ask?.to?.count == 1 && ask?.from != nil && ask?.to?.first != ask?.from, "the ask is logged: who asked whom")
    expect(ask?.failed == 0 && ask?.smallTalk == false && ask?.turn == last?.id, "the ask is logged: how it went, for which turn")
    expect(outcome?.outcome == "partly" && outcome?.call == 1 && outcome?.from == ask?.from, "and what the asking AI says it took")
    let raw = (try? String(contentsOf: CollabLog.file, encoding: .utf8)) ?? ""
    expect(!raw.contains("SECRET-QUESTION-TEXT") && !raw.contains("Looks right") && !raw.contains("이 숫자"), "no message, reply or question text in the log")
    let show = run(.notify, "안녕", ask: true)
    expect(show.chat.current.turns.last?.peerFolded == nil && show.chat.current.turns.last?.peerNotes?.count == 1, "show and go: the card is shown")
    expect(CollabLog.events().first { $0.chat == show.chat.currentID && $0.kind == .ask }?.smallTalk == true, "a call on a greeting is counted as small talk")
    let request = run(.notify, "다른 AI한테도 물어봐", ask: false)
    expect(CollabLog.events().contains { $0.chat == request.chat.currentID && $0.kind == .request && $0.priorCalls == 0 }, "the user's request for other AIs is logged")
    print("PASS: AI collaboration setting (off keeps ask_peer only, show and go, on its own folds the cards) and log (who, whom, why, outcome, no text, writers at once, size)")
}
