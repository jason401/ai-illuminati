# Modules: step records (moved from docs/MODULES.md in step M, 2026-11-12)

What each modularization step showed, in order: falsification tables, parallel trials and decisions. They describe the
code at that step; the current rules and map are in `docs/MODULES.md`.

## App, step A: final falsification and parallel trial (2026-11-12)

The reproducible command is registered locally as `validate-app-modules`
(`python3 -B tools/tests/validate_app_modules.py`). It first runs the unchanged Swift ToolHub test, then changes one
body/list at a time in temporary copies. DependencyRules independently mutates disposable module trees.

| Mutation | Detected by |
|---|---|
| A1 Peer/Convene order exchanged | testToolHub: exact original 13 singleton order |
| A2 last(where:) instead of first(where:) | testToolHub: first eligible duplicate provider |
| A3 active check removed from call dispatch | testToolHub: inactive providers absent from listing and calls |
| A4 consulted Convene exclusion removed | testToolHub: exact consulted provider identities before providers' own gates |
| A5 expiry check replaced with true | testToolHub: expired sessions cannot list or call |
| Declared Runtime -> Chat reverse edge/cycle, undeclared/attributed/scoped imports, unknown/duplicate/unused declarations | DependencyRules temporary-tree tests |

All five Swift mutants were caught after the unchanged baseline passed. No mutant touched main's source.
The one parallel experiment overlapped both workers and both module contracts passed separately and after manual
combination. The initial integration copied disjoint module directories; review subsequently verified the Git three-way
result using merge-tree (details below). Consumer validation then failed with exit 133 at mode2's "everyone must give an opening view first":
Code tracing identifies the Gemini title's use in Discussion.label as the cause. The review's Localization-only full
consumer run passed, supporting that diagnosis; Accounts-only consumers were not run separately.
**Module-only validation was insufficient for this behavior change.**
The original experimental consumer assertions were kept; the trial behavior is never promoted to main.
The combined run stopped at its first failure: later app assertions, space_web, icon and the final accounts checksum
were not run in that combined experimental tree. The later Localization-only consumer run and main's complete suite
both reached and passed those stages and the final account checksum.

The first harness treated this experimental consumer failure as an exception and cleaned its temporary folder before
saving artifacts. The exact deterministic mutation sources and result were recovered from its project_run output.
The harness now checkpoints before consumers and records this expected negative finding. A link-only resume does
not repeat the parallel experiment. The link-only resume passed (exit 0), including an unchanged-main-source hash check. A subsequent record preflight
verified each recovered source equals current main plus exactly its one prescribed mutation; recovery provenance and
the original consumer failure are recorded explicitly. These one-time recovery commands and helper functions were
removed from the shared registry/script after the review; only test, build and validate-app-modules remain.
The default validator creates its artifacts and never requires an ignored result.json input. Final main run_mode2.sh and the
staged signed build both passed (exit 0). No trial behavior or built app is committed to main.

Contract: [APP_PARALLEL_TRIAL.md](APP_PARALLEL_TRIAL.md). Two concurrent script workers change Accounts' Gemini
display title and Localization's uppercase-language handling in isolated copies, run each leaf module's own contract,
then combine and rerun both contracts, full run_mode2 and an all-source app link. Original app source hashes must be
unchanged. Sources/results are preserved under ignored .ai-illuminati/a-trial for local trial branch snapshots.
Unlike earlier trials, these are script workers in copies, not two AIs in worktrees. Connected git_* tools have no
worktree/merge operation: the local branch snapshots used manual composition. The review closed the conflict-check gap
with temporarily registered merge-tree validation; no working-tree merge or merge commit was created.
Module-only success is limited to these cases, and never
replaces the consumer tests in each promise row. C0's Space-refine app-path coverage gap is still open.

Review follow-up (2026-11-12):
- `git merge-tree --write-tree trial/app-a-accounts-20261112 trial/app-a-localization-20261112` exited 0:
  no three-way conflicts. Result tree `d384cac44f05839dba761f7e35c35b2568bbb0cb` equals `28beee3^{tree}`.
  This command writes Git objects but does not update the working tree or branch refs. Its one-time registry entry was removed.
- A Localization-only snapshot first verified the recorded source equals current main plus the prescribed replacement,
  then ran the entire run_mode2.sh: exit 0, through space_web, icon and the final account checksum. Main app source hashes
  stayed unchanged. This was follow-up consumer validation, not another parallel trial.
- The consulted-call loop named tools no fixture exposed and the empty slow-list check proved nothing, so both were deleted.
  Central origin filtering remains checked by actual singleton identities (A4); the nonempty slow-name positive check
  remains in testExternalMCP, with no claim that an excluded-name negative case is covered.
- register() can skip listening for in-process fixture hubs. Production keeps its default; testToolHub asserts no hub.sock.
- run_mode2 stage 1 is now named "Check module dependencies and the data folder rule".
- After these fixes, main passed the complete run_mode2.sh (including the no-socket fixture assertion and final
  account checksum) and the staged signed build, both exit 0.

Local trial snapshots (not pushed or merged into main):
- `trial/app-a-accounts-20261112`: 165633a
- `trial/app-a-localization-20261112`: 99b50d3
- `trial/app-a-combined-20261112`: 28beee3 (manual composition, not a merge commit)

Returned to main with a clean tree, then compared Accounts.swift, Language.swift and accounts_contract.swift with
their exact pre-trial contents: identical. No trial branch was deleted. Stable publication/release and branch cleanup
remain the user's decisions; no force push was performed.


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

## What the second step showed (2026-11-11: AILocalization, AISpaces)
- Change size: `AILocalization` is the old `Language.swift` minus `localizedNotice` (now in `ChatWindow.swift`), 5 names
  public; 45 app files and 8 test files got `import AILocalization`. `AISpaces`: four files moved, 139 `public`
  declarations (list above), one wrapper (`SpaceMigrator` became an enum so its WebKit delegate methods stay
  inside), explicit public inits where Swift's memberwise ones are internal (`SpaceDraftNote`, `SpaceRefineEntry`,
  `SpaceActions`, `SpaceWebView`, `SpaceBad`, `SpacePictures.Request`); 6 app files and 4 test files import it.
  No app line changed besides imports. Scripts: `build_modules.sh` gained `dependencies` (order, only declared
  modules visible); the other compile commands already took `lib*.a` and `app/macos/*.swift`, so `build_app.sh`
  and the preview scripts needed nothing; `run_mode2.sh` lost five files from its list and runs both contracts.
- Finding the public names: everything internal first, then the app compiled against the module, the compiler's
  "inaccessible" notes turned into `public` by a script, repeated until it built. Tests were left out of that loop, so
  no name became public only for a test; `space_build.swift` uses `@testable`, `space_web.swift` was rewritten to
  open pages through `SpaceWebView` (the app's own way) and needs nothing extra.
- Falsification (public interface from `-emit-module-interface`, the same hash in every run). First run with the
  tests as they were, then with the user checks added:

  | Change | Contract | User tests, before | User tests, after |
  |---|---|---|---|
  | S1 `manifest.json` without sorted keys | caught | missed | caught ("shared manifest format", via `syncLibrary`) |
  | S2 id no longer taken from the folder | caught | missed | caught ("a copied folder is its own Space", `Discussion.spaceRule`) |
  | S3 `state.json` that is not one object read as it is | caught | missed | caught ("a Space with odd data", `SpaceWebView`) |
  | S4 files no longer 0600 | caught | missed | caught ("its files are private") |
  | I1 web view data store persistent | — | missed | caught (data store check) |
  | I2 every navigation allowed | — | missed | caught (`about:blank?moved`: the content rules do not block it) |
  | I3 CSP `connect-src *` | — | missed | caught (policy text) |
  | I4 hidden picture files served | — | missed | caught (`assets/.kept.png`) |

  The isolation has layers (CSP, content rules, navigation policy, guard script): with one layer weakened the others
  still stopped every load the test tried, so a behavior test alone cannot see it. Each layer now has its own check.
- Parallel work: two AIs in two worktrees from one written contract (`SpaceStore.duplicate(_:)` in the module,
  `Discussion.duplicateSpace(_:)` and a sidebar "Duplicate" item in `SpaceView.swift`), each checked alone (the app
  side against a stub it did not commit). The merge had no conflicts and the full test passed, after one line the
  contract had missed: the test build's file list did not have `SpaceView.swift`, where the contract put the user
  code. The app-side AI found it and left it to the merge. Trial branch: `trial/spaces-parallel` (local, not merged).
- For the next step (Runtime, RunConditions): the contract names the files each side may touch and also every
  build or test list those files must be in; find the public names by compiling the app against an all-internal
  module, never by hand; for every promise write one user check that goes through the app's own way in (as
  `SpaceWebView` here), and for a guard with several layers check each layer, since behavior alone hides a weak one;
  run the falsification before calling a row done.


## Runtime, step R0: the way in made narrow, before it becomes a module (2026-11-11)
Target order: `AILocalization`, `AIAccounts` ← Runtime ← Workspace ← Projects, Chat ← App. Runtime (now `Answerer`,
`StreamParser`, `AnswerProgress`, `RunConditions` in `Discussion.swift`) no longer names `WorkspaceInvocation`,
`AutoGuard`, `PlanLink`, `FaceLink` or `projectRunID` (grep from `struct RunConditions` to `ChatTurn`: 0). No module
yet (R1); nothing changed in what the tools are started with (below).
- `Answerer.ask(…, run: RunConditions, …)`: `run` is required, so no call can forget the Codex face rule. A
  `RunConditions` holds only how to start: `prefix` (before the tool's arguments), `wrapper` (program + its
  arguments, the tool after them), `environment` (the account's environment → the tool's), `processGroup` (stop the
  whole group at the end), `folders` (`directory` of the room, `arguments` and `read` from the linked folders).
  The rules stay with the caller: `RunConditions.app(account, workspace?)` in `Workspace.swift` puts Codex's AI Face
  servers off (`FaceLink.codexOff`), wraps project work in `project_process.py` with `AI_ILLUMINATI_PROJECT_PROCESS`
  and a process group, and calls `AutoGuard.environment` when `fullAccessActive` (the call moved; AutoGuard's own
  code did not change). The arguments get the answering account; file requests are read without it, as before.
- `AnswerProgress.todos(Any?)` replaces `.plan([WorkStep])`: the parser sends every TodoWrite `todos` input as it
  came, where it came in the stream; `ProjectChat` turns it into steps (`PlanLink.todos`) and drops what is not a list.
- Left for R1 (Runtime still uses them; R1 moved them into `AIRuntime` or behind `ToolHome`, see below): `CloudModels` (model pick, `apply`, `noteSeen`), `LocalModel.ask`,
  `GeminiLinks` (agy web rules and note), `ClaudeUsage.binary`/`CodexUsage.binary`, `Login.home`/`agyInstalled`,
  `NativeSessionCall`, `DebateCancellation`, `AccountStore.home` (AIAccounts, allowed). `GeminiLinks.workspaceNote` is
  used by `Workspace.swift`. Users of Runtime: Attachments, Collaboration, Debate, Local, NativeSessions, Peer, Poker,
  ProjectChat, Route, Solo, SpaceView, Workspace, Usage, Enterprise (`Answerer.Failure`).
- Contract for parallel work in R1: a Runtime side touches `Discussion.swift` (Answerer…StreamParser, moved to
  `app/modules/<Runtime>/`), and must keep `tools/tests/run_mode2.sh`'s file list and `build_modules.sh` order right;
  the app side touches `Workspace.swift` (`RunConditions.app`), `ProjectChat.swift`, `Solo.swift` and every call site
  above; both run `run_conditions.swift` (in the run_mode2 list) and the full test.

### Runtime promises (draft)
| Promise | Users (files) | Runtime test | User tests (through the app) |
|---|---|---|---|
| The tool starts with exactly what `RunConditions` says: prefix before its arguments, the wrapper's program first and the tool after its arguments, the changed environment, the group stopped at the end | every `Answerer.ask` caller (`RunConditions.app`) | none yet (R1: a contract test with a hand-made `RunConditions`) | `run_conditions.swift`: launches through `Discussion.requestDebate` for Claude, Codex, Gemini, local × plain, folder, folder with full access, project off, project on (a read-only view), and through ProjectChat's own run (`send()`: write and execute, backup, session) for Claude and Codex × the chat's full auto off and on; compared byte for byte with `run_conditions.golden` |
| Full access → AutoGuard's environment (shims on PATH, no Git/GitHub credentials, no SSH agent); off → none | `RunConditions.app` (RunConditionsApp.swift) | — | `run_conditions.swift` layer checks: project-on and folder-full have it, project-off and folder do not; `testFullAuto` (the shims themselves) |
| Project work runs in `project_process.py` (its own process group, `AI_ILLUMINATI_PROJECT_PROCESS=1`) and the whole group is stopped | `RunConditions.app`, ProjectChat | — | `run_conditions.swift` (wrapper, marker, group: three separate checks in one), `testProjectWork` ("Stop kills foreground and background project writers") |
| Codex: the account's own AI Face servers are off on every call | `RunConditions.app`, every Codex call | — | `run_conditions.swift` ("AI Face's own server is turned off"), AI Face link test in mode2 |
| Linked folders: arguments from the folder rules, runs in `rooms/<id>/stateless-…`, file requests read and answered (limits, repeats) | Workspace.swift, Attachments, Collaboration, Peer, ProjectChat | — | `run_conditions.swift`, mode2 "file requests keep good files …" |
| Stream events in order: text (at most ~12 a second, all at the end of a message), tool starts, every TodoWrite list raw | Solo (text, activity), ProjectChat (all three) | mode2 StreamParser block (order, two lists, a list that is not one) | `testProjectHandoff`: a TodoWrite line through `StreamParser` and project work's own progress becomes the plan |
| The local model starts no command line tool (RunConditions do not apply) | Local | — | `run_conditions.swift` ("the local model starts no command line tool") |

### Falsification (2026-11-11): one change at a time, call sites and signatures kept
`run_conditions.swift` checks each guard first, then the whole capture against the golden file:

| Change | Layer check | Golden file | Other user test |
|---|---|---|---|
| M1 `AutoGuard.environment` not applied | caught (full access → AutoGuard) | differs (78 lines) | — |
| M2 no `project_process.py` wrapper | caught (process group) | differs (24) | — |
| M3 process group not stopped (`processGroup` false) | caught | differs (12) | — |
| M4 full access reversed | caught | differs (146) | — |
| M5 no `AI_ILLUMINATI_PROJECT_PROCESS` | caught | differs (6) | — |
| M6 Codex face servers left on | caught | differs (10) | — |
| M7 Answerer ignores `run.environment` | caught | differs (84) | — |
| M8 Answerer ignores `run.wrapper` | caught | differs (24) | — |
| P1 TodoWrite event dropped | caught (StreamParser block) | — | caught (`testProjectHandoff`) |
| P2 TodoWrite sent after the message's text | caught (StreamParser block) | — | — |
| P3 ProjectChat ignores the event | passes (parser fine) | — | caught (`testProjectHandoff`) |
| P4 only the first list of a message | caught (order check) | — | — |
| P5 parser filters lists itself (old behavior) | caught (order check) | — | — |

The capture was made from the code before the change (with only `Answerer.launchForTests` added), three runs
identical, and is byte-identical after it (sha1 `1ca3b747…` for the first 449 lines). After review: the
`requestDebate` project kinds are a read-only view, so ProjectChat's own run was added (198 lines). Its baseline was
taken from 9b6af86 plus the hook alone, in a separate worktree; it is byte-identical with the code after the change.
That capture showed one thing that was already there before R0: `Discussion.soloBinding` rebuilds a project chat's
binding without `fullAuto`, so turning full auto off for a project chat still runs the work full auto
(`bypassPermissions`, AutoGuard). R0 keeps that as it is (the golden file records it); fixing it is a separate change. It needs no CLI: a missing tool counts as `<cli>`;
the environment is compared with the account's own after a fixed start (plain PATH, a GitHub token and an SSH agent
to take away), Claude's `--mcp-config` with sorted keys. Gemini has no "plain" kind: it would add web rules to agy's
settings in the real home.

## What the third step showed (2026-11-11: AIRuntime, R1)
- Before the move: R0's conditions still held on main (cdbec40): no `WorkspaceInvocation`, `AutoGuard`, `PlanLink`,
  `FaceLink` or `projectRunID` between `struct RunConditions` and `ChatTurn`, and the full test passed with
  `run_conditions.swift`'s golden file byte-identical (all eight kinds). `runtime_contract.swift` was written and run
  against that code first (plus only the new `Answerer.toolForTests` hook): it passed, three runs; after the move the
  same file, compiled from outside the module, passes, and so does the golden file.
- Change size: four files moved whole (`NativeSessions`, `CloudModels`, `Usage`, `Local`), two made from parts
  (`Answerer.swift` = Discussion.swift's `GeminiLinks` … `StreamParser`; `Cancellation.swift` = Debate.swift's
  `DebateCancellation`). 135 `public` declarations (list above), explicit public inits where Swift's memberwise ones
  are internal (`RunConditions`, `RunConditions.Folders`, `DebateCancellation`, `NativeSessions`, `LocalModel.Variant`).
  Lines that left for the app: `GeminiLinks.workspaceNote` (Workspace.swift), `LocalModel.install` (Login.swift).
  New: `ToolHome` (the user's home where the tools live; `Login.home`/`agyInstalled` read it) and `ReplyHeadline.split`
  (NativeSessions named `ChatTurn.Entry.reply`, a chat type; both now cut the TL;DR line with one function). 26 app
  files and 10 test files got an import line. Scripts: `run_mode2.sh` lost four files from its list, runs the runtime
  contract, four boundary checks and a check that no app file sets `toolForTests`; `build_app.sh` and the preview
  scripts compile `app/macos/*.swift` and every `lib*.a`, so they needed nothing (`render_settings.sh`, a local file,
  builds the modules with `-enable-testing`).
- Finding the public names: everything internal, then a script compiled the app against the module and turned what the
  compiler named into `public`: its "declared here" notes (they name the module's interface, `AIRuntime.Answerer.ask`,
  not a source line, so the script finds the declaration by name and argument labels), "cannot find … in scope" for
  internal types, and in the module itself "… because its parameter uses an internal type", repeated until the app
  compiled. Hand work only
  where the compiler names nothing usable: the implicit inits above, fields of a one-line struct (`LocalModel.Loaded`),
  `Fit`'s `<` (asked by `Comparable`). Tests were left out of the loop: they say `@testable import AIRuntime` instead.
- Promise table: the AIRuntime section above (errors, Stop, time limit, left processes, threads, event order, session
  storage format).
- Two layers in Stop, found by the falsification: Foundation starts the tool as the leader of a process group of its
  own, so ending it ends what stayed in that group; the runtime's own walk (`ps`, by parent) is what ends a program that
  left the group. A test with only same-group children cannot see the walk; `runtime_contract.swift` starts one child
  that leaves the group (`setpgrp`). And: an environment that already carries `AI_ILLUMINATI_PROJECT_PROCESS=1` (any
  test run from inside project work inherits it) makes Stop kill the group first, before the walk, and a program that
  left the group stays. That is the marker's rule since before R1 (project work's own `project_process.py` stops its
  writers); the contract takes the marker off for its own runs and checks the marker's group kill apart.
- Stop's result message races: `Cancelled` when the runtime sees the Stop first, the tool's own exit when the tool
  ends first. Callers already look at the token, not the message; the contract checks "a failure", not the text.
- Falsification (one change at a time in a copy; public interface from `-emit-module-interface`, the same hash
  `cae823709515` in every run). "User tests" = `run_mode2.sh` without `runtime_contract.swift`:

  | Change | Contract | User tests only |
  |---|---|---|
  | F1 Stop ignored while the tool runs (no `attach`, no check in the wait loops) | caught | missed |
  | F2 process group not killed at the end | caught | missed (`run_conditions` sees only the flag) |
  | F3 time limit not applied | caught | missed |
  | F4 TodoWrite sent after the message's text | caught | caught (StreamParser block) |
  | F5 session id not saved | caught | caught (session delta block) |
  | F6 a stopped session answer stays valid | caught | missed |
  | F7 Stop leaves a program that left the tool's group | caught (after the stray child was added; before: missed) | missed |
  | F8 the tool's error message dropped | caught | missed |
  | F9 a resumed session gets the whole context again | caught | caught (session delta block) |

  Six of nine are caught only by the module's own test: the app's tests reach the runtime through stand-ins
  (`replyForTests`, `launchForTests`, fake sessions) that skip the process. For a change in Stop, the time limit, the
  group, errors or session validity run `runtime_contract.swift` (it is in the full test). A user check through the
  app's own way in (e.g. `Discussion.requestDebate` with the fake CLI) for those six is the next gap to close.
- Parallel work: two AIs in two worktrees from one written contract (`NativeSessions.kept(_:)` in the module,
  `Discussion.keptSessions` in `Attachments.swift` with a check in `mode2.swift`). The contract named each side's files
  and every build or test list they are in (`build_modules.sh` takes `app/modules/AIRuntime/*.swift` itself, the
  runtime contract is in stage 2, `Attachments.swift` in stage 8, `mode2.swift` is the test's main), so nothing was
  missing at the merge: no conflict, the full test passed on the merged branch. Both sides still reported gaps for
  the next contract: it did not say who adds the new public name's reason here, what "unreadable" covers, which room
  the app uses between messages, or that the preview scripts also compile every app file (the app side alone does
  not build until the module side is in). The app side checked itself against a stub it did not commit; one of its
  two full runs crashed in `testAutoMeeting` (exit 139), outside the change, and passed when run again. Trial branch:
  `trial/runtime-parallel` (local, not merged; the contract is `docs/RUNTIME_PARALLEL_TRIAL.md` there).

## Workspace, step W0: the folder rules name nothing above them, before they become a module (2026-11-12)
No module yet (W1); nothing changed in what the tools are started with. `Workspace.swift` now names no ToolHub,
FaceLink, Projects or Chat code (grep for `ToolHub|FaceLink|ProjectProcess|ProjectWork|ProjectChat|GitLink|PlanLink|
Discussion|RunConditions` in it: 0). What moved, and where:
- The tool gateway is given, not called: `prepare(in:tools:)`, `arguments(…, tools:)` and `readRequests(…, tools:)` take
  a `WorkspaceTools` (`(WorkspaceInvocation) -> WorkspaceToolLink?`: socket, session key, the legacy face socket).
  Workspace still decides when a chat offers tools (`face`, project work, `origin == .side`) and asks only then; the
  app's answer is `ToolHub.workspaceLink` (ToolHub.swift: `active`, `register`, `FaceLink.active`, in the old order).
  The parameter has no default, like R0's `run`, so no call can forget it; the tests pass `ToolHub.workspaceLink` too.
- `RunConditions.app` moved whole to `RunConditionsApp.swift` (an app file, in run_mode2's list): Codex's face servers
  off (`FaceLink.codexOff`), agy's web rule (`GeminiLinks.rules`/`allowWeb`, moved with it), the `project_process.py`
  wrapper, the marker, the group and `AutoGuard.environment`. Workspace gives only what that needs: `arguments`,
  `readRequests`, `binding.projectRunID`, `binding.fullAccessActive`, `WorkspaceInvocation.resources`.
- Value types moved down into `Workspace.swift`, unchanged: `ProjectBinding` (from ProjectWork.swift; the same fields,
  so `workspace.project` and TODO lists save and read the same JSON) and `ToolOrigin` (from ToolHub.swift; the same raw
  values). Project work still makes them (`ProjectProcess.inspect`, `documents`); ToolHub still reads them.
- `Discussion.setWorkspaceLevel` and `undoWorkspace` moved to Attachments.swift (Chat side), unchanged.
- Stays in Workspace on purpose: `AutoGuard.claudeDenied` in Claude's full access arguments. AutoGuard is Workspace's
  by the plan and is not split; it still lives in ProjectWork.swift and moves whole in W1. `GeminiLinks.workspaceNote`
  (the folder rules' text for agy) and `MaterialReader`, `WorkspaceBackup` (Workspace's own) stay too.
- New names (internal; no `public` name was added, nothing is a module yet): `WorkspaceToolLink`, `WorkspaceTools`
  (how Workspace asks for the gateway without naming it; they become public with W1, the app gives the gateway),
  `ToolHub.workspaceLink` (the app's one answer, so every caller passes the same thing).
- Same start, byte for byte: `run_conditions.swift` passes with its golden file unchanged (Claude, Codex, Gemini, local ×
  plain, folder, folder with full access, project off/on, and ProjectChat's own run with full auto off/on), and the full
  test passes.

### Runtime through the app (`tools/tests/runtime_app.swift`, after `testRunConditions` in mode2)
R1 left six promises caught only by `runtime_contract.swift`. The new test goes through `Discussion.requestDebate`
(the app's `RunConditions.app` and folder rules) with a fake CLI as the AI's own tool (`Answerer.toolForTests`; it
reads what to do from a file, since the app makes its environment), for Claude and Codex in a linked folder: Stop
(at once; the tool, its child and a program in a group of its own are gone), the time limit (`timedOut`, all ended),
the tool's error text, and project work (`project_process.py`: its watchdog is there; the fake stops it, so the app's
group stop is the layer left, and the program left in the group must be gone). Sessions: a chat with its session room,
a stopped answer, then the next message must start a new session (`--session-id`, not `--resume`). The project marker
is taken off for the test (inherited inside project work, it would make Stop end the group first). About 7 s;
three runs in a row passed.

Falsification (one change at a time in a copy of the tree, the new test alone):

| Change | New test |
|---|---|
| F1 Stop ignored while the tool runs (no `attach`, no check in the wait loops) | caught ("Stop ends the answer at once") |
| F2 process group not killed at the end | caught ("project work's process group is stopped when the answer ends") |
| F3 time limit not applied | caught ("a slow tool times out") |
| F6 a stopped session answer stays valid | caught (the next message resumed the stopped session) |
| F7 Stop leaves a program that left the tool's group | caught ("… in a group of its own") |
| F8 the tool's error message dropped | caught ("a failed tool's message reaches the app") |

Found on the way: through the app, F2 hides behind a second layer. `project_process.py` forks a watchdog that kills the
group as soon as the tool exits, so with the runtime's own group kill gone the left program still died; a test that
does not take the watchdog away cannot see F2 (checked: F2 with the watchdog left in place passes the test). A session room the app does not know reads as an Enterprise-locked chat
(`lock(of:)`), so a test must use the chat's own room.

## What the fourth step showed (2026-11-12: AIWorkspace, W1)
- Before the move: W0 was on main (186f895) and its conditions held. The plan matched the code except in three places,
  changed within the rules (reviewed by ChatGPT before the change):
  - `MaterialReader` stays in the app. The plan counted "reading documents" as Workspace's, but `MaterialReader.read`
    makes the chat's `RoomDocument` in `ChatStore.dir` (attached files): chat data, so it goes with Chat (C0/C1).
    Workspace's own document reading is `readRequests` (the bridge and `WorkspaceDocument`), which moved. Workspace and
    its backups used `MaterialReader.error`; they now make the same NSError themselves (`WorkspaceError.make`: domain
    `Materials`, code 1, the same texts; nothing checks the domain).
  - Backup clean-up named two chat things: `ChatStore.dir` (is the chat gone?) and `ChatStorage.size` (bytes freed). The
    folder is now `WorkspaceBackup.chats` (`supportDir/chats`, the same path; mode2 checks it equals `ChatStore.dir`). A
    required parameter, as W0 did with `tools:`, was weighed and left: `finish()` starts the clean-up itself
    (`cleanUpSoon`), so every caller of `finish` would have needed it. The size walker moved down as `DiskUsage`
    (lines unchanged, `public` added), and `ChatStorage.Size`/`FileID`/`size(of:)` forward to it.
  - AutoGuard: the app calls `AutoGuard.environment` (RunConditionsApp, `ProjectProcess.run(guarded:)`), and `public`
    would be a changed line. The app now calls `FullAutoGuard.environment`, a one-line pass-through next to the folder
    rules; AutoGuard stays internal and whole.
- AutoGuard, file move only: `app/modules/AIWorkspace/AutoGuard.swift` is ProjectWork.swift's lines 667–798 at 186f895,
  byte for byte (sha1 `9108477d…` both), after two import lines (`Foundation`, `AIAccounts`: a file of its own needs
  them). `git diff -M --color-moved=plain` shows every other line of it as moved; the only non-moved lines in
  ProjectWork.swift are its import and the call `FullAutoGuard.environment`.
- Change size: `Workspace.swift`, `WorkspaceBackup.swift` moved (git sees renames, 77% and 87%), `AutoGuard.swift` and
  `Tools.swift` (`ToolContext`, `ToolProvider` from ToolHub.swift) cut out as they were, `DiskUsage.swift` new from
  ChatStorage. 98 `public` declarations (list above). 26 app files and 18 test files got `import AIWorkspace`; tests that
  need insides say `@testable` (mode2, project_work, google_drive, ask_ai, chat_search). Scripts: `run_mode2.sh` lost two
  files from its list, runs the workspace contract and three boundary checks (AutoGuard as a whole type); `build_app.sh`,
  `build_modules.sh` and the preview scripts needed nothing (they take `app/macos/*.swift` and every module).
- Finding the public names: everything internal, then a script compiled the app against the module and made public
  what the compiler named, as in R1, plus the module's own "must be declared public" and "type declared here" notes.
  Hand work: explicit public inits (memberwise ones are internal), `ProjectBinding`'s fields (a timed-out type check hid
  them), the protocol extension's default `tools(context:)`, `Policy.current` (a public default argument).
- Same start, byte for byte: `run_conditions.swift` passes with its golden file unchanged. One full test run stopped in
  `testRuntimeThroughApp` ("Stop ends the tool and what it started"): Stop comes 0.8 s after the start, and when the fake
  tool has not yet written its pids the check fails; the run right after passed whole, and so did the unchanged copy in
  the falsification below. Not caused by the move (nothing in the runtime or the start changed); a later fix could wait
  for the fake's pid file before pressing Stop.
- Falsification (one change at a time in a copy of the tree; only function bodies changed, so the public interface
  stayed the same). "App tests" = `run_mode2.sh` without `workspace_contract.swift`; an unchanged copy passed both:

  | Change | Contract | App tests |
  |---|---|---|
  | G1 `claudeDenied` without `Bash(gh repo delete:*)` | caught (the whole list) | caught (`run_conditions.golden`, `--disallowedTools`) |
  | G2 AutoGuard keeps `SSH_AUTH_SOCK` | caught | caught (`run_conditions` layer check) |
  | G3 the git shim lets `push` through | caught | caught (testFullAuto) |
  | W1 view gives Claude Bash | caught | caught (golden file) |
  | W2 the gateway asked for every chat | caught | caught (AI Face link: "plain chat only") |
  | B1 Undo leaves added files | caught (restore's own after-check refuses) | caught (backup tests) |
  | B2 clean-up looks for chats in `supportDir/chat` | missed (by design: the row says none) | caught ("backup clean-up looks for chats where the chats are saved") |
  | D1 a hard link counted each time | caught | caught (storage by chat) |

  The step's own criterion: G1 (one entry less in `claudeDenied`) fails both the module's test and the app's.

## What the fifth step showed (2026-11-12: AIProjects, P0 and P1)
- Before the move: W1 was on main (159e511) and the plan matched the code except in four places, changed within the rules:
  - `ProjectInfo.swift` (project-info.json, `ProjectRules`) moved too. The plan named "project link, Git, lock, approval, TODO",
    but `ProjectCreator` and `TodoAddLink` use `ProjectInfoStore`, and the file names nothing above Workspace; leaving it in
    the app would have needed one more injection for no boundary.
  - The crew pick stays with the chat side (`TodoChatsApp.swift`): it is `AutoPick` (plain chat's usage rule, Solo.swift)
    and `Enterprise.permits`; the scheduler asks `TodoChats.crew`/`noCrew`. Which TODO starts, and every state change after
    an answer, stay in Projects.
  - A TODO's photos: the scheduler picks them (not sent yet in that chat, at most 4) and hands `TodoPhoto` values; the chat
    side makes its `ChatImage` under the attachment's ID when it sends (and removes it when the send is refused), since
    `ChatImage`/`ImageStore` are chat types. Same files, same IDs, same order of refusal.
  - `GitBranches.swift`, `ProjectInfoView.swift`, `SidebarProjects.swift`, `ApprovalAlerts.swift`, `ProjectSnapshot` stay in
    the app (views, the sidebar, notifications, the review); they import the module.
- P0 (c37b11e, no module): the four files named no app type afterwards. `TodoScheduler(chats:)` + `TodoChats` (Discussion's
  conformance in `TodoChatsApp.swift`, `init(discussion:)` kept as an app extension so the tests read as before);
  `ProjectChatSummary` for `Conversation` in todo_add, create_project and the scheduler's locks (`ProjectChats.list`, set in
  `linkChatTools` and read through `ChatLink`, so the tests' fake chat lists still apply); `ProjectError.make` (the same NSError
  as `MaterialReader.error`) and `ProjectTools.failure` (the same reply as `ToolHub.failure`); `ProjectWork.revokeTools`, set by
  ToolHub's init (sessions exist only after it); `ProjectBinding.groupKey` (`SidebarProjects.key` forwards). From
  `runProjectSolo` two pieces of project logic moved down: `ProjectRun.endAttempt` (cancel + revoke, three places) and
  `ProjectWork.workBinding`. The full test passed with the golden file unchanged. Also fixed there: W1's flaky
  `testRuntimeThroughApp` check now presses Stop once the fake tool has written its pid files.
- P1: `git mv` of ProjectWork.swift, Todo.swift, ProjectInfo.swift; ProjectCreator.swift is ProjectCreate.swift's first 317
  lines (the `extension Discussion` part stays as `ProjectCreate.swift`). Besides `public`, explicit inits and imports, no
  line changed. 19 app files and 8 test files got `import AIProjects`; four tests say `@testable` (project_work, todo_work,
  project_info, chat_search). ToolHub's provider list (13, same order) is untouched.
- Finding the public names: the same loop as R1/W1, with two lessons. The driver stops after the first failing batch, so
  without `-continue-building-after-errors` most errors stay hidden; and an internal name inside a SwiftUI builder shows only
  as "unable to type-check this expression in reasonable time" (TodoBoard's row: `store.change`, `stop(after:)`, `setAfter`,
  …). Proof it was access: the same file compiled with `@testable import`; the fix was the names, not the view.
- New tests: `projects_contract.swift` (run_mode2 stage 2, with `AI_ILLUMINATI_TEST_RESOURCES` for `project_process.py`; a
  fake `TodoChats` records starts, the lock's releases and stops) and `testTodoOrder` (todo_work, after testTodoScheduler:
  through Discussion and the project chat's own lock; nothing calls `tick`). Three boundary checks: `TodoScheduler.retryDelay`,
  `ProjectWork.leasePrefix`, `TodoStore.encoder`.
- Falsification (one change at a time in a copy of the tree; only function bodies changed). "App tests" = `run_mode2.sh`
  without `projects_contract.swift`; the first test that failed is named:

  | Change | Contract | App tests |
  |---|---|---|
  | F1 a busy repository counts as an attempt | caught ("a busy repository does not count") | first missed (110 passes); after the busy answer was added to `testTodoOrder`: caught there |
  | F2 the scheduler ignores the repository lock (`held`) | caught (the retry started at once) | caught (testTodoStore "a folder a chat is writing is skipped") |
  | F3 `release` does not post `.projectReleased` | caught ("the release starts the retry first": nothing started) | caught (testTodoStore "releasing locks is announced") |
  | F4 the user is asked one retry early (`>=`) | caught ("after 2 retries the user decides") | caught (testTodoScheduler "an error is retried 2 times") |
  | F5 a new attempt keeps the earlier attempt's tool sessions | caught ("a new attempt ends the earlier attempt's tool sessions") | caught, indirectly (testDocumentsProject "the changes are listed with a backup"); testProjectHandoff's revocation check passed |

  F5 is the one to watch: the app's own revocation check did not see it, a later test did through its effects.
- For C0 (Chat): the `extension Discussion` blocks that call Projects and stay as shells: `ProjectChat.swift`
  (`approvalChatName`, `askAgain`, `allowProjectWork`, `configureProject`, `linkDocumentsProject`, `linkProjectFromSidebar`,
  `moveChat`, `runProjectSolo`, `projectFaceRule`, `toggleFullAuto`, the notes), `ProjectCreate.swift` (`linkProjectMaker`,
  `addProjectChat`, `newEmptyProject`, `disconnectProjectFolder`, `projectRoots`, `disconnectRefusal`, `disconnectFolder`,
  `newProjectFromMenu`), `TodoChatsApp.swift` (Discussion as `TodoChats`), `SidebarProjects.swift` (`openBoard`,
  `showBoardTab`), `ChatTools.swift` (`linkChatTools` sets `ProjectChats.list`; `Conversation.projectSummary`).
- Seen once: a full run stopped with exit 139 in `testAutoMeeting` (a crash, not a failed check); the run right after passed
  whole. R1 saw the same crash in the same test; nothing here touches meetings. The staged build (`build_app.sh --stage`)
  links and signs.

## Chat, step C0: the chat side names no other part's insides, before it becomes a module (2026-11-12)
No module yet (C1 makes `AIChat`). Before: P was on main (a9d353e). The plan held, with one count changed: the roadmap's
"19 files, 22 places" is now **20 files, 24 blocks** (P0/P1 added `TodoChatsApp.swift`, and `ProjectCreate.swift` is all
`extension Discussion` since `ProjectCreator.swift` moved).

### The `extension Discussion` table
(a) Chat takes the block whole (chat state, sending, the chat's own rules). (b) a shell: the logic that belongs to another
module is that module's public function now; the block keeps only the chat's part (its state, the dialog, which account).
`run_mode2.sh` stage 1 holds this table (file → kinds): a new block fails the test until it gets a row here.

| File:line | Kind | What it is | C0 change / note for C1 |
|---|---|---|---|
| Attachments:48 | a | pictures in the message box, `canSend`, `request`/`requestDebate` (the Enterprise gate before each send) | — |
| Attachments:209 | a | `setWorkspaceLevel` (session reset + the chat's binding) | — |
| Attachments:219 | a | `undoWorkspace`: the turn's Undo state; the restore itself is already `WorkspaceBackup` (AIWorkspace) | — |
| ChatFind:58 | a | find in a chat (jump, step, close) | `ChatFindBar` (a view) shares the file: C1 decides views |
| ChatSearch:150 | a | open a search result | — |
| ChatTools:154 | a | `linkChatTools`: sets `ProjectChats.list` (P0 injection) | — |
| Collaboration:65 | a | the collaboration run | — |
| Debate:45 | a | the debate run, speakers, search notes | — |
| DeviceSync:472 | a | chat state turn, `continueFromDevice`, `openRemote`, share toggle | reads another Mac's copy through `ChatStore.links.remote`; C1: the block leaves DeviceSync.swift, and `SyncSnapshot`/`RemoteChat` (they hold `ChatTurn`) need an owner |
| Enterprise:72 | a | a chat's lock, `permits` (the gate), `lockEnterprise` | DeviceSync hears through `ChatStore.links.locked`; the `Enterprise` rules enum and badges stay app-side for C1 to place |
| Enterprise:114 | b | locking a whole project | its TODO lists: `TodoStore.lockProject` (AIProjects); `SidebarProjects.key` → `groupKey` |
| Meeting:19 | b | meetings: members, brief, hidden chats | `prepareMeeting`'s folder view: `WorkspaceBinding.meeting(folder:)` (AIWorkspace) |
| Meeting:268 | a | `convene_meeting` (held meetings) | — |
| Peer:413 | b | ask_ai sessions, the review of changes | `peerView`/`sideView` → `WorkspaceBinding.consulted`/`.side` (they forward); `ProjectSnapshot` is Peer.swift's own |
| ProjectChat:132 | b | linking a project, moving a chat, `runProjectSolo`, full auto | stream plan → `ProjectRun.setPlan(todos:)` (no `PlanLink`); links → `ProjectWork.linking`/`moving`; the approval views share the file (app) |
| ProjectCreate:8 | b | the menus of new projects, disconnecting a folder | P1 moved the logic (`ProjectCreator`); C1: still uses `SidebarProjects.key` (forward of `groupKey`) |
| RoomDocuments:50 | a | attaching materials, restarting sessions | `RoomDocuments`/`MaterialReader` (reading documents) are not named by `ChatStore` any more (`links.documents`); C1 decides whether they join Chat or Workspace |
| Route:393 | a | route choice, rerun | `Route.opinionView` forwards to `WorkspaceBinding.opinion` |
| SidebarProjects:220 | a | `openBoard`/`showBoardTab`: the chat window's navigation state | C1: `BoardTab` is an app type |
| Solo:96 | a | plain chat (members, instruction, state, Spaces in answers) | C1: still names app types (`Pictures`, `FaceLink`, `SidebarProjects.key`, …) |
| Solo:1015 | a | a Space's lock and who may change it | — |
| SpaceView:39 | b | Space actions from a chat | the refine loop → `SpaceBuilder.refine` (AISpaces); stop and apply were Space-only, now `SpaceRefiner.stop`/`apply` (not Discussion); C1: `SpaceRefiner`, `SidebarFold`, `openBoard` are app names the shell still uses |
| TodoChatsApp:10 | a | `Discussion: TodoChats` (P0's seam: crew, start, end) | — |
| Vote:91 | a | the vote run | — |

So no block is left that would have to go to another module: 18 (a), 6 (b) shells. The app names the (a)/(b) blocks
still use (views' state types, `SidebarProjects`, `Pictures`, `FaceLink`, `SpaceRefiner`, `BoardTab`, `Enterprise`) are C1's
list: each becomes Chat's, moves down, or comes in by injection.

### Calls cut (Discussion and ChatStore name none of them; `run_mode2.sh` stage 1 searches every block and Discussion.swift)
- StreamParser → PlanLink: the chat hands `.todos` to `ProjectRun.setPlan(todos:generation:)`; Projects reads the shape.
- `ChatStore.save` → DeviceSync, `delete` → NativeSessions, WorkspaceBackup, RoomDocuments, DeviceSync; also
  `runFinished` → DeviceSync, `lockEnterprise` → DeviceSync, `openRemote` → `DeviceSync.load`: all through
  `ChatStore.links` (`purge` in order, `documents`, `saved`, `deleted`, `finished`, `locked`, `remote`), set once by the
  app in `ChatLinksApp.connect()` (main.swift, after `useRealHome()` and before `AppDelegate()`; stage 1 checks the place;
  mode2 calls it before its first Discussion). Unset, a program writes and removes only the chat's own files.
- Delete keeps its order and failures: sessions, backups, `<id>.work`, documents, `<id>.assets`, `<id>.json`, then
  `deleted`; the first failure throws and keeps that place and all after it (the chat stays listed, nothing is told);
  a chat's meetings go first and one that cannot keeps its chat.

| Promise | Users | Test |
|---|---|---|
| A deleted chat leaves none of its places, in the order above; a failure at any of the first four keeps it and what follows, the chat stays, no `deleted`; a second delete removes the rest; meetings first | Discussion (`removeChats`, delete menu, blank chats), Meeting (`removeMeetings`) | `chat_links.swift` `testChatLinks` (through `removeChats` with what main.swift connects; failures made by a read-only folder at each place), mode2 "storage by chat … delete covers the measured paths", "chat delete removes only its sessions …" |
| DeviceSync hears saves and deletes through the app's link | ChatStore | `testChatLinks` (a shared chat's copy appears, its delete takes it down) |
| The moved-down functions behave as the blocks did | the shells above | contracts: workspace ("consulted", "side", "opinion", "meeting"), projects ("linking", "moved", "the stream's task list", "a project with no list gets a locked one"), spaces ("a refused block goes back once", "no block", …); app: testPeerReview, testMoveChatToProject, testDocumentsProject, testEnterpriseMarks, testProjectHandoff |

### Falsification (one change at a time in a copy of the tree, only function bodies; "app tests" = run_mode2 without the module contracts)
| Change | Module contract | App tests (first failing check) |
|---|---|---|
| F1 `connect` purges backups before sessions | — (app wiring) | caught: testChatLinks "a failure at sessions keeps it and what comes after" (backups were already gone); mode2's storage test passed (it checks only that all go) |
| F2 `connect` gives no documents folder | — | caught: testChatLinks "the app connects … the documents' folder" (the fixture would also have left documents); mode2's storage test passed (its fixture has no documents) |
| F3 `delete` tells `deleted` also when it fails (`defer`) | — | caught: testChatLinks "deleted is told per chat, meeting first, once nothing is left" |
| F4 `connect` drops `saved` | — | caught: testChatLinks "a saved shared chat reaches DeviceSync" |
| F5 `consulted` keeps each folder's `writable` | caught ("consulted: every folder read only") | caught: mode2 chat members "the others get the folders read only, not just told so" |
| F6 `ProjectRun.setPlan(todos:)` reads nothing | (contract skipped for this run; its "the stream's task list becomes the plan" covers it) | caught: testProjectHandoff "TodoWrite shows as the project plan" |
| F7 `SpaceBuilder.refine` does not send a refused block back | caught ("the fixed block after a refusal is taken") | **missed** (all pass): no app test reaches a Space's change box; `SpaceView.swift` is not in the test build. C1 should add an app-path check when the shell moves |

### Results
- Full test passes, staged build (`build_app.sh --stage`) links and signs. Storage format unchanged (no key, no file moved).
- New: `ChatLinksApp.swift` (app; in the test list), `tools/tests/chat_links.swift` (`testChatLinks`, after
  testRuntimeThroughApp), contract checks for the moved-down functions, stage-1 checks (the table, no direct calls, where
  `connect` is called).
- For C1:
  - The shells still name app types (table above, right column). Each needs a decision before `AIChat` builds alone:
    becomes Chat's, moves down, or is injected like `ChatStore.links`. `SidebarProjects`' chat functions
    (`group`, `deletable`, `moveRefusal`, `runningFirst`) take `Conversation`: likely Chat's.
  - Views: `ChatWindow`, `ChatFindBar`, the approval views, Space views use Discussion's state. Opening that state wholesale is
    what the roadmap forbids; decide whether the chat views go with Chat or the app gets a narrow surface.
  - `ChatStore.links` must be set before the first `Discussion` (its init deletes old blank chats). Keep `connect` in main.swift
    and in mode2; a new program that deletes chats must connect too, or sessions and backups stay behind.
  - F7: Space refine is covered by the contract only; add an app-path check when SpaceView's shell moves.
  - `ChatStorage` (the storage tool) still names `NativeSessions.directory`, `RoomDocuments.directory`, `WorkspaceBackup.base` to
    measure; C0 left it (not Discussion or ChatStore). It goes with the Storage tool.
