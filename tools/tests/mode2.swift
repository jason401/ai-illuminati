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

// Offer the three new modes, then check legacy engines separately.
expect(Discussion.availableModes == [1, 2, 3], "all three new modes should be offered")
let hiddenDefault = Discussion(model: AppModel())
expect(hiddenDefault.configuration.mode == 1, "a new room must start in discussion mode 1")
expect(!hiddenDefault.configuration.participants.contains(.gemini) && !hiddenDefault.useGemini, "Gemini must be off by default in new chats")
Discussion.modernModes = false
Discussion.availableModes = [1, 2, 3]
let model = AppModel()
model.accounts = Account.Provider.allCases.map {
    Account(id: "test-" + $0.rawValue, provider: $0, name: $0.title, dir: nil)
}
let discussion = Discussion(model: model)
discussion.useGemini = true
discussion.configure {
    $0.participants = [.claude, .codex, .gemini]
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
reloaded.useGemini = true
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
expect(AppModel.oldDefaultRules.count == 2 && !AppModel.defaultChatRules.contains("3–5") && !AppModel.rules(for: .korean).contains("3~5"),
       "default rules must not set a length any more")
UserDefaults.standard.set(AppModel.oldDefaultRules[1], forKey: "chatRules")
expect(AppModel().chatRules == AppModel.defaultChatRules, "a saved old default must become the new default")
UserDefaults.standard.set("My custom rules", forKey: "chatRules")
expect(AppModel().chatRules == "My custom rules", "custom saved rules must be kept")
print("PASS: default English, Korean switch, persistence, default rule localization, custom rule preservation")

// Mode 3: parallel opening, then repeat speakers, complete history, moderator termination and synthesis.
// The opening runs the AIs at the same time, so the fakes below guard shared counters with a lock.
let testLock = NSLock()
let debate = Discussion(model: model)
debate.useGemini = true
debate.configure { $0.participants = [.claude, .codex, .gemini]; $0.mode = 3; $0.turnsPerAI = 4; $0.leader = .claude }
var decisions = 0
var debateCalls: [String] = []
var openingSeen: [String] = []
var webMismatch = false
debate.debateAnswer = { account, prompt, _, _, web in
    testLock.lock(); defer { testLock.unlock() }
    debateCalls.append(prompt)
    if web != prompt.contains("[MODE3 SPEECH]") { webMismatch = true }
    if prompt.contains("[MODE3 MODERATION]") {
        decisions += 1
        if decisions == 1 { return .success(#"{"action":"speak","speaker":"codex","focus":"Address the counterexample","board":"Agreed: A / Check: B"}"#) }
        if decisions == 2 { return .success(#"{"action":"speak","speaker":"gemini","focus":"Find data for B","board":{"agreed":["A"]}}"#) }
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
// No minimum: the moderator's finish is accepted as soon as it comes. A board in an unexpected shape is ignored.
expect(Array(debateEntries.dropFirst(3)) == ["ChatGPT", "Gemini"], "moderator's speakers and early finish must be followed")
expect(decisions == 3, "moderator should be asked once per turn until it finishes")
let moderations = debateCalls.filter { $0.contains("[MODE3 MODERATION]") }
expect(moderations.first?.contains("at most 4 times") == true, "moderator must know the per-AI limit")
expect(moderations.first?.contains("best possible answer") == true && !moderations.contains { $0.contains("Right of reply") },
       "moderator must aim at the best answer, not at rebuttals")
let speeches = debateCalls.filter { $0.contains("[MODE3 SPEECH]") && !$0.contains("opening round") }
expect(speeches.last?.contains("[Moderator board]\nAgreed: A / Check: B") == true, "board must reach later speakers")
expect(debateCalls.last { $0.contains("[MODE3 FINAL]") }?.contains("Write the final answer") == true, "final must be the answer itself")
// Shared rules + transcript come first and the changing task last, so repeated calls share an identical opening.
for call in debateCalls {
    let task = ["[MODE3 SPEECH]", "[MODE3 MODERATION]", "[MODE3 FINAL]"].compactMap { call.range(of: $0)?.lowerBound }.first
    expect(call.hasPrefix("[MODE3 DEBATE]") && task != nil && call.range(of: "[Complete transcript]")!.lowerBound < task!,
           "mode3 prompt must put the transcript before the task")
}
expect(debate.current.turns[0].entries[3].focus == "Address the counterexample", "moderator focus not saved")
expect(debateCalls.first { $0.contains("[MODE3 SPEECH]") && !$0.contains("opening round") }?.contains("Contribution from gemini") == true,
       "all opening views missing from the next speaker's context")
expect(debate.current.turns[0].endReason == "Important objections addressed", "moderator end reason missing")
expect(!webMismatch, "only speeches may search the web; moderation and the final answer must not")
expect(speeches.last?.contains("check it yourself with a search") == true, "speakers must verify before disputing")
expect(!speeches.contains { $0.contains("Do not use tools") }, "speeches must not forbid the web search they are given")
expect(debate.current.turns[0].maxTurns == 12 && debate.current.turns[0].turnsPerAI == 4, "per-AI limit not saved")
expect(debate.current.turns[0].final != nil && debate.current.summary.isEmpty, "mode3 final or full-history behavior wrong")

// Per-AI limit: the moderator keeps asking for Claude, but Claude stops after 2 turns; the others fill the rest.
let capped = Discussion(model: model)
capped.useGemini = true
capped.configure { $0.participants = [.claude, .codex, .gemini]; $0.mode = 3; $0.turnsPerAI = 2 }
var spokenBy: [String: Int] = [:]
var finalCount = 0
capped.debateAnswer = { account, prompt, _, _, _ in
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

// An AI whose usage is used up is left out after its failed reply; the others carry on.
let exhausted = Discussion(model: model)
exhausted.useGemini = true
exhausted.configure { $0.participants = [.claude, .codex, .gemini]; $0.mode = 3; $0.turnsPerAI = 3 }
var exhaustedCalls: [String: Int] = [:]
var exhaustedDecisions = 0
exhausted.debateAnswer = { account, prompt, _, _, _ in
    testLock.lock(); defer { testLock.unlock() }
    if prompt.contains("[MODE3 MODERATION]") {
        exhaustedDecisions += 1
        if exhaustedDecisions > 3 { return .success(#"{"action":"finish","reason":"done"}"#) }
        return .success(#"{"action":"speak","speaker":"gemini","focus":"Search for it"}"#)
    }
    if prompt.contains("[MODE3 FINAL]") { return .success("Final") }
    exhaustedCalls[account.provider.rawValue, default: 0] += 1
    if account.provider == .gemini { return .failure(.failed("RESOURCE_EXHAUSTED (code 429): Individual quota reached.")) }
    return .success("Reply")
}
exhausted.draft = "Quota test"; exhausted.send(); waitFor(exhausted)
expect(exhaustedCalls["gemini"] == 1 && exhaustedDecisions == 4, "an AI out of usage must not be asked again")
expect(exhausted.current.turns[0].entries.filter { !$0.failed }.count == 5, "the other AIs must keep speaking")

let broken = Discussion(model: model)

broken.useGemini = true
broken.configure { $0.participants = [.claude, .codex, .gemini]; $0.mode = 3 }
var brokenCalls = 0
broken.debateAnswer = { _, prompt, _, _, _ in
    testLock.lock(); defer { testLock.unlock() }
    brokenCalls += 1
    if prompt.contains("[MODE3 MODERATION]") { return .success("invalid JSON") }
    return .success("Short response")
}
broken.draft = "Invalid scheduling"; broken.send(); waitFor(broken)
expect(broken.current.turns[0].entries.count == 3 && brokenCalls == 5, "invalid moderation must end without retry loops")

let stopped = Discussion(model: model)

stopped.useGemini = true
stopped.configure { $0.participants = [.claude, .codex, .gemini]; $0.mode = 3 }
var stoppedCalls = 0
stopped.debateAnswer = { _, _, _, token, _ in
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
let named = Discussion.namedFirst("야, 재미나이한테 반론의 기회라도 주는게 어때", team: model.accounts).map(\.provider)
expect(named.first == .gemini && named.count == model.accounts.count, "named AI must open the first lap")
expect(Discussion.namedFirst("부처님이랑 예수님", team: model.accounts).map(\.provider) == model.accounts.map(\.provider), "order unchanged without names")
expect(debateCalls.contains { $0.contains("Speak only as yourself") }, "speakers must be told not to speak for others")
print("PASS: mode3 parallel opening, moderator tasks and board, early finish, moderator completion, per-AI cap, invalid decision, named first speaker, stop prevents calls, actual process cancellation")

// Attachment storage uses normalized private copies, not references to the user's original.
let imageChat = Discussion(model: model)
imageChat.useGemini = true
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
    chat.useGemini = true
    chat.newConversation()
    var prompts: [String] = []
    // Mode 1 calls this fake concurrently; protect the captured array just like
    // the mode 3 fakes above. Unsynchronized append can corrupt Swift's storage.
    let promptLock = NSLock()
    chat.answer = { account, prompt, _ in
        promptLock.lock(); defer { promptLock.unlock() }
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

// Persistent session transport: source images once, delta text, separate moderator,
// cold bootstrap after compaction, no retries on Stop/quota.
do {
    let sessions = NativeSessions(), room = UUID(), sid = UUID().uuidString
    let account = Account(id: "session-test", provider: .claude, name: "Claude", dir: AccountStore.accountsDir + "/session-test")
    let image = URL(fileURLWithPath: "/tmp/session-test.png")
    var requests: [(String, [URL], Bool)] = []
    func request(_ context: String, role: String = "SPEECH", compact: Bool = false) {
        let result = sessions.ask(account, room: room, prompt: context + "\n[MODE3 \(role)]\nrespond", images: [image], timeout: 1, token: DebateCancellation(), web: false, speaker: "Claude", invoke: { text, images, call in
            expect(call != nil, "dedicated account must have a native session")
            requests.append((text, images, call!.resume))
            call!.observe("{\"type\":\"result\",\"session_id\":\"\(sid)\",\"is_error\":false}")
            if compact { call!.observe("{\"type\":\"system\",\"subtype\":\"compact_boundary\"}") }
            return .success("TL;DR: short\n\nanswer")
        }, note: { _ in })
        if case .failure = result { fatalError("fake session failed") }
    }
    request("source")
    request("source\n\n[Claude]\nanswer\n\n[Other]\nnew")
    expect(requests[0].1 == [image] && !requests[0].2, "first call must bootstrap image")
    expect(requests[1].1.isEmpty && requests[1].2, "resume must not resend image")
    expect(!requests[1].0.contains("source") && !requests[1].0.contains("[Claude]"), "resume duplicated previous text or own reply")
    request("source\n\n[Claude]\nanswer\n\n[Other]\nnew", role: "MODERATION")
    expect(!requests[2].2 && requests[2].1 == [image], "moderator must have a separate session")
    request("source\n\n[Claude]\nanswer\n\n[Other]\nnew\nnext", compact: true)
    request("source\n\n[Claude]\nanswer\n\n[Other]\nnew\nnext\nlast")
    expect(!requests.last!.2 && requests.last!.1 == [image], "compaction must bootstrap original images")
    expect(!NativeSessions.eligible(Account(id: "personal", provider: .codex, name: "personal", dir: nil)), "personal default home must stay stateless")
    try! sessions.reset(room)
    let source = URL(fileURLWithPath: AccountStore.home).appendingPathComponent("source.txt")
    try! "value 247".write(to: source, atomically: true, encoding: .utf8)
    let doc = try! RoomDocuments.read(source)
    expect(doc.text == "value 247", "material text changed")
    var conversation = Conversation()
    conversation.documents = [doc]
    conversation.configuration = ChatConfiguration()
    conversation.configuration?.keepSessions = true
    ChatStore.save(conversation)
    expect(ChatStore.loadAll().contains { $0.id == conversation.id && $0.documents?.first?.text == "value 247" && $0.configuration?.keepSessions == true }, "empty room materials / toggle not persisted")
    print("PASS: session delta, image reuse, role separation, compaction bootstrap and material persistence")
}

// New mode semantics, large Office import, all-account collaboration and artifacts.
do {
    Discussion.modernModes = true
    let root = URL(fileURLWithPath: AccountStore.home).appendingPathComponent("material-fixtures")
    let room = UUID()
    let word = try! MaterialReader.read(root.appendingPathComponent("large.docx"), room: room)
    expect(word.units!.contains { $0.text.contains("247 kPa") && $0.text.contains("386") }, "DOCX text/table missing")
    expect(word.units!.contains { !$0.images.isEmpty }, "DOCX embedded image missing")
    let slides = try! MaterialReader.read(root.appendingPathComponent("slides.pptx"), room: room)
    expect(slides.units![0].text.contains("file 2") && slides.units![0].text.contains("789"), "PPTX order or notes lost")
    expect(slides.units![1].text.contains("file 1"), "PPTX second slide wrong")
    let m = AppModel()
    m.accounts = [Account(id: "personal-test", provider: .codex, name: "Personal", dir: nil),
                  Account(id: "school-test", provider: .codex, name: "School", dir: AccountStore.accountsDir + "/school-test"),
                  Account(id: "claude-test", provider: .claude, name: "Claude", dir: nil)]
    let chat = Discussion(model: m)
    chat.useGemini = true
    chat.configure { $0.participants = [.claude, .codex, .gemini]; $0.mode = 3; $0.leaderAccountID = "claude-test"; $0.accountIDs = m.accounts.map(\.id) }
    var assigned: Set<String> = [], active = 0, maximum = 0
    let lock = NSLock()
    chat.collaborationAnswer = { account, prompt, _, _ in
        expect(prompt.contains("language of the latest user request") && prompt.contains("[source: URL]"), "collaboration missing language/search contract")
        if prompt.contains("[COLLAB PLAN]") { return .success("{\"assignments\":[{\"id\":\"design\",\"accountID\":\"personal-test\",\"task\":\"Design option\"},{\"id\":\"cost\",\"accountID\":\"school-test\",\"task\":\"Cost analysis\"},{\"id\":\"risk\",\"accountID\":\"claude-test\",\"task\":\"Risk analysis\"}]}") }
        if prompt.contains("[Your assignment]") {
            lock.lock(); assigned.insert(account.id); active += 1; maximum = max(maximum, active); lock.unlock()
            Thread.sleep(forTimeInterval: 0.05)
            lock.lock(); active -= 1; lock.unlock()
        }
        return .success("Concrete deliverable with uncertainties.")
    }
    chat.draft = "Compare designs and produce a project proposal, not a paper."
    chat.send(); waitFor(chat)
    expect(assigned == Set(m.accounts.map(\.id)) && maximum >= 2, "all accounts must receive independent concurrent tasks")
    expect(chat.current.turns[0].tasks?.allSatisfy { $0.state == "done" } == true, "task state not persisted")
    expect(chat.current.turns[0].artifact.map { FileManager.default.fileExists(atPath: $0) } == true, "final deliverable missing")
    expect(chat.current.turns[0].modeVersion == 2, "new mode version must persist")
    let writingRoot = URL(fileURLWithPath: AccountStore.home).appendingPathComponent("serial-writing")
    try FileManager.default.createDirectory(at: writingRoot, withIntermediateDirectories: true)
    chat.change(chat.currentID, save: true) { $0.workspace = WorkspaceBinding(roots: [WorkspaceRoot(path: writingRoot.path, directory: true)], level: .write) }
    maximum = 0
    chat.draft = "Write a proposal."; chat.send(); waitFor(chat)
    expect(maximum == 1, "writers must execute sequentially")
    expect(chat.current.turns.last?.backupPath != nil && chat.current.turns.last?.workspaceChanges?.isEmpty == false, "writing must keep backup and actual diff")
    print("PASS: large DOCX, images, PPTX order/notes, general-purpose parallel all-account collaboration and saved artifacts")
}

// A dependent account runs only after its prerequisite. Reuse source notes on follow-up.
do {
    let m = AppModel()
    m.accounts = [Account(id: "school-claude-fake", provider: .claude, name: "School Claude", dir: nil),
                  Account(id: "school-codex-fake", provider: .codex, name: "School Codex", dir: nil)]
    let chat = Discussion(model: m)
    chat.useGemini = true
    chat.configure { $0.participants = [.claude, .codex, .gemini]; $0.mode = 3; $0.leaderAccountID = "school-claude-fake"; $0.accountIDs = m.accounts.map(\.id) }
    let fixture = URL(fileURLWithPath: AccountStore.home).appendingPathComponent("material-fixtures/slides.pptx")
    let document = try! MaterialReader.read(fixture, room: chat.currentID)
    chat.change(chat.currentID, save: true) { $0.documents = [document] }
    var sourceCalls = 0, order: [String] = []
    chat.collaborationAnswer = { account, prompt, _, _ in
        if prompt.contains("[COLLAB PLAN]") {
            return .success("{\"assignments\":[{\"id\":\"requirements\",\"accountID\":\"school-claude-fake\",\"task\":\"Requirements\",\"dependsOn\":[]},{\"id\":\"proposal\",\"accountID\":\"school-codex-fake\",\"task\":\"Proposal\",\"dependsOn\":[\"requirements\"]}]}")
        }
        if prompt.contains("[COLLAB SOURCE]") { sourceCalls += 1 }
        if prompt.contains("[Your assignment]") {
            order.append(account.id)
            if account.id == "school-codex-fake" {
                expect(prompt.contains("[Completed prerequisites]") && prompt.contains("[Prerequisite result: requirements]"), "dependent worker missing prerequisite result")
            }
        }
        return .success("Evidence-backed contribution with source IDs.")
    }
    chat.draft = "Create a design proposal."; chat.send(); waitFor(chat)
    expect(order == ["school-claude-fake", "school-codex-fake"], "dependency order wrong")
    let initial = sourceCalls
    expect(initial == 0, "linking material must not launch pre-reading calls")
    order = []
    chat.draft = "Refine the same design proposal."; chat.send(); waitFor(chat)
    expect(sourceCalls == initial, "unchanged material notes must be reused on follow-up")
    expect(chat.current.turns.last?.endReason?.contains("On-demand source access") == true, "coverage/reuse must be visible")
    print("PASS: prerequisite ordering, prerequisite outputs, complete source coverage and persistent index reuse")
}

// New discussion/critical mode limits and an unavailable visual moderator fallback.
do {
    let m = AppModel()
    m.accounts = [Account(id: "mode-school-claude-fake", provider: .claude, name: "School Claude", dir: nil),
                  Account(id: "mode-school-codex-fake", provider: .codex, name: "School Codex", dir: nil)]
    let chat = Discussion(model: m)
    chat.useGemini = true
    chat.configure { $0.participants = [.claude, .codex, .gemini]; $0.mode = 1; $0.leader = .gemini; $0.turnsPerAI = 2 }
    chat.debateAnswer = { _, prompt, _, _, _ in
        if prompt.contains("[MODE3 MODERATION]") { return .success("{\"action\":\"finish\",\"reason\":\"Enough evidence\"}") }
        return .success("TL;DR: A contribution\n\nA concrete contribution.")
    }
    chat.draft = "Discuss a design."; chat.send(); waitFor(chat)
    expect(chat.current.turns[0].maxTurns == 4 && chat.current.turns[0].final != nil, "new mode limits or missing moderator fallback wrong")
    chat.configure { $0.participants = [.claude, .codex, .gemini]; $0.mode = 2 }
    chat.draft = "Critique the design."; chat.send(); waitFor(chat)
    expect(chat.current.turns[1].entries.count == 4 && chat.current.turns[1].maxTurns == 4, "critical mode must give each participant a follow-up objection turn")
    print("PASS: new discussion limits, unavailable moderator fallback and critical follow-up round")
}

// Speech length: default medium (800), and the chosen length reaches every AI turn.
do {
    let m = AppModel()
    m.accounts = [Account(id: "len-claude-fake", provider: .claude, name: "Claude", dir: nil),
                  Account(id: "len-codex-fake", provider: .codex, name: "Codex", dir: nil)]
    let chat = Discussion(model: m)
    chat.useGemini = true
    chat.configure { $0.participants = [.claude, .codex, .gemini]; $0.mode = 1; $0.leader = .claude; $0.turnsPerAI = 2 }
    var speeches: [String] = []
    chat.debateAnswer = { _, prompt, _, _, _ in
        if prompt.contains("[MODE3 MODERATION]") { return .success("{\"action\":\"finish\",\"reason\":\"Enough\"}") }
        if prompt.contains("[MODE3 SPEECH]") { speeches.append(prompt) }
        return .success("TL;DR: Point\n\nDetail.")
    }
    chat.draft = "Default length."; chat.send(); waitFor(chat)
    expect(!speeches.isEmpty && speeches.allSatisfy { $0.contains("at most 800 characters") }, "default turn length must be 800")
    speeches.removeAll()
    chat.configure { $0.speechLength = SpeechLength.long }
    chat.draft = "Long turns."; chat.send(); waitFor(chat)
    expect(!speeches.isEmpty && speeches.allSatisfy { $0.contains("at most 1500 characters") }, "chosen long length must reach every speech")
    expect(SpeechLength.clamp(123) == 800 && SpeechLength.clamp(nil) == 800 && SpeechLength.clamp(400) == 400, "length clamp")
    print("PASS: speech length default 800 and chosen length in every AI turn")
}

// Collaboration role sessions continue across different task payloads without resending old images.
do {
    let manager = NativeSessions(), room = UUID(), sid = UUID().uuidString
    let account = Account(id: "school-continuity-fake", provider: .claude, name: "School", dir: AccountStore.accountsDir + "/school-continuity-fake")
    let image = URL(fileURLWithPath: "/tmp/continuity-figure.png")
    var calls: [(Bool, Int, String)] = []
    for (payload, images) in [("source document", [image]), ("write a design", []), ("review a different design", [image])] {
        _ = manager.ask(account, room: room, prompt: payload + "\n[MODE3 SPEECH]\nDo this task", images: images, timeout: 1,
                        token: DebateCancellation(), web: false, speaker: "School", appendContext: true, invoke: { prompt, pictures, call in
            calls.append((call!.resume, pictures.count, prompt))
            call!.observe("{\"type\":\"result\",\"session_id\":\"\(sid)\",\"is_error\":false}")
            return .success("Result")
        }, note: { _ in })
    }
    expect(calls.map { $0.0 } == [false, true, true] && calls.map { $0.1 } == [1, 0, 0], "task sessions must continue and retain previously delivered image IDs")
    expect(!calls[1].2.contains("source document") && !calls[2].2.contains("write a design"), "continuation resent previous tasks")
    print("PASS: collaboration role continuity across tasks, delta payload and image delivery ledger")
}

// Source mutations, exact backup/undo, and external-change conflict protection.
do {
    let root = URL(fileURLWithPath: AccountStore.home).appendingPathComponent("backup-fixture")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try "ORIGINAL".write(to: root.appendingPathComponent("edit.txt"), atomically: true, encoding: .utf8)
    try "DELETE".write(to: root.appendingPathComponent("delete.txt"), atomically: true, encoding: .utf8)
    let binding = WorkspaceBinding(roots: [WorkspaceRoot(path: root.path, directory: true)], level: .write)
    var backup = try WorkspaceBackup.begin(binding, room: UUID(), runID: UUID())
    try "MODIFIED".write(to: root.appendingPathComponent("edit.txt"), atomically: true, encoding: .utf8)
    try "CREATED".write(to: root.appendingPathComponent("new.txt"), atomically: true, encoding: .utf8)
    try FileManager.default.removeItem(at: root.appendingPathComponent("delete.txt"))
    try backup.finish()
    expect(Set(backup.changes.map { $0.kind }) == Set(["added","modified","deleted"]), "actual diff kinds wrong")
    try "LATER".write(to: root.appendingPathComponent("edit.txt"), atomically: true, encoding: .utf8)
    do { try backup.restore(); fatalError("overwrote external edits") } catch {}
    try "MODIFIED".write(to: root.appendingPathComponent("edit.txt"), atomically: true, encoding: .utf8)
    try backup.restore()
    let restoredStamps = try WorkspaceBackup.stamps(binding.roots)
    expect(restoredStamps == backup.before, "restored source hashes differ")
    expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("new.txt").path), "undo left created file")
    print("PASS: backup, actual add/edit/delete list, conflict refusal and exact hash undo")
}

// Fresh/resume permissions are explicit at every invocation; no broad bypass flags.
do {
    let root = URL(fileURLWithPath: AccountStore.home).appendingPathComponent("permission-fixture")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let binding = WorkspaceBinding(roots: [WorkspaceRoot(path: root.path, directory: true)], level: .execute)
    let room = UUID(), backup = try WorkspaceBackup.begin(binding, room: room, runID: UUID())
    let invocation = WorkspaceInvocation(binding: binding, room: room, readOnly: false, backupPath: backup.directory)
    let dir = NativeSessions.directory(room).appendingPathComponent("test")
    let original = ["-c", "sandbox_mode=\"read-only\"", "exec", "resume", "fake-session", "question"]
    let resume = try invocation.arguments(provider: .codex, original: original, directory: dir, web: true)
    expect(resume.contains("sandbox_mode=\"workspace-write\"") && resume.contains("features.shell_tool=true"), "resume lost execution sandbox")
    expect(resume.contains("sandbox_workspace_write.exclude_slash_tmp=true") && resume.contains("sandbox_workspace_write.exclude_tmpdir_env_var=true"), "unexpected writable tmp roots")
    let claude = try invocation.arguments(provider: .claude, original: ["--tools", "", "--mcp-config", "{}"], directory: dir, web: true)
    expect(claude.contains(where: { $0.contains("Bash") }) && claude.contains("--settings") && !claude.contains("--dangerously-skip-permissions"), "execution must stay sandboxed")
    let viewing = WorkspaceInvocation(binding: binding, room: room, readOnly: true)
    let read = try viewing.arguments(provider: .codex, original: original, directory: dir, web: true)
    expect(read.contains("sandbox_mode=\"read-only\"") && read.contains("features.shell_tool=false"), "review must remain read-only even in execution room")
    let agy = try viewing.arguments(provider: .gemini, original: ["-p","test","--sandbox","--disable-slash-commands"], directory: dir, web: true)
    expect(!agy.contains("--disable-slash-commands") && agy.contains("plan"), "agy mode disabled by conflicting slash flag")
    print("PASS: explicit resume sandbox, linked write roots, no temporary roots and read-only review")
}

// Explicit participants, repeated tasks on one account, task-ID prerequisites, no forced assignments.
do {
    let m = AppModel()
    m.accounts = [Account(id: "chosen", provider: .claude, name: "Chosen", dir: nil), Account(id: "not-chosen", provider: .codex, name: "Unused", dir: nil)]
    let chat = Discussion(model: m)
    chat.useGemini = true
    chat.configure { $0.participants = [.claude, .codex, .gemini]; $0.mode = 3 }
    var calls = 0, work: [String] = []
    chat.collaborationAnswer = { _, _, _, _ in calls += 1; return .success("Unexpected") }
    chat.draft = "한국어로 작업해줘"; chat.send(); waitFor(chat)
    expect(calls == 0, "nil account selection must not run all accounts")
    chat.configure { $0.accountIDs = ["chosen"] }
    chat.collaborationAnswer = { account, prompt, _, _ in
        expect(account.id == "chosen", "unselected account called")
        if prompt.contains("[COLLAB PLAN]") { return .success("{\"assignments\":[{\"id\":\"first\",\"accountID\":\"chosen\",\"task\":\"자료 확인\"},{\"id\":\"second\",\"accountID\":\"chosen\",\"task\":\"초안\",\"dependsOn\":[\"first\"]}]}") }
        if prompt.contains("[Your assignment]") {
            if prompt.contains("Task ID: second") { expect(prompt.contains("[Prerequisite result: first]"), "task prerequisite missing"); work.append("second") }
            else { work.append("first") }
        }
        return .success("한국어 결과 [source: https://example.org]")
    }
    chat.draft = "한국어로 두 작업을 이어서 해줘"; chat.send(); waitFor(chat)
    expect(work == ["first","second"], "one account must support multiple task IDs")
    expect(chat.current.turns.last?.tasks?.compactMap(\.planID) == ["first","second"], "task IDs must persist separately from accounts")
    chat.collaborationAnswer = { _, prompt, _, _ in
        if prompt.contains("[COLLAB PLAN]") { return .success("{\"assignments\":[{\"id\":\"cycle\",\"accountID\":\"chosen\",\"task\":\"bad\",\"dependsOn\":[\"cycle\"]}]}") }
        fatalError("invalid cyclic plan executed")
    }
    chat.draft = "Invalid plan test"; chat.send(); waitFor(chat)
    expect(chat.current.turns.last?.error != nil, "invalid plan must fail visibly")
    print("PASS: explicit account selection, task DAG, multiple tasks per account and cycle rejection")
}

// Stop also kills a shell's child writer, so no delayed changes occur after diff capture.
do {
    let target = URL(fileURLWithPath: AccountStore.home).appendingPathComponent("late-writer")
    let script = URL(fileURLWithPath: AccountStore.home).appendingPathComponent("late-writer.sh")
    try "#!/bin/sh\n(sleep 1; echo BAD > \"$1\") &\nwait\n".write(to: script, atomically: true, encoding: .utf8)
    let process = Process(); process.executableURL = URL(fileURLWithPath: "/bin/sh"); process.arguments = [script.path,target.path]
    try process.run(); Thread.sleep(forTimeInterval: 0.15)
    DebateCancellation.end(process); process.waitUntilExit(); Thread.sleep(forTimeInterval: 1.1)
    expect(!FileManager.default.fileExists(atPath: target.path), "child writer survived Stop")
    print("PASS: Stop terminates descendant writers")
}

// Git working state (including untracked files) is recoverable without resetting the user's checkout.
do {
    let root = URL(fileURLWithPath: AccountStore.home).appendingPathComponent("git-backup-fixture")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try WorkspaceBackup.run("/usr/bin/git", ["init", root.path])
    try "committed".write(to: root.appendingPathComponent("tracked"), atomically: true, encoding: .utf8)
    try WorkspaceBackup.run("/usr/bin/git", ["-C",root.path,"add","tracked"])
    try WorkspaceBackup.run("/usr/bin/git", ["-C",root.path,"-c","user.name=Fixture","-c","user.email=fixture@example.invalid","commit","-m","fixture"])
    try "dirty".write(to: root.appendingPathComponent("tracked"), atomically: true, encoding: .utf8)
    try "untracked".write(to: root.appendingPathComponent("untracked"), atomically: true, encoding: .utf8)
    let binding = WorkspaceBinding(roots: [WorkspaceRoot(path: root.path, directory: true)], level: .write)
    var backup = try WorkspaceBackup.begin(binding, room: UUID(), runID: UUID())
    expect(!backup.gitStates.isEmpty, "git state not recorded")
    try FileManager.default.removeItem(at: root.appendingPathComponent("tracked"))
    try backup.finish(); try backup.restore()
    let restored = try WorkspaceBackup.stamps(binding.roots)
    expect(restored == backup.before, "git working state and untracked hashes not restored")
    let inventory = binding.inventory()
    expect(inventory.contains { $0.hasSuffix("/tracked") }, "inventory must use unambiguous full file paths")
    print("PASS: git dirty state, untracked preservation and absolute inventory paths")
}

// Deleting a chat removes exactly this room's session transcripts and backups, nothing else.
do {
    let fm = FileManager.default
    let room = UUID()
    let claudeDir = AccountStore.accountsDir + "/purge-claude", codexDir = AccountStore.accountsDir + "/purge-codex"
    let claude = Account(id: "purge-claude", provider: .claude, name: "C", dir: claudeDir)
    let codex = Account(id: "purge-codex", provider: .codex, name: "X", dir: codexDir)
    let saved = AccountStore.load()
    AccountStore.save(saved + [claude, codex])
    let cid = UUID().uuidString.lowercased(), xid = UUID().uuidString.lowercased(), other = UUID().uuidString.lowercased()
    let project = claudeDir + "/projects/-tmp-rooms-" + room.uuidString + "-s1"
    try fm.createDirectory(atPath: project + "/" + cid, withIntermediateDirectories: true)
    try "x".write(toFile: project + "/" + cid + ".jsonl", atomically: true, encoding: .utf8)
    try fm.createDirectory(atPath: claudeDir + "/projects/-other", withIntermediateDirectories: true)
    try "keep".write(toFile: claudeDir + "/projects/-other/" + other + ".jsonl", atomically: true, encoding: .utf8)
    try "login".write(toFile: claudeDir + "/.claude.json", atomically: true, encoding: .utf8)
    try fm.createDirectory(atPath: codexDir + "/sessions/2026/10/23", withIntermediateDirectories: true)
    try "x".write(toFile: codexDir + "/sessions/2026/10/23/rollout-2026-10-23-" + xid + ".jsonl", atomically: true, encoding: .utf8)
    try "keep".write(toFile: codexDir + "/sessions/2026/10/23/rollout-2026-10-23-" + other + ".jsonl", atomically: true, encoding: .utf8)
    try "auth".write(toFile: codexDir + "/auth.json", atomically: true, encoding: .utf8)
    let ledger = NativeSessions.directory(room)
    try fm.createDirectory(at: ledger, withIntermediateDirectories: true)
    let records = [NativeSessions.Record(accountID: claude.id, provider: .claude, role: "speaker", nativeID: cid),
                   NativeSessions.Record(accountID: codex.id, provider: .codex, role: "speaker", nativeID: xid)]
    try JSONEncoder().encode(records).write(to: ledger.appendingPathComponent("ownership.json"))
    // A backup of a linked git folder, with the app's ref marker.
    let repo = AccountStore.home + "/purge-repo", runID = UUID()
    try fm.createDirectory(atPath: repo, withIntermediateDirectories: true)
    try "v1".write(toFile: repo + "/a.txt", atomically: true, encoding: .utf8)
    for args in [["init", "-q"], ["-c", "user.email=t@t", "-c", "user.name=t", "add", "."], ["-c", "user.email=t@t", "-c", "user.name=t", "commit", "-qm", "init"]] {
        try WorkspaceBackup.run("/usr/bin/git", ["-C", repo] + args)
    }
    let head = try WorkspaceBackup.run("/usr/bin/git", ["-C", repo, "rev-parse", "HEAD"])
    try WorkspaceBackup.run("/usr/bin/git", ["-C", repo, "update-ref", "refs/ai-illuminati/" + runID.uuidString, head])
    let runFolder = WorkspaceBackup.base.appendingPathComponent(room.uuidString).appendingPathComponent(runID.uuidString)
    try fm.createDirectory(at: runFolder, withIntermediateDirectories: true)
    let backup = WorkspaceBackup(directory: runFolder.path, roots: [WorkspaceRoot(path: repo, directory: true)], before: [:])
    try backup.save()
    var conversation = Conversation(); conversation.id = room
    try ChatStore.delete(conversation)
    expect(!fm.fileExists(atPath: project + "/" + cid + ".jsonl") && !fm.fileExists(atPath: project + "/" + cid) && !fm.fileExists(atPath: project),
           "room's Claude session must be deleted")
    expect(!fm.fileExists(atPath: codexDir + "/sessions/2026/10/23/rollout-2026-10-23-" + xid + ".jsonl"), "room's Codex session must be deleted")
    expect(fm.fileExists(atPath: claudeDir + "/projects/-other/" + other + ".jsonl") && fm.fileExists(atPath: codexDir + "/sessions/2026/10/23/rollout-2026-10-23-" + other + ".jsonl"),
           "other sessions must be kept")
    expect(fm.fileExists(atPath: claudeDir + "/.claude.json") && fm.fileExists(atPath: codexDir + "/auth.json"), "logins must be kept")
    expect(!fm.fileExists(atPath: ledger.path), "room session folder must be deleted")
    expect(!fm.fileExists(atPath: WorkspaceBackup.base.appendingPathComponent(room.uuidString).path), "room backups must be deleted")
    expect((try? WorkspaceBackup.run("/usr/bin/git", ["-C", repo, "rev-parse", "--verify", "-q", "refs/ai-illuminati/" + runID.uuidString])) == nil,
           "backup git marker must be removed")
    expect(fm.fileExists(atPath: repo + "/a.txt"), "linked folder must be kept")
    AccountStore.save(saved)
    print("PASS: chat delete removes only its sessions, session folder, backups and git marker; keeps logins, other sessions and linked folders")
}

// Update status text for each state (the update steps themselves need git and are checked live).
do {
    expect(Updater.describe(["status": "current", "current": "abcdef1234"]).contains("abcdef1"), "current version text")
    expect(Updater.describe(["status": "updated", "previous": "1111111aaa", "current": "2222222bbb"]).contains("1111111")
           && Updater.describe(["status": "updated", "previous": "1111111aaa", "current": "2222222bbb"]).contains("2222222"), "updated text")
    for state in ["checking", "testing", "building", "waiting", "postponed", "local-changes", "local-commits", "unavailable", "failed"] {
        expect(!Updater.describe(["status": state]).isEmpty, "status text for " + state)
    }
    print("PASS: update status texts")
}

// Pictures: Claude's SVG and Codex's generated image become stored pictures, shown with markers,
// and are passed to everyone who speaks afterwards (moderator now, all AIs in the next question).
do {
    let m = AppModel()
    let codexDir = AccountStore.accountsDir + "/pic-codex"
    m.accounts = [Account(id: "pic-claude", provider: .claude, name: "Claude", dir: nil),
                  Account(id: "pic-codex", provider: .codex, name: "Codex", dir: codexDir)]
    let chat = Discussion(model: m)
    chat.newConversation()
    chat.configure { $0.participants = [.claude, .codex]; $0.mode = 1; $0.leader = .claude; $0.turnsPerAI = 2; $0.keepSessions = false }
    let png = Pictures.render(svg: "<svg viewBox='0 0 10 10'><rect width='10' height='10' fill='green'/></svg>")!
    let promptLock = NSLock()
    var prompts: [String] = []
    chat.debateAnswer = { account, prompt, _, _, _ in
        promptLock.lock(); prompts.append(prompt); promptLock.unlock()
        if prompt.contains("[MODE3 MODERATION]") { return .success("{\"action\":\"finish\",\"reason\":\"Done\"}") }
        if prompt.contains("[MODE3 FINAL]") { return .success("가장 좋은 그림은 [그림 2]입니다.") }
        if account.provider == .claude {
            return .success("TL;DR: 사과\n\n사과를 그렸어요.\n```svg\n<svg viewBox='0 0 10 10'><circle cx='5' cy='5' r='4' fill='red'/></svg>\n```\n끝.")
        }
        let folder = codexDir + "/generated_images/thread-1"
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try? png.write(to: URL(fileURLWithPath: folder + "/exec-1.png"))
        return .success("TL;DR: 그렸어요\n\n초록 네모를 그렸어요.")
    }
    var pictureCounts: [Int] = []
    chat.pictureAnswer = { account, prompt, pictures, timeout, token, web in
        promptLock.lock(); pictureCounts.append(pictures.count); promptLock.unlock()
        return chat.debateAnswer(account, prompt, timeout, token, web)
    }
    chat.draft = "사과 그림 그려줘"; chat.send(); waitFor(chat)
    let turn = chat.current.turns[0]
    let claudeEntry = turn.entries.first { $0.speaker.hasPrefix("Claude") }!
    let codexEntry = turn.entries.first { $0.speaker.hasPrefix("ChatGPT") }!
    expect(claudeEntry.images?.count == 1 && !claudeEntry.text.contains("<svg") && claudeEntry.text.contains("[그림") || claudeEntry.text.contains("[Picture"),
           "Claude's SVG must become a stored picture with a marker")
    expect(codexEntry.images?.count == 1, "Codex's generated image must be collected")
    let all = turn.entries.flatMap { $0.images ?? [] }
    expect(Set(all.map(\.name)) == ["picture-1.png", "picture-2.png"] && all.allSatisfy { FileManager.default.fileExists(atPath: $0.url.path) },
           "pictures are numbered and stored with the chat")
    let moderation = prompts.first { $0.contains("[MODE3 MODERATION]") } ?? ""
    expect(moderation.contains("drawn by") && pictureCounts.contains(2), "the moderator must receive the pictures")
    expect(prompts.contains { $0.contains("Pictures: only when the user asks") }, "speakers are told how to make pictures")
    prompts.removeAll()
    chat.draft = "두 그림 중 뭐가 나아?"; chat.send(); waitFor(chat)
    let opening = prompts.filter { $0.contains("[MODE3 SPEECH]") }
    expect(!opening.isEmpty && opening.allSatisfy { $0.contains("Image 1: picture-") && $0.contains("Image 2: picture-") },
           "pictures from earlier messages go to every AI in the next question")
    expect(chat.current.turns.last?.entries.allSatisfy { ($0.images ?? []).isEmpty || $0.images!.allSatisfy { $0.name.hasPrefix("picture-") } } == true,
           "numbering continues")
    print("PASS: AI pictures (SVG and generated files) are stored, marked, shown and shared with later speakers")
}

// Pin to top and delete all.
do {
    let m = AppModel()
    let chat = Discussion(model: m)
    chat.removeChats(chat.conversations.filter(\.hasContent))
    var made: [UUID] = []
    for title in ["A", "B", "C"] {
        var c = Conversation(); c.title = title; c.turns = [ChatTurn(question: title)]
        ChatStore.save(c); chat.conversations.insert(c, at: 0); made.append(c.id)
    }
    chat.togglePin(made[0])   // "A" is the oldest
    expect(chat.listedConversations.first?.id == made[0], "pinned chat must be listed first")
    let reloaded = Discussion(model: m)
    expect(reloaded.conversations.first { $0.id == made[0] }?.pinned == true, "pin must be saved")
    expect(reloaded.listedConversations.first?.id == made[0], "pinned chat first after reopening")
    chat.togglePin(made[0])
    expect(chat.conversations.first { $0.id == made[0] }?.pinned == nil, "unpin")
    chat.togglePin(made[1])
    // "Keep pinned" path of delete all.
    let failed = chat.removeChats(chat.conversations.filter { $0.hasContent && $0.pinned != true })
    expect(failed == 0 && chat.conversations.filter(\.hasContent).map(\.id) == [made[1]], "delete all keeping pinned")
    expect(!FileManager.default.fileExists(atPath: ChatStore.dir + "/\(made[0].uuidString).json") && FileManager.default.fileExists(atPath: ChatStore.dir + "/\(made[1].uuidString).json"),
           "files of deleted chats removed, pinned kept")
    chat.removeChats(chat.conversations.filter(\.hasContent))
    expect(chat.conversations.count == 1 && chat.conversations[0].turns.isEmpty && chat.currentID == chat.conversations[0].id, "after deleting all, one empty new chat")
    expect(!ChatStore.loadAll().contains { made.contains($0.id) }, "none of the deleted chats remain saved")
    // A chat with only settings is not kept once you leave it; a new window reuses the newest one.
    chat.configure { $0.turnsPerAI = 3 }
    let blankID = chat.currentID
    let again = Discussion(model: m)
    expect(again.currentID == blankID && again.configuration.turnsPerAI == 3 && again.conversations.filter { !$0.hasContent }.count == 1,
           "newest settings-only chat becomes the new chat, no pile-up")
    expect(ChatConfiguration().sessionsOn && !ChatConfiguration(keepSessions: false).sessionsOn, "sessions are on unless turned off")
    print("PASS: pin to top (order, saved, unpin) and delete all (all or keep pinned)")
}


// Menu bar limit choice: 5-hour by default; each choice reads only its own limit.
do {
    var u = AIUsage(name: "x")
    u.fiveHour = UsageWindow(usedPercent: 80, resetsAt: Date().addingTimeInterval(3600))
    u.weekly = UsageWindow(usedPercent: 33, resetsAt: Date().addingTimeInterval(86400))
    expect(AppModel.MenuBarWindow.fiveHour.left(u) == 20 && AppModel.MenuBarWindow.weekly.left(u) == 67, "menu bar limit choice")
    var g = AIUsage(name: "g"); g.weekly = UsageWindow(usedPercent: 6, resetsAt: nil)
    expect(AppModel.MenuBarWindow.fiveHour.left(g) == 100 && AppModel.MenuBarWindow.fiveHour.hasNoLimit(g), "a plan without this limit counts as full")
    expect(AppModel.MenuBarWindow.weekly.left(AIUsage(name: "unread")) == nil, "no reading stays empty")
    UserDefaults.standard.removeObject(forKey: "menuBarWindow")
    expect(AppModel().menuBarWindow == .fiveHour, "default is 5-hour")
    print("PASS: menu bar 5-hour / weekly choice")
}

// Poker: hand ranking, betting rules, side pots, AI answers and a full fake game.
do {
    func c(_ s: String) -> [Card] { s.split(separator: " ").map { Card(String($0))! } }
    func v(_ s: String) -> HandValue { HandEvaluator.best(c(s)) }
    expect(v("As Ks Qs Js Ts 2d 3c").category == 8 && v("As Ks Qs Js Ts").name == L("로열 플러시", "Royal flush"), "royal flush")
    expect(v("Ah 2d 3c 4s 5h 9d Kc") == HandValue(category: 4, ranks: [5]), "wheel straight is 5-high")
    expect(v("Kh Kd Kc 2s 2h 9d 9c") > v("Ah Qh 9h 4h 2h 3d 3c"), "full house beats flush")
    expect(v("Kh Kd 7c 7s 2h 9d 3c") < v("Kh Kd 7c 7s 2h Ad 3c"), "two pair kicker")
    expect(v("Ah Ad 7c 6s 2h") == v("As Ac 7d 6h 2c"), "same hand ties")
    expect(v("2h 2d 2c 3s 3h 3d Ac") == HandValue(category: 6, ranks: [3, 2]), "two trips make the best full house")

    // A deck where each seat gets the given cards and the board comes out as given.
    func rig(_ holes: [String], dealer: Int, board: String) -> [Card] {
        let hs = holes.map(c), b = c(board)
        var order: [Card] = []
        for round in 0..<2 { for k in 1...hs.count { order.append(hs[(dealer + k) % hs.count][round]) } }
        let rest = Card.fullDeck.filter { !hs.joined().contains($0) && !b.contains($0) }
        order += [rest[0]] + b.prefix(3) + [rest[1], b[3], rest[2], b[4]] + rest.dropFirst(3)
        return order
    }
    func seat(_ id: String, _ chips: Int) -> PokerSeat { PokerSeat(id: id, name: id, isHuman: false, chips: chips) }

    // Heads-up: the dealer posts the small blind and acts first before the flop, last after it.
    var h = PokerHand(seats: [seat("A", 1000), seat("B", 1000)], dealer: 0, smallBlind: 10, bigBlind: 20,
                      deck: rig(["Ah Ad", "Kc Kd"], dealer: 0, board: "2s 7h 9c Jd 3s"))
    expect(h.seats[0].hole == c("Ah Ad") && h.seats[1].hole == c("Kc Kd"), "rigged deal")
    expect(h.seats[0].bet == 10 && h.seats[1].bet == 20 && h.toAct == 0 && h.pot == 30, "heads-up blinds")
    expect(h.legal(.check, for: 0) == .fold && h.legal(.raise(25), for: 0) == .raise(40) && h.legal(.raise(5000), for: 0) == .raise(1000), "legal actions")
    h.apply(.call, by: 0)
    expect(h.toAct == 1 && h.street == .preflop, "big blind keeps the option")
    h.apply(.raise(60), by: 1)
    expect(h.toAct == 0 && h.minRaiseTo(0) == 100, "re-raise minimum")
    h.apply(.call, by: 0)
    expect(h.street == .flop && h.board == c("2s 7h 9c") && h.toAct == 1 && h.pot == 120, "flop dealt, non-dealer first")
    h.apply(.check, by: 1); h.apply(.raise(50), by: 0); h.apply(.call, by: 1)
    expect(h.street == .turn && h.pot == 220, "turn")
    h.apply(.check, by: 1); h.apply(.check, by: 0)
    h.apply(.check, by: 1); h.apply(.check, by: 0)
    expect(h.finished && h.street == .showdown && h.wins == [PokerWin(seat: 0, amount: 220, hand: L("원페어", "One pair"))], "showdown winner")
    expect(h.seats[0].chips == 1110 && h.seats[1].chips == 890, "chips after showdown")

    // Fold ends the hand at once.
    var f = PokerHand(seats: [seat("A", 1000), seat("B", 1000), seat("C", 1000)], dealer: 0, smallBlind: 10, bigBlind: 20, deck: Card.fullDeck)
    expect(f.toAct == 0, "three-handed: dealer acts first preflop")
    f.apply(.fold, by: 0); f.apply(.fold, by: 1)
    expect(f.finished && f.seats[2].chips == 1010 && f.seats[1].chips == 990, "everyone folded to the big blind")

    // Side pot: the short all-in stack can win only what it matched.
    var s = PokerHand(seats: [seat("A", 100), seat("B", 500), seat("C", 500)], dealer: 2, smallBlind: 10, bigBlind: 20,
                      deck: rig(["As Ah", "Ks Kh", "2c 7d"], dealer: 2, board: "3s 8h 9c Jd 4s"))
    expect(s.toAct == 2, "first to act after the big blind")
    s.apply(.call, by: 2); s.apply(.raise(100), by: 0)
    expect(s.seats[0].allIn, "short stack is all in")
    s.apply(.raise(300), by: 1); s.apply(.call, by: 2)
    expect(s.street == .flop && s.pots().map(\.amount) == [300, 400], "main pot and side pot")
    s.apply(.check, by: 1); s.apply(.check, by: 2); s.apply(.check, by: 1); s.apply(.check, by: 2); s.apply(.check, by: 1); s.apply(.check, by: 2)
    expect(s.finished && s.seats.map(\.chips) == [300, 600, 200], "short stack wins main, next best wins side")

    // Everyone all in: the board runs out with no more questions.
    let r = PokerHand(seats: [seat("A", 15), seat("B", 20)], dealer: 0, smallBlind: 10, bigBlind: 20, deck: rig(["2c 3d", "Ac Ad"], dealer: 0, board: "Ks Qh 9c 7d 5s"))
    var r2 = r; r2.apply(.call, by: 0)
    expect(r2.finished && r2.board.count == 5 && r2.seats.map(\.chips) == [0, 35], "all in runs out the board; unmatched chips go back")

    // AI answers.
    let p = PokerHand(seats: [seat("A", 1000), seat("B", 1000)], dealer: 0, smallBlind: 10, bigBlind: 20, deck: rig(["Ah Ad", "Kc Kd"], dealer: 0, board: "2s 7h 9c Jd 3s"))
    expect(PokerAI.parse("{\"action\":\"raise\",\"amount\":80,\"reason\":\"좋은 패\"}", hand: p, seat: 0) == .init(action: .raise(80), reason: "좋은 패", usable: true), "JSON answer")
    expect(PokerAI.parse("Sure! ```json\n{\"action\":\"CALL\",\"amount\":0,\"reason\":\"x\"}\n```", hand: p, seat: 0).action == .call, "JSON inside text")
    expect(PokerAI.parse("I will fold here.", hand: p, seat: 0).action == .fold, "plain words")
    expect(PokerAI.parse("{\"action\":\"raise\",\"amount\":3}", hand: p, seat: 0).action == .raise(40), "small raise becomes the minimum")
    let bad = PokerAI.parse("hmm", hand: p, seat: 0)
    expect(bad.action == .fold && !bad.usable, "unreadable answer folds when a bet is owed")
    let promptA = PokerAI.prompt(p, seat: 0)
    expect(promptA.contains("A♥ A♦") && !promptA.contains("K♣") && !promptA.contains("K♦"), "an AI sees only its own cards")

    // A whole game between two fake AIs, saved to poker.json.
    try? FileManager.default.removeItem(at: PokerStore.file)
    let pm = AppModel()
    pm.accounts = [Account(id: "p1", provider: .claude, name: "Claude P", dir: nil), Account(id: "p2", provider: .codex, name: "GPT P", dir: nil)]
    let game = PokerGame(model: pm)
    game.withMe = false
    game.autoNext = false
    var prompts: [String] = []
    game.answer = { account, prompt in
        prompts.append(prompt)
        return .success(account.id == "p1" ? "{\"action\":\"call\",\"reason\":\"콜\"}" : "{\"action\":\"check\",\"reason\":\"체크\"}")
    }
    expect(game.chosenAI == ["p1", "p2"] && game.canStart, "setup")
    game.start()
    let deadline = Date().addingTimeInterval(5)
    while game.hand?.finished != true && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
    expect(game.hand?.finished == true && prompts.count >= 2, "fake hand finished")
    expect(game.seats.map(\.chips).reduce(0, +) == 2000 && PokerStore.load()["p1"]?.hands == 1, "chips kept and saved")
    expect(game.hand!.events.contains { $0.reason == "콜" }, "reasons kept for after the hand")
    game.stop()
    print("PASS: poker (ranking, betting, side pots, AI answers, saved chips)")
}
