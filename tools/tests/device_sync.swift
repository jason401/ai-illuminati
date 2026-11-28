import Foundation
import AIAccounts
import AIChatRecords
import AIProjects
import AIWorkspace
@testable import AIChat

/// Chats from other Macs: two DeviceSync instances share a throwaway folder as two Macs would share iCloud Drive.
func testDeviceSync() {
    let fm = FileManager.default
    let folder = URL(fileURLWithPath: AccountStore.home).appendingPathComponent("device-sync-" + UUID().uuidString)
    defer { try? fm.removeItem(at: folder) }
    var on = DeviceSyncSettings(); on.enabled = true; on.folder = folder.path; on.deviceName = "Mac mini"
    let a = DeviceSync(deviceID: "mac-a", persist: false, settings: on)
    on.deviceName = "MacBook"
    let b = DeviceSync(deviceID: "mac-b", persist: false, settings: on)
    let personal = Account(id: "ds-claude", provider: .claude, name: "Claude", dir: nil)
    let workLock = EnterpriseLock(organization: "work", name: "Work", lockedAt: Date())
    expect(DeviceSync.shared.settings.enabled == false, "chats from other Macs are off until turned on")
    expect(DeviceSync.hardwareID().count == 16 && DeviceSync.hardwareID() == DeviceSync.hardwareID(), "this Mac's ID is stable")
    // Tests never reach the real iCloud Drive: DeviceSync.shared has this Mac's real ID, so with the default folder
    // (settings put back to folder nil) it would write or take down the real devices/<id>/remote.json.
    let realCloud = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Mobile Documents").standardizedFileURL.path
    let testHome = URL(fileURLWithPath: AccountStore.home).standardizedFileURL.path
    let shared = DeviceSync.shared.connectionFile.standardizedFileURL.path
    expect(DeviceSync.defaultFolder.standardizedFileURL.path.hasPrefix(testHome + "/") && !DeviceSync.defaultFolder.standardizedFileURL.path.hasPrefix(realCloud)
           && shared.hasPrefix(testHome + "/") && !shared.hasPrefix(realCloud), "the default sync folder is under the test home, not the real iCloud Drive: \(shared)")

    // A chat with this Mac's paths, pictures and a reply still being written.
    var chat = Conversation()
    chat.title = "Lens notes"
    var config = ChatConfiguration(); config.mode = 0; config.modeVersion = 2
    chat.configuration = config
    var done = ChatTurn(question: "FIRST question")
    done.mode = 0; done.modeVersion = 2
    done.final = "FIRST answer"; done.finalBy = "Claude"
    done.images = [ChatImage(conversationID: chat.id, name: "photo.png")]
    done.backupPath = "/Users/someone/backup"; done.artifact = "/Users/someone/result.pdf"
    done.workspaceChanges = [WorkspaceChange(path: "/Users/someone/file.txt", kind: "modified")]
    done.projectLog = ["git_push → main"]
    done.tasks = [CollaborationTask(title: "t", accountID: "x", output: "/Users/someone/out.md", expectedFiles: ["/Users/someone/a"])]
    var writing = ChatTurn(question: "SECOND question")
    writing.partial = "half"; writing.partialBy = "Claude"
    chat.turns = [done, writing]
    Discussion.saveText("Goal: lenses", to: Discussion.stateFile(chat.id))
    Discussion.saveText(done.id.uuidString, to: Discussion.stateTurnFile(chat.id))
    let file = a.myChats.appendingPathComponent(chat.id.uuidString + ".json")

    expect(!a.publish(chat) && !fm.fileExists(atPath: file.path), "with ‘chosen chats’, an unchosen chat is not copied")
    chat.shareToDevices = true
    a.isBusy = { _ in true }
    expect(a.publish(chat), "a chosen chat is copied")
    let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
    expect(!text.contains("/Users/someone") && !text.contains("git_push") && !text.contains("photo.png"), "the copy leaves out this Mac's paths, project steps and pictures")
    expect(!text.contains("SECOND question") && !text.contains("half"), "the turn being answered stays out of the copy")
    let snap = DeviceSync.load(RemoteChat(device: "mac-a", deviceName: "", chat: chat.id, title: "", updatedAt: nil, school: false, status: .ready, file: file))!
    expect(snap.turns.count == 1 && snap.pictures == 1 && snap.state == "Goal: lenses" && snap.stateTurn == done.id, "the copy has the finished turns, the chat state and which turn it covers")
    a.isBusy = { _ in false }
    expect(a.publish(chat), "copied again")
    let finished = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
    expect(finished.contains("SECOND question") && !finished.contains("\"half\""), "once answered, the last turn goes out too, without the work in progress")
    let old = Date(timeIntervalSince1970: 1_000_000)
    try! fm.setAttributes([.modificationDate: old], ofItemAtPath: file.path)
    a.publish(chat)
    expect((try? fm.attributesOfItem(atPath: file.path)[.modificationDate] as? Date) == old, "an unchanged chat is not written again")

    // Enterprise (locked) chats stay off unless included; turning that off removes their copies.
    var school = Conversation(); school.title = "Work chat"; school.shareToDevices = true
    school.turns = [ChatTurn(question: "work question")]
    school.enterpriseLock = workLock
    expect(DeviceSync.isSchool(school), "a locked chat is Enterprise")
    var named = Conversation(); var reply = ChatTurn(question: "q"); reply.finalBy = "ChatGPT (Work)"; named.turns = [reply]
    expect(!DeviceSync.isSchool(named), "a chat an Enterprise account answered is not, unless locked")
    expect(!a.publish(school), "Enterprise chats are not copied by default")
    a.settings.includeSchool = true
    a.waitForWrites()   // the reconcile that change starts, before this write
    expect(a.publish(school), "included Enterprise chats are copied")
    let schoolFile = a.myChats.appendingPathComponent(school.id.uuidString + ".json")
    a.conversations = { [chat, school] }
    a.settings.includeSchool = false   // reconciles
    a.waitForWrites()
    expect(!fm.fileExists(atPath: schoolFile.path) && fm.fileExists(atPath: file.path), "turning Enterprise off removes only the Enterprise copies")
    let gone = a.myChats.appendingPathComponent(UUID().uuidString + ".json")
    try! Data("{}".utf8).write(to: gone)
    a.reconcile(); a.waitForWrites()
    expect(!fm.fileExists(atPath: gone.path), "copies of chats deleted while the app was closed are removed")
    let unreadable = UUID().uuidString + ".json"
    let unreadableCopy = a.myChats.appendingPathComponent(unreadable)
    try! Data("{}".utf8).write(to: unreadableCopy)
    a.hasLocalFile = { $0 == unreadable }
    a.reconcile(); a.waitForWrites()
    expect(fm.fileExists(atPath: unreadableCopy.path), "a chat whose own file is here but could not be read keeps its copy")
    a.hasLocalFile = { _ in false }
    try? fm.removeItem(at: unreadableCopy)

    // A write that fails (the folder read only for a moment) keeps a shared chat's existing copy, and so does
    // a chat with nothing finished yet; neither looks to the other Macs as if it was taken away.
    var steady = Conversation(); steady.shareToDevices = true; steady.title = "Steady"
    var answered = ChatTurn(question: "STEADY one"); answered.final = "a"; steady.turns = [answered]
    let steadyFile = a.myChats.appendingPathComponent(steady.id.uuidString + ".json")
    expect(a.publish(steady), "copied")
    let before = try! Data(contentsOf: steadyFile)
    steady.turns.append(ChatTurn(question: "STEADY two"))
    var answering = Conversation(); answering.shareToDevices = true; answering.title = "Answering"
    answering.turns = [ChatTurn(question: "still answering")]
    let answeringFile = a.myChats.appendingPathComponent(answering.id.uuidString + ".json")
    try! Data("{}".utf8).write(to: answeringFile)
    a.conversations = { [chat, steady, answering] }
    a.isBusy = { $0 == answering.id }
    try! fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: a.myChats.path)
    a.reconcile(); a.waitForWrites()
    try! fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: a.myChats.path)
    expect((try? Data(contentsOf: steadyFile)) == before, "a copy that could not be written just now is kept, not removed")
    expect(fm.fileExists(atPath: answeringFile.path), "a chat with nothing finished yet keeps its copy")
    a.reconcile(); a.waitForWrites()
    expect((try? String(contentsOf: steadyFile, encoding: .utf8))?.contains("STEADY two") == true, "once writable, the copy is written again")
    a.isBusy = { _ in false }
    a.conversations = { [chat] }
    a.reconcile(); a.waitForWrites()
    expect(!fm.fileExists(atPath: steadyFile.path) && !fm.fileExists(atPath: answeringFile.path) && fm.fileExists(atPath: file.path), "cleaned up")

    // Locking a shared chat takes its copy down at once.
    var later = Conversation(); later.title = "Locked later"; later.shareToDevices = true
    var laterTurn = ChatTurn(question: "q"); laterTurn.final = "a"; later.turns = [laterTurn]
    let laterFile = a.myChats.appendingPathComponent(later.id.uuidString + ".json")
    expect(a.publish(later) && fm.fileExists(atPath: laterFile.path), "an open chat is copied")
    later.enterpriseLock = workLock
    a.chatLocked(later)
    let removing = Date().addingTimeInterval(5)
    while fm.fileExists(atPath: laterFile.path) && Date() < removing { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
    a.waitForWrites()
    expect(!fm.fileExists(atPath: laterFile.path) && !a.shares(later) && a.shares(chat), "locking removes its copy; open chats stay shared")

    // The other Mac reads them; broken, half-written, newer and not-yet-downloaded files are handled.
    let chats = a.myChats
    try! Data("{\"schemaVersion\": 1, \"title\": \"half".utf8).write(to: chats.appendingPathComponent(UUID().uuidString + ".json"))
    let newer = UUID()
    try! Data("{\"schemaVersion\": 99, \"title\": \"From the future\"}".utf8).write(to: chats.appendingPathComponent(newer.uuidString + ".json"))
    let cloud = UUID()
    try! Data().write(to: chats.appendingPathComponent("." + cloud.uuidString + ".json.icloud"))
    expect(a.scanNow().isEmpty, "a Mac does not list its own chats")
    let seen = b.scanNow()
    expect(seen.count == 1 && seen[0].name == "Mac mini" && seen[0].id == "mac-a", "the other Mac is listed by its name")
    let listed = seen[0].chats
    expect(listed.first { $0.chat == chat.id }?.status == .ready && listed.first { $0.chat == chat.id }?.title == "Lens notes", "a copied chat is listed")
    expect(listed.first { $0.chat == newer }?.status == .newerVersion, "a copy from a newer app is shown as needing an update")
    expect(listed.first { $0.chat == cloud }?.status == .downloading, "a file iCloud has not brought down yet is shown as downloading")
    expect(listed.count == 3, "a half-written copy is skipped until it is complete")
    expect(DeviceSync.load(listed.first { $0.chat == newer }!) == nil, "a newer copy is not guessed at")

    // Continue on this Mac: a new chat with the turns, summary, state and side, but no folders or sessions.
    Discussion.modernModes = true
    Discussion.availableModes = [0, 1, 2, 3, 4]
    let m = AppModel()
    m.accounts = [personal]
    m.sharedFolders = []
    let here = Discussion(model: m)
    let remote = listed.first { $0.chat == chat.id }!
    here.openRemote(remote)
    expect(here.viewingRemote?.loading == true, "the copy is read off the main thread")
    let opening = Date().addingTimeInterval(5)
    while here.viewingRemote?.loading == true && Date() < opening { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
    expect(here.viewingRemote?.snapshot?.turns.count == 2, "the copy opens read only")
    let id = here.continueFromDevice(here.viewingRemote!.snapshot!, device: remote.device, deviceName: remote.deviceName)
    let copy = here.current
    expect(id != chat.id && copy.id == id && here.viewingRemote == nil, "continuing makes a new chat and opens it")
    expect(copy.turns.map(\.question) == ["FIRST question", "SECOND question"] && copy.workspace == nil, "the new chat has the turns and no linked folders")
    expect(here.configuration.mode == 0, "a plain chat stays a plain chat")
    expect(!copy.isEnterprise && copy.origin?.device == "mac-a" && copy.origin?.chat == chat.id, "an open chat stays open and keeps where it came from")
    expect(Discussion.loadState(id) == "Goal: lenses" && Discussion.loadStateTurn(id) == done.id, "the chat state comes along")
    expect(here.continued(from: remote).map(\.id) == [id], "a second ‘continue’ finds the chat already continued")
    expect(fm.fileExists(atPath: file.path), "the other Mac's copy is never changed")
    here.openRemote(remote); here.open(id)
    expect(here.viewingRemote == nil, "opening a chat here leaves the read-only view")

    // A locked chat's copy is continued locked; an older copy marked Enterprise (no lock) is open.
    let lockedID = here.continueFromDevice(DeviceSync.snapshot(school, school: true, busy: false, state: nil, stateTurn: nil), device: "mac-a", deviceName: "Mac mini")
    expect(here.conversations.first { $0.id == lockedID }?.enterpriseLock == workLock, "a locked chat stays locked on the other Mac")
    var olderSnap = DeviceSync.snapshot(school, school: true, busy: false, state: nil, stateTurn: nil); olderSnap.enterpriseLock = nil
    let olderID = here.continueFromDevice(olderSnap, device: "mac-a", deviceName: "Mac mini")
    expect(here.conversations.first { $0.id == olderID }?.isEnterprise == false, "an older copy is open")
    here.open(id)

    // The first message: a new session that knows the chat came from another Mac and reads every turn after the state.
    var legacy = ChatConfiguration(); legacy.mode = 0
    expect(DeviceSync.mode(legacy) == 1 && DeviceSync.mode(nil) == 0, "a copy carries the mode the chat really runs in")
    expect(Discussion.recentCount(Array(repeating: ChatTurn(question: ""), count: 2), stateTurn: nil) == Discussion.recentTurns, "without a state turn, the usual recent turns")
    var long = Conversation(); long.title = "Long"
    long.configuration = ChatConfiguration(); long.configuration?.mode = 0; long.configuration?.modeVersion = 2
    let words = ["ZERO", "ONE", "TWO", "THREE", "FOUR", "FIVE"]
    long.turns = words.map { w in
        var t = ChatTurn(question: "QUESTION-\(w)"); t.mode = 0; t.modeVersion = 2
        t.final = "ANSWER-\(w) " + String(repeating: "lens ", count: 1100); t.finalBy = "Claude"; return t
    }
    let longSnap = DeviceSync.snapshot(long, school: false, busy: false, state: "Goal: long lenses", stateTurn: long.turns[1].id)
    expect(Discussion.recentCount(longSnap.turns, stateTurn: longSnap.stateTurn) == 4, "every turn after the state's turn is read in full")
    let longID = here.continueFromDevice(longSnap, device: "mac-a", deviceName: "Mac mini")
    var prompts: [String] = []
    here.workspaceAnswer = { _, prompt, _, _, _ in prompts.append(prompt); return .success("Next answer") }
    here.draft = "NEXT question"
    here.send(); waitFor(here)
    let first = prompts.last ?? ""
    expect(first.contains("[Continued from another Mac]") && first.contains("Mac mini") && first.contains("do not carry them out again"), "the AI is told the chat came from another Mac")
    expect(first.contains("Goal: long lenses") && first.contains("QUESTION-TWO") && first.contains("QUESTION-FIVE"), "the new session starts from the state and the turns after it")
    expect(!first.contains("QUESTION-ONE") && first.contains(Discussion.historyFile(longID).path), "earlier turns stay in the history file")
    expect(here.current.turns.last?.final == "Next answer", "the continued chat answers here")
    testMacConnection(folder: folder)
    print("PASS: chats from other Macs: own folder only, chosen chats, no paths or pictures, Enterprise kept off, broken/newer/downloading copies, continue as a new chat with state")
}

/// Other Macs → connect: a Mac with its phone page on leaves remote.json only while "Let my other Macs connect" is on;
/// the other Mac lists it with the address, and only a tailnet https address of that same host is opened.
func testMacConnection(folder: URL) {
    let fm = FileManager.default
    var on = DeviceSyncSettings(); on.enabled = true; on.folder = folder.path; on.deviceName = "Studio"
    let a = DeviceSync(deviceID: "mac-c", persist: false, settings: on)
    on.deviceName = "Air"
    let b = DeviceSync(deviceID: "mac-d", persist: false, settings: on)
    let offered = RemoteConnection(address: "https://studio.tail1.ts.net/?k=KEY", host: "Studio.tail1.ts.net", app: "0.3.0")
    a.offerConnection(offered); a.waitForWrites()
    expect(!fm.fileExists(atPath: a.connectionFile.path), "connect: nothing goes up while ‘Let my other Macs connect’ is off")
    a.settings.sharesConnection = true; a.waitForWrites()
    expect(fm.fileExists(atPath: a.connectionFile.path), "connect: turned on, this Mac's address goes in its folder")
    expect((try? fm.removeItem(at: a.connectionFile)) != nil && !fm.fileExists(atPath: a.connectionFile.path), "connect: remote.json taken down from outside")
    a.offerConnection(offered); a.waitForWrites()
    expect(fm.fileExists(atPath: a.connectionFile.path), "connect: a remote.json taken down from outside comes back at the next offer of the same address")
    let listed = b.scanNow().first { $0.id == "mac-c" }
    expect(listed?.name == "Studio" && listed?.connection?.url?.absoluteString == "https://studio.tail1.ts.net/?k=KEY", "connect: the other Mac lists it with its address")
    expect(listed.map(b.reach) == .unknown, "connect: unknown until Tailscale was checked")
    b.onlineHosts = ["studio.tail1.ts.net"]
    expect(listed.map(b.reach) == .ready, "connect: online on Tailscale means ready")
    b.onlineHosts = []
    expect(listed.map(b.reach) == .offline, "connect: not online means off or asleep")
    let bad = RemoteConnection(address: "https://evil.example.com/?k=KEY", host: "studio.tail1.ts.net", app: "")
    let plain = RemoteConnection(address: "http://studio.tail1.ts.net/?k=KEY", host: "studio.tail1.ts.net", app: "")
    expect(bad.url == nil && plain.url == nil, "connect: only a tailnet https address of its own host is opened")
    a.offerConnection(nil); a.waitForWrites()
    expect(!fm.fileExists(atPath: a.connectionFile.path), "connect: the page turned off takes the address down")
    let byHand = try! JSONEncoder().encode(RemoteConnection(address: "https://studio.tail1.ts.net/?k=HAND", host: "studio.tail1.ts.net", app: ""))
    try? byHand.write(to: a.connectionFile)
    a.offerConnection(nil); a.waitForWrites()
    expect(fm.fileExists(atPath: a.connectionFile.path), "connect: with the page still off, a remote.json written by hand is not taken down again")
    try? fm.removeItem(at: a.connectionFile)
    a.offerConnection(offered); a.waitForWrites()
    a.settings.sharesConnection = false; a.waitForWrites()
    expect(!fm.fileExists(atPath: a.connectionFile.path), "connect: turning connecting off takes the address down")
    try? byHand.write(to: a.connectionFile)
    a.offerConnection(offered); a.waitForWrites()
    expect(fm.fileExists(atPath: a.connectionFile.path), "connect: with connecting off, the same address again leaves a remote.json written by hand")
    try? fm.removeItem(at: a.connectionFile)
    a.settings.sharesConnection = true; a.waitForWrites()
    a.settings.enabled = false; a.waitForWrites()
    expect(!fm.fileExists(atPath: a.connectionFile.path), "connect: turning the sync folder off takes it down too")
    expect(b.scanNow().first { $0.id == "mac-c" }?.connection == nil, "connect: then the other Mac has no address for it")
    var saved = DeviceSyncSettings(); saved.enabled = true
    let old = try! JSONSerialization.data(withJSONObject: ["enabled": true, "shareAll": false, "includeSchool": false])
    expect((try? JSONDecoder().decode(DeviceSyncSettings.self, from: old))?.sharesConnection == false && !saved.sharesConnection, "connect: older settings read as off")
}

/// "Sync skills & memory" (연동 1/3): a throwaway folder stands in for iCloud Drive; skills and memory are test stores.
func testKnowledgeSync() {
    let fm = FileManager.default
    let root = URL(fileURLWithPath: AccountStore.home).appendingPathComponent("knowledge-sync-" + UUID().uuidString)
    defer { try? fm.removeItem(at: root) }
    let folder = root.appendingPathComponent("sync"), skillsDir = root.appendingPathComponent("skills")
    let realCloud = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Mobile Documents").standardizedFileURL.path
    let shared = KnowledgeSync.folder(DeviceSync.shared.folder).standardizedFileURL.path
    expect(shared.hasPrefix(URL(fileURLWithPath: AccountStore.home).standardizedFileURL.path + "/") && !shared.hasPrefix(realCloud),
           "knowledge sync's default folder is under the test home, not the real iCloud Drive: \(shared)")
    expect(!DeviceSync.shared.settings.syncsKnowledge && KnowledgeSync.shared.syncNow() == nil, "sync skills & memory is off until turned on")

    var on = DeviceSyncSettings(); on.folder = folder.path; on.deviceName = "Mac mini"; on.syncsKnowledge = true
    try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
    let syncA = DeviceSync(deviceID: "mac-a", persist: false, settings: on)
    expect(!syncA.settings.enabled && !syncA.settings.includeSchool, "it is on while chats from other Macs are off, Enterprise chats not included")
    let skills = SkillStore(folder: { skillsDir })
    var memory = MemoryData(), memoryBroken = false
    let a = KnowledgeSync(sync: syncA, skills: skills, memory: { memoryBroken ? nil : memory }, updateMemory: { edit in edit(&memory); return true },
                          candidates: KnowledgeCandidates(root: root.appendingPathComponent("local-a")), local: root.appendingPathComponent("local-a"))
    _ = skills.save(name: "lens-cleaning", description: "Clean a lens", body: "1. Blow off dust", by: .user)
    _ = skills.save(name: "school-procedure", description: "Made in an Enterprise chat", body: "Steps", by: .ai)
    _ = skills.save(name: "old-skill", description: "Old", body: "Gone soon", by: .user)
    let reviewID = UUID()
    let mine = MemoryItem(text: "Prefers Word documents", by: "Claude")
    let reviewed = MemoryItem(text: "Uses Caltrain", by: "Claude", meeting: reviewID)
    memory.profile = "Postdoc"
    memory.items = [mine, reviewed]
    let ids = Dictionary(uniqueKeysWithValues: skills.list().map { ($0.name, $0.id.uuidString) })
    let knowledge = KnowledgeSync.folder(folder), myFolder = a.myFolder(folder)
    let changesFile = myFolder.appendingPathComponent("changes.jsonl")
    func lines() -> [KnowledgeChange] {
        ((try? String(contentsOf: changesFile, encoding: .utf8)) ?? "").split(separator: "\n")
            .compactMap { try? DeviceSync.decoder().decode(KnowledgeChange.self, from: Data($0.utf8)) }
    }
    func skillText(_ name: String) -> String? {
        try? String(contentsOf: myFolder.appendingPathComponent("skills/\(ids[name]!)/SKILL.md"), encoding: .utf8)
    }

    // The first pass: everything once, the host claimed.
    expect(a.syncNow() == 6, "the first pass writes all three skills, the profile and both facts")
    let first = lines()
    expect(first.count == 6 && first.allSatisfy { $0.op == .add && $0.initial == true && $0.base == nil && $0.hash != nil && $0.device == "mac-a" },
           "the first pass is all initial adds with a hash and no base")
    let lens = first.first { $0.id == ids["lens-cleaning"] }
    expect(lens?.kind == .skill && lens?.name == "lens-cleaning" && lens?.enabled == true && lens?.by == .user, "a skill line has its name, on/off and author")
    expect(first.first { $0.id == ids["school-procedure"] }?.by == .ai, "a skill an AI saved (an Enterprise chat's too) goes, by ai")
    expect(first.first { $0.id == mine.id.uuidString }?.by == .user && first.first { $0.id == reviewed.id.uuidString }?.by == .meeting
           && first.first { $0.id == reviewed.id.uuidString }?.text == "Uses Caltrain", "facts: the user's (asked for) and a review's, with their text")
    expect(first.first { $0.kind == .profile }?.text == "Postdoc", "the profile goes too")
    expect(skillText("lens-cleaning") == skills.read("lens-cleaning")?.document.render()
           && lens?.hash == SkillDocument.hash(skills.read("lens-cleaning")!.document.render()), "SKILL.md is the skill as written, its hash in the line")
    expect(KnowledgeSync.host(folder)?.device == "mac-a" && KnowledgeSync.host(folder)?.name == "Mac mini", "the first Mac to turn it on holds the meetings")
    expect(!fm.fileExists(atPath: folder.appendingPathComponent("devices").path), "chat copies are not written by it")

    // Nothing changed: nothing written.
    let before = try? Data(contentsOf: changesFile)
    expect(a.syncNow() == 0 && (try? Data(contentsOf: changesFile)) == before, "an unchanged pass writes no line")

    // Another Mac: its own folder; the host stays.
    on.deviceName = "MacBook"
    var memoryB = MemoryData()
    let skillsB = SkillStore(folder: { root.appendingPathComponent("skills-b") })
    let b = KnowledgeSync(sync: DeviceSync(deviceID: "mac-b", persist: false, settings: on), skills: skillsB,
                          memory: { memoryB }, updateMemory: { edit in edit(&memoryB); return true },
                          candidates: KnowledgeCandidates(root: root.appendingPathComponent("local-b")), local: root.appendingPathComponent("local-b"))
    expect(b.syncNow() == 6 && fm.fileExists(atPath: b.myFolder(folder).appendingPathComponent("state.json").path)
           && KnowledgeSync.host(folder)?.device == "mac-a", "another Mac takes the first Mac's six items, writes them in its own folder and leaves host.json as it is")
    expect(skillsB.list().map(\.id.uuidString).sorted() == ids.values.sorted() && memoryB.items.map(\.id) == [mine.id, reviewed.id]
           && memoryB.profile == "Postdoc", "the other Mac has the same skills and facts, under the same ids")

    // Changes: modify, disable, delete (tombstone), a review's change, a fact the user removed, the profile cleared.
    let lensHash = lens!.hash, oldHash = first.first { $0.id == ids["old-skill"] }!.hash
    _ = skills.save(name: "lens-cleaning", description: "Clean a lens", body: "1. Blow off dust\n2. Wipe once", by: .user)
    _ = skills.setEnabled("school-procedure", false)
    _ = skills.delete("old-skill")
    var changed = reviewed; changed.text = "Uses Caltrain and VTA"
    memory.history.append(MemoryChange(old: reviewed, new: changed.text, meeting: reviewID))
    memory.items = [changed]
    memory.profile = ""
    expect(a.syncNow() == 6, "six changes, six lines")
    let next = Array(lines().dropFirst(6))
    let modify = next.first { $0.id == ids["lens-cleaning"] }
    expect(modify?.op == .modify && modify?.base == lensHash && modify?.hash != lensHash && modify?.initial == nil && modify?.by == .user,
           "a modify names the hash it was made on")
    expect(skillText("lens-cleaning")?.contains("Wipe once") == true, "SKILL.md follows the change")
    let off = next.first { $0.id == ids["school-procedure"] }
    expect(off?.op == .disable && off?.enabled == false && off?.by == .user, "turning a skill off is a disable line")
    let gone = next.first { $0.id == ids["old-skill"] }
    expect(gone?.op == .delete && gone?.hash == nil && gone?.base == oldHash && gone?.name == "old-skill"
           && skills.tombstones().contains { $0.id.uuidString == ids["old-skill"] && $0.deletedAt == gone?.at }, "a delete is a tombstone line at the skill's deletion time")
    expect(!fm.fileExists(atPath: myFolder.appendingPathComponent("skills/\(ids["old-skill"]!)").path), "a deleted skill's SKILL.md leaves the folder")
    let fact = next.first { $0.id == reviewed.id.uuidString }
    expect(fact?.op == .modify && fact?.by == .meeting && fact?.text == "Uses Caltrain and VTA" && fact?.base == SkillDocument.hash("Uses Caltrain"),
           "a review's change to a fact is by meeting, on the old text's hash")
    let removed = next.first { $0.id == mine.id.uuidString }
    expect(removed?.op == .delete && removed?.by == .user && removed?.hash == nil && removed?.text == nil, "a fact removed is a tombstone line")
    expect(next.first { $0.kind == .profile }?.op == .delete, "the profile cleared is a delete")
    expect(knowledge.appendingPathComponent("mac-a/changes.jsonl").path == changesFile.path, "lines go to knowledge/<this Mac>/changes.jsonl")

    // An unreadable skills.json lists no skill: that is not every skill deleted.
    let index = skillsDir.appendingPathComponent("skills.json"), saved = try! Data(contentsOf: index)
    try! Data("{broken".utf8).write(to: index)
    expect(skills.list().isEmpty && a.syncNow() == 0 && lines().count == 12, "an unreadable skill index writes no tombstones")
    try! saved.write(to: index)
    expect(a.syncNow() == 0, "readable again: nothing to write")

    // Turning it off writes nothing more; on again, only what changed meanwhile.
    syncA.settings.syncsKnowledge = false
    _ = skills.setEnabled("school-procedure", true)
    expect(a.syncNow() == nil && lines().count == 12, "off: nothing is written")
    syncA.settings.syncsKnowledge = true
    expect(a.syncNow() == 1 && lines().last?.op == .enable && lines().last?.initial == nil, "on again: the change made while off goes out, not everything again")

    // An AI's edit, then the user turning the skill off before the pass: each line keeps its own author.
    _ = skills.save(name: "school-procedure", description: "Made in an Enterprise chat", body: "Steps, revised", by: .ai)
    _ = skills.setEnabled("school-procedure", false)
    expect(a.syncNow() == 2, "an edit and a turn-off: two lines")
    let pair = lines().suffix(2)
    expect(pair.first { $0.op == .modify }?.by == .ai && pair.first { $0.op == .disable }?.by == .user,
           "the edit stays the AI's, the turn-off is the user's")

    // An unreadable memory.json is not every fact deleted.
    let count = lines().count
    memoryBroken = true
    expect(a.syncNow() == 0 && lines().count == count, "an unreadable memory.json writes no tombstones")
    memoryBroken = false
    expect(a.syncNow() == 0, "readable again: nothing to write")
    let memoryFile = MemoryStore.file, keptMemory = try? Data(contentsOf: memoryFile)
    try? fm.createDirectory(at: memoryFile.deletingLastPathComponent(), withIntermediateDirectories: true)
    try! Data("{broken".utf8).write(to: memoryFile)
    let brokenStore = MemoryStore()
    expect(brokenStore.readableSnapshot == nil && brokenStore.snapshot.items.isEmpty, "MemoryStore tells an unreadable file from an empty one")
    expect(brokenStore.update { $0.profile = "New" } && brokenStore.readableSnapshot?.profile == "New", "saved again: readable")
    if let keptMemory { try! keptMemory.write(to: memoryFile) } else { try? fm.removeItem(at: memoryFile) }

    // A last line cut short by an earlier write: the next line starts on its own line.
    let handle = try! FileHandle(forWritingTo: changesFile)
    handle.seekToEndOfFile(); handle.write(Data("{\"kind\":\"memory\",\"op\":\"ad".utf8)); handle.closeFile()
    memory.profile = "Postdoc at Stanford"
    let rows = { ((try? String(contentsOf: changesFile, encoding: .utf8)) ?? "").split(separator: "\n") }
    expect(a.syncNow() == 1 && rows().count == lines().count + 1 && lines().last?.kind == .profile && lines().last?.text == "Postdoc at Stanford",
           "after a line cut short, the next line still reads")
    print("PASS: knowledge sync: own folder, first full export, modify/enable/disable/tombstones with base hashes, host kept, off writes nothing, unreadable stores and cut lines")
}

/// "Sync skills & memory" 2/3: two throwaway Mac folders and one throwaway sync folder stand in for two Macs and iCloud Drive.
func testKnowledgeSyncMerge() {
    let fm = FileManager.default
    let root = URL(fileURLWithPath: AccountStore.home).appendingPathComponent("knowledge-merge-" + UUID().uuidString)
    defer { try? fm.removeItem(at: root) }
    let folder = root.appendingPathComponent("sync")
    try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
    final class Mac {
        let sync: KnowledgeSync, skills: SkillStore, inbox: KnowledgeCandidates, support: URL
        var memory = MemoryData()
        init(_ id: String, _ name: String, root: URL, folder: URL) {
            var on = DeviceSyncSettings(); on.folder = folder.path; on.deviceName = name; on.syncsKnowledge = true
            support = root.appendingPathComponent(id)
            let skillsDir = support.appendingPathComponent("skills")
            skills = SkillStore(folder: { skillsDir })
            inbox = KnowledgeCandidates(root: support)
            var box: Mac?
            sync = KnowledgeSync(sync: DeviceSync(deviceID: id, persist: false, settings: on), skills: skills,
                                 memory: { box?.memory }, updateMemory: { edit in guard let mac = box else { return false }; edit(&mac.memory); return true },
                                 candidates: inbox, local: support)
            box = self
        }
        func body(_ name: String) -> String? { skills.read(name)?.document.body }
        func rows() -> [KnowledgeCandidate] { inbox.globalRows() ?? [] }
    }
    let mini = Mac("mac-a", "Mac mini", root: root, folder: folder), book = Mac("mac-b", "MacBook", root: root, folder: folder)
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }

    // The Mac mini syncs first and holds the reviews; the MacBook takes its skills and facts under the same ids.
    _ = mini.skills.save(name: "lens-cleaning", description: "Clean a lens", body: "1. Blow off dust", by: .user, now: at(1))
    _ = mini.skills.save(name: "plot-style", description: "Plot figures", body: "Use 12 pt", by: .ai, now: at(2))
    let fact = MemoryItem(text: "Uses Caltrain", createdAt: at(3))
    mini.memory.items = [fact]
    expect(mini.sync.syncNow(now: at(10)) == 3 && mini.sync.isReviewHost, "the first Mac writes its three items and holds the reviews")
    expect(book.sync.syncNow(now: at(11)) == 3, "the second Mac applies them and writes them as its own first pass")
    let lensID = mini.skills.read("lens-cleaning")!.record.id
    expect(book.skills.read("lens-cleaning")?.record.id == lensID && book.skills.read("lens-cleaning")?.record.userLocked == true
           && book.skills.read("plot-style")?.record.createdBy == .ai && book.memory.items.map(\.id) == [fact.id],
           "same ids, the user's skill locked, the AI's skill still the AI's")
    expect(!book.sync.isReviewHost && KnowledgeSync.host(folder)?.device == "mac-a", "the other Mac does not hold reviews")
    let miniHistory = mini.skills.history().count
    expect(mini.sync.syncNow(now: at(12)) == 0 && mini.skills.history().count == miniHistory && mini.memory.items == [fact],
           "the other Mac's copy of the same items changes nothing on the first")

    // A change and a switch go across; a SKILL.md that does not match its line yet waits, the rest still applies.
    _ = book.skills.save(name: "lens-cleaning", description: "Clean a lens", body: "1. Blow off dust\n2. Wipe once", by: .user, now: at(100))
    _ = book.skills.setEnabled("plot-style", false, now: at(101))
    expect(book.sync.syncNow(now: at(110)) == 2, "a modify and a disable")
    let lensFile = book.sync.myFolder(folder).appendingPathComponent("skills/\(lensID.uuidString)/SKILL.md")
    let lensText = try! Data(contentsOf: lensFile)
    try! Data("---\nname: lens-cleaning\ndescription: Clean a lens\n---\nsomething newer\n".utf8).write(to: lensFile)
    let bookLines = KnowledgeSync.lines(book.sync.myFolder(folder).appendingPathComponent("changes.jsonl")).count
    _ = mini.sync.syncNow(now: at(120))
    expect(mini.body("lens-cleaning") == "1. Blow off dust" && mini.skills.read("plot-style")?.record.enabled == false
           && (mini.sync.loadCursor().read["mac-b"] ?? 0) < bookLines, "a SKILL.md that does not match waits; the switch is applied")
    try! lensText.write(to: lensFile)
    _ = mini.sync.syncNow(now: at(121))
    expect(mini.body("lens-cleaning") == "1. Blow off dust\n2. Wipe once" && mini.sync.loadCursor().read["mac-b"] == bookLines,
           "then it applies, and this Mac keeps how far it read each Mac")
    expect(mini.skills.read("lens-cleaning")?.record.userLocked == true
           && mini.skills.history().last { $0.skillID == lensID }?.by == .user, "applied as the user's change")
    _ = book.sync.syncNow(now: at(122))

    // A delete wins over a change made beside it, which goes to the inbox; the deleted skill never comes back.
    _ = book.skills.save(name: "plot-style", description: "Plot figures", body: "Use 14 pt", by: .ai, now: at(200))
    expect(book.sync.syncNow(now: at(210)) == 1, "the MacBook's AI edit goes out")
    _ = mini.skills.delete("plot-style", now: at(205))
    _ = mini.sync.syncNow(now: at(220))
    expect(mini.skills.read("plot-style") == nil, "the Mac that deleted it does not take the edit made beside the delete")
    _ = book.sync.syncNow(now: at(230))
    let lostEdit = book.rows().first { $0.origin == "sync" && $0.content["body"] == "Use 14 pt" }
    expect(book.skills.read("plot-style") == nil && book.skills.tombstones().contains { $0.name == "plot-style" } && lostEdit != nil,
           "the other Mac deletes it too and puts its edit in the inbox")
    _ = mini.sync.syncNow(now: at(240))
    expect(mini.skills.read("plot-style") == nil && mini.rows().contains { $0.id == lostEdit?.id && $0.state == .pending },
           "no resurrection, and the review Mac has that candidate")

    // The user's change beats a review's made beside it on the other Mac, on both Macs; the review's text goes to the inbox.
    let lockedHash = mini.skills.read("lens-cleaning")!.record.contentHash
    _ = mini.skills.save(name: "lens-cleaning", description: "Clean a lens", body: "A-meeting", by: .meeting, now: at(300), approved: lockedHash)
    _ = book.skills.save(name: "lens-cleaning", description: "Clean a lens", body: "B-user", by: .user, now: at(310))
    _ = mini.sync.syncNow(now: at(320))
    _ = book.sync.syncNow(now: at(330))
    expect(book.body("lens-cleaning") == "B-user", "the MacBook keeps the user's version")
    _ = mini.sync.syncNow(now: at(340))
    let setAside = mini.rows().filter { $0.content["body"] == "A-meeting" }
    expect(mini.body("lens-cleaning") == "B-user" && setAside.count == 1 && setAside.first?.content["replaces"] == "lens-cleaning"
           && setAside.first?.state == .pending && book.rows().contains { $0.id == setAside.first?.id },
           "the Mac mini takes the user's version; the review's text is one candidate, the same on both Macs")

    // Both by the user: the later stays for now and both versions go to the review as one conflict-merge candidate.
    mini.memory.history.append(MemoryChange(old: mini.memory.items[0], new: "Uses Caltrain and VTA", at: at(400)))
    mini.memory.items[0].text = "Uses Caltrain and VTA"
    book.memory.history.append(MemoryChange(old: book.memory.items[0], new: "Uses Caltrain and BART", at: at(410)))
    book.memory.items[0].text = "Uses Caltrain and BART"
    _ = mini.sync.syncNow(now: at(420))
    _ = book.sync.syncNow(now: at(430))
    _ = mini.sync.syncNow(now: at(440))
    let merge = mini.rows().filter { $0.kind == .memory && $0.origin == "sync" }
    expect(mini.memory.items.map(\.text) == ["Uses Caltrain and BART"] && book.memory.items.map(\.text) == ["Uses Caltrain and BART"],
           "both Macs keep the later fact for now")
    expect(merge.count == 1 && merge.first?.content["text"] == "Uses Caltrain and VTA" && merge.first?.content["replaces_id"] == fact.id.uuidString
           && (merge.first?.evidence.contains("충돌 병합") == true || merge.first?.evidence.contains("Conflict merge") == true)
           && merge.first?.evidence.contains("Uses Caltrain and BART") == true, "one conflict-merge candidate with both versions")

    // An edit undone (X → Y → X) on the Mac mini while the MacBook's own X → Y was still on its way: the late line does not
    // undo the undo, and the MacBook takes the undo too.
    func edit(_ mac: Mac, _ id: UUID, _ text: String, _ s: TimeInterval) {
        let i = mac.memory.items.firstIndex { $0.id == id }!
        mac.memory.history.append(MemoryChange(old: mac.memory.items[i], new: text, at: at(s)))
        mac.memory.items[i].text = text
    }
    let coffee = MemoryItem(text: "Prefers drip coffee", createdAt: at(450))
    mini.memory.items.append(coffee)
    _ = mini.sync.syncNow(now: at(451)); _ = book.sync.syncNow(now: at(452)); _ = mini.sync.syncNow(now: at(453))
    let bookChanges = book.sync.myFolder(folder).appendingPathComponent("changes.jsonl")
    let delivered = try! Data(contentsOf: bookChanges)
    edit(book, coffee.id, "Prefers pour-over", 455)
    _ = book.sync.syncNow(now: at(456))
    let full = try! Data(contentsOf: bookChanges)
    try! delivered.write(to: bookChanges)   // iCloud has not brought the MacBook's line to the Mac mini yet
    edit(mini, coffee.id, "Prefers pour-over", 457); _ = mini.sync.syncNow(now: at(458))
    edit(mini, coffee.id, "Prefers drip coffee", 459); _ = mini.sync.syncNow(now: at(460))
    try! full.write(to: bookChanges)
    _ = mini.sync.syncNow(now: at(461))
    _ = book.sync.syncNow(now: at(462))
    func text(_ mac: Mac, _ id: UUID) -> String? { mac.memory.items.first { $0.id == id }?.text }
    expect(text(mini, coffee.id) == "Prefers drip coffee" && text(book, coffee.id) == "Prefers drip coffee",
           "a late X → Y does not undo an undo; both Macs keep the later X")

    // An AI's delete beside the user's change: the user's change stays on both Macs (on the deleting Mac under a new id).
    _ = mini.skills.save(name: "trip-plan", description: "Plan trips", body: "Caltrain first", by: .ai, now: at(463))
    _ = mini.sync.syncNow(now: at(464)); _ = book.sync.syncNow(now: at(465)); _ = mini.sync.syncNow(now: at(466))
    let tripID = mini.skills.read("trip-plan")!.record.id
    if case .deleted = mini.skills.delete("trip-plan", by: .ai, now: at(470)) {} else { expect(false, "the Mac mini's AI deletes it") }
    _ = book.skills.save(name: "trip-plan", description: "Plan trips", body: "Caltrain first, then VTA", by: .user, now: at(471))
    _ = mini.sync.syncNow(now: at(472))
    _ = book.sync.syncNow(now: at(473))
    _ = mini.sync.syncNow(now: at(474))
    _ = book.sync.syncNow(now: at(475))
    expect(book.body("trip-plan") == "Caltrain first, then VTA" && book.skills.read("trip-plan")?.record.id == tripID,
           "the MacBook keeps the user's change under its id")
    expect(mini.body("trip-plan") == "Caltrain first, then VTA" && mini.skills.read("trip-plan")?.record.id != tripID,
           "the Mac mini brings it back under a new id")
    _ = book.skills.save(name: "trip-plan", description: "Plan trips", body: "Walk to the station", by: .user, now: at(476))
    _ = book.sync.syncNow(now: at(477)); _ = mini.sync.syncNow(now: at(478)); _ = book.sync.syncNow(now: at(479))
    expect(mini.body("trip-plan") == "Walk to the station" && book.skills.read("trip-plan")?.record.id == tripID
           && mini.skills.list().filter { $0.name == "trip-plan" }.count == 1, "later changes still reach it through the alias")

    // A conflict candidate the inbox cannot take yet stays in the cursor file and reaches the inbox on a later pass.
    let bus = MemoryItem(text: "Takes the 22 bus", createdAt: at(480))
    mini.memory.items.append(bus)
    _ = mini.sync.syncNow(now: at(481)); _ = book.sync.syncNow(now: at(482)); _ = mini.sync.syncNow(now: at(483))
    edit(mini, bus.id, "Takes the 22 bus at 8", 484); _ = mini.sync.syncNow(now: at(485))
    edit(book, bus.id, "Takes the 22 bus at 9", 484.5)
    let bookInbox = book.inbox.globalFile, inboxData = try? Data(contentsOf: bookInbox)
    try? fm.removeItem(at: bookInbox); try! fm.createDirectory(at: bookInbox, withIntermediateDirectories: true)
    _ = book.sync.syncNow(now: at(486))
    let held = book.sync.loadCursor().conflicts ?? []
    expect(held.count == 1 && held.first?.content["text"] == "Takes the 22 bus at 8", "the inbox cannot be written: the candidate waits in the cursor file")
    try! fm.removeItem(at: bookInbox); if let inboxData { try! inboxData.write(to: bookInbox) }
    _ = book.sync.syncNow(now: at(487))
    expect(book.sync.loadCursor().conflicts == nil && book.rows().contains { $0.id == held.first?.id }, "then it goes into the inbox")
    _ = mini.sync.syncNow(now: at(488)); _ = book.sync.syncNow(now: at(489))

    // The profile cleared on the Mac mini after the MacBook changed it from the same version: both keep the later clear.
    mini.memory.profile = "Postdoc at Stanford"
    _ = mini.sync.syncNow(now: at(490)); _ = book.sync.syncNow(now: at(491)); _ = mini.sync.syncNow(now: at(492))
    let profileDelivered = try! Data(contentsOf: bookChanges)
    book.memory.profile = "Postdoc at Stanford, Ginzton Lab"; _ = book.sync.syncNow(now: at(493))
    let profileFull = try! Data(contentsOf: bookChanges)
    try! profileDelivered.write(to: bookChanges)
    mini.memory.profile = ""; _ = mini.sync.syncNow(now: at(494))
    try! profileFull.write(to: bookChanges)
    _ = mini.sync.syncNow(now: at(495))
    _ = book.sync.syncNow(now: at(496))
    _ = mini.sync.syncNow(now: at(497))
    expect(mini.memory.profile.isEmpty && book.memory.profile.isEmpty, "both Macs keep the later clear")

    // Candidates: the MacBook only proposes; the review Mac takes its pending rows, and its outcome goes back.
    func candidate(_ name: String) -> KnowledgeCandidate {
        KnowledgeCandidate(kind: .skill, content: ["name": name, "description": "d", "body": "b"], evidence: "seen twice", accountID: "a",
                           accountName: "ChatGPT", chatID: UUID(), turnID: UUID(), todoID: nil)
    }
    let fromBook = candidate("from-book"), fromMini = candidate("from-mini")
    expect(book.inbox.submit(fromBook, project: nil) == nil && mini.inbox.submit(fromMini, project: nil) == nil, "candidates proposed on each Mac")
    book.sync.shareable = { [fromBook.id] }; mini.sync.shareable = { [fromMini.id] }
    _ = book.sync.syncNow(now: at(500))
    _ = mini.sync.syncNow(now: at(510))
    expect(mini.rows().first { $0.id == fromBook.id }?.origin == "mac-b" && mini.rows().first { $0.id == fromBook.id }?.state == .pending,
           "the review Mac adds the other Mac's candidate to its inbox")
    _ = book.sync.syncNow(now: at(520))
    expect(!book.rows().contains { $0.id == fromMini.id }, "a Mac that does not hold reviews does not collect the others' candidates")
    expect(mini.inbox.settle([fromBook.id: .applied]), "the review applies it")
    _ = mini.sync.syncNow(now: at(530))
    _ = book.sync.syncNow(now: at(540))
    expect(book.rows().first { $0.id == fromBook.id }?.state == .applied && book.sync.shareable().contains(fromBook.id),
           "the outcome reaches the Mac that proposed it")

    // The review Mac quiet for over a week: the other Mac takes over, and the old one no longer holds reviews.
    let week = KnowledgeSync.quiet
    expect(book.sync.syncNow(now: at(540 + week - 3_600)) != nil && !book.sync.isReviewHost, "within a week the review Mac stays")
    _ = book.sync.syncNow(now: at(540 + week + 3_600))
    expect(book.sync.isReviewHost && KnowledgeSync.host(folder)?.device == "mac-b", "after a week without a pass the next Mac takes over")
    _ = mini.sync.syncNow(now: at(540 + week + 7_200))
    expect(!mini.sync.isReviewHost && book.sync.isReviewHost, "the old review Mac comes back and leaves the reviews to the new one")
    let early = KnowledgeHost(device: "mac-c", name: "iMac", since: at(0)), late = KnowledgeHost(device: "mac-a", name: "Mac mini", since: at(5))
    let devices = ["mac-c": KnowledgeDevice(name: "iMac", since: at(0), at: at(9))]
    expect(KnowledgeSync.reviewHost([late, early], devices: devices, me: "mac-a", now: at(10)) == ("mac-c", false),
           "two Macs that claimed at once: both take the earlier claim")

    // The review: a row from another Mac is reviewed without its chat; this Mac's own rows still need theirs.
    let shared = KnowledgeCandidates.shared, inboxFile = KnowledgeCandidates.file(nil), kept = try? Data(contentsOf: inboxFile)
    defer { if let kept { try? kept.write(to: inboxFile) } else { try? fm.removeItem(at: inboxFile) } }
    var remoteRow = candidate("from-other-mac"); remoteRow.origin = "mac-b"
    let orphan = candidate("chat-gone")
    expect(shared.merge([remoteRow, orphan], adding: true), "rows in this Mac's inbox")
    let eligible = KnowledgeReviewLink.eligible(Discussion(model: AppModel(persist: false))).map(\.row.id)
    expect(eligible.contains(remoteRow.id) && !eligible.contains(orphan.id), "another Mac's candidate is reviewed here; one whose chat is gone is not")
    print("PASS: knowledge sync 2/3: other Macs' changes applied once, waits for SKILL.md, tombstones, user first (also over an AI delete), undone edits, held conflicts, profile clears, conflict-merge candidates, review Mac and takeover")
}
