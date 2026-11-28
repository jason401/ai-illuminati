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
    let a = KnowledgeSync(sync: syncA, skills: skills, memory: { memoryBroken ? nil : memory })
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
    let b = KnowledgeSync(sync: DeviceSync(deviceID: "mac-b", persist: false, settings: on), skills: SkillStore(folder: { root.appendingPathComponent("skills-b") }), memory: { MemoryData() })
    expect(b.syncNow() == 0 && fm.fileExists(atPath: b.myFolder(folder).appendingPathComponent("state.json").path)
           && KnowledgeSync.host(folder)?.device == "mac-a", "another Mac writes its own folder and leaves host.json as it is")

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
