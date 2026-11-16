import Foundation
import AIAccounts

// Tokens actually sent and received, summed from the session logs the CLIs write themselves (read only):
//   Claude Code: <config>/projects/**/*.jsonl, one `message.usage` per answer. A message is written over several lines
//                and its usage can grow on a later line (the output while it streamed): each message id counts once,
//                each field at its highest value, in the hour of its first line. Ids are unique across files (measured),
//                so one seen in another file is not counted again (a copied or forked session).
//   Codex:       <CODEX_HOME>/sessions|archived_sessions/**/*.jsonl and *.jsonl.zst (old sessions, compressed), whose
//                `token_count` events carry the session's running total. Each session (the UUID in the file name)
//                counts every field up to its highest total once, wherever it is: a session moved to the archive,
//                compressed or copied adds nothing again; a total that goes down (never seen) adds nothing until it
//                passes the highest. Each rise goes to the hour it happened. `input_tokens` includes the cached part;
//                `reasoning_output_tokens` is part of `output_tokens`.
//   Gemini (agy): ~/.gemini/antigravity-cli/brain/<id>/.system_generated/logs/transcript.jsonl, one PLANNER_RESPONSE
//                per model step with `input_tokens` (without the cached part: a step's input comes back as the next
//                step's cache_read_tokens, measured), `cache_read_tokens`, `output_tokens`. No cache writes. One folder
//                for every Gemini account: it has no account in it, so it is "Gemini, account unknown".
//   The app:     calls that leave no log (Claude --no-session-persistence, Codex --ephemeral) record the usage the CLI
//                returned (`recordApp`), with what the call was for, in token-usage-app.jsonl (support folder).
// The desktop apps' Code/agent work writes to ~/.claude and ~/.codex too (Claude `entrypoint`, Codex `originator`);
// chats on the web and the desktop apps' plain chat are in no log.
// Every file is read once: what was read is kept in token-usage.json (support folder), by UTC hour, model, session and
// working folder (no text), and only new lines are read later. A log the CLI deleted (Claude Code removes sessions
// after 30 days) keeps its sums there. Sums kept by the older format (version 2: by this Mac's local day, nothing else)
// stay as they were: day only, the time zone they were counted in unknown.
public struct TokenCounts: Codable, Equatable {
    public var input = 0        // not from the cache
    public var cacheWrite = 0
    public var cacheRead = 0
    public var output = 0       // includes thinking (Claude) and reasoning (Codex)
    public var reasoning: Int?  // the part of output the CLI reported as reasoning; nil: not reported (not 0)

    public init(input: Int = 0, cacheWrite: Int = 0, cacheRead: Int = 0, output: Int = 0, reasoning: Int? = nil) {
        self.input = input; self.cacheWrite = cacheWrite; self.cacheRead = cacheRead; self.output = output; self.reasoning = reasoning
    }
    // New tokens: everything except reading the cache back (which is most of an agent loop's total).
    public var fresh: Int { input + cacheWrite + output }
    public var total: Int { fresh + cacheRead }
    public var isEmpty: Bool { total == 0 }

    public static func + (a: TokenCounts, b: TokenCounts) -> TokenCounts {
        TokenCounts(input: a.input + b.input, cacheWrite: a.cacheWrite + b.cacheWrite, cacheRead: a.cacheRead + b.cacheRead,
                    output: a.output + b.output, reasoning: a.reasoning == nil && b.reasoning == nil ? nil : (a.reasoning ?? 0) + (b.reasoning ?? 0))
    }
    public static func += (a: inout TokenCounts, b: TokenCounts) { a = a + b }
}

// One sum: one log folder's tokens in one hour (UTC) for one model and session. Older sums have only a day.
public struct TokenEntry: Equatable {
    public enum Origin: String, Codable { case desktop, terminal, other }
    public enum Source: String, Codable { case log, app, legacy }   // legacy: kept by an older format, a day and nothing else

    public var provider: Account.Provider
    public var accountID: String?     // nil: a folder no account uses (outside the app), or Gemini's shared one
    public var accountName: String?   // the account's name, which is what matches it on other Macs (TokenSync)
    public var device = ""            // "": this Mac, else the other Mac's id (TokenSync)
    public var folder: String
    public var origin: Origin?        // which program wrote the logs (Claude `entrypoint`, Codex `originator`)
    public var source: Source
    public var start: Date            // the hour's start; legacy: the day's start as this Mac counts days now
    public var hourly: Bool
    public var model: String?
    public var session: String?       // the CLI's session id (Codex, Claude) or Gemini's conversation folder
    public var project: String?       // the working folder the CLI logged (cwd)
    public var kind: String?          // app calls: what the call was for (routing, meeting, ...)
    public var counts: TokenCounts

    public init(provider: Account.Provider, accountID: String?, accountName: String? = nil, folder: String, origin: Origin?, source: Source, start: Date, hourly: Bool,
                model: String?, session: String?, project: String?, kind: String?, counts: TokenCounts) {
        self.provider = provider; self.accountID = accountID; self.accountName = accountName; self.folder = folder; self.origin = origin; self.source = source
        self.start = start; self.hourly = hourly; self.model = model; self.session = session; self.project = project
        self.kind = kind; self.counts = counts
    }
}

// What was found in one log folder, so the window can tell "no log" from "nothing used".
public struct TokenFolder: Equatable {
    public var provider: Account.Provider
    public var accountID: String?
    public var folder: String
    public var exists: Bool
    public var files = 0
    public var compressed = 0     // .zst
    public var failed = 0         // could not be read (permissions, a broken .zst)
    public var deleted = 0        // logs the CLI deleted: their sums are kept
    public var legacy = 0         // of those, kept by the older format (day only)
    public var first: Date?       // the earliest token seen
    public var last: Date?
}

public struct TokenReport: Equatable {
    public var entries: [TokenEntry]
    public var folders: [TokenFolder]
    public var readAt: Date
}

public enum TokenLedger {
    private static let lock = NSLock()

    private struct FileState: Codable {
        var n: Int                        // a short id (Claude message owners, Codex session owners)
        var size: Int64
        var offset: Int64                 // read up to here (the end of the last whole line; .zst: in the unpacked text)
        var recent: [String: [Int]]? = nil   // Claude: message id → [hour, input, cache write, cache read, output] counted
        var steps: [Int]? = nil           // Gemini: the last step indexes, so a repeated step counts once
        var model: String? = nil          // Codex: the model of the current turn
        var origin: String? = nil         // Claude `entrypoint`, Codex `originator`
        var session: String? = nil
        var project: String? = nil
        var gone: Bool? = nil             // the log was deleted: only its sums are left
        var failed: Bool? = nil
        var buckets: [String: TokenCounts] = [:]   // "<UTC hour since 1970>|<model>"
        var legacy: [String: TokenCounts]? = nil   // version 2 sums by local day ("yyyy-MM-dd")
    }
    private struct Session: Codable {
        var owner: Int                    // the file that counted it
        var high: [Int]                   // input, cached, cache write, output, reasoning
    }
    private struct Saved: Codable {
        var version: Int
        var files: [String: FileState]
        var next: Int
        var claude: [String: Int]         // message id → the file that counted it
        var codex: [String: Session]
    }
    // Version 2 (and 1): daily sums per file, read again as version 3 except for deleted logs.
    private struct OldState: Codable {
        var last: [Int]?
        var origin: String?
        var gone: Bool?
        var days: [String: TokenCounts]
    }
    private struct OldSaved: Codable { var version: Int; var files: [String: OldState] }

    private static let version = 3   // 3: hours, models, sessions, folders; .zst; Claude usage updates; Codex sessions once
    static var cacheFile: URL { URL(fileURLWithPath: AccountStore.supportDir + "/token-usage.json") }
    static var appFile: URL { URL(fileURLWithPath: AccountStore.supportDir + "/token-usage-app.jsonl") }

    // Blocking (the first run reads every log, seconds for gigabytes): call it off the main thread.
    // `toolHome` holds the tools' own folders: accounts without a folder use them, and if none does they are the
    // "outside the app" sources. The app passes ToolHome.path; tests pass a scratch folder.
    public static func read(_ accounts: [Account], toolHome: String) -> TokenReport {
        lock.lock(); defer { lock.unlock() }
        let gemini = toolHome + "/.gemini/antigravity-cli/brain"
        var roots: [(String?, Account.Provider, String)] = []
        for a in accounts where a.provider == .claude || a.provider == .codex {
            roots.append((a.id, a.provider, a.dir ?? toolHome + (a.provider == .claude ? "/.claude" : "/.codex")))
        }
        for (p, folder) in [(Account.Provider.claude, toolHome + "/.claude"), (.codex, toolHome + "/.codex"), (.gemini, gemini)]
        where !roots.contains(where: { $0.2 == folder }) {
            roots.append((nil, p, folder))
        }
        var saved = load()
        var old = saved.files
        saved.files = [:]
        var entries: [TokenEntry] = []
        var folders: [TokenFolder] = []
        for (id, provider, folder) in roots {
            var status = TokenFolder(provider: provider, accountID: id, folder: folder, exists: FileManager.default.fileExists(atPath: folder))
            var states: [FileState] = []
            let subs = provider == .claude ? ["/projects"] : provider == .codex ? ["/sessions", "/archived_sessions"] : [""]
            for file in subs.flatMap({ logs(in: folder + $0, zst: provider == .codex) }).sorted()
            where provider != .gemini || file.hasSuffix("/transcript.jsonl") {
                let state = update(file, old.removeValue(forKey: file), provider, &saved)
                saved.files[file] = state
                states.append(state)
                status.files += 1
                if file.hasSuffix(".zst") { status.compressed += 1 }
                if state.failed == true { status.failed += 1 }
            }
            for (file, state) in old where file.hasPrefix(folder + "/") {
                var state = state
                state.gone = true
                old[file] = nil
                saved.files[file] = state
                states.append(state)
                status.deleted += 1
                if state.legacy != nil { status.legacy += 1 }
            }
            for state in states {
                let origin = state.origin.map { origin(provider, $0) } ?? (id == nil ? .other : nil)
                for (key, c) in state.buckets where !c.isEmpty {
                    let parts = key.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
                    guard let hour = Int(parts[0]) else { continue }
                    let model = parts.count > 1 && !parts[1].isEmpty ? String(parts[1]) : nil
                    entries.append(TokenEntry(provider: provider, accountID: id, folder: folder, origin: origin, source: .log,
                                              start: Date(timeIntervalSince1970: Double(hour) * 3600), hourly: true, model: model,
                                              session: state.session, project: state.project, kind: nil, counts: c))
                }
                for (day, c) in state.legacy ?? [:] where !c.isEmpty {
                    guard let start = dayFormat.date(from: day) else { continue }
                    entries.append(TokenEntry(provider: provider, accountID: id, folder: folder, origin: origin, source: .legacy,
                                              start: start, hourly: false, model: nil, session: nil, project: nil, kind: nil, counts: c))
                }
            }
            let seen = entries.filter { $0.folder == folder }.map(\.start)
            status.first = seen.min(); status.last = seen.max()
            folders.append(status)
        }
        // A folder no longer read (an account removed) keeps nothing: its sums were that account's.
        entries += appEntries(accounts)
        save(saved)
        return TokenReport(entries: entries, folders: folders, readAt: Date())
    }

    private static func load() -> Saved {
        let empty = Saved(version: version, files: [:], next: 1, claude: [:], codex: [:])
        guard let data = try? Data(contentsOf: cacheFile) else { return empty }
        if let saved = try? JSONDecoder().decode(Saved.self, from: data), saved.version == version { return saved }
        // An older format: its deleted logs' daily sums are all that is left of them, so they stay as they are. A Codex
        // session among them counts as already counted up to its last total, so its archived (.zst) copy adds only
        // what came after.
        guard let older = try? JSONDecoder().decode(OldSaved.self, from: data) else { return empty }
        var saved = empty
        for (path, o) in older.files where o.gone == true {
            let state = FileState(n: saved.next, size: 0, offset: 0, origin: o.origin, session: codexSession(path), gone: true,
                                  legacy: o.days)
            if let session = state.session, let last = o.last, last.count >= 4 {
                saved.codex[session] = Session(owner: saved.next, high: Array(last.prefix(4)) + [0])
            }
            saved.files[path] = state
            saved.next += 1
        }
        return saved
    }

    private static func save(_ saved: Saved) {
        guard let data = try? JSONEncoder().encode(saved) else { return }
        try? FileManager.default.createDirectory(atPath: AccountStore.supportDir, withIntermediateDirectories: true)
        try? data.write(to: cacheFile, options: .atomic)
    }

    private static func logs(in dir: String, zst: Bool) -> [String] {
        guard let walk = FileManager.default.enumerator(atPath: dir) else { return [] }
        var found: [String] = []
        while let rel = walk.nextObject() as? String {
            if rel.hasSuffix(".jsonl") || (zst && rel.hasSuffix(".jsonl.zst")) { found.append(dir + "/" + rel) }
        }
        return found
    }

    private static func origin(_ provider: Account.Provider, _ name: String) -> TokenEntry.Origin {
        if name.lowercased().contains("desktop") { return .desktop }
        return ["cli", "codex_cli_rs", "codex-tui", "codex_tui"].contains(name) ? .terminal : .other
    }

    // Codex names a session's file after it: rollout-<time>-<uuid>.jsonl(.zst).
    static func codexSession(_ path: String) -> String? {
        var name = (path as NSString).lastPathComponent
        for end in [".zst", ".jsonl"] where name.hasSuffix(end) { name = String(name.dropLast(end.count)) }
        guard name.hasPrefix("rollout-"), name.count > 36 else { return nil }
        let id = String(name.suffix(36))
        return UUID(uuidString: id) != nil ? id.lowercased() : nil
    }

    // Reads what was added since last time; a file that got shorter (rewritten) is read again from the start, and what
    // it counted before (its buckets, the messages and session it owned) is counted again from it.
    private static func update(_ path: String, _ previous: FileState?, _ provider: Account.Provider, _ saved: inout Saved) -> FileState {
        let size = ((try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? NSNumber)?.int64Value ?? 0
        var state: FileState
        if let previous { state = previous } else { state = FileState(n: saved.next, size: 0, offset: 0); saved.next += 1 }
        func restart() {
            let n = state.n
            saved.claude = saved.claude.filter { $0.value != n }
            saved.codex = saved.codex.filter { $0.value.owner != n }
            state = FileState(n: n, size: 0, offset: 0)
        }
        if state.legacy != nil && state.buckets.isEmpty { restart() }   // a deleted log of the old format came back: read it whole
        if provider == .codex && state.session == nil { state.session = codexSession(path) }
        state.gone = nil
        let packed = path.hasSuffix(".zst")
        if packed ? size != state.size && state.size != 0 : size < state.offset { restart(); if provider == .codex { state.session = codexSession(path) } }
        if packed && size == state.size { return state }
        guard packed || size > state.offset else { state.size = size; return state }
        var data: Data
        if packed {
            guard let raw = try? Data(contentsOf: URL(fileURLWithPath: path)), let unpacked = try? Zstd.decode(raw) else {
                state.size = size; state.failed = true; return state
            }
            data = unpacked
            if data.count < state.offset { restart(); if provider == .codex { state.session = codexSession(path) } }
            data = data.subdata(in: Int(state.offset) ..< data.count)
            if data.last != 0x0A { data.append(0x0A) }   // a finished file: its last line is whole
        } else {
            guard let handle = FileHandle(forReadingAtPath: path) else { state.failed = true; return state }
            defer { try? handle.close() }
            guard (try? handle.seek(toOffset: UInt64(state.offset))) != nil, let read = try? handle.readToEnd() else { state.failed = true; return state }
            data = read
        }
        state.size = size
        state.failed = nil
        // Up to the last newline: a line still being written is read next time.
        guard let end = data.lastIndex(of: 0x0A) else { return state }
        let used = end - data.startIndex + 1
        for range in lines(data, length: used, provider) {
            guard let json = try? JSONSerialization.jsonObject(with: data.subdata(in: range)) as? [String: Any] else { continue }
            let stamp = (json["timestamp"] ?? json["created_at"]) as? String
            let hour = stamp.flatMap(date).map { Int(floor($0.timeIntervalSince1970 / 3600)) }
            switch provider {
            case .claude: addClaude(json, hour: hour, to: &state, &saved)
            case .codex: addCodex(json, hour: hour, to: &state, &saved)
            default: addGemini(json, hour: hour, path: path, to: &state)
            }
        }
        state.offset += Int64(used)
        return state
    }

    // The lines that can hold a count, found with memchr/memmem: Data's own slicing and search made
    // the first read of a few gigabytes several times slower.
    // A line is kept when it has every needle of one of the sets.
    private static func lines(_ data: Data, length: Int, _ provider: Account.Provider) -> [Range<Int>] {
        let sets: [[String]] = provider == .claude ? [["\"usage\"", "\"assistant\""]]
            : provider == .codex ? [["\"token_count\""], ["\"session_meta\""], ["\"turn_context\""]]
            : [["\"PLANNER_RESPONSE\"", "\"output_tokens\""]]
        return data.withUnsafeBytes { raw -> [Range<Int>] in
            guard let base = raw.baseAddress else { return [] }
            var found: [Range<Int>] = []
            var start = 0
            while start < length {
                let stop = memchr(base + start, 0x0A, length - start).map { $0 - UnsafeMutableRawPointer(mutating: base) } ?? length
                if sets.contains(where: { $0.allSatisfy { n in n.withCString { memmem(base + start, stop - start, $0, strlen($0)) != nil } } }) {
                    found.append(data.startIndex + start ..< data.startIndex + stop)
                }
                start = stop + 1
            }
            return found
        }
    }

    private static func key(_ hour: Int, _ model: String?) -> String { "\(hour)|" + (model ?? "").replacingOccurrences(of: "|", with: "/") }

    private static func addClaude(_ json: [String: Any], hour: Int?, to state: inout FileState, _ saved: inout Saved) {
        guard json["type"] as? String == "assistant", let message = json["message"] as? [String: Any],
              let u = message["usage"] as? [String: Any], let hour else { return }
        if state.origin == nil { state.origin = json["entrypoint"] as? String }
        if state.session == nil { state.session = json["sessionId"] as? String }
        if state.project == nil { state.project = json["cwd"] as? String }
        let now = [int(u["input_tokens"]), int(u["cache_creation_input_tokens"]), int(u["cache_read_input_tokens"]), int(u["output_tokens"])]
        let model = message["model"] as? String
        var counted = [hour, 0, 0, 0, 0]
        if let id = (message["id"] as? String) ?? (json["requestId"] as? String) {
            var recent = state.recent ?? [:]
            if let before = recent[id] { counted = before }
            else if saved.claude[id] != nil { return }   // counted in another file (or long ago in this one)
            let rise = (0..<4).map { max(now[$0] - counted[$0 + 1], 0) }
            recent[id] = [counted[0]] + (0..<4).map { max(now[$0], counted[$0 + 1]) }
            if recent.count > 64, let oldest = recent.min(by: { $0.value[0] < $1.value[0] })?.key, oldest != id { recent[oldest] = nil }
            state.recent = recent
            saved.claude[id] = state.n
            guard rise.contains(where: { $0 > 0 }) else { return }
            state.buckets[key(counted[0], model), default: TokenCounts()] += TokenCounts(input: rise[0], cacheWrite: rise[1], cacheRead: rise[2], output: rise[3])
            return
        }
        state.buckets[key(hour, model), default: TokenCounts()] += TokenCounts(input: now[0], cacheWrite: now[1], cacheRead: now[2], output: now[3])
    }

    private static func addCodex(_ json: [String: Any], hour: Int?, to state: inout FileState, _ saved: inout Saved) {
        let payload = json["payload"] as? [String: Any]
        switch json["type"] as? String {
        case "session_meta":
            if state.origin == nil { state.origin = payload?["originator"] as? String }
            if state.project == nil { state.project = payload?["cwd"] as? String }
            if state.session == nil { state.session = (payload?["id"] as? String)?.lowercased() }
            return
        case "turn_context":
            if let model = payload?["model"] as? String { state.model = model }
            return
        default: break
        }
        guard let payload, payload["type"] as? String == "token_count", let hour,
              let total = (payload["info"] as? [String: Any])?["total_token_usage"] as? [String: Any] else { return }
        let now = [int(total["input_tokens"]), int(total["cached_input_tokens"]), int(total["cache_write_input_tokens"]),
                   int(total["output_tokens"]), int(total["reasoning_output_tokens"])]
        let id = state.session ?? "file:\(state.n)"
        var session = saved.codex[id] ?? Session(owner: state.n, high: [0, 0, 0, 0, 0])
        let rise = (0..<5).map { max(now[$0] - session.high[$0], 0) }
        session.high = (0..<5).map { max(now[$0], session.high[$0]) }
        saved.codex[id] = session
        guard rise.contains(where: { $0 > 0 }) else { return }
        // Cached and cache-written input are parts of input_tokens.
        state.buckets[key(hour, state.model), default: TokenCounts()] += TokenCounts(
            input: max(rise[0] - rise[1] - rise[2], 0), cacheWrite: rise[2], cacheRead: rise[1], output: rise[3],
            reasoning: total["reasoning_output_tokens"] != nil ? min(rise[4], rise[3]) : nil)   // never more than the output it is part of
    }

    private static func addGemini(_ json: [String: Any], hour: Int?, path: String, to state: inout FileState) {
        guard json["type"] as? String == "PLANNER_RESPONSE", json["output_tokens"] != nil, let hour else { return }
        if state.session == nil {   // brain/<conversation>/.system_generated/logs/transcript.jsonl
            let parts = path.split(separator: "/")
            if parts.count >= 4 { state.session = String(parts[parts.count - 4]) }
        }
        if let step = (json["step_index"] as? NSNumber)?.intValue {
            var steps = state.steps ?? []
            if steps.contains(step) { return }
            steps.append(step)
            state.steps = Array(steps.suffix(32))
        }
        state.buckets[key(hour, json["model"] as? String), default: TokenCounts()] += TokenCounts(
            input: int(json["input_tokens"]), cacheRead: int(json["cache_read_tokens"]), output: int(json["output_tokens"]))
    }

    // MARK: Calls that leave no log

    private struct AppRecord: Codable {
        var id: String          // the CLI's session id for the call (or a new UUID): written twice, counted once
        var at: Date
        var provider: String
        var account: String
        var model: String?
        var kind: String?
        var folder: String?
        var counts: TokenCounts
    }

    // Records one call's usage as the CLI returned it. Claude's `result` event and Codex's `turn.completed` events
    // in `output` (JSON lines) are read; anything else records nothing.
    public static func recordApp(_ account: Account, output: String, model: String?, kind: String?, folder: String?, at: Date = Date()) {
        var counts = TokenCounts(), found = false, id: String?, ranOn = model
        for line in output.split(separator: "\n") where line.contains("\"usage\"") || line.contains("thread.started") {
            guard let json = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
            switch (account.provider, json["type"] as? String) {
            case (.claude, "result"?):
                guard let u = json["usage"] as? [String: Any] else { continue }
                id = json["session_id"] as? String ?? id
                if let models = json["modelUsage"] as? [String: Any], models.count == 1 { ranOn = models.keys.first }
                counts = TokenCounts(input: int(u["input_tokens"]), cacheWrite: int(u["cache_creation_input_tokens"]),
                                     cacheRead: int(u["cache_read_input_tokens"]), output: int(u["output_tokens"]))
                found = true
            case (.codex, "thread.started"?):
                id = json["thread_id"] as? String ?? id
            case (.codex, "turn.completed"?):
                guard let u = json["usage"] as? [String: Any] else { continue }
                let cached = int(u["cached_input_tokens"])
                counts += TokenCounts(input: max(int(u["input_tokens"]) - cached, 0), cacheRead: cached, output: int(u["output_tokens"]),
                                      reasoning: u["reasoning_output_tokens"] != nil ? int(u["reasoning_output_tokens"]) : nil)
                found = true
            default: continue
            }
        }
        guard found, !counts.isEmpty else { return }
        let record = AppRecord(id: id ?? UUID().uuidString, at: at, provider: account.provider.rawValue, account: account.id,
                               model: ranOn, kind: kind, folder: folder, counts: counts)
        guard var data = try? appCoder.encode(record) else { return }
        data.append(0x0A)
        lock.lock(); defer { lock.unlock() }
        try? FileManager.default.createDirectory(atPath: AccountStore.supportDir, withIntermediateDirectories: true)
        if let handle = FileHandle(forWritingAtPath: appFile.path) {
            handle.seekToEndOfFile(); handle.write(data); try? handle.close()
        } else {
            FileManager.default.createFile(atPath: appFile.path, contents: data, attributes: [.posixPermissions: 0o600])
        }
    }

    private static func appEntries(_ accounts: [Account]) -> [TokenEntry] {
        guard let text = try? String(contentsOf: appFile, encoding: .utf8) else { return [] }
        var seen: Set<String> = []
        var entries: [TokenEntry] = []
        for line in text.split(separator: "\n") {
            guard let r = try? appDecoder.decode(AppRecord.self, from: Data(line.utf8)), seen.insert(r.id).inserted,
                  let provider = Account.Provider(rawValue: r.provider) else { continue }
            let account = accounts.first { $0.id == r.account }
            entries.append(TokenEntry(provider: provider, accountID: account?.id, folder: appFile.path, origin: nil, source: .app,
                                      start: Date(timeIntervalSince1970: floor(r.at.timeIntervalSince1970 / 3600) * 3600), hourly: true,
                                      model: r.model, session: nil, project: r.folder, kind: r.kind, counts: r.counts))
        }
        return entries
    }

    private static let appCoder: JSONEncoder = { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = .sortedKeys; return e }()
    private static let appDecoder: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }()

    // Every Mac's sums together. A session found on more than one Mac (its log copied over) counts once: the Mac
    // with the most of it keeps it (this Mac first on a tie, then by id). Calls and sums without a session id are
    // never taken for the same as another's, whatever their time or numbers.
    public static func together(_ local: [TokenEntry], _ peers: [TokenDevice]) -> [TokenEntry] {
        var all = local.map { e -> TokenEntry in var e = e; e.device = ""; return e }
        for peer in peers { all += peer.entries.map { e in var e = e; e.device = peer.id; return e } }
        var sizes: [String: [String: Int]] = [:]   // provider|session → device → tokens
        for e in all where e.session != nil && e.source == .log { sizes[e.provider.rawValue + "|" + e.session!, default: [:]][e.device, default: 0] += e.counts.total }
        var keeper: [String: String] = [:]
        for (key, byDevice) in sizes where byDevice.count > 1 {
            keeper[key] = byDevice.max { a, b in a.value != b.value ? a.value < b.value : (a.key.isEmpty ? false : b.key.isEmpty ? true : a.key > b.key) }!.key
        }
        guard !keeper.isEmpty else { return all }
        return all.filter { e in
            guard let s = e.session, e.source == .log, let k = keeper[e.provider.rawValue + "|" + s] else { return true }
            return k == e.device
        }
    }

    // MARK: Projects

    // The project a working folder belongs to: a Git worktree goes with its main repository (its .git file names it),
    // a folder inside a repository with the repository. A folder that is gone stays as it was logged.
    public static func projectRoot(_ cwd: String) -> String {
        let fm = FileManager.default
        var dir = cwd
        while dir.count > 1 {
            let git = dir + "/.git"
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: git, isDirectory: &isDir) {
                if isDir.boolValue { return dir }
                // "gitdir: <repo>/.git/worktrees/<name>"
                if let text = try? String(contentsOfFile: git, encoding: .utf8), let line = text.split(separator: "\n").first,
                   line.hasPrefix("gitdir:") {
                    let target = line.dropFirst(7).trimmingCharacters(in: .whitespaces)
                    if let r = target.range(of: "/.git/worktrees/") { return String(target[..<r.lowerBound]) }
                }
                return dir
            }
            dir = (dir as NSString).deletingLastPathComponent
        }
        return cwd
    }

    private static func int(_ value: Any?) -> Int { (value as? NSNumber)?.intValue ?? 0 }

    private static let isoFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()
    private static let iso = ISO8601DateFormatter()
    private static func date(_ stamp: String) -> Date? { isoFraction.date(from: stamp) ?? iso.date(from: stamp) }
    // Version 2's days: this Mac's local days when they were counted (the time zone is not known).
    private static let dayFormat: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"
        return f
    }()
}
