# Coding mode: let a chat AI work on a linked project like Claude Code / Codex do

Written 2026-11-06 for GPT. Read `CLAUDE.md` / `AGENTS.md`, the top of `HANDOFF.md` and `docs/GOOGLE_DRIVE_BACKEND.md`
first and follow their rules (Korean, simple replies to Younghun; tests before commit; push `main`; **`stable` only
after his explicit "배포해"**; public repo: no emails, tokens or personal data). Do not change the Drive code paths
while doing this, except to share ToolHub plumbing.

## Goal

Younghun links a project folder (for example `~/Documents/Projects/AI Face`) to a plain chat and says
"read X and change it like this". The AI should work the way Claude Code and Codex work for him today:
read and edit files, run build and test commands, then `git pull`, commit, push to `main`, and — only after he
approves in the app — publish to `stable`. Same models, same subscription accounts.

## What already exists (do not rebuild)

- `Workspace.swift`: linked roots and three levels — 보기 (view), 작성 (write), 작성+실행 (write + execute).
  Claude runs with `--tools Read,Grep,Glob,Edit,Write,Bash`, `--permission-mode dontAsk`, a sandbox that can write only
  the linked roots; Codex runs `workspace-write` with `features.shell_tool=true`.
- `WorkspaceBackup.swift`: a backup before each AI run, the change list and Undo; it already records git state and
  adds `refs/ai-illuminati/<run>` markers.
- `ToolHub.swift` + `app/resources/workspace_mcp.py`: per-answer capability, providers (`FaceLink`, `DriveLink`).
- Native sessions (`NativeSessions.swift`): a chat keeps one Claude/Codex session, so multi-step work can continue.

## What blocks "work like Claude Code" today

1. **No network inside the sandbox.** Codex: `sandbox_workspace_write.network_access=false`; the Claude sandbox
   also has no allowed domains. So `git pull`, `git push`, `gh`, package downloads fail.
2. **`.git` is not writable for Codex.** Codex keeps `.git` read-only inside writable roots, so `git commit` fails.
   (Check Claude's sandbox too.)
3. **Keychain / signing inside the sandbox.** Builds that sign (`build_app.sh` uses the "… Local Signing" identity)
   or read the Keychain will likely fail inside the sandbox. Verify with AI Illuminati and AI Face.
4. **Project rules are not loaded.** The CLI runs in a session folder, and Claude uses `--setting-sources ""`, so
   the project's `CLAUDE.md` / `AGENTS.md` are not read automatically.
5. **Time limit.** `Answerer.ask` defaults to 240 s. Real coding turns take 5–30 minutes.
6. **Nobody can approve mid-run.** `-p` / `exec` cannot show a permission prompt; risky steps need an app-side approval.
7. **Two AIs on one repo.** Discussion/vote modes could let several AIs edit the same folder at once.

## Decisions

1. **Git and other outside-the-sandbox actions go through the app, not through opening the sandbox.**
   Keep the AI sandbox as it is (no network, no `.git` writes). Add a ToolHub provider **`GitLink`** whose tools the
   app runs itself, as Younghun's user, with his existing `gh` login. This is the same pattern as Drive: the AI asks,
   the app checks the rules and does it. The AI never gets network or credentials.
2. **New level "코딩" (Code)** above 작성+실행, offered only for a linked folder that is a git repository.
   It means: write + execute (as today) + `GitLink` tools + project rules loaded + long time limit.
3. **Rules enforced in the app (not just in the prompt):**
   | Action | Rule |
   |---|---|
   | status, diff, log, branch list | always allowed |
   | pull | `git pull --ff-only` only. On conflict or a non-fast-forward: stop, report, change nothing |
   | commit | allowed; the app commits only paths inside the repo; author = the user's own git config; message from the AI |
   | push `main` (or the current feature branch) | allowed if it is a fast-forward |
   | push `main:stable` (publish) | **approval card in the chat**; the tool waits for the click (timeout 15 min → refused) |
   | new branch, switch branch | allowed if the working tree is clean |
   | force push, delete branch, reset --hard, rebase, tag delete, history rewrite, change remotes or git config | **not provided** |
4. **Outside-sandbox commands (build that signs, install, tests that need the Keychain)** go through one tool
   `project_run(name)`. Names come from a small file in the project, `.ai-illuminati.json`
   (e.g. `{"commands": {"test": "zsh tools/tests/run_mode2.sh", "build": "zsh tools/build_app.sh --stage < /dev/null"}}`).
   The first run of each command in a chat shows an approval card; output is returned to the AI (cap 60k chars).
   The AI cannot pass arbitrary shell through this tool. Everything else still runs inside the sandbox via Bash.
5. **Project rules:** in 코딩 level the app reads the repo's `CLAUDE.md` and `AGENTS.md` (top level, cap ~30k chars)
   and puts them at the top of the prompt as "project rules". Also run the CLI with the repo root as working
   directory where the sandbox allows it.
6. **One writer per repo.** A per-repo lock in the app; a second chat or AI that wants 코딩 on the same repo waits or
   is told it is busy. In discussion/vote modes only one chosen AI gets 코딩; the others get 보기 to review.
7. **Undo vs. push.** Undo still works for local edits. After a push, Undo is disabled for that run and the chat
   says the change is already on GitHub (fix it with a new commit).
8. **Time limit** in 코딩 level: 45 minutes per answer, with the existing Stop button; streaming progress as today.

## Code changes

### `GitLink.swift` (new, ToolProvider)
- Active only for rooms whose binding level is 코딩 and whose root is a git repo (`git rev-parse --show-toplevel`).
- Tools: `git_status`, `git_diff(path?, staged?)`, `git_log(n)`, `git_pull`, `git_commit(message, paths?)`,
  `git_push(branch?)`, `git_publish_stable` (push `main:stable` after approval), `git_branch(name)`, `git_switch(name)`,
  `project_run(name)`.
- Run git with `Process`, fixed argument arrays (no shell strings), `GIT_TERMINAL_PROMPT=0`, a timeout, and the repo
  path from the binding (never from the AI's arguments).
- Every result is short JSON: `ok`, `summary`, `output` (capped). Each action is also shown in the chat as a small
  line ("git push main → 3f2a1c0") so Younghun can see what happened.
- Approval: a pending request object the chat window observes; buttons "허용" / "거절". Refuse automatically on
  timeout, chat stop, or window close.

### `Workspace.swift`
- `WorkspaceLevel.code` (title "코딩" / "Code"). Arguments as `.execute`, plus the GitLink tools in
  `--allowedTools` (`mcp__illuminati__git_*`, `mcp__illuminati__project_run`), plus the project-rules prompt.
- Offer 코딩 only for a single git-repo directory root.

### `ToolHub.swift`
- Add `GitLink.shared` to providers; pass the room's binding in `ToolContext` so GitLink knows the repo.

### `Discussion.swift` / `Solo.swift`
- 45-minute timeout in 코딩 level; the per-repo lock; in multi-AI modes, 코딩 only for the chosen worker.
- Prompt line for 코딩: "Use the git_* tools for git (not Bash git). Before editing: git_pull. After tests pass:
  commit and push main. Never publish to stable unless the user asked in this chat; the app will ask him."

### `ChatWindow.swift`
- Level picker gets 코딩 (with a one-line explanation). Approval cards. Git action lines. Undo disabled after push.

### Docs
- `docs/USAGE.md`: the 코딩 level in a short paragraph; `.ai-illuminati.json`. Add `.ai-illuminati.json` to this repo
  (test + build commands from `CLAUDE.md`). `HANDOFF.md` snapshot.

## Tests (`tools/tests/`)

Use a temporary bare repo as `origin` and a clone as the linked folder (no network, no real GitHub).
1. pull fast-forward works; pull with a conflicting local change → refused, tree unchanged.
2. commit + push `main` → the bare repo has the commit; non-fast-forward push → refused.
3. `git_publish_stable` waits for approval: refuse → `stable` unchanged; approve → `stable` == `main`; timeout → refused.
4. No tool can force push, delete a branch, reset, or touch a path outside the repo; repo path comes only from the binding.
5. `project_run` runs only named commands from `.ai-illuminati.json`; first run needs approval; output capped.
6. GitLink tools absent for 보기/작성/작성+실행 levels and for non-git folders.
7. Per-repo lock: a second 코딩 run on the same repo is refused or waits.
8. Undo is disabled after a push in that run.
9. All existing tests pass (`zsh tools/tests/run_mode2.sh`), then `zsh tools/build_app.sh --stage < /dev/null` and
   `python3 tools/tests/check_signing.py`.

## Real check with Younghun

1. Link `AI Face` (or a scratch repo first) at 코딩 level in a plain Claude chat. Ask for a tiny change (a README line).
2. It should pull, edit, run the tests via `project_run` (approval card), commit, push `main`.
3. Ask "배포해" → approval card → `stable` updated. Repeat once with ChatGPT.
4. Check signing builds work through `project_run` (point 3 of "What blocks").

If any CLI cannot call the GitLink tools inside its sandbox, or a needed build cannot run even through
`project_run`, stop and report the exact error to Younghun. Do not open network or `.git` writes in the sandbox
on your own.
