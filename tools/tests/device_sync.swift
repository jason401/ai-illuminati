import Foundation

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
    var work = Account(id: "ds-work", provider: .codex, name: "Work", dir: nil); work.school = true
    let accounts = [personal, work]
    expect(DeviceSync.shared.settings.enabled == false, "chats from other Macs are off until turned on")
    expect(DeviceSync.hardwareID().count == 16 && DeviceSync.hardwareID() == DeviceSync.hardwareID(), "this Mac's ID is stable")

    // A chat with this Mac's paths, pictures and a reply still being written.
    var chat = Conversation()
    chat.title = "Lens notes"
    var config = ChatConfiguration(); config.mode = 0; config.modeVersion = 2; config.school = false
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

    expect(!a.publish(chat, accounts: accounts) && !fm.fileExists(atPath: file.path), "with ‘chosen chats’, an unchosen chat is not copied")
    chat.shareToDevices = true
    a.isBusy = { _ in true }
    expect(a.publish(chat, accounts: accounts), "a chosen chat is copied")
    let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
    expect(!text.contains("/Users/someone") && !text.contains("git_push") && !text.contains("photo.png"), "the copy leaves out this Mac's paths, project steps and pictures")
    expect(!text.contains("SECOND question") && !text.contains("half"), "the turn being answered stays out of the copy")
    let snap = DeviceSync.load(RemoteChat(device: "mac-a", deviceName: "", chat: chat.id, title: "", updatedAt: nil, school: false, status: .ready, file: file))!
    expect(snap.turns.count == 1 && snap.pictures == 1 && snap.state == "Goal: lenses" && snap.stateTurn == done.id, "the copy has the finished turns, the chat state and which turn it covers")
    a.isBusy = { _ in false }
    expect(a.publish(chat, accounts: accounts), "copied again")
    let finished = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
    expect(finished.contains("SECOND question") && !finished.contains("\"half\""), "once answered, the last turn goes out too, without the work in progress")
    let old = Date(timeIntervalSince1970: 1_000_000)
    try! fm.setAttributes([.modificationDate: old], ofItemAtPath: file.path)
    a.publish(chat, accounts: accounts)
    expect((try? fm.attributesOfItem(atPath: file.path)[.modificationDate] as? Date) == old, "an unchanged chat is not written again")

    // Enterprise chats stay off unless included; turning that off removes their copies.
    var school = Conversation(); school.title = "Work chat"; school.shareToDevices = true
    school.turns = [ChatTurn(question: "work question")]
    school.configuration = ChatConfiguration(); school.configuration?.lastSoloAccountID = work.id
    expect(DeviceSync.isSchool(school, accounts: accounts), "a chat an Enterprise account answered is Enterprise")
    var named = Conversation(); var reply = ChatTurn(question: "q"); reply.finalBy = "ChatGPT (Work)"; named.turns = [reply]
    expect(DeviceSync.isSchool(named, accounts: accounts), "an older chat is Enterprise when an Enterprise account's name answered")
    expect(!a.publish(school, accounts: accounts), "Enterprise chats are not copied by default")
    a.settings.includeSchool = true
    expect(a.publish(school, accounts: accounts), "included Enterprise chats are copied")
    let schoolFile = a.myChats.appendingPathComponent(school.id.uuidString + ".json")
    a.conversations = { [chat, school] }
    a.accounts = { accounts }
    a.settings.includeSchool = false   // reconciles
    expect(!fm.fileExists(atPath: schoolFile.path) && fm.fileExists(atPath: file.path), "turning Enterprise off removes only the Enterprise copies")
    let gone = a.myChats.appendingPathComponent(UUID().uuidString + ".json")
    try! Data("{}".utf8).write(to: gone)
    a.reconcile()
    expect(!fm.fileExists(atPath: gone.path), "copies of chats deleted while the app was closed are removed")

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
    expect(here.viewingRemote?.snapshot?.turns.count == 2, "the copy opens read only")
    let id = here.continueFromDevice(here.viewingRemote!.snapshot!, device: remote.device, deviceName: remote.deviceName)
    let copy = here.current
    expect(id != chat.id && copy.id == id && here.viewingRemote == nil, "continuing makes a new chat and opens it")
    expect(copy.turns.map(\.question) == ["FIRST question", "SECOND question"] && copy.workspace == nil, "the new chat has the turns and no linked folders")
    expect(here.configuration.mode == 0, "a plain chat stays a plain chat")
    expect(copy.configuration?.school == false && copy.origin?.device == "mac-a" && copy.origin?.chat == chat.id, "it keeps its side and where it came from")
    expect(Discussion.loadState(id) == "Goal: lenses" && Discussion.loadStateTurn(id) == done.id, "the chat state comes along")
    expect(here.continued(from: remote).map(\.id) == [id], "a second ‘continue’ finds the chat already continued")
    expect(fm.fileExists(atPath: file.path), "the other Mac's copy is never changed")
    here.openRemote(remote); here.open(id)
    expect(here.viewingRemote == nil, "opening a chat here leaves the read-only view")

    // The first message: a new session that knows the chat came from another Mac and reads every turn after the state.
    var legacy = ChatConfiguration(); legacy.mode = 0
    expect(DeviceSync.mode(legacy) == 1 && DeviceSync.mode(nil) == 0, "a copy carries the mode the chat really runs in")
    expect(Discussion.recentCount(Array(repeating: ChatTurn(question: ""), count: 2), stateTurn: nil) == Discussion.recentTurns, "without a state turn, the usual recent turns")
    var long = Conversation(); long.title = "Long"
    long.configuration = ChatConfiguration(); long.configuration?.mode = 0; long.configuration?.modeVersion = 2; long.configuration?.school = false
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
    print("PASS: chats from other Macs: own folder only, chosen chats, no paths or pictures, Enterprise kept off, broken/newer/downloading copies, continue as a new chat with state")
}
