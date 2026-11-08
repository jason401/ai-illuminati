# Usage

## Accounts and usage limits

Open Settings (⌘,) → Accounts, add Claude or ChatGPT accounts, and authenticate through the provider's browser sign-in. Gemini uses a separate agy login. App-specific accounts have separate folders. Do not duplicate accounts by copying authentication files.

The menu shows per-account five-hour and weekly remaining limits and reset times. Available limits vary by provider and plan. Choose bar, ring, or card layouts in Settings, and hover over an account for additional limits.

Menu bar meters show one bar per account, in Settings order. Choose either the five-hour or weekly window as the menu bar's usage basis. An absent limit is distinguished from a failed reading. Monochrome ON means black and white; OFF means color.

Eye and halo animation can be disabled in Settings. The halo cycles from fully absent to bright and back, with a faster cycle while an AI response is running. macOS Reduce Motion stops the animation.

## External tools

- Models on this Mac through [Ollama](https://ollama.com) (optional). Settings → Accounts → Add account → **Ollama Models (this Mac)…** opens a window with a recommended list (Gemma 4, Qwen, Llama, Mistral, DeepSeek-R1, Phi-4, gpt-oss and more) grouped by how well each fits this Mac's memory: **runs well**, **tight** (other apps may need closing) and **too big** (shown with **Show all**). **Show all** also lists every model family on ollama.com, with a size menu for each. Type a name (`qwen3:8b`) to download any model, even one not listed yet; its exact size is checked first. Sizes and memory are approximate. The recommended list lives in `app/resources/local_models.json` and the app fetches the latest one from the `stable` branch, so new models need no new app. Downloads run in the window with a progress bar and can be cancelled; the first one installs Ollama in Terminal when it is missing (with Homebrew, after asking, or its download page). Each model is its own entry, so call the one you want with @ (`@ollama`, `@local`, or part of its name such as `@qwen`). Models already on this Mac (downloaded in Terminal) appear under **On this Mac** with **Add to List** and a delete button. **Remove from list…** on an Ollama entry asks whether to delete its model files too. Needs Apple silicon. Only one model is ever in memory: answers take turns across chats, the others are unloaded before one loads, a vote takes one local model, and the last resort uses the one already loaded (else the first in the list). A model that cannot read pictures gets the text only, and a model with a shorter conversation limit than 32K uses its own. It runs only on this Mac, without an account, key or usage limit. In plain chat it answers when called with @ and when every cloud account is out of usage; it also votes. It reads linked files through the app, cannot change files or search the web, and does not join discussions or collaboration. A model takes memory only while it is loaded: after a reply it stays for the time chosen in Settings → Accounts (the model's row, default 5 minutes; "right after each reply" unloads at once), and closing the chat window unloads it once no chat is answering. The menu bar shows its memory while loaded, with **Unload Local Model Now**. Settings → Accounts → **Ollama (this Mac) → Use** turns them off entirely (left out of @, votes and the last resort). The Gemma 4 E4B and 12B entries made before keep their ids, chats and order.

- Claude: install and sign in through Claude Code's official tools. The app uses `~/.local/bin/claude`.
- ChatGPT: install OpenAI Codex CLI. The app checks `~/.local/bin`, standard Homebrew locations, and a supported ChatGPT app bundle path.
- Gemini: install and sign in through Antigravity CLI (agy). The app uses `~/.local/bin/agy`.

Availability, limits, and subscription support depend on each provider and organizational policy. A free software license does not make AI services unlimited or free.

## Plain chat

New chats start as a plain chat with one AI, like a desktop chat app. **Automatic** picks, among signed-in Claude and ChatGPT accounts with at least 15% of the five-hour limit left, the one with the most weekly usage left (a plan without a weekly limit counts as full). The same account keeps answering while both of its limits stay at 15% or more. When it drops below that, or a reply fails because a limit was reached, another account continues from the saved chat history and the same folders; the chat shows the handoff. Replies appear as they are written (Claude streams text; Codex shows each finished step), with what the AI is doing next to the spinner. Once a chat is long, each answer also updates a short chat state (goal, user instructions, sources and files, current work, next steps) kept in the chat folder; an account that starts without a session it can resume gets that state, the last three turns, and the path of a file with every earlier turn, instead of the whole chat. If a reply is cut off by a usage limit, the next account receives what was written so far and completes it. Stopping keeps what was already written. Gemini never answers automatically. Type **@** to call accounts for one message: a numbered list appears (Gemini included); type to narrow it, press a number or Return to pick, ↑↓ to move, Esc to close. A picked name is one colored piece that ⌫ removes at once. With several names, they answer at the same time without seeing each other's replies: the first good reply is the main answer and the others are listed below it. In a project chat the first one works on the project and the others review it read only. The next message goes back to the chat's usual AI. When a message mentions YouTube, Gemini searches YouTube first and the answering AI receives its notes (agy reads video pages and search results, not the video itself). You can also pick the chat's members by hand from the menu under the message box. Check one and it answers every message. Check two or more and, in a plain chat, they all answer every message at the same time, as with @: one of them (the lead) may change files and the others get the folders read only. In a project chat the lead does the work and the others review it (see Review). The app picks the lead (the one who worked last while it has usage left, else the member with the most usage left) and keeps it; **Who does the work** in the same menu picks one by hand. The menu shows who works and who reviews. **Automatic** clears the checks. @ in a message replaces the checked accounts for that message only. Accounts that need sign-in or have no usage left sit out; if fewer than two remain, the usual single answer runs.

**Google Drive (read only).** In the chat sidebar, choose **Google Drive → + → Sign in with Google** and allow read-only Drive access. If Google shows an unverified-app warning, review the app and choose **Advanced → Go to AI Illuminati** to continue. Login credentials stay in this Mac's Keychain and are never given to an AI. Then choose the Drive folders the AIs may read; only those folders and their subfolders are reachable, with an eye to pause each one. Local `.gdoc`/`.gsheet`/`.gslides` pointers and shortcut targets must also be inside those Drive folders. In plain chat Claude and ChatGPT can search, list and read them (Docs as Markdown, Sheets by tab, Slides as text, PDF and Word as text). What they read goes to whichever AI answers. Settings → Chat → MCP servers has the on/off switch. Advanced users can choose **Connect with Own Client File…** in the sidebar context menu for their own Desktop OAuth client.

**One answer, everyone, or work.** In a project chat with two or more members taking part, the app first sorts each message (without @): **one** when a single answer covers it (a question of fact about the code or the app, an explanation, a status check, a short follow-up, thanks), **all** when it asks for views (opinions, design choices, pros and cons, ideas, or the AIs together), and **work** when it asks to change the project or approves what was just discussed ("가자", "그걸로 하자"). Unsure between one and all, it picks all. Gemma 4 E4B on this Mac sorts it in about a second, whether or not it is checked (checked only means it answers too); it is taken out of memory right after unless it was already loaded. If Ollama is off, E4B is not downloaded, another chat is using the local model, or it does not answer within 10 seconds, the checked Claude or ChatGPT member with the most usage left sorts it without any tools. If nobody can, it is all. One: only the lead answers, the project read only. All: every member answers at the same time, and the project is read only for all of them (only the chat folder stays writable), with no review. Work: the lead works and the others review, as below; a "가자" after opinions gives the lead every opinion in the chat. A label above the answer shows the mode and who sorted it, and under the newest answer **Ask the others too** (after one), **Run as work** and **Ask for opinions** send the same message again, with its pictures, in that mode as a new turn (files a work answer already changed stay changed). With one member, or with @, nothing is sorted.

**Review.** There is no separate switch: a project chat with two or more members has review. The lead gets an `ask_peer` tool and asks another member (the other kind of AI first, Claude ↔ ChatGPT, on the chat's Enterprise or personal side) before complex work (several files or about 100 lines, saved data, sync or publishing, concurrency, an uncertain design, or when you ask), at most twice per answer. When the lead's answer changed the project, a member who did not do the work reviews those changes (the commits made in the answer and the files it changed; your own earlier unfinished changes are left out). If it finds something, the lead weighs each point, fixes what is right in the same turn and says what it took and left; the fix is shown after the first reply under **After the review**. This happens once per message, with no second review. Questions that change nothing are not reviewed. Reviewers only read: their folders are read only and they get no tools. Opinions and reviews appear as one-line rows under the answer (click for the full text). Chats that had review turned on in an older version get the reviewer as a second member.

Mark Enterprise (school or work) accounts in Settings → Accounts. With **Keep Enterprise and personal chats apart** (Settings → Chat, on by default), an Enterprise chat is continued only by Enterprise accounts and a personal chat only by personal ones; choose the chat's side in the account menu.

Replies are shown with Markdown: bold, italics, code, links, headings, tables and `---` rules. A single `~` stays as written (`2~4GB`); only `~~text~~` strikes through.

**Shared folders** in the sidebar can be read by every chat's AI and are read only. A folder linked to a chat with **+ → Link folder** can be read, edited and deleted by that chat's AI; it is backed up before each answer (APFS clones), changed files are listed under the answer, and **Undo** restores the folder. Linked single files are read only. Each chat also has its own folder (right-click the chat → **Show this chat's folder**) where its AI saves new drafts and documents as Markdown.

## Older team modes

Discussion, critical debate, collaboration and vote are no longer offered. Chats made in those modes open as plain chats; their earlier turns still show as they were. To get several views, check several AIs or call them with @, and ask for a debate or critique in the message itself.

Enter sends a message. Shift+Enter or Option+Enter inserts a newline. ⌘Enter also sends. During Korean input composition, Enter finishes the composed text. Stop cancels active requests.

Sessions are always kept for app-specific Claude/Codex accounts, so each AI receives only what is new. Gemini and some other paths may resend the full context.

Attach pictures using +, paste, or drag and drop. Image generation and sharing differ by provider; do not assume all tools provide the same capabilities.

Picture makers (Settings → Chat): checked ChatGPT accounts draw every picture the other AIs (Claude, Gemini, Gemma) need, in plain chats, team modes and project chats. The AI writes a picture request and the drawn image takes its place. With "Keep Enterprise and personal chats apart" on, an Enterprise AI asks only an Enterprise ChatGPT and a personal AI only a personal one; if every maker on that side fails, the request is shown instead. Charts of real data and diagrams that must be exact are still drawn by each AI. Uncheck all makers to have each AI draw for itself again.

## Materials and file permissions

Linking folders or files initially records paths and inventory. Files and pages are read when needed. Selected PDF/Office ranges can be converted to text or images; this is not a full rendering of the original Office layout.

- **View:** read linked materials.
- **Write:** collaboration workers may modify, create, or delete files within linked scope, with a prior backup and change reporting.
- **Write + Execute:** also permits commands within each CLI's sandbox and permissions. Organizational policies or approval requirements may prevent execution.

Planning and review remain read-only. Undo may refuse to overwrite files changed separately after the task, so keep independent backups. Only link materials you have permission to send to AI providers.

## Chat management and games

Use a chat's ⋯ or context menu to pin or delete it. Deletion cleans up the app-owned JSON, copies, and associated app-owned session and backup records. It does not delete original external linked files or guarantee deletion of provider-side records and every unrelated CLI session.

### Chats from other Macs

Settings → Chat → **Chats from other Macs** (off by default) shows chats from your other Macs read only, under **Other Macs** in the sidebar. Turn it on on each Mac with the same iCloud account (or pick the same folder on each). Each Mac writes copies only into its own folder (`AI Illuminati Sync/devices/<this Mac>/`) and only reads the others, so nothing is overwritten or merged.

- **Chats shown:** *Chosen chats* (default: pick them with **Show on other Macs** in a chat's ⋯ menu) or *All*.
- **Enterprise chats** are not copied unless you include them; turning that off removes their copies at once.
- A copy holds the messages, finished answers, summary and chat state. Pictures, linked folders, backups, results, sessions and the reply being written stay on the Mac they came from.
- **Continue on this Mac** makes a new chat here from the copy, on the same Enterprise/personal side, with no folders or project linked. Its first message starts a new session from the chat state and the turns after it. The original chat is unchanged; continuing again offers the chat you already continued first.
- The bar under a copy shows when it last changed and when this Mac last checked. iCloud may take a while to bring changes over.

Open Game (⌘G) starts AI poker with virtual chips. Each AI decision consumes usage for the corresponding account. There are no real-money transactions.

## Language, updates, and reports

The app follows the macOS language: Korean on a Korean Mac, English otherwise. To pick one for this app only, use System Settings → General → Language & Region → Applications. The AI is instructed to follow the language of your latest message. Existing conversations, materials, and account names are not automatically translated.

Updates check stable (or main, with the Beta channel in Settings) and install only after a user action. If installation fails, inspect the update state and logs in the local app-data folder, but remove emails, tokens, personal paths, and private conversations before sharing a report. See the [security guidance](../SECURITY.md).

Updates fetch, test and build in a separate checkout while the app remains usable. Only replacing the installed app and restarting waits for active chats, material imports and games to finish. Replacement resumes when the work state changes, with a ten-second fallback check. The progress area shows when it last checked and a countdown; a prepared build is reused rather than rebuilt while waiting.

The app uses a public iOS OAuth client ID without a client secret. A small group personally known to the
developer may qualify for Google’s personal-use exception; a count below 100 alone is not a
public-distribution exemption.

To enable Drive writing, use a folder's pencil menu → **Allow Writing…** and grant additional Google access.
Google consent includes full Drive modification authority; the app limits tools to creation, Docs/Slides text/page edits and moving Docs/Slides files to trash in explicitly writable folders. Add a subfolder and set **Read Only** to override a writable parent;
**Inherit Parent Permission** removes the override. Existing connections remain read only until upgraded.
The app owner must enable Google Docs API and Google Slides API, and add the Drive write scope in Google Cloud data access.
Cloud writes are not covered by the local-folder Undo system. Restore trashed files from Google Drive trash before Google purges them. File moving, folder/permanent deletion and Sheets edits are not offered. Folder names refresh automatically when the app becomes active and about once a minute.

Slides supports native text replacement, page addition and page deletion. Reading slide structure provides
page IDs, text and geometry, but does not visually inspect images or rendered layout.

The Google Drive sidebar is a folder tree. Click a chevron to load/expand direct subfolders; collapse to hide
them. Only opened branches are fetched, with loading/error/retry states. Each row's permission menu can
allow writing, force read only, or inherit the parent. Dim icons indicate inherited settings. Child folders
need not be added as separate shared roots. Root eye switches pause the whole shared tree; removing a root
only removes sharing and its associated permission overrides, never the real Drive folder. Double-click
opens the folder in the browser. Expanded branches refresh about once a minute while visible.


## Project work in plain chat

In plain chat, open `+` → **Link folder (full access)**. A top-level Git folder with a remote becomes project work
(Git tools below); any other folder gets the same full access, backed up before each answer with Undo.
Claude or Codex can edit it and use app-hosted Git tools for status/diff/log, fast-forward pull,
explicit-path commit, and normal push to main or feature/fix/codex branches.
The project permission remains attached to that chat until disabled from the same menu.
Project work uses the same instruction as any plain chat, plus the Git steps: the AI knows the shared folders
(read only here), can search the web with sources, uses Drive, pictures and AI Face, and keeps the chat state
summary in long chats. Whatever is added to plain chat reaches project work too.
Only one writer in this app may work on a repository at a time. External editors and agents
are not locked. On a usage limit, the previous attempt is cancelled and another supported
account continues the same files; no automatic stash, reset, checkpoint commit, or dirty pull.
Additional mentioned accounts review the completed work read-only.

Register build/test commands in `.ai-illuminati.json`, for example:

```json
{"version":1,"commands":{"test":{"executable":"/bin/zsh","args":["tools/tests/run_mode2.sh"]}}}
```

Each registered command requires an approval card and runs outside the AI sandbox with your
user permissions. Trust and review the project code before allowing it. A changed command or
working tree while approval is pending invalidates that approval. Stop cancels the process
group. Approval expires after 15 minutes; a project turn allows 45 minutes of active work
and at most 60 minutes including approvals. App restart preserves unfinished files and a
local journal, but does not automatically resume the task.

Approval cards appear right above the message box. While the AI works, the latest project tool
result shows under its progress line; afterwards the reply has a collapsed **project steps** list
with every tool it used in that turn, kept with the chat.

**Full auto** is the default for project work (turn it off per chat in `+` to confirm steps with cards): the AI runs any command without
approval cards, uses the network, runs registered commands directly and pushes main through the app's
`git_push`. Up to 8 hours, and the Mac stays awake. Still blocked: force push and history rewrites (its shell has
no Git/GitHub credentials and `git push` is refused), and permanent deletes (`rm` moves files to the Trash,
except temporary folders). These guard mistakes, not a deliberately malicious script.

Stable publishing always asks approval for the exact main SHA and remote shown on the card, in full auto too: ask in the chat
and the card appears; without a request the AI only reports what is ready to publish.
Ordinary push does not update stable. Undo is unavailable after commit or push; use Git to
review and revert those changes. Google Drive permissions are separate from project work.
