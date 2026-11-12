import Foundation
import AIAccounts

// The promises of the AIAccounts module, checked from outside it with only its public API.
// Run with AI_ILLUMINATI_TEST_HOME set to an empty folder (run_mode2.sh).
func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fatalError("FAIL: " + message) }
}
let fm = FileManager.default
let file = AccountStore.supportDir + "/accounts.json"
func written() -> String { (try? String(contentsOfFile: file, encoding: .utf8)) ?? "" }
func files(_ dir: String) -> [String] { ((try? fm.contentsOfDirectory(atPath: dir)) ?? []).sorted() }

// Test home: the named folder, never the real one, and settings apart from the app's.
let home = ProcessInfo.processInfo.environment["AI_ILLUMINATI_TEST_HOME"] ?? ""
expect(!home.isEmpty && AccountStore.home == home, "the module must use the folder the test names")
expect(AccountStore.supportDir == home + "/Library/Application Support/AI Illuminati"
       && AccountStore.accountsDir == home + "/.ai-illuminati/accounts", "data folders sit under the chosen home")
expect(UserDefaults.app !== UserDefaults.standard, "a test must not use the app's real settings")

// First start: only Gemini, saved at once.
expect(AccountStore.load() == [AccountStore.gemini] && written().contains("\"gemini-main\""), "first start saves a list with Gemini only")

// Save format: pretty, sorted keys, empty fields left out. Older and newer app versions read this file.
let golden = """
[
  {
    "dir" : "\\/x\\/claude-1",
    "id" : "claude-1",
    "name" : "학교",
    "provider" : "claude",
    "school" : true
  },
  {
    "id" : "ollama-local",
    "model" : "qwen3:8b",
    "name" : "Gemma",
    "provider" : "ollama"
  },
  {
    "id" : "gemini-main",
    "name" : "Gemini",
    "provider" : "gemini"
  }
]
"""
let three = [Account(id: "claude-1", provider: .claude, name: "학교", dir: "/x/claude-1", school: true),
             Account(id: "ollama-local", provider: .ollama, name: "Gemma", dir: nil, model: "qwen3:8b"), AccountStore.gemini]
expect(AccountStore.save(three) && written() == golden, "accounts.json format changed")
expect(AccountStore.load() == three, "a saved list loads back unchanged")

// Reading: lists from older versions (no school/model) load; an unknown kind of AI is skipped, not the list.
let old = #"[{"id":"codex-1","provider":"codex","name":"ChatGPT 1","dir":"/x/codex-1"},{"id":"n","provider":"newer-ai","name":"N"},{"id":"claude-2","provider":"claude","name":"C"}]"#
expect(AccountStore.decode(Data(old.utf8))?.map(\.id) == ["codex-1", "claude-2"], "old lists load, unknown entries are skipped")
expect(AccountStore.decode(Data("not json".utf8)) == nil, "an unreadable list is reported as unreadable")

// A list saved before Gemini was an entry gets it once, at the end; removing it later sticks.
UserDefaults.app.removeObject(forKey: "geminiInList")
try! Data(old.utf8).write(to: URL(fileURLWithPath: file))
expect(AccountStore.load().map(\.id) == ["codex-1", "claude-2", "gemini-main"], "Gemini is added to an older list")
expect(AccountStore.save(Array(AccountStore.load().prefix(2))) && AccountStore.load().map(\.id) == ["codex-1", "claude-2"],
       "Gemini is added only once")

// An unreadable list is copied aside before anything writes over it.
let broken = Data("{ broken".utf8)
try! broken.write(to: URL(fileURLWithPath: file))
_ = AccountStore.load()
let copies = files(AccountStore.supportDir).filter { $0.hasPrefix("accounts.unreadable-") }
expect(copies.count == 1 && fm.contents(atPath: AccountStore.supportDir + "/" + copies[0]) == broken, "an unreadable list must be kept")

// Saving: a changed list is backed up first; a list that drops accounts gets a "-shrink" copy;
// when the backup cannot be written the list is not replaced and save reports it.
try? fm.removeItem(at: AccountStore.backupDir)
expect(AccountStore.save(three), "save")
expect(AccountStore.save(three) && files(AccountStore.backupDir.path).count == 1, "an unchanged save makes no backup")
expect(AccountStore.save(Array(three.prefix(1))) && files(AccountStore.backupDir.path).filter { $0.hasSuffix("-shrink.json") }.count == 1,
       "a save that drops accounts keeps a shrink copy")
let kept = written()
try! fm.removeItem(at: AccountStore.backupDir)
try! Data().write(to: AccountStore.backupDir)   // a file where the backup folder should be
expect(!AccountStore.save(three) && written() == kept, "a save whose backup fails must fail and keep the list")
try! fm.removeItem(at: AccountStore.backupDir)

// Running an account's tool: no API keys (subscription only), the account folder set.
let claude = Account(id: "c", provider: .claude, name: "C", dir: "/Users/test/.ai-illuminati/accounts/claude-1")
let codex = Account(id: "x", provider: .codex, name: "X", dir: "/x/codex-1")
setenv("ANTHROPIC_API_KEY", "k", 1); setenv("OPENAI_API_KEY", "k", 1); setenv("CODEX_HOME", "/elsewhere", 1)
expect(claude.environment["ANTHROPIC_API_KEY"] == nil && claude.environment["OPENAI_API_KEY"] == nil
       && claude.environment["CLAUDE_CONFIG_DIR"] == claude.dir && claude.environment["CODEX_HOME"] == nil, "Claude environment")
expect(codex.environment["CODEX_HOME"] == "/x/codex-1" && codex.environment["CLAUDE_CONFIG_DIR"] == nil, "Codex environment")
expect(AccountStore.gemini.environment["CODEX_HOME"] == nil && AccountStore.gemini.environment["CLAUDE_CONFIG_DIR"] == nil, "Gemini environment")
expect(codex.codexHome == "/x/codex-1" && Account(id: "y", provider: .codex, name: "Y", dir: nil).codexHome.hasSuffix("/.codex"), "Codex folder")

// Claude Code's own Keychain naming rule (first 8 hex digits of sha256 of the folder).
expect(claude.claudeKeychainService == "Claude Code-credentials-886ef913"
       && Account(id: "d", provider: .claude, name: "D", dir: nil).claudeKeychainService == "Claude Code-credentials", "Keychain name")

// Enterprise: the setting wins, otherwise the name says.
expect(Account(id: "s", provider: .claude, name: "Claude (학교)", dir: nil).isSchool
       && !Account(id: "p", provider: .claude, name: "Claude (학교)", dir: nil, school: false).isSchool
       && Account(id: "q", provider: .codex, name: "Mine", dir: nil, school: true).isSchool
       && !Account(id: "g", provider: .gemini, name: "Gemini (학교)", dir: nil).isSchool
       && Account(id: "g", provider: .gemini, name: "Gemini (학교)", dir: nil, school: true).isSchool, "Enterprise accounts (an unmarked Gemini is personal)")

// New accounts: a private folder each; Codex keeps its login in a file there.
let made = AccountStore.newAccount(provider: .codex, name: "ChatGPT 2")
let mode = (try? fm.attributesOfItem(atPath: made.dir ?? ""))?[.posixPermissions] as? Int
expect(made.dir == AccountStore.accountsDir + "/" + made.id && mode == 0o700
       && (try? String(contentsOfFile: made.dir! + "/config.toml", encoding: .utf8)) == "cli_auth_credentials_store = \"file\"\n", "new Codex account")
expect(AccountStore.newAccount(provider: .gemini, name: "G").id == AccountStore.gemini.id, "Gemini is always the one entry")
expect(made.school == false && !AccountStore.newAccount(provider: .claude, name: "Claude (학교)").isSchool
       && AccountStore.newAccount(provider: .gemini, name: "G").school == false, "a new account is personal until marked Enterprise")
print("PASS: AIAccounts promises (test home, save format, old lists, unreadable list, backups, environment, Keychain name, new accounts)")
