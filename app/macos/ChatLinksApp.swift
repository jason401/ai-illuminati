import Foundation
import AIAccounts
import AIChatRecords
import AIRuntime
import AIWorkspace
import AIChat
import AIIntegrations

// The app connects the chat store to what else keeps a chat's data or hears of its changes (C0: the chat side names
// none of them). Called once, before the first chat loads: main.swift and the tests (mode2.swift). The app's screens
// inside the chat window are connected apart (ChatScreensApp.swift: main.swift only, the tests build no window).
enum ChatLinksApp {
    @discardableResult
    static func cleanProjectMemory(in discussion: Discussion, project: String? = nil) -> Bool {
        guard !discussion.importingMaterials, discussion.stoppingRooms.isEmpty else { return false }
        return ProjectMemoryCleanupLink.runIfIdle(in: discussion, project: project, manual: project != nil)
    }

    @discardableResult
    static func reviewKnowledge(in discussion: Discussion) -> Bool {
        guard !discussion.importingMaterials, discussion.stoppingRooms.isEmpty else { return false }
        return KnowledgeReviewLink.runIfIdle(in: discussion)
    }

    static func connect() {
        ChatStore.links = ChatStore.Links(
            // The same order and failures as before: sessions (exact IDs only, never an account folder), then backups.
            purge: [{ try NativeSessions.purgeRoom($0, accounts: AccountStore.load()) }, { try WorkspaceBackup.purgeRoom($0) }],
            documents: { RoomDocuments.directory($0) },
            saved: { DeviceSync.shared.noteSaved($0) },
            deleted: { DeviceSync.shared.noteDeleted($0) },
            finished: { DeviceSync.shared.noteFinished($0) },
            locked: { DeviceSync.shared.chatLocked($0) },
            remote: { DeviceSync.load($0) })
        // C1: what the chat (AIChat) gets from the app's other parts, the same calls it made by name before.
        ChatApp.run = { RunConditions.app($0, $1, screen: $2 != nil, answer: $2) }
        var face = ChatApp.Face()
        face.extract = { FaceLink.extract($0) }
        face.show = { FaceLink.shared.show($0) }
        face.active = { FaceLink.active() != nil }
        face.moods = { FaceLink.shared.moods() }
        face.rule = { FaceLink.rule($0) }
        ChatApp.face = face
    }
}
