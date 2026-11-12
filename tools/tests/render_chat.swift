import Cocoa
import SwiftUI
import AILocalization
import AIAccounts
import AIWorkspace
import AIProjects

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
        if CommandLine.arguments.contains("--parallel") {
            // Several AIs at once: one finished, one still writing, one failed (CHAT_STACKED=1: one under the other).
            turn.question = "Which plot style reads better for the paper?"
            turn.answerOrder = ["c", "g", "m"]; turn.answerNames = ["Claude (School)", "ChatGPT (School)", "Gemma 4 E4B"]
            turn.final = "**Line plot** with shared axes.\n\n- Easier to compare the three samples\n- Keeps the 2 MHz peak visible"
            turn.finalBy = "Claude (School)"; turn.finalAccountID = "c"
            turn.partials = ["g": "A small-multiples layout could work, because each sample"]
            var failed = ChatTurn.Entry(round: 1, speaker: "Gemma 4 E4B", text: "Ollama is not running.", failed: true); failed.accountID = "m"
            turn.moreAnswers = [failed]
            turn.status = "ChatGPT (School) answering…"
            if !CommandLine.arguments.contains("--three") { turn.answerOrder = ["c", "g"]; turn.moreAnswers = nil }
            UserDefaults.standard.set(ProcessInfo.processInfo.environment["CHAT_STACKED"] != "1", forKey: "answersSideBySide")
        }
        if CommandLine.arguments.contains("--progress") {
            // Project work under way: 12 minutes in, quiet for 3, a plan with a step added after a failing test.
            turn.question = "Add the progress display from the plan."
            turn.final = nil; turn.finalBy = nil
            turn.askedAt = Date().addingTimeInterval(-12 * 60); turn.lastActivityAt = Date().addingTimeInterval(-3 * 60 - 5)
            turn.status = "Claude (School) · working on project"; turn.activity = "Running a command…"
            turn.plan = [WorkStep(text: "Read the status line code", status: .done), WorkStep(text: "Add work_plan tool", status: .done),
                         WorkStep(text: "Fix the failing handoff test", status: .doing), WorkStep(text: "Build the app", status: .todo),
                         WorkStep(text: "Review: ChatGPT (School)", status: .todo)]
            turn.planNote = "a test failed, added a fix step"
            turn.waitingApproval = CommandLine.arguments.contains("--waiting") ? true : nil
        }
        conversation.turns = [turn]
        chat.conversations = [conversation]; chat.currentID = conversation.id
        if CommandLine.arguments.contains("--projects") {
            // The sidebar by project: a repository with a chat, its meeting and a TODO chat; a folded one; a plain chat.
            let repo = ProjectBinding(root: "/tmp/preview/AI Illuminati", common: "/tmp/preview/AI Illuminati/.git", remote: "origin", remoteURL: "")
            let face = ProjectBinding(root: "/tmp/preview/AI Face", common: "/tmp/preview/AI Face/.git", remote: "origin", remoteURL: "")
            func linked(_ title: String, _ project: ProjectBinding) -> Conversation {
                var c = Conversation(); c.title = title; c.turns = [ChatTurn(question: title)]
                c.workspace = WorkspaceBinding(roots: [WorkspaceRoot(path: project.root, directory: true, writable: true)], project: project)
                return c
            }
            conversation.workspace = WorkspaceBinding(roots: [WorkspaceRoot(path: repo.root, directory: true, writable: true)], project: repo)
            conversation.pinned = true
            var meeting = Conversation(); meeting.title = "Meeting"; meeting.turns = [ChatTurn(question: "Sidebar structure: folders or chats?")]
            meeting.meetingOf = MeetingLink(room: conversation.id, turn: turn.id)
            let todoRoom = linked("TODO · Drag and drop PDFs", repo)
            let item = try? TodoStore.shared.add(title: "Drag and drop PDFs", project: repo, projectName: "AI Illuminati")
            if let item { try? TodoStore.shared.change(item.id) { $0.room = todoRoom.id; $0.state = .review } }
            var notes = Conversation(); notes.title = "Todo list structure idea"; notes.turns = [ChatTurn(question: "ideas")]; notes.pinned = true
            chat.conversations = [conversation, meeting, todoRoom, linked("Face expressions", face), notes]
            SidebarFold.shared.toggle("project." + face.common)
            // CHAT_BOARD=todo|info|all opens the project's folder (its TODO board or Project info) or every project's board in place of the chat.
            if let tab = ProcessInfo.processInfo.environment["CHAT_BOARD"] {
                chat.openBoard(project: tab == "all" ? nil : SidebarProjects.key(repo), tab: tab == "info" ? .info : .todo)
            }
        }
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
            // List marks: a work chat (Git project), an Enterprise chat and open chats.
            func listed(_ title: String, _ edit: (inout Conversation) -> Void) -> Conversation {
                var c = Conversation(); c.title = title; c.turns = [ChatTurn(question: title)]; edit(&c); return c
            }
            chat.conversations += [
                listed("AI Illuminati work") { $0.workspace = WorkspaceBinding(roots: [], project: ProjectBinding(root: "/tmp/p", common: "", remote: "", remoteURL: "")) },
                listed("Grant draft for school") { $0.enterpriseLock = EnterpriseLock(organization: "school", name: "School", lockedAt: Date()) },
                listed("Copied from the iMac") { _ in },
                listed("Weekend trip ideas") { _ in },
            ]
        }
        if CommandLine.arguments.contains("--project-approval") {
            ProjectCenter.shared.requests = [ProjectApproval(room: conversation.id, run: UUID(), title: "Run project command", detail: "Runs outside the AI sandbox as your user.\n/Example/Project\n/bin/zsh tools/tests/run_mode2.sh")]
        }
        if ProcessInfo.processInfo.environment["CHAT_KOREAN"] == "1" { AppLanguage.current = .korean }
        for appearance in [NSAppearance.Name.darkAqua, .aqua] {
            let host = NSHostingController(rootView: ChatView(discussion: chat, model: model).environment(\.colorScheme, appearance == .darkAqua ? .dark : .light))
            host.sizingOptions = []
            let window = ChatDragWindow(contentViewController: host)
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            window.titlebarSeparatorStyle = .none; window.titleVisibility = .hidden
            window.appearance = NSAppearance(named: appearance)
            window.contentMinSize = ChatView.minSize
            // CHAT_WIDTH renders a narrow window; CHAT_SIDEBAR=1 opens the sliding sidebar there, 0 hides the sidebar.
            let width = Double(ProcessInfo.processInfo.environment["CHAT_WIDTH"] ?? "") ?? 1040
            chat.sidebarOverlay = ProcessInfo.processInfo.environment["CHAT_SIDEBAR"] == "1"
            chat.sidebarHidden = ProcessInfo.processInfo.environment["CHAT_SIDEBAR"] == "0"
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
