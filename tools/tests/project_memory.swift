import Foundation
import AIAccounts
import AIChatRecords
@testable import AIRuntime
@testable import AIWorkspace
@testable import AIProjects
@testable import AIChat

// Project memory: one set of notes per project that every AI of it reads, adds to and replaces (never edits),
// each change one appended history line, kept only under the test home.
func testProjectMemory() {
    let store = ProjectMemoryStore.shared
    let root = "/tmp/pm-\(UUID().uuidString.prefix(8))"
    let binding = ProjectBinding(root: root, common: root + "/.git", remote: "", remoteURL: "")
    let key = SidebarProjects.key(binding)
    store.forget()
    let folder = ProjectMemoryStore.folder(key)
    defer { try? FileManager.default.removeItem(at: folder); store.forget() }
    let real = NSHomeDirectory() + "/Library/Application Support/AI Illuminati"
    expect(ProcessInfo.processInfo.environment["AI_ILLUMINATI_TEST_HOME"] != nil && folder.path.hasPrefix(AccountStore.supportDir + "/projects/")
           && !folder.path.hasPrefix(real), "saved only under the test home, in projects/<id>")

    let m = AppModel()
    let claude = Account(id: "pm-claude", provider: .claude, name: "Claude", dir: nil, school: false)
    let codex = Account(id: "pm-codex", provider: .codex, name: "Codex", dir: nil, school: false)
    let gemma = Account(id: "pm-gemma", provider: .ollama, name: "Gemma", dir: nil, school: false)
    m.accounts = [claude, codex]
    let chat = Discussion(model: m)
    func linked(_ title: String, _ question: String) -> Conversation {
        var c = Conversation(); c.title = title
        c.workspace = WorkspaceBinding(roots: [WorkspaceRoot(path: root, directory: true)], project: binding)
        var t = ChatTurn(question: question); t.askedAt = Date(); c.turns = [t]
        return c
    }
    let a = linked("A", "로그인 저장 방식 정하자"), b = linked("B", "로그인 어디에 저장하지?")
    var plain = Conversation(); plain.title = "Plain"; plain.turns = [ChatTurn(question: "안녕")]
    var locked = linked("Locked", "회사 일"); locked.enterpriseLock = EnterpriseLock(organization: "school", name: "School", lockedAt: Date())
    chat.conversations = [a, b, plain, locked]; chat.currentID = a.id
    let link = MemoryLink.shared
    func session(_ room: UUID, _ who: Account, _ origin: ToolOrigin = .member) -> ToolContext {
        ToolContext(room: room, roots: [WorkspaceRoot(path: root, directory: true)], asker: who, turn: link.newestTurn(room), origin: origin)
    }
    func names(_ c: ToolContext) -> Set<String> { Set(link.tools(context: c).compactMap { $0["name"] as? String }) }
    func ok(_ reply: [String: Any]) -> Bool { reply["isError"] as? Bool == false }
    func said(_ reply: [String: Any]) -> String { ((reply["content"] as? [[String: Any]])?.first?["text"] as? String) ?? "" }

    let all: Set = ["project_memory_add", "project_memory_replace", "project_memory_search"]
    expect(all.isSubset(of: names(session(a.id, claude))) && names(session(plain.id, claude)).isDisjoint(with: all)
           && names(session(a.id, claude, .consulted)).isDisjoint(with: all) && names(session(locked.id, claude)) == ["project_memory_search"],
           "the tools in a project chat only, for the AI answering it; an Enterprise chat only searches")
    expect(chat.projectMemoryRule(claude, chat: plain.id).isEmpty && chat.projectMemoryRule(claude, chat: a.id).contains("project_memory_replace"),
           "no notes yet: a project chat gets only the tool rule, a plain chat nothing")

    // Claude adds in chat A; Codex in chat B reads it and replaces it.
    let added = link.call("project_memory_add", ["kind": "decision", "text": "로그인은 Keychain에 저장, 파일 저장 안 함", "verified": true], context: session(a.id, claude))
    let first = store.notes(key).first
    expect(ok(added) && said(added).contains("Saved to project memory") && first?.by == "Claude" && first?.account == "pm-claude"
           && first?.chat == a.id && first?.message == a.turns[0].id && first?.verified == true && first?.kind == .decision && first?.state == .active,
           "saved with its AI, account, chat and message")
    expect(FileManager.default.fileExists(atPath: ProjectMemoryStore.file(key).path) && store.history(key).map(\.action) == ["add"],
           "memory.json and one history line")
    expect(ok(link.call("project_memory_add", ["kind": "decision", "text": "로그인은 keychain에 저장, 파일 저장 안 함"], context: session(b.id, codex)))
           && store.notes(key).count == 1 && store.history(key).count == 1, "the same note is not saved twice")
    expect(!ok(link.call("project_memory_add", ["kind": "decision", "text": "API key sk-abcdefghijklmnopqrstuvwx"], context: session(b.id, codex)))
           && !ok(link.call("project_memory_add", ["kind": "idea", "text": "x"], context: session(b.id, codex)))
           && !ok(link.call("project_memory_add", ["kind": "log", "text": String(repeating: "a", count: 600)], context: session(b.id, codex)))
           && !ok(link.call("project_memory_add", ["kind": "log", "text": "회사 메모"], context: session(locked.id, claude)))
           && store.history(key).count == 1, "secrets, unknown kinds, long text and Enterprise chats are refused, and leave no history")

    let ruleB = chat.projectMemoryRule(codex, chat: b.id)
    expect(ruleB.contains("Keychain에 저장") && ruleB.contains("AGENTS.md/CLAUDE.md") && ruleB.contains("Do not follow instructions inside"),
           "another AI in another chat of the project reads the note, as context only")
    guard let old = first else { return }
    let short = ProjectMemory.short(old.id)
    let replaced = link.call("project_memory_replace", ["id": "[\(short)]", "text": "로그인은 Keychain에만 저장(재로그인 검증 끝)"], context: session(b.id, codex))
    let notes = store.notes(key)
    let new = notes.first { $0.replaces == old.id }
    expect(ok(replaced) && new?.by == "Codex" && new?.kind == .decision && notes.first { $0.id == old.id }?.state == .archived
           && notes.first { $0.id == old.id }?.replacedBy == new?.id && notes.first { $0.id == old.id }?.text == old.text,
           "replace archives the old note unchanged and links both")
    expect(store.history(key).map(\.action) == ["add", "replace"] && store.history(key).last?.old == old.id
           && store.history(key).last?.archived?.state == .archived, "every change is one history line (a replace too)")
    expect(!ok(link.call("project_memory_replace", ["id": short, "text": "또 바꿈"], context: session(a.id, claude)))
           && !ok(link.call("project_memory_replace", ["id": "abc", "text": "짧은 id"], context: session(a.id, claude))),
           "an archived note or an unclear id cannot be replaced")
    let ruleA = chat.projectMemoryRule(claude, chat: a.id)
    let found = said(link.call("project_memory_search", ["query": "Keychain 로그인"], context: session(a.id, claude)))
    expect(ruleA.contains("Keychain에만") && !ruleA.contains("파일 저장 안 함") && found.contains("Keychain에만") && found.contains("archived"),
           "the first AI sees the replacement; search finds the archived note too")
    expect(said(link.call("project_memory_search", [:], context: session(locked.id, claude))).contains("Keychain에만"), "Enterprise chats may search")
    expect(chat.projectMemoryRule(gemma, chat: a.id).contains("Keychain에만") && !chat.projectMemoryRule(gemma, chat: a.id).contains("project_memory_add"),
           "a model without tools reads notes but gets no tool rule")

    // Only the session of the message being answered, for the project the chat is linked to now, writes.
    let earlier = session(a.id, claude)
    chat.change(a.id) { $0.turns.append(ChatTurn(question: "다음")) }
    expect(!ok(link.call("project_memory_add", ["kind": "log", "text": "옛 세션 기록"], context: earlier)) && !names(earlier).contains("project_memory_add")
           && names(earlier).contains("project_memory_search"), "an earlier answer's session only searches")
    let other = ProjectBinding(root: root + "-other", common: root + "-other/.git", remote: "", remoteURL: "")
    let before = session(b.id, codex)
    chat.change(b.id) { $0.workspace?.project = other }
    expect(!ok(link.call("project_memory_add", ["kind": "log", "text": "다른 프로젝트로"], context: before))
           && store.notes(SidebarProjects.key(other)).isEmpty, "a session made before the chat moved to another project writes nowhere")
    chat.change(b.id) { $0.workspace?.project = binding }
    chat.change(a.id) { $0.turns[$0.turns.count - 1].answeredAt = Date() }
    expect(!names(session(a.id, claude)).contains("project_memory_add"), "once the answer is done, no more saving")

    // The history is the record: a crash after it was written, a cut-off last line, a damaged file.
    let count = store.notes(key).count
    try? FileManager.default.removeItem(at: ProjectMemoryStore.file(key)); store.forget()
    expect(store.notes(key).count == count && store.notes(key).last?.text.contains("Keychain에만") == true, "memory.json lost: the notes come back from the history")
    let history = ProjectMemoryStore.historyFile(key)
    if let h = try? FileHandle(forWritingTo: history) { h.seekToEndOfFile(); h.write(Data("{\"at\":\"2026".utf8)); h.closeFile() }
    store.forget()
    expect(store.notes(key).count == count, "a line cut off by a crash is skipped")
    chat.change(b.id) { $0.turns.append(ChatTurn(question: "기록 남겨")) }
    expect(ok(link.call("project_memory_add", ["kind": "log", "text": "잘린 줄 뒤 기록"], context: session(b.id, codex))), "saving after a cut-off line works")
    store.forget()
    expect(store.notes(key).count == count + 1 && store.history(key).count == 3, "the cut-off line was written over, the new one kept")
    let good = try! Data(contentsOf: history)
    try! (Data("garbage\n".utf8) + good).write(to: history); store.forget()
    expect(!ok(link.call("project_memory_add", ["kind": "log", "text": "손상 뒤 기록"], context: session(b.id, codex)))
           && (try? Data(contentsOf: history)) == Data("garbage\n".utf8) + good, "a damaged history is never saved over")
    try! good.write(to: history); store.forget()

    // The instruction: pinned, decisions, open progress, the last 14 days of log; archived notes never.
    let now = Date()
    func note(_ kind: ProjectMemoryNote.Kind, _ text: String, days: Double = 0, pinned: Bool = false) -> ProjectMemoryNote {
        ProjectMemoryNote(kind: kind, text: text, pinned: pinned, createdAt: now.addingTimeInterval(-days * 86_400))
    }
    var archived = note(.decision, "보관된 결정"); archived.state = .archived
    let sample = [note(.log, "옛 작업 기록", days: 20), note(.log, "최근 작업 기록", days: 3), note(.progress, "재로그인 검증 남음"),
                  note(.decision, "결정 하나"), note(.log, "고정된 기록", days: 30, pinned: true), archived]
    let rule = ProjectMemory.rule(sample, question: "", now: now)
    let order = ["고정된 기록", "결정 하나", "재로그인 검증 남음", "최근 작업 기록"].map { rule.range(of: $0)?.lowerBound }
    expect(order.allSatisfy { $0 != nil } && zip(order, order.dropFirst()).allSatisfy { $0! < $1! }
           && !rule.contains("옛 작업 기록") && !rule.contains("보관된 결정"),
           "pinned → decisions → open progress → work log of 14 days; older log and archived notes left out")

    // Over the budget: pinned and matching notes first, the rest cut.
    let many = (0..<300).map { note(.log, "잡다한 작업 기록 번호 \($0) 그리고 길이를 늘리는 조금 더 긴 설명입니다", days: Double($0 % 10)) }
        + [note(.decision, "트랜스듀서 공진 주파수는 2 MHz"), note(.decision, "고정된 규칙", pinned: true)]
    let cut = ProjectMemory.rule(many, question: "트랜스듀서 공진 주파수?", now: now)
    expect(cut.contains("2 MHz") && cut.contains("고정된 규칙") && cut.contains("others left out") && cut.count < ProjectMemory.budget + 600,
           "over the budget: pinned and matching notes kept, about 6,000 characters")
    print("PASS: project memory (per project under the test home, two AIs add/read/replace, archive kept and searchable, history of every change, no secrets, Enterprise search only, 14-day log, budget)")
}

// The info tab's changes: the user edits, pins, archives and undoes any change or a whole meeting cleanup; a note
// deleted for good leaves no text in any file and its words are refused when an AI or a meeting adds them again.
func testProjectMemoryUndo() {
    let store = ProjectMemoryStore.shared
    let key = "/tmp/pmu-\(UUID().uuidString.prefix(8))"
    store.forget()
    defer { try? FileManager.default.removeItem(at: ProjectMemoryStore.folder(key)); store.forget() }
    func saved(_ o: ProjectMemoryStore.Outcome) -> ProjectMemoryNote? { if case .saved(let n) = o { return n }; return nil }
    func refused(_ o: ProjectMemoryStore.Outcome) -> Bool { if case .refused = o { return true }; return false }
    func current(_ id: UUID) -> ProjectMemoryNote? { store.notes(key).first { $0.id == id } }

    // Undo a replace: the old note comes back, the new one goes to the archive; a later change blocks it until undone.
    guard let a = saved(store.add(ProjectMemoryNote(kind: .decision, text: "빌드는 --stage로만", by: "Claude"), project: key)),
          let b = saved(store.replace(a.id, with: ProjectMemoryNote(kind: .decision, text: "빌드는 --stage, 설치는 사용자가", by: "Codex"), project: key))
    else { expect(false, "notes saved"); return }
    expect(saved(store.setPinned(b.id, true, project: key))?.pinned == true
           && saved(store.edit(b.id, text: "빌드는 --stage만, 설치는 사용자가", kind: .decision, verified: true, project: key))?.verified == true,
           "the user pins and edits a note in place")
    var history = store.history(key)
    expect(history.map(\.action) == ["add", "replace", "pin", "edit"] && history.map { $0.who } == ["Claude", "Codex", "user", "user"],
           "every change says who made it")
    expect(refused(store.undo([1], project: key)) && current(b.id)?.state == .active, "a replace with later changes to its note is not undone first")
    expect(saved(store.undo([3], project: key)) != nil && current(b.id)?.text == "빌드는 --stage, 설치는 사용자가" && current(b.id)?.verified == false,
           "undoing the edit gives back the AI's text")
    expect(refused(store.undo([3], project: key)), "a change is undone only once")
    expect(saved(store.undo([4], project: key)) != nil && current(b.id)?.text == "빌드는 --stage만, 설치는 사용자가"
           && ProjectMemoryStore.undone(store.history(key)) == [4], "an undo can be undone too")
    _ = store.undo([5], project: key); _ = store.undo([2], project: key)
    history = store.history(key)
    expect(saved(store.undo([1], project: key)) != nil && current(a.id)?.state == .active && current(a.id)?.replacedBy == nil
           && current(b.id)?.state == .archived, "with the later changes undone, the replace is undone: the old note is back, the new one archived")
    store.forget()
    expect(current(a.id)?.state == .active && current(b.id)?.state == .archived, "undo is a history line: it survives a restart")

    // Archive and restore; undo of an add archives the note.
    guard let c = saved(store.add(ProjectMemoryNote(kind: .progress, text: "재로그인 검증 남음", by: "Gemini"), project: key)) else { return }
    expect(saved(store.archive(c.id, project: key))?.state == .archived && !ProjectMemory.rule(store.notes(key), question: "").contains("재로그인")
           && saved(store.restore(c.id, project: key))?.state == .active, "an archived note leaves the instruction and can be restored")
    let addLine = store.history(key).lastIndex { $0.action == "add" && $0.note.id == c.id }!
    _ = store.undo([store.history(key).count - 1], project: key); _ = store.undo([store.history(key).count - 3], project: key)
    expect(saved(store.undo([addLine], project: key)) != nil && current(c.id)?.state == .archived, "undoing an AI's add archives the note")

    // A meeting cleanup is one batch: undone as a whole.
    let cleanup = UUID()
    guard let d = saved(store.add(ProjectMemoryNote(kind: .log, text: "작업 기록 하나"), project: key)) else { return }
    let e = saved(store.replace(d.id, with: ProjectMemoryNote(kind: .log, text: "작업 기록 합침"), project: key, by: ProjectMemoryChange.byMeeting, batch: cleanup))
    let f = saved(store.add(ProjectMemoryNote(kind: .decision, text: "회의가 정한 규칙"), project: key, by: ProjectMemoryChange.byMeeting, batch: cleanup))
    expect(e != nil && f != nil && store.history(key).suffix(2).allSatisfy { $0.who == "meeting" && $0.batch == cleanup }, "a cleanup's lines say meeting and share a batch")
    expect(saved(store.undo(batch: cleanup, project: key)) != nil && current(d.id)?.state == .active
           && current(e!.id)?.state == .archived && current(f!.id)?.state == .archived, "undoing the cleanup takes back all of it")

    // Delete for good: every copy of the text gone from both files, the words refused again however written.
    let secret = "고객사 이름은 아크메"
    guard let g = saved(store.add(ProjectMemoryNote(kind: .decision, text: secret, by: "Claude"), project: key)),
          let h = saved(store.replace(g.id, with: ProjectMemoryNote(kind: .decision, text: "고객사 이름은 비공개", by: "Codex"), project: key)),
          let copy = saved(store.add(ProjectMemoryNote(kind: .log, text: secret + "!", by: "Codex"), project: key))
    else { expect(false, "notes to delete saved"); return }
    let lines = store.history(key).count
    expect(saved(store.delete(g.id, project: key)) != nil && current(g.id) == nil && current(copy.id) == nil && current(h.id)?.state == .active,
           "delete removes the note and every note with the same words, not the one that replaced it")
    let files = [ProjectMemoryStore.historyFile(key), ProjectMemoryStore.file(key)].compactMap { try? String(contentsOf: $0, encoding: .utf8) }
    expect(files.count == 2 && files.allSatisfy { !$0.contains("아크메") } && store.history(key).count == lines + 1
           && store.history(key).last?.action == "delete" && store.history(key).last?.marks?.isEmpty == false,
           "the text is in neither file; the history keeps its lines, blanked, and one delete line with the marks")
    store.forget()
    expect(refused(store.add(ProjectMemoryNote(kind: .decision, text: "고객사 이름은 아크메", by: "Gemini"), project: key))
           && refused(store.add(ProjectMemoryNote(kind: .log, text: "  고객사  이름은 아크메.", by: "Gemini"), project: key))
           && refused(store.replace(h.id, with: ProjectMemoryNote(kind: .decision, text: secret), project: key))
           && refused(store.add(ProjectMemoryNote(kind: .decision, text: secret), project: key, by: ProjectMemoryChange.byMeeting, batch: UUID())),
           "after a restart the deleted words are refused: added again, written differently, as a replacement, by a meeting")
    let deleteLine = store.history(key).count - 1
    let addG = store.history(key).firstIndex { $0.note.id == g.id }!
    expect(refused(store.undo([deleteLine], project: key)) && refused(store.undo([addG], project: key)) && refused(store.undo([addG + 1], project: key))
           && current(g.id) == nil, "a delete is never undone, and no undo brings the deleted note back")
    let root = "/tmp/pmu-tool"
    let context = ToolContext(room: UUID(), roots: [WorkspaceRoot(path: root, directory: true)], asker: Account(id: "x", provider: .claude, name: "Claude", dir: nil, school: false), turn: UUID())
    let reply = ProjectMemory.call("project_memory_add", ["kind": "decision", "text": secret], project: key, enterprise: false, writes: true, context: context)
    expect(reply["isError"] as? Bool == true && "\(reply)".contains("deleted"), "an AI's tool call is refused with the reason")
    expect(saved(store.add(ProjectMemoryNote(kind: .decision, text: "고객사 이름은 비공개로 둠"), project: key)) != nil, "other words are still saved")
    print("PASS: project memory undo (who changed what, undo any change or a meeting cleanup, undo of undo, archive/restore, delete for good leaves no text and blocks the same words)")
}
