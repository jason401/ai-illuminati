# Usage

## Accounts and usage limits

Open Settings (⌘,) → Accounts, add Claude or ChatGPT accounts, and authenticate through the provider's browser sign-in. Gemini uses a separate agy login. App-specific accounts have separate folders. Do not duplicate accounts by copying authentication files.

The menu shows per-account five-hour and weekly remaining limits and reset times. Available limits vary by provider and plan. Choose bar, ring, or card layouts in Settings, and hover over an account for additional limits.

Menu bar meters show one bar per account, in Settings order. Choose either the five-hour or weekly window as the menu bar's usage basis. An absent limit is distinguished from a failed reading. Monochrome ON means black and white; OFF means color.

Eye and halo animation can be disabled in Settings. The halo cycles from fully absent to bright and back, with a faster cycle while an AI response is running. macOS Reduce Motion stops the animation.

## External tools

- Claude: install and sign in through Claude Code's official tools. The app uses `~/.local/bin/claude`.
- ChatGPT: install OpenAI Codex CLI. The app checks `~/.local/bin`, standard Homebrew locations, and a supported ChatGPT app bundle path.
- Gemini: install and sign in through Antigravity CLI (agy). The app uses `~/.local/bin/agy`.

Availability, limits, and subscription support depend on each provider and organizational policy. A free software license does not make AI services unlimited or free.

## Conversation modes

| Mode | Behavior |
|---|---|
| Discussion | Independent opening opinions, moderator-assigned follow-ups, and a final answer |
| Critical debate | Review objections, alternatives, and failure conditions before a final answer |
| Collaboration | Assign tasks to selected accounts, respect prerequisites, execute independent work, cross-review, and integrate results |
| Vote | Accounts vote independently on the options; the app counts the ballots |

Discussions automatically select one account per provider. Collaboration lets you select accounts individually. Voting participation can be switched for each connected account; sign-in status and usage limits may exclude an account. The crown selects the moderator.

Enter sends a message. Shift+Enter or Option+Enter inserts a newline. ⌘Enter also sends. During Korean input composition, Enter finishes the composed text. Stop cancels active requests.

Discussion turns have a 400/800/1500-character length setting. Models may not obey the requested length exactly. Sessions are kept by default for app-specific Claude/Codex accounts and can be disabled per chat. Gemini and some other paths may resend the full context.

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
