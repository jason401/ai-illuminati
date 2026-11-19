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
        ToolContext(room: room, roots: [], asker: who, turn: link.newestTurn(room), origin: origin)
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
    expect(store.history(key).map(\.action) == ["add", "archive", "replace"] && store.history(key).last?.old == old.id,
           "every change is in the history")
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
