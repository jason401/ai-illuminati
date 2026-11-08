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
