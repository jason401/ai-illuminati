# AI Illuminati — notes for Claude

Younghun's macOS menu bar app: remaining subscription usage (5-hour / weekly) per AI account
(multiple Claude, multiple ChatGPT/Codex, one Gemini via agy). Private repo: github.com/jason401/ai-illuminati (MIT license file).
Bigger plan (AI agents talking to each other, dashboards): `~/Downloads/ai-office-spec.md`; this app is steps 1 (usage gauge) and 2 (chat).

## How to work with Younghun
- Answer in Korean, simply. Avoid jargon.
- Every reply: call the `ai-face` MCP tool `set_expression` (skip silently if missing).
- Never use API keys. Never handle his passwords; logins go through each tool's own login.
- `claude -p` is allowed: Anthropic paused the June 2026 change, so it still draws from subscription limits
  (support.claude.com/en/articles/15036540, checked 2026-10-14; Oct 7 update added API credits for Max/Team).

## Layout
- `app/macos/main.swift` menu · `Settings.swift` AppModel (account list, options) + Settings window ·
  `ChatWindow.swift` chat UI · `Discussion.swift` Answerer (runs each CLI, tools off) + 3-step discussion + summary, ChatStore (chats/*.json) ·
  `Accounts.swift` account list/folders (Gemini is an entry too) · `Usage.swift` readers ·
  `Login.swift` Terminal login scripts (window closes itself) · `Icon.swift` eye-in-triangle template icon.
- Data: `~/Library/Application Support/AI Illuminati` (accounts.json, chats/*.json, last-usage-*.json, login .command files).
  Chat rules live in UserDefaults `chatRules` (default in `AppModel.defaultChatRules`).
- agy keeps a local history file per `agy -p` call (`~/.gemini/antigravity-cli/conversations`); Claude/Codex calls keep none.
- Account folders: `~/.ai-illuminati/accounts/<id>`.

## How usage is read (verified 2026-10-14)
- Codex: `codex app-server` JSON-RPC `account/rateLimits/read` + `account/read`, with `CODEX_HOME`.
  Binary bundled in `/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex`.
- Claude: Keychain `Claude Code-credentials[-<sha256(CLAUDE_CONFIG_DIR)[0:8]>]`, read only; then
  `GET https://api.anthropic.com/api/oauth/usage` (undocumented). Prefer its `limits` array (plans differ:
  school plan has no overall weekly limit, only Cowork weekly).
- Gemini: `agy -p /usage` prints TSV lines. Login email from agy logs.

## Build
- `zsh tools/build_app.sh < /dev/null` (same as double-clicking `Build AI Illuminati.command`).
- Requires the persistent "AI Illuminati Local Signing" identity in the login keychain. No ad-hoc fallback. Run `zsh tools/setup_signing.sh` only if missing; preserve the existing identity.
- Read the latest snapshot at the top of `HANDOFF.md` before editing. Older chronological notes below it describe earlier states.
- Regression checks: `zsh tools/tests/run_mode2.sh`; signing checks: `python3 tools/tests/check_signing.py`. The image clipboard test needs access to the macOS pasteboard service.
- Commit and push to `origin main` when a change is done. End commit messages with the Co-Authored-By line.

See also `HANDOFF.md` (state and open items as of 2026-10-14) and `AGENTS.md` (same notes, for Codex).
