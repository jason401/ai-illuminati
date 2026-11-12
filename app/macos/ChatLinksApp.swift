import Foundation
import AIAccounts
import AIRuntime
import AIWorkspace

// The app connects the chat store to what else keeps a chat's data or hears of its changes (C0: the chat side names
// none of them). Called once, before the first chat loads: main.swift and the tests (mode2.swift).
enum ChatLinksApp {
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
    }
}
