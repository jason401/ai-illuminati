import Foundation
import AIAccounts
import AILocalization
import AIRuntime
import AIWorkspace
import AIChat

// convene_meeting / meeting_result (Meeting.swift): an answering AI hands a decision to a meeting in a hidden chat on a
// worker of its own and continues its answer with the result. The answer's own state is never overwritten, a stop
// stops the meeting, one meeting per answer, and nobody in the meeting can ask or convene on (depth 1).
func testMeetingTool() {
    func text(_ reply: [String: Any]) -> String { ((reply["content"] as? [[String: Any]])?.first?["text"] as? String) ?? "" }
    func spin(_ seconds: TimeInterval, until done: () -> Bool) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline && !done() { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    }
    func meetingID(_ reply: String) -> String? {
        reply.range(of: #"[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}"#, options: .regularExpression).map { String(reply[$0]) }
    }

    // A child token stops with its parent, starts stopped under a stopped parent, and stops alone without the parent.
    let parent = DebateCancellation(), child = parent.child(), alone = parent.child()
    alone.cancel()
    expect(alone.isCancelled && !parent.isCancelled && !child.isCancelled, "a child stops alone without stopping the answer")
    parent.cancel()
    expect(child.isCancelled && parent.child().isCancelled, "the answer's stop reaches its meetings, even ones made after it")

    // One end, set once: a late result does not overwrite a stop; a stop wakes the waiter at once.
    let once = HeldMeeting(id: UUID(), asker: "a", names: [], token: DebateCancellation())
    once.end(.stopped); once.end(.done("late"))
    expect(once.state == .stopped && once.wait(0) == .stopped, "the first end stays")
    let raced = HeldMeeting(id: UUID(), asker: "a", names: [], token: DebateCancellation())
    raced.token.cancel(); raced.end(.done("too late"))
    expect(raced.state == .stopped && raced.wait(0) == .stopped, "a result that ends after the stop is not handed out")
    let waiting = HeldMeeting(id: UUID(), asker: "a", names: [], token: DebateCancellation())
    DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { waiting.token.cancel() }
    let began = Date()
    expect(waiting.wait(30) == .stopped && Date().timeIntervalSince(began) < 5, "a stop wakes meeting_result before the meeting thread ends")

    let claude = Account(id: "meet-claude", provider: .claude, name: "C"), codex = Account(id: "meet-codex", provider: .codex, name: "G")
    let gemini = Account(id: "meet-gemini", provider: .gemini, name: "Gem")
    let model = AppModel()
    model.accounts = [claude, codex, gemini]
    let lock = NSLock()
    var speakers: [(String, WorkspaceBinding)] = [], moderations: [String] = [], finals: [String] = []

    // The meeting's own speeches, moderation and result (answers that are not the chat's own).
    func meetingReply(_ account: Account, _ prompt: String, _ binding: WorkspaceBinding, _ token: DebateCancellation) -> Result<String, Answerer.Failure>? {
        if prompt.contains("[MEETING RESULT]") {
            lock.lock(); finals.append(prompt); lock.unlock()
            return .success("결론: A로 가자.\n이견: 없음.")
        }
        if prompt.contains("[MODE3 MODERATION]") {
            lock.lock(); moderations.append(prompt); lock.unlock()
            return .success(#"{"action":"finish","reason":"agreed","board":"Agreed: A"}"#)
        }
        if prompt.contains("[MODE3 SPEECH]") {
            lock.lock(); speakers.append((account.id, binding)); lock.unlock()
            if prompt.contains("SLOW") {
                let end = Date().addingTimeInterval(20)
                while !token.isCancelled && Date() < end { Thread.sleep(forTimeInterval: 0.02) }
                return .failure(.failed("Cancelled"))
            }
            return .success("\(account.name): A.")
        }
        return nil
    }

    // Held directly on a worker: the worker's own state stays as it was.
    let direct = Discussion(model: model)
    direct.configure { $0.mode = 0 }
    let room = direct.currentID
    direct.change(room) { $0.turns.append(ChatTurn(question: "A와 B 중 뭐가 나아?")) }
    let own = WorkspaceBinding(roots: [WorkspaceRoot(path: AccountStore.home + "/meet-own", directory: true, writable: true)], face: true)
    let ownRoom = UUID()
    direct.activeWorkspace = own; direct.activeSessionRoom = ownRoom; direct.activeMeeting = false
    direct.workspaceAnswer = { account, prompt, binding, token, _ in meetingReply(account, prompt, binding, token) ?? .success("?") }
    let token = DebateCancellation()
    let request = HeldMeeting.Request(agenda: "A or B?", brief: "A is simpler.", decision: "pick one", members: [], join: false)
    let (held, reply) = direct.holdMeeting(request, asker: claude, id: room, index: 0, question: "A와 B 중 뭐가 나아?", binding: own, cancellation: token)
    expect(held != nil && reply.contains(held!.id.uuidString) && reply.contains("meeting_result"), "convening returns the meeting id at once")
    held?.start()
    var state = HeldMeeting.State.running
    spin(30) { state = held?.state ?? .stopped; return state != .running }
    expect(state == .done("결론: A로 가자.\n이견: 없음."), "the result goes to the AI that called it: \(state)")
    expect(direct.activeWorkspace?.roots == own.roots && direct.activeWorkspace?.face == true && direct.activeSessionRoom == ownRoom
           && !direct.activeMeeting && direct.activeHeldBy == nil && direct.runCancellation == nil,
           "the answer's worker keeps its workspace, session room and mode")
    let hidden = direct.conversations.first { $0.id == held?.id }
    expect(hidden?.meetingOf?.room == room && hidden?.turns.first?.question.contains("A or B?") == true && hidden?.turns.first?.answeredAt != nil
           && !direct.listedConversations.contains { $0.id == held?.id }, "held in a hidden chat of the chat, not listed")
    expect(Set(speakers.map(\.0)) == [codex.id, gemini.id] && speakers.allSatisfy { $0.1.origin == .consulted && $0.1.project == nil && $0.1.face == nil
           && $0.1.roots.allSatisfy { $0.writable != true || $0.path.contains(held!.id.uuidString) } },
           "the caller stays out (join false); members read only, with no tools")
    expect(moderations.allSatisfy { $0.contains("Quick meeting") } && finals.first?.contains("the AI that called it") == true
           && finals.first?.contains("가자라고 하면") == false && finals.first?.contains("Say 가자") == false, "quick format; the result is written for the AI, without the user's go line")
    let card = direct.current.turns.first?.peerNotes?.first
    expect(card?.meeting == held?.id && card?.headline == L("회의 끝남 · ", "Meeting done · ") + "A or B?" && card?.text.contains("A or B?") == true
           && card?.text.contains("결론") == false, "the user sees a card with the agenda, not the result")
    let joined = direct.heldTeam(asker: claude, members: ["G"], join: true, room: room)
    expect(joined.team.map(\.id) == [claude.id, codex.id] && joined.note == nil, "named members, and the caller with join")
    let unknown = direct.heldTeam(asker: claude, members: ["Nobody"], join: false, room: room)
    expect(unknown.team.isEmpty && unknown.note?.contains("Nobody") == true
           && direct.holdMeeting(HeldMeeting.Request(agenda: "x", brief: "", decision: "", members: ["Nobody"], join: false), asker: claude, id: room, index: 0,
                                 question: "q", binding: own, cancellation: token).0 == nil, "fewer than two can meet: no meeting")
    // Convened, but the answer ended before it was registered: never started, its chat and card end as stopped.
    let (never, _) = direct.holdMeeting(request, asker: claude, id: room, index: 0, question: "q", binding: own, cancellation: DebateCancellation())
    never?.abandon()
    spin(10) { direct.current.turns.first?.peerNotes?.first { $0.meeting == never?.id }?.headline?.hasPrefix(L("회의 멈춤", "Meeting stopped")) == true }
    expect(never?.state == .stopped && never?.token.isCancelled == true
           && direct.conversations.first { $0.id == never?.id }?.turns.first?.answeredAt != nil
           && direct.current.turns.first?.peerNotes?.first { $0.meeting == never?.id }?.headline?.hasPrefix(L("회의 멈춤", "Meeting stopped")) == true,
           "an abandoned meeting ends as stopped in its chat and on its card")

    // Through a sent message: the AI convenes, keeps answering, reads the result and continues with it.
    let chat = Discussion(model: model)
    chat.configure { $0.mode = 0 }
    var tools: [String] = [], instruction = "", steps: [String] = [], running: [Int] = [], gateway: [ToolOrigin: [String]] = [:]
    var second = "", other = "", foreign = "", stopped = "", stopToken: DebateCancellation?
    chat.workspaceAnswer = { account, prompt, binding, token, _ in
        if let reply = meetingReply(account, prompt, binding, token) { return reply }
        let context = ToolContext(room: chat.currentID, roots: binding.roots, asker: account, origin: binding.origin ?? .member)
        if prompt.contains("STOP ME") {
            let opened = text(ConveneLink.shared.call("convene_meeting", ["agenda": "SLOW agenda", "brief": "b", "decision_needed": "d"], context: context))
            stopToken = token
            stopped = text(ConveneLink.shared.call("meeting_result", ["id": meetingID(opened) ?? "", "wait_seconds": 60], context: context))
            return .success("stopped")
        }
        instruction = prompt
        tools = ConveneLink.shared.tools(context: context).compactMap { $0["name"] as? String }
        for origin in [ToolOrigin.member, .side, .consulted] {
            let key = ToolHub.shared.register(room: chat.currentID, roots: [], asker: account, origin: origin)
            gateway[origin] = (ToolHub.shared.handle(["session": key, "op": "tools"])["tools"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
        }
        let opened = text(ConveneLink.shared.call("convene_meeting", ["agenda": "A or B?", "brief": "A is simpler.", "decision_needed": "pick one"], context: context))
        steps.append("convened")
        running.append(DispatchQueue.main.sync { chat.runningRooms.count })
        second = text(ConveneLink.shared.call("convene_meeting", ["agenda": "again", "brief": "b", "decision_needed": "d"], context: context))
        var codexContext = context; codexContext.asker = account.id == claude.id ? codex : claude
        foreign = text(ConveneLink.shared.call("meeting_result", ["id": meetingID(opened) ?? "", "wait_seconds": 0], context: codexContext))
        var consulted = context; consulted.origin = .consulted
        other = text(ConveneLink.shared.call("convene_meeting", ["agenda": "x", "brief": "b", "decision_needed": "d"], context: consulted))
        let result = text(ConveneLink.shared.call("meeting_result", ["id": meetingID(opened) ?? "", "wait_seconds": 60], context: context))
        steps.append("result")
        return .success("회의 결과: " + result)
    }
    chat.draft = "A와 B 중 골라 줘"; chat.send()
    spin(30) { !chat.anyRunning && chat.current.turns.last?.final != nil }
    let last = chat.current.turns.last
    expect(tools == ["convene_meeting", "meeting_result"] && instruction.contains("[Meetings]") && instruction.contains("convene_meeting"),
           "the answering AI has both tools and is told when to use them")
    expect(gateway[.member]?.contains("convene_meeting") == true && gateway[.side] == ["ask_ai"]
           && gateway[.consulted]?.contains("convene_meeting") == false && gateway[.consulted]?.contains("meeting_result") == false
           && gateway[.consulted]?.contains("ask_ai") == false, "depth 1 at the gateway: no meeting tools for side answers or consulted AIs")
    expect(other.isEmpty == false && !other.contains("started"), "a consulted AI cannot convene by calling the tool directly")
    expect(steps == ["convened", "result"] && last?.final?.contains("결론: A로 가자.") == true && last?.final?.contains("Continue your answer") == true,
           "the AI keeps answering with the meeting's result: \(last?.final ?? "")")
    expect(second.contains("already convened") && foreign.contains("No meeting"), "one meeting per answer; only its caller reads the result")
    expect(running == [1], "the meeting takes no running slot of its own")
    let chatCard = last?.peerNotes?.first { $0.meeting != nil }
    expect(chatCard != nil && chat.conversations.contains { $0.id == chatCard?.meeting && $0.meetingOf?.room == chat.currentID }, "the card links its hidden meeting chat")
    expect(PeerLink.shared.session(chat.currentID) == nil && ConveneLink.shared.tools(context: ToolContext(room: chat.currentID, roots: [], asker: claude)).isEmpty,
           "closed when the message is answered")

    // The stop button stops the meeting too, and the AI waiting for its result hears so at once.
    chat.draft = "STOP ME"; chat.send()
    spin(20) { chat.current.turns.last?.peerNotes?.contains { $0.meeting != nil } == true && stopToken != nil }
    chat.stopDebate()
    spin(20) { !chat.anyRunning }
    let halted = chat.current.turns.last?.peerNotes?.first { $0.meeting != nil }
    spin(10) { chat.current.turns.last?.peerNotes?.first { $0.meeting != nil }?.headline?.hasPrefix(L("회의 멈춤", "Meeting stopped")) == true }
    let stoppedCard = chat.current.turns.last?.peerNotes?.first { $0.meeting != nil }
    expect(halted != nil && stopped.contains("stopped") && stoppedCard?.headline?.hasPrefix(L("회의 멈춤", "Meeting stopped")) == true,
           "stop: the meeting stops and meeting_result says so: \(stopped) / \(stoppedCard?.headline ?? "")")

    // The answer ended: a meeting still running stops with it.
    let ended = PeerLink.Session(room: UUID(), turn: nil) { _, _ in "" }
    let late = HeldMeeting(id: UUID(), asker: claude.id, names: [], token: DebateCancellation())
    ended.convene = { _, _ in (late, "") }
    PeerLink.shared.open(ended)
    expect(PeerLink.shared.reserveMeeting(ended, asker: claude.id) && PeerLink.shared.attach(late, to: ended), "registered while the answer runs")
    PeerLink.shared.close(ended)
    expect(late.token.isCancelled && !PeerLink.shared.reserveMeeting(ended, asker: codex.id)
           && !PeerLink.shared.attach(HeldMeeting(id: UUID(), asker: "", names: [], token: DebateCancellation()), to: ended),
           "closing the answer stops its meetings and takes no new one")
    print("PASS: convene_meeting (own worker, state kept, quick format, card, result to the caller, budget, depth 1, stop, no slot)")
}
