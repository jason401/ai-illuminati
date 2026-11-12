# AI Illuminati — rules for AI agents

macOS menu-bar app (Swift, no Xcode project) that runs Claude Code / Codex / Gemini CLIs under the user's own
accounts. Sources: `app/macos/*.swift`, modules in `app/modules/<Name>/`, bundled helpers in `app/resources/`,
scripts in `tools/`.
Feature and design notes live in `docs/`; read them only when the task needs them.

## Commands (registered in `.ai-illuminati.json`; run them with `project_run`)
- Test: `zsh tools/tests/run_mode2.sh` (`test`). Compiles the app sources with `tools/tests/*.swift` into a
  temp folder, runs the Python tests (`tools/tests/test_*.py`) and checks that the real `accounts.json` is unchanged.
- Build: `zsh tools/build_app.sh --stage` (`build`). Builds and signs `AI Illuminati.update.app` only; never
  touches the installed app. Needs the "AI Illuminati Local Signing" Keychain identity, so it fails in a sandbox.
- The build compiles `app/macos/*.swift`, but the test script has its own `swiftc` file list: add a new
  app file there too if the tested files use it.
- Modules: each `app/modules/<Name>/` is its own Swift module: `AILocalization` (`L()`, `AppLanguage`),
  `AIAccounts` (`Accounts.swift`), `AISpaces` (`Space*.swift`: saving, checks, the isolated web view; its UI stays in
  `app/macos/SpaceView.swift`), `AIRuntime` (`Answerer`, `RunConditions`, `StreamParser`, `NativeSessions`, Stop
  tokens, the local model, usage readings, cloud model picks; it decides no permission: callers pass
  `RunConditions.app` from `RunConditionsApp.swift`), `AIWorkspace` (`Workspace.swift` folder rules, `WorkspaceBackup`
  backups and Undo, `AutoGuard.swift` moved whole, `ToolProvider`/`ToolContext`, `DiskUsage`; the app reaches AutoGuard only
  through `FullAutoGuard.environment`), `AIProjects` (`ProjectWork.swift` Git work, repository lock, approvals, project
  turns; `Todo.swift` the TODO board and scheduler; `ProjectInfo.swift`; `ProjectCreator.swift`; the Git, Plan, Task, TodoAdd
  and ProjectMaker tools; it names no chat type: Discussion plugs in as `TodoChats` in `TodoChatsApp.swift`). Files that use one `import <Name>` and see only its `public` names; a
  module may import only the modules in its `dependencies` file. Tests that need a module's insides say
  `@testable import` (the test build adds `-enable-testing`); app files never do. Every `swiftc` that compiles app files runs
  `zsh tools/build_modules.sh <out>` first and adds `-I <out> <out>/lib*.a`. A new `public` name gets its reason
  in `docs/MODULES.md`. A module's own tests (`tools/tests/*_contract.swift`) are not enough when its behavior
  changes (save format, errors, folders, isolation): run the tests its promise row in `docs/MODULES.md` names, or
  the full test when unsure: unchanged `public` names do not mean unchanged behavior for its users.
- Previews: `zsh tools/tests/render_chat.sh`, `zsh tools/tests/render_drive_tree.sh`.

## Never break: tests and previews are isolated from the real app
- Real data: `~/Library/Application Support/AI Illuminati/` (accounts.json, chats, settings) and
  `~/.ai-illuminati/` (account folders, logins). Tests and previews must never read or write them.
  A test once overwrote real account metadata; this rule exists because of that.
- Only `app/macos/main.swift` calls `AccountStore.useRealHome()` (checked by the test script). Any other
  program built from these sources gets a throwaway home, or `AI_ILLUMINATI_TEST_HOME` when a test names one.
- New tests/previews: use `mktemp -d` and `AI_ILLUMINATI_TEST_HOME`; never `UserDefaults.standard`, the real
  Keychain items ("Claude Code-credentials*"), or real CLI config folders.

## Do not
- Do not change signing, install or release files unless the task asks for it: `tools/setup_signing.sh`,
  `tools/build_app.sh` signing steps, `tools/install_app.py`, `tools/package_release.py`,
  `tools/prepare_update_source.py`, `tools/tests/check_signing.py`, the Info.plist written by `build_app.sh`.
- Do not commit built apps, `dist/`, `app-build.log`, credentials or personal data (see `.gitignore`).
- Do not weaken workspace permissions or sandbox rules (`Workspace.swift`, `AutoGuard`, `project_process.py`)
  to make a task pass.
- Do not add progress notes, TODO lists or decision logs to this file.

## Code style
- Match the surrounding code: compact Swift, short comments that say why, no new dependencies.
- User-facing text goes through `L("한국어", "English")` with both languages.
