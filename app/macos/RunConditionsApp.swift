import Foundation
import AIAccounts
import AIRuntime
import AIWorkspace
import AIIntegrations
import AIChat

// What Answerer starts each tool with (RunConditions), put together by the app: Answerer knows nothing about
// folders, project work, AI Face or AutoGuard, and Workspace (Workspace.swift) gives only what this needs: the
// folder rules (`arguments`, `readRequests`, with the app's tool gateway), whether it is project work
// (`projectRunID`) and whether full access is on (`fullAccessActive`).
extension RunConditions {
    static func app(_ account: Account, _ workspace: WorkspaceInvocation? = nil, screen: Bool = false, answer: ChatApp.ScreenAnswer? = nil) -> RunConditions {
        var run = RunConditions()
        // The face goes through the app as "illuminati", never through Codex's own AI Face server ("gpt").
        if account.provider == .codex { run.prefix = FaceLink.codexOff(account) }
        let screenScope = (screen || answer != nil) && MacControl.enabled(account) && (workspace?.binding.origin ?? .member) == .member ? UUID() : nil
        if let scope = screenScope {
            // The Mac control session lives as long as the grant: its cards go to the answer's chat, Esc stops that answer.
            let name = account.name.hasPrefix(account.provider.title) ? account.name : "\(account.provider.title) (\(account.name))"
            MacControl.begin(scope, MacControl.Session(account: account, room: answer?.room ?? workspace?.room, speaker: answer?.speaker ?? name,
                                                       stop: answer?.stop ?? {}, note: answer?.note ?? { _ in }))
            run.screenTools = RunConditions.ScreenTools { ToolHub.shared.revoke(screen: scope); MacControl.end(scope) }
        }
        guard let workspace else {
            if let scope = screenScope {
                let plain = WorkspaceInvocation(binding: WorkspaceBinding(roots: []), room: UUID(), account: account)
                run.screenTools = RunConditions.ScreenTools(arguments: { original, directory in
                    guard let link = ToolHub.link(plain, screenScope: scope, screenOnly: true) else { return original }
                    return try link.screenArguments(provider: account.provider, original: original, directory: directory)
                }, finish: { ToolHub.shared.revoke(screen: scope); MacControl.end(scope) })
            }
            if account.provider == .gemini, AICapabilities.rule(account, .web) != .off {
                run.beforeStart = GeminiLinks.allowWeb
            }
            return run
        }
        let project = workspace.binding.projectRunID != nil
        let guarded = workspace.binding.fullAccessActive && AICapabilities.rule(account, .terminal) != .off
        // Project work: one cancellable process group (project_process.py), stopped as a whole at the end.
        if project {
            run.wrapper = ["/usr/bin/python3", WorkspaceInvocation.resources.appendingPathComponent("project_process.py").path]
            run.processGroup = true
            run.thinkHard = true
        }
        run.environment = { base in
            var environment = base
            if project { environment["AI_ILLUMINATI_PROJECT_PROCESS"] = "1" }
            if guarded { environment = FullAutoGuard.environment(environment) }
            return environment
        }
        // The arguments know who answers (the chat tools ask for it); file requests are read as before, without it.
        var answering = workspace
        answering.account = account
        if workspace.binding.fullAccessActive && !guarded {
            // Keep this launch isolated when the terminal is off, even if it is enabled before arguments are built.
            answering.binding.fullAuto = false
            answering.binding.fullAccess = false
        }
        if account.provider == .ollama, workspace.binding.origin != .consulted {
            let context = ToolContext(room: workspace.room, roots: workspace.binding.roots,
                                      projectRun: workspace.binding.projectRunID, projectGeneration: workspace.binding.projectGeneration, asker: account,
                                      turn: MemoryLink.shared.newestTurn(workspace.room), origin: workspace.binding.origin ?? .member)
            let call: (String, [String: Any]) -> String = { name, arguments in
                let result = SkillLink.shared.call(name, arguments, context: context)
                return (result["content"] as? [[String: Any]])?.first?["text"] as? String ?? ""
            }
            run.readSkill = { call("skill_read", ["name": $0]) }
            if SkillLink.shared.tools(context: context).contains(where: {
                let name = $0["name"] as? String
                return name == "skill_save" || name == "skill_delete"
            }) {
                run.editSkill = call
            }
        }
        run.folders = RunConditions.Folders(directory: NativeSessions.directory(workspace.room),
            arguments: { try answering.arguments(provider: account.provider, original: $0, directory: $1, web: $2,
                tools: { ToolHub.link($0, screenScope: screenScope) },
                screenTools: { invocation in screenScope.flatMap { ToolHub.link(invocation, screenScope: $0, screenOnly: true) } }) },
            read: { try workspace.readRequests($0, directory: $1, token: $2, tools: ToolHub.workspaceLink) })
        return run
    }
}

extension GeminiLinks {
    // Gemini (agy) can open YouTube links: in one-shot mode it cannot ask for permission, so agy needs
    // an allow rule in ~/.gemini/antigravity-cli/settings.json. agy reads the page (title, channel,
    // description), it does not watch the video. Rules are only added, never removed; the file is
    // backed up once, and left alone if it cannot be read. Only for plain chat (no linked folders).
    // "read_url(*)" lets it open any page it finds with its web search (read only; commands stay blocked).
    static let rules = ["read_url(*)", "read_url(youtube.com)", "read_url(www.youtube.com)", "read_url(m.youtube.com)", "read_url(youtu.be)"]

    static func allowWeb() {
        let path = Login.home + "/.gemini/antigravity-cli/settings.json"
        var settings: [String: Any] = [:]
        if FileManager.default.fileExists(atPath: path) {
            guard let data = FileManager.default.contents(atPath: path),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            settings = json
        }
        var permissions = settings["permissions"] as? [String: Any] ?? [:]
        var allow = permissions["allow"] as? [String] ?? []
        let missing = rules.filter { !allow.contains($0) }
        guard !missing.isEmpty else { return }
        let backup = path + ".backup-before-ai-illuminati"
        if FileManager.default.fileExists(atPath: path), !FileManager.default.fileExists(atPath: backup) {
            try? FileManager.default.copyItem(atPath: path, toPath: backup)
        }
        allow += missing
        permissions["allow"] = allow
        settings["permissions"] = permissions
        if let data = try? JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys]) {
            try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
            NSLog("AI Illuminati: added to agy settings: \(missing.joined(separator: ", "))")
        }
    }
}
