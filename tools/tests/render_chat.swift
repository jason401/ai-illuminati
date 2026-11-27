import Cocoa
import SwiftUI
import AIChatRecords
import AILocalization
import AIAccounts
import AIWorkspace
import AIProjects
@testable import AIChat

// Offscreen fixture rendering only: no real chats, credentials, AI calls or screen capture.
@main struct ChatPreview {
    static func main() throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        ChatScreensApp.connect()   // the app's screens in the chat window, as main.swift connects them
        AppLanguage.current = .english
        UserDefaults.standard.setVolatileDomain(["mcpOff": ["ai-face"]], forName: UserDefaults.argumentDomain)
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
        if CommandLine.arguments.contains("--pictures") {
            // AI pictures where their markers are: one alone, two on a line, a missing one and one with no place (listed below).
            func picture(_ n: Int, _ color: String, _ w: Int, _ h: Int) -> ChatImage? {
                let svg = "<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 \(w) \(h)' width='\(w)' height='\(h)'><rect width='\(w)' height='\(h)' fill='\(color)'/><text x='20' y='60' font-size='48' fill='white'>\(n)</text></svg>"
                return Pictures.render(svg: svg).flatMap { try? ImageStore.importImage($0, name: "picture-\(n).png", conversationID: conversation.id) }
            }
            turn.final = "Here is the layout:\n\n[Picture 1]\n\nAnd the two options side by side:\n\n[Picture 2] [Picture 3]\n\nA lost one: [Picture 9]\n\n[Picture 9]\n\nThat is all."
            turn.finalImages = [picture(1, "#3b6ea5", 800, 450), picture(2, "#a5573b", 400, 400), picture(3, "#3ba56a", 400, 300), picture(4, "#7a3ba5", 300, 300)].compactMap { $0 }
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
            UserDefaults.app.set(ProcessInfo.processInfo.environment["CHAT_STACKED"] != "1", forKey: "answersSideBySide")
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
        // --picks: the message box's account, model and thinking picked by hand (else all Auto).
        if CommandLine.arguments.contains("--picks") {
            model.accounts = [Account(id: "preview-claude", provider: .claude, name: "Claude (학교)")]
            chat.configure { $0.mode = 0; $0.soloAccountID = "preview-claude"; $0.memberIDs = ["preview-claude"]; $0.model = "opus"; $0.effort = "high" }
        } else if CommandLine.arguments.contains("--auto") {
            model.accounts = [Account(id: "preview-claude", provider: .claude, name: "Claude (학교)")]
            chat.configure { $0.mode = 0 }
        }
        if CommandLine.arguments.contains("--projects") {
            // The sidebar by project: a repository with a chat, its meeting and a TODO chat; a folded one; a plain chat.
            let repo = ProjectBinding(root: "/tmp/preview/AI Illuminati", common: "/tmp/preview/AI Illuminati/.git", remote: "origin", remoteURL: "")
            let face = ProjectBinding(root: "/tmp/preview/AI Face", common: "/tmp/preview/AI Face/.git", remote: "origin", remoteURL: "")
            // A documents project (no Git): its folder has no branch badge.
            let papers = ProjectBinding(root: "/tmp/preview/Papers", common: "/tmp/preview/Papers", remote: "", remoteURL: "", kind: ProjectBinding.documentsKind)
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
            let item = CommandLine.arguments.contains("--empty-board") ? nil : try? TodoStore.shared.add(title: "Drag and drop PDFs", project: repo, projectName: "AI Illuminati")
            if let item { try? TodoStore.shared.change(item.id) { $0.room = todoRoom.id; $0.state = .review; $0.result = "PDFs dropped on a chat attach like photos; the full test passed." } }
            if CommandLine.arguments.contains("--inbox") || CommandLine.arguments.contains("--asked") {
                // With the inbox (or --asked, for the project's TODO panel): a TODO waiting for a decision, its answer box in the panel;
                // with --asked also one waiting its turn.
                if CommandLine.arguments.contains("--asked") { _ = try? TodoStore.shared.add(title: "Show the work folder once", project: repo, projectName: "AI Illuminati") }
                let json = #"{"kind":"choice","blocked":false,"reason":"Two ways to keep the order of dropped files.","items":[{"text":"Which order?","options":["As dropped","By name"],"recommended":"As dropped"}]}"#
                if let asked = try? TodoStore.shared.add(title: "Keep the drop order", project: repo, projectName: "AI Illuminati"),
                   let question = try? JSONDecoder().decode(TodoQuestion.self, from: Data(json.utf8)) {
                    try? TodoStore.shared.change(asked.id) { $0.state = .needsYou; $0.question = question; $0.stateSince = Date() }
                }
            }
            var notes = Conversation(); notes.title = "Todo list structure idea"; notes.turns = [ChatTurn(question: "ideas")]; notes.pinned = true
            chat.conversations = [conversation, meeting, todoRoom, linked("Face expressions", face), linked("Lamb wave draft", papers), notes]
            SidebarFold.shared.toggle("project." + face.common)
            // --working: two chats answering (one stopping) listed under Search.
            if CommandLine.arguments.contains("--working") {
                chat.runningRooms = [todoRoom.id, chat.conversations[3].id, notes.id]; chat.stoppingRooms = [notes.id]
            }
            // CHAT_BOARD=todo|info|all opens the project's folder (its whole TODO board, or Project info with the TODO panel) or every project's board.
            if let tab = ProcessInfo.processInfo.environment["CHAT_BOARD"] {
                if tab == "info" {
                    // Project info's folder list: an edited folder, a file, and a Git folder turned off (in the preview home).
                    let home = URL(fileURLWithPath: AccountStore.home), key = SidebarProjects.key(repo)
                    let notes = home.appendingPathComponent("Design notes"), spec = home.appendingPathComponent("spec.pdf"), old = home.appendingPathComponent("AI Illuminati-old")
                    try? FileManager.default.createDirectory(at: notes, withIntermediateDirectories: true)
                    try? FileManager.default.createDirectory(at: old.appendingPathComponent(".git"), withIntermediateDirectories: true)
                    try? Data("%PDF".utf8).write(to: spec)
                    _ = try? ProjectInfoStore.shared.addFolders([notes, spec, old], to: key)
                    let path = { (url: URL) in url.resolvingSymlinksInPath().standardizedFileURL.path }
                    try? ProjectInfoStore.shared.setWritable(path(notes), true, in: key, workRoot: repo.root)
                    try? ProjectInfoStore.shared.setRead(path(old), false, in: key)
                }
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
        if CommandLine.arguments.contains("--inbox") {
            // The Inbox and Unread sidebar (with --projects for a TODO result).
            func ended(_ title: String, final: String?, error: String?) -> Conversation {
                var c = Conversation(); c.title = title; c.turns = [ChatTurn(question: title)]; c.turns[0].final = final; c.turns[0].error = error; return c
            }
            let failed = ended("Weekly report", final: nil, error: "The AI stopped: out of usage")
            let answered = ended("Trip ideas", final: "Three routes along the coast, with times.", error: nil)
            var paper = ended("Lamb wave figures", final: "Which figure should I update?", error: nil)
            paper.turns[0].inputRequest = "Which figure should I update?"; paper.turns[0].answeredAt = Date()
            chat.conversations += [failed, answered, paper]
            chat.unreadRooms = [failed.id: Date(), answered.id: Date().addingTimeInterval(-120)]
            ProjectCenter.shared.requests = [ProjectApproval(room: conversation.id, run: UUID(), title: "Run project command", detail: "fixture", deadline: Date().addingTimeInterval(600))]
            chat.inboxShown = true
        }
        if ProcessInfo.processInfo.environment["CHAT_KOREAN"] == "1" { AppLanguage.current = .korean }
        if CommandLine.arguments.contains("--subrooms") {
            // Sub-rooms (SubRoomViews.swift), CHAT_SUBROOMS=waiting|running|approval|stopped|done: the split card waiting
            // for approval; two sub-rooms under way (one merged with a warning); a sub-room's command gathered here;
            // stopped (Continue/Discard); ended (folded into one row, ✓ Done).
            let state = ProcessInfo.processInfo.environment["CHAT_SUBROOMS"] ?? "running"
            let repo = ProjectBinding(root: "/tmp/preview/AI Illuminati", common: "/tmp/preview/AI Illuminati/.git", remote: "origin", remoteURL: "")
            var main = Conversation(); main.title = "Sub-room P3: screens"
            var ask = ChatTurn(question: "Do P3: the progress cards, the sidebar's sub-rooms and the gathered approval card.")
            ask.mode = 0; ask.final = state == "done" ? "Both parts are merged, the full test passed and the push is done." : nil
            ask.finalBy = "Claude (Personal)"; ask.status = ["running", "waiting", "approval"].contains(state) ? "Claude (Personal) · working on project" : ""
            ask.askedAt = Date().addingTimeInterval(-15 * 60)
            main.turns = [ask]
            main.workspace = WorkspaceBinding(roots: [WorkspaceRoot(path: repo.root, directory: true, writable: true)], project: repo)
            func part(_ n: Int, _ goal: String, _ owned: [String], _ name: String, _ edit: (inout Split.Part) -> Void) -> Split.Part {
                var p = Split.Part(n: n, room: UUID(), goal: goal, owned: owned, forbidden: [], interfaces: "", done: "tests pass")
                p.name = name; p.tree = SubWork.Tree(path: "/tmp/preview/worktrees/\(n)", branch: "sub/a1b2c3d4/\(n)", base: "")
                p.started = Date().addingTimeInterval(-Double(14 - n * 3) * 60); edit(&p); return p
            }
            let parts = [
                part(1, "Sidebar: sub-room rows and badges", ["app/modules/AIChat/SidebarProjects.swift"], "Claude (School)") { p in
                    switch state {
                    case "running", "approval": p.state = .running; p.live = true; p.sent = ["Name the row view SubRoomRow"]
                    case "stopped": p.state = .cancelled; p.finished = Date().addingTimeInterval(-60)
                    default: p.state = .merged; p.finished = Date().addingTimeInterval(-5 * 60); p.sha = "4f2a9c1e77"; p.tests = "--affected: 12 passed"; p.removed = state == "done"
                    }
                },
                part(2, "Cards: split and progress cards", ["app/modules/AIChat/SubRoomViews.swift"], "ChatGPT (School)") { p in
                    p.finished = Date().addingTimeInterval(-2 * 60); p.sha = "9b1d03aa52"; p.tests = "--affected: 8 passed"
                    switch state {
                    case "stopped": p.state = .reported
                    case "running", "approval": p.state = .merged; p.outside = ["docs/MODULES.md"]
                    default: p.state = .merged; p.removed = state == "done"
                    }
                },
            ]
            var split = Split(id: "a1b2c3d4", room: main.id, repo: repo.root, common: repo.common, auto: state != "stopped", parts: parts)
            split.mine = "Gathered approval card and the command identity"
            split.paused = state == "stopped"; split.closed = state == "done"
            var subs: [Conversation] = []
            if state != "waiting" {
                for p in parts {
                    var room = Conversation(id: p.room); room.title = "Sub-room \(p.n): " + p.goal; room.turns = [ChatTurn(question: p.goal)]
                    room.subOf = SubRoomLink(room: main.id, split: split.id, n: p.n); room.meetingOf = MeetingLink(room: main.id, turn: ask.id)
                    subs.append(room)
                }
                chat.splitRecords[main.id] = [split]
                if ["running", "approval"].contains(state) { chat.runningRooms = Set([main.id] + subs.prefix(1).map(\.id)) }
            } else {
                chat.runningRooms = [main.id]
            }
            var other = Conversation(); other.title = "Face expressions"; other.turns = [ChatTurn(question: "faces")]
            other.workspace = main.workspace
            // With the sub-rooms, a meeting and three subagent records (one working, one done, one failed) under the same chip.
            var attached: [Conversation] = []
            if ["running", "done"].contains(state) {
                var meeting = Conversation(); meeting.title = "Meeting"; meeting.turns = [ChatTurn(question: "When to switch Drive over?")]
                meeting.meetingOf = MeetingLink(room: main.id, turn: ask.id); meeting.createdAt = Date().addingTimeInterval(-40 * 60)
                attached.append(meeting)
                for (i, agent) in [("Explore", "Find the sidebar rows", true, false), ("general-purpose", "Check the API", false, false),
                                   ("Plan", "Split the steps", false, true)].enumerated() {
                    var record = Conversation(); record.title = "Agent: " + agent.1; record.turns = [ChatTurn(question: agent.1)]
                    record.meetingOf = MeetingLink(room: main.id, turn: ask.id); record.createdAt = Date().addingTimeInterval(-Double(3 + i * 4) * 60)
                    record.agentOf = AgentRoomLink(room: main.id, turn: ask.id, toolUseID: "t\(i)", description: agent.1, type: agent.0,
                                                   running: agent.2 && state == "running")
                    if !(agent.2 && state == "running") { record.agentOf?.endedAt = Date(); record.agentOf?.failed = agent.3 }
                    attached.append(record)
                }
            }
            chat.conversations = [main] + subs + attached + [other]; chat.currentID = main.id
            if state == "waiting" {
                var plan = split; plan.id = ""; plan.auto = false; plan.paused = false
                for i in plan.parts.indices { plan.parts[i].state = .creating; plan.parts[i].tree = nil }
                let request = ProjectApproval(room: main.id, run: UUID(), title: "하위방으로 나누기 / Split into sub-rooms", detail: repo.root)
                chat.splitPlans[request.id] = plan
                ProjectCenter.shared.requests = [request]
            }
            if state == "approval", let first = subs.first {
                var request = ProjectApproval(room: first.id, run: UUID(), title: "프로젝트 실행 / Run project command",
                                              detail: "Runs outside the AI sandbox as your user.\n/tmp/preview/worktrees/1\n/bin/zsh tools/tests/run_mode2.sh --affected app/modules/AIChat/SidebarProjects.swift")
                request.command = "test-affected: /bin/zsh tools/tests/run_mode2.sh --affected app/modules/AIChat/SidebarProjects.swift"; request.same = "k"
                ProjectCenter.shared.requests = [request]
            }
        }
        for appearance in [NSAppearance.Name.darkAqua, .aqua] {
            let host = NSHostingController(rootView: ChatView(discussion: chat, model: model).environment(\.colorScheme, appearance == .darkAqua ? .dark : .light))
            host.sizingOptions = []
            let window = ChatDragWindow(contentViewController: host)
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            window.titlebarSeparatorStyle = .none; window.titleVisibility = .hidden
            window.appearance = NSAppearance(named: appearance)
            window.contentMinSize = ChatViewSize.minSize
            // CHAT_WIDTH renders a narrow window (CHAT_HEIGHT a taller one); CHAT_SIDEBAR=1 opens the sliding sidebar there, 0 hides the sidebar.
            let width = Double(ProcessInfo.processInfo.environment["CHAT_WIDTH"] ?? "") ?? 1040
            chat.sidebarOverlay = ProcessInfo.processInfo.environment["CHAT_SIDEBAR"] == "1"
            chat.sidebarHidden = ProcessInfo.processInfo.environment["CHAT_SIDEBAR"] == "0"
            let height = Double(ProcessInfo.processInfo.environment["CHAT_HEIGHT"] ?? "") ?? 720
            window.setContentSize(NSSize(width: width, height: height))
            for _ in 0..<5 { host.view.layoutSubtreeIfNeeded(); window.displayIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.04)) }
            let view = window.contentView!.superview ?? host.view
            let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(appearance == .darkAqua ? "chat-dark.png" : "chat-light.png"))
            window.contentView = nil
        }
    }
}
