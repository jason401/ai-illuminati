# Modules: one Swift module per part, checked by promise → user → test

The app is one Swift program built from `app/macos/*.swift`: in it, every file can use every other file's
`internal` names, so a folder alone draws no line. A part in `app/modules/<Name>/` is its own Swift module:
it builds alone, and the app sees only its `public` names. Nine modules (2026-11-11 to 2026-11-13): `AILocalization`,
`AIAccounts`, `AISpaces`, `AIRuntime`, `AIWorkspace`, `AIProjects`, `AIChatRecords` (T4), `AIChat`, `AIIntegrations`.
Size (2026-11-15; count: `git ls-files 'app/*.swift' | xargs wc -l`, 85 files): 33,333 lines; AIChat 13,846 (41.5%),
AIChatRecords 465, App (`app/macos`, 18 files, the files S3 counts) 7,402, of them Settings.swift 2,351.
This file: **Rules** (how to keep the lines) → **Module map** (owners, graph, promises, public names and why). Dated
measurements and step records (A, M, T4, the falsification tables) are in `docs/modules-history.md`.

## Rules
Principle: the rules are short; what must hold is checked by a machine. AGENTS.md "Module rules" is the short form
every AI gets with each project answer; this section adds the reasons and the checks.

### Where new code goes
1. The module that owns the work (the map below). Shared logic goes to the lowest module that owns its idea, never to a
   new "Core"/"Common" module: a common module becomes everyone's dependency and everything drifts into it.
2. App (`app/macos`), only for screens, settings, app start and connecting modules (`tools/app_files.txt` gives each
   App file's reason).
3. Neither fits, or the owner would need a new dependency: stop and ask the user (a graph change).

Examples:
- *Usage readings for a new AI service*: reading the numbers is `AIRuntime` (usage readers sit there; its contract and the
  promise rows' tests run); the menu card showing them is App (`MenuCards.swift`); the account entry is `AIAccounts`.
- *A tool that reads a new outside service (say a calendar)*: the sign-in and requests are `AIIntegrations` (injectable
  network and Keychain, like `DriveLink`); the App offers it as a tool in `ToolHub.swift` (like `DriveTools.swift`), because
  Integrations has no tool provider and only the App imports it.
- *A new field on a TODO and its badge on the board*: the field and its save format are `AIProjects` (`Todo.swift`; run
  `projects_contract` and the `TodoItem` row's tests, update `docs/api/AIProjects.txt`); the badge is App (`TodoBoard.swift`)
  or, inside a chat's TODO card, `AIChat`. Projects never names a chat type: a chat-side need goes through `TodoChats`.

### Never, and what needs the user's approval
Never: a dependency outside `tools/module_graph.txt`; logic in an `extension` of another module's type (the old
`extension Discussion` sprawl); a Core/Common module; bulk `public` (each public name gets its reason in the map below);
splitting AutoGuard; `@testable import` in app files or contract tests; `git commit --no-verify`.
User approval: graph changes, a new module, removing or merging modules, changing a guard device (G7).
A failing check means the code changes, not the check. If a check must change, write why here and tell the user.

### Guards (`tools/check_modules.sh`; fast = no compiler, pre-commit hook and run_mode2 stage 1; slow = run_mode2 stage 2)
| Check | What it does | Prevents |
|---|---|---|
| G1 graph (fast) | each `dependencies` file and each actual import stays inside `tools/module_graph.txt`; reverse edges, unused or repeated declarations and cycles fail (`check_module_dependencies.py`, from step A, now reads the graph file) | a one-line detour through `dependencies` |
| G2 required files (fast) | every module folder has `dependencies` (empty = none), `boundary`, `tools/tests/<name>_contract.swift` (AIFoo → foo) and `docs/api/<Name>.txt`; a contract with no module fails. run_mode2 finds contracts and boundaries from the module folders (no hand list) | a module without contract or boundary; dropping one from a list |
| G3 App files (fast) | every `app/macos/*.swift` is in `tools/app_files.txt` with a reason | new features piling into the App |
| G4 outside extensions (fast, **warning**) | an `extension` of a type another module declares `public`, outside that module, unless listed in `tools/module_extensions.txt` with a reason | logic scattered over other modules' types |
| G5 `@testable` (fast) | none in `app/macos` or `*_contract.swift` (comments and strings ignored) | app files using insides through the test build's `-enable-testing` |
| G6 documents (fast) | the backticked `AI…` names in AGENTS.md "Module rules" and the `### AI…` sections under "Module map" here equal the module folders; that section ≤ 2,000 characters; AGENTS.md + CLAUDE.md ≤ 25,000 (the app passes 30,000, AGENTS.md first); `tools/test_map.txt` has a line per module, real test names only, and every test a module's rows below name (`tools/affected_tests.py`, guarded too) | stale rule documents; a selective run that skips a named test |
| G7 guard hashes (fast) | sha256 of the guard files and run_mode2's `# >>> module checks` blocks (exactly two) against `tools/module_guard.sha256`; update with `zsh tools/check_modules.sh guard` | quietly weakening a guard: the change shows in the same commit |
| S1 API snapshots (slow) | each module's public declarations (`swift-symbolgraph-extract`, public and open, no synthesized members, sorted text) equal `docs/api/<Name>.txt`; update with `zsh tools/check_modules.sh snapshot` | bulk `public` slipping by unseen |
| S2 boundaries (slow) | each `boundary` line (`code<TAB>name[<TAB>hidden]`) compiled outside the module must fail with exactly the "inaccessible due to 'internal'" (or, hidden, "cannot find … in scope" for a type that exists inside) error and no other | boundary checks that pass for another reason |
| S3 App size (slow, warning) | `app/macos` lines over 10% above `# baseline-lines` in `tools/app_files.txt` | the App growing inside its files |

G4 stays a warning (T5, 2026-11-13). It becomes a failure (a guard change: the user approves) only when all hold, not after
a time or a number of commits: (1) no false hit on correct code: a full `check_modules.sh` run warns 0 times, and an
extension of a module's own type inside it, of an Apple type, or of a type no module declares public gives no warning;
(2) no missed case among the supported ones: a copy test of each (`extension <OtherModuleType>` in an App file and in another
module, `extension AIChat.Discussion` with the module name, a nested `extension Type.Inner`, with `public`/`private` and a
plain `@attribute`) warns; (3) `tools/module_extensions.txt` still has its 17 lines, none added to make it pass; (4) the
limits are written here. Known limits (not caught, regex not a parser): an attribute with arguments before `extension`
(`@available(...) extension X`), a constrained extension of a standard type (`extension Array where Element == X`), types
declared public only inside an extension or a nested type, `tools/tests/` files and folders below a module's top level.

Hooks: `.githooks/pre-commit` (fast) and `.githooks/pre-push` (`run_mode2.sh --modules`: stages 1-2), installed by
`zsh tools/setup_dev.sh` (`core.hooksPath`, never overwriting another value); run_mode2 warns when they are missing.
They are a convenience, not enforcement: the app's own Git commands run with `core.hooksPath=/dev/null` (ProjectWork,
on purpose: a repository's hooks never run inside the app), so the same checks run again in run_mode2. Real enforcement
would be CI, which the user decides (public repository).
New module: `zsh tools/new_module.sh <Name> <deps...>` makes the folder, `dependencies`, `boundary`, a contract stub,
an empty snapshot and the map entry to fill; it prints, but does not make, the graph and guard lines (approval).
Hidden coupling (globals, notifications, shared files; D11) is not a graph matter: the promise rows and app-path tests
below cover it.

### Exceptions (each with its reason; the full list)
- G4: 17 existing extensions in `tools/module_extensions.txt` (3 App tool providers for Integrations types, the App's run
  policy on `RunConditions`/`GeminiLinks`, Login's Ollama installer, a menu display helper, and 10 inside modules: display
  colors/titles, the TODO seam, one-field helpers, the chat's picture and routing helpers). The file is guarded (G7).
- G1: `AIIntegrations` → `AIRuntime` is interface-only (`AIRuntime*` in the graph): Swift must see a module a
  dependency's public interface names.
- S2: `AILocalization` has no internal name (only `L()` and `AppLanguage`, all public): its boundary file says `# none:`.
- G2: `AILocalization` had no contract test; step M added `localization_contract.swift` rather than an exception.

## Module map

### Module map and dependency graph

The map below is the final ownership; step reports are in `docs/modules-history.md`.



| Part | Owns | Direct module dependencies |
|---|---|---|
| AIAccounts | accounts, paths, save format, test-home isolation | none |
| AILocalization | L(), AppLanguage | none |
| AISpaces | Space storage, versions, checks, isolated WebView | AIAccounts, AILocalization |
| AIRuntime | CLI execution, Stop, sessions, streams, usage, local models | AIAccounts, AILocalization |
| AIWorkspace | folder permissions, documents bridge, backup/Undo, whole AutoGuard, tool types, disk sizes | AIAccounts, AILocalization, AIRuntime |
| AIProjects | Git work, repository locks, approvals, TODO storage/scheduling, project info/creation; Git/Plan/Task/TodoAdd/ProjectMaker providers | AIAccounts, AILocalization, AIRuntime, AIWorkspace |
| AIChatRecords | chat record values (pictures, documents, sync origins…), the chats/ path, dropped files, collab log, disk report; no providers; knows no Discussion | AIAccounts, AILocalization, AIRuntime, AIWorkspace |
| AIChat | chat records/state/storage, routing, meetings/reviews, ask_ai, attachments, DeviceSync, chat/Space views; Peer/Convene/Chat/Memory/Storage providers | AIAccounts, AILocalization, AIRuntime, AIWorkspace, AIProjects, AISpaces, AIChatRecords |
| AIIntegrations | Google auth/Drive gate, external MCP connections, AI Face; no providers | AIAccounts, AILocalization, AIRuntime (interface only), AIWorkspace |
| AIRemote | the iPhone page and its 127.0.0.1 server (key check, HTTP parsing); knows no chat | AILocalization |
| App (app/macos) | startup, menu/settings, screens, update/login, wiring and explicit 13-provider list; Face/Drive/ExternalMCP conformances | all ten modules, each imported directly by the files that use it |

Arrows mean imports, from caller to dependency (all direct edges are in the table):

```text
App            -> all ten modules directly
AIChat         -> AIChatRecords, AIProjects, AISpaces, AIWorkspace, AIRuntime, AIAccounts, AILocalization
AIChatRecords  -> AIWorkspace, AIRuntime, AIAccounts, AILocalization
AIProjects     -> AIWorkspace, AIRuntime, AIAccounts, AILocalization
AIIntegrations -> AIWorkspace, AIRuntime, AIAccounts, AILocalization
AIWorkspace    -> AIRuntime, AIAccounts, AILocalization
AIRuntime      -> AIAccounts, AILocalization
AISpaces       -> AIAccounts, AILocalization
AIRemote       -> AILocalization
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
7. DelegateLink (sub-room P2: delegate_*, git_merge_sub, sub_report, sub_blocked; left out for consulted AIs like Peer and Convene)
8. ChatLink
9. MemoryLink
10. ProjectMakerLink
11. TaskLink
12. TodoAddLink
13. StorageLink
14. ExternalMCP

`shared` alone connects ProjectWork.revokeTools; a fixture hub cannot overwrite that hook.
The clock defaults to Date(); tests inject time without waiting two hours. `available(context:legacy:)` holds the
unchanged origin selection so its identities can be checked independently of providers' own permission gates.
Fixture hubs pass listenOnRegister: false and assert no socket file was created; the production default still listens.
These are app-internal seams: no new module or public symbol.

| Promise | Consumer | Check |
|---|---|---|
| The exact 14 singleton identities and order; current replaceable Drive singleton | ToolHub.shared | run_mode2 stage 1 exact source list; testToolHub identity and Drive replacement |
| Tool listing preserves provider order and duplicate names; call uses the first active provider that lists the name in that context | CLI bridge | testToolHub duplicate fixtures, inactive/context-hidden list and call; baseline + A1/A2/A3 mutants |
| member keeps the list; side has only Peer; consulted excludes Peer, Convene and Delegate; legacy has only Face, before providers' own gates | workspace bridge, ask_ai, meetings, old Face bridge | testToolHub exact selected identities and side/legacy call refusals, A4 mutant; testAskAI, testMeetingTool, testChatThroughCLI |
| Unknown/expired sessions cannot list or call; project revocation removes only that project's sessions; unknown operations/names fail | all CLI calls, project turn end | testToolHub, injected-clock expiry, A5 mutant; testProjectHandoff |
| Slow names are limited to tools actually exposed | workspace_mcp.py | testExternalMCP (nonempty exposed fake-server slow names); an excluded-slow-name negative case is not covered |
| Each module follows its declared imports and allowed direction | every module/app build in run_mode2 | check_module_dependencies.py, DependencyRules temporary-tree falsifications, build_modules.sh visibility and cycle checks |
| No trial behavior survives in the app sources | main | validate_app_modules.py app-source SHA256 comparison, return to main after local trial snapshots |

### App code reviewed for later moves (list only; A moves none)

| Candidate | Possible owner | Boundary to preserve |
|---|---|---|
| GitBranches.swift: parsing Git output, branch/version/distance report | AIProjects | inject Git runner; ProjectInfoView and its presentation stay App |
| DriveUI.swift: DriveTree rows/writable and tree request/cache bookkeeping | pure tree data in AIIntegrations; observable screen state stays App | preserve lazy expansion, cycle/depth bound, inherited write rules and login-version rejection |
| LocalModels.swift: LocalModelStore refresh/pull/cancel/delete state | AIRuntime behind a narrow view model | remove AppModel coupling first; opening NSWorkspace and the window stay App |
| Settings.swift: pure default-chat-rule migration and account/model choice transformations | split by AIChat/AIAccounts/AIRuntime ownership | preserve UserDefaults keys, per-instance test settings and the App's ChatSettings conformance |

App cleanup (Settings.swift 2,351 lines and the rest of `app/macos`, 7,402 lines on 2026-11-15, counted as in the size
line above) is outside the modules follow-up (T5). Look again when `app/macos` grows more than 10% above the S3 baseline
(7,054 → over 7,759 lines), i.e. when S3 warns.

Startup, ToolHub, ChatLinksApp/ChatScreensApp, RunConditions.app, settings/windows/menu, notifications, login and
updater remain App composition or platform work. Gemini allowWeb in RunConditionsApp still expresses App policy;
A does not relocate it or alter AutoGuard, permissions, signing, install or release files.


### How a module is built and used
- `zsh tools/build_modules.sh <out> [swiftc options]` builds every `app/modules/<Name>/` alone into
  `<out>/<Name>.swiftmodule` + `<out>/lib<Name>.a` (static: nothing new in the app bundle, signing unchanged).
- A module may use only the modules named in its `dependencies` file (one per line; an empty file: none), and only
  edges allowed by `tools/module_graph.txt` (G1). They are built
  first, and the compiler sees only theirs, so an import of any other module fails the build. Now
  `AISpaces` → `AIAccounts`, `AILocalization`; `AIRuntime` → `AIAccounts`, `AILocalization`; `AIWorkspace` → `AIAccounts`,
  `AILocalization`, `AIRuntime`; `AIProjects` → `AIAccounts`, `AILocalization`, `AIRuntime`, `AIWorkspace`; `AIChatRecords` → `AIAccounts`, `AILocalization`, `AIRuntime`, `AIWorkspace`; `AIChat` → those five, `AISpaces` and `AIChatRecords` (Chat uses
  Projects, never the other way: Projects names no chat type since P0); `AIIntegrations` → `AIAccounts`, `AILocalization`,
  `AIRuntime` (only because `AIWorkspace`'s interface names it), `AIWorkspace` (`WorkspaceRoot`: Drive's folders), used by the app only; the other two use none. No circles (the script refuses them).
- Every `swiftc` that compiles app files runs it first and adds `-I <out> <out>/lib*.a`:
  `tools/build_app.sh` (compile step), `tools/tests/run_mode2.sh`, the preview scripts.
- Each file that uses a module says `import <Name>`. Not the hidden compiler option (`-Xfrontend -import-module`):
  the import line shows who uses the module (`grep -l "import AIAccounts"` lists its users), and no
  compile command needs one more flag.
- Name: `AI` + the part, never Apple's framework names (`Accounts` is one).
- `run_mode2.sh` stage "Modules on their own": builds the modules alone, runs each module folder's contract test from
  outside (`tools/tests/<part>_contract.swift`, public names only), and its `boundary` file checks that internal names
  (`AccountStore.place`, `SpaceStore.setting`, `SpaceAssets.served`, `Answerer.chatDir`, `Answerer.launchForTests`,
  `NativeSessions.split`, `CloudModels.apply`, `WorkspaceBackup.chats`/`keepPerChat`, the whole `AutoGuard` type,
  `TodoScheduler.retryDelay`, `ProjectWork.leasePrefix`, `TodoStore.encoder`, `ChatTime.calendar`, `CollabLog.maxBytes`/`file`/`Summary` fields, `RoomDocuments.read`, `Discussion.maxRunning`, `Discussion.draft`, the whole `Peer` and `Route` types, `FaceLink.fallbackMoods`, `GoogleAuth.tokenURL`,
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


### Which tests a change needs
Unchanged `public` names do not mean unchanged behavior: the falsification runs (`docs/modules-history.md`) kept every public
declaration and still broke the app. Use the table: find the promise the change touches, run the module's own
test and the user tests in its row. When the row says "none", or it is unclear which promise a change touches,
run the full test (`zsh tools/tests/run_mode2.sh`). A new promise gets a row, a module check and a user check.

Selective run (T2, 2026-11-13): `zsh tools/tests/run_mode2.sh --affected <paths>` (paths as `git diff --name-only`
prints them). `tools/affected_tests.sh` reads `tools/test_map.txt`: a module's line gives its app tests, and the script
adds that module's contract and those of every module that depends on it; a test file gives its own tests (or ALL when
another test uses what it defines). Paths not in the map, guard devices, `ToolHub.swift`/`Settings.swift`/`main.swift`,
build scripts, resources and Accounts, Localization, Runtime, Workspace and Chat give ALL: the full run, unchanged.
Stages 1, 3-9 and 12, the module build, S1-S3 and mode2's checks outside `runTest` always run (they set up the shared
state and hold the data-folder rules), so only contracts, `runTest` functions, stage 10 and stage 11 (screens) are skipped. Stage 11
runs anyway when a path is under `app/macos/` (it compiles every app file and hosts `TodoCard` from `TodoBoard.swift`),
under `app/modules/AIProjects/` (the card shows its `TodoItem`) or is `tools/tests/screens_idle.swift`; run_mode2 decides
this itself (outside the guarded blocks, so `affected_tests.py` is unchanged). AIChat's view files already give ALL. Without the
option nothing changes. A new row naming a test fails G6 until the map has it.
Test module cache: every compiler in run_mode2 (S1 and S2 included) shares `~/Library/Caches/AI Illuminati/test-cache`,
kept between runs; it holds only SDK clang modules (the app's modules are rebuilt every run). Over 2 GB at the start a run
clears it unless another run holds it; `AI_ILLUMINATI_TEST_CACHE=fresh` uses an empty one. Clearing it by hand (only
while no test runs; the next run rebuilds it and is slower once): `rm -rf ~/Library/Caches/"AI Illuminati"/test-cache`.
The guard changes behind `--affected`, the cache, `-j` and contracts at once (T2, O1, O2, O5-A, O5-B) are in `docs/modules-history.md`.
Guard changes (run_mode2's module block, guard files) are recorded with date and approval in `docs/modules-history.md`, not here.

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

### AIRuntime (`app/modules/AIRuntime/`: Answerer, Cancellation, NativeSessions, Local, Usage, TokenUsage, TokenSync, Zstd, CloudModels)
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
| Sessions: a new session starts with its own id (`--session-id` / Codex `thread.started`); the next call resumes it (`--resume <id>`, `exec resume <id>`) with only what is new; a stopped or failed answer marks it for a rebuild and is not retried (only "session not found" is, once, with the full context); the CLI's own compaction keeps the session; an instruction's fixed part (before `NativeSessions.turnMarker`) goes on every call as the system prompt (`--append-system-prompt`, Codex `-c developer_instructions=`), never in the text, and a changed fixed part starts a new session | Attachments, Collaboration, ProjectChat (`nativeSessions.ask`) | session block (new, resumed, stopped, Codex resume, "after compaction the same session id is resumed", "changed fixed instructions start a new session") | mode2 "session delta, image reuse, role separation, session kept after compaction …", project_work "fixed rules … come before the turn marker", `runtime_app.swift` ("after a stopped answer the next message starts a new session") |
| Session save format: `rooms/<room>/ownership.json`, 0600, a JSON array of records `id`, `accountID`, `provider`, `role`, `nativeID`, `context`, `ownBlock` (`[<speaker>]\n<reply without its TL;DR line>` for speakers), `images`, `valid`, and `system` (SHA-256 of the fixed instructions, only when there are some); older files are read as they are; archive and purge keep or remove only what a room recorded | Attachments, Collaboration, ProjectChat, Discussion (delete, archive) | "ownership.json keeps its fields", "an older ownership.json is read", "is private" | mode2 "chat delete removes only its sessions …" |
| Local model: no command line tool, one answer at a time (`gate`), keep-alive and unload | Local chat, Route sorter, Settings, LocalModels window, main (menu) | none (needs Ollama: a fake server in mode2) | mode2 "Ollama on this Mac", "Gemma on this Mac", `run_conditions.swift` ("the local model starts no command line tool") |
| Steering (Claude with progress and `RunConditions.steering`): the input stays open (`--input-format stream-json --replay-user-messages`); a message is written only while a tool of the main conversation runs; one replayed before the first result is told once (`onRead`) and belongs to that answer; one never written, or written and not read by the result (the call is then ended, so it never becomes a second answer), comes back from `close()`; the first result is the answer. Claude Code's reading between tool calls is measured (2.1.300), not documented | Attachments (`requestDebate`), ProjectChat (project work), Discussion (`enqueue`, `afterRun`) | "a message written while a tool runs is read into the answer, once", "… offered while the AI writes is not written; it comes back", "… written but not read before the result ends the call" | testQueuedMessages (the chat's side of the channel) |
| Usage readings and cloud model picks (stored per account in `UserDefaults.app`) | main, MenuCards, Settings, Solo, Meeting, Peer (auto pick by usage) | none | mode2 "menu bar …", "plain chat (auto pick 10% …)", testCloudModels |
| Token counts from the CLI logs (read only), by UTC hour, model, session and working folder (kept in `token-usage.json`, version 3): a Claude message once with each field at its highest (a grown later line adds only the rise, in its first line's hour; one counted in another file is not counted again); a Codex session (the UUID in its file name) up to its highest running total once wherever it is (sessions, archived_sessions, `.jsonl.zst` read by the module's own zstd decoder, copies), reasoning a part of output; Gemini (agy) model steps with no account; only new lines read later; a rewritten log counted from what it has now; a deleted log keeps its sums; the older format's deleted logs stay as day sums (`legacy`) and their archived copy adds only what came after; unused tool folders = outside the app split by the program that wrote them; app calls without a log (Claude `--no-session-persistence` asks `--output-format json`, Codex `--ephemeral` asks `--json`; plain text still answers) recorded once from the CLI's usage with `RunConditions.usageKind` (`token-usage-app.jsonl`) | TokenStats window, Answerer | "a Claude message split over lines counts once …", "a grown message adds only the rise …", "a message already counted in another file …", "a Codex running total …", "the archived .zst copy of a session adds only what came after", "a copy of a session adds nothing", "a broken .zst …", "a deleted log keeps its sums", "a rewritten log …", "Gemini's model steps are counted with no account …", "outside the app …", "app calls without a log are counted once …", "the older format's deleted logs stay as day sums", "an archived copy of an old-format session …", "a worktree's project is its repository" | testTokenStats, testRunConditions (the added output flags) |
| Every Mac's ledgers (TokenSync, version 2): each Mac writes only its own whole file with a revision; syncing again changes nothing; a correction replaces the old copy; a half-synced file keeps the last whole copy; version 1 files read as day sums; a session on two Macs counts once (`TokenLedger.together`) | TokenStats window | "another Mac's ledger comes back whole …", "syncing again changes nothing", "a correction (fewer tokens) replaces the old copy", "a half-synced file …", "an older app's daily sums …", "a session on two Macs counts once …" | testTokenStats |

Public names and why (everything else stays internal: `Answerer.chatDir`/`askOnce`/`launchForTests`/`replyForTests`,
`StreamParser`, `NativeSessions.split`/`load`/`save`, `CloudModels.apply`/`noteSeen`, `ClaudeUsage.binary`, the HTTP
streams `LocalStream`/`PullStream`, `LocalModel.ask` and the Ollama requests):
- `Answerer.ask`, `Answerer.Failure`, `AnswerProgress`: the one way in, its result and its progress (every caller).
  `AnswerProgress.model`: actual ID from the answering call (Claude stream, Codex thread log/current turn_context,
  Gemini conversation log/final PLANNER_RESPONSE; Codex assistant event as fallback). Sent once before success;
  empty means checked but unavailable, nil on older stored replies remains absent. The chat saves it beside the name.
  Visible stateless Codex answers omit --ephemeral so the CLI retains its model log; auxiliary calls keep it.
  Log attribution is read only, ID-bound and bounded to 4 MiB plus the first metadata line; ambiguous or missing logs
  never reuse another call. Checked by testCloudModels fixtures and runtime_contract fake subprocesses (including Gemini).
- `RunConditions` (all seven fields, `init()`) and `RunConditions.Folders` (an explicit `init`): the app builds them
  (`RunConditionsApp.swift`); the fields are what the caller decides. `steering` is set by the chat (`Discussion.steered`)
  for the one AI answering alone.
- `SteerChannel` (`init`, `live`, `offer`, `close`, `onRead`): the chat hands messages sent while it answers to the running
  answer and gets back what was read and what was not; strings only, so the runtime knows no chat type. Its call side
  (`attach`, `detach`, `tools`, `read`) and `SteerLink` stay internal.
- `Answerer.toolForTests`: the only public test hook, so `runtime_contract.swift` can run a fake CLI from outside; the
  app never sets it (run_mode2 stage 1 checks that no app file names it).
- `DebateCancellation` (`init`, `isCancelled`, `child`, `attach`, `detach`, `cancel`, `end`): the app makes the tokens
  and stops its own processes the same way (project commands in ProjectWork, document reading in MaterialReader and
  Workspace, the updater).
- `NativeSessionCall` (the type only: `ask` hands one to the caller's closure, which passes it back), `NativeSessions`
  (`init`, `ask`, `directory`, `eligible`, `pinnedAccount`, `reset`, `purgeRoom`, `turnMarker`: AIChat's instruction puts
  it between the chat's fixed rules, which a session takes as its system prompt, and the turn's own part).
- `ReplyHeadline.split`: the chat's headline and the session's own block must cut a reply the same way.
- `ToolHome` (`path`, `agyInstalled`): where the tools live (the user's home, not the test home); `Login` and Settings.
- `GeminiLinks` and `toolNote` (what agy is told in plain chat): `Workspace.swift` adds the workspace note and
  `RunConditionsApp.swift` agy's web rule (`allowWeb`, it writes agy's settings) to the same type; `RunConditions.beforeStart` is how the app runs that
  rule just before the tool starts, so the runtime changes no permission itself (review, 2026-11-11).
- `CloudModels` (`model`, `set`, `valid`, `Choice`, `claudeChoices`, `codexChoices`, `loadGemini`, `seenKey`, `seenTitle`):
  the Settings model menus. `versionTitle`: formats Claude versions in Settings; chat replies preserve the exact ID.
- `LocalModel` (63 names: variants, the catalog and its entries, fit by memory, Ollama's library, installed/loaded
  models, pull, delete, keep-alive, the gate, `server` for mode2's fake server) and `LocalUsage.read`: the Settings
  Ollama section, the Ollama window, the menu and the Route sorter use all of them. It is the largest public part:
  model management came with the file (`Local.swift`); splitting it from running is a later step.
- `AIUsage`, `UsageWindow` (fields, `left`, `leftNow`; no public inits: only the module makes readings; `checkedAt` is
  readable (`internal(set)`) so AutoPick can keep the 10% bar for a reading 30 minutes old or older),
  `CodexUsage`/`ClaudeUsage`/`GeminiUsage` (`read`, `forget`; `CodexUsage.binary` for the Codex login): the menu.
- `TokenLedger.read` → `TokenReport` (`entries`, `folders`, `readAt`), `TokenEntry` (fields, `init`, `Origin`, `Source`), `TokenFolder` (fields), `TokenCounts` (the four counts, `reasoning`, `init`, `fresh`, `total`, `isEmpty`, `+`, `+=`): the Usage window (App, TokenStats.swift) groups the sums by period, account, model, project, chat, session, Mac and source, so the sums and their counts are public values with inits (its test builds them); reading the logs stays in the module. `TokenFolder` tells the window "no log" from "nothing used" (files, compressed, unreadable, deleted, older format, first and last).
- `TokenLedger.recordApp`: Answerer records the calls that leave no log itself; it is public for runtime_contract's check of the CLI replies it reads. `RunConditions.usageKind`/`tagged(_:)`: the chat side says what a call is for (routing, meeting, attachment, picture, ask_ai, space) without the runtime knowing those features.
- `TokenLedger.projectRoot`: a Git worktree's or subfolder's repository, the filesystem rule the window groups projects by. `TokenLedger.together`: every Mac's sums with a session copied between Macs counted once (the rule is the ledger's, the window only shows it).
- `TokenSync` (`exchange`, `cached`, `removeMine`), `TokenDevice` (fields, `init` for the window's test): the window adds up every Mac. The app names this Mac's sums by account (`TokenEntry.accountName`; account ids differ on each Mac, so the same provider and name is the same account) and passes the folder and id of chats from other Macs (AIChat's DeviceSync, which the module cannot import); writing this Mac's file and reading the others' whole stays in the module.

### AIWorkspace (`app/modules/AIWorkspace/`: Workspace, WorkspaceBackup, AutoGuard, Tools, DiskUsage)

O3 test hook: the bundled Python bridge accepts `AI_ILLUMINATI_TEST_BRIDGE_TIMEOUT` (finite, positive seconds) for
its ordinary named-tool socket limit. `testProjectWork` uses 1 second only in its child bridge and delays the command
2 seconds, preserving the long-command exemption check. Defaults remain 15 seconds (ordinary), 3610 (long tools),
65 (Drive), 125 (outside MCP). Invalid values and tool inventory requests keep 15 seconds. No Swift public name is
added, so `docs/api` snapshots stay unchanged and S1 still checks them. `test_workspace_mcp.py` checks the override,
inventory, invalid values and default; the app test checks the real bridge and app socket together.

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
| Backup before writes: refuses overlapping folders or one holding the backups; lists what the answer added, changed, deleted; Undo puts back exactly that, once, and refuses (writing nothing) after a later change; a deleted chat's backups go | Solo, ProjectChat, Collaboration (`begin`, `finish`), Attachments (`restore`), Discussion (`purgeRoom`, `finishLeftOpen` at launch), Peer, ProjectWork (`stamps`) | "the backup lists what changed", "a backup left open is finished later", "Undo puts back …", "an Undo runs once", "a refused Undo writes nothing", "nested folders …", "a deleted chat's backups go" | mode2 "backup, actual add/edit/delete list, conflict refusal and exact hash undo", "backup by size and time, cloud-only …", "chat delete removes only its sessions, … backups and git marker" |
| Clean-up of old backups (age, count, restored, a deleted chat's after a day, in use and newest kept); it tells a deleted chat by `supportDir/chats`, the app's `ChatStore.dir` | Settings (`cleanUp`, `Policy`), main (`startAutomaticCleanUp`), every `finish` | none (needs aged folders) | mode2 "backups keep changed files only, … cleanup by age/count/restored/deleted chat …" (and `WorkspaceBackup.chats == ChatStore.dir`) |
| Save format: a chat's `workspace` (`WorkspaceBinding`, `WorkspaceRoot`, `ProjectBinding`, levels, `ToolOrigin`) and a backup's `complete.json` keep their keys; absent fields left out; older ones read | Discussion (chats/*.json), Todo (lists), ProjectWork, every `load` | "a chat's workspace keeps its saved keys" (golden), "an older workspace reads", "an older backup reads", "complete.json is private" | mode2 "legacy decoding", testTodoStore (saved and read back) |
| Errors: an NSError (domain `Materials`, code 1, the same texts) the callers show as they are | Solo, ProjectChat, Attachments (notes) | "the refusal names the backup" | mode2 conflict refusal |
| Disk sizes: lstat blocks, links not followed, a hard link once across calls with one `seen` | ChatStorage (`report`), clean-up (`bytes`) | "a hard link counts once", "… not counted again across calls", "a missing path counts as unreadable" | mode2 "storage by chat, …, hard links once" |
| Tool gateway's types: `ToolProvider.tools(context:)` defaults to `tools()`; `ToolContext` carries the room, roots, run, asker, turn, origin | ToolHub and the 14 providers (app files) | none (types) | mode2 tool tests (ask_ai, meetings, chat tools, memory, Drive, outside MCP) |

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
- `WorkspaceBackup` (`begin`, `finish`, `finishLeftOpen` (since 2026-11-16: a backup whose answer never ended, the app quit,
  finished at the next launch so its changes list and Undo works; Discussion `recoverInterrupted`), `restore`, `load`, `purgeRoom`, `stamps`, `digest`, `base`, `directory`, `roots`,
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
`SidebarProjects.swift` and `ProjectSnapshot` (Peer.swift, the review).
TODO usage bar: `AutoPick.need(window:kind:purpose:now:checkedAt:)` (Solo.swift) is the one rule for how much must be left. For `.todo` it lowers the weekly bar to min(10, max(3, 5 × days to the reset)) and the five-hour bar to 3 in its last hour; for `.chat` (plain and project chats, `Peer.pick`) it stays `AutoPick.threshold` (10); never above 10, and no reset time, a reset already past or a reading `staleAfter` (30 min) old gives 10. `AutoPick.surplus` (the smaller of the two left − bar) orders the TODO crew (`todoCrew`, a tie by weekly left); `choose` keeps its order by weekly left so chats pick as before; `todoBar` gives `TodoScheduler.noCrew` the lowest bar of the able accounts for the waiting text (Discussion's `noCrew`, also on the board). Tests: todo_work `testTodoUsageBar`, `testTodoCrew`; mode2 "plain chat (auto pick 10% …)". App keeps `TodoBoard.swift`, `ProjectInfoView.swift`,
`GitBranches.swift`, `ApprovalAlerts.swift`, `ToolHub` with the 14 providers in their order.

| Promise | Users (files) | Module test (`projects_contract.swift`) | User tests |
|---|---|---|---|
| TODO order: an error is counted and noted and the TODO is ready again, retried in the same chat before a TODO after it; a busy repository (`isBusy`) is not counted; after `maxAttempts` retries the user decides; every list is in order and its `RunMode` says what holds the next TODO: a result to check only `checkEach`, a question or failure every mode until the TODO is parked (`TodoItem.parked`, passed in order), while an "after" link to it waits, parked or not; a report becomes the check only when the chat ended; the next TODO starts only once the repository lock is let go, woken by `.projectReleased` (no tick) | TodoChatsApp (Discussion), main (start, quit), TodoBoard | "an error is counted and noted", "nothing starts while the repository is held", "the release starts the retry first", "a busy repository does not count", "after 2 retries the user decides", "B waits while A needs the user", "a parked question does not hold B", "the lock's release starts the next TODO" | todo_work `testTodoOrder` (through Discussion: A, its retry, then B, each start after a release, no tick), `testTodoScheduler` (retries, no report, report final at the end, busy chat waits) |
| Stand-in answer, delegation and parking by `RunMode` (`TodoList.mode`; a file without it, whatever its old `waitForDone`/`sequential`/`standIn`, reads `aiThenPark`, and only `mode` is written): `checkEach` and `stopOnIssue` never answer for the user; `aiThenPark`: a question or failure (failed retries and no report too, with a brief asking for a fix) unanswered for `standInDelay` (15 min) goes to another AI than the lead through `TodoChats.standIn`; its answer (`ANSWER:`) makes the TODO ready with a note `by` that AI (`aiHelped` += 1), a decline parks it at once, and still waiting `parkDelay` (30 min) or stuck again after an AI's help (`aiHelped` > 0) it is parked (`TodoStore.park`, `parkDue`); `auto`: a failure is parked at once, a question gets the stand-in at 15 min and the app's delegation at `autoAnswerDelay` (30 min; at once when asked again after an AI's answer) (`delegateAnswer`: the recommended answer or its own call, no push/release/publish/delete/accounts/secrets/money, check the current state first) with a note `by` "앱 자동 위임", stopping a stand-in still running, and a failure after the delegation is parked; the card's 알아서 해 delegates at once ("사용자 위임"); parked keeps the question (the user may answer later), is lifted by an answer, a retry, done, cancel or a new question, and its next attempt is told to check the current state first (`wasParked`); all timed from `stateSince`, so a restart keeps them; once each per question (`standIns` 0/1/2, a new question starts at 0); `aiHelped` cleared by the user's answer, check or done; asked again right after a delegation (`delegated`): the recommended answers go on once, then the question is failed; a late answer, delegation or park is checked again in the save (`needsYou`, the same `TodoQuestion.id`, the list's mode still allows it); the ask still running is cancelled (`token`) once the user answers, the TODO moves on, is parked, stopped or marked done, or asks again; a failed ask is retried after `standInDelay` for that question only; nothing while the user wrote in the TODO's chat since the question (`TodoChats.userWrote`); Pause holds what is answered or passed; the card shows "another AI is answering" while it runs (`TodoScheduler.standingIn`), the minutes to each next step, or the parked badge; an answered TODO goes back in board order | TodoChatsApp (`Peer.pick`, read-only `peerView`, `userWrote`: turns, queued and steering messages), TodoBoard (mode menu) | none | todo_work `testTodoStandIn`, `testTodoRunModes`, `testTodoReadyOrder` |
| Chat messages: a message in a TODO's own chat while it does not run goes to the TODO (`chatMessage`: needsYou → `answer`, review → `requestChanges`, draft/ready → a feedback note and ready; pictures become attachments) and the next attempt starts in that chat at once when it may, the message shown first (when it cannot start, the message stays in the chat as a saved turn answered by a note; a failed save keeps it in the message box); queued messages go the same way when the attempt ends; done/cancelled TODOs and read-only ways (one, all, meeting) stay plain chat | Discussion (`send`, `flushQueue`, `sendToTodo`) | none | todo_work `testTodoChatMessage` |
| Scheduler limits: drafts wait for Start; one answering place stays free; a TODO's own chat; Stop cancels and stops the chat; after a quit running TODOs are ready, interrupted, one attempt counted | main, TodoBoard | "drafts wait for Start", "one of the places stays free", "Stop cancels a running TODO", "restart" | `testTodoScheduler`, `testTodoTime`, `testTodoPause`, `testTodoFailureRecovery` (a fake CLI killed, its retries and the Retry badge, the app quitting mid-run) |
| Mark as done: `markDone` from any state but done (draft, ready, needsYou, review, cancelled at once; running: saved done first, then `TodoChats.stop`, so settle passes it), question/report/stand-ins cleared, clocks closed as on any change; done again changes nothing; the TODO below and those waiting by "after" go on; todo_edit `state: "done"` (alone, the list's lock checked; another chat's running TODO is stopped, the TODO's own chat's answer just ends) | TodoBoard (row ⋯ and right-click, cards), the sidebar's ⋯ (`Discussion.markTodoDone`), todo_edit | "mark done stops a running TODO's chat", "settle does not turn a TODO marked done back" | `testTodoMarkDone`, `testTodoEditTool` (done from any state, lock, own chat) |
| Save format: todos.json pretty with sorted keys, older files read, an unreadable or newer file held and never written over; project-info.json the same | TodoBoard, Todo tools, ProjectInfoView, Solo (rules) | "todos.json keeps its shape", "reads back", "an unreadable todos.json is held" | `testTodoStore` (held unreadable files, older files, failed save), `testProjectInfo` |
| Repository lock, two layers: one writer per Git work tree (`--show-toplevel`; two work trees of one repository are written at once; `isHeld` is per work tree) and per documents folder, across app instances (lock files, refused at once), shared locks above; GitLink's commands that change shared refs (branch, switch, merge, fetch/pull, push, the turn's push, stable) take a short "refs:" lock per common dir while they run (waiting up to 60 s), commits do not; `git_branch`/`git_switch` refuse `sub/` branches; refusals say `busyKorean`/`busyEnglish` ("this folder"), and `isBusy` still knows the older texts | Discussion (every writing answer), TodoChatsApp | "a second writer is refused", "released" | `testProjectWork` (repo locks), `testWorkTreeLocks` (two work trees, refs waits, commits pass, another instance's lock file, sub/), `testDocumentsProject` (one writer per folder), `testTodoScheduler` (folder lock) |
| Sub-room work trees (`SubWork`): made outside the repository (app folder `worktrees/`, a test home in tests) on `sub/<split>/<n>` from a clean main HEAD; merged only when reported, its tree not being written, the SHA after the start and on its branch, main clean; conflicts checked against the current HEAD with `merge-tree --write-tree` and returned without merging; files outside the owned ones only warned; `--no-ff`, only a merge it started is aborted; `resync` leaves conflict markers in the sub-room's tree; removed with its branch only once merged and pushed and clean; no stash/reset/force; `sub/` is never pushed | AIChat (P2: delegate tools, split record) | none | `testSubTrees` |
| Sub-room turns (P2): `isSubRoom` runs list and run no git_pull/git_push/git_publish_stable/git_branch/git_switch; `report` only a clean tree's HEAD after the start; `leftover`/`halfMerged` read what a restart left; `discard` removes an unmerged tree and branch (the user's choice); `project_run` one at a time per repository, the others wait in line ("run:" lock file) | AIChat (`Delegate.swift`, ProjectChat) | none | `testDelegate` |
| Scoped tools: `work_plan`, `task_done`/`task_ask`, Git tools only for the live attempt of the run's own chat; a new attempt or the run's end ends the earlier tool sessions (`revokeTools`); documents projects get `project_run` only | ToolHub (14 providers, order unchanged), ProjectChat | "the live attempt gets its tools", "an earlier attempt, another chat and the global list get none", "a new attempt ends the earlier attempt's tool sessions", "a finished run is gone" | `testProjectWork` (scoped tools), `testProjectHandoff` (old-token revocation), `testTodoScheduler` ("task tools only in the TODO's own chat") |
| Git work: fixed argv, no hooks, explicit commit paths, push only main/feature/fix/codex, in a project chat (plain or TODO) one push by the app when the turn ends well (after the review and its fixes; a failed push is the turn's error, the commits stay local), stable only through the card with the exact SHA, `project_run` only registered commands, approved commands checked unchanged, AutoGuard's environment in full auto | ProjectChat (`runProjectSolo`) | none (needs a repository with a remote: app tests) | `testProjectWork`, `testFullAuto`, `testWorkTiming` |
| The work binding: execute, writable only in the project's root and the chat's folder | ProjectChat | "work binding" | `run_conditions.swift` (ProjectChat's own run in the golden file) |
| Approvals: one list for every place, a decision clears them all, 15 minutes unanswered is no and leaves a note | ProjectChat views, ApprovalAlerts, ExternalMCP, ProjectCreator | none | `testProjectWork` (expired, twice), render_chat |
| New projects: card first, folder + first commit + GitHub + push, asking again continues the same plan; folderless and documents kinds | ProjectCreate (menus), ProjectMakerLink | none (needs a fake gh) | `testProjectCreate`, `testDocumentsProject` |
| Project memory (ProjectMemory.swift): one note set per project (`groupKey`) in `projects/<id>/memory.json` under the support folder (a test home in tests); notes are added or replaced, never edited in place (the old one archived and linked both ways), a duplicate active note is not saved again, every change is one line appended to `memory-history.jsonl`, which is the record (the notes are its lines replayed, memory.json a copy; a line cut off by a crash is dropped, a damaged history refuses every save); the user edits, pins, archives, restores and undoes any change or a whole meeting cleanup (`batch`; refused when the note changed since), each one more history line; only the user deletes for good, which blanks the text in both files and keeps a hash `mark` that refuses the same words from an AI or a meeting; a meeting cleanup (ProjectMemoryCleanup.swift) applies only agreed edits with evidence from its material, at most 30, folds committed logs older than 14 days into one line per ISO week (archived after 30 days), one batch, recorded in `memory-cleanups.json` | AIChat ProjectMemoryLink (tools, instruction), ChatWindow (the saved line), App ProjectMemoryView (Project info) | "project memory" | testProjectMemory, testProjectMemoryUndo |

Public names and why (everything else stays internal: `ProjectError`, `ProjectTools`, the lock tables and files, `RunProgress`,
`RunTimings`, `TodoStore.encoder`/`decoder`/`copyIn`, `TodoData.eligible`/`hasCycle`, `TodoScheduler.begin`/`settle`/
`deliver`/`retryDelay`/`chats`/`standIn()`/`standInBrief`/`standInAnswer`, `TodoStore.standIn`, the tools' schemas and scopes):
- Saved values the board, the chats and the tools show (the save format above): `TodoItem` (its stored fields, `State`,
  `timeLine`), `TodoList`, `TodoData` (`item`, `list`, `ordered`, `blockers`, `satisfied`, `linkChoices` for the board's "must finish first" menus, `stopped`, `workers`, `standInDue` for the card's
  "an AI decides in n min" step, `autoAnswerDue` for its "handed to the AI in n min" step, `parkDue` for its "parked in n min" step,
  `mode(_:)` for a TODO's list mode),
  `RunMode` and `TodoList.mode` (the board's mode menu, saved), `TodoPark` and `TodoItem.parked`/`isParked`/`aiHelped`/`wasParked`
  (saved fields; the card's parked badge and reason, todo_list's "(parked)"), `TodoNote` (`by`: who answered in the user's place),
  `TodoQuestion` (`id`: which asking a stand-in answer belongs to; older files get a new one; `Kind`/`kind`: what the app may settle,
  `delegable` for the card's 알아서 해 button, `blocked` kept in the file for older apps, so `encode(to:)` is written out),
  `TodoItem.delegated` (a stored field: the re-ask guard after a delegation), `TodoReport`, `TodoAttachment`, `WorkStep` (a chat turn keeps the plan), `ProjectInfo`, `ProjectInfoData`,
  `ProjectFolder`, `ProjectLink`. Explicit public inits where Swift's memberwise ones are internal (`ProjectApproval`,
  `TodoReport`, `ProjectFolder`, `ProjectChatSummary`, `TodoTurnEnd`, `TodoPark`).
- `TodoStore` (the board's actions, among them `setList(_:mode:accounts:)` for the mode menu, `setReady` and `move(_:before:)` for a row's draft/ready capsule and drag, `shared`, `snapshot`, `current`, `change`, `update`, `file`, `locked`, `url`): the board,
  the scheduler's users and `Discussion` (`workers(room:)`, delete and disconnect).
- `TodoScheduler` (`init(chats:store:)`, `start`, `startNow`, `wake`, `tick`, `recover`, `closeClocks`, `cancel`, `crew`, `lock`,
  `waiting`, `nextCheck`, `editing`, `standingIn` for the card's "another AI is answering" line, `retrying` for a ready row's
  "Retry 1 of 2" badge and its reason (since 2026-11-16), `question`, `instruction`, `threshold`, `maxAttempts`, `standInDelay`, `chatMessage` for a message
  the user writes in a TODO's own chat, `markDone` for [Mark as done] on the board, the sidebar and the cards, which must stop a
  running TODO's chat, `delegate` for the card's 알아서 해) and `TodoChats`, `TodoPhoto`,
  `TodoTurnEnd`, `TodoStandInReply`: how the chat side plugs in (P0; `TodoChats.standIn` has a default that asks nobody and `userWrote` one that says no, for fakes). `TodoScheduler.noCrew` and `init(discussion:store:)` are app extensions.
- `ProjectChatSummary`, `ProjectChats.list`: what project code may read of a chat (id, time, project, lock, the open turn);
  `TodoProject` (`all`, its fields): the board's and todo_add's project list.
- `ProjectWork` (`acquire`, `release`, `busy`, `isBusy`, `isHeld`, `busyKorean`/`busyEnglish`, `register`, `finish`, `active`,
  `workBinding`, `revokeTools`), `Notification.Name.projectReleased`/`todoNeedsUser`: the chat's writing answers, ToolHub
  (`revokeTools`, set once when it starts), ApprovalAlerts. `isHeld`, `active`, `busyEnglish`, `projectReleased`, `tick`,
  `recover`, `maxAttempts`, `startDrafts`, `url` and TodoItem's `attempts`/`notes`/`report`/`interrupted` are public also so the
  contract can watch the state changes from outside (nothing else of the module was opened for a test).
- `ProjectRun` (the turn's capability: `init`, `nextAttempt`, `endAttempt`, `validate`, `checkpoint`, `setPlan`, `setAppStep`,
  `note`, `log`, the `on…` callbacks, `generation`, `attempt`, `deadline`, `committed`/`pushed`; `deferPush`/`pushWanted`: a project chat (plain or TODO) sets `deferPush`, git_push only asks, and the chat reads `pushWanted` at the turn's end), `ProjectProcess` (`run`,
  `git`, `inspect`, `documents`, `Reply`), `ProjectCenter`, `ProjectApproval`, `ProjectRules` (`read`, `Part`),
  `ProjectInfoStore`, `ProjectCreator` (`prepare`, `create`, `createFolderless`, `folderlessBinding`, `summary`,
  `defaultLocation`, `Plan`): `runProjectSolo`, the menus, Project info, the review (`ProjectSnapshot`).
- `ProjectApproval.command`/`same` and `ProjectCenter.preapproved` (sub-room P3): a project_run card carries its command line and
  its `CommandIdentity` key (executable's real path, arguments, work tree, `.ai-illuminati.json` bytes, permission, and the bytes of every script in the tree and of the folders of the files it names),
  so the chat can gather a sub-room's card in its main room and let the very same command through for that split; the hook is
  asked before a card is shown.
- `ProjectBinding.groupKey`: one project across its worktrees (`SidebarProjects.key` forwards to it).
- Project memory (2026-11-19): `ProjectMemoryNote` (its stored fields, `Kind`, `State`, `init`), `ProjectMemoryChange` (a history
  line), `ProjectMemoryStore` (`shared`, `notes`, `history`, `add`, `replace`, `Outcome`, `textLimit`, `revision` for the chat's
  "saved to project memory" line): AIChat's three tools and the instruction read and write notes only through it, so the store
  alone owns the files, the archive rule and the history (the info tab and the meeting cleanup will use the same names).
- Project memory 3 (2026-11-19): `ProjectRun.memoryWorkers` lets AIChat enable automatic Git completion logs only outside Enterprise rooms; `ProjectMemoryNote.commits` stores full hashes for durable deduplication. `ProjectWork.finish` records new commit-creation entries from HEAD reflog (excluding pull/checkout/reset) as one log without an AI call, including local TODO piece commits. Log identities survive edit/archive/delete; automatic logs are sent for 14 days even when pinned. Tested by `testProjectMemory` through real fixture Git commits and completion, no-commit, repeated completion and reload/delete cases.
- Project memory 4, cleanup saving (2026-11-19): `ProjectMemoryEdit` (`Kind`: merge, fix, shorten, archive, add, verify,
  resolve; `ids`, `keep`, `text`, `noteKind`, `verified`, `evidence`, `agreed`, `init`), `ProjectMemoryCleanupRecord` (`Dropped`,
  counts, `deferred`, `attendees`, `manual`), `ProjectMemoryCleanup` (`apply`, `Outcome`, `records`, `last`, `due` and its limits
  `maxEdits`/`logDays`/`weekDays`/`interval`/`minAnswers`/`fullShare`), `ProjectMemoryStore.budget`, `ProjectMemoryChange.evidence`:
  AIChat's cleanup meeting hands its edit list to `apply` and the info tab reads `records`, so the checks (evidence from the
  material, agreement, deleted marks, the 30 limit), the weekly fold of old work logs and memory-cleanups.json stay in the
  store's module; one cleanup is one history `batch`, undone with `undo(batch:)`. Tested by `testProjectMemoryUndo` (its
  cleanup part).
- Project memory 2 (2026-11-19): `ProjectMemoryNote.State.deleted`, `ProjectMemoryChange` `by`/`batch`/`others`/`undoes`/`marks`/`who`/`notes`,
  `byUser`/`byMeeting`, `ProjectMemoryStore` `edit`, `setPinned`, `archive`, `restore`, `delete`, `undo(_:project:)`,
  `undo(batch:project:)`, `undone`, `mark`, and `add`/`replace`'s `by:`/`batch:`: Project info's memory section (App) shows the notes
  and history and changes them only through the store, so undo, delete and the deleted-text marks stay in one place.
- C0, logic moved down from the chat's `extension Discussion` blocks: `ProjectWork.linking` (a chat links a project: the
  root writable, after the linked folders or first for documents), `ProjectWork.moving` (a chat moved into a project;
  `SidebarProjects.moved` forwards), `ProjectRun.setPlan(todos:generation:)` (the stream's TodoWrite list read here, so the
  chat no longer names `PlanLink`), `TodoStore.lockProject` (a locked project's TODO lists).
- The five providers (`shared`, `ToolProvider`'s members; `GitLink.pushDeferred` for the one push at the end of a project turn, after the review and its fixes; `ProjectMakerLink.cancellation`/`addChat`, `TodoAddLink.store`/
  `names` as before): ToolHub lists them in its order.
- Stable publish screen API: `GitLink.publishStable(_:room:onWaiting:)` is public so the App project screen can publish without an AI turn. It acquires the existing repository lock and reuses the Git tool's exact-SHA approval path; its waiting callback updates the screen. The shared publish path fetches first, preserves publishing the exact local main SHA, rejects divergent stable, and supports the first stable publish. `projects_contract` checks approval, refusal, exact SHA and lock release against a temporary local remote.
- Pull main screen API: `GitLink.pullMain(_:)` is public so the App project screen can pull main when its refresh finds main behind origin/main. It holds the repository lock (no pull in the middle of an AI's work) and keeps `git_pull`'s rules: main checked out, clean tree, `pull --ff-only`, never stash/reset. `projects_contract` checks dirty, other branch, busy lock, fast-forward and diverged cases against a temporary local remote. No graph change.
- TODO split execution (AIChat): `ProjectRun.noPush` skips step reviews and deferred pushes, `isTodoPiece` omits
  delegation for the whole group, `todoWasSplit` ends the original turn before review/push, and `todoReviewBase()`
  returns the stored review base to the finish and records HEAD at the first step for splits without a base. The initializer's `todoSplitFullAuto`
  argument supplies the chat's approval mode to the TODO split decision.
  `ProjectRun.usedSubRooms` is set by `Delegate.swift` when delegate_plan opens sub-rooms, so `task_split` refuses a TODO that already
  uses sub-rooms (a TODO uses one of the two, docs/TODO_SPLIT_PLAN.md 1.5).
- TODO split screens (App, docs/TODO_SPLIT_PLAN.md 1.5 step 4): `TaskLink.splitEnabledKey`, the key Settings ▸ Chat's "Let the AI
  split large TODOs" switch writes (off by default; the module reads it). `TodoData.splitLine` and `TodoSplitLine` (`Piece`):
  a board row's place in its split, the pieces done, a stuck step, and the plan's estimate, reason, finish done-when line and
  files, read-only, so the board never sees the split fields themselves. `TodoStore.unpushedPieceCommits` counts the steps'
  own commits on no remote (git, called off the main thread) for "push 안 된 조각 커밋 n개": each step run's HEAD at its start
  (`todoReviewBase`) to its end, which the chat records with `ProjectRun.todoPieceEnded` before it lets the repository go, so
  another chat's commits between the pieces are not counted.
  `TodoStore.restartable` / `restartStep`: the board's "다시 시작" on a cancelled step of a split that is still open (ready
  again, its finish goes on); `setReady` keeps refusing cancelled TODOs.
- Sub-room P2 (AIChat's `Delegate.swift` uses them): `ProjectRun.isSubRoom` (set by the chat for a sub-room's turn: GitLink then lists and runs no git_pull/git_push/git_publish_stable/git_branch/git_switch),
  `ProjectWork.run(for:)` (another module's tool provider finds the live project turn of a tool call, with the same room/generation/cancel checks as GitLink),
  `SubWork.report` (sub_report: the work tree's HEAD only when everything is committed, and the files changed since the start),
  `SubWork.leftover`/`Leftover` and `SubWork.halfMerged` (the restart check: folder, listed work tree, branch, half-done merges),
  `SubWork.discard` (the user's Discard: work tree and branch go also unmerged, its last SHA returned; the only forced Git step).
  `project_run` waits in line per repository (a "run:" lock file per common dir) so tests in two work trees never run at once.
- Sub-room Git work (SUBROOM_PLAN 3, 5; P2's split record and tools in AIChat call it): `SubWork` (`create`, `remove`, `merge`, `resync`), `SubWork.Tree` (`path`, `branch`, `base`, Codable: the split record saves it) and `SubWork.Merge` (`merged`, `conflicts`, `outside`, `head`: what git_merge_sub tells the main room). Work trees under the app folder's `worktrees/<repo hash>/<split>-<n>` on `sub/<split>/<n>` from a clean main HEAD; every step inside the refs lock and the sub-room's work tree lock; merge checks with `merge-tree --write-tree` against the current HEAD, `--no-ff`, aborts only a merge it started; removed only when merged and pushed. Test: `testSubTrees`.

### AIChat (`app/modules/AIChat/`: ChatRecords, SyncSnapshot; ChatValues went to AIChatRecords in T4), step C1a
A chat's record and where it is kept: `Conversation` (chats/<id>.json), `ChatTurn` and `ChatTurn.Entry`, `ChatConfiguration`,
`ChatStore` (`dir`, `loadAll`, `save`, `delete`, `links`), a synced copy's `SyncSnapshot` (it holds turns; `SyncSnapshot.swift`) and the
record's helpers (`ChatTurn.Entry.reply`/`shortLine`, `ChatTime`, `SpeechLength`). `ChatTurn.finalModel` and
`ChatTurn.Entry.model` (optional, so older chats open as they were): the model a reply ran on when its output named it,
kept apart from `finalBy`/`speaker`, which colors and speaker matching read. Moved as they were: the declarations are
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
| Pictures at <id>.assets/<picture id>.png, a bad picture refused (since T4 `ImageStore` is in AIChatRecords; this contract still checks it through ChatStore) | Attachments, Pictures, TodoChatsApp | "a picture lives in the chat's .assets folder", "a bad picture is refused" | mode2 attachments ("deleting chat must remove copied images") |

Since 2026-11-13: `Conversation.queued` (`[QueuedMessage]`, messages sent while it answered, as typed) and
`ChatTurn.followUps` (messages its answer read while it ran) are optional fields, so older chats read as before and
are saved without them; `QueuedMessage` (`id`, `text`, `images`, `mentions`, `route` as a `RouteChoice` raw value, `sentAt`,
one public init) is a saved value too.

Since 2026-11-15: `ChatTurn.digest`/`digestBy`/`digestAccountID`/`digestModel` (opinion mode: one AI's summary of the
answers, Route.swift, digestOpinions) and `answersOpen` (its answers unfolded) are optional fields, so older chats read as before and a
synced copy shows the summary and the fold; `final`/`moreAnswers` keep the answers themselves.

Since 2026-11-16: `ChatTurn.cutOff` (optional): `final` is a reply cut off before its end (the CLI was killed, failed or
timed out, the usage ran out with nobody left, the app quit). The chat says so with Try again, and the next answer's context
marks it unfinished so it continues from there (Solo.swift `keepCutOff`, Discussion `recoverInterrupted`).

Public names and why: the record types' stored fields and their inits are the save format (every reader and writer of a
chat uses them; Swift's memberwise inits are internal, so each type got one public init with the same order and defaults);
`ChatStore` and `Links` (C0's seam, set by `ChatLinksApp.connect`); `SyncSnapshot.version` (DeviceSync reads copies; `ImageStore`,
`RemoteChat.Status` and the other values moved to AIChatRecords in T4 with these reasons); `ChatTime.stamp`/`day`/`when`,
`SpeechLength` (the chat window and the discussion modes); `Entry.reply`/`shortLine`. Internal: `ChatTime.calendar` (the
boundary check), `ChatTime.format`.

C1a falsification table: `docs/modules-history.md`.

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
- `ChatSettings` (protocol, `AppModel` conforms: `extension AppModel: ChatSettings {}`): the 15 settings the chat reads
  (accounts, usage, chat rules, local model, picture makers, team picks, collaboration, opinion digest, shared folders); `Discussion(model:)`
  takes it, `ChatView` is generic over it so the window still observes the settings.
- `ChatApp.run` = `RunConditions.app` (RunConditionsApp.swift), `ChatApp.face` = FaceLink's extract/show/active/moods/rule,
  `ChatApp.driveRule` = DriveLink's rule while on: set in `ChatLinksApp.connect()` (main.swift and mode2, as in C0).
- `ChatApp.screens`: the TODO board (row, board, a chat's cards), Project info and its rename, the icon, `manageItems`
  (2026-11-16: the app's items atop the sidebar's Manage chats menu, now Connect iPhone in PhoneAccess.swift):
  set in the new `ChatScreensApp.connect()` (main.swift after ChatLinksApp, stage 1 checks the place; the chat preview too).
- `FolderSources` / `FolderSource`: outside folder kinds shown in the sidebar's Shared folders after the local ones (their
  + menu item, rows and folder count); Google Drive's is registered in `ChatScreensApp.connect()`. Only the list is joined,
  each kind keeps its own storage; another cloud is one more entry.
- `toolFailure` is the module's copy of `ToolHub.failure` (the same reply shape); `RunConditions.app` inside the module forwards
  to `ChatApp.run`, so the chat's calls read as before.

Stays in the app (what the user sees of other parts): Settings (all tabs, Memory/Rules/Storage windows), TodoBoard, ProjectInfoView,
GitBranches, DriveUI/DriveLink/GoogleAuth, ExternalMCP/RemoteMCP, FaceLink, ToolHub (the 14 providers in their order, stage 1
checks the list), ApprovalAlerts, MenuCards, main, Login, Updater, Icon, LocalModels, RunConditionsApp, ChatLinksApp,
ChatScreensApp. Two app edits besides imports: `StorageListView.measured` (one string the compiler could no longer type-check
inline once the names came from another module; same text) and the `AppModel` conformance line.

Public names and why (found by the compiler, not by hand: a script opened only what an app file or a public protocol asked for;
everything else, Discussion's state above all, stays internal):
- Discussion (about 30 of its members): `init(model:)`; what main.swift does with the chat (`open`, `current`, `anyRunning`,
  `cancelAll`, `discardPendingImages`, `draftsFile`/`saveDrafts` (2026-11-15: main.swift says where each chat's unsent message
  box is kept, the app's own `drafts.json`; tests leave it nil and keep boxes in memory; quitting writes them), `unreadFile` (2026-11-16: main.swift says where "Needs review" is kept, the app's own `unread.json`, this Mac only; tests leave it nil), `importingMaterials`, `fillSpaceLocks`, `runningRooms`/`stoppingRooms` and their
  publishers); what the app's screens show (TODO board: `conversations`, `conversation`, `currentID`, `label`, `openBoard`,
  `viewingBoard`, `boardProject`, `hover`/`hoverKey`, `model`; Project info: `listedConversations`, `showBoardTab`,
  `disconnectProjectFolder`, `openTurn` (2026-11-19: a project memory note opens the chat and message it was written in); approvals: `approvalChatName`, `viewingRemote`, `approvalHome` (sub-room P3: a sub-room's request is answered and
  noticed in its main room, ApprovalAlerts); `markTodoDone`: the board's and cards' [Mark as done],
  the same confirmation as the sidebar's ⋯); `TodoChats` (P0's seam, all its members);
  `Discussion.meets`/`autoPicked` (Settings' team picks).
- The six tool providers (`shared`, `active`, `tools`, `call`; `MemoryLink.newestTurn` for ToolHub.register): ToolHub lists them
  (`DelegateLink` since sub-room P2).
  `DelegateLink.enabledKey`/`enabled`: Settings ▸ Chat's "Split into sub-rooms" switch (off by default) writes the key the module reads.
- `Conversation.subOf` and `SubRoomLink` (`room`, `split`, `n`, one public init): a sub-room's chat record says which split it works
  for, so it is saved with the chat like `meetingOf` (the chat window and synced copies read the record type).
- Settings' tabs: `MemoryStore`/`MemoryItem`/`MemoryData`, `ChatStorage` (`report`, `items`, `format`, `Report`, `Room`, `Kind`; AIChatRecords since T4),
  `CollabMode`/`CollabLog` (AIChatRecords since T4), `RouteSorter`, `ApprovalAlertSettings`, `AIColors` (each AI's color: the color window changes what `Account.Provider.color` draws; `revisionKey` lets their views redraw), `AIColorWindow` (`show`, `menuTitle`: Appearance's "Change…" and the usage menu's "Change <AI> Color…" open the same window as a right-click on an AI's name in the chat), `DeviceSync` (settings, start, scan, the notes the links call; `deviceID` and `deviceName`: the Usage window puts this Mac's token ledger in the same folder under the same id and name, so a Mac is one Mac in both; `offerConnection`, `onlineHosts`, `checkOnline`, `RemoteConnection` (`init`) and the settings' `shareConnection`/`sharesConnection`: the app's phone page (PhoneAccess.swift) hands over its address and Tailscale's online Macs, which the module cannot read, for Other Macs → connect in MacConnect.swift),
  `ChatLink.conversations`; the board and Project info: `SidebarProjects` (`key`, `group`, `pickerName`), `ProjectGroup`,
  `SidebarFold`, `BoardTab`, `PictureDrop`, `Enterprise.permits`, `ProjectLockSection` (Project info's lock setting; the lock stays the chat's), `AutoPick.fiveHour`/`weekly`, `TodoItem.State.title`/`color`;
  DriveLink: `MaterialReader.read`, `RoomDocuments.directory` (AIChatRecords since T4); main: `ChatWindow`, `SpaceRefiner.watchLibrary`,
  `ApprovalListView`; everyone's views: `PlainHitButtonStyle`/`.plainHit`, `SidebarHeader`.
- `ChatSettings`, `ChatApp` (and `Face`, `Screens`), `FolderSources`/`FolderSource`: the seams above.
- `ProjectMemoryCleanupLink.runIfIdle(in:project:manual:)` lets the app's timer and Project info start a cleanup on the
  main thread. It returns whether a hidden meeting started. Manual requests bypass the automatic due condition and
  still require an idle app and two available accounts. The cleanup date marks the start of the evidence window for
  the next meeting, so work completed during a cleanup can be considered next time.

| Promise | Users | Test |
|---|---|---|
| ask_ai from an answering CLI reaches another kind of AI through the app's tool socket (ToolHub → PeerLink → Peer → Answerer), read only and unable to ask on; the reply goes back into the answer and shows as a card | ToolHub, the CLIs | `chat_cli.swift` `testChatThroughCLI` (fake claude/codex CLI, no answer hooks), testAskAI (whom: "a different kind first, even when…" added in C1) |
| A meeting runs in its hidden chat with both members' CLIs and brings the result back as the answer | ChatWindow | `testChatThroughCLI`, testPickedRoute, testMeetingTool |
| The idle app can start a hidden project memory cleanup meeting using the default team. It sends active notes, updated chat summaries, recent commit subjects and finished TODOs (at most 14 days of work), and HANDOFF.md. The meeting receives a read-only room and returns JSON to the project memory store for evidence and agreement checks. Enterprise projects keep read-only memory, and personal projects use only permitted accounts. | App timer, Project info | testProjectMemoryCleanup |
| A work answer's change is reviewed once by the other member, read only, and fixed in the same turn | ChatWindow, TODOs | `testChatThroughCLI`, testPeerReview, testDocumentsProject |
| A failure in the middle of an answer (the CLI killed, out of usage with nobody left, the network, a time-out, the app quitting) keeps the reply so far as the answer (`cutOff`) in chats/*.json, saved every few seconds while written and at quit (`cancelAll`); the chat stops showing it answering (at launch too, `recoverInterrupted`), says Try again, and Try again continues from it; the files it changed are listed for Undo, also after a quit (`finishLeftOpen`) | ChatWindow (Try again), TODOs, main (quit) | `failure_recovery.swift` `testFailureRecovery` (fake CLI, no answer hooks), `testTodoFailureRecovery` |
| The 14 tool providers keep their order | ToolHub | run_mode2 stage 1 (the exact list) |
| Sub-rooms (`Delegate.swift`, SUBROOM_PLAN 4, 6, 8): the split record `splits/<main room id>.json` is written before any work tree; at most two parts with owned files that do not overlap; a card unless full auto (then "approved automatically" on the card); a sub-room gets only sub_report/sub_blocked and no push, pull, switch, branch or publish, and cannot split again; places kept for approved sub-rooms (`subWaiting`) count against other chats and TODOs; the join turn once per split; the main room's Stop stops its sub-rooms and keeps their work trees (Continue/Discard); after a restart nothing goes on by itself and each leftover is a card once; merged work trees go after the push | ChatWindow (cards), TODOs (places), ToolHub | `testDelegate` (fake AIs: two parts → reports → merges → push → cleanup, card vs full auto, overlap and a sub-room's split refused, join turn once, Stop and Continue/Discard, restart cases, project_run in line), `testToolHub` |
| The chat runs each AI with the app's run conditions and AI Face rules | Answerer | testRunConditions (golden), testRuntimeThroughApp, mode2 AI Face link |

C1b falsification table: `docs/modules-history.md`.

Still open from C0: F7 (Space refine) is covered by the Spaces contract only; SpaceView is now in the module and in the test build,
but no app test drives a Space's change box yet.

### AIChatRecords (`app/modules/AIChatRecords/`: ChatPaths, ChatValues, RoomDocumentFiles, CollabLog, ChatStorage), step T4 (2026-11-13)
The lower layer of the chat that knows no Discussion, Route, chat window or ChatLink (the module compiles without AIChat):
`ChatPaths.dir` (chats/ in the data folder; `ChatStore.dir` takes it), the values a record holds (`ChatImage`/`ImageStore` for
<id>.assets, `RoomDocument`, `MaterialUnit`, `CollaborationTask`, `VoteBallot`, `ChatRoute`, `MeetingLink`, `SyncOrigin`,
`RemoteChat`), `RoomDocuments` (<id>.documents, dropped files, reading a document), `CollabMode`/`CollabEvent`/`CollabLog`
(collab-log.jsonl) and `ChatStorage` (the disk report). Moved with `git mv`, bodies unchanged except `ChatStore.dir` →
`ChatPaths.dir`; what leans on the chat stayed in AIChat: `SyncSnapshot` (holds turns) → `AIChat/SyncSnapshot.swift`,
`StorageLink` (chat_storage, uses ChatLink) → `AIChat/ChatStorageTool.swift`, the `extension Discussion` part of
RoomDocuments stays in `AIChat/RoomDocuments.swift` (same file name: run_mode2 C0's table). Not moved (T3: they lean on
`ChatTurn`/`Conversation`/Discussion or the chat window uses their insides): ChatRecords, DeviceSync, Memory, ChatNotes.
Depends on AIAccounts, AILocalization, AIRuntime (`NativeSessions.directory` in the report), AIWorkspace (`DiskUsage`,
`WorkspaceBackup.base`); no cycle (Workspace already uses Runtime). Users: AIChat and the App
(Settings' Storage and collaboration tabs, DriveLink), each file with its own `import AIChatRecords`.

| Promise | Users | Module test (`chatrecords_contract.swift`) | User tests |
|---|---|---|---|
| Chats live in the data folder's chats/; pictures at <id>.assets/<picture id>.png, a bad picture refused and leaves no file | ChatStore, Attachments, Pictures, TodoChatsApp, ChatWindow | "chats live in …", "picture path", "bad picture refused", "a refused picture leaves no file" | chat contract (`ChatStore.dir`, pictures), mode2 attachments |
| Dropped files are copied into <id>.documents; the readable kinds are fixed | ChatWindow (drop), MaterialReader, DriveLink | "documents folder", "a dropped file is copied …", "readable document kinds" | mode2 materials (`RoomDocuments.read`) |
| collab-log.jsonl: old lines read and written back the same (sorted keys, ISO dates); past 2 MB the older half goes; the summary counts | Peer (ask_ai, meetings, reviews, requests), Settings' collaboration tab | "an old collab line …", "a full log keeps its newer half", "the summary line counts them" | testCollabLog |
| Disk report: a hard-linked file counts once; the parts are named | Settings' Storage, chat_storage (`StorageLink`) | "a hard-linked file counts once", "the report line names the parts" | mode2 storage, testChatTools |

Public names and why: the moved types were already public (C1a, C1b reasons). New in T4, each asked for by the compiler:
`ChatPaths`/`ChatPaths.dir` (ChatStore stays above and takes its folder from here); `RoomDocuments.extensions`
(MaterialReader checks the kinds) and `keepDropped` (ChatWindow's drop); `ChatStorage.describe` (`StorageLink` stays above);
`CollabEvent.init(at:kind:chat:…:priorCalls:)` (Swift's memberwise init is internal; Peer builds events; the fields stay
internal and the synthesized `Codable` is unchanged), `CollabLog.add`, `smallTalk(_:)`, `asksOthers(_:)` (Peer).
Internal (boundary): `CollabLog.maxBytes`, `CollabLog.file`, the `Summary` counts, `RoomDocuments.read`.

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

I falsification table: `docs/modules-history.md`.

### AIRemote (`app/modules/AIRemote/`: AIRemote, RemotePage), 2026-11-17
The iPhone page (Manage chats → Connect iPhone, `app/macos/PhoneAccess.swift`): a small HTTP/1.1 server on 127.0.0.1 only
(`tailscale serve` brings `https://<mac>.ts.net/` to it) and the one page it serves. It knows no chat: the App's `PhoneServer.handle`
answers each `/api/` call from AIChat's `RemoteChats` (`RemoteChats.swift`) and
`ProjectCenter.decide`. Every `/api/` call needs the QR's key (header `X-Remote-Key` or `k`): any program on this Mac, the AI CLIs
included, reaches 127.0.0.1 and must not send messages or allow its own approvals. Depends on `AILocalization` only; used only by App.
| Promise | Users (files) | Module test | User tests (mode2.swift unless named) |
|---|---|---|---|
| A request is read only whole (head, then Content-Length bytes); chunked, broken or over `maxBody` is refused | PhoneAccess.swift | remote contract | testPhoneServer |
| `/api/` without the key (or with part of it) is 401; the page and icon need none; nothing else is served | PhoneAccess.swift | remote contract | testPhoneServer |
| The handler runs on the main queue (the chats are main-thread state) | PhoneAccess.swift | remote contract | testPhoneServer |

Public, each with its reason: `RemoteServer` (init, `start`, `stop`, `running`, `port`: the App starts it with its key and handler),
`RemoteRequest`/`RemoteResponse` (what the handler reads and returns; `json`, `error`), `RemoteHTTP` (`parse`, `authorized`, `newKey`,
`maxBody`: the contract checks them, the App makes the key), `RemotePage.html()` (the App hands it to the server).
AIChat's new public names for it (`RemoteChats.swift`, an enum, not an `extension Discussion`): `RemoteChats.list` (the sidebar's
sections as JSON values, built from the sidebar's own internal lists), `chat(_:_:opened:)` (one chat's messages, answers so far and
approval cards; opened counts as seen), `image(_:_:id:)` (a picture of that chat only) and `send(_:room:text:photos:)` (the message
box's path for any chat: queue while answering, TODO, or a new turn; photos imported like `addImage`), `search(_:_:)` (the
sidebar's ChatSearch for the page's search field) and `create(_:project:text:photos:)` (the page's new chat: a loose or project chat
made only with its first message, sent through `send`, removed again when that fails; the Mac's open chat stays).

## Records

Step records, falsification tables and dated measurements (A, M, T4, the direct AIChatRecords import, the earlier
steps): `docs/modules-history.md`, section "Moved from docs/MODULES.md (2026-11-15)" and before it.
