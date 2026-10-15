import Foundation
import Cocoa

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fatalError(message) }
}
func waitFor(_ discussion: Discussion) {
    let deadline = Date().addingTimeInterval(5)
    while discussion.running && Date() < deadline {
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    }
    expect(!discussion.running, "discussion did not finish")
}

let model = AppModel()
model.accounts = Account.Provider.allCases.map {
    Account(id: "test-" + $0.rawValue, provider: $0, name: $0.title, dir: nil)
}
let discussion = Discussion(model: model)
discussion.configure {
    $0.mode = 2
    $0.order = [.codex, .claude, .gemini]
    $0.leader = .claude
}
var calls: [(Account.Provider, String)] = []
var schedule = "gemini,codex,claude"
discussion.answer = { account, prompt, _ in
    calls.append((account.provider, prompt))
    if prompt.contains("당신은 대화 진행자입니다") { return .success(schedule) }
    return .success("발언-\(account.provider.rawValue)-\(calls.count)")
}
discussion.draft = "첫 질문 원문"
discussion.send()
waitFor(discussion)
expect(calls.map { $0.0 } == [.codex, .claude, .gemini, .claude], "first order or representative wrong")
expect(calls[1].1.contains("발언-codex-1"), "second AI missing first AI's words")
expect(calls[2].1.contains("발언-claude-2"), "third AI missing second AI's words")
expect(discussion.configuration.order == [.gemini, .codex, .claude], "representative order not applied")
expect(discussion.current.summary.isEmpty && discussion.current.turns[0].final == nil, "mode2 must not summarize")
expect(discussion.current.turns[0].entries.count == 3, "each participant should speak once")

calls.removeAll()
schedule = "claude,claude,gemini" // invalid duplicate: preserve current order
discussion.draft = "두 번째 질문 원문"
discussion.send()
waitFor(discussion)
expect(calls.map { $0.0 } == [.gemini, .codex, .claude, .claude], "next order not used")
expect(calls[0].1.contains("첫 질문 원문") && calls[0].1.contains("발언-gemini-3"), "previous full dialogue lost")
expect(calls[0].1.contains("두 번째 질문 원문"), "latest question missing")
expect(discussion.configuration.order == [.gemini, .codex, .claude], "invalid schedule must preserve order")
expect(discussion.current.turns.last?.orderNote?.contains("실패") == true, "invalid order must be visible")
let savedID = discussion.currentID
let reloaded = Discussion(model: model)
reloaded.open(savedID)
expect(reloaded.configuration.mode == 2 && reloaded.configuration.leader == .claude, "configuration not persisted")
expect(reloaded.current.turns.count == 2, "full history not persisted")

// Failure of one participant must not skip later participants.
calls.removeAll()
discussion.answer = { account, prompt, _ in
    calls.append((account.provider, prompt))
    if account.provider == .gemini { return .failure(.timedOut) }
    if prompt.contains("당신은 대화 진행자입니다") { return .success("gemini,codex,claude") }
    return .success("계속 발언")
}
discussion.draft = "실패에도 계속"
discussion.send()
waitFor(discussion)
expect(discussion.current.turns.last?.entries.count == 3, "failure stopped later participants")
expect(discussion.current.turns.last?.entries.first?.failed == true, "failed entry not recorded")

let decoder = JSONDecoder()
decoder.dateDecodingStrategy = .iso8601
let legacy = Data(#"{"id":"00000000-0000-0000-0000-000000000001","title":"old","createdAt":"2026-10-14T00:00:00Z","updatedAt":"2026-10-14T00:00:00Z","turns":[{"id":"00000000-0000-0000-0000-000000000002","question":"old question","status":"","entries":[]}],"summary":"old summary"}"#.utf8)
let old = try decoder.decode(Conversation.self, from: legacy)
expect(old.configuration == nil && old.turns[0].mode == nil, "old chats must remain readable as mode1")
print("PASS: sequential full context, next-turn order, invalid order fallback, failure continuation, persistence, legacy decoding")
