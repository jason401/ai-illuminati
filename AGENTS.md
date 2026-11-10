# AI Illuminati — rules for AI agents

macOS menu-bar app (Swift, no Xcode project) that runs Claude Code / Codex / Gemini CLIs under the user's own
accounts. Sources: `app/macos/*.swift`, bundled helpers in `app/resources/`, scripts in `tools/`.
Feature and design notes live in `docs/`; read them only when the task needs them.

## Commands (registered in `.ai-illuminati.json`; run them with `project_run`)
- Test: `zsh tools/tests/run_mode2.sh` (`test`). Compiles the app sources with `tools/tests/*.swift` into a
  temp folder, runs the Python tests (`tools/tests/test_*.py`) and checks that the real `accounts.json` is unchanged.
- Build: `zsh tools/build_app.sh --stage` (`build`). Builds and signs `AI Illuminati.update.app` only; never
  touches the installed app. Needs the "AI Illuminati Local Signing" Keychain identity, so it fails in a sandbox.
- The build compiles `app/macos/*.swift`, but the test script has its own `swiftc` file list: add a new
  app file there too if the tested files use it.
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
