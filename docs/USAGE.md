# Usage

## Accounts and usage limits

Open Settings (⌘,) → Accounts, add Claude or ChatGPT accounts, and authenticate through the provider's browser sign-in. Gemini uses a separate agy login. App-specific accounts have separate folders. Do not duplicate accounts by copying authentication files.

The menu shows per-account five-hour and weekly remaining limits and reset times. Available limits vary by provider and plan. Choose bar, ring, or card layouts in Settings, and hover over an account for additional limits.

Menu bar meters show one bar per account, in Settings order. Choose either the five-hour or weekly window as the menu bar's usage basis. An absent limit is distinguished from a failed reading. Monochrome ON means black and white; OFF means color.

Eye and halo animation can be disabled in Settings. The halo cycles from fully absent to bright and back, with a faster cycle while an AI response is running. macOS Reduce Motion stops the animation.

## External tools

- Gemma 4 on this Mac (optional), in two sizes: **E4B** (`gemma4:e4b`, about 10 GB, fast, 7–8 GB of memory while answering) and **12B** (`gemma4:12b`, about 8 GB, smarter and slower, about 10–11 GB of memory). Settings → Accounts → Add account → **Install Gemma 4 E4B / 12B (this Mac)**; each is its own entry, so call the one you want with @. Needs Apple silicon, 16 GB of memory and 15 GB of free disk. Terminal installs [Ollama](https://ollama.com) (with Homebrew, after asking) or opens its download page, then downloads the model ([Gemma terms](https://ai.google.dev/gemma/terms)). Only one Gemma is ever in memory: answers take turns across chats, the other model is unloaded before one loads, a vote takes one Gemma, and the last resort uses the one already loaded (else the first in the list). It runs only on this Mac, without an account, key or usage limit, In plain chat it answers when called with **@Gemma** and when every cloud account is out of usage; it also votes. It reads linked files through the app, cannot change files or search the web, and does not join discussions or collaboration. Gemma takes memory only while it is loaded: after a reply it stays for the time chosen in Settings → Accounts (Gemma's row, default 5 minutes; "right after each reply" unloads at once), and closing the chat window unloads it once no chat is answering. The menu bar shows its memory while loaded, with **Unload Gemma Now**. Settings → Accounts → **Gemma 4 (this Mac) → Use** turns it off entirely (left out of @, votes and the last resort).

- Claude: install and sign in through Claude Code's official tools. The app uses `~/.local/bin/claude`.
- ChatGPT: install OpenAI Codex CLI. The app checks `~/.local/bin`, standard Homebrew locations, and a supported ChatGPT app bundle path.
- Gemini: install and sign in through Antigravity CLI (agy). The app uses `~/.local/bin/agy`.

Availability, limits, and subscription support depend on each provider and organizational policy. A free software license does not make AI services unlimited or free.

## Plain chat

New chats start as a plain chat with one AI, like a desktop chat app. **Automatic** picks, among signed-in Claude and ChatGPT accounts with at least 15% of the five-hour limit left, the one with the most weekly usage left (a plan without a weekly limit counts as full). The same account keeps answering while both of its limits stay at 15% or more. When it drops below that, or a reply fails because a limit was reached, another account continues from the saved chat history and the same folders; the chat shows the handoff. Replies appear as they are written (Claude streams text; Codex shows each finished step), with what the AI is doing next to the spinner. Once a chat is long, each answer also updates a short chat state (goal, user instructions, sources and files, current work, next steps) kept in the chat folder; an account that starts without a session it can resume gets that state, the last three turns, and the path of a file with every earlier turn, instead of the whole chat. If a reply is cut off by a usage limit, the next account receives what was written so far and completes it. Stopping keeps what was already written. Gemini never answers automatically. Type **@** to call accounts for one message: a numbered list appears (Gemini included); type to narrow it, press a number or Return to pick, ↑↓ to move, Esc to close. A picked name is one colored piece that ⌫ removes at once. With several names, each answers in order and reads the replies before it; the next message is automatic again. When a message mentions YouTube, Gemini searches YouTube first and the answering AI receives its notes (agy reads video pages and search results, not the video itself). You can also pick an account by hand from the menu under the message box.

**Google Drive (read only).** In the chat sidebar, choose **Google Drive → + → Sign in with Google** and allow read-only Drive access. If Google shows an unverified-app warning, review the app and choose **Advanced → Go to AI Illuminati** to continue. Login credentials stay in this Mac's Keychain and are never given to an AI. Then choose the Drive folders the AIs may read; only those folders and their subfolders are reachable, with an eye to pause each one. Local `.gdoc`/`.gsheet`/`.gslides` pointers and shortcut targets must also be inside those Drive folders. In plain chat Claude and ChatGPT can search, list and read them (Docs as Markdown, Sheets by tab, Slides as text, PDF and Word as text). What they read goes to whichever AI answers. Settings → Chat → MCP servers has the on/off switch. Advanced users can choose **Connect with Own Client File…** in the sidebar context menu for their own Desktop OAuth client.

Mark Enterprise (school or work) accounts in Settings → Accounts. With **Keep Enterprise and personal chats apart** (Settings → Chat, on by default), an Enterprise chat is continued only by Enterprise accounts and a personal chat only by personal ones; choose the chat's side in the account menu.

**Shared folders** in the sidebar can be read by every chat's AI and are read only. A folder linked to a chat with **+ → Link folder** can be read, edited and deleted by that chat's AI; it is backed up before each answer (APFS clones), changed files are listed under the answer, and **Undo** restores the folder. Linked single files are read only. Each chat also has its own folder (right-click the chat → **Show this chat's folder**) where its AI saves new drafts and documents as Markdown. The other modes are under **+ → Ask several AIs**.

## Conversation modes

| Mode | Behavior |
|---|---|
| Discussion | Independent opening opinions, moderator-assigned follow-ups, and a final answer |
| Critical debate | Review objections, alternatives, and failure conditions before a final answer |
| Collaboration | Assign tasks to selected accounts, respect prerequisites, execute independent work, cross-review, and integrate results |
| Vote | Accounts vote independently on the options; the app counts the ballots |

Discussions automatically select one account per provider. Collaboration lets you select accounts individually. Voting participation can be switched for each connected account; sign-in status and usage limits may exclude an account. The crown selects the moderator.

Enter sends a message. Shift+Enter or Option+Enter inserts a newline. ⌘Enter also sends. During Korean input composition, Enter finishes the composed text. Stop cancels active requests.

Discussion and vote turns have no length limit by default; the mode settings also offer 400/800/1500 characters. Models may not obey a requested length exactly. Sessions are always kept for app-specific Claude/Codex accounts, so each AI receives only what is new. Gemini and some other paths may resend the full context.

Attach pictures using +, paste, or drag and drop. Image generation and sharing differ by provider; do not assume all tools provide the same capabilities.

## Materials and file permissions

Linking folders or files initially records paths and inventory. Files and pages are read when needed. Selected PDF/Office ranges can be converted to text or images; this is not a full rendering of the original Office layout.

- **View:** read linked materials.
- **Write:** collaboration workers may modify, create, or delete files within linked scope, with a prior backup and change reporting.
- **Write + Execute:** also permits commands within each CLI's sandbox and permissions. Organizational policies or approval requirements may prevent execution.

Planning and review remain read-only. Undo may refuse to overwrite files changed separately after the task, so keep independent backups. Only link materials you have permission to send to AI providers.

## Chat management and games

Use a chat's ⋯ or context menu to pin or delete it. Deletion cleans up the app-owned JSON, copies, and associated app-owned session and backup records. It does not delete original external linked files or guarantee deletion of provider-side records and every unrelated CLI session.

Open Game (⌘G) starts AI poker with virtual chips. Each AI decision consumes usage for the corresponding account. There are no real-money transactions.

## Language, updates, and reports

Choose English or Korean in Settings. The AI is instructed to follow the language of your latest message. Existing conversations, materials, and account names are not automatically translated.

Updates check stable and install only after a user action. If installation fails, inspect the update state and logs in the local app-data folder, but remove emails, tokens, personal paths, and private conversations before sharing a report. See the [security guidance](../SECURITY.md).

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

In plain chat, open `+` → **Allow project work**, then choose the top-level Git folder.
Claude or Codex can edit it and use app-hosted Git tools for status/diff/log, fast-forward pull,
explicit-path commit, and normal push to main or feature/fix/codex branches.
The project permission remains attached to that chat until disabled from the same menu.
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

**Full auto** (`+` → Full auto…, per chat, for when you are away): the AI runs any command without
approval cards, uses the network, runs registered commands directly and pushes main through the app's
`git_push`. Up to 8 hours, and the Mac stays awake. Still blocked: force push and history rewrites (its shell has
no Git/GitHub credentials and `git push` is refused), and permanent deletes (`rm` moves files to the Trash,
except temporary folders). These guard mistakes, not a deliberately malicious script.

Stable publishing always asks approval for the exact main SHA and remote shown on the card.
Ordinary push does not update stable. Undo is unavailable after commit or push; use Git to
review and revert those changes. Google Drive permissions are separate from project work.
