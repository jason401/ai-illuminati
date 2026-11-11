import Foundation
import CryptoKit

// One logged-in subscription. Each account has its own folder, so several Claude or ChatGPT
// accounts can be logged in at the same time:
//   Claude: CLAUDE_CONFIG_DIR=<dir>  (login kept in Keychain "Claude Code-credentials-<hash>")
//   Codex:  CODEX_HOME=<dir>         (login kept in <dir>/auth.json)
//   Gemini: agy's own folder only (~/.gemini), so there is at most one Gemini entry.
// dir == nil means the tool's normal folder (~/.claude for Claude, ~/.codex for Codex).
// The order of the list is the order shown in the menu (changed in Settings).
// Module AIAccounts: the app sees only what is `public` here.
public struct Account: Codable, Equatable {
    public enum Provider: String, Codable, CaseIterable {
        case claude, codex, gemini
        case ollama   // a model on this Mac through Ollama (Local.swift)
        public var title: String {
            switch self {
            case .claude: return "Claude"
            case .codex: return "ChatGPT"
            case .gemini: return "Gemini"
            case .ollama: return "Ollama"
            }
        }
    }
    public var id: String
    public var provider: Provider
    public var name: String
    public var dir: String?
    public var school: Bool?   // an Enterprise (school or work) account, set in Settings; nil = guessed from the name
    public var model: String?   // Ollama's name for the model ("qwen3:8b"); nil for the first two Gemma entries (their ids say)

    public init(id: String, provider: Provider, name: String, dir: String? = nil, school: Bool? = nil, model: String? = nil) {
        self.id = id; self.provider = provider; self.name = name; self.dir = dir; self.school = school; self.model = model
    }

    // Enterprise accounts hand work only to other Enterprise accounts (Settings can turn that off).
    public var isSchool: Bool {
        school ?? ["학교", "school", "univ", "edu", "enterprise", "엔터프라이즈", "회사"].contains { name.lowercased().contains($0) }
    }

    public var codexHome: String {
        dir ?? FileManager.default.homeDirectoryForCurrentUser.path + "/.codex"
    }

    // Same rule as Claude Code itself: no CLAUDE_CONFIG_DIR -> "Claude Code-credentials",
    // otherwise a suffix of the first 8 hex digits of sha256(folder path).
    public var claudeKeychainService: String {
        guard let dir else { return "Claude Code-credentials" }
        let digest = SHA256.hash(data: Data(dir.precomposedStringWithCanonicalMapping.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "Claude Code-credentials-" + hex.prefix(8)
    }

    // Environment for running this account's tool: API keys removed (so the subscription is used,
    // never API billing) and the account folder set.
    public var environment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        for key in ["ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "OPENAI_API_KEY", "GEMINI_API_KEY",
                    "GOOGLE_API_KEY", "ANTHROPIC_BASE_URL", "CLAUDECODE", "CLAUDE_CONFIG_DIR", "CODEX_HOME"] {
            env.removeValue(forKey: key)
        }
        if let dir, provider != .gemini {
            env[provider == .claude ? "CLAUDE_CONFIG_DIR" : "CODEX_HOME"] = dir
        }
        return env
    }
}

// The app's settings. Same place rule as AccountStore.home: the real ones only in the app itself.
extension UserDefaults {
    public static var app: UserDefaults { AccountStore.place.defaults }
}

// The account list, saved in ~/Library/Application Support/AI Illuminati/accounts.json.
// Account folders live in ~/.ai-illuminati/accounts/<id>.
public enum AccountStore {
    // Only the app itself (main.swift) chooses the real home folder and settings, before anything reads
    // them. Every other program built from these files (tests, previews) gets a throwaway folder and
    // settings file, or AI_ILLUMINATI_TEST_HOME when a test names one, so a forgotten step can never
    // write over the real accounts.
    private static var realHomeChosen = false
    private static var placeChosen = false
    static let place: (home: String, defaults: UserDefaults) = {
        placeChosen = true
        let real = FileManager.default.homeDirectoryForCurrentUser.path
        if realHomeChosen { return (real, .standard) }
        var home = ProcessInfo.processInfo.environment["AI_ILLUMINATI_TEST_HOME"] ?? ""
        if home.isEmpty || URL(fileURLWithPath: home).standardizedFileURL.path == URL(fileURLWithPath: real).standardizedFileURL.path {
            home = NSTemporaryDirectory() + "ai-illuminati-scratch-" + UUID().uuidString
        }
        try? FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        return (home, UserDefaults(suiteName: home + "/settings")!)
    }()
    public static func useRealHome() {
        precondition(!placeChosen, "AccountStore.useRealHome() must run before anything reads the data folder")
        realHomeChosen = true
    }
    public static var home: String { place.home }
    public static var supportDir: String { home + "/Library/Application Support/AI Illuminati" }
    public static var accountsDir: String { home + "/.ai-illuminati/accounts" }
    private static var file: URL { URL(fileURLWithPath: supportDir + "/accounts.json") }
    public static var backupDir: URL { URL(fileURLWithPath: supportDir + "/backups") }
    public static let keptBackups = 20, keptDays = 7, keptShrinkBackups = 30

    public static let gemini = Account(id: "gemini-main", provider: .gemini, name: "Gemini", dir: nil)

    // One entry that cannot be read (for example a kind of AI from a newer version) is skipped, not the list.
    private struct Entry: Decodable {
        let account: Account?
        init(from decoder: Decoder) throws { account = try? Account(from: decoder) }
    }

    public static func decode(_ data: Data) -> [Account]? {
        (try? JSONDecoder().decode([Entry].self, from: data)).map { $0.compactMap(\.account) }
    }

    public static func load() -> [Account] {
        let saved = try? Data(contentsOf: file)
        if let saved, decode(saved) == nil {
            // Never write over a list that could not be read: keep a copy next to it first.
            try? saved.write(to: file.deletingLastPathComponent().appendingPathComponent("accounts.unreadable-\(Int(Date().timeIntervalSince1970)).json"))
        }
        if let data = saved, var list = decode(data) {
            // Lists saved before Gemini became an entry get it once, at the end.
            if !UserDefaults.app.bool(forKey: "geminiInList") {
                UserDefaults.app.set(true, forKey: "geminiInList")
                if !list.contains(where: { $0.provider == .gemini }) {
                    list.append(gemini)
                    save(list)
                }
            }
            return list
        }
        // First start: only Gemini. Claude and ChatGPT accounts are added in Settings, each with its own
        // app folder, so every account works the same way (sessions included) and the ChatGPT / Claude
        // apps' own logins and histories are never shared or touched.
        var list: [Account] = []
        list.append(gemini)
        UserDefaults.app.set(true, forKey: "geminiInList")
        save(list)
        return list
    }

    // The list on disk is copied to backups/ before it changes; if that copy fails, the list is not
    // replaced. A save that drops accounts gets a "-shrink" copy, kept apart from everyday saves.
    @discardableResult
    public static func save(_ list: [Account]) -> Bool {
        let fm = FileManager.default
        try? fm.createDirectory(atPath: supportDir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(list) else { return false }
        if let old = try? Data(contentsOf: file), old != data {
            let dropped = (decode(old) ?? []).filter { account in !list.contains { $0.id == account.id } }
            guard backUp(old, shrink: !dropped.isEmpty) else {
                NSLog("AI Illuminati: accounts.json not saved, its backup could not be written")
                return false
            }
        }
        do { try data.write(to: file, options: .atomic) } catch { return false }
        return true
    }

    private static func backUp(_ data: Data, shrink: Bool) -> Bool {
        let fm = FileManager.default
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.dateFormat = "yyyyMMdd-HHmmss"
        let now = Date()
        // Microseconds keep quick saves apart and in order.
        var micro = Int(now.timeIntervalSince1970 * 1_000_000) % 1_000_000, stamp = ""
        repeat {
            stamp = format.string(from: now) + String(format: "-%06d", micro)
            micro += 1
        } while ["", "-shrink"].contains { fm.fileExists(atPath: backupDir.appendingPathComponent("accounts-\(stamp)\($0).json").path) }
        let name = "accounts-" + stamp + (shrink ? "-shrink" : "") + ".json"
        do {
            try fm.createDirectory(at: backupDir, withIntermediateDirectories: true)
            try data.write(to: backupDir.appendingPathComponent(name), options: .atomic)
        } catch { return false }
        pruneBackups()
        return true
    }

    // Keeps the newest everyday copies, plus the newest copy of each of the last days, and the newest
    // shrink copies. Names sort by time, so the newest come last.
    public static func pruneBackups() {
        let fm = FileManager.default
        let names = ((try? fm.contentsOfDirectory(atPath: backupDir.path)) ?? [])
            .filter { $0.hasPrefix("accounts-") && $0.hasSuffix(".json") }.sorted()
        let shrink = names.filter { $0.hasSuffix("-shrink.json") }
        let everyday = names.filter { !$0.hasSuffix("-shrink.json") }
        var keep = Set(shrink.suffix(keptShrinkBackups)).union(everyday.suffix(keptBackups))
        var days: [String: String] = [:]
        for name in everyday { days[String(name.dropFirst("accounts-".count).prefix(8))] = name }
        keep.formUnion(days.keys.sorted().suffix(keptDays).compactMap { days[$0] })
        for name in names where !keep.contains(name) {
            try? fm.removeItem(at: backupDir.appendingPathComponent(name))
        }
    }

    // Makes a new, empty account folder. Codex is told to keep its login in a file there
    // (not the shared Keychain entry) so each account stays separate.
    public static func newAccount(provider: Account.Provider, name: String) -> Account {
        if provider == .gemini { return Account(id: gemini.id, provider: .gemini, name: name, dir: nil) }
        let id = "\(provider.rawValue)-\(Int(Date().timeIntervalSince1970))"
        let dir = accountsDir + "/" + id
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        if provider == .codex {
            try? "cli_auth_credentials_store = \"file\"\n"
                .write(toFile: dir + "/config.toml", atomically: true, encoding: .utf8)
        }
        return Account(id: id, provider: provider, name: name, dir: dir)
    }
}
