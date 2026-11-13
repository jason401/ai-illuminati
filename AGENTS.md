# AI Illuminati — rules for AI agents

macOS menu-bar app (Swift, no Xcode project) that runs Claude Code / Codex / Gemini CLIs under the user's own
accounts. Sources: `app/macos/*.swift`, modules in `app/modules/<Name>/`, bundled helpers in `app/resources/`,
scripts in `tools/`.
Feature and design notes live in `docs/`; read them only when the task needs them.

## Commands (registered in `.ai-illuminati.json`; run them with `project_run`)
- Test: `zsh tools/tests/run_mode2.sh` (`test`). Compiles the app sources with `tools/tests/*.swift` into a
  temp folder, runs the Python tests (`tools/tests/test_*.py`) and checks that the real `accounts.json` is unchanged.
  Quicker while working: `--affected <changed paths>` runs only the tests `tools/test_map.txt` picks (unclear: all);
  see `docs/MODULES.md` "Which tests a change needs".
- Build: `zsh tools/build_app.sh --stage` (`build`). Builds and signs `AI Illuminati.update.app` only; never
  touches the installed app. Needs the "AI Illuminati Local Signing" Keychain identity, so it fails in a sandbox.
- The build compiles `app/macos/*.swift`, but the test script has its own `swiftc` file list: add a new
  app file there too if the tested files use it.
- Modules: every `swiftc` that compiles app files runs `zsh tools/build_modules.sh <out>` first and adds
  `-I <out> <out>/lib*.a`. Module guards alone: `zsh tools/check_modules.sh` (also the pre-commit hook; install the
  hooks once with `zsh tools/setup_dev.sh`). A module's own contract is not enough when its behavior changes (save
  format, errors, folders, isolation): run the tests its promise row in `docs/MODULES.md` names, or the full test.
- Previews: `zsh tools/tests/render_chat.sh`, `zsh tools/tests/render_drive_tree.sh`.

## Module rules (모듈 유지 규칙)
Each `app/modules/<Name>/` is a Swift module; others see only its `public` names. Owners, arrows = may import:
- `AILocalization` L(), AppLanguage · `AIAccounts` accounts, folders, Enterprise lock (both import nothing)
- `AISpaces` Spaces saving, checks, isolated web view → Accounts, Localization
- `AIRuntime` runs the CLIs, sessions, usage, local model; decides no permission → Accounts, Localization
- `AIWorkspace` folder rules, backups/Undo, AutoGuard (whole), tool gateway types → + Runtime
- `AIProjects` Git work, approvals, TODO board and scheduler, project info → + Workspace
- `AIChat` chats, Discussion, routing, meetings, ask_ai, chat window → + Projects, Spaces
- `AIIntegrations` Google login/Drive, outside MCP, AI Face link → Accounts, Localization, Workspace (Runtime
  only through Workspace's interface)
- App (`app/macos`): screens, settings, app start, connecting modules; only it imports Integrations.

Where new code goes: (1) the module that owns the work; (2) App, only if it is a screen, a setting, app start or
connecting modules; (3) neither: stop and ask the user.
Never: a dependency outside `tools/module_graph.txt`; logic in an `extension` of another module's type; a
"Core"/"Common" module; making internals `public` in bulk (each new public name gets its reason in
`docs/MODULES.md`); splitting AutoGuard; `@testable import` in app files or contracts; `git commit --no-verify`.
Only with the user's approval: changing the graph, a new module (`tools/new_module.sh`), removing or merging modules,
changing a guard (`tools/check_modules.*`, `module_graph.txt`, `build_modules.sh`, run_mode2's module checks,
`.githooks`; hashed in `tools/module_guard.sha256`).
If a check fails, fix the code, not the check. Details and examples: `docs/MODULES.md` "Rules".

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
