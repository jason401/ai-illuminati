# Modules: one Swift module per part, checked by promise → user → test

The app is one Swift program built from `app/macos/*.swift`: in it, every file can use every other file's
`internal` names, so a folder alone draws no line. A part in `app/modules/<Name>/` is its own Swift module:
it builds alone, and the app sees only its `public` names. The first one is `AIAccounts` (2026-11-11).

## How a module is built and used
- `zsh tools/build_modules.sh <out> [swiftc options]` builds every `app/modules/<Name>/` alone into
  `<out>/<Name>.swiftmodule` + `<out>/lib<Name>.a` (static: nothing new in the app bundle, signing unchanged).
- Every `swiftc` that compiles app files runs it first and adds `-I <out> <out>/lib<Name>.a`:
  `tools/build_app.sh` (compile step), `tools/tests/run_mode2.sh`, the preview scripts.
- Each file that uses a module says `import <Name>`. Not the hidden compiler option (`-Xfrontend -import-module`):
  the import line shows who uses the module (`grep -l "import AIAccounts"` lists its users), and no
  compile command needs one more flag.
- Name: not Apple's framework names (`Accounts` is one), hence `AIAccounts`.
- `run_mode2.sh` stage "AIAccounts module on its own": builds the module alone, runs its own test from outside
  (`tools/tests/accounts_contract.swift`, public names only), and checks that `AccountStore.place`
  (internal) does not compile outside the module.

## Which tests a change needs
Unchanged `public` names do not mean unchanged behavior: the four falsification runs below kept every public
declaration and still broke the app. Use the table: find the promise the change touches, run the module's own
test and the user tests in its row. When the row says "none", or it is unclear which promise a change touches,
run the full test (`zsh tools/tests/run_mode2.sh`). A new promise gets a row, a module check and a user check.

### AIAccounts (`app/modules/AIAccounts/Accounts.swift`)
| Promise | Users (files) | Module test | User tests (mode2.swift unless named) |
|---|---|---|---|
| Test home: only `main.swift` picks the real home; others get `AI_ILLUMINATI_TEST_HOME` or a throwaway one; `UserDefaults.app` follows | every file that stores data (`supportDir`, `accountsDir`, `home`, `.app`): Settings, Discussion, ProjectWork, Updater, ExternalMCP, FaceLink, Local, RemoteMCP (Keychain or file), … | contract: test home | run_mode2 stage 1 (rule), stage 3 `real_home.swift`, "test home and settings kept apart", final real `accounts.json` check |
| Save format: `accounts.json` pretty, sorted keys, empty fields left out (older and newer app versions read it) | Settings `AppModel.accounts` didSet | contract: golden file | "the app's account edits keep the shared format" |
| Reading: older lists load; an unknown kind of AI is skipped, not the list | Settings `AppModel.init`, Discussion (chat delete), Local (Ollama `model`) | contract: old lists | "the app's account edits …" (unknown entry), Gemma block |
| An unreadable list is copied aside before anything writes over it | Settings `AppModel.init` | contract: unreadable list | "the app's account edits …" (unreadable list) |
| Backups: a changed list is backed up first, dropped accounts make a `-shrink` copy, limits; no backup → no save, `false` | Settings `AppModel.accounts` didSet | contract: backups | "test home … account backups", "the app's account edits …" (failed backup) |
| Gemini is added once to lists from before it was an entry | Settings `AppModel.init` | contract | none |
| Tool environment: API keys removed, account folder set | Discussion `Answerer` | contract: environment | none (needs a CLI run) |
| Claude Keychain name = Claude Code's rule | Usage (Keychain read) | contract: Keychain name | none (needs the Keychain) |
| `codexHome` | Usage, Pictures, CloudModels | contract | pictures, cloud models |
| `isSchool`: the setting wins, else the name | Solo, Meeting, Todo, Peer, Enterprise, Settings UI | contract | "school accounts", plain chat (Enterprise), Enterprise lock |
| New account: private (0700) folder, Codex login in a file there, one Gemini entry | Settings `AppModel.add` | contract: new accounts | none |

## What the first module showed (2026-11-11)
- Change size: the module file got `public` on 26 names and one `public init` (Swift's own memberwise init is
  internal); 44 app files and 13 test files got one `import` line; one app line changed (`RemoteMCP` asked the
  internal `AccountStore.place`, now `UserDefaults.app`). Scripts: `build_modules.sh` (new, 14 lines), the
  compile step of `build_app.sh` (9 lines), five lines of `run_mode2.sh` plus the new stage, three lines in each
  preview script. Adding the import lines by hand would be slow: a script added them where the module's names
  appear outside strings and comments, then the compiler confirmed.
- Parallel work: two AIs in two worktrees from one written contract (`AccountStore.latestBackup()` in the module,
  `AppModel.restoreLatestBackup()` in the app). The app side checked itself against a stub built from the
  contract; after the merge, with the real code, the full test passed. Trial branch: `trial/accounts-parallel`
  (local, not merged).
- Falsification (public interface compared with `-emit-module-interface`, unchanged in every run):

  | Change | Module test | User tests only |
  |---|---|---|
  | no sorted keys in `accounts.json` | caught | caught (shared format) |
  | unreadable list not copied aside | caught | caught (unreadable list) |
  | save goes on when its backup fails | caught | caught (failed backup) |
  | one unknown entry drops the whole list | caught | **missed** → user check added ("unknown entry") |
  | `ANTHROPIC_API_KEY` kept in the tool environment | caught | see the row: none |
