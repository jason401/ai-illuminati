import Foundation
import AIAccounts
import AIRuntime
import AIWorkspace
import AIChat

/// C0: the chat store names no sessions, backups, documents or DeviceSync; the app connects them (`ChatLinksApp`).
/// Through Discussion's own delete (`removeChats`), with what main.swift connects: the same paths go in the same order,
/// a failure keeps everything after it, and DeviceSync hears of saves and deletes.
func testChatLinks() {
    let fm = FileManager.default
    let model = AppModel()
    let chats = Discussion(model: model)
    let dir = URL(fileURLWithPath: ChatStore.dir)
    func file(_ url: URL) throws {
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: url)
    }
    // Every place a chat keeps data, each with one file.
    func places(_ id: UUID) -> [(String, URL)] {
        [("sessions", NativeSessions.directory(id)), ("backups", WorkspaceBackup.base.appendingPathComponent(id.uuidString)),
         ("work", dir.appendingPathComponent(id.uuidString + ".work")), ("documents", RoomDocuments.directory(id)),
         ("assets", dir.appendingPathComponent(id.uuidString + ".assets")), ("chat", dir.appendingPathComponent(id.uuidString + ".json"))]
    }
    func make(_ title: String, meetingOf: UUID? = nil) throws -> Conversation {
        var chat = Conversation(); chat.title = title
        chat.turns = [ChatTurn(question: "q")]
        if let meetingOf { chat.meetingOf = MeetingLink(room: meetingOf, turn: UUID()) }
        ChatStore.save(chat)
        try file(NativeSessions.directory(chat.id).appendingPathComponent("ownership.json"))
        try file(WorkspaceBackup.base.appendingPathComponent(chat.id.uuidString + "/" + UUID().uuidString + "/note"))
        try file(dir.appendingPathComponent(chat.id.uuidString + ".work/files/a.txt"))
        try file(RoomDocuments.directory(chat.id).appendingPathComponent("doc.txt"))
        try file(dir.appendingPathComponent(chat.id.uuidString + ".assets/x.png"))
        chats.conversations.append(chat)
        return chat
    }
    func left(_ id: UUID) -> [String] { places(id).filter { fm.fileExists(atPath: $0.1.path) }.map(\.0) }
    func locked(_ folder: URL, _ body: () -> Void) {
        try? fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
        body()
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
    }

    // What the app connected: two purges (sessions, then backups) and the documents' folder.
    let connected = ChatStore.links
    expect(connected.purge.count == 2 && connected.documents(UUID())?.lastPathComponent.hasSuffix(".documents") == true,
           "the app connects the sessions and backups purges and the documents' folder")

    do {
        // A chat and its meeting go whole, the meeting first; DeviceSync hears of it after the files are gone.
        let chat = try make("Delete fixture")
        let meeting = try make("", meetingOf: chat.id)
        expect(left(chat.id).count == 6 && left(meeting.id).count == 6, "the fixture fills every place: \(left(chat.id))")
        var heard: [(UUID, [String])] = []
        ChatStore.links.deleted = { id in heard.append((id, left(id))); connected.deleted(id) }
        defer { ChatStore.links = connected }
        expect(chats.removeChats([chat]) == 0, "the chat is deleted")
        expect(left(chat.id).isEmpty && left(meeting.id).isEmpty, "sessions, backups, work, documents, assets and the chat file are gone: \(left(chat.id)) \(left(meeting.id))")
        expect(heard.map(\.0) == [meeting.id, chat.id] && heard.allSatisfy { $0.1.isEmpty }, "deleted is told per chat, meeting first, once nothing is left")
        expect(!chats.conversations.contains { $0.id == chat.id || $0.id == meeting.id }, "both leave the list")

        // Each step that fails keeps that place and every one after it (the order is sessions, backups, work, documents,
        // assets, the chat file), the chat stays in the list, and nobody is told it was deleted.
        heard = []
        for (i, place) in ["sessions", "backups", "work", "documents"].enumerated() {
            let kept = try make("Kept " + place)
            let url = places(kept.id)[i].1
            var failed = -1
            // A folder that cannot be removed: its content's parent is read only.
            let inner = fm.enumerator(at: url, includingPropertiesForKeys: nil)?.allObjects.compactMap { $0 as? URL }
                .first { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true } ?? url
            locked(inner) { failed = chats.removeChats([kept]) }
            let expected = Array(places(kept.id).map(\.0)[i...])
            expect(failed == 1 && left(kept.id) == expected, "a failure at \(place) keeps it and what comes after: \(left(kept.id))")
            expect(chats.conversations.contains { $0.id == kept.id } && heard.isEmpty, "the chat stays and no delete is told (\(place))")
            expect(chats.removeChats([kept]) == 0 && left(kept.id).isEmpty, "once it can, the second delete removes the rest (\(place))")
            heard = []
        }

        // A meeting that cannot be deleted keeps its chat whole.
        let parent = try make("Parent")
        let stuck = try make("", meetingOf: parent.id)
        locked(NativeSessions.directory(stuck.id)) { expect(chats.removeChats([parent]) == 1, "a meeting that cannot go keeps its chat") }
        expect(left(parent.id).count == 6 && left(stuck.id).count == 6, "nothing of the chat or its meeting was removed: \(left(parent.id)) \(left(stuck.id))")
        expect(chats.removeChats([parent]) == 0 && left(parent.id).isEmpty && left(stuck.id).isEmpty, "then both go")
    } catch { expect(false, "chat links fixture: \(error)") }

    // DeviceSync hears through what the app connected: a shared chat's save is copied out, its delete takes the copy down.
    let sync = DeviceSync.shared
    let before = sync.settings
    let folder = URL(fileURLWithPath: AccountStore.home).appendingPathComponent("chat-links-sync-" + UUID().uuidString)
    var on = before; on.enabled = true; on.folder = folder.path; on.deviceName = "Test Mac"
    sync.settings = on
    defer { sync.settings = before; try? fm.removeItem(at: folder) }
    var shared = Conversation(); shared.title = "Shared"; shared.shareToDevices = true
    var turn = ChatTurn(question: "q"); turn.final = "a"; turn.finalBy = "Claude"
    shared.turns = [turn]
    ChatStore.save(shared)
    chats.conversations.append(shared)
    let copy = sync.myChats.appendingPathComponent(shared.id.uuidString + ".json")
    let saveBy = Date().addingTimeInterval(DeviceSync.delay + 5)
    while !fm.fileExists(atPath: copy.path) && Date() < saveBy { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    expect(fm.fileExists(atPath: copy.path), "a saved shared chat reaches DeviceSync")
    expect(chats.removeChats([shared]) == 0, "the shared chat is deleted")
    let deleteBy = Date().addingTimeInterval(5)
    while fm.fileExists(atPath: copy.path) && Date() < deleteBy { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    expect(!fm.fileExists(atPath: copy.path), "its delete reaches DeviceSync and takes the copy down")
    print("PASS: chat delete through the app's links: same places, same order, a failure keeps the rest, meetings first, DeviceSync hears")
}
