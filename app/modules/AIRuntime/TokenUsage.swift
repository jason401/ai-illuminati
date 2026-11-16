import Foundation
import AIAccounts

// Tokens actually sent and received, summed from the session logs the CLIs write themselves (read only):
//   Claude Code: <config>/projects/**/*.jsonl, one `message.usage` per answer. A message split over several lines
//                repeats the same usage, so each `message.id` counts once per file (across files: same numbers, measured).
//   Codex:       <CODEX_HOME>/sessions|archived_sessions/**/*.jsonl, `token_count` events whose `total_token_usage`
//                is the session's running total: each event adds its rise to the day it happened, so a session that
//                crosses midnight is split between the days. Codex's `input_tokens` includes the cached part.
// Gemini (agy) writes no token counts. Web and desktop app use is not in these logs.
// Every file is read once: what was read is kept in token-usage.json (support folder) and only new lines are read later.
public struct TokenCounts: Codable, Equatable {
    public var input = 0        // not from the cache
    public var cacheWrite = 0
    public var cacheRead = 0
    public var output = 0       // includes thinking (Claude) and reasoning (Codex)

    public init(input: Int = 0, cacheWrite: Int = 0, cacheRead: Int = 0, output: Int = 0) {
        self.input = input; self.cacheWrite = cacheWrite; self.cacheRead = cacheRead; self.output = output
    }
    // New tokens: everything except reading the cache back (which is most of an agent loop's total).
    public var fresh: Int { input + cacheWrite + output }
    public var total: Int { fresh + cacheRead }
    public var isEmpty: Bool { total == 0 }

    public static func + (a: TokenCounts, b: TokenCounts) -> TokenCounts {
        TokenCounts(input: a.input + b.input, cacheWrite: a.cacheWrite + b.cacheWrite,
                    cacheRead: a.cacheRead + b.cacheRead, output: a.output + b.output)
    }
    public static func += (a: inout TokenCounts, b: TokenCounts) { a = a + b }
}

// One log folder's counts by local day (the day's start).
public struct TokenSource {
    public let accountID: String?    // nil: the tool's own folder (~/.claude, ~/.codex) that no account uses, i.e. outside the app
    public let provider: Account.Provider
    public let folder: String
    public let days: [Date: TokenCounts]
}

public enum TokenLedger {
    private static let lock = NSLock()

    private struct FileState: Codable {
        var size: Int64
        var offset: Int64                 // read up to here (the end of the last whole line)
        var recent: [String]? = nil       // Claude: the last message ids, so a split message counts once
        var last: [Int]? = nil            // Codex: the running total last seen (input, cached, cache write, output)
        var days: [String: TokenCounts] = [:]
    }
    private struct Saved: Codable {
        var version: Int
        var files: [String: FileState]
    }
    private static let version = 1
    static var cacheFile: URL { URL(fileURLWithPath: AccountStore.supportDir + "/token-usage.json") }

    // Blocking (the first run reads every log, seconds for gigabytes): call it off the main thread.
    // `toolHome` holds the tools' own folders: accounts without a folder use them, and if none does they are the
    // "outside the app" sources. The app passes ToolHome.path; tests pass a scratch folder.
    public static func read(_ accounts: [Account], toolHome: String) -> [TokenSource] {
        lock.lock(); defer { lock.unlock() }
        var roots: [(String?, Account.Provider, String)] = []
        for a in accounts where a.provider == .claude || a.provider == .codex {
            roots.append((a.id, a.provider, a.dir ?? toolHome + (a.provider == .claude ? "/.claude" : "/.codex")))
        }
        for (p, sub) in [(Account.Provider.claude, "/.claude"), (.codex, "/.codex")]
        where !roots.contains(where: { $0.2 == toolHome + sub }) {
            roots.append((nil, p, toolHome + sub))
        }
        var saved = (try? Data(contentsOf: cacheFile)).flatMap { try? JSONDecoder().decode(Saved.self, from: $0) }
        if saved?.version != version { saved = nil }
        var old = saved?.files ?? [:]
        var kept: [String: FileState] = [:]
        var sources: [TokenSource] = []
        for (id, provider, folder) in roots {
            var days: [String: TokenCounts] = [:]
            let subs = provider == .claude ? ["/projects"] : ["/sessions", "/archived_sessions"]
            for file in subs.flatMap({ logs(in: folder + $0) }) {
                let state = update(file, old.removeValue(forKey: file), claude: provider == .claude)
                kept[file] = state
                for (d, c) in state.days { days[d, default: TokenCounts()] += c }
            }
            if id != nil || !days.isEmpty {
                sources.append(TokenSource(accountID: id, provider: provider, folder: folder,
                                           days: Dictionary(uniqueKeysWithValues: days.compactMap { k, v in dayStart(k).map { ($0, v) } })))
            }
        }
        if let data = try? JSONEncoder().encode(Saved(version: version, files: kept)) {
            try? FileManager.default.createDirectory(atPath: AccountStore.supportDir, withIntermediateDirectories: true)
            try? data.write(to: cacheFile, options: .atomic)
        }
        return sources
    }

    private static func logs(in dir: String) -> [String] {
        guard let walk = FileManager.default.enumerator(atPath: dir) else { return [] }
        var found: [String] = []
        while let rel = walk.nextObject() as? String { if rel.hasSuffix(".jsonl") { found.append(dir + "/" + rel) } }
        return found
    }

    // Reads what was added since last time; a file that got shorter (rewritten) is read again from the start.
    private static func update(_ path: String, _ previous: FileState?, claude: Bool) -> FileState {
        let size = ((try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? NSNumber)?.int64Value ?? 0
        var state = previous ?? FileState(size: 0, offset: 0)
        if size < state.offset { state = FileState(size: 0, offset: 0) }
        state.size = size
        guard size > state.offset, let handle = FileHandle(forReadingAtPath: path) else { return state }
        defer { try? handle.close() }
        guard (try? handle.seek(toOffset: UInt64(state.offset))) != nil, let data = try? handle.readToEnd(),
              let end = data.lastIndex(of: 0x0A) else { return state }
        let used = end - data.startIndex + 1
        for range in lines(data, length: used, claude: claude) {
            guard let json = try? JSONSerialization.jsonObject(with: data.subdata(in: range)) as? [String: Any],
                  let stamp = json["timestamp"] as? String, let day = dayKey(stamp) else { continue }
            if claude { addClaude(json, day: day, to: &state) } else { addCodex(json, day: day, to: &state) }
        }
        state.offset += Int64(used)
        return state
    }

    // The lines that can hold a count, found with memchr/memmem: Data's own slicing and search made
    // the first read of a few gigabytes several times slower.
    private static func lines(_ data: Data, length: Int, claude: Bool) -> [Range<Int>] {
        let needles = claude ? ["\"usage\"", "\"assistant\""] : ["\"token_count\""]
        return data.withUnsafeBytes { raw -> [Range<Int>] in
            guard let base = raw.baseAddress else { return [] }
            var found: [Range<Int>] = []
            var start = 0
            while start < length {
                let stop = memchr(base + start, 0x0A, length - start).map { $0 - UnsafeMutableRawPointer(mutating: base) } ?? length
                if needles.allSatisfy({ n in n.withCString { memmem(base + start, stop - start, $0, strlen($0)) != nil } }) {
                    found.append(data.startIndex + start ..< data.startIndex + stop)
                }
                start = stop + 1
            }
            return found
        }
    }

    private static func addClaude(_ json: [String: Any], day: String, to state: inout FileState) {
        guard json["type"] as? String == "assistant", let message = json["message"] as? [String: Any],
              let u = message["usage"] as? [String: Any] else { return }
        if let id = message["id"] as? String {
            var recent = state.recent ?? []
            if recent.contains(id) { return }
            recent.append(id)
            state.recent = Array(recent.suffix(32))
        }
        state.days[day, default: TokenCounts()] += TokenCounts(
            input: int(u["input_tokens"]), cacheWrite: int(u["cache_creation_input_tokens"]),
            cacheRead: int(u["cache_read_input_tokens"]), output: int(u["output_tokens"]))
    }

    private static func addCodex(_ json: [String: Any], day: String, to state: inout FileState) {
        guard let payload = json["payload"] as? [String: Any], payload["type"] as? String == "token_count",
              let total = (payload["info"] as? [String: Any])?["total_token_usage"] as? [String: Any] else { return }
        let now = [int(total["input_tokens"]), int(total["cached_input_tokens"]),
                   int(total["cache_write_input_tokens"]), int(total["output_tokens"])]
        let before = state.last ?? [0, 0, 0, 0]
        // A total that went down is a new count (never seen; resumed sessions keep counting up): take it whole.
        let rise = zip(now, before).contains { $0 < $1 } ? now : zip(now, before).map { $0 - $1 }
        state.last = now
        // Cached and cache-written input are parts of input_tokens.
        state.days[day, default: TokenCounts()] += TokenCounts(
            input: max(rise[0] - rise[1] - rise[2], 0), cacheWrite: rise[2], cacheRead: rise[1], output: rise[3])
    }

    private static func int(_ value: Any?) -> Int { (value as? NSNumber)?.intValue ?? 0 }

    private static let isoFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()
    private static let iso = ISO8601DateFormatter()
    private static let dayFormat: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"
        return f
    }()
    // Days are this Mac's local days, as when the log was read.
    private static func dayKey(_ stamp: String) -> String? {
        (isoFraction.date(from: stamp) ?? iso.date(from: stamp)).map { dayFormat.string(from: $0) }
    }
    private static func dayStart(_ key: String) -> Date? { dayFormat.date(from: key) }
}
