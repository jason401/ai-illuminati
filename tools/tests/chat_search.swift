import Foundation

// An Enterprise chat: locked by the user, never unlocked. In it only accounts of its organization and models on
// this Mac are sent anything; every other chat (older ones too) is open to every account.
func testEnterpriseMarks() {
    func usage(_ five: Double, _ week: Double) -> AIUsage {
        var u = AIUsage(name: "u")
        u.fiveHour = UsageWindow(usedPercent: 100 - five, resetsAt: nil)
        u.weekly = UsageWindow(usedPercent: 100 - week, resetsAt: nil)
        return u
    }
    let personal = Account(id: "ent-p-claude", provider: .claude, name: "Claude", dir: nil, school: false)
    let school = Account(id: "ent-s-claude", provider: .claude, name: "학교", dir: nil, school: true)
    let schoolCodex = Account(id: "ent-s-codex", provider: .codex, name: "학교", dir: nil, school: true)
    let work = Account(id: "ent-w-codex", provider: .codex, name: "회사", dir: nil, school: true)
    let local = Account(id: "ent-ollama", provider: .ollama, name: "Gemma", dir: nil, school: false)
    let gemini = Account(id: "ent-gemini", provider: .gemini, name: "학교", dir: nil, school: true)
    let m = AppModel()
    m.accounts = [personal, school, schoolCodex, work]
    m.latestUsage = ["ent-p-claude": usage(95, 95), "ent-s-claude": usage(60, 60), "ent-s-codex": usage(50, 50), "ent-w-codex": usage(40, 40)]
    let chat = Discussion(model: m)
    let lock = NSLock()
    var asked: [String] = []
    chat.workspaceAnswer = { account, _, _, _, _ in
        lock.lock(); asked.append(account.id); lock.unlock()
        return .success("ok")
    }

    // Older chats (with the old record) and new ones are open.
    let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
    let old = try! decoder.decode(Conversation.self, from: Data(#"{"id":"\#(UUID().uuidString)","title":"old","createdAt":"2025-01-01T00:00:00Z","updatedAt":"2025-01-01T00:00:00Z","turns":[],"summary":"","enterprise":[{"id":"x","name":"학교"}],"enterpriseUnsure":true}"#.utf8))
    expect(!old.isEnterprise && !Conversation().isEnterprise, "older chats, marked or unsure, and new chats are open")

    // The gate.
    let organization = Enterprise.organizations(m.accounts + [local, gemini])
    expect(organization.map(\.name) == ["학교", "회사"], "one organization per Enterprise name (not Gemini or models on this Mac)")
    let schoolLock = organization[0]
    expect([personal, school, schoolCodex, work, local, gemini].allSatisfy { Enterprise.permits($0, lock: nil) }, "an open chat: every account")
    expect(Enterprise.permits(school, lock: schoolLock) && Enterprise.permits(schoolCodex, lock: schoolLock) && Enterprise.permits(local, lock: schoolLock),
           "a locked chat: its organization and models on this Mac")
    expect(!Enterprise.permits(personal, lock: schoolLock) && !Enterprise.permits(work, lock: schoolLock) && !Enterprise.permits(gemini, lock: schoolLock),
           "but no personal account, other organization or Gemini")

    // Picking: only allowed accounts in a locked chat (the personal one has the most left).
    expect(AutoPick.choose(m.accounts, usage: m.latestUsage, lock: nil, current: nil)?.id == personal.id, "an open chat picks from everyone")
    expect(AutoPick.choose(m.accounts, usage: m.latestUsage, lock: schoolLock, current: nil)?.id == school.id, "a locked chat picks only its organization")
    expect(Peer.choose(asker: school, picked: nil, accounts: m.accounts, usage: m.latestUsage, lock: schoolLock)?.id == schoolCodex.id, "its reviewer too")
    expect(Discussion.typedMentions(in: "@클로드 @지피", accounts: m.accounts + [local], label: chat.label, lock: schoolLock, usage: m.latestUsage, localEnabled: true).map(\.id)
           == [school.id, schoolCodex.id], "@ calls only accounts allowed in the locked chat")

    // Only the user locks a chat: answering with an Enterprise account does not.
    chat.configure { $0.soloAccountID = school.id }
    chat.draft = "학교 계정이 답해도 열린 방"
    chat.send(); waitFor(chat)
    let openID = chat.currentID
    expect(!chat.current.isEnterprise, "an Enterprise account answering does not lock a chat")

    // Locked: a personal account picked by hand drops out and is never sent anything, even when called directly.
    chat.newConversation()
    chat.configure { $0.soloAccountID = personal.id; $0.memberIDs = [personal.id] }
    chat.lockEnterprise(chat.currentID, organization: schoolLock)
    let lockedID = chat.currentID
    expect(chat.current.enterpriseLock?.organization == "학교" && chat.configuration.soloAccountID == nil && chat.configuration.memberIDs == nil,
           "locking drops members who may not take part")
    chat.lockEnterprise(lockedID, organization: organization[1])
    expect(chat.current.enterpriseLock?.organization == "학교", "a lock is never changed")
    lock.lock(); asked = []; lock.unlock()
    chat.draft = "잠긴 방 질문"
    chat.send(); waitFor(chat)
    lock.lock(); let answeredBy = asked; lock.unlock()
    expect(answeredBy == [school.id] && chat.current.turns.last?.final == "ok", "a locked chat is answered by its organization")
    let view = WorkspaceBinding(roots: [])
    lock.lock(); asked = []; lock.unlock()
    if case .success = chat.peerAnswer(personal, prompt: "review", view: view, room: lockedID, timeout: 5, token: DebateCancellation()) {
        expect(false, "a personal reviewer must not be asked in a locked chat")
    }
    _ = chat.peerAnswer(work, prompt: "review", view: view, room: lockedID, timeout: 5, token: DebateCancellation())
    _ = chat.peerAnswer(personal, prompt: "review", view: view, room: openID, timeout: 5, token: DebateCancellation())
    lock.lock(); let reviewed = asked; lock.unlock()
    expect(reviewed == [personal.id], "the gate stops personal and other-organization accounts, not open chats")
    expect(!chat.permits(personal, room: UUID()) && chat.permits(local, room: UUID()), "a chat that cannot be found sends only to models on this Mac")
    chat.mentionQuery = ""
    expect(Set(chat.mentionCandidates().map(\.id)) == [school.id, schoolCodex.id], "the @ list in a locked chat has only allowed accounts")
    expect(Discussion.mentions(in: "@" + chat.label(personal) + " hi", picked: [personal.id],
                               accounts: m.accounts.filter { Enterprise.permits($0, lock: schoolLock) }, label: chat.label).isEmpty,
           "a personal account picked before cannot be called")
    chat.mentionQuery = nil

    // Saved and loaded with its lock; the open chat stays open.
    let reloaded = Discussion(model: m)
    expect(reloaded.conversations.first { $0.id == lockedID }?.enterpriseLock?.organization == "학교"
           && reloaded.conversations.first { $0.id == openID }?.isEnterprise == false, "the lock is saved")
    expect(DeviceSync.isSchool(chat.current) && !DeviceSync.isSchool(old), "device sync keeps only locked chats apart")

    // Work chats: a Git project is linked; folders alone are a plain chat.
    var folders = Conversation(); folders.workspace = WorkspaceBinding(roots: [])
    expect(!folders.isProjectChat, "linked folders alone are a plain chat")
    print("PASS: Enterprise lock (older chats open, the gate, picking, only the user locks, never unlocked, saved, work chats)")
}

// ⌘F in a chat: turns with the words, moves between them, earlier turns drawn first, highlights.
func testChatFind() {
    let m = AppModel()
    let chat = Discussion(model: m)
    var c = Conversation(); c.title = "find"
    c.turns = (0..<45).map { i in
        var t = ChatTurn(question: "질문 \(i)"); t.mode = 0
        t.final = i == 2 ? "청룡영화제는 11월에 열려요. 청룡영화제 수상작" : i == 30 ? "작년 청룡영화제 얘기" : "다른 답 \(i)"
        if i == 40 { t.moreAnswers = [.reply(round: 1, speaker: "ChatGPT", text: "청룡영화제 후보")] }
        return t
    }
    chat.conversations = [c]; chat.currentID = c.id
    let hits = ChatFind.hits(chat.current, " 청룡영화제 ")
    expect(hits.map(\.count) == [2, 1, 1] && hits.map(\.turn) == [c.turns[2].id, c.turns[30].id, c.turns[40].id], "turns with the words, oldest first, with counts (answers by other members too)")
    expect(ChatFind.hits(chat.current, "   ").isEmpty && ChatFind.hits(chat.current, "CHUNG").isEmpty, "blank words find nothing")
    expect(ChatFind.ranges("Spacing and spacing", "SPACING").count == 2, "case does not matter")

    chat.findOpen = true; chat.findText = "청룡영화제"; chat.findFresh = true
    chat.findStep(0)
    expect(chat.jumpTurn == c.turns[40].id && chat.findPosition == 2, "a new search starts at the newest turn")
    chat.findStep(-1); chat.findStep(-1)
    expect(chat.jumpTurn == c.turns[2].id && chat.findPosition == 0, "earlier moves up")
    expect(chat.shownTurns >= 43, "a turn not drawn yet is drawn before scrolling to it")
    chat.findStep(-1)
    expect(chat.jumpTurn == c.turns[40].id, "and wraps around")
    let count = chat.jumpCount
    chat.jump(to: UUID())
    expect(chat.jumpCount == count, "an unknown turn is ignored")

    let marked = ChatFind.highlighted(AttributedString("a 청룡영화제 b 청룡영화제"), "청룡영화제", current: true)
    expect(marked.runs.filter { $0.backgroundColor != nil }.count == 2 && String(marked.characters) == "a 청룡영화제 b 청룡영화제", "the words are highlighted, the text unchanged")
    expect(FindHighlight().apply(AttributedString("x")) == AttributedString("x"), "no words: nothing changes")

    // Another chat closes the search.
    var other = Conversation(); other.turns = [ChatTurn(question: "x")]
    chat.conversations.append(other)
    chat.open(other.id)
    expect(!chat.findOpen && chat.findText.isEmpty && chat.jumpTurn == nil, "opening another chat closes find")
    print("PASS: find in a chat (turns with the words, counts, newest first, earlier and next with wrap, earlier turns drawn, highlights, closed on another chat)")
}

// Search across chats: words with endings, title first, filters, the best turn and a line from it.
func testChatSearch() {
    let chats = searchFixtures()
    let found = ChatSearch.search("청룡영화제", in: chats)
    expect(found.first?.title == "청룡영화제 후보", "a title match comes first")
    expect(Set(found.map(\.title)) == ["청룡영화제 후보", "영화 이야기", "AI Illuminati 작업", "연구 노트"], "messages and answers are searched, with endings (는, 에서, 와는)")
    let story = found.first { $0.title == "영화 이야기" }!
    expect(story.turn == chats[0].turns[1].id && story.snippet.contains("청룡영화제") && story.words == "청룡영화제", "the matching turn and a line from it")
    expect(ChatSearch.search("청룡영화제에서", in: chats).contains { $0.title == "영화 이야기" }, "a word with another ending still finds it")
    expect(!ChatSearch.search("청룡영화제 얘기했던거", in: chats).isEmpty, "half of the words is enough")
    expect(ChatSearch.search("우주 로켓 발사", in: chats).isEmpty, "unrelated words find nothing")
    expect(ChatSearch.search("앱", in: chats).first?.title == "앱 아이콘", "a one-letter word")
    expect(ChatSearch.search("  ", in: chats).isEmpty, "blank finds nothing")
    expect(ChatSearch.search("MHZ", in: chats).first?.title == "연구 노트", "case does not matter")

    func titles(_ side: ChatSearch.SideFilter, _ kind: ChatSearch.KindFilter) -> Set<String> {
        Set(chats.filter { ChatSearch.passes($0, side: side, kind: kind) }.map(\.title))
    }
    expect(titles(.enterprise, .all) == ["연구 노트"] && !titles(.personal, .all).contains("연구 노트"), "personal / Enterprise filter")
    expect(titles(.all, .work) == ["AI Illuminati 작업"] && titles(.all, .plain).count == 5, "plain / work filter")
    expect(titles(.all, .all).contains("연구 노트"), "the sidebar search (on this Mac only) lists Enterprise chats too")

    // A result opens its chat at the turn, with the words found.
    let m = AppModel()
    let chat = Discussion(model: m)
    chat.conversations = chats; chat.currentID = chats[5].id
    chat.openResult(story)
    expect(chat.currentID == chats[0].id && chat.jumpTurn == chats[0].turns[1].id && chat.findOpen && chat.findText == "청룡영화제", "opened at the turn with ⌘F on the words")

    // A broken chat file is skipped, the others load.
    try? FileManager.default.createDirectory(atPath: ChatStore.dir, withIntermediateDirectories: true)
    let broken = URL(fileURLWithPath: ChatStore.dir).appendingPathComponent("\(UUID().uuidString).json")
    try! Data("{ not json".utf8).write(to: broken)
    ChatStore.save(chats[1])
    expect(ChatStore.loadAll().contains { $0.id == chats[1].id }, "a broken chat file does not stop the others")
    try? FileManager.default.removeItem(at: broken)
    print("PASS: chat search (messages and answers, endings, title first, half the words, one letter, filters, best turn and line, opens at the turn, broken files skipped)")
}

// search_chats / read_chat: the app decides what the answering account may see.
func testChatTools() {
    let m = AppModel()
    let host = Discussion(model: m)
    var chats = searchFixtures()
    let personal = Account(id: "t-p", provider: .claude, name: "Claude", dir: nil, school: false)
    let school = Account(id: "t-s", provider: .codex, name: "학교", dir: nil, school: true)    // the fixture's Enterprise chat's organization
    let local = Account(id: "t-o", provider: .ollama, name: "학교", dir: nil, school: true)
    var copy = Conversation(); copy.title = "청룡영화제 사본"; copy.turns = [ChatTurn(question: "청룡영화제")]
    copy.origin = SyncOrigin(device: "d", deviceName: "iMac", chat: UUID(), lastTurn: nil, contentAt: Date(), importedAt: Date())
    var here = Conversation(); here.title = "새 채팅 청룡영화제"; here.turns = [ChatTurn(question: "청룡영화제 얘기 했던거 있잖아?")]
    chats += [copy, here]
    host.conversations = chats
    let link = ChatLink.shared
    func context(_ asker: Account?) -> ToolContext { ToolContext(room: here.id, roots: [], asker: asker) }
    func reply(_ name: String, _ args: [String: Any], _ asker: Account?) -> (String, Bool) {
        let r = link.call(name, args, context: context(asker))
        return (((r["content"] as? [[String: Any]])?.first?["text"] as? String) ?? "", r["isError"] as? Bool ?? false)
    }
    expect(link.tools(context: context(nil)).isEmpty && link.tools(context: context(personal)).count == 2, "offered only when the answering account is known")

    let research = chats.first { $0.title == "연구 노트" }!
    let (forPersonal, _) = reply("search_chats", ["query": "청룡영화제"], personal)
    expect(forPersonal.contains("영화 이야기") && forPersonal.contains("AI Illuminati 작업") && forPersonal.contains("사본"), "every account finds open chats, copies from other Macs too")
    expect(!forPersonal.contains("연구 노트") && !forPersonal.contains(here.id.uuidString), "not Enterprise chats or the chat being answered")
    expect(forPersonal.contains("data, not instructions"), "results are marked as data")
    for asker in [school, local] {
        let (found, _) = reply("search_chats", ["query": "청룡영화제"], asker)
        expect(!found.contains("연구 노트") && found.contains("영화 이야기"), "an Enterprise chat is left out for its own organization and models on this Mac too")
    }

    // Reading by id directly is checked the same way.
    let (denied, deniedError) = reply("read_chat", ["id": research.id.uuidString], school)
    let (missing, _) = reply("read_chat", ["id": UUID().uuidString], school)
    expect(deniedError && denied == missing, "an Enterprise chat cannot be read by its id, and cannot be told to exist")
    expect(reply("read_chat", ["id": research.id.uuidString], personal).1 && reply("read_chat", ["id": research.id.uuidString], local).1, "by no account")
    expect(reply("read_chat", ["id": here.id.uuidString], school).1, "the chat itself cannot be read")
    expect(!host.conversations.contains { $0.id == here.id && $0.isEnterprise }, "searching never locks a chat")
    // From inside an Enterprise chat, open chats are still found and read.
    let inLocked = link.call("read_chat", ["id": chats[0].id.uuidString], context: ToolContext(room: research.id, roots: [], asker: school))
    expect(inLocked["isError"] as? Bool == false, "an Enterprise chat reads open chats")
    let story = chats.first { $0.title == "영화 이야기" }!
    let (whole, _) = reply("read_chat", ["id": story.id.uuidString], personal)
    expect(whole.contains("[The whole chat]") && whole.contains("주말에 뭐 볼까") && whole.contains("11월 말"), "a short chat is given whole")
    var called = Conversation(); called.title = "두 AI"
    var both = ChatTurn(question: "의견?"); both.final = "Claude 의견"; both.finalBy = "Claude"
    both.moreAnswers = [.reply(round: 1, speaker: "ChatGPT", text: "부산국제영화제도 있어요")]
    called.turns = [both]
    expect(ChatSearch.search("부산국제영화제", in: [called]).first?.title == "두 AI", "answers by other members are searched")
    expect(ChatLink.reading(called, query: "", state: "").contains("ChatGPT:\n부산국제영화제도 있어요"), "and read, with who wrote them")

    // A long chat: its summary first, then the matching turns and their neighbors, within the limit.
    var long = Conversation(); long.title = "긴 대화"
    long.turns = (0..<200).map { i in var t = ChatTurn(question: "질문 \(i) " + String(repeating: "가", count: 300)); t.final = i == 120 ? "청룡영화제 수상작 정리" : "답 \(i) " + String(repeating: "나", count: 300); return t }
    let longText = ChatLink.reading(long, query: "청룡영화제", state: String(repeating: "요약", count: 5000))
    expect(longText.count <= ChatLink.readLimit + 200, "the limit holds")
    expect(longText.contains("[Its saved summary]") && longText.contains("…\n"), "the summary comes first, cut to its share")
    expect(longText.contains("[Turn 120]") && longText.contains("[Turn 121]") && longText.contains("[Turn 122]") && !longText.contains("[Turn 5]"), "the matching turn with one on each side")
    let latest = ChatLink.reading(long, query: "", state: "")
    expect(latest.contains("[Turn 200]") && !latest.contains("[Turn 1]") && latest.count <= ChatLink.readLimit + 200, "no words: the latest turns that fit")

    // A project chat may search only its own project's chats; elsewhere project_only is not offered.
    let project = ProjectBinding(root: "/tmp/p", common: "", remote: "", remoteURL: "")
    var inProject = Conversation(); inProject.title = "프로젝트 새 채팅"; inProject.turns = [ChatTurn(question: "청룡영화제 화면?")]
    inProject.workspace = WorkspaceBinding(roots: [], project: project)
    var sibling = Conversation(); sibling.title = "청룡영화제 TODO 방"; sibling.turns = [ChatTurn(question: "청룡영화제 버튼")]
    sibling.workspace = WorkspaceBinding(roots: [], project: ProjectBinding(root: "/tmp/p", common: "", remote: "", remoteURL: ""))
    var other = Conversation(); other.title = "다른 프로젝트 청룡영화제"; other.turns = [ChatTurn(question: "청룡영화제")]
    other.workspace = WorkspaceBinding(roots: [], project: ProjectBinding(root: "/tmp/q", common: "", remote: "", remoteURL: ""))
    host.conversations = chats + [inProject, sibling, other]
    func inRoom(_ args: [String: Any]) -> (String, Bool) {
        let r = link.call("search_chats", args, context: ToolContext(room: inProject.id, roots: [], asker: personal))
        return (((r["content"] as? [[String: Any]])?.first?["text"] as? String) ?? "", r["isError"] as? Bool ?? false)
    }
    func schema(_ room: UUID) -> [String: Any] {
        let search = link.tools(context: ToolContext(room: room, roots: [], asker: personal)).first { $0["name"] as? String == "search_chats" }
        return (search?["inputSchema"] as? [String: Any])?["properties"] as? [String: Any] ?? [:]
    }
    expect(schema(inProject.id)["project_only"] != nil && schema(here.id)["project_only"] == nil, "project_only is offered only in a project chat")
    let (onlyProject, _) = inRoom(["query": "청룡영화제", "project_only": true])
    expect(onlyProject.contains("AI Illuminati 작업") && onlyProject.contains("TODO 방") && !onlyProject.contains("영화 이야기")
           && !onlyProject.contains("다른 프로젝트") && !onlyProject.contains(inProject.id.uuidString), "project_only: only that project's other chats")
    let (everywhere, _) = inRoom(["query": "청룡영화제"])
    expect(everywhere.contains("영화 이야기") && everywhere.contains("다른 프로젝트"), "without it every open chat as before")
    let marked = everywhere.split(separator: "\n").filter { $0.contains("· this project") }
    expect(marked.count == 2 && marked.allSatisfy { $0.contains("AI Illuminati 작업") || $0.contains("TODO 방") }, "the same project's chats are marked")
    let (none, _) = inRoom(["query": "날씨", "project_only": true])
    expect(none.contains("No other chat of project"), "nothing in the project says so")
    expect(reply("search_chats", ["query": "청룡영화제", "project_only": true], personal).1, "project_only outside a project is an error")
    host.conversations = chats

    // The answering account reaches the tools through the invocation.
    var invocation = WorkspaceInvocation(binding: WorkspaceBinding(roots: [], face: true), room: here.id)
    invocation.account = school
    let dir = URL(fileURLWithPath: AccountStore.home).appendingPathComponent("chat-tools-manifest")
    let (_, args) = try! invocation.prepare(in: dir)
    let manifest = try! JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: args[1]))) as! [String: Any]
    let session = manifest["toolSession"] as? String ?? ""
    let listed = ToolHub.shared.handle(["op": "tools", "session": session])["tools"] as? [[String: Any]] ?? []
    expect(listed.contains { $0["name"] as? String == "read_chat" }, "the bridge offers the chat tools")
    let viaHub = ToolHub.shared.handle(["op": "call", "session": session, "name": "read_chat", "arguments": ["id": chats[0].id.uuidString]])
    let lockedViaHub = ToolHub.shared.handle(["op": "call", "session": session, "name": "read_chat", "arguments": ["id": research.id.uuidString]])
    expect(viaHub["isError"] as? Bool == false && lockedViaHub["isError"] as? Bool == true, "and the same rules hold there")
    print("PASS: chat tools (offered with a known account, open chats for all, Enterprise chats for none, direct ids checked, this chat out, Enterprise chats read open ones, project_only, summary first, whole or matching turns within the limit)")
}

// Long-term memory (Memory.swift): the profile and facts go to every AI; the remember tool only with "AI saves on
// its own" on, or in an answer to a message that asks to remember; never in an Enterprise chat; no secrets.
func testMemory() {
    let store = MemoryStore.shared
    store.update { $0 = MemoryData() }
    defer { store.update { $0 = MemoryData() } }
    expect(MemoryStore.asksToRemember("이거 기억해 줘") && MemoryStore.asksToRemember("Please remember I use COMSOL")
           && !MemoryStore.asksToRemember("이건 기억하지 마") && !MemoryStore.asksToRemember("forget it, don't remember that") && !MemoryStore.asksToRemember("논문 요약해 줘"),
           "a message that asks to remember, not one that asks not to")
    expect(MemoryStore.looksSecret("내 비밀번호는 hunter2") && MemoryStore.looksSecret("key sk-abcdefghijklmnopqrstuv") && !MemoryStore.looksSecret("LiNbO3 투명 초음파 트랜스듀서를 연구함"),
           "secrets are refused, research facts are not")

    let m = AppModel()
    let claude = Account(id: "mem-claude", provider: .claude, name: "Claude", dir: nil, school: false)
    let gemma = Account(id: "mem-gemma", provider: .ollama, name: "Gemma", dir: nil, school: false)
    m.accounts = [claude]
    let chat = Discussion(model: m)
    var open = Conversation(); open.title = "Open"
    var turn = ChatTurn(question: "초음파 실험 계획 짜 줘"); turn.askedAt = Date(); open.turns = [turn]
    var locked = open; locked.id = UUID(); locked.title = "Locked"; locked.turns = [ChatTurn(question: "이거 기억해: 학교 과제")]
    locked.turns[0].askedAt = Date(); locked.enterpriseLock = EnterpriseLock(organization: "school", name: "School", lockedAt: Date())
    chat.conversations = [open, locked]; chat.currentID = open.id
    let link = MemoryLink.shared
    // A tool session is made for the chat's newest message (ToolHub.register).
    func session(_ room: UUID) -> ToolContext { ToolContext(room: room, roots: [], asker: claude, turn: link.newestTurn(room)) }
    func offered(_ room: UUID) -> Bool { link.tools(context: session(room)).contains { $0["name"] as? String == "remember" } }

    expect(chat.memoryRule(claude, chat: open.id).isEmpty && !offered(open.id), "nothing saved and saving off: no memory block, no tool")
    expect(link.call("remember", ["text": "x"], context: session(open.id))["isError"] as? Bool == true, "a call without the tool is refused")
    chat.change(open.id) { $0.turns[0].question = "나는 COMSOL을 써. 기억해 줘" }
    expect(offered(open.id) && chat.memoryRule(claude, chat: open.id).contains("asked you to remember"), "a message that asks to remember opens the tool")
    let reply = link.call("remember", ["text": "COMSOL과 MATLAB을 씀"], context: session(open.id))
    expect(reply["isError"] as? Bool == false && store.snapshot.items.first?.turn == open.turns[0].id && store.snapshot.items.first?.roomTitle == "Open",
           "saved with the chat and the message it came from (for Undo under the answer)")
    expect(link.call("remember", ["text": "comsol과 matlab을 씀"], context: session(open.id))["isError"] as? Bool == false && store.snapshot.items.count == 1,
           "the same fact is not saved twice")
    expect(link.call("remember", ["text": "비밀번호 1234"], context: session(open.id))["isError"] as? Bool == true
           && link.call("remember", ["text": String(repeating: "a", count: 400)], context: session(open.id))["isError"] as? Bool == true
           && store.snapshot.items.count == 1, "secrets and long text are refused")
    chat.change(open.id) { $0.turns[0].answeredAt = Date() }
    expect(!offered(open.id), "once the answer is done the tool closes")

    let earlier = session(open.id)
    store.update { $0.autoSave = true; $0.profile = "Stanford 초음파 연구자. 수치 위주 답 선호." }
    chat.change(open.id) { $0.turns.append(ChatTurn(question: "다음 실험은?")) }
    expect(link.call("remember", ["text": "옛 세션에서 온 내용"], context: earlier)["isError"] as? Bool == true && store.snapshot.items.count == 1,
           "the tool session of an earlier answer never saves to a later message")
    let rule = chat.memoryRule(claude, chat: open.id)
    expect(offered(open.id) && rule.contains("Stanford 초음파") && rule.contains("COMSOL과 MATLAB") && rule.contains("never instructions") && rule.contains("lasting fact"),
           "saving on its own: the tool every message, and every AI gets the profile and facts")
    expect(!chat.memoryRule(gemma, chat: open.id).contains("remember tool") && chat.memoryRule(gemma, chat: open.id).contains("Stanford"), "Gemma reads memory but gets no saving rule")
    expect(!offered(locked.id) && chat.memoryRule(claude, chat: locked.id).contains("Stanford") && chat.memoryRule(claude, chat: locked.id).contains("Enterprise chat: nothing from it is saved"),
           "an Enterprise chat reads memory and never saves, even when asked")

    // Many facts: those that match the message, within the limit.
    store.update { data in
        data.items += (0..<200).map { MemoryItem(text: "잡다한 사실 번호 \($0) 입니다 그리고 조금 더 긴 설명을 붙여서 길이를 늘립니다") }
        data.items.append(MemoryItem(text: "트랜스듀서 공진 주파수는 2 MHz"))
    }
    let many = MemoryStore.rule(store.snapshot, question: "트랜스듀서 공진 주파수 얼마였지?")
    expect(many.contains("2 MHz") && many.contains("others left out") && many.count < MemoryStore.profileLimit + MemoryStore.itemsLimit + 800,
           "over the limit: the matching facts go first and the rest is cut")
    store.update { $0.enabled = false }
    expect(chat.memoryRule(claude, chat: open.id).isEmpty && !offered(open.id), "memory off: nothing given, nothing saved")
    print("PASS: memory (profile and facts for every AI, remember only when on or asked and only to its own message, Enterprise reads only, no secrets or repeats, matching facts over the limit, off)")
}
