import Foundation
import CryptoKit

// One logged-in subscription. Each account has its own folder, so several Claude or ChatGPT
// accounts can be logged in at the same time:
//   Claude: CLAUDE_CONFIG_DIR=<dir>  (login kept in Keychain "Claude Code-credentials-<hash>")
//   Codex:  CODEX_HOME=<dir>         (login kept in <dir>/auth.json)
//   Gemini: agy's own folder only (~/.gemini), so there is at most one Gemini entry.
// dir == nil means the tool's normal folder (~/.claude for Claude, ~/.codex for Codex).
// The order of the list is the order shown in the menu (changed in Settings).
struct Account: Codable, Equatable {
    enum Provider: String, Codable, CaseIterable {
        case claude, codex, gemini
        var title: String {
            switch self {
            case .claude: return "Claude"
            case .codex: return "ChatGPT"
            case .gemini: return "Gemini"
            }
        }
    }
    var id: String
    var provider: Provider
    var name: String
    var dir: String?

    var codexHome: String {
        dir ?? FileManager.default.homeDirectoryForCurrentUser.path + "/.codex"
    }

    // Same rule as Claude Code itself: no CLAUDE_CONFIG_DIR -> "Claude Code-credentials",
    // otherwise a suffix of the first 8 hex digits of sha256(folder path).
    var claudeKeychainService: String {
        guard let dir else { return "Claude Code-credentials" }
        let digest = SHA256.hash(data: Data(dir.precomposedStringWithCanonicalMapping.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "Claude Code-credentials-" + hex.prefix(8)
    }

    // Environment for running this account's tool: API keys removed (so the subscription is used,
    // never API billing) and the account folder set.
    var environment: [String: String] {
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

// The account list, saved in ~/Library/Application Support/AI Illuminati/accounts.json.
// Account folders live in ~/.ai-illuminati/accounts/<id>.
enum AccountStore {
    static let home = FileManager.default.homeDirectoryForCurrentUser.path
    static let supportDir = home + "/Library/Application Support/AI Illuminati"
    static let accountsDir = home + "/.ai-illuminati/accounts"
    private static var file: URL { URL(fileURLWithPath: supportDir + "/accounts.json") }

    static let gemini = Account(id: "gemini-main", provider: .gemini, name: "Gemini", dir: nil)

    static func load() -> [Account] {
        if let data = try? Data(contentsOf: file),
           var list = try? JSONDecoder().decode([Account].self, from: data) {
            // Lists saved before Gemini became an entry get it once, at the end.
            if !UserDefaults.standard.bool(forKey: "geminiInList") {
                UserDefaults.standard.set(true, forKey: "geminiInList")
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
        UserDefaults.standard.set(true, forKey: "geminiInList")
        save(list)
        return list
    }

    static func save(_ list: [Account]) {
        try? FileManager.default.createDirectory(atPath: supportDir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(list).write(to: file, options: .atomic)
    }

    // Makes a new, empty account folder. Codex is told to keep its login in a file there
    // (not the shared Keychain entry) so each account stays separate.
    static func newAccount(provider: Account.Provider, name: String) -> Account {
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
