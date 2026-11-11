import Foundation

// Which model a cloud account answers with (Settings → Accounts, each row's model menu). Nothing saved is "Auto": no model
// option, so the CLI picks its own default as before. Per account, since plans differ in what they offer
// (a school Claude may lack a model a personal one has). A model the account cannot use fails the answer with
// the CLI's own error; there is no silent fallback.
enum CloudModels {
    static let key = "cloudModels"   // [account id: model name]

    static func model(_ account: Account, defaults: UserDefaults = .app) -> String? {
        guard account.provider != .ollama, let name = (defaults.dictionary(forKey: key) as? [String: String])?[account.id],
              valid(name) else { return nil }
        return name
    }

    static func set(_ name: String?, for account: Account, defaults: UserDefaults = .app) {
        var all = defaults.dictionary(forKey: key) as? [String: String] ?? [:]
        let name = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let name, valid(name) { all[account.id] = name } else { all[account.id] = nil }
        defaults.set(all, forKey: key)
    }

    // A model name, never an option: letters first, then only name characters ("opus[1m]", "gpt-6.1-sol").
    static func valid(_ name: String) -> Bool {
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

    struct Choice: Equatable {
        let id: String
        let title: String
    }

    // Claude Code's aliases always point at the latest model of each kind.
    static let claudeChoices = [Choice(id: "fable", title: "Fable"), Choice(id: "opus", title: "Opus"),
                                Choice(id: "sonnet", title: "Sonnet"), Choice(id: "haiku", title: "Haiku")]

    // Claude's aliases do not say which version they are now: each Claude answer's stream names the model it ran on
    // ("claude-fable-5-1"), kept per account and pick ("" = Auto), so the menu can show "Fable 5.1".
    static let seenKey = "cloudModelsSeen"   // [account id: [pick: model id]]

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

    // "claude-fable-5-1" → "Fable 5.1", "claude-haiku-4-5-20251001" → "Haiku 4.5", "claude-opus-5-5[1m]" → "Opus 5.5 [1m]".
    static func versionTitle(_ id: String) -> String {
        var name = id.hasPrefix("claude-") ? String(id.dropFirst(7)) : id
        var tail = ""
        if let bracket = name.firstIndex(of: "[") { tail = " " + name[bracket...]; name = String(name[..<bracket]) }
        let parts = name.split(separator: "-").map(String.init)
        let words = parts.filter { Int($0) == nil }, numbers = parts.filter { Int($0) != nil && $0.count < 8 }
        guard !words.isEmpty, !numbers.isEmpty else { return id }
        return words.map(\.capitalized).joined(separator: " ") + " " + numbers.joined(separator: ".") + tail
    }

    // The models Codex lists for this account, from the cache it keeps in its folder (missing or old: none).
    static func codexChoices(_ account: Account) -> [Choice] {
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
    static func loadGemini(_ account: Account, done: @escaping ([Choice]) -> Void) {
        guard Login.agyInstalled else { return done([]) }
        DispatchQueue.global(qos: .utility).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: Login.home + "/.local/bin/agy")
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
