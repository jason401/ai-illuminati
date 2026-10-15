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

// Mode 3: repeat speakers, complete history, moderator termination and synthesis.
let debate = Discussion(model: model)
debate.configure { $0.mode = 3; $0.maxTurns = 9; $0.leader = .claude }
var decisions = 0
var debateCalls: [String] = []
debate.debateAnswer = { account, prompt, _, _ in
    debateCalls.append(prompt)
    if prompt.contains("[MODE3 MODERATION]") {
        decisions += 1
        if decisions == 1 { return .success(#"{"action":"speak","speaker":"codex","focus":"Address the counterexample"}"#) }
        return .success(#"{"action":"finish","reason":"Important objections addressed"}"#)
    }
    if prompt.contains("[MODE3 FINAL]") { return .success("Final conclusion with an open question.") }
    return .success("Contribution from " + account.provider.rawValue)
}
debate.draft = "Discuss a counterexample"
debate.send()
waitFor(debate)
expect(debate.current.turns[0].entries.map(\.speaker) == ["Claude", "ChatGPT", "Gemini", "ChatGPT"], "mode3 should repeat the moderator-selected speaker")
expect(debate.current.turns[0].entries.last?.focus == "Address the counterexample", "moderator focus not saved")
expect(debateCalls[4].contains("Contribution from gemini"), "full first lap missing from repeated speaker's context")
expect(debate.current.turns[0].endReason == "Important objections addressed", "moderator end reason missing")
expect(debate.current.turns[0].final != nil && debate.current.summary.isEmpty, "mode3 final or full-history behavior wrong")

// Hard limit: no additional speech/decision after reaching the cap, exactly one synthesis.
let capped = Discussion(model: model)
capped.configure { $0.mode = 3; $0.maxTurns = 4 }
var speechCount = 0
var finalCount = 0
capped.debateAnswer = { _, prompt, _, _ in
    if prompt.contains("[MODE3 MODERATION]") { return .success(#"{"action":"speak","speaker":"claude","focus":"One more detail"}"#) }
    if prompt.contains("[MODE3 FINAL]") { finalCount += 1; return .success("Summary") }
    speechCount += 1
    return .success("Short contribution")
}
capped.draft = "Limit test"; capped.send(); waitFor(capped)
expect(speechCount == 4 && finalCount == 1, "maximum turns must be enforced")
expect(capped.current.turns[0].maxTurns == 4, "limit not persisted")
expect(DebateDecision.parse(#"{"action":"speak","speaker":"unknown","focus":"x"}"#, team: model.accounts) == nil, "unknown speaker accepted")
expect(DebateDecision.parse(#"{"action":"finish","reason":""}"#, team: model.accounts) == nil, "empty reason accepted")

let broken = Discussion(model: model)
broken.configure { $0.mode = 3 }
var brokenCalls = 0
broken.debateAnswer = { _, prompt, _, _ in
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
    stoppedCalls += 1
    while !token.isCancelled { Thread.sleep(forTimeInterval: 0.01) }
    return .failure(.failed("Cancelled"))
}
stopped.draft = "Stop test"; stopped.send()
DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { stopped.stopDebate() }
waitFor(stopped)
expect(stoppedCalls == 1 && stopped.current.turns[0].final == nil, "stop must prevent all subsequent requests")
expect(stopped.current.turns[0].status.isEmpty && stopped.current.turns[0].endReason != nil, "stop must clear busy state and save reason")

let process = Process()
process.executableURL = URL(fileURLWithPath: "/bin/sleep")
process.arguments = ["30"]
try process.run()
let token = DebateCancellation(); token.attach(process); token.cancel()
let killDeadline = Date().addingTimeInterval(2)
while process.isRunning && Date() < killDeadline { Thread.sleep(forTimeInterval: 0.01) }
expect(!process.isRunning, "cancel must terminate the actual process")
print("PASS: mode3 repeat speakers, moderator completion, hard cap, invalid decision, stop prevents calls, actual process cancellation")

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
