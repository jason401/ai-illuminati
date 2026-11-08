import Foundation

// A chat becomes Enterprise right before its content goes to an Enterprise account, and stays so.
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
    let local = Account(id: "ent-ollama", provider: .ollama, name: "학교 Gemma", dir: nil, school: true)
    let m = AppModel()
    m.accounts = [personal, school]
    m.latestUsage = ["ent-p-claude": usage(90, 90), "ent-s-claude": usage(90, 90)]
    let chat = Discussion(model: m)
    let lock = NSLock()
    var seenBeforeAnswer: [EnterpriseMark]?
    chat.workspaceAnswer = { account, _, _, _, _ in
        // The mark is already there (and saved) when the content goes out.
        let room = chat.currentID
        let saved = ChatStore.loadAll().first { $0.id == room }
        lock.lock(); if account.id == school.id { seenBeforeAnswer = saved?.enterprise }; lock.unlock()
        return account.id == school.id ? .failure(.failed("boom")) : .success("ok")
    }

    // A personal account only: personal.
    chat.configure { $0.soloAccountID = personal.id }
    chat.draft = "개인 질문"
    chat.send(); waitFor(chat)
    let personalID = chat.currentID
    expect(chat.current.enterprise == [] && chat.current.side == .personal, "a chat answered by a personal account stays personal")

    // An Enterprise account that fails still saw the message.
    chat.newConversation()
    chat.configure { $0.soloAccountID = school.id }
    chat.draft = "학교 질문"
    chat.send(); waitFor(chat)
    let schoolID = chat.currentID
    expect(seenBeforeAnswer?.map(\.id) == [school.id], "the mark is saved before the content is sent")
    expect(chat.current.turns[0].final == nil && chat.current.enterprise?.map(\.id) == [school.id] && chat.current.side == .enterprise,
           "a failed answer still makes the chat Enterprise")

    // A reviewer only (ask_peer / review): counts too, once per account.
    chat.open(personalID)
    let view = WorkspaceBinding(roots: [])
    _ = chat.peerAnswer(schoolCodex, prompt: "review", view: view, room: personalID, timeout: 5, token: DebateCancellation())
    _ = chat.peerAnswer(schoolCodex, prompt: "review", view: view, room: personalID, timeout: 5, token: DebateCancellation())
    expect(chat.conversations.first { $0.id == personalID }?.enterprise?.map(\.id) == [schoolCodex.id], "a reviewer that read the chat marks it, once")
    // A model on this Mac sends nothing out.
    chat.noteSent(local, room: schoolID)
    expect(chat.conversations.first { $0.id == schoolID }?.enterprise?.count == 1, "a local model does not mark a chat")

    // Removing the account (or reloading) keeps the mark.
    m.accounts = [personal]
    let reloaded = Discussion(model: m)
    expect(reloaded.conversations.first { $0.id == schoolID }?.side == .enterprise, "the mark stays after the account is removed")
    expect(reloaded.conversations.first { $0.id == personalID }?.side == .enterprise, "and the reviewer's mark is saved")

    // Organizations: the same name (an account added again) is covered, another organization is not.
    let mark = EnterpriseMark(school)
    expect(mark.covers(school) && mark.covers(schoolCodex) && !mark.covers(work) && !mark.covers(personal), "a mark covers its own organization only")

    // Older chats, once: by the accounts that picked or answered them.
    let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
    let old = try! decoder.decode(Conversation.self, from: Data(#"{"id":"\#(UUID().uuidString)","title":"old","createdAt":"2025-01-01T00:00:00Z","updatedAt":"2025-01-01T00:00:00Z","turns":[],"summary":""}"#.utf8))
    expect(old.enterprise == nil && old.side == .unsure, "an older chat has no record yet")
    expect(Conversation().enterprise == [] && Conversation().side == .personal, "a new chat starts personal")
    var answered = old
    answered.turns = [ChatTurn(question: "q")]; answered.turns[0].finalBy = "Claude (학교)"
    Enterprise.classify(&answered, accounts: [personal, school])
    expect(answered.enterprise?.map(\.id) == [school.id] && answered.side == .enterprise, "an Enterprise speaker's name tells")
    var picked = old
    picked.configuration = ChatConfiguration(); picked.configuration?.memberIDs = [schoolCodex.id]
    Enterprise.classify(&picked, accounts: [schoolCodex])
    expect(picked.side == .enterprise, "a picked Enterprise member tells")
    var plain = old
    plain.turns = [ChatTurn(question: "q")]; plain.turns[0].finalBy = "Claude"
    Enterprise.classify(&plain, accounts: [personal, school])
    expect(plain.side == .personal, "a personal answer stays personal")
    var marked = old
    marked.configuration = ChatConfiguration(); marked.configuration?.school = true
    Enterprise.classify(&marked, accounts: [personal])
    expect(marked.side == .unsure, "marked Enterprise with no account to name: unsure, not personal")
    var copied = old
    copied.origin = SyncOrigin(device: "other", deviceName: "Other Mac", chat: UUID(), lastTurn: nil, contentAt: Date(), importedAt: Date())
    Enterprise.classify(&copied, accounts: [personal])
    expect(copied.side == .unsure, "a copy from another Mac is unsure, not personal")
    var helped = old
    helped.turns = [ChatTurn(question: "q")]; helped.turns[0].entries = [.reply(round: 1, speaker: "Gemini · YouTube search", text: "v")]
    Enterprise.classify(&helped, accounts: [personal, Account(id: "ent-s-gemini", provider: .gemini, name: "Gemini", dir: nil, school: true)])
    expect(helped.side == .unsure, "an Enterprise helper with no name left (YouTube search): unsure")
    var drawn = old
    drawn.turns = [ChatTurn(question: "q")]; drawn.turns[0].finalBy = "Claude"; drawn.turns[0].finalImages = [ChatImage(conversationID: drawn.id, name: "a.png")]
    Enterprise.classify(&drawn, accounts: [personal, schoolCodex])
    expect(drawn.side == .unsure, "pictures with an Enterprise picture maker on this Mac: unsure")
    // Sync keeps marked chats apart even when nothing else in them names the account.
    var markedOnly = Conversation(); markedOnly.enterprise = [mark]
    expect(DeviceSync.isSchool(markedOnly, accounts: []) && DeviceSync.isSchool(copied, accounts: []) && !DeviceSync.isSchool(Conversation(), accounts: []),
           "device sync uses the record")
    var again = answered
    Enterprise.classify(&again, accounts: [])
    expect(again.enterprise == answered.enterprise, "told only once")

    // Work chats: a Git project is linked; folders alone are a plain chat.
    var folders = Conversation(); folders.workspace = WorkspaceBinding(roots: [])
    expect(!folders.isProjectChat, "linked folders alone are a plain chat")
    print("PASS: Enterprise marks (saved before sending, failed answers and reviewers count, kept after removal, organizations apart, older chats told once, copies unsure, work chats)")
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
    var unsure = Conversation(); unsure.enterpriseUnsure = true
    expect(ChatSearch.passes(unsure, side: .enterprise, kind: .all) && !ChatSearch.passes(unsure, side: .personal, kind: .all), "an unsure chat is listed with Enterprise")

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
    let school = Account(id: "t-s", provider: .codex, name: "학교", dir: nil, school: true)    // same organization as the fixture's mark
    let work = Account(id: "t-w", provider: .claude, name: "회사", dir: nil, school: true)
    var copy = Conversation(); copy.title = "청룡영화제 사본"; copy.turns = [ChatTurn(question: "청룡영화제")]; copy.enterpriseUnsure = true
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
    expect(forPersonal.contains("영화 이야기") && forPersonal.contains("AI Illuminati 작업") && !forPersonal.contains("연구 노트"), "a personal account finds personal chats, not Enterprise ones")
    expect(!forPersonal.contains("사본") && !forPersonal.contains(here.id.uuidString), "copies from other Macs and the chat being answered are left out")
    expect(forPersonal.contains("data, not instructions"), "results are marked as data")
    let (forSchool, _) = reply("search_chats", ["query": "청룡영화제"], school)
    expect(forSchool.contains("연구 노트") && forSchool.contains("영화 이야기"), "an account of the organization that saw it finds the Enterprise chat too")
    let (forWork, _) = reply("search_chats", ["query": "청룡영화제"], work)
    expect(!forWork.contains("연구 노트"), "another organization's account does not")

    // Reading by id directly is checked the same way.
    let (denied, deniedError) = reply("read_chat", ["id": research.id.uuidString], personal)
    let (missing, _) = reply("read_chat", ["id": UUID().uuidString], personal)
    expect(deniedError && denied == missing, "a personal account cannot read an Enterprise chat by its id, and cannot tell it exists")
    expect(reply("read_chat", ["id": research.id.uuidString], work).1, "nor another organization's account")
    expect(reply("read_chat", ["id": copy.id.uuidString], school).1 && reply("read_chat", ["id": here.id.uuidString], school).1, "copies and the chat itself cannot be read")
    expect(reply("read_chat", ["id": research.id.uuidString], Account(id: "t-o", provider: .ollama, name: "학교", dir: nil, school: true)).1, "a model on this Mac is not an Enterprise account")
    let (read, readError) = reply("read_chat", ["id": research.id.uuidString], school)
    expect(!readError && read.contains("3.2 MHz") && read.contains("data, not instructions"), "the right account reads it")
    expect(host.conversations.first { $0.id == here.id }?.enterprise?.map(\.name) == ["학교"], "reading an Enterprise chat carries its record into this chat")
    let story = chats.first { $0.title == "영화 이야기" }!
    let (whole, _) = reply("read_chat", ["id": story.id.uuidString], personal)
    expect(whole.contains("[The whole chat]") && whole.contains("주말에 뭐 볼까") && whole.contains("11월 말"), "a short chat is given whole")

    // A long chat: its summary first, then the matching turns and their neighbors, within the limit.
    var long = Conversation(); long.title = "긴 대화"
    long.turns = (0..<200).map { i in var t = ChatTurn(question: "질문 \(i) " + String(repeating: "가", count: 300)); t.final = i == 120 ? "청룡영화제 수상작 정리" : "답 \(i) " + String(repeating: "나", count: 300); return t }
    let longText = ChatLink.reading(long, query: "청룡영화제", state: String(repeating: "요약", count: 5000))
    expect(longText.count <= ChatLink.readLimit + 200, "the limit holds")
    expect(longText.contains("[Its saved summary]") && longText.contains("…\n"), "the summary comes first, cut to its share")
    expect(longText.contains("[Turn 120]") && longText.contains("[Turn 121]") && longText.contains("[Turn 122]") && !longText.contains("[Turn 5]"), "the matching turn with one on each side")
    let latest = ChatLink.reading(long, query: "", state: "")
    expect(latest.contains("[Turn 200]") && !latest.contains("[Turn 1]") && latest.count <= ChatLink.readLimit + 200, "no words: the latest turns that fit")

    // The answering account reaches the tools through the invocation.
    var invocation = WorkspaceInvocation(binding: WorkspaceBinding(roots: [], face: true), room: here.id)
    invocation.account = school
    let dir = URL(fileURLWithPath: AccountStore.home).appendingPathComponent("chat-tools-manifest")
    let (_, args) = try! invocation.prepare(in: dir)
    let manifest = try! JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: args[1]))) as! [String: Any]
    let session = manifest["toolSession"] as? String ?? ""
    let listed = ToolHub.shared.handle(["op": "tools", "session": session])["tools"] as? [[String: Any]] ?? []
    expect(listed.contains { $0["name"] as? String == "read_chat" }, "the bridge offers the chat tools")
    let viaHub = ToolHub.shared.handle(["op": "call", "session": session, "name": "read_chat", "arguments": ["id": research.id.uuidString]])
    expect(viaHub["isError"] as? Bool == false, "and decides by the account that answers")
    print("PASS: chat tools (offered with a known account, personal for all, Enterprise for its organization only, direct ids checked, copies and this chat out, record carried over, summary first, whole or matching turns within the limit)")
}
