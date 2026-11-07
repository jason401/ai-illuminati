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
        let model = AppModel()
        model.accounts = []
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
