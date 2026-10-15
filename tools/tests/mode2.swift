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
expect(discussion.current.turns.last?.orderNote?.contains(L("실패", "failed")) == true, "invalid order must be visible")
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

let originalLanguage = UserDefaults.standard.object(forKey: "appLanguage")
defer {
    if let originalLanguage { UserDefaults.standard.set(originalLanguage, forKey: "appLanguage") }
    else { UserDefaults.standard.removeObject(forKey: "appLanguage") }
}
UserDefaults.standard.removeObject(forKey: "appLanguage")
expect(AppLanguage.current == .english, "fresh install must default to English")
expect(L("보내기", "Send") == "Send", "English default text")
let languageModel = AppModel()
languageModel.chatRules = AppModel.defaultChatRules
languageModel.language = .korean
expect(L("보내기", "Send") == "보내기", "Korean selection")
expect(languageModel.chatRules == AppModel.rules(for: .korean), "default rules must follow language")
expect(AppModel().language == .korean, "language must persist across model recreation")
languageModel.chatRules = "My custom rules"
languageModel.language = .english
expect(languageModel.chatRules == "My custom rules", "custom rules must be preserved")
print("PASS: default English, Korean switch, persistence, default rule localization, custom rule preservation")

// Mode 3: parallel opening, then repeat speakers, complete history, moderator termination and synthesis.
// The opening runs the AIs at the same time, so the fakes below guard shared counters with a lock.
let testLock = NSLock()
let debate = Discussion(model: model)
debate.configure { $0.mode = 3; $0.turnsPerAI = 4; $0.leader = .claude }
var decisions = 0
var debateCalls: [String] = []
var openingSeen: [String] = []
debate.debateAnswer = { account, prompt, _, _ in
    testLock.lock(); defer { testLock.unlock() }
    debateCalls.append(prompt)
    if prompt.contains("[MODE3 MODERATION]") {
        decisions += 1
        if decisions == 1 { return .success(#"{"action":"speak","speaker":"codex","focus":"Address the counterexample"}"#) }
        return .success(#"{"action":"finish","reason":"Important objections addressed"}"#)
    }
    if prompt.contains("[MODE3 FINAL]") { return .success("Final conclusion with an open question.") }
    if prompt.contains("opening round") { openingSeen.append(prompt) }
    return .success("Contribution from " + account.provider.rawValue)
}
debate.draft = "Discuss a counterexample"
debate.send()
waitFor(debate)
let debateEntries = debate.current.turns[0].entries.map(\.speaker)
expect(Set(debateEntries.prefix(3)) == ["Claude", "ChatGPT", "Gemini"], "everyone must give an opening view first")
expect(openingSeen.count == 3 && !openingSeen.contains { $0.contains("Contribution from") }, "opening views must not see each other")
// 3 AIs × 4 turns = 12, minimum 8. Finish requests before that are overridden: the AI with the fewest turns
// (not the last speaker) answers instead.
expect(Array(debateEntries.dropFirst(3)) == ["ChatGPT", "Claude", "Gemini", "Claude", "ChatGPT"], "early finish must be overridden until the minimum")
expect(decisions == 6, "moderator should be asked until finishing is allowed")
let moderations = debateCalls.filter { $0.contains("[MODE3 MODERATION]") }
expect(moderations.first?.contains("Finishing is NOT allowed yet") == true, "moderator must be told finishing is not allowed yet")
expect(moderations.first?.contains("at most 4 times") == true, "moderator must know the per-AI limit")
expect(moderations.last?.contains("Finish only if") == true, "moderator must be told when finishing is allowed")
expect(debate.current.turns[0].entries[3].focus == "Address the counterexample", "moderator focus not saved")
expect(debateCalls.first { $0.contains("[MODE3 SPEECH]") && !$0.contains("opening round") }?.contains("Contribution from gemini") == true,
       "all opening views missing from the next speaker's context")
expect(debate.current.turns[0].endReason == "Important objections addressed", "moderator end reason missing")
expect(debate.current.turns[0].maxTurns == 12 && debate.current.turns[0].turnsPerAI == 4, "per-AI limit not saved")
expect(debate.current.turns[0].final != nil && debate.current.summary.isEmpty, "mode3 final or full-history behavior wrong")

// Per-AI limit: the moderator keeps asking for Claude, but Claude stops after 2 turns; the others fill the rest.
let capped = Discussion(model: model)
capped.configure { $0.mode = 3; $0.turnsPerAI = 2 }
var spokenBy: [String: Int] = [:]
var finalCount = 0
capped.debateAnswer = { account, prompt, _, _ in
    testLock.lock(); defer { testLock.unlock() }
    if prompt.contains("[MODE3 MODERATION]") { return .success(#"{"action":"speak","speaker":"claude","focus":"One more detail"}"#) }
    if prompt.contains("[MODE3 FINAL]") { finalCount += 1; return .success("Summary") }
    spokenBy[account.provider.rawValue, default: 0] += 1
    return .success("Short contribution")
}
capped.draft = "Limit test"; capped.send(); waitFor(capped)
expect(spokenBy == ["claude": 2, "codex": 2, "gemini": 2] && finalCount == 1, "per-AI turn limit must be enforced")
expect(capped.current.turns[0].maxTurns == 6, "total limit not saved")
expect(DebateDecision.parse(#"{"action":"speak","speaker":"unknown","focus":"x"}"#, team: model.accounts) == nil, "unknown speaker accepted")
expect(DebateDecision.parse(#"{"action":"finish","reason":""}"#, team: model.accounts) == nil, "empty reason accepted")
let longFocus = String(repeating: "가", count: 900)
let wrapped = DebateDecision.parse("Here is my decision:\n```json\n{\"action\":\"speak\",\"speaker\":\"gemini\",\"focus\":\"\(longFocus)\"}\n```", team: model.accounts)
expect(wrapped?.speaker == .gemini && (wrapped?.focus?.count ?? 0) <= 600, "long or wrapped moderator decision must be accepted and clipped")

// One-line headlines: "TL;DR:" becomes the chat line, the rest stays as the full reply.
let tldr = ChatTurn.Entry.reply(round: 1, speaker: "Claude", text: "**TL;DR:** 최빈국 부자가 낫다\n\n긴 설명 첫 줄.\n둘째 줄.")
expect(tldr.headline == "최빈국 부자가 낫다" && tldr.text == "긴 설명 첫 줄.\n둘째 줄." && tldr.shortLine == "최빈국 부자가 낫다", "TL;DR line not split")
let plainReply = ChatTurn.Entry.reply(round: 1, speaker: "Gemini", text: "첫 문장입니다. 두 번째 문장입니다.")
expect(plainReply.headline == nil && plainReply.text == "첫 문장입니다. 두 번째 문장입니다." && plainReply.shortLine == "첫 문장입니다.", "fallback line wrong")
expect(ChatTurn.Entry(round: 1, speaker: "x", text: String(repeating: "a", count: 200), failed: false).shortLine.count == 89, "long fallback line not cut")

let broken = Discussion(model: model)
broken.configure { $0.mode = 3 }
var brokenCalls = 0
broken.debateAnswer = { _, prompt, _, _ in
    testLock.lock(); defer { testLock.unlock() }
    brokenCalls += 1
    if prompt.contains("[MODE3 MODERATION]") { return .success("invalid JSON") }
    return .success("Short response")
}
broken.draft = "Invalid scheduling"; broken.send(); waitFor(broken)
expect(broken.current.turns[0].entries.count == 3 && brokenCalls == 5, "invalid moderation must end without retry loops")

let stopped = Discussion(model: model)
stopped.configure { $0.mode = 3 }
var stoppedCalls = 0
stopped.debateAnswer = { _, _, _, token in
    testLock.lock(); stoppedCalls += 1; testLock.unlock()
    while !token.isCancelled { Thread.sleep(forTimeInterval: 0.01) }
    return .failure(.failed("Cancelled"))
}
stopped.draft = "Stop test"; stopped.send()
DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { stopped.stopDebate() }
waitFor(stopped)
expect(stoppedCalls == 3 && stopped.current.turns[0].final == nil, "stop must end the opening round and prevent further requests")
expect(stopped.current.turns[0].entries.isEmpty, "stopped opening must not save cancelled replies")
expect(stopped.current.turns[0].status.isEmpty && stopped.current.turns[0].endReason != nil, "stop must clear busy state and save reason")

let process = Process()
process.executableURL = URL(fileURLWithPath: "/bin/sleep")
process.arguments = ["30"]
try process.run()
let second = Process()
second.executableURL = URL(fileURLWithPath: "/bin/sleep")
second.arguments = ["30"]
try second.run()
let token = DebateCancellation(); token.attach(process); token.attach(second); token.cancel()
let killDeadline = Date().addingTimeInterval(2)
while (process.isRunning || second.isRunning) && Date() < killDeadline { Thread.sleep(forTimeInterval: 0.01) }
expect(!process.isRunning && !second.isRunning, "cancel must terminate every running process")
expect(Discussion.minimumDebateTurns(limit: 9, teamSize: 3) == 6 && Discussion.minimumDebateTurns(limit: 3, teamSize: 3) == 3
       && Discussion.minimumDebateTurns(limit: 30, teamSize: 2) == 18, "minimum turns formula")
let named = Discussion.namedFirst("야, 재미나이한테 반론의 기회라도 주는게 어때", team: model.accounts).map(\.provider)
expect(named.first == .gemini && named.count == model.accounts.count, "named AI must open the first lap")
expect(Discussion.namedFirst("부처님이랑 예수님", team: model.accounts).map(\.provider) == model.accounts.map(\.provider), "order unchanged without names")
expect(debateCalls.contains { $0.contains("Speak only as yourself") }, "speakers must be told not to speak for others")
print("PASS: mode3 parallel opening, repeat speakers, minimum turns, moderator completion, per-AI cap, invalid decision, named first speaker, stop prevents calls, actual process cancellation")

// Attachment storage uses normalized private copies, not references to the user's original.
let imageChat = Discussion(model: model)
let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 32, pixelsHigh: 24, bitsPerSample: 8, samplesPerPixel: 4,
                              hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
let fixture = bitmap.representation(using: .png, properties: [:])!
try imageChat.addImage(fixture, name: "fixture.png")
let attached = imageChat.pendingImages[0]
expect(attached.url.path.hasPrefix(ChatStore.dir), "image must be copied into app storage")
expect(FileManager.default.fileExists(atPath: attached.url.path), "image copy missing")
expect(imageChat.canSend, "image-only message must be sendable")
var imageTurn = ChatTurn(question: "image question")
imageTurn.images = [attached]
var imageConversation = Conversation()
imageConversation.id = imageChat.currentID
imageConversation.turns = [imageTurn]
ChatStore.save(imageConversation)
let restored = ChatStore.loadAll().first { $0.id == imageConversation.id }!
expect(restored.turns[0].images == [attached], "attachment metadata must survive reload")
expect(Discussion.transcript(restored.turns).contains(attached.id.uuidString), "transcript must link image to its user message")
try ChatStore.delete(imageConversation)
expect(!FileManager.default.fileExists(atPath: attached.url.path), "deleting chat must remove copied images")
expect(!ChatStore.loadAll().contains { $0.id == imageConversation.id }, "deleted image chat must not reload")
imageChat.pendingImages = []
let invalid = Data("not an image".utf8)
do { _ = try ImageStore.importImage(invalid, name: "bad.png", conversationID: UUID()); fatalError("invalid image accepted") }
catch ImageStore.Failure.invalid { }
let paste = NSPasteboard.withUniqueName()
paste.setData(fixture, forType: .png)
expect(imageChat.addPastedImages(paste), "clipboard PNG must be recognized")
expect(imageChat.pendingImages.count == 1, "clipboard image not imported")
imageChat.removePendingImage(imageChat.pendingImages[0])
expect(imageChat.pendingImages.isEmpty, "remove pending image failed")
print("PASS: normalized attachment copy, image-only send, persistence, transcript image links, actual image deletion, invalid input, clipboard image import")

// Switching modes inside one chat: 1 → 2 → 1. Mode 1 must see what was said in mode 2.
do {
    let chat = Discussion(model: model)
    chat.newConversation()
    var prompts: [String] = []
    chat.answer = { account, prompt, _ in
        prompts.append(prompt)
        if prompt.contains("당신은 대화 진행자입니다") { return .success("claude,codex,gemini") }
        return .success("답-\(account.provider.rawValue)-\(prompts.count)")
    }
    chat.setMode(1)
    chat.draft = "모드1 첫 질문"
    chat.send(); waitFor(chat)
    chat.setMode(2)
    expect(chat.configuration.mode == 2, "mode must change after the first message")
    chat.draft = "모드2 질문"
    chat.send(); waitFor(chat)
    let mode2Words = chat.current.turns[1].entries.first?.text ?? "missing"
    prompts.removeAll()
    chat.setMode(1)
    chat.draft = "다시 모드1 질문"
    chat.send(); waitFor(chat)
    expect(chat.current.turns.map { $0.mode ?? 1 } == [1, 2, 1], "each message must keep its own mode")
    expect(prompts.first?.contains("요약 이후 다른 방식으로 나눈 대화 원문") == true, "mode 1 must get the mode 2 exchange")
    expect(prompts.first?.contains(mode2Words) == true && prompts.first?.contains("모드2 질문") == true, "mode 2 words missing in mode 1")
    print("PASS: mode switch mid-chat keeps per-message mode and carries mode 2 context into mode 1")
}
