# Modules: one Swift module per part, checked by promise → user → test

The app is one Swift program built from `app/macos/*.swift`: in it, every file can use every other file's
`internal` names, so a folder alone draws no line. A part in `app/modules/<Name>/` is its own Swift module:
it builds alone, and the app sees only its `public` names. Now: `AILocalization` (L(), AppLanguage), `AIAccounts`
(account list and folders), `AISpaces` (Spaces: saving, checks, the isolated web view) and `AIRuntime` (running each
AI's command line tool, sessions, the local model, usage readings), all 2026-11-11; `AIWorkspace` (the folder rules each
AI gets, the backup before writes and its Undo, AutoGuard, the tool gateway's types) and `AIProjects` (linked projects, Git
work, the repository lock, approvals, the TODO board and its scheduler, five tool providers), 2026-11-12; `AIChat` (the chat: its
records and store, Discussion with routing, meetings, reviews and ask_ai, five tool providers, the chat window; C1a/C1b), 2026-11-12;
`AIIntegrations` (the Google login and Drive gate, outside MCP servers, the AI Face link; no tool provider; step I), 2026-11-12.

## Final module map and dependency graph — App, step A (2026-11-12)

Status: C1 and I completed before A (3794afc, 2ceaf41). A completed: implementation a98ec3e; main's full suite and staged signed build passed. Trial behavior remains on local branches only.
The map below is the final ownership; older step reports below describe the code at that step.

| Stage | Implementation / contract follow-up commits |
|---|---|
| 1 AIAccounts | 94d3c85; promise/user checks 2fb027b |
| 2 AILocalization + AISpaces | 3ed052f |
| 3 Runtime R0 | 922eb6f, cdbec40 |
| 4 Runtime R1 | d3df383; contract follow-up 4c67045 |
| 5 Workspace W0 | 186f895 |
| 6 Workspace W1 | 159e511 |
| 7 Projects P0 / P1 | c37b11e, a9d353e |
| 8 Chat C0 | f05fd72 |
| 9 Chat C1a / C1b | b88d0a8, 3794afc |
| 10 Integrations I | 2ceaf41 |
| 11 App A | a98ec3e; final documentation follows |

Older hashes were confirmed read-only through the existing trial branch histories (the connected git_log returns ten
entries per call); those branches were not changed.


| Part | Owns | Direct module dependencies |
|---|---|---|
| AIAccounts | accounts, paths, save format, test-home isolation | none |
| AILocalization | L(), AppLanguage | none |
| AISpaces | Space storage, versions, checks, isolated WebView | AIAccounts, AILocalization |
| AIRuntime | CLI execution, Stop, sessions, streams, usage, local models | AIAccounts, AILocalization |
| AIWorkspace | folder permissions, documents bridge, backup/Undo, whole AutoGuard, tool types, disk sizes | AIAccounts, AILocalization, AIRuntime |
| AIProjects | Git work, repository locks, approvals, TODO storage/scheduling, project info/creation; Git/Plan/Task/TodoAdd/ProjectMaker providers | AIAccounts, AILocalization, AIRuntime, AIWorkspace |
| AIChat | chat records/state/storage, routing, meetings/reviews, ask_ai, attachments, DeviceSync, chat/Space views; Peer/Convene/Chat/Memory/Storage providers | AIAccounts, AILocalization, AIRuntime, AIWorkspace, AIProjects, AISpaces |
| AIIntegrations | Google auth/Drive gate, external MCP connections, AI Face; no providers | AIAccounts, AILocalization, AIRuntime (interface only), AIWorkspace |
| App (app/macos) | startup, menu/settings, screens, update/login, wiring and explicit 13-provider list; Face/Drive/ExternalMCP conformances | all eight modules |

Arrows mean imports, from caller to dependency (all direct edges are in the table):

```text
App            -> all eight modules
AIChat         -> AIProjects, AISpaces, AIWorkspace, AIRuntime, AIAccounts, AILocalization
AIProjects     -> AIWorkspace, AIRuntime, AIAccounts, AILocalization
AIIntegrations -> AIWorkspace, AIRuntime, AIAccounts, AILocalization
AIWorkspace    -> AIRuntime, AIAccounts, AILocalization
AIRuntime      -> AIAccounts, AILocalization
AISpaces       -> AIAccounts, AILocalization
AIAccounts     -> {}
AILocalization -> {}
```

No feature module imports AIIntegrations. Projects imports no Chat; Runtime imports no Workspace.
`tools/check_module_dependencies.py` compares each module's dependencies and real imports with this fixed direction
map before compilation. It rejects undeclared imports, forbidden declarations even if they would compile, unknown
modules, duplicate or unused declarations and cycles. Missing dependencies means an empty list. AIIntegrations'
AIRuntime declaration is the explicit public-interface-only exception. System framework imports are outside this map.
Nested comments and ordinary/raw/multiline strings are masked; this is not a full Swift parser (nested interpolation
quotes are a known limit). The independent compiler visibility checks remain in run_mode2. Tests may import module
internals; app code may not use @testable (the existing stage-1 check).

### App tool composition and exposure

App passes `{ ToolHub.appProviders }` into ToolHub. The closure reads the explicit list again so replacing
DriveLink.shared in an isolated test keeps working. The list is never dynamically registered or sorted:

1. FaceLink
2. DriveLink
3. GitLink
4. PlanLink
5. PeerLink
6. ConveneLink
7. ChatLink
8. MemoryLink
9. ProjectMakerLink
10. TaskLink
11. TodoAddLink
12. StorageLink
13. ExternalMCP

`shared` alone connects ProjectWork.revokeTools; a fixture hub cannot overwrite that hook.
The clock defaults to Date(); tests inject time without waiting two hours. `available(context:legacy:)` holds the
unchanged origin selection so its identities can be checked independently of providers' own permission gates.
Fixture hubs pass listenOnRegister: false and assert no socket file was created; the production default still listens.
These are app-internal seams: no new module or public symbol.

| Promise | Consumer | Check |
|---|---|---|
| The exact 13 singleton identities and order; current replaceable Drive singleton | ToolHub.shared | run_mode2 stage 1 exact source list; testToolHub identity and Drive replacement |
| Tool listing preserves provider order and duplicate names; call uses the first active provider that lists the name in that context | CLI bridge | testToolHub duplicate fixtures, inactive/context-hidden list and call; baseline + A1/A2/A3 mutants |
| member keeps the list; side has only Peer; consulted excludes Peer and Convene; legacy has only Face, before providers' own gates | workspace bridge, ask_ai, meetings, old Face bridge | testToolHub exact selected identities and side/legacy call refusals, A4 mutant; testAskAI, testMeetingTool, testChatThroughCLI |
| Unknown/expired sessions cannot list or call; project revocation removes only that project's sessions; unknown operations/names fail | all CLI calls, project turn end | testToolHub, injected-clock expiry, A5 mutant; testProjectHandoff |
| Slow names are limited to tools actually exposed | workspace_mcp.py | testExternalMCP (nonempty exposed fake-server slow names); an excluded-slow-name negative case is not covered |
| Each module follows its declared imports and allowed direction | every module/app build in run_mode2 | check_module_dependencies.py, DependencyRules temporary-tree falsifications, build_modules.sh visibility and cycle checks |
| No trial behavior survives in the app sources | main | validate_app_modules.py app-source SHA256 comparison, return to main after local trial snapshots |

### App code reviewed for later moves (list only; A moves none)

| Candidate | Possible owner | Boundary to preserve |
|---|---|---|
| Poker.swift: cards, hand evaluator, betting/pot settlement, records and engine | a dedicated Poker module | keep poker.json shape, hidden cards and AI calls; PokerWindow stays a screen |
| GitBranches.swift: parsing Git output, branch/version/distance report | AIProjects | inject Git runner; ProjectInfoView and its presentation stay App |
| DriveUI.swift: DriveTree rows/writable and tree request/cache bookkeeping | pure tree data in AIIntegrations; observable screen state stays App | preserve lazy expansion, cycle/depth bound, inherited write rules and login-version rejection |
| LocalModels.swift: LocalModelStore refresh/pull/cancel/delete state | AIRuntime behind a narrow view model | remove AppModel coupling first; opening NSWorkspace and the window stay App |
| Settings.swift: pure default-chat-rule migration and account/model choice transformations | split by AIChat/AIAccounts/AIRuntime ownership | preserve UserDefaults keys, per-instance test settings and the App's ChatSettings conformance |

Startup, ToolHub, ChatLinksApp/ChatScreensApp, RunConditions.app, settings/windows/menu, notifications, login and
updater remain App composition or platform work. Gemini allowWeb in RunConditionsApp still expresses App policy;
A does not relocate it or alter AutoGuard, permissions, signing, install or release files.

### Final falsification and parallel trial

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

## How a module is built and used
- `zsh tools/build_modules.sh <out> [swiftc options]` builds every `app/modules/<Name>/` alone into
  `<out>/<Name>.swiftmodule` + `<out>/lib<Name>.a` (static: nothing new in the app bundle, signing unchanged).
- A module may use only the modules named in its `dependencies` file (one per line; none: no file). They are built
  first, and the compiler sees only theirs, so an import of any other module fails the build. Now
  `AISpaces` → `AIAccounts`, `AILocalization`; `AIRuntime` → `AIAccounts`, `AILocalization`; `AIWorkspace` → `AIAccounts`,
  `AILocalization`, `AIRuntime`; `AIProjects` → `AIAccounts`, `AILocalization`, `AIRuntime`, `AIWorkspace`; `AIChat` → those five and `AISpaces` (Chat uses
  Projects, never the other way: Projects names no chat type since P0); `AIIntegrations` → `AIAccounts`, `AILocalization`,
  `AIRuntime` (only because `AIWorkspace`'s interface names it), `AIWorkspace` (`WorkspaceRoot`: Drive's folders), used by the app only; the other two use none. No circles (the script refuses them).
- Every `swiftc` that compiles app files runs it first and adds `-I <out> <out>/lib*.a`:
  `tools/build_app.sh` (compile step), `tools/tests/run_mode2.sh`, the preview scripts.
- Each file that uses a module says `import <Name>`. Not the hidden compiler option (`-Xfrontend -import-module`):
  the import line shows who uses the module (`grep -l "import AIAccounts"` lists its users), and no
  compile command needs one more flag.
- Name: `AI` + the part, never Apple's framework names (`Accounts` is one).
- `run_mode2.sh` stage "Modules on their own": builds the modules alone, runs each contract test from outside
  (`tools/tests/<part>_contract.swift`, public names only), and checks that internal names
  (`AccountStore.place`, `SpaceStore.setting`, `SpaceAssets.served`, `Answerer.chatDir`, `Answerer.launchForTests`,
  `NativeSessions.split`, `CloudModels.apply`, `WorkspaceBackup.chats`/`keepPerChat`, the whole `AutoGuard` type,
  `TodoScheduler.retryDelay`, `ProjectWork.leasePrefix`, `TodoStore.encoder`, `ChatTime.calendar`, `Discussion.maxRunning`, `Discussion.draft`, the whole `Peer` and `Route` types, `FaceLink.fallbackMoods`, `GoogleAuth.tokenURL`,
  `DriveLink.isAllowed`, `ExternalMCP.callTimeout`) do not compile outside.
- Tests build the modules with `-enable-testing` only so tests can say `@testable import`: `space_build.swift` for
  `AISpaces` (module insides such as `SpaceCheck`), and for `AIRuntime` the app tests that make their own usage
  readings (`AIUsage`, `UsageWindow` inits) or use its test hooks (`Answerer.launchForTests`/`replyForTests`,
  `StreamParser`): `mode2`, `run_conditions`, `project_work`, `ask_ai`, `collab_log`, `todo_work`, `chat_search`,
  `space_build`, and the settings preview (`render_settings.sh` builds the modules with `-enable-testing` for it).
  For `AIWorkspace` the app tests that reach its insides (`prepare`, `WorkspaceBackup.run`/`treatAsCloud`/`keepPerChat`,
  `AutoGuard.folder`/`claudeDenied`): `mode2`, `project_work`, `google_drive`, `ask_ai`, `chat_search`.
  For `AIProjects`: `project_work`, `todo_work`, `project_info`, `chat_search` (`RunProgress`, `RunTimings`, `TodoData.eligible`,
  `ProjectInfoStore` insides, `ProjectRun.plan`, …). For `AIIntegrations`: `mode2` (`FaceLink.server`, `RemoteMCPSession`, `MCPHTTP`,
  `MCPOAuth`, `MCPKeychain`/`MCPFileSecrets`) and `google_drive` (the Drive requests and the Keychain store's insides).
  Every app file and every contract test keeps a plain import and sees public names only; the app build
  (`build_app.sh`) has no `-enable-testing`.
- A `public` name in a module gets its reason in this file (the tables below). A new public name is a promise:
  add it to its row, or a row.

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
| `EnterpriseLock` (a stored value only; the rules stay in Enterprise.swift): here so `SpaceManifest` can keep it | Enterprise, Discussion, Solo, Todo, SpaceView, AISpaces | none | "an Enterprise Space is changed only by its organization", Enterprise lock |

### AILocalization (`app/modules/AILocalization/Language.swift`)
Only `L()` and `AppLanguage`: every part uses them, so they depend on nothing (no shared "Core" module).
Chat notices (`localizedNotice`) belong to the chat: `ChatWindow.swift`.
| Promise | Users (files) | Module test | User tests (mode2.swift unless named) |
|---|---|---|---|
| `L(ko, en)` gives Korean only when `AppLanguage.current == .korean` | nearly every app file (`grep -l "import AILocalization"`) | none (one line) | "macOS language, default rule localization …", render_chat (both languages) |
| `resolve`: the first Korean or English entry wins, else English; read once at launch | `AppLanguage.current` | none | "macOS language …" (resolve checks) |
| `current` can be set from outside (tests switch it and put it back) | mode2.swift, render_chat.swift | none | "macOS language …" |
| `locale`: ko_KR / en_US | Usage, ChatWindow, MenuCards, ProjectInfoView (dates) | none | "chat times …" (language given) |

Public: `AppLanguage` (`current`, `resolve`, `locale`, its cases) and `L`. That is the whole file.

### AISpaces (`app/modules/AISpaces/`: Space, SpaceLibrary, SpaceTemplates, SpaceWeb)
Depends on `AIAccounts` (`AccountStore.supportDir`: where `spaces/` is) and `AILocalization`. UI and chat callers are in AIChat since C1:
`SpaceView.swift` (sidebar, the Space window, `extension Discussion` for Space actions), `Solo.swift` (chat side:
`deliverSpaceBuild`, `drawSpacePictures`, `syncLibrary`, `spaceRule`), `Pictures.swift` (`extension SpacePictures`).
SpaceWeb stays in this module (WebKit is a system framework, linked by its import): the isolation needs the CSP
and page wrapper (`SpaceCheck`), the asset rules (`SpaceAssets.served`/`file`) and the data writes
(`SpaceStore.setState`) together; a module of its own would have to make those public, so any app file could load a
page around them. Here they stay internal and the app gets one way in: `SpaceWebView`.
| Promise | Users (files) | Module test | User tests |
|---|---|---|---|
| Save format: `manifest.json` pretty, sorted keys, absent fields left out; `state.json` one compact object with sorted keys, at most 10 MB; files 0600, folders 0700 | SpaceView (sidebar edits: `update`, `move`), Solo `syncLibrary`, the Spaces folder rule an AI gets (Solo `spaceRule`) | spaces_contract: save format, data limit, 0600 | testSpaceLibrary (`store.syncLibrary`: "… saved in the shared manifest format", "its files are private", "the bridge's own writes are not edits") |
| Reading an existing `spaces/` folder: missing keys keep defaults, odd values fall back, the id comes from the folder, data that is not one object reads `{}`, broken manifests and hidden folders are left out; the first sync of a build accepts all and rewrites nothing | SpaceView sidebar (`SpaceStore.shared.spaces`), Solo (`SpaceLibrary.all`, folder rule), Route (`named`) | spaces_contract: old folder | testSpaceLibrary ("a copied folder is its own Space": `Discussion.spaceRule`; folders added, set aside), space_web ("a Space with odd data …" through `SpaceFolderHost`), testSpace (Route) |
| Versions and Undo: `versions/<n>/` keeps code, data, info, look; Undo brings code and look back, data only after a migrate; newest 30 stay; restore is a new change | SpaceView (`apply`, `undo`, `restore`), Solo `syncLibrary` (direct edits) | spaces_contract: undo of an old version; space_build | testSpaceLibrary ("Undo of a direct edit", "a data edit is a version") |
| Old per-chat `space.json` becomes template Spaces once (`migrateLegacy`), renamed `.migrated`; a failing file stays | main.swift (launch) | space_build (testSpace) | none (main.swift is not in tests) |
| Checks before saving: `<space-build>` split and parse, refused code (`SpaceCheck`), limits (300 KB code, 10 MB data, 1 GB with files, 40-letter name, migrate 20 KB); a refused change writes nothing | Solo `deliverSpaceBuild`, Discussion `extractState`, SpaceView refiner (`apply`) | space_build | space_build (`Discussion.extractState`), testSpaceLibrary (page put back), mode2 "a chat's Space pictures …" |
| Isolation: CSP before the page, content rules block http(s)/ws/file/ftp/blob, nothing kept (`nonPersistent`), no navigation after the first load, no pop-ups or panels, bridge only from the main frame, pictures only `space-asset://local/<name>` of its folder, migrate in a page of its own (5 s, no bridge) | SpaceView through `SpaceWebView` and `SpaceMigrator.run` | — | space_web (through `SpaceWebView`, public names only; also what a page cannot see: the data store is not persistent, the policy text, a navigation the content rules allow, a hidden picture file) |
| Errors: `SpaceBad(reason)` in the user's language; the reason names what was refused | Solo (draft notes), SpaceView (refiner notes) | space_build ("the reason names …"), spaces_contract (refused write) | testSpace (draft notes) |
| Threads: `SpaceStore` list and changes on the main thread (`dispatchPrecondition`), its static file helpers anywhere; `SpaceLibrary` stamps under a lock, `beginAnswer`/`endAnswer` count writers so a sync waits | Solo (answer threads: `beginAnswer`, `named`, `all`), SpaceView (main) | none | none (a wrong thread stops the app at the precondition) |
| What an AI is told (rules, the change prompt, the folder rule, picture rules) | Solo `spaceRule`, SpaceView refiner | space_build (rule contents) | testSpace ("other messages get no Space rule", folder rule) |
| Pictures: hidden as `space-kept:N` for AIs, put back, requests in order, files in `assets/` | Solo `drawSpacePictures`, Pictures.swift | space_build | mode2 "a chat's Space pictures are drawn by ChatGPT …" |
| Export: one HTML file under 50 MB, else a folder | SpaceView export | none | testSpaceLibrary (export) |
| Schedule (days, hours, overnight) and the sidebar's `shown(at:)` | SpaceView sidebar | space_build | none |

Public names and why (everything else stays internal: `SpaceCheck`, `SpaceRules`, `SpaceBridge`, `SpaceAssetServer`,
`SpacePage`, the migrate page, `SpaceStore.write`/`encode`/`setting`/`setState`/`make`/`shape`, `SpaceLibrary.settle`):
- Stored types the app keeps in chats or shows: `SpaceManifest` (its fields except `template`/`updatedAt`; `createdAt`
  for the contract test's old-date check; `colors`; `shown(at:)`; `init(from:)` because Decodable asks for it),
  `SpaceSchedule` (`days`, `from`, `to`, `parse`), `SpaceDraftNote` and `SpaceSyncNote` (fields and init: `ChatTurn`
  saves them), `SpaceVersion` (history menu), `SpaceRefineEntry` (refine log).
- `SpaceManifest.lock` (an `EnterpriseLock` from `AIAccounts`, 2026-11-11): the Enterprise lock of the chat that made
  the Space, kept after that chat is deleted; SpaceView picks only accounts it permits. An edit of the files keeps it.
- Results the chat side handles: `SpaceBuild` (name, icon, color, html, migrate), `SpaceBad` (`reason`, init: Solo
  makes one for a missing picture), `SpaceLimits` (SpaceView cuts names; one declaration, so all its numbers).
- `SpaceStore`: `shared`, `spaces`, `stateVersion` (SwiftUI watches them), `root`/`folder`/`draftFolder`
  (folder rule, Codex write roots, export), `manifest(at:)`, `manifest(_:)`, `html`, `state`, `reload`, the changes
  the UI makes (`adopt`, `makeFromTemplate`, `apply`, `undo`, `restore`, `update`, `move`, `delete`, `dataChanged`),
  drafts (`saveDraft`, `draftBuild`, `discardDraft`, `pruneDrafts`), `versions`, `refineLog`, `addRefine`, `named`,
  `migrateLegacy`.
- Chat side: `SpaceBuilder` (`split`, `parse`, `rule`, `chatRule`, `refinePrompt`, `refine`: the change loop of a Space's
  box, a refused block back once with its reason; C0 moved it down from SpaceView's `extension Discussion`, which now picks
  the account and sends), `SpacePictures` (`perAnswer`,
  `hide`, `embed`, `Request`, `requests`, `referenceFile`, `chatRule`), `SpaceLibrary` (`beginAnswer`, `endAnswer`,
  `busy`, `all`, `sync`, `rule`, `pictureBlockRule`), `SpaceAssets.dataURL` (a redraw's source picture),
  `SpacePatch.meetingState` (a meeting into a decision log), `SpaceExport` (`fitsOneFile`, `folder`, `document`),
  `SpaceTemplate` (its cases and `name`: the "new Space" menu).
- The page: `SpaceStateHost`, `SpaceFolderHost`, `SpaceMemoryHost` (where its data lives), `SpaceActions` (what it may
  ask), `SpaceWebView` (with what `NSViewRepresentable` asks: `makeNSView`, `updateNSView`, `dismantleNSView`,
  `makeCoordinator`, `Coordinator`), `SpaceMigrator.run` (an enum: the page behind it and its WebKit delegate methods
  stay inside).

### AIRuntime (`app/modules/AIRuntime/`: Answerer, Cancellation, NativeSessions, Local, Usage, CloudModels)
Runs one AI's command line tool for one prompt and hands back its answer; keeps its sessions; runs the local model
(Ollama); reads usage. Depends on `AIAccounts` (accounts, their environment and folders, `AccountStore.home`) and
`AILocalization`; it cannot import Workspace, Projects, Chat, Face or ToolHub (they are app files, not modules), and it
decides no permission: what to start with comes in a `RunConditions` the caller built (`RunConditions.app` in
`RunConditionsApp.swift`, since W0). Chat-side callers are now AIChat's: `extension Discussion` (`requestDebate` …),
`GeminiLinks.workspaceNote` (names `WorkspaceLevel`, an `extension GeminiLinks` in `Workspace.swift`),
`LocalModel.install` (opens Terminal: an `extension LocalModel` in `Login.swift`), `LocalModelStore`/the Ollama window
(`LocalModels.swift`), `Login` (its `home`/`agyInstalled` now read `ToolHome`), `ChatTurn.Entry.reply` (uses
`ReplyHeadline.split`, which a session needs too).

| Promise | Users (files) | Module test (`runtime_contract.swift`) | User tests |
|---|---|---|---|
| Starts exactly what `RunConditions` says (prefix, wrapper first, environment, folders) | every `Answerer.ask` caller through `RunConditions.app` | fake CLI: arguments and folder seen by the tool | `run_conditions.swift` (golden file, each guard alone), `runtime_app.swift` (the same through the app with a fake CLI) |
| Errors: a tool that cannot start → `missingTool`; a failed exit → `failed(<model note> + last 300 letters of stderr)`; no answer in time → `timedOut`; a picked model the account lacks names the model | Solo, Meeting, Debate, Vote, Peer, ProjectChat, Enterprise (`Answerer.Failure`) | "a failed tool's message is passed on", "missingTool", "a slow tool times out" | mode2 error and fallback checks (debate, plain chat limit handoff), `runtime_app.swift` ("a failed tool's message reaches the app", "a slow tool times out", Claude and Codex) |
| Stop: a stopped token starts nothing; Stop while it runs fails the answer at once (`Cancelled`, or the tool's own exit when the tool ends first: callers look at the token) and ends the tool, its group and every descendant found by parent; with `AI_ILLUMINATI_PROJECT_PROCESS=1` the whole group is killed first | Debate, Solo, ProjectChat, Meeting, Todo (tokens); project work (marker) | "a stopped token starts no tool", "Stop ends … at once", "… the programs it started", "… in a group of its own", "Stop ends a marked tool's whole group" | mode2 "actual process cancellation", testProjectWork "Stop kills foreground and background project writers", `runtime_app.swift` ("Stop ends the answer at once", "… what it started", "… in a group of its own", through `requestDebate`) |
| Time limit: at `timeout` the tool and its descendants are ended | same | "a slow tool times out", "a timed-out tool and its children are ended" | `runtime_app.swift` ("the time limit is kept", "a timed-out tool and its programs are ended") |
| Left processes: with `processGroup` the tool's whole group is killed when the call ends, even after a good answer; without it nothing else is stopped | `RunConditions.app` (project work) | "the process group is stopped when the call ends", "without a process group nothing else is stopped" | `run_conditions.swift` (group flag per kind), `runtime_app.swift` (project work: the watchdog is there, and with it gone the group is still stopped) |
| Threads: `ask` blocks its caller (never call it on the main thread from UI); progress comes on a background thread; `DebateCancellation` and `NativeSessions` are locked, any thread | all callers (they hop to the main thread themselves) | "progress comes on a background thread" | none (a main-thread call freezes the app) |
| Stream events in order: Claude text within one message (a new message starts over; at most ~12 a second, the last text of each message always sent), each tool start as `activity`, each TodoWrite list as it came (`todos(Any?)`, not filtered), where it came; Codex: command/tool/search starts, each finished message | Solo (text, activity), ProjectChat (all three) | Claude and Codex orders | mode2 StreamParser block, `testProjectHandoff` |
| Sessions: a new session starts with its own id (`--session-id` / Codex `thread.started`); the next call resumes it (`--resume <id>`, `exec resume <id>`) with only what is new; a stopped or failed answer marks it for a rebuild and is not retried (only "session not found" is, once, with the full context); compaction rebuilds | Attachments, Collaboration, ProjectChat (`nativeSessions.ask`) | session block (new, resumed, stopped, Codex resume) | mode2 "session delta, image reuse, role separation, compaction bootstrap …", `runtime_app.swift` ("after a stopped answer the next message starts a new session") |
| Session save format: `rooms/<room>/ownership.json`, 0600, a JSON array of records `id`, `accountID`, `provider`, `role`, `nativeID`, `context`, `ownBlock` (`[<speaker>]\n<reply without its TL;DR line>` for speakers), `images`, `valid`; older files are read as they are; archive and purge keep or remove only what a room recorded | Attachments, Collaboration, ProjectChat, Discussion (delete, archive) | "ownership.json keeps its fields", "an older ownership.json is read", "is private" | mode2 "chat delete removes only its sessions …" |
| Local model: no command line tool, one answer at a time (`gate`), keep-alive and unload | Local chat, Route sorter, Settings, LocalModels window, main (menu) | none (needs Ollama: a fake server in mode2) | mode2 "Ollama on this Mac", "Gemma on this Mac", `run_conditions.swift` ("the local model starts no command line tool") |
| Usage readings and cloud model picks (stored per account in `UserDefaults.app`) | main, MenuCards, Settings, Solo, Meeting, Peer (auto pick by usage) | none | mode2 "menu bar …", "plain chat (auto pick 15% …)", testCloudModels |

Public names and why (everything else stays internal: `Answerer.chatDir`/`askOnce`/`launchForTests`/`replyForTests`,
`StreamParser`, `NativeSessions.split`/`load`/`save`, `CloudModels.apply`/`noteSeen`, `ClaudeUsage.binary`, the HTTP
streams `LocalStream`/`PullStream`, `LocalModel.ask` and the Ollama requests):
- `Answerer.ask`, `Answerer.Failure`, `AnswerProgress`: the one way in, its result and its progress (every caller).
- `RunConditions` (all six fields, `init()`) and `RunConditions.Folders` (an explicit `init`): the app builds them
  (`RunConditionsApp.swift`); the fields are what the caller decides.
- `Answerer.toolForTests`: the only public test hook, so `runtime_contract.swift` can run a fake CLI from outside; the
  app never sets it (run_mode2 stage 1 checks that no app file names it).
- `DebateCancellation` (`init`, `isCancelled`, `child`, `attach`, `detach`, `cancel`, `end`): the app makes the tokens
  and stops its own processes the same way (project commands in ProjectWork, document reading in MaterialReader and
  Workspace, the updater).
- `NativeSessionCall` (the type only: `ask` hands one to the caller's closure, which passes it back), `NativeSessions`
  (`init`, `ask`, `directory`, `eligible`, `pinnedAccount`, `reset`, `purgeRoom`).
- `ReplyHeadline.split`: the chat's headline and the session's own block must cut a reply the same way.
- `ToolHome` (`path`, `agyInstalled`): where the tools live (the user's home, not the test home); `Login` and Settings.
- `GeminiLinks` and `toolNote` (what agy is told in plain chat): `Workspace.swift` adds the workspace note and
  `RunConditionsApp.swift` agy's web rule (`allowWeb`, it writes agy's settings) to the same type; `RunConditions.beforeStart` is how the app runs that
  rule just before the tool starts, so the runtime changes no permission itself (review, 2026-11-11).
- `CloudModels` (`model`, `set`, `valid`, `Choice`, `claudeChoices`, `codexChoices`, `loadGemini`, `seenKey`, `seenTitle`):
  the Settings model menus.
- `LocalModel` (63 names: variants, the catalog and its entries, fit by memory, Ollama's library, installed/loaded
  models, pull, delete, keep-alive, the gate, `server` for mode2's fake server) and `LocalUsage.read`: the Settings
  Ollama section, the Ollama window, the menu and the Route sorter use all of them. It is the largest public part:
  model management came with the file (`Local.swift`); splitting it from running is a later step.
- `AIUsage`, `UsageWindow` (fields, `left`, `leftNow`; no public inits: only the module makes readings),
  `CodexUsage`/`ClaudeUsage`/`GeminiUsage` (`read`, `forget`; `CodexUsage.binary` for the Codex login): the menu.

### AIWorkspace (`app/modules/AIWorkspace/`: Workspace, WorkspaceBackup, AutoGuard, Tools, DiskUsage)
What an AI may do in a chat's linked folders and how its writes can be undone. Depends on `AIAccounts` (where the data
lives, `Account`), `AILocalization` (level titles) and `AIRuntime` (`DebateCancellation` for reads, `NativeSessions.directory`
for the document cache, `GeminiLinks` for agy's note). It names nothing above it: the app hands it the tool gateway
(`WorkspaceTools`, W0) and runs the tools itself (`RunConditions.app` in `RunConditionsApp.swift`).
Other owners since C1/I: MaterialReader and Discussion's workspace actions are AIChat's; ProjectProcess and project work
are AIProjects'; ToolHub and the Settings backup UI stay App. Providers live with Chat/Projects or the three App conformances.

| Promise | Users (files) | Module test (`workspace_contract.swift`) | User tests |
|---|---|---|---|
| Folder rules per CLI and level: view reads only (Claude `Read,Grep,Glob`, `dontAsk`, `--restricted`; Codex `read-only`, no shell, no web), only the chat's own folder editable in view, write/execute after a backup, execute in the sandbox writing only in the linked folders, a project's Git data denied | RunConditionsApp (`arguments`), every caller of `Answerer.ask` with a workspace | "view: Claude reads only", "Codex read only", "only the chat's own folder", "writing without a backup is refused", "execute: …", "the project's Git data is denied" | `run_conditions.swift` (golden file, every kind), mode2 "explicit resume sandbox, linked write roots …", testProjectWork |
| Full access (project work full auto, or `fullAccess`): every tool, no prompts, no sandbox, and AutoGuard's denied Claude commands, the whole list in order | RunConditionsApp | "full access denies exactly AutoGuard's commands" (the list written out), "Codex full access" | `run_conditions.swift` (golden file: `--disallowedTools`), testFullAuto (`claudeDenied` has `/usr/bin/security`) |
| AutoGuard's environment: its `git`/`rm`/`security` shims first on PATH (0700), no credential helper, prompt, SSH key, SSH agent or GitHub token, an empty GitHub CLI login | RunConditionsApp (full access), ProjectWork `ProjectProcess.run(guarded:)` (`FullAutoGuard.environment`) | environment checks, "the git shim refuses …", "the security shim refuses …", rm keeps temporary-file and `-f` semantics | testFullAuto (shims through bash, Keychain items), `run_conditions.swift` (layer check: full access has it, others not) |
| The bridge's manifest: 0600, folders and level, the backup; the app's gateway is asked only when the chat offers tools (AI Face, project work, a side AI) and named only when it answers | RunConditionsApp, ToolHub `workspaceLink` | "the manifest is private", "the gateway is not asked …", "a chat with tools gets the gateway", "a side AI …", "no gateway running …" | `run_conditions.swift` (manifests in the golden file), mode2 AI Face link, testAskAI |
| Backup before writes: refuses overlapping folders or one holding the backups; lists what the answer added, changed, deleted; Undo puts back exactly that, once, and refuses (writing nothing) after a later change; a deleted chat's backups go | Solo, ProjectChat, Collaboration (`begin`, `finish`), Attachments (`restore`), Discussion (`purgeRoom`), Peer, ProjectWork (`stamps`) | "the backup lists what changed", "Undo puts back …", "an Undo runs once", "a refused Undo writes nothing", "nested folders …", "a deleted chat's backups go" | mode2 "backup, actual add/edit/delete list, conflict refusal and exact hash undo", "backup by size and time, cloud-only …", "chat delete removes only its sessions, … backups and git marker" |
| Clean-up of old backups (age, count, restored, a deleted chat's after a day, in use and newest kept); it tells a deleted chat by `supportDir/chats`, the app's `ChatStore.dir` | Settings (`cleanUp`, `Policy`), main (`startAutomaticCleanUp`), every `finish` | none (needs aged folders) | mode2 "backups keep changed files only, … cleanup by age/count/restored/deleted chat …" (and `WorkspaceBackup.chats == ChatStore.dir`) |
| Save format: a chat's `workspace` (`WorkspaceBinding`, `WorkspaceRoot`, `ProjectBinding`, levels, `ToolOrigin`) and a backup's `complete.json` keep their keys; absent fields left out; older ones read | Discussion (chats/*.json), Todo (lists), ProjectWork, every `load` | "a chat's workspace keeps its saved keys" (golden), "an older workspace reads", "an older backup reads", "complete.json is private" | mode2 "legacy decoding", testTodoStore (saved and read back) |
| Errors: an NSError (domain `Materials`, code 1, the same texts) the callers show as they are | Solo, ProjectChat, Attachments (notes) | "the refusal names the backup" | mode2 conflict refusal |
| Disk sizes: lstat blocks, links not followed, a hard link once across calls with one `seen` | ChatStorage (`report`), clean-up (`bytes`) | "a hard link counts once", "… not counted again across calls", "a missing path counts as unreadable" | mode2 "storage by chat, …, hard links once" |
| Tool gateway's types: `ToolProvider.tools(context:)` defaults to `tools()`; `ToolContext` carries the room, roots, run, asker, turn, origin | ToolHub and the 13 providers (app files) | none (types) | mode2 tool tests (ask_ai, meetings, chat tools, memory, Drive, outside MCP) |

Public names and why (everything else stays internal: `AutoGuard` whole, `WorkspaceError`, `WorkspaceInvocation.prepare`/
`readOnly`/`backupPath`/`executionFolders`, `WorkspaceBackup.run`/`survey`/`copyTree`/`trim`/`protect`/`chats`/`keepPerChat`/
`prune`/`cleanUpSoon`, `Stamp.digest`):
- Stored values the chat and project work keep (save format above): `WorkspaceBinding` (its fields, `isFullAuto`,
  `fullAccessActive`, `inventory`, `description`: the folder list the AI is told), `WorkspaceRoot`, `ProjectBinding` (fields,
  `isFolderless`, `isDocuments`, `linkedRoots`, `documentsKind`, `protectedPaths`), `WorkspaceLevel` (`offered`, `title`: the
  level menu), `ToolOrigin`, `WorkspaceChange` (shown under an answer). Explicit public inits where Swift's memberwise ones
  are internal (all of these, `WorkspaceInvocation`, `ToolContext`, `WorkspaceToolLink`, `Policy`, `DiskUsage.Size`).
- `WorkspaceInvocation` (`binding`, `room`, `account`, `resources`, `arguments`, `readRequests`; `readOnly`, `backupPath` and
  `level` only through the init): the
  app builds one per answer and turns it into the tool's start (`RunConditions.app`).
- `WorkspaceTools`, `WorkspaceToolLink` (init only): how the app gives its gateway (W0).
- `WorkspaceBackup` (`begin`, `finish`, `restore`, `load`, `purgeRoom`, `stamps`, `digest`, `base`, `directory`, `roots`,
  `before`, `changes`, `cloud`, `Stamp.kind`, `cleanUp`, `Policy` (`days`, `perChat`, `standard`, `current`),
  `CleanUpResult` (`removed`, `trimmed`, `bytes`), `startAutomaticCleanUp`; `after`, `restored`, `trimmed` stay inside): the answer's
  backup and Undo (Solo, ProjectChat, Collaboration, Attachments), project review (`stamps`), the Settings backup section.
- `FullAutoGuard.environment`: the app's one way to AutoGuard. AutoGuard moves as it was (not one line changed, so not even
  `public`), and is not split: its shims, the credential removal and `claudeDenied` stay together inside, and
  `claudeDenied` is used only by `arguments` here.
- `ToolProvider`, `ToolContext`: the gateway's types, here so later modules (Projects, Chat) can offer tools without
  naming the app; `ToolHub` itself (the socket, the provider list and its order) stays in the app.
- `WorkspaceBinding.consulted`, `.side`, `opinion(chatFolder:)`, `meeting(folder:)` (C0): what another AI of a chat may
  see of an answer's folders (ask_ai and the review, a side answer, an opinion, a meeting's members). Folder rules, so they
  live here; they were `Discussion.peerView`/`sideView`, `Route.opinionView` and part of `prepareMeeting` (those forward).
- `DiskUsage` (`of`, `Size` and its fields and `+`, `FileID`): clean-up counts what it frees and ChatStorage each chat's
  parts; it was `ChatStorage.size`, a chat file, which Workspace may not name (`ChatStorage.Size`/`FileID`/`size(of:)` now
  forward to it).

### AIProjects (`app/modules/AIProjects/`: ProjectWork, Todo, ProjectInfo, ProjectCreator)
A chat's linked project and what an AI may do in it: Git commands with fixed arguments (`ProjectProcess`), the repository
lock across chats and app instances (`ProjectWork.acquire`/`release`), the approval cards (`ProjectCenter`), a project turn's
capabilities (`ProjectRun`: generations, deadlines, checkpoint, plan), the TODO board (`TodoStore`, todos.json) and its
scheduler (`TodoScheduler`), project info (project-info.json, `ProjectRules`), new projects (`ProjectCreator`), and five tool
providers: `GitLink`, `PlanLink`, `TaskLink`, `TodoAddLink`, `ProjectMakerLink`. Depends on `AIAccounts`, `AILocalization`,
`AIRuntime` (`DebateCancellation`) and `AIWorkspace` (`ProjectBinding`, `WorkspaceBinding`, `WorkspaceBackup.stamps`,
`FullAutoGuard`, `ToolProvider`/`ToolContext`). It names no chat type (P0): the scheduler works through `TodoChats`, the
tools read chats as `ProjectChatSummary` values (`ProjectChats.list`), and ToolHub hands in how a run's tool sessions end
(`ProjectWork.revokeTools`). It decides commits, pushes and every TODO state change (retry, needs the user, review, the next
start, the lock's release); the chat side makes the chat, picks the crew by usage and lock, sends, and says how it ended.
Chat-side files are AIChat's since C1: `ProjectChat.swift` (approval views; `extension Discussion` with `runProjectSolo`, linking, moving a chat),
`ProjectCreate.swift` (`extension Discussion`: `addProjectChat`, disconnecting a folder, the menus), `TodoChatsApp.swift`
(Discussion as `TodoChats`, the crew by `AutoPick`/`Enterprise.permits`, `TodoScheduler.noCrew`, the photo import),
`SidebarProjects.swift` and `ProjectSnapshot` (Peer.swift, the review). App keeps `TodoBoard.swift`, `ProjectInfoView.swift`,
`GitBranches.swift`, `ApprovalAlerts.swift`, `ToolHub` with the 13 providers in their order.

| Promise | Users (files) | Module test (`projects_contract.swift`) | User tests |
|---|---|---|---|
| TODO order: an error is counted and noted and the TODO is ready again, retried in the same chat before a TODO after it; a busy repository (`isBusy`) is not counted; after `maxAttempts` retries the user decides and what waits for it does not start; a report becomes the check only when the chat ended; the next TODO starts only once the repository lock is let go, woken by `.projectReleased` (no tick) | TodoChatsApp (Discussion), main (start, quit), TodoBoard | "an error is counted and noted", "nothing starts while the repository is held", "the release starts the retry first", "a busy repository does not count", "after 2 retries the user decides", "B waits while A needs the user", "the lock's release starts the next TODO" | todo_work `testTodoOrder` (through Discussion: A, its retry, then B, each start after a release, no tick), `testTodoScheduler` (retries, no report, report final at the end, busy chat waits) |
| Scheduler limits: drafts wait for Start; one answering place stays free; a TODO's own chat; Stop cancels and stops the chat; after a quit running TODOs are ready, interrupted, one attempt counted | main, TodoBoard | "drafts wait for Start", "one of the places stays free", "Stop cancels a running TODO", "restart" | `testTodoScheduler`, `testTodoTime`, `testTodoPause` |
| Save format: todos.json pretty with sorted keys, older files read, an unreadable or newer file held and never written over; project-info.json the same | TodoBoard, Todo tools, ProjectInfoView, Solo (rules) | "todos.json keeps its shape", "reads back", "an unreadable todos.json is held" | `testTodoStore` (held unreadable files, older files, failed save), `testProjectInfo` |
| Repository lock: one writer per Git repository (common folder) and per documents folder, across app instances (lock files), shared locks above; refusals say `busyKorean`/`busyEnglish` | Discussion (every writing answer), TodoChatsApp | "a second writer is refused", "released" | `testProjectWork` (repo locks), `testDocumentsProject` (one writer per folder), `testTodoScheduler` (folder lock) |
| Scoped tools: `work_plan`, `task_done`/`task_ask`, Git tools only for the live attempt of the run's own chat; a new attempt or the run's end ends the earlier tool sessions (`revokeTools`); documents projects get `project_run` only | ToolHub (13 providers, order unchanged), ProjectChat | "the live attempt gets its tools", "an earlier attempt, another chat and the global list get none", "a new attempt ends the earlier attempt's tool sessions", "a finished run is gone" | `testProjectWork` (scoped tools), `testProjectHandoff` (old-token revocation), `testTodoScheduler` ("task tools only in the TODO's own chat") |
| Git work: fixed argv, no hooks, explicit commit paths, push only main/feature/fix/codex, stable only through the card with the exact SHA, `project_run` only registered commands, approved commands checked unchanged, AutoGuard's environment in full auto | ProjectChat (`runProjectSolo`) | none (needs a repository with a remote: app tests) | `testProjectWork`, `testFullAuto`, `testWorkTiming` |
| The work binding: execute, writable only in the project's root and the chat's folder | ProjectChat | "work binding" | `run_conditions.swift` (ProjectChat's own run in the golden file) |
| Approvals: one list for every place, a decision clears them all, 15 minutes unanswered is no and leaves a note | ProjectChat views, ApprovalAlerts, ExternalMCP, ProjectCreator | none | `testProjectWork` (expired, twice), render_chat |
| New projects: card first, folder + first commit + GitHub + push, asking again continues the same plan; folderless and documents kinds | ProjectCreate (menus), ProjectMakerLink | none (needs a fake gh) | `testProjectCreate`, `testDocumentsProject` |

Public names and why (everything else stays internal: `ProjectError`, `ProjectTools`, the lock tables and files, `RunProgress`,
`RunTimings`, `TodoStore.encoder`/`decoder`/`copyIn`, `TodoData.eligible`/`hasCycle`, `TodoScheduler.begin`/`settle`/
`deliver`/`retryDelay`/`chats`, the tools' schemas and scopes):
- Saved values the board, the chats and the tools show (the save format above): `TodoItem` (its stored fields, `State`,
  `timeLine`), `TodoList`, `TodoData` (`item`, `list`, `ordered`, `blockers`, `satisfied`, `stopped`, `workers`), `TodoNote`,
  `TodoQuestion`, `TodoReport`, `TodoAttachment`, `WorkStep` (a chat turn keeps the plan), `ProjectInfo`, `ProjectInfoData`,
  `ProjectFolder`, `ProjectLink`. Explicit public inits where Swift's memberwise ones are internal (`ProjectApproval`,
  `TodoReport`, `ProjectFolder`, `ProjectChatSummary`, `TodoTurnEnd`).
- `TodoStore` (the board's actions, `shared`, `snapshot`, `current`, `change`, `update`, `file`, `locked`, `url`): the board,
  the scheduler's users and `Discussion` (`workers(room:)`, delete and disconnect).
- `TodoScheduler` (`init(chats:store:)`, `start`, `startNow`, `wake`, `tick`, `recover`, `closeClocks`, `cancel`, `crew`, `lock`,
  `waiting`, `nextCheck`, `editing`, `question`, `instruction`, `threshold`, `maxAttempts`) and `TodoChats`, `TodoPhoto`,
  `TodoTurnEnd`: how the chat side plugs in (P0). `TodoScheduler.noCrew` and `init(discussion:store:)` are app extensions.
- `ProjectChatSummary`, `ProjectChats.list`: what project code may read of a chat (id, time, project, lock, the open turn);
  `TodoProject` (`all`, its fields): the board's and todo_add's project list.
- `ProjectWork` (`acquire`, `release`, `busy`, `isBusy`, `isHeld`, `busyKorean`/`busyEnglish`, `register`, `finish`, `active`,
  `workBinding`, `revokeTools`), `Notification.Name.projectReleased`/`todoNeedsUser`: the chat's writing answers, ToolHub
  (`revokeTools`, set once when it starts), ApprovalAlerts. `isHeld`, `active`, `busyEnglish`, `projectReleased`, `tick`,
  `recover`, `maxAttempts`, `startDrafts`, `url` and TodoItem's `attempts`/`notes`/`report`/`interrupted` are public also so the
  contract can watch the state changes from outside (nothing else of the module was opened for a test).
- `ProjectRun` (the turn's capability: `init`, `nextAttempt`, `endAttempt`, `validate`, `checkpoint`, `setPlan`, `setAppStep`,
  `note`, `log`, the `on…` callbacks, `generation`, `attempt`, `deadline`, `committed`/`pushed`), `ProjectProcess` (`run`,
  `git`, `inspect`, `documents`, `Reply`), `ProjectCenter`, `ProjectApproval`, `ProjectRules` (`read`, `Part`),
  `ProjectInfoStore`, `ProjectCreator` (`prepare`, `create`, `createFolderless`, `folderlessBinding`, `summary`,
  `defaultLocation`, `Plan`): `runProjectSolo`, the menus, Project info, the review (`ProjectSnapshot`).
- `ProjectBinding.groupKey`: one project across its worktrees (`SidebarProjects.key` forwards to it).
- C0, logic moved down from the chat's `extension Discussion` blocks: `ProjectWork.linking` (a chat links a project: the
  root writable, after the linked folders or first for documents), `ProjectWork.moving` (a chat moved into a project;
  `SidebarProjects.moved` forwards), `ProjectRun.setPlan(todos:generation:)` (the stream's TodoWrite list read here, so the
  chat no longer names `PlanLink`), `TodoStore.lockProject` (a locked project's TODO lists).
- The five providers (`shared`, `ToolProvider`'s members; `ProjectMakerLink.cancellation`/`addChat`, `TodoAddLink.store`/
  `names` as before): ToolHub lists them in its order.

### AIChat (`app/modules/AIChat/`: ChatRecords, ChatValues), step C1a
A chat's record and where it is kept: `Conversation` (chats/<id>.json), `ChatTurn` and `ChatTurn.Entry`, `ChatConfiguration`,
`ChatStore` (`dir`, `loadAll`, `save`, `delete`, `links`), the values a record holds (`ChatImage` and `ImageStore` for
<id>.assets, `RoomDocument`, `MaterialUnit`, `CollaborationTask`, `VoteBallot`, `ChatRoute`, `MeetingLink`, `SyncOrigin`,
and a synced copy's `SyncSnapshot`/`RemoteChat`, which hold turns and are what `ChatStore.links.remote` returns) and the
record's helpers (`ChatTurn.Entry.reply`/`shortLine`, `ChatTime`, `SpeechLength`). Moved as they were: the declarations are
the same lines with `public` and an explicit init; the old files lost them (Discussion.swift, Attachments, RoomDocuments,
MaterialReader, Collaboration, Vote, Route, Meeting, DeviceSync). Depends on `AIAccounts`, `AILocalization`, `AIRuntime`
(`ReplyHeadline`), `AIWorkspace` (`WorkspaceBinding`, `WorkspaceChange`), `AISpaces` (`SpaceDraftNote`, `SpaceSyncNote`) and
`AIProjects` (`WorkStep`). The direction is Chat → Projects: Projects keeps deciding commits and TODO state changes and
names no chat type; Chat calls its public functions.

| Promise | Users | Module test (`chat_contract.swift`) | User tests |
|---|---|---|---|
| Older chats are read as they were (old keys `keepSessions`, `school`, `maxTurns`, `peerReview`/`peerAccountID`, turns without `mode` or times) and saved again with the same content as before the module: the fixtures' `*.saved.json` were written by the app's own ChatStore at f05fd72 (compared as JSON: JSONEncoder's key order differs run to run, before and after alike) | Discussion, DeviceSync, ChatSearch, ChatTools, Memory, ChatStorage, every test | "old keys are read", "… saved as before" (three fixtures in `tools/tests/chat_fixtures`: the oldest discussion, a locked synced project chat with most fields, a meeting's chat) | mode2 "legacy decoding", testDeviceSync, testChatSearch |
| Newest first; an unreadable file skipped; a blank chat not written; files 0600 | Discussion | "all readable chats, newest first", "a blank chat is not kept", "a chat file is 0600" | mode2 (persistence), testAutoMeeting (order, indirectly) |
| Delete: the links' purges in order, `<id>.work`, documents, `<id>.assets`, `<id>.json`, then `deleted`; the first failure throws and keeps it and what follows | Discussion (`removeChats`), Meeting | "a failure stops at once", "a failure keeps every place after it", "sessions, backups, then the documents' folder, deleted last" | `testChatLinks`, mode2 storage |
| Pictures at <id>.assets/<picture id>.png, a bad picture refused | Attachments, Pictures, TodoChatsApp | "a picture lives in the chat's .assets folder", "a bad picture is refused" | mode2 attachments ("deleting chat must remove copied images") |

Public names and why: the record types' stored fields and their inits are the save format (every reader and writer of a
chat uses them; Swift's memberwise inits are internal, so each type got one public init with the same order and defaults);
`ChatStore` and `Links` (C0's seam, set by `ChatLinksApp.connect`); `ImageStore` (pictures pasted, drawn or brought by a
TODO); `SyncSnapshot.version`, `RemoteChat.Status` (DeviceSync lists and reads copies); `ChatTime.stamp`/`day`/`when`,
`SpeechLength` (the chat window and the discussion modes); `Entry.reply`/`shortLine`. Internal: `ChatTime.calendar` (the
boundary check), `ChatTime.format`.

C1a falsification (one change in a copy of the tree, "app" = the mode2 app tests):
| Change | Module contract | App tests |
|---|---|---|
| F1 `delete` tells `deleted` before the purges | caught ("a failure stops at once, nothing told") | caught (testChatLinks "deleted is told per chat …") |
| F2 a picture's folder `.asset` | caught ("a picture lives in the chat's .assets folder") | caught (mode2 "deleting chat must remove copied images") |
| F3 `loadAll` oldest first | caught ("newest first") | caught, indirectly (testAutoMeeting picks by the first chats) |
| F4 a chat file saved 0644 | caught ("a chat file is 0600") | **missed**: only the module test checks the mode |

### AIChat, step C1b: Discussion and everything it runs (2026-11-12)
Moved whole (`git mv`, bodies unchanged except the lines below) from `app/macos` into `app/modules/AIChat`: Discussion, Solo
(plain chat, `AutoPick`), Route (the way a message is answered, `RouteSorter`), Meeting (meetings, `ConveneLink`), Debate,
Collaboration, Vote, Peer (ask_ai, the review, `PeerLink`), Attachments, RoomDocuments, MaterialReader, ChatTools (`ChatLink`),
Memory (`MemoryStore`, `MemoryLink`), ChatStorage (`StorageLink`), CollabLog, Pictures, Enterprise, ChatSearch, ChatFind,
ChatNotes, TodoChatsApp (Discussion as Projects' `TodoChats`), ProjectChat, ProjectCreate, SidebarProjects, DeviceSync (chats
from other Macs: a chat's synced copy), and the chat window's own views: ChatWindow, Markdown, SpaceView, WindowDrag; new
ChatUI.swift (`PlainHitButtonStyle`/`.plainHit` and `SidebarHeader` out of Settings.swift, the TODO state's `title`/`color`
out of TodoBoard.swift) and ChatApp.swift (what the chat gets from the app). Every `extension Discussion` is now inside the
module (stage 1: none in `app/macos`), so Discussion's state stays internal.

Why the chat window went with it: with the views in the app, the app would need about 117 of Discussion's members public
(measured), which the roadmap rules out; ChatGPT (school) and Gemini, asked, said the same and advised against hiding them
behind `@_spi`. In the module the views use the state directly, and the app reaches the chat through the names below.

Direction: AIChat → AIProjects (and Workspace, Runtime, Spaces, Accounts, Localization). Projects names no chat type.
What the chat gets from the app, set by the app (the chat side names none of these app parts; unset it runs plainly):
- `ChatSettings` (protocol, `AppModel` conforms: `extension AppModel: ChatSettings {}`): the 14 settings the chat reads
  (accounts, usage, chat rules, local model, picture makers, team picks, collaboration, shared folders); `Discussion(model:)`
  takes it, `ChatView` is generic over it so the window still observes the settings.
- `ChatApp.run` = `RunConditions.app` (RunConditionsApp.swift), `ChatApp.face` = FaceLink's extract/show/active/moods/rule,
  `ChatApp.driveRule` = DriveLink's rule while on: set in `ChatLinksApp.connect()` (main.swift and mode2, as in C0).
- `ChatApp.screens`: the TODO board (row, board, a chat's cards), Project info and its rename, the Drive section, the icon:
  set in the new `ChatScreensApp.connect()` (main.swift after ChatLinksApp, stage 1 checks the place; the chat preview too).
- `toolFailure` is the module's copy of `ToolHub.failure` (the same reply shape); `RunConditions.app` inside the module forwards
  to `ChatApp.run`, so the chat's calls read as before.

Stays in the app (what the user sees of other parts): Settings (all tabs, Memory/Rules/Storage windows), TodoBoard, ProjectInfoView,
GitBranches, DriveUI/DriveLink/GoogleAuth, ExternalMCP/RemoteMCP, FaceLink, ToolHub (the 13 providers in their order, stage 1
checks the list), ApprovalAlerts, MenuCards, main, Login, Updater, Icon, Poker, LocalModels, RunConditionsApp, ChatLinksApp,
ChatScreensApp. Two app edits besides imports: `StorageListView.measured` (one string the compiler could no longer type-check
inline once the names came from another module; same text) and the `AppModel` conformance line.

Public names and why (found by the compiler, not by hand: a script opened only what an app file or a public protocol asked for;
everything else, Discussion's state above all, stays internal):
- Discussion (about 30 of its members): `init(model:)`; what main.swift does with the chat (`open`, `current`, `anyRunning`,
  `cancelAll`, `discardPendingImages`, `importingMaterials`, `fillSpaceLocks`, `runningRooms`/`stoppingRooms` and their
  publishers); what the app's screens show (TODO board: `conversations`, `conversation`, `currentID`, `label`, `openBoard`,
  `viewingBoard`, `boardProject`, `hover`/`hoverKey`, `model`; Project info: `listedConversations`, `showBoardTab`,
  `disconnectProjectFolder`; approvals: `approvalChatName`, `viewingRemote`); `TodoChats` (P0's seam, all its members);
  `Discussion.meets`/`autoPicked` (Settings' team picks).
- The five tool providers (`shared`, `active`, `tools`, `call`; `MemoryLink.newestTurn` for ToolHub.register): ToolHub lists them.
- Settings' tabs: `MemoryStore`/`MemoryItem`/`MemoryData`, `ChatStorage` (`report`, `items`, `format`, `Report`, `Room`, `Kind`),
  `CollabMode`/`CollabLog`, `RouteSorter`, `ApprovalAlertSettings`, `DeviceSync` (settings, start, scan, the notes the links call),
  `ChatLink.conversations`; the board and Project info: `SidebarProjects` (`key`, `group`, `pickerName`), `ProjectGroup`,
  `SidebarFold`, `BoardTab`, `PictureDrop`, `Enterprise.permits`, `AutoPick.fiveHour`/`weekly`, `TodoItem.State.title`/`color`;
  DriveLink: `MaterialReader.read`, `RoomDocuments.directory`; main: `ChatWindow`, `SpaceRefiner.watchLibrary`,
  `ApprovalListView`; everyone's views: `PlainHitButtonStyle`/`.plainHit`, `SidebarHeader`.
- `ChatSettings`, `ChatApp` (and `Face`, `Screens`): the seams above.

| Promise | Users | Test |
|---|---|---|
| ask_ai from an answering CLI reaches another kind of AI through the app's tool socket (ToolHub → PeerLink → Peer → Answerer), read only and unable to ask on; the reply goes back into the answer and shows as a card | ToolHub, the CLIs | `chat_cli.swift` `testChatThroughCLI` (fake claude/codex CLI, no answer hooks), testAskAI (whom: "a different kind first, even when…" added in C1) |
| A meeting runs in its hidden chat with both members' CLIs and brings the result back as the answer | ChatWindow | `testChatThroughCLI`, testPickedRoute, testMeetingTool |
| A work answer's change is reviewed once by the other member, read only, and fixed in the same turn | ChatWindow, TODOs | `testChatThroughCLI`, testPeerReview, testDocumentsProject |
| The 13 tool providers keep their order | ToolHub | run_mode2 stage 1 (the exact list) |
| The chat runs each AI with the app's run conditions and AI Face rules | Answerer | testRunConditions (golden), testRuntimeThroughApp, mode2 AI Face link |

C1b falsification (one change in a copy of the tree; module contract, then the mode2 app tests):
| Change | Module contract | App tests |
|---|---|---|
| G1 the app connects no AI Face tag reader (`face.extract` returns the text) | passed (not its promise) | caught: mode2 chat members "both replies are shown, the first done on top" |
| G2 the app's run conditions drop the folders (`ChatApp.run` ignores the workspace) | passed | caught: testRunConditions "full access runs with AutoGuard's environment" |
| G3 ask_ai asks by usage only (no "different kind first") | passed | **missed at first**; caught after C1 added testAskAI "a different kind first, even when another account of the asker's kind has more usage left" |
| G4 a review with findings starts no fix | passed | caught: testChatThroughCLI "review: the work, its review and the fix in one turn" (and testPeerReview) |

Still open from C0: F7 (Space refine) is covered by the Spaces contract only; SpaceView is now in the module and in the test build,
but no app test drives a Space's change box yet.

### AIIntegrations (`app/modules/AIIntegrations/`: GoogleAuth, DriveLink, ExternalMCP, RemoteMCP, FaceLink, Failure), step I (2026-11-12)
Moved (`git mv`) from `app/macos`: GoogleAuth (the Google login, its Keychain item, the bounded HTTP client, the sign-in callback),
DriveLink (the shared folders, the folder gate and the Drive requests), ExternalMCP and RemoteMCP (outside MCP servers: the settings file,
local and remote connections, secrets, tool rules, OAuth) and FaceLink (the AI Face link). Depends on `AIAccounts`, `AILocalization`,
`AIRuntime` (only because `AIWorkspace`'s interface names it) and `AIWorkspace` (`WorkspaceRoot`: which local folders Drive may read and
download into). Not on `AIChat` or `AIProjects`; no module imports it (stage 1 checks both): the app uses it and hands the chat what it
needs through `ChatApp` (C1, unchanged).

No tool provider in the module (stage 1: no `ToolProvider`, `ToolHub` or `ToolContext` in its files). The app makes the three providers:
- `ToolHub.swift` `extension FaceLink: ToolProvider` (as before).
- New `DriveTools.swift` `extension DriveLink: ToolProvider`: the tool descriptions (`tools()`, `tools(context:)`, unchanged text) and the
  hand-over `perform(name, arguments, roots:)`. The gate stays in the module because its order is the permission: only allowed folders,
  a write validated again after the token refresh and right before sending, no result once the login or the settings changed
  (ChatGPT (school), asked, agreed: the app must not re-implement it).
- New `ExternalMCPTools.swift` `extension ExternalMCP: ToolProvider`: the Enterprise rule in both the list and the call (before anything
  is passed on), the approval card (`approve`, `isEnterprise`, tests replace them as before); the module's `call(name, arguments, approve:)`
  keeps block/ask/allow, the two-minute limit with the approval counted, the refusal text with `approvalWait`, and the remote-data note.

Injected so tests need no real Keychain, network or socket (the defaults do what the app always did):
- Keychain: `GoogleKeychainStore(run:)` (already) and `MCPKeychain(run:)` (new), both the `/usr/bin/security` runner; `GoogleAuth(store:)`.
- Network: `GoogleHTTP.transport` and `MCPHTTP.transport` (default `live`: no redirects, nothing kept, size and time limits, SSE as it
  comes). Every Google and remote MCP request already went through `send`; only its URLSession part moved into `live`.
- Sockets: `GoogleLoopback.make(port, label)` returns an `OAuthCallback` (both Google's desktop sign-in and MCP's, including the
  registered port reuse); the tool socket and AI Face's older socket stay ToolHub's (main.swift opens them right before
  `FaceLink.shared.start()`, which no longer does; stage 1 checks the order).
- AI Face: `FaceLink(open:)` takes the connection (`FacePipe`); the default `FaceProcess` is the old process code moved as it was
  (AIFACE_AGENT=illuminati, 10 s per reply).
- Office files read from Drive use the chat's material reader through `DriveLink.officeText` (set in `ChatLinksApp.connect()`), so the
  module names no chat type; without it such a file is "not supported", as other formats are.

Storage unchanged: the Google item is still service "AI Illuminati Google", account `oauth` (copy `oauth-migration`), value
`ai-illuminati-google-v1:` + base64 of the same `Credentials` JSON; MCP secrets "AI Illuminati MCP" in numbered chunks; `mcp.json`,
`mcp-servers.json`, `mcpOff`, `driveFolders`, `pausedDriveFolders`, `driveWriteRules`, `drive.log` the same keys and files.

| Promise | Users | Module test (`integrations_contract.swift`) | User tests |
|---|---|---|---|
| A saved Google login (current form, an older raw item, a half-done migration) is read; refresh, rotation, expiry and revoke keep the same item and input line | DriveUI, DriveLink | "a saved login is connected…", "a raw item from older versions still loads", "a half-done migration is finished…", "saved through security's stdin…", "an expired login keeps the client…", "disconnect clears…" | google_drive "Google Keychain CLI", "Google Drive backend" |
| Both sign-ins finish only with their own state, saved in the same form | DriveUI | "the app's client signs in…", "a callback with another state is refused", "the desktop client is saved with its secret" | google_drive (PKCE, state) |
| Drive's gate: allowed folders, writes re-checked before sending, no result after a change | DriveTools (the app's provider) | none (needs Drive answers) | google_drive (all Drive blocks) |
| Outside MCP: rules block/ask/allow, Enterprise never, approval, secrets in chunks | ExternalMCPTools, Settings | "an unknown outside tool is refused without asking", MCP secrets block | testExternalMCP, testRemoteMCP |
| AI Face: one connection, its tools and moods, unknown moods dropped; missing, off or dying AI Face: error replies at once, reconnect on the next use | ToolHub, ChatLinksApp (`ChatApp.face`), RunConditionsApp (`codexOff`) | the AI Face block (fake `FacePipe`) | mode2 "AI Face link", and new there: a dead AI Face server while a plain chat answers (reply shown, tag removed, usual moods in the rule, no wait) |

Public names and why (found by the compiler: a script opened what an app file asked for, the rest by hand for the contract test):
- What the app's screens and providers use: `DriveLink` (`shared`, `enabled`, `active`, `canWrite`, `folders`, `pausedFolders`,
  `writeRules`, `rule`, `downloadRoot`, `perform`, `childFolders`, `folder(from:)`, `accountEmail`, `officeText`), `DriveFolder`;
  `GoogleAuth` (`shared`, `builtInClientID`, `connected`, `needsReconnect`, `canWrite`, `publicClientID`, `connectionVersion`, the three
  sign-ins, `cancelAuthorization`, `disconnect`), `GoogleFailure`, `GoogleAuthPresenter` (DriveUI's browser session);
  `ExternalMCP` (settings, status, sign-in, rules, `tools`, `active`, `slowTools`, `call(…approve:)`, `approvalWait`, `stopAll`, `State`,
  `Status`), `MCPServerEntry` (Settings' editor), `MCPToolRule`, `MCPSecrets` (`store`, `header`, `clientSecret`), `MCPSession.Failure`
  (Settings shows its message; `MCPSession` itself is public only to hold it); `FaceLink` (`shared`, `socketPath`, `isOn`, `active`,
  `configured`/`connected`/`on`, `codexOff`, `moods`, `rule`, `extract`, `show`, `start`, `refresh`, `tools`, `call`).
- The injection points (for the contract test, and they say what may be replaced): `GoogleHTTP` (`Reply`, `transport`, `live`),
  `GoogleTokenStore`, `GoogleKeychainStore` (`Runner`, `init(run:)`, `load`/`save`/`clear`), `GoogleAuth.init(store:)`, `accessToken`,
  `OAuthCallback`, `GoogleLoopback.make`, `MCPSecretStore`, `MCPKeychain(run:)`, `FaceLink.init(open:)`, `FacePipe`, `FaceLink.file`/
  `faceFolder`, `FaceLink.Server`.
- Internal (stage 2 checks four): `FaceLink.server`, `fallbackMoods`, `FaceProcess`, `GoogleAuth.tokenURL`/`authorizeURL`/`revokeURL`,
  `DriveLink.isAllowed`/`isWritable`/`fileID` and every request, `ExternalMCP.callTimeout`, `MCPHTTP`, `RemoteMCPSession`, `MCPOAuth`,
  `MCPPermissions`, `MCPFileSecrets`. mode2 and google_drive reach them with `@testable import AIIntegrations`.

App edits besides imports: main.swift opens ToolHub's two sockets before `FaceLink.shared.start()`; ChatLinksApp sets `DriveLink.officeText`;
the three provider extensions (`@retroactive`: the conformance is the app's on purpose). mode2's AI Face test opens the older socket itself,
as main.swift does. Previews import the module.

I falsification (one change in a copy of the tree; module contract, then the app tests without the module contracts):
| Change | Module contract | App tests |
|---|---|---|
| H1 the Google item's prefix becomes `…-v2:` (an existing login is no longer read) | caught ("a saved login is connected, writable as saved") | **missed**: google_drive writes and reads with the same code; only the contract holds a login in the old form |
| H2 a dead AI Face connection is kept while the setup is the same (no reconnect) | caught ("with AI Face gone the link offers nothing…") | **missed at first**; caught after I added mode2 "a restarted AI Face is connected again on the next use" (this test's server killed by its path in the test home) |
| H3 an outside MCP tool set to "ask" runs without asking | passed (no connected server in the contract) | caught: testRemoteMCP "a write tool asks first; no answer is no" |
| H4 Drive returns a result after a folder was paused during the call (post-request check gone) | passed (needs Drive answers) | caught: google_drive "in-flight result withheld after folder pause with another folder active" |
| H6 the app's list offers outside MCP tools in Enterprise chats | passed (the rule is the app's) | caught: testExternalMCP "no outside servers in Enterprise chats" |

The first H3 run (three copies at once) stopped earlier at testMeetingTool "the meeting stops…" (timing under load, unrelated: no
meeting code changed); alone it reached and failed the MCP check above.

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
