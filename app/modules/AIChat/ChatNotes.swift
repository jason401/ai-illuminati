import Foundation

// The user's notes for one chat, in the panel on the right of the chat window. They are kept next to the
// chat folder, not in it, so the AIs (which may write in the chat folder) cannot change them; each answer
// gets them in its instructions to read. Deleting the chat deletes them with the rest of its .work folder.
final class ChatNotes: ObservableObject {
    static let shared = ChatNotes()
    // Longer notes reach the AI cut to this many characters, with a line saying so.
    static let promptLimit = 20_000

    @Published private(set) var room: UUID?
    @Published var text = "" { didSet { if text != oldValue, room != nil { scheduleSave() } } }
    private var pending: DispatchWorkItem?

    static func file(_ room: UUID) -> URL {
        URL(fileURLWithPath: ChatStore.dir).appendingPathComponent("\(room.uuidString).work/notes.md")
    }

    static func load(_ room: UUID) -> String {
        (try? String(contentsOf: file(room), encoding: .utf8)) ?? ""
    }

    static func save(_ text: String, room: UUID) {
        let url = file(room)
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            try? FileManager.default.removeItem(at: url)
            return
        }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? text.write(to: url, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    // Shows another chat's notes, saving what was typed in the one before.
    func open(_ room: UUID) {
        guard room != self.room else { return }
        flush()
        self.room = nil
        text = Self.load(room)
        self.room = room
    }

    // Typing is saved half a second after the last key, and right away when the chat changes.
    func flush() {
        pending?.cancel(); pending = nil
        if let room { Self.save(text, room: room) }
    }

    private func scheduleSave() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.flush() }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    // What an answer reads: the notes as they are now (also while still being typed in this chat).
    static func current(_ room: UUID) -> String {
        if Thread.isMainThread, shared.room == room { shared.flush() }
        return load(room)
    }

    static func rule(_ notes: String) -> String {
        let trimmed = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let shown = trimmed.count > promptLimit ? String(trimmed.prefix(promptLimit)) + "\n… (cut: the notes are longer)" : trimmed
        return """
            [User's notes for this chat]
            The user keeps these notes beside the chat for you to read. Only the user edits them: never change, move,
            copy or delete them. Use them as context; the latest message comes first where they differ.
            \(shown)
            [End of the user's notes]
            """
    }
}
