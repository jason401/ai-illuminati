import Foundation
import AIAccounts

// Which model a cloud account answers with (Settings by AI, the Model column). Nothing saved is "Auto": no model
// option, so the CLI picks its own default as before. Per account, since plans differ in what they offer
// (a school Claude may lack a model a personal one has). A model the account cannot use fails the answer with
// the CLI's own error; there is no silent fallback.
public enum CloudModels {
    static let key = "cloudModels"   // [account id: model name]

    public static func model(_ account: Account, defaults: UserDefaults = .app) -> String? {
        guard account.provider != .ollama, let name = (defaults.dictionary(forKey: key) as? [String: String])?[account.id],
              valid(name) else { return nil }
        return name
    }

    public static func set(_ name: String?, for account: Account, defaults: UserDefaults = .app) {
        var all = defaults.dictionary(forKey: key) as? [String: String] ?? [:]
        let name = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let name, valid(name) { all[account.id] = name } else { all[account.id] = nil }
        defaults.set(all, forKey: key)
    }

    // A model name, never an option: letters first, then only name characters ("opus[1m]", "gpt-6.1-sol").
    public static func valid(_ name: String) -> Bool {
        name.range(of: #"^[A-Za-z0-9][A-Za-z0-9._:/\[\]-]{0,79}$"#, options: .regularExpression) != nil
    }

    // Adds the model to a finished command line (after the workspace and stdin rewriting, which rely on positions).
    // Codex takes it as a top-level -c in front, which `exec` and `exec resume` both honor.
    static func apply(_ arguments: [String], provider: Account.Provider, model: String?) -> [String] {
        guard let model, valid(model) else { return arguments }
        switch provider {
        case .claude, .gemini: return arguments + ["--model", model]
        case .codex: return ["-c", "model=\"\(model)\""] + arguments
        case .ollama: return arguments
        }
    }

    public struct Choice: Equatable {
        public let id: String
        public let title: String
    }

    // Claude Code's aliases always point at the latest model of each kind. The titles name the versions they point
    // at now, until an answer from this account shows what an alias really ran on.
    public static let claudeChoices = [Choice(id: "fable", title: "Fable 5.1"), Choice(id: "opus", title: "Opus 5.5"),
                                Choice(id: "sonnet", title: "Sonnet 5.5"), Choice(id: "haiku", title: "Haiku 5.5")]

    // Claude's aliases do not say which version they are now: each Claude answer's stream names the model it ran on
    // ("claude-fable-5-1"), kept per account and pick ("" = Auto), so the menu can show "Fable 5.1".
    public static let seenKey = "cloudModelsSeen"   // [account id: [pick: model id]]

    static func noteSeen(_ output: String, account: Account, picked: String?, defaults: UserDefaults = .app) {
        guard account.provider == .claude, let id = resolved(output) else { return }
        var all = defaults.dictionary(forKey: seenKey) as? [String: [String: String]] ?? [:]
        guard all[account.id]?[picked ?? ""] != id else { return }
        all[account.id, default: [:]][picked ?? ""] = id
        defaults.set(all, forKey: seenKey)
    }

    static func seen(_ account: Account, picked: String?, defaults: UserDefaults = .app) -> String? {
        (defaults.dictionary(forKey: seenKey) as? [String: [String: String]])?[account.id]?[picked ?? ""]
    }

    // The model of the first assistant message or the init line in Claude's stream-json output.
    static func resolved(_ output: String) -> String? {
        for line in output.split(separator: "\n") where line.contains("\"model\"") {
            guard let json = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
            let name = (json["type"] as? String == "system" ? json["model"] : (json["message"] as? [String: Any])?["model"]) as? String
            if let name, valid(name), name.hasPrefix("claude-") { return name }
        }
        return nil
    }

    // The model one answer ran on, only when the CLI's output names it (never the pick or an earlier answer's).
    // Only from JSON event output (`events`): plain output is the answer itself, which may hold any JSON.
    // Claude stream-json or Codex assistant events. Gemini uses its exact conversation log below.
    static func reported(_ output: String, provider: Account.Provider, events: Bool) -> String? {
        guard events else { return nil }
        if provider == .claude { return resolved(output) }
        guard provider == .codex else { return nil }
        var found: String?
        for line in output.split(separator: "\n") {
            guard let json = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
            let type = json["type"] as? String
            let item = json["item"] as? [String: Any]
            if type == "turn.started" || (type == "item.completed" && item?["type"] as? String == "agent_message") {
                // Reset on a later answer with no model: an earlier step's model may have changed.
                found = (json["model"] ?? item?["model"]) as? String
            }
        }
        return found.flatMap { valid($0) ? $0 : nil }
    }

    // Bind to the ID emitted by this process, never the newest log. Gemini starts a new conversation;
    // resumed Codex sessions identify the model only through this invocation's turn_context.
    static func logged(_ output: String, provider: Account.Provider, home: String, since: Date, directory: String) -> String? {
        let events = output.split(separator: "\n").compactMap { line in
            try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
        }
        let ids = Set(events.compactMap { event -> String? in
            if provider == .codex, event["type"] as? String == "thread.started" { return event["thread_id"] as? String }
            if provider == .gemini, ["system", "result"].contains(event["type"] as? String ?? "") { return event["session_id"] as? String }
            if provider == .gemini { return GeminiEvents.conversation(event) }
            return nil
        })
        guard ids.count == 1, let id = ids.first, UUID(uuidString: id) != nil else { return nil }
        let root = URL(fileURLWithPath: home)
        if provider == .gemini {
            let file = root.appendingPathComponent(id + "/.system_generated/logs/transcript.jsonl")
            guard let rows = logRows(file) else { return nil }
            let replies = rows.filter { $0["type"] as? String == "PLANNER_RESPONSE" }
            guard let last = replies.last, let model = last["model"] as? String, valid(model) else { return nil }
            return model
        }
        guard provider == .codex else { return nil }
        var matches: [URL] = []
        for folder in ["sessions", "archived_sessions"] {
            guard let walk = FileManager.default.enumerator(at: root.appendingPathComponent(folder), includingPropertiesForKeys: nil) else { continue }
            for case let file as URL in walk where file.lastPathComponent.lowercased().hasSuffix(id.lowercased() + ".jsonl") { matches.append(file) }
        }
        guard matches.count == 1, let rows = logRows(matches[0]),
              let meta = rows.first(where: { $0["type"] as? String == "session_meta" })?["payload"] as? [String: Any],
              (meta["id"] as? String)?.lowercased() == id.lowercased(), let cwd = meta["cwd"] as? String,
              URL(fileURLWithPath: cwd).resolvingSymlinksInPath().path == URL(fileURLWithPath: directory).resolvingSymlinksInPath().path else { return nil }
        let turns = rows.filter { row in
            guard row["type"] as? String == "turn_context", let stamp = row["timestamp"] as? String,
                  let date = logDate(stamp) else { return false }
            return date >= since
        }
        // More than one new turn could be concurrent resumes of the same thread: attribute neither.
        guard turns.count == 1, let payload = turns[0]["payload"] as? [String: Any],
              let model = payload["model"] as? String, valid(model) else { return nil }
        return model
    }

    private static func logDate(_ value: String) -> Date? {
        let format = ISO8601DateFormatter()
        format.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = format.date(from: value) { return date }
        format.formatOptions = [.withInternetDateTime]
        return format.date(from: value)
    }

    private static func logRows(_ file: URL) -> [[String: Any]]? {
        // Model lookup must not load multi-GB histories. Keep the current tail plus session_meta's first line.
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        let limit: UInt64 = 4 * 1024 * 1024
        try? handle.seek(toOffset: 0)
        let head = (try? handle.read(upToCount: 65536)) ?? Data()
        let offset = size > limit ? size - limit : 0
        guard (try? handle.seek(toOffset: offset)) != nil, let data = try? handle.read(upToCount: Int(limit)) else { return nil }
        var lines = String(decoding: data, as: UTF8.self).components(separatedBy: "\n")
        if offset > 0 {
            lines.removeFirst() // partial first line
            if let first = String(decoding: head, as: UTF8.self).components(separatedBy: "\n").first { lines.insert(first, at: 0) }
        }
        var rows: [[String: Any]] = []
        for line in lines where !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard let row = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { return nil }
            rows.append(row)
        }
        return rows
    }

    // "claude-fable-5-1" → "Fable 5.1", "claude-haiku-4-5-20251001" → "Haiku 4.5", "claude-opus-5-5[1m]" → "Opus 5.5 [1m]".
    public static func versionTitle(_ id: String) -> String {
        var name = id.hasPrefix("claude-") ? String(id.dropFirst(7)) : id
        var tail = ""
        if let bracket = name.firstIndex(of: "[") { tail = " " + name[bracket...]; name = String(name[..<bracket]) }
        let parts = name.split(separator: "-").map(String.init)
        let words = parts.filter { Int($0) == nil }, numbers = parts.filter { Int($0) != nil && $0.count < 8 }
        guard !words.isEmpty, !numbers.isEmpty else { return id }
        return words.map(\.capitalized).joined(separator: " ") + " " + numbers.joined(separator: ".") + tail
    }

    // What the menu shows for a pick that ran on `id`: a typed option such as "[1m]" stays visible even when the
    // stream names only the base model.
    public static func seenTitle(_ id: String, picked: String?) -> String {
        let title = versionTitle(id)
        guard let picked, let bracket = picked.firstIndex(of: "["), !title.hasSuffix(String(picked[bracket...])) else { return title }
        return title + " " + picked[bracket...]
    }

    // The models Codex lists for this account, from the cache it keeps in its folder (missing or old: none).
    public static func codexChoices(_ account: Account) -> [Choice] {
        guard let data = FileManager.default.contents(atPath: account.codexHome + "/models_cache.json"),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = object["models"] as? [[String: Any]] else { return [] }
        return models.compactMap { model in
            guard let slug = model["slug"] as? String, valid(slug), (model["visibility"] as? String ?? "list") == "list" else { return nil }
            return Choice(id: slug, title: model["display_name"] as? String ?? slug)
        }
    }

    // `agy models` prints "id<TAB>name" lines (after a "Fetching…" line).
    static func parseGemini(_ output: String) -> [Choice] {
        output.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "\t", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2, valid(parts[0]) else { return nil }
            return Choice(id: parts[0], title: parts[1])
        }
    }

    // Asks agy for its list in the background (it needs the network); empty when agy is missing, slow or fails.
    public static func loadGemini(_ account: Account, done: @escaping ([Choice]) -> Void) {
        guard ToolHome.agyInstalled else { return done([]) }
        DispatchQueue.global(qos: .utility).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: ToolHome.path + "/.local/bin/agy")
            process.arguments = ["models"]
            process.environment = account.environment
            let out = Pipe()
            process.standardOutput = out
            process.standardError = FileHandle.nullDevice
            process.standardInput = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return DispatchQueue.main.async { done([]) } }
            let timer = DispatchWorkItem { if process.isRunning { process.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + 20, execute: timer)
            let data = out.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            timer.cancel()
            let choices = process.terminationStatus == 0 ? parseGemini(String(decoding: data, as: UTF8.self)) : []
            DispatchQueue.main.async { done(choices) }
        }
    }
}
