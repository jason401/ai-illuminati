# Modules: one Swift module per part, checked by promise → user → test

The app is one Swift program built from `app/macos/*.swift`: in it, every file can use every other file's
`internal` names, so a folder alone draws no line. A part in `app/modules/<Name>/` is its own Swift module:
it builds alone, and the app sees only its `public` names. Now: `AILocalization` (L(), AppLanguage), `AIAccounts`
(account list and folders) and `AISpaces` (Spaces: saving, checks, the isolated web view), all 2026-11-11.

## How a module is built and used
- `zsh tools/build_modules.sh <out> [swiftc options]` builds every `app/modules/<Name>/` alone into
  `<out>/<Name>.swiftmodule` + `<out>/lib<Name>.a` (static: nothing new in the app bundle, signing unchanged).
- A module may use only the modules named in its `dependencies` file (one per line; none: no file). They are built
  first, and the compiler sees only theirs, so an import of any other module fails the build. Now
  `AISpaces` → `AIAccounts`, `AILocalization`; the other two use none. No circles (the script refuses them).
- Every `swiftc` that compiles app files runs it first and adds `-I <out> <out>/lib*.a`:
  `tools/build_app.sh` (compile step), `tools/tests/run_mode2.sh`, the preview scripts.
- Each file that uses a module says `import <Name>`. Not the hidden compiler option (`-Xfrontend -import-module`):
  the import line shows who uses the module (`grep -l "import AIAccounts"` lists its users), and no
  compile command needs one more flag.
- Name: `AI` + the part, never Apple's framework names (`Accounts` is one).
- `run_mode2.sh` stage "Modules on their own": builds the modules alone, runs each contract test from outside
  (`tools/tests/<part>_contract.swift`, public names only), and checks that internal names
  (`AccountStore.place`, `SpaceStore.setting`, `SpaceAssets.served`) do not compile outside.
- Tests build the modules with `-enable-testing` only so `space_build.swift` can say `@testable import AISpaces`
  (it checks module insides such as `SpaceCheck`). Every app file and every other test keeps a plain import and
  sees public names only; the app build (`build_app.sh`) has no `-enable-testing`.
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


## Runtime, step R0: the way in made narrow, before it becomes a module (2026-11-11, draft)
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
- Left for R1 (Runtime still uses them): `CloudModels` (model pick, `apply`, `noteSeen`), `LocalModel.ask`,
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
| The tool starts with exactly what `RunConditions` says: prefix before its arguments, the wrapper's program first and the tool after its arguments, the changed environment, the group stopped at the end | every `Answerer.ask` caller (`RunConditions.app`) | none yet (R1: a contract test with a hand-made `RunConditions`) | `run_conditions.swift`: launches through `Discussion.requestDebate` for Claude, Codex, Gemini, local × plain, folder, folder with full access, project off, project on, compared byte for byte with `run_conditions.golden` |
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
identical, and is byte-identical after it (sha1 `1ca3b747…`). It needs no CLI: a missing tool counts as `<cli>`;
the environment is compared with the account's own after a fixed start (plain PATH, a GitHub token and an SSH agent
to take away), Claude's `--mcp-config` with sorted keys. Gemini has no "plain" kind: it would add web rules to agy's
settings in the real home.
