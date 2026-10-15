import Foundation
import CryptoKit

// One logged-in subscription. Each account has its own folder, so several Claude or ChatGPT
// accounts can be logged in at the same time:
//   Claude: CLAUDE_CONFIG_DIR=<dir>  (login kept in Keychain "Claude Code-credentials-<hash>")
//   Codex:  CODEX_HOME=<dir>         (login kept in <dir>/auth.json)
// dir == nil means the tool's normal folder (~/.claude for Claude, ~/.codex for Codex).
struct Account: Codable, Equatable {
    enum Provider: String, Codable { case claude, codex }
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
                    "GOOGLE_API_KEY", "CLAUDE_CONFIG_DIR", "CODEX_HOME"] {
            env.removeValue(forKey: key)
        }
        if let dir {
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

    static func load() -> [Account] {
        if let data = try? Data(contentsOf: file),
           let list = try? JSONDecoder().decode([Account].self, from: data) {
            return list
        }
        // First start: the accounts that are already logged in on this Mac.
        var list: [Account] = []
        if FileManager.default.fileExists(atPath: home + "/.codex/auth.json") {
            list.append(Account(id: "codex-main", provider: .codex, name: "ChatGPT 기본", dir: nil))
        }
        if ClaudeUsage.loginExists(Account(id: "claude-main", provider: .claude, name: "", dir: nil)) {
            list.append(Account(id: "claude-main", provider: .claude, name: "Claude 기본", dir: nil))
        }
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
