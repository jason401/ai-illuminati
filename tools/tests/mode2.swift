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
Discussion.modernModes = false
Discussion.availableModes = [1, 2, 3]
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
capped.configure { $0.mode = 3; $0.turnsPerAI = 2 }
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
exhausted.configure { $0.mode = 3; $0.turnsPerAI = 3 }
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
broken.configure { $0.mode = 3 }
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
stopped.configure { $0.mode = 3 }
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
    chat.configure { $0.mode = 3; $0.leaderAccountID = "claude-test" }
    var assigned: Set<String> = [], active = 0, maximum = 0
    let lock = NSLock()
    chat.collaborationAnswer = { account, prompt, _, _ in
        if prompt.contains("[COLLAB PLAN]") { return .success("{\"assignments\":[{\"accountID\":\"personal-test\",\"task\":\"Design option\"},{\"accountID\":\"school-test\",\"task\":\"Cost analysis\"},{\"accountID\":\"claude-test\",\"task\":\"Risk analysis\"}]}") }
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
    print("PASS: large DOCX, images, PPTX order/notes, general-purpose parallel all-account collaboration and saved artifacts")
}

// A dependent account runs only after its prerequisite. Reuse source notes on follow-up.
do {
    let m = AppModel()
    m.accounts = [Account(id: "school-claude-fake", provider: .claude, name: "School Claude", dir: nil),
                  Account(id: "school-codex-fake", provider: .codex, name: "School Codex", dir: nil)]
    let chat = Discussion(model: m)
    chat.configure { $0.mode = 3; $0.leaderAccountID = "school-claude-fake" }
    let fixture = URL(fileURLWithPath: AccountStore.home).appendingPathComponent("material-fixtures/slides.pptx")
    let document = try! MaterialReader.read(fixture, room: chat.currentID)
    chat.change(chat.currentID, save: true) { $0.documents = [document] }
    var sourceCalls = 0, order: [String] = []
    chat.collaborationAnswer = { account, prompt, _, _ in
        if prompt.contains("[COLLAB PLAN]") {
            return .success("{\"assignments\":[{\"accountID\":\"school-claude-fake\",\"task\":\"Requirements\",\"dependsOn\":[]},{\"accountID\":\"school-codex-fake\",\"task\":\"Proposal\",\"dependsOn\":[\"school-claude-fake\"]}]}")
        }
        if prompt.contains("[COLLAB SOURCE]") { sourceCalls += 1 }
        if prompt.contains("[Your assignment]") {
            order.append(account.id)
            if account.id == "school-codex-fake" {
                expect(prompt.contains("[Completed prerequisites]") && prompt.contains("[Prerequisite result: school-claude-fake]"), "dependent worker missing prerequisite result")
            }
        }
        return .success("Evidence-backed contribution with source IDs.")
    }
    chat.draft = "Create a design proposal."; chat.send(); waitFor(chat)
    expect(order == ["school-claude-fake", "school-codex-fake"], "dependency order wrong")
    let initial = sourceCalls
    expect(initial == document.units!.count, "not all material parts covered")
    order = []
    chat.draft = "Refine the same design proposal."; chat.send(); waitFor(chat)
    expect(sourceCalls == initial, "unchanged material notes must be reused on follow-up")
    expect(chat.current.turns.last?.endReason?.contains("reused index notes") == true, "coverage/reuse must be visible")
    print("PASS: prerequisite ordering, prerequisite outputs, complete source coverage and persistent index reuse")
}

// New discussion/critical mode limits and an unavailable visual moderator fallback.
do {
    let m = AppModel()
    m.accounts = [Account(id: "mode-school-claude-fake", provider: .claude, name: "School Claude", dir: nil),
                  Account(id: "mode-school-codex-fake", provider: .codex, name: "School Codex", dir: nil)]
    let chat = Discussion(model: m)
    chat.configure { $0.mode = 1; $0.leader = .gemini; $0.turnsPerAI = 2 }
    chat.debateAnswer = { _, prompt, _, _, _ in
        if prompt.contains("[MODE3 MODERATION]") { return .success("{\"action\":\"finish\",\"reason\":\"Enough evidence\"}") }
        return .success("TL;DR: A contribution\n\nA concrete contribution.")
    }
    chat.draft = "Discuss a design."; chat.send(); waitFor(chat)
    expect(chat.current.turns[0].maxTurns == 4 && chat.current.turns[0].final != nil, "new mode limits or missing moderator fallback wrong")
    chat.configure { $0.mode = 2 }
    chat.draft = "Critique the design."; chat.send(); waitFor(chat)
    expect(chat.current.turns[1].entries.count == 4 && chat.current.turns[1].maxTurns == 4, "critical mode must give each participant a follow-up objection turn")
    print("PASS: new discussion limits, unavailable moderator fallback and critical follow-up round")
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
