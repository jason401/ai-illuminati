import Foundation
import AIAccounts
import AILocalization
@testable import AIRuntime

// ask_ai (Peer.swift): an answering AI asks other AIs on this Mac; those it asks cannot ask on (depth 1).
func testAskAI() {
    func usage(_ five: Double, _ week: Double) -> AIUsage {
        var u = AIUsage(name: "u")
        u.fiveHour = UsageWindow(usedPercent: 100 - five, resetsAt: nil)
        u.weekly = UsageWindow(usedPercent: 100 - week, resetsAt: nil)
        return u
    }
    func text(_ reply: [String: Any]) -> String { ((reply["content"] as? [[String: Any]])?.first?["text"] as? String) ?? "" }
    let claude = Account(id: "ask-claude", provider: .claude, name: "C"), codex = Account(id: "ask-codex", provider: .codex, name: "G")
    let gemini = Account(id: "ask-gemini", provider: .gemini, name: "Gem"), claude2 = Account(id: "ask-claude-2", provider: .claude, name: "C2")
    var school = Account(id: "ask-school", provider: .claude, name: "학교"); school.school = true
    var schoolCodex = Account(id: "ask-school-codex", provider: .codex, name: "학교"); schoolCodex.school = true
    let label = { (a: Account) in a.name }

    // Whom one call asks: another kind first, Gemini too, one of each kind before a second one; low usage is left out.
    let all = [claude, codex, gemini, claude2]
    let low = ["ask-codex": usage(5, 80)]
    expect(Peer.pick(asker: claude, to: nil, count: 1, members: [], accounts: all, usage: [:], lock: nil, label: label).accounts.first?.provider != .claude,
           "without `to`: a different kind of AI")
    expect(Set(Peer.pick(asker: claude, to: nil, count: 3, members: [], accounts: all, usage: [:], lock: nil, label: label).accounts.map(\.provider)) == [.codex, .gemini, .claude],
           "three at once: one of each kind")
    expect(Peer.pick(asker: claude, to: nil, count: 9, members: [], accounts: all, usage: [:], lock: nil, label: label).accounts.count == Peer.maxAtOnce, "at most three at once")
    expect(Peer.pick(asker: claude, to: nil, count: 1, members: [], accounts: all, usage: low, lock: nil, label: label).accounts.map(\.id) == [gemini.id],
           "an account low on usage is not asked")
    expect(Peer.pick(asker: claude, to: nil, count: 1, members: [], accounts: [claude, codex], usage: low, lock: nil, label: label).accounts.isEmpty,
           "nobody with enough left: nobody, not a low account")
    expect(Peer.pick(asker: claude, to: nil, count: 1, members: [codex.id], accounts: all, usage: [:], lock: nil, label: label).accounts.map(\.id) == [codex.id],
           "the chat's members first")
    let named = Peer.pick(asker: claude, to: "C2", count: 1, members: [], accounts: all, usage: [:], lock: nil, label: label)
    expect(named.accounts.map(\.id) == [claude2.id] && named.note == nil, "`to` names an AI: that one, even of the same kind")
    // `to` unknown, or outside the lock: a different kind instead, with a note.
    let unknown = Peer.pick(asker: claude, to: "Nobody", count: 1, members: [], accounts: all, usage: [:], lock: nil, label: label)
    expect(unknown.accounts.first?.provider != .claude && unknown.accounts.count == 1 && unknown.note?.contains("Nobody") == true, "unknown `to`: a different kind instead, said so")
    let lock = Enterprise.organizations([school]).first!
    let outside = Peer.pick(asker: school, to: "G", count: 1, members: [], accounts: [school, codex, gemini, schoolCodex], usage: [:], lock: lock, label: label)
    expect(outside.accounts.map(\.id) == [schoolCodex.id] && outside.note != nil, "`to` outside the Enterprise lock: a different kind of its organization instead")
    // An Enterprise chat: only AIs of its organization (no personal account, no Gemini).
    let locked = Peer.pick(asker: school, to: "any", count: 3, members: [], accounts: [school, codex, gemini, claude2, schoolCodex], usage: [:], lock: lock, label: label)
    expect(locked.accounts.map(\.id) == [schoolCodex.id], "Enterprise chat: only the same organization's AIs")
    expect(Peer.pick(asker: claude, to: "any", count: 3, members: [], accounts: [claude, claude2], usage: [:], lock: nil, label: label).accounts.map(\.id) == [claude2.id],
           "\"any\": another account of the same kind too")

    // The tool: open only while a message is answered; budget per answer; asked AIs get no ask_ai (depth 1).
    let room = UUID(), turn = UUID()
    var calls: [(Account?, PeerLink.Request)] = []
    let session = PeerLink.Session(room: room, turn: turn) { asker, request in calls.append((asker, request)); return "reply \(calls.count)" }
    let member = ToolContext(room: room, roots: [], asker: claude, turn: turn)
    expect(PeerLink.shared.tools(context: member).isEmpty, "no ask_ai before the message is being answered")
    PeerLink.shared.open(session)
    expect(PeerLink.shared.tools(context: member).first?["name"] as? String == "ask_ai", "the answering AI has ask_ai")
    var consulted = member; consulted.origin = .consulted
    expect(PeerLink.shared.tools(context: consulted).isEmpty && PeerLink.shared.call("ask_ai", ["message": "x"], context: consulted)["isError"] as? Bool == true,
           "an AI that was asked gets no ask_ai and cannot call it")
    var stale = member; stale.turn = UUID()
    expect(PeerLink.shared.tools(context: stale).isEmpty, "a tool session from an earlier message cannot ask")
    let first = PeerLink.shared.call("ask_ai", ["message": "Is 2+2 4?", "to": "G", "count": 2, "purpose": "fact_check"], context: member)
    expect(text(first) == "[ask_ai call 1]\nreply 1" && calls.last?.1.purpose == .fact_check && calls.last?.1.count == 2 && calls.last?.1.to == "G" && calls.last?.0?.id == claude.id,
           "the call carries purpose, count, to and the asker")
    for _ in 1..<Peer.maxAsks { _ = PeerLink.shared.call("ask_ai", ["message": "again"], context: member) }
    let over = PeerLink.shared.call("ask_ai", ["message": "once more"], context: member)
    expect(text(over).contains("already asked") && calls.count == Peer.maxAsks, "over budget: refused with a note, nobody asked")
    var other = member; other.asker = codex
    expect(text(PeerLink.shared.call("ask_ai", ["message": "mine"], context: other)) == "[ask_ai call 1]\nreply \(Peer.maxAsks + 1)", "another AI's answer has its own budget")
    var third = member; third.asker = gemini
    for _ in 0..<Peer.maxAsks { _ = PeerLink.shared.call("ask_ai", ["message": "mine too"], context: third) }
    for _ in 1..<Peer.maxAsks { _ = PeerLink.shared.call("ask_ai", ["message": "mine"], context: other) }
    expect(calls.count == 3 * Peer.maxAsks, "three AIs answering one message each get all four asks")
    PeerLink.shared.close(session)
    // Nobody this AI may ask (signed out, low on usage, outside the lock): no tool listed and no call.
    let nobody = PeerLink.Session(room: room, turn: turn, reachable: { $0?.id != claude.id }) { _, _ in "asked" }
    PeerLink.shared.open(nobody)
    expect(PeerLink.shared.tools(context: member).isEmpty && PeerLink.shared.call("ask_ai", ["message": "x"], context: member)["isError"] as? Bool == true
           && !PeerLink.shared.tools(context: other).isEmpty, "no one to ask: no ask_ai for that AI")
    PeerLink.shared.close(nobody)

    // Through the app's tool gateway: consulted sessions list no ask_ai; side sessions (another AI answering at once) only ask_ai.
    PeerLink.shared.open(session)
    func listed(_ origin: ToolOrigin) -> [String] {
        let key = ToolHub.shared.register(room: room, roots: [], asker: claude, origin: origin)
        return (ToolHub.shared.handle(["session": key, "op": "tools"])["tools"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
    }
    expect(!listed(.consulted).contains("ask_ai") && listed(.side) == ["ask_ai"], "depth 1 at the gateway; side answers get only ask_ai")
    PeerLink.shared.close(session)
    let dir = URL(fileURLWithPath: AccountStore.home).appendingPathComponent("ask-ai-" + UUID().uuidString)
    let base = WorkspaceBinding(roots: [WorkspaceRoot(path: dir.path, directory: true, writable: true)], face: true)
    let view = Discussion.peerView(base)
    PeerLink.shared.open(session)
    let manifest = try! WorkspaceInvocation(binding: view, room: room, account: codex).prepare(in: dir, tools: ToolHub.workspaceLink)
    let object = try! JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: manifest.1.last!))) as! [String: Any]
    PeerLink.shared.close(session)
    expect(view.origin == .consulted && object["toolSession"] == nil && view.roots.allSatisfy { $0.writable != true }, "the AI asked gets the folders read only and no tool session")
    expect(Peer.askPrompt(peer: "G", asker: "C", project: nil, roots: [], question: "q", message: "m").contains("cannot ask other AIs"), "and is told so")
    let check = Peer.askPrompt(peer: "G", asker: "C", project: nil, roots: [], question: "q", message: "m", purpose: .review)
    expect(check.contains("**Checked**") && check.contains("**Could not check**") && check.contains("**Disagree**"), "fact checks and reviews: evidence / not checked / disagree")
    expect(check.contains(Peer.answerReview) && Peer.answerReview.contains("invented") && Peer.answerReview.contains("counterexamples")
           && Peer.answerReview.contains("different question") && !Peer.askPrompt(peer: "G", asker: "C", project: nil, roots: [], question: "q", message: "m").contains(Peer.answerReview),
           "a review of a written answer looks for invented quotes and numbers, missing counterexamples and answers to another question")
    let rule = Peer.rule(peers: ["G"])
    expect(rule.contains("before you") && rule.contains("purpose \"review\" with your draft"), "answers built on numbers, quotes or advice: consider a review before sending")
    expect(Peer.rule(peers: ["G"], reviewer: "G").contains("to \"G\")") && !rule.contains("[Review is on]"), "with review on: fixes may be sent back to the reviewer")

    // Review findings and the lead's count of what it took.
    let numbered = "Two problems:\n1. a.swift:3 crashes\n   - nested detail\n2) b.swift:9 typo\n\nThat's all."
    expect(Peer.points(numbered) == 2 && Peer.points("- x\n* y\n• z") == 3 && Peer.points("Prose only, one concern.") == 1
           && Peer.points("  1. first\n  2. second\n     - detail") == 2 && Peer.points("Intro:\n   - a\n   - b\n      - nested") == 2 && Peer.points("  ") == 0,
           "points: top-level items only; prose counts as one")
    let note = Peer.fixNote("1. x", by: "G", points: 2)
    expect(note.contains("Review: taken N, left M") && note.contains("2 points") && note.contains("to \"G\"") && note.contains("does not review again on its own"),
           "the fix note asks for the count and allows a re-check by the reviewer")
    let counted = Peer.tally("Fixed 1, left 2 (wrong).\n\n**Review: taken 1, left 1**\n", points: 2)
    expect(counted.reply == "Fixed 1, left 2 (wrong)." && counted.counts?.taken == 1 && counted.counts?.left == 1, "the count line is read and taken out of the reply")
    expect(Peer.tally("Fixed.\nreview: Taken 3, left 0.", points: 2).counts == nil && Peer.tally("Fixed.\nreview: Taken 3, left 0.", points: 2).reply == "Fixed.",
           "a count that does not add up is dropped")
    expect(Peer.tally("Fixed all.", points: 2).counts == nil && Peer.tally("Fixed all.", points: 2).reply == "Fixed all."
           && Peer.tally("Review: taken 1, left 0\nthen more text", points: 1).counts == nil, "no count line at the end: the reply stays as it is")
    expect(Peer.tallyLine(points: 3, counts: (2, 1)) == L("지적 3개 → 반영 2개 / 안 반영 1개", "3 points → 2 taken / 1 left")
           && Peer.tallyLine(points: 3, counts: nil) == L("지적 3개", "3 points"), "the card line")

    // A plain chat (no project), everyone at once: both ask, each is answered by the other kind, askers never mixed.
    let model = AppModel()
    model.accounts = [claude, codex]
    let chat = Discussion(model: model)
    chat.configure { $0.mode = 0 }
    let answers = NSLock()
    var asked: [(peer: String, prompt: String)] = [], instructions: [String: String] = [:], sides: [String: ToolOrigin?] = [:]
    chat.workspaceAnswer = { account, prompt, binding, _, _ in
        if prompt.hasPrefix("[SECOND OPINION]") {
            answers.lock(); asked.append((account.id, prompt)); answers.unlock()
            return .success("Fine by \(account.name).")
        }
        answers.lock(); instructions[account.id] = prompt; sides[account.id] = binding.origin; answers.unlock()
        let context = ToolContext(room: chat.currentID, roots: binding.roots, asker: account, origin: binding.origin ?? .member)
        let reply = PeerLink.shared.call("ask_ai", ["message": "Check my answer, \(account.name)", "purpose": "review"], context: context)
        return .success("Answer by \(account.name): " + text(reply))
    }
    chat.draftMentions = [claude.id, codex.id]
    let cl = chat.label(claude), cx = chat.label(codex)
    chat.draft = "@\(cl) @\(cx) 이거 맞아?"
    chat.send()
    let deadline = Date().addingTimeInterval(30)
    while Date() < deadline && (chat.anyRunning || chat.current.turns.last?.final == nil) { RunLoop.main.run(until: Date().addingTimeInterval(0.03)) }
    let last = chat.current.turns.last
    expect(instructions.values.allSatisfy { $0.contains("[Asking other AIs]") && $0.contains("ask_ai") && !$0.contains("[Review is on]") },
           "a plain chat gets ask_ai, with no review")
    expect(sides[codex.id] == .side, "the second AI answering at once asks through a side session")
    let byPeer = Dictionary(asked.map { ($0.peer, $0.prompt) }, uniquingKeysWith: { a, _ in a })
    expect(asked.count == 2 && byPeer[codex.id]?.contains("You are \(cx). \(cl),") == true && byPeer[codex.id]?.contains("Check my answer, C") == true
           && byPeer[claude.id]?.contains("You are \(cl). \(cx),") == true && byPeer[claude.id]?.contains("Check my answer, G") == true,
           "each AI's question goes to the other one, with its own name")
    let notes = last?.peerNotes ?? []
    expect(notes.count == 2 && notes.contains { $0.headline?.hasPrefix(L("\(cl) → \(cx)에게 검토 · ", "\(cl) → \(cx) · review · ")) == true }
           && notes.contains { $0.headline?.hasPrefix(L("\(cx) → \(cl)에게 검토 · ", "\(cx) → \(cl) · review · ")) == true }, "one card per question: who asked whom, why")
    let replies = [last?.final ?? ""] + (last?.moreAnswers?.map(\.text) ?? [])
    expect(replies.contains { $0.contains("Answer by C") && $0.contains("Fine by G.") } && replies.contains { $0.contains("Answer by G") && $0.contains("Fine by C.") },
           "the replies come back to the AI that asked")
    let closing = Date().addingTimeInterval(5)   // the worker closes ask_ai just after the answer is shown
    while Date() < closing && PeerLink.shared.session(chat.currentID) != nil { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    expect(PeerLink.shared.session(chat.currentID) == nil, "closed when the message is answered")

    // Nobody else on this Mac: no ask_ai rule.
    let lonely = AppModel(); lonely.accounts = [claude]
    let alone = Discussion(model: lonely)
    alone.configure { $0.mode = 0 }
    var aloneInstruction = ""
    var aloneTools = -1
    alone.workspaceAnswer = { account, prompt, binding, _, _ in
        aloneInstruction = prompt
        aloneTools = PeerLink.shared.tools(context: ToolContext(room: alone.currentID, roots: binding.roots, asker: account)).count
        return .success("ok")
    }
    alone.draft = "안녕"; alone.send()
    let aloneDeadline = Date().addingTimeInterval(30)
    while Date() < aloneDeadline && (alone.anyRunning || alone.current.turns.last?.final == nil) { RunLoop.main.run(until: Date().addingTimeInterval(0.03)) }
    expect(!aloneInstruction.isEmpty && !aloneInstruction.contains("ask_ai") && aloneTools == 0, "no other AI: no ask_ai rule and no tool")
    print("PASS: ask_ai (whom, budget, depth 1, Enterprise, side answers, plain chat, askers kept apart, cards)")
}
