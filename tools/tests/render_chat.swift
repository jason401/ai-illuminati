import Cocoa
import SwiftUI

private struct EmptyPreviewLogin: GoogleTokenStore {
    func load() throws -> Data? { nil }
    func save(_ data: Data) throws {}
    func clear() throws {}
}

// Offscreen fixture rendering only: no real chats, credentials, AI calls or screen capture.
@main struct ChatPreview {
    static func main() throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        GoogleAuth.shared = GoogleAuth(store: EmptyPreviewLogin())
        AppLanguage.current = .english
        UserDefaults.standard.setVolatileDomain(["mcpOff": ["ai-face", "google-drive"], "driveFolders": Data()], forName: UserDefaults.argumentDomain)
        let output = URL(fileURLWithPath: CommandLine.arguments[1])
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let model = AppModel(persist: false)
        let chat = Discussion(model: model)
        var conversation = Conversation()
        conversation.title = "Window spacing preview"
        var turn = ChatTurn(question: "Can we make the top spacing more compact?")
        turn.mode = 0
        turn.final = "The sidebar starts closer to the title bar. The conversation header remains readable, with room to drag the window."
        turn.finalBy = "Preview AI"
        if CommandLine.arguments.contains("--markdown") {
            turn.final = "Memory first.\n\n## Models\n\n| Model | Memory | Time |\n|---|---|---|\n| SD 1.5 | 2~4GB | 10~20s |\n| **SDXL** | 7~9GB | 30s~1min |\n\n---\n### Notes\nKeep ~~old~~ text and `a~b` code."
        }
        conversation.turns = [turn]
        chat.conversations = [conversation]; chat.currentID = conversation.id
        if CommandLine.arguments.contains("--find") {
            // ⌘F: two turns with the words, the newer one moved to.
            var earlier = ChatTurn(question: "Which spacing did we pick for the sidebar?")
            earlier.mode = 0; earlier.final = "We kept 16 pt above the first row."; earlier.finalBy = "Preview AI"
            chat.conversations[0].turns.insert(earlier, at: 0)
            chat.findOpen = true; chat.findText = "spacing"; chat.findStep(0)
        }
        if CommandLine.arguments.contains("--search") {
            // Sidebar search: Korean words with endings, a filter menu and results with their lines.
            AppLanguage.current = .korean
            chat.conversations += searchFixtures()
            chat.sidebarSearching = true; chat.sidebarSearch = "청룡영화제"
        }
        if CommandLine.arguments.contains("--list") {
            // List marks: a work chat (Git project), an Enterprise chat, an unsure copy and a personal chat.
            func listed(_ title: String, _ edit: (inout Conversation) -> Void) -> Conversation {
                var c = Conversation(); c.title = title; c.turns = [ChatTurn(question: title)]; edit(&c); return c
            }
            chat.conversations += [
                listed("AI Illuminati work") { $0.workspace = WorkspaceBinding(roots: [], project: ProjectBinding(root: "/tmp/p", common: "", remote: "", remoteURL: "")) },
                listed("Grant draft for school") { $0.enterprise = [EnterpriseMark(Account(id: "s", provider: .claude, name: "School", dir: nil, school: true))] },
                listed("Copied from the iMac") { $0.enterpriseUnsure = true },
                listed("Weekend trip ideas") { _ in },
            ]
        }
        if CommandLine.arguments.contains("--project-approval") {
            ProjectCenter.shared.requests = [ProjectApproval(room: conversation.id, run: UUID(), title: "Run project command", detail: "Runs outside the AI sandbox as your user.\n/Example/Project\n/bin/zsh tools/tests/run_mode2.sh")]
        }
        for appearance in [NSAppearance.Name.darkAqua, .aqua] {
            let host = NSHostingController(rootView: ChatView(discussion: chat, model: model).environment(\.colorScheme, appearance == .darkAqua ? .dark : .light))
            host.sizingOptions = []
            let window = ChatDragWindow(contentViewController: host)
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            window.titlebarSeparatorStyle = .none; window.titleVisibility = .hidden
            window.appearance = NSAppearance(named: appearance)
            window.contentMinSize = ChatView.minSize
            // CHAT_WIDTH renders a narrow window; CHAT_SIDEBAR=1 opens the sliding sidebar there.
            let width = Double(ProcessInfo.processInfo.environment["CHAT_WIDTH"] ?? "") ?? 1040
            chat.sidebarOverlay = ProcessInfo.processInfo.environment["CHAT_SIDEBAR"] == "1"
            window.setContentSize(NSSize(width: width, height: 720))
            for _ in 0..<5 { host.view.layoutSubtreeIfNeeded(); window.displayIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.04)) }
            let view = window.contentView!.superview ?? host.view
            let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(appearance == .darkAqua ? "chat-dark.png" : "chat-light.png"))
            window.contentView = nil
        }
    }
}
