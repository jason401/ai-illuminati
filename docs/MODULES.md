# Modules: one Swift module per part, checked by promise → user → test

The app is one Swift program built from `app/macos/*.swift`: in it, every file can use every other file's
`internal` names, so a folder alone draws no line. A part in `app/modules/<Name>/` is its own Swift module:
it builds alone, and the app sees only its `public` names. Now: `AILocalization` (L(), AppLanguage), `AIAccounts`
(account list and folders), `AISpaces` (Spaces: saving, checks, the isolated web view) and `AIRuntime` (running each
AI's command line tool, sessions, the local model, usage readings), all 2026-11-11.

## How a module is built and used
- `zsh tools/build_modules.sh <out> [swiftc options]` builds every `app/modules/<Name>/` alone into
  `<out>/<Name>.swiftmodule` + `<out>/lib<Name>.a` (static: nothing new in the app bundle, signing unchanged).
- A module may use only the modules named in its `dependencies` file (one per line; none: no file). They are built
  first, and the compiler sees only theirs, so an import of any other module fails the build. Now
  `AISpaces` → `AIAccounts`, `AILocalization`; `AIRuntime` → `AIAccounts`, `AILocalization`; the other two use none. No circles (the script refuses them).
- Every `swiftc` that compiles app files runs it first and adds `-I <out> <out>/lib*.a`:
  `tools/build_app.sh` (compile step), `tools/tests/run_mode2.sh`, the preview scripts.
- Each file that uses a module says `import <Name>`. Not the hidden compiler option (`-Xfrontend -import-module`):
  the import line shows who uses the module (`grep -l "import AIAccounts"` lists its users), and no
  compile command needs one more flag.
- Name: `AI` + the part, never Apple's framework names (`Accounts` is one).
- `run_mode2.sh` stage "Modules on their own": builds the modules alone, runs each contract test from outside
  (`tools/tests/<part>_contract.swift`, public names only), and checks that internal names
  (`AccountStore.place`, `SpaceStore.setting`, `SpaceAssets.served`, `Answerer.chatDir`, `Answerer.launchForTests`,
  `NativeSessions.split`, `CloudModels.apply`) do not compile outside.
- Tests build the modules with `-enable-testing` only so tests can say `@testable import`: `space_build.swift` for
  `AISpaces` (module insides such as `SpaceCheck`), and for `AIRuntime` the app tests that make their own usage
  readings (`AIUsage`, `UsageWindow` inits) or use its test hooks (`Answerer.launchForTests`/`replyForTests`,
  `StreamParser`): `mode2`, `run_conditions`, `project_work`, `ask_ai`, `collab_log`, `todo_work`, `chat_search`,
  `space_build`, and the settings preview (`render_settings.sh` builds the modules with `-enable-testing` for it).
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
Depends on `AIAccounts` (`AccountStore.supportDir`: where `spaces/` is) and `AILocalization`. UI stays in the app:
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
- Chat side: `SpaceBuilder` (`split`, `parse`, `rule`, `chatRule`, `refinePrompt`), `SpacePictures` (`perAnswer`,
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
`Workspace.swift`). Stays in the app: `extension Discussion` (`requestDebate` …, later the Chat module),
`GeminiLinks.workspaceNote` (names `WorkspaceLevel`, an `extension GeminiLinks` in `Workspace.swift`),
`LocalModel.install` (opens Terminal: an `extension LocalModel` in `Login.swift`), `LocalModelStore`/the Ollama window
(`LocalModels.swift`), `Login` (its `home`/`agyInstalled` now read `ToolHome`), `ChatTurn.Entry.reply` (uses
`ReplyHeadline.split`, which a session needs too).

| Promise | Users (files) | Module test (`runtime_contract.swift`) | User tests |
|---|---|---|---|
| Starts exactly what `RunConditions` says (prefix, wrapper first, environment, folders) | every `Answerer.ask` caller through `RunConditions.app` | fake CLI: arguments and folder seen by the tool | `run_conditions.swift` (golden file, each guard alone) |
| Errors: a tool that cannot start → `missingTool`; a failed exit → `failed(<model note> + last 300 letters of stderr)`; no answer in time → `timedOut`; a picked model the account lacks names the model | Solo, Meeting, Debate, Vote, Peer, ProjectChat, Enterprise (`Answerer.Failure`) | "a failed tool's message is passed on", "missingTool", "a slow tool times out" | mode2 error and fallback checks (debate, plain chat limit handoff) |
| Stop: a stopped token starts nothing; Stop while it runs fails the answer at once (`Cancelled`, or the tool's own exit when the tool ends first: callers look at the token) and ends the tool, its group and every descendant found by parent; with `AI_ILLUMINATI_PROJECT_PROCESS=1` the whole group is killed first | Debate, Solo, ProjectChat, Meeting, Todo (tokens); project work (marker) | "a stopped token starts no tool", "Stop ends … at once", "… the programs it started", "… in a group of its own", "Stop ends a marked tool's whole group" | mode2 "actual process cancellation", testProjectWork "Stop kills foreground and background project writers" |
| Time limit: at `timeout` the tool and its descendants are ended | same | "a slow tool times out", "a timed-out tool and its children are ended" | none |
| Left processes: with `processGroup` the tool's whole group is killed when the call ends, even after a good answer; without it nothing else is stopped | `RunConditions.app` (project work) | "the process group is stopped when the call ends", "without a process group nothing else is stopped" | `run_conditions.swift` (group flag per kind) |
| Threads: `ask` blocks its caller (never call it on the main thread from UI); progress comes on a background thread; `DebateCancellation` and `NativeSessions` are locked, any thread | all callers (they hop to the main thread themselves) | "progress comes on a background thread" | none (a main-thread call freezes the app) |
| Stream events in order: Claude text within one message (a new message starts over; at most ~12 a second, the last text of each message always sent), each tool start as `activity`, each TodoWrite list as it came (`todos(Any?)`, not filtered), where it came; Codex: command/tool/search starts, each finished message | Solo (text, activity), ProjectChat (all three) | Claude and Codex orders | mode2 StreamParser block, `testProjectHandoff` |
| Sessions: a new session starts with its own id (`--session-id` / Codex `thread.started`); the next call resumes it (`--resume <id>`, `exec resume <id>`) with only what is new; a stopped or failed answer marks it for a rebuild and is not retried (only "session not found" is, once, with the full context); compaction rebuilds | Attachments, Collaboration, ProjectChat (`nativeSessions.ask`) | session block (new, resumed, stopped, Codex resume) | mode2 "session delta, image reuse, role separation, compaction bootstrap …" |
| Session save format: `rooms/<room>/ownership.json`, 0600, a JSON array of records `id`, `accountID`, `provider`, `role`, `nativeID`, `context`, `ownBlock` (`[<speaker>]\n<reply without its TL;DR line>` for speakers), `images`, `valid`; older files are read as they are; archive and purge keep or remove only what a room recorded | Attachments, Collaboration, ProjectChat, Discussion (delete, archive) | "ownership.json keeps its fields", "an older ownership.json is read", "is private" | mode2 "chat delete removes only its sessions …" |
| Local model: no command line tool, one answer at a time (`gate`), keep-alive and unload | Local chat, Route sorter, Settings, LocalModels window, main (menu) | none (needs Ollama: a fake server in mode2) | mode2 "Ollama on this Mac", "Gemma on this Mac", `run_conditions.swift` ("the local model starts no command line tool") |
| Usage readings and cloud model picks (stored per account in `UserDefaults.app`) | main, MenuCards, Settings, Solo, Meeting, Peer (auto pick by usage) | none | mode2 "menu bar …", "plain chat (auto pick 15% …)", testCloudModels |

Public names and why (everything else stays internal: `Answerer.chatDir`/`askOnce`/`launchForTests`/`replyForTests`,
`StreamParser`, `NativeSessions.split`/`load`/`save`, `CloudModels.apply`/`noteSeen`, `ClaudeUsage.binary`, the HTTP
streams `LocalStream`/`PullStream`, `LocalModel.ask` and the Ollama requests):
- `Answerer.ask`, `Answerer.Failure`, `AnswerProgress`: the one way in, its result and its progress (every caller).
- `RunConditions` (all five fields, `init()`) and `RunConditions.Folders` (an explicit `init`): `Workspace.swift` builds
  them; the fields are what the caller decides.
- `Answerer.toolForTests`: the only public test hook, so `runtime_contract.swift` can run a fake CLI from outside; the
  app never sets it (run_mode2 stage 1 checks that no app file names it).
- `DebateCancellation` (`init`, `isCancelled`, `child`, `attach`, `detach`, `cancel`, `end`): the app makes the tokens
  and stops its own processes the same way (project commands in ProjectWork, document reading in MaterialReader and
  Workspace, the updater).
- `NativeSessionCall` (the type only: `ask` hands one to the caller's closure, which passes it back), `NativeSessions`
  (`init`, `ask`, `directory`, `eligible`, `pinnedAccount`, `reset`, `purgeRoom`).
- `ReplyHeadline.split`: the chat's headline and the session's own block must cut a reply the same way.
- `ToolHome` (`path`, `agyInstalled`): where the tools live (the user's home, not the test home); `Login` and Settings.
- `GeminiLinks` and `toolNote`: `Workspace.swift` adds the workspace note to the same type.
- `CloudModels` (`model`, `set`, `valid`, `Choice`, `claudeChoices`, `codexChoices`, `loadGemini`, `seenKey`, `seenTitle`):
  the Settings model menus.
- `LocalModel` (63 names: variants, the catalog and its entries, fit by memory, Ollama's library, installed/loaded
  models, pull, delete, keep-alive, the gate, `server` for mode2's fake server) and `LocalUsage.read`: the Settings
  Ollama section, the Ollama window, the menu and the Route sorter use all of them. It is the largest public part:
  model management came with the file (`Local.swift`); splitting it from running is a later step.
- `AIUsage`, `UsageWindow` (fields, `left`, `leftNow`; no public inits: only the module makes readings),
  `CodexUsage`/`ClaudeUsage`/`GeminiUsage` (`read`, `forget`; `CodexUsage.binary` for the Codex login): the menu.

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
| Full access → AutoGuard's environment (shims on PATH, no Git/GitHub credentials, no SSH agent); off → none | `RunConditions.app` (Workspace.swift) | — | `run_conditions.swift` layer checks: project-on and folder-full have it, project-off and folder do not; `testFullAuto` (the shims themselves) |
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
