import Foundation
import AIAccounts
import AIRuntime
import AIWorkspace
import AIIntegrations

// What Answerer starts each tool with (RunConditions), put together by the app: Answerer knows nothing about
// folders, project work, AI Face or AutoGuard, and Workspace (Workspace.swift) gives only what this needs: the
// folder rules (`arguments`, `readRequests`, with the app's tool gateway), whether it is project work
// (`projectRunID`) and whether full access is on (`fullAccessActive`).
extension RunConditions {
    static func app(_ account: Account, _ workspace: WorkspaceInvocation? = nil) -> RunConditions {
        var run = RunConditions()
        // The face goes through the app as "illuminati", never through Codex's own AI Face server ("gpt").
        if account.provider == .codex { run.prefix = FaceLink.codexOff(account) }
        guard let workspace else {
            if account.provider == .gemini { run.beforeStart = GeminiLinks.allowWeb }
            return run
        }
        let project = workspace.binding.projectRunID != nil, guarded = workspace.binding.fullAccessActive
        // Project work: one cancellable process group (project_process.py), stopped as a whole at the end.
        if project {
            run.wrapper = ["/usr/bin/python3", WorkspaceInvocation.resources.appendingPathComponent("project_process.py").path]
            run.processGroup = true
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
        run.folders = RunConditions.Folders(directory: NativeSessions.directory(workspace.room),
            arguments: { try answering.arguments(provider: account.provider, original: $0, directory: $1, web: $2, tools: ToolHub.workspaceLink) },
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
