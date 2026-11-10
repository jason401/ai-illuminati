import Foundation

// Spaces (Space.swift): the hidden patch block, the schema check, locked items and stale versions becoming
// proposals, Undo, the file kept outside the chat folder, and a meeting's result turned into a decision log.
func testSpace() {
    func raw(_ reply: String) -> SpacePatch.Raw { SpacePatch.split(reply).raw! }
    func reason(_ reply: String) -> String? {
        if case .failure(let bad) = SpacePatch.parse(raw(reply)) { return bad.reason }
        return nil
    }

    // Extraction: hidden from the shown reply, also while it is still being written.
    let reply = "답이에요.\n<space-patch base=1>{\"ops\":[{\"op\":\"add\",\"to\":\"b1\",\"item\":{\"text\":\"초안\"}}]}</space-patch>"
    let split = SpacePatch.split(reply)
    expect(split.reply == "답이에요." && split.raw?.header == " base=1" && split.raw?.count == 1, "the patch block is taken out of the reply")
    expect(SpacePatch.split("답 <space-pa").reply == "답", "a tag still arriving is not shown")
    expect(SpacePatch.split("답 <space-patch base=1>{\"ops\":").reply == "답", "an unclosed block is not shown")
    expect(SpacePatch.split("a < b").reply == "a < b" && SpacePatch.split("plain").raw == nil, "other text stays as it is")
    expect(Discussion.extractState("답\n<space-patch base=2>{}</space-patch>\n<chat-state>s</chat-state>").reply == "답", "the chat state cut also hides the patch")
    expect(Discussion.extractState("답 <space-patch base=2>{\"ops\"").reply == "답", "streamed replies hide a patch being written")

    // Schema: anything outside it drops the whole patch, with the reason.
    expect(reason("<space-patch base=1>{\"ops\":[{\"op\":\"run\",\"id\":\"i1\"}]}</space-patch>") != nil, "unknown ops are dropped")
    expect(reason("<space-patch>{\"ops\":[{\"op\":\"remove\",\"id\":\"i1\"}]}</space-patch>") != nil, "a patch without a base is dropped")
    expect(reason("<space-patch base=1>not json</space-patch>") != nil, "non-JSON is dropped")
    expect(reason("<space-patch base=1>{\"ops\":[{\"op\":\"add\",\"to\":\"b1\",\"item\":{\"text\":\"x\",\"userLocked\":false}}]}</space-patch>") != nil, "an AI cannot set the lock")
    expect(reason("<space-patch base=1>{\"ops\":[{\"op\":\"setStatus\",\"id\":\"i1\",\"status\":\"confirmed\"}]}</space-patch>") != nil, "an AI cannot confirm a decision")
    expect(reason("<space-patch base=1>{\"ops\":[{\"op\":\"add\",\"block\":{\"kind\":\"html\",\"title\":\"x\"}}]}</space-patch>") != nil, "only the four block kinds exist")
    expect(reason("<space-patch base=1>{\"ops\":[{\"op\":\"update\",\"id\":\"b1\",\"set\":{\"items\":[]}}]}</space-patch>") != nil, "a block's items cannot be replaced through update")
    expect(reason("<space-patch base=1>{\"ops\":[{\"op\":\"add\",\"to\":\"b1\",\"item\":{\"text\":\"x\",\"done\":1}}]}</space-patch>") != nil, "flags must be true or false")
    expect(reason("<space-patch base=1>{\"ops\":[]}</space-patch><space-patch base=1>{\"ops\":[]}</space-patch>") != nil, "two blocks in one reply are dropped")
    expect(reason("<space-patch base=1>\n```json\n{\"ops\":[{\"op\":\"remove\",\"id\":\"i1\"}]}\n```\n</space-patch>") == nil, "a fenced JSON body is read")

    // A Space with a checklist, a kanban and a decision log.
    var doc = SpaceDoc.new(title: "논문", goal: "11월 제출")
    expect(doc.userAddBlock(.checklist, title: "할 일") && doc.userAddBlock(.kanban, title: "진행") && doc.userAddBlock(.decisionLog, title: "결정"), "blocks")
    let check = doc.blocks[0].id, board = doc.blocks[1].id, log = doc.blocks[2].id
    func patch(_ base: Int, _ ops: String) -> SpacePatch.Raw { raw("<space-patch base=\(base)>{\"ops\":[\(ops)]}</space-patch>") }
    let added = SpacePatch.receive(patch(doc.version, "{\"op\":\"add\",\"to\":\"\(check)\",\"item\":{\"text\":\"초록\",\"id\":\"zzz\"}},{\"op\":\"add\",\"to\":\"\(board)\",\"item\":{\"text\":\"그림 3\"}},{\"op\":\"add\",\"to\":\"\(log)\",\"item\":{\"text\":\"저널 A\",\"pro\":[\"Claude\"],\"con\":[\"Gemini\"]}}"),
                                   by: "Claude", key: "t1", into: &doc)
    expect(added == .applied && doc.blocks[0].items.count == 1 && doc.blocks[0].items[0].id != "zzz", "an AI adds items; the app gives the ids")
    expect(doc.blocks[1].items[0].lane == doc.blocks[1].columns![0] && doc.blocks[2].items[0].status == "proposed" && doc.blocks[2].items[0].pro == ["Claude"], "items get what their kind needs")
    expect(SpacePatch.receive(patch(doc.version, "{\"op\":\"remove\",\"id\":\"\(check)\"}"), by: "Claude", key: "t1", into: &doc) == .duplicate, "one answer is applied once")
    let item = doc.blocks[0].items[0].id, decision = doc.blocks[2].items[0].id

    // Stale base: a proposal, not applied.
    let version = doc.version
    expect(SpacePatch.receive(patch(version - 1, "{\"op\":\"setStatus\",\"id\":\"\(item)\",\"status\":\"done\"}"), by: "Codex", key: "t2", into: &doc) == .proposed, "an old base becomes a proposal")
    expect(doc.version == version && doc.blocks[0].items[0].done == false && doc.proposals.count == 1, "a proposal changes nothing until accepted")
    expect(SpacePatch.accept(doc.proposals[0].id, in: &doc) && doc.blocks[0].items[0].done == true && doc.proposals.isEmpty, "accepting applies it")

    // The user's edit locks the item: an AI patch on it becomes a proposal, whole.
    doc.userChange(item) { item, _ in item.text = "초록 (내가 씀)" }
    expect(doc.blocks[0].items[0].locked, "an edit locks the item")
    let before = doc.content
    let locked = SpacePatch.receive(patch(doc.version, "{\"op\":\"update\",\"id\":\"\(item)\",\"set\":{\"text\":\"AI 초록\"}},{\"op\":\"add\",\"to\":\"\(check)\",\"item\":{\"text\":\"참고문헌\"}}"),
                                    by: "Gemini", key: "t3", into: &doc)
    expect(locked == .proposed && doc.content == before, "a patch touching a locked item is not applied, not even in part")
    expect(SpacePatch.receive(patch(doc.version, "{\"op\":\"remove\",\"id\":\"\(check)\"}"), by: "Gemini", key: "t4", into: &doc) == .proposed, "removing a block with a locked item is a proposal")
    expect(SpacePatch.receive(patch(doc.version, "{\"op\":\"setStatus\",\"id\":\"\(decision)\",\"status\":\"open\"}"), by: "Claude", key: "t5", into: &doc) == .applied
           && doc.blocks[2].items[0].open == true, "items the user did not touch still change")
    doc.userChange(decision) { item, _ in item.status = "confirmed" }
    expect(SpacePatch.receive(patch(doc.version, "{\"op\":\"update\",\"id\":\"\(decision)\",\"set\":{\"text\":\"저널 B\"}}"), by: "Claude", key: "t6", into: &doc) == .proposed, "a confirmed decision is the user's")
    let accepted = doc.proposals.first { $0.by == "Gemini" && $0.ops.count == 2 }!
    expect(SpacePatch.accept(accepted.id, in: &doc) && doc.blocks[0].items[0].text == "AI 초록" && doc.blocks[0].items[0].locked, "an accepted proposal changes locked items and keeps them locked")
    let reworded = doc.proposals.first { $0.ops.first?.target == decision }!
    expect(SpacePatch.describe(reworded.ops[0], in: doc).contains("text: 저널 B"), "the proposal card shows the fields a change sets")
    expect(SpacePatch.accept(reworded.id, in: &doc) && doc.blocks[2].items[0].status == "proposed" && doc.blocks[2].items[0].text == "저널 B",
           "a confirmed decision changed by an AI is a proposal again, not shown as the user's")

    // Bad targets drop the patch; the reason is kept.
    let notices = doc.notices.count
    expect(SpacePatch.receive(patch(doc.version, "{\"op\":\"remove\",\"id\":\"i999\"}"), by: "Claude", key: "t7", into: &doc) != .applied && doc.notices.count == notices + 1, "unknown ids are dropped with a notice")
    expect(SpacePatch.receive(patch(doc.version, "{\"op\":\"setStatus\",\"id\":\"\(doc.blocks[1].items[0].id)\",\"status\":\"\(doc.blocks[1].columns![2])\"}"), by: "Claude", key: "t8", into: &doc) == .applied && doc.blocks[1].items[0].lane == doc.blocks[1].columns![2], "kanban lanes move")

    // Undo: back one version, the number still goes up.
    let undoFrom = doc.version, previous = doc.history.last!.content
    expect(doc.undo() && doc.content == previous && doc.version == undoFrom + 1, "undo restores the version before")
    for n in 0..<40 { doc.userChange(item) { item, _ in item.text = "v\(n)" } }
    expect(doc.history.count == SpaceDoc.historyLimit, "history is bounded")

    // The prompt: ids, locks, the version, and no more than about 6,000 characters.
    let rule = SpacePatch.rule(doc)
    expect(rule.contains("<space-patch base=\(doc.version)>") && rule.contains("(locked)") && rule.contains(item), "the AI reads the Space with ids, locks and the version")
    var big = doc
    for n in 0..<150 { big.userAdd(String(repeating: "긴 항목 \(n) ", count: 8), to: check) }
    expect(SpacePatch.rule(big).count < SpacePatch.promptLimit + 2_500 && SpacePatch.rule(big).contains("(cut: the Space is longer)"), "a long Space is cut")
    let instruction = Discussion.composeInstruction(name: "Claude", provider: .claude, folders: "[Folders]", drive: "", fullAccess: false,
                                                    picture: "", helper: "", face: "", project: nil, space: rule)
    expect(instruction.contains("[Space]"), "the Space reaches the instructions")

    // On disk: outside the chat folder, kept across a restart, never overwritten when it cannot be read.
    let room = UUID()
    let file = SpaceStore.file(room)
    expect(!file.path.hasPrefix(Discussion.chatFolder(room).path + "/") && file.path.hasSuffix(".work/space.json"), "the Space is kept outside the chat folder")
    expect(SpaceStore.rule(for: room).isEmpty, "a chat without a Space tells the AI nothing")
    let store = SpaceStore()
    expect(store.change(room) { $0 = doc }, "save")
    expect(SpaceStore.load(room) == .doc(doc) && store.titles[room] == "논문", "a Space survives a restart")
    let raw1 = patch(doc.version, "{\"op\":\"add\",\"to\":\"\(check)\",\"item\":{\"text\":\"발표 연습\"}}")
    expect(store.receive(raw1, room: room, by: "Claude", key: SpaceStore.key(turn: 3, by: "Claude", raw: raw1)) == .applied, "an answer's patch is applied to the file")
    expect(store.receive(raw1, room: room, by: "Claude", key: SpaceStore.key(turn: 3, by: "Claude", raw: raw1)) == .duplicate, "the same answer delivered twice is applied once")
    expect(store.receive(raw1, room: UUID(), by: "Claude", key: "x") == nil, "a chat without a Space gets none from a patch")
    try! "{broken".write(to: file, atomically: true, encoding: .utf8)
    expect(SpaceStore.load(room) == .broken && !store.change(room, { $0 = doc }) && (try? String(contentsOf: file, encoding: .utf8)) == "{broken",
           "a Space that cannot be read is never overwritten")
    try? FileManager.default.removeItem(at: file.deletingLastPathComponent())

    // A meeting's result: conclusion and agreements decided, disagreements and open decisions open, next steps a checklist.
    let meeting = """
        ## 결론
        Space는 채팅마다 하나로 한다.
        ## 근거
        - 단순함
        ## 합의
        - **space.json**은 files/ 밖에 둔다
        ## 이견
        - Claude는 칸반을 넣자, Codex는 빼자고 했다
        ## 네 결정이 필요한 것
        1. 예약 기능을 MVP에 넣을지
        ## 다음 행동
        - 스키마 정의
        - 파서 테스트
        """
    let source = UUID()
    let blocks = SpacePatch.meetingBlocks(meeting, title: "회의 결정", source: "회의 · 턴 2", chat: source)
    expect(blocks.count == 2 && blocks[0].kind == .decisionLog && blocks[1].kind == .checklist && blocks[1].items.map(\.text) == ["스키마 정의", "파서 테스트"], "a meeting gives a decision log and its next steps")
    let decisions = blocks[0].items
    expect(decisions.map(\.text) == ["Space는 채팅마다 하나로 한다.", "space.json은 files/ 밖에 둔다", L("이견: ", "Disagreement: ") + "Claude는 칸반을 넣자, Codex는 빼자고 했다", "예약 기능을 MVP에 넣을지"],
           "conclusion, agreements, disagreements and decisions are kept, reasons are not: \(decisions.map(\.text))")
    expect(decisions.map { $0.open == true } == [false, false, true, true] && decisions.allSatisfy { $0.status == "proposed" && $0.source == "회의 · 턴 2" && $0.chat == source.uuidString },
           "meeting items are AI proposals with their source")
    expect(SpacePatch.meetingBlocks("Conclusion: ship it\nNext step: tests", title: "t", source: "s", chat: nil)[0].items.first?.text == "ship it", "English headings with a colon")
    expect(SpacePatch.meetingBlocks("결론적으로 이렇게 갑니다.", title: "t", source: "s", chat: nil)[0].items.first?.text == "결론적으로 이렇게 갑니다.", "a result without headings keeps its first paragraph")
    print("PASS: Spaces take checked patches, keep the user's edits, propose stale changes and undo")
}
