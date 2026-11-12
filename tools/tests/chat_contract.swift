import Foundation
import AIAccounts
import AIChat

// The promises of Chat (AIChat), checked from outside with only its public API: chats saved by older builds
// (tools/tests/chat_fixtures, with their old keys: keepSessions, school, maxTurns, peerReview…) are read as they were
// and saved again with the same content as before the module existed (the *.saved.json files were written by the
// app's own ChatStore at f05fd72); a blank chat is not kept; files are 0600; delete goes through ChatStore.links in
// order and a failure keeps what follows; the record helpers (Entry.reply, shortLine, SpeechLength, ChatTime).
// Run with AI_ILLUMINATI_TEST_HOME set to an empty folder and CHAT_FIXTURES to the fixture folder (run_mode2.sh).
func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fatalError("FAIL: " + message) }
}
let fm = FileManager.default
let env = ProcessInfo.processInfo.environment
let home = env["AI_ILLUMINATI_TEST_HOME"] ?? "", fixtures = env["CHAT_FIXTURES"] ?? ""
expect(!home.isEmpty && AccountStore.home == home, "the chat test needs its own home")
expect(ChatStore.dir == home + "/Library/Application Support/AI Illuminati/chats", "chats live in the data folder's chats/")
try! fm.createDirectory(atPath: ChatStore.dir, withIntermediateDirectories: true)
let names = try! fm.contentsOfDirectory(atPath: fixtures).filter { $0.hasSuffix(".json") && !$0.hasSuffix(".saved.json") }.sorted()
expect(names.count == 3, "three fixture chats")
for name in names { try! fm.copyItem(atPath: fixtures + "/" + name, toPath: ChatStore.dir + "/" + name) }
try! Data("{ not a chat".utf8).write(to: URL(fileURLWithPath: ChatStore.dir + "/broken.json"))

// Reading: every chat, newest first; an unreadable file is skipped, not fatal.
let all = ChatStore.loadAll()
expect(all.map(\.title) == ["Project chat", "Meeting", "Oldest discussion"], "all readable chats, newest first: \(all.map(\.title))")
let oldest = all[2], project = all[0], meeting = all[1]
// The oldest shape: no mode on the turn (mode 1), the old total turn limit, the old session and school switches.
let config = oldest.configuration!
expect(config.mode == 1 && config.order == [.claude, .codex, .gemini] && config.participants == [.claude, .codex] && config.leader == .claude,
       "the oldest chat's settings")
expect(config.maxTurns == 6 && config.keepSessions == false && config.school == true && config.sessionsOn, "old keys are read (sessions are on anyway)")
expect(config.turnsPerAI == nil && config.memberIDs == nil && config.accountIDs == nil, "keys the old chat did not have stay unset")
let first = oldest.turns[0]
expect(first.mode == nil && first.askedAt == nil && first.maxTurns == 6 && first.status == "", "the old turn: no mode, no time")
expect(first.entries.map(\.speaker) == ["Claude", "ChatGPT"] && first.entries[1].focus == "access" && first.entries[0].headline == nil,
       "the old turn's speeches")
expect(first.entries[0].shortLine == "A unit of code." && first.final?.hasPrefix("A module") == true && first.finalBy == "Claude",
       "an old speech without a headline shows its first sentence")
expect(oldest.documents == nil && oldest.workspace == nil && oldest.pinned == nil && oldest.enterpriseLock == nil && oldest.hasContent,
       "the old chat has only turns")
// A project chat with most of what a chat keeps.
expect(project.pinned == true && project.shareToDevices == true && project.enterpriseLock?.organization == "학교"
       && project.origin?.deviceName == "Other Mac" && project.origin?.lastTurn == nil, "a locked, synced, pinned chat")
expect(project.workspace?.project?.root == "/tmp/project" && project.workspace?.level == .execute && project.workspace?.fullAuto == true,
       "its project link")
expect(project.documents?.first?.units?.first?.images == ["p1.png"] && project.documents?.first?.notice == "1 page", "its documents and their parts")
let pc = project.configuration!
expect(pc.mode == 0 && pc.memberIDs == ["acct-a", "acct-b"] && pc.leadID == "acct-a" && pc.peerReview == true && pc.peerAccountID == "acct-b"
       && pc.pendingReview == "def456" && pc.lastReviewAt != nil && pc.speechLength == 800 && pc.voteSkippedIDs == ["acct-c"],
       "members, and the older review settings read once to make the reviewer a member")
let work = project.turns[0], opinion = project.turns[1], vote = project.turns[2]
expect(work.route == .work && work.plan?.map(\.status) == [.done, .doing] && work.plan?[1].sub == "[2/11] Modules" && work.plan?[0].ended != nil,
       "a work turn's route and plan")
expect(work.images?.first?.url.path == ChatStore.dir + "/22222222-2222-4222-8222-222222222222.assets/22222222-0000-4000-8000-0000000000E1.png",
       "a picture lives in the chat's .assets folder: \(work.images?.first?.url.path ?? "")")
expect(work.workspaceChanges?.first?.kind == "modified" && work.projectCommitted == true && work.projectPushed == false
       && work.peerNotes?.first?.accountID == "acct-b" && work.peerFolded == true, "the work's changes and reviews")
expect(work.spaceDraft?.reason == "no network" && work.spaceEdits?.first?.version == 3, "the Space the answer made")
expect(opinion.route == .opinion && opinion.routeOne == false && opinion.meetingRoom == meeting.id
       && opinion.moreAnswers?.first?.meeting == meeting.id && opinion.answerNames?.count == 2 && opinion.mentions == ["acct-b"],
       "an opinion turn held as a meeting")
expect(vote.mode == 4 && vote.votes?.map(\.choice) == [1, nil] && vote.voteOptions == ["A", "B"]
       && vote.tasks?.first?.state == "done" && vote.tasks?.first?.expectedFiles == ["a.md"] && vote.partials?["acct-a"] == "…",
       "a vote, its ballots (one without a valid vote) and tasks")
expect(meeting.meetingOf?.room == project.id && meeting.meetingOf?.turn == opinion.id, "a meeting's chat knows what it was held for")

// Saving again keeps the same content as the app before the module (key order is JSONEncoder's own, so compared as JSON).
func object(_ path: String) -> NSObject { try! JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as! NSObject }
var saved: [UUID] = []
ChatStore.links = ChatStore.Links(saved: { saved.append($0.id) })
for chat in all { ChatStore.save(chat) }
expect(saved == all.map(\.id), "every save is told once, in order")
for chat in all {
    let path = ChatStore.dir + "/\(chat.id.uuidString).json"
    expect(object(path) == object(fixtures + "/\(chat.id.uuidString).saved.json"), "\(chat.title) saved as before")
    expect((try! fm.attributesOfItem(atPath: path)[.posixPermissions] as! NSNumber).intValue == 0o600, "a chat file is 0600")
}
// A chat with nothing in it is not written.
let blank = Conversation()
ChatStore.save(blank)
expect(!fm.fileExists(atPath: ChatStore.dir + "/\(blank.id.uuidString).json") && saved.count == all.count && !blank.hasContent,
       "a blank chat is not kept")
var withSettings = Conversation(); withSettings.configuration = ChatConfiguration()
ChatStore.save(withSettings)
expect(fm.fileExists(atPath: ChatStore.dir + "/\(withSettings.id.uuidString).json"), "a chat with only settings is saved (but not listed as content)")

// Delete: what the links name first, in order, then the chat's own places; the first failure keeps it and all after it.
enum Stop: Error { case here }
var heard: [String] = []
let documents = URL(fileURLWithPath: home).appendingPathComponent("documents")
func places(_ id: UUID) -> [String] {
    [ChatStore.dir + "/\(id.uuidString).work/x", documents.path + "/\(id.uuidString)/x", ChatStore.dir + "/\(id.uuidString).assets/x"]
}
func fill(_ id: UUID) {
    for path in places(id) {
        try! fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try! Data("x".utf8).write(to: URL(fileURLWithPath: path))
    }
}
var failAt: String?
ChatStore.links = ChatStore.Links(
    purge: [{ _ in heard.append("sessions"); if failAt == "sessions" { throw Stop.here } }, { _ in heard.append("backups") }],
    documents: { heard.append("documents"); return documents.appendingPathComponent($0.uuidString) },
    deleted: { _ in heard.append("deleted") })
let doomed = project
fill(doomed.id)
failAt = "sessions"
do { try ChatStore.delete(doomed); expect(false, "a failed purge throws") } catch {}
expect(heard == ["sessions"], "a failure stops at once, nothing told: \(heard)")
expect(places(doomed.id).allSatisfy(fm.fileExists) && fm.fileExists(atPath: ChatStore.dir + "/\(doomed.id.uuidString).json"),
       "a failure keeps every place after it")
heard = []; failAt = nil
try! ChatStore.delete(doomed)
expect(heard == ["sessions", "backups", "documents", "deleted"], "sessions, backups, then the documents' folder, deleted last: \(heard)")
expect(!places(doomed.id).contains(where: fm.fileExists) && !fm.fileExists(atPath: ChatStore.dir + "/\(doomed.id.uuidString).work")
       && !fm.fileExists(atPath: documents.path + "/\(doomed.id.uuidString)") && !fm.fileExists(atPath: ChatStore.dir + "/\(doomed.id.uuidString).json"),
       "a delete removes the chat's places")
expect(ChatStore.loadAll().map(\.id) == [withSettings.id, meeting.id, oldest.id], "the rest stays listed")
ChatStore.links = ChatStore.Links()

// The record helpers.
let reply = ChatTurn.Entry.reply(round: 1, speaker: "Claude", text: "**TL;DR:** It works.\n\nThe long part.")
expect(reply.headline == "It works." && reply.text == "The long part." && reply.shortLine == "It works." && !reply.failed, "a reply's TL;DR is its headline")
let plain = ChatTurn.Entry(round: 2, speaker: "Gemini", text: "First sentence here. Second one.", failed: false)
expect(plain.shortLine == "First sentence here." && plain.focus == nil && plain.images == nil, "without a headline, the first sentence")
expect(SpeechLength.clamp(nil) == SpeechLength.unlimited && SpeechLength.clamp(800) == 800 && SpeechLength.clamp(123) == SpeechLength.unlimited,
       "speech lengths are one of the four")
let now = Date()
expect(ChatTime.when(first, last: false, updatedAt: now) == nil && ChatTime.when(first, last: true, updatedAt: now) == now
       && ChatTime.when(work, last: false, updatedAt: now) == work.askedAt, "an old turn's time is the chat's last change only when last")
do { _ = try ImageStore.importImage(Data("no picture".utf8), name: "bad.png", conversationID: UUID()); expect(false, "a bad picture is refused") }
catch ImageStore.Failure.invalid {} catch { expect(false, "a bad picture fails as invalid") }
print("PASS: chat contract")
