import Foundation
import AIAccounts
import AIRuntime
import AIWorkspace
import AIChat
import AIIntegrations

// The app connects the chat store to what else keeps a chat's data or hears of its changes (C0: the chat side names
// none of them). Called once, before the first chat loads: main.swift and the tests (mode2.swift). The app's screens
// inside the chat window are connected apart (ChatScreensApp.swift: main.swift only, the tests build no window).
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
        // C1: what the chat (AIChat) gets from the app's other parts, the same calls it made by name before.
        ChatApp.run = { RunConditions.app($0, $1) }
        var face = ChatApp.Face()
        face.extract = { FaceLink.extract($0) }
        face.show = { FaceLink.shared.show($0) }
        face.active = { FaceLink.active() != nil }
        face.moods = { FaceLink.shared.moods() }
        face.rule = { FaceLink.rule($0) }
        ChatApp.face = face
        ChatApp.driveRule = { DriveLink.shared.active ? DriveLink.shared.rule() : nil }
        // I: Drive (AIIntegrations) reads Office files with the chat's material reader, in a throwaway documents folder.
        DriveLink.officeText = { file in
            let room = UUID()
            defer { try? FileManager.default.removeItem(at: RoomDocuments.directory(room)) }
            let document = try MaterialReader.read(file, room: room)
            return document.units?.map { "[" + $0.locator + "]\n" + $0.text }.joined(separator: "\n\n") ?? document.text
        }
    }
}
