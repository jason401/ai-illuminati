# AI Illuminati ↔ AI Face

How AI Illuminati shows up in AI Face as its own AI app, next to Claude desktop, Codex and Claude Code.
This is the agreement between the two apps. AI Illuminati's side is done (2026-11-05). The **AI Face** section
below is the work requested from AI Face.

## Goal

AI Face should see **AI Illuminati** as one AI app, not as Claude or GPT. Inside AI Illuminati, Claude,
ChatGPT or another account may answer; to AI Face it is always "AI Illuminati": its own row in Settings → AI,
its own ring color, its own name in the history and its own permission switches.

## How it connects (same as the other apps: MCP)

1. In AI Face, Settings → AI → AI apps → **AI Illuminati → Connect**.
2. AI Face writes its MCP server into AI Illuminati's data folder, in the same shape as Claude desktop's config:

   `~/Library/Application Support/AI Illuminati/mcp.json`

   ```json
   {
     "mcpServers": {
       "ai-face": {
         "command": "/usr/bin/python3",
         "args": ["/Users/<you>/Library/Application Support/AI Face/ai_face_mcp.py"],
         "env": { "AIFACE_AGENT": "illuminati" }
       }
     }
   }
   ```

   Keep any other entries in the file and change only `ai-face`. Write it atomically (temporary file + rename).
   **Disconnect** removes the `ai-face` entry (or the file when nothing else is left in it).
3. AI Illuminati reads the file before every plain-chat answer, so no restart is needed after Connect or Disconnect.
4. In plain chat, AI Illuminati starts the answering AI (Claude Code CLI or Codex CLI) with this server added,
   always with `AIFACE_AGENT=illuminati` (whatever the file says), and asks the AI to call `set_expression`
   once before each reply.

### What AI Illuminati accepts (its checks)

- Only the `ai-face` entry. `command` must be an absolute path to an executable; `args[0]` must be a file
  inside `~/Library/Application Support/AI Face/` (symlinks and `..` are resolved first). Anything else is ignored.
- Only the tool **`set_expression`** is allowed (Claude: `--allowedTools mcp__ai-face__set_expression`;
  Codex: `enabled_tools = ["set_expression"]`). Calendar, mail, folders, timer and the other tools stay off
  inside AI Illuminati for now, whatever AI Face allows. Widening this later is a change on AI Illuminati's side.
- Only plain chat (mode 0). Debate, collaboration and vote modes do not get AI Face. Gemini does not get it.
- If the file is missing or invalid, chats work as before, without a face.

## What AI Face needs to change

Today AI Face knows exactly two AIs, `claude` and `gpt`; any other name is treated as GPT (or by the MCP client
name). `AIFACE_AGENT=illuminati` therefore currently shows up as Claude (Claude Code CLI) or GPT (Codex CLI).
Places that assume two AIs (from a search for `'gpt'`):

1. **MCP shim** `core/ai_face_mcp.py` `agent()`: return `'illuminati'` when `AIFACE_AGENT` is `illuminati`.
   Also the awake label (`'Claude' if agent() == 'claude' else 'GPT'`) and the `get_expression` description.
2. **Owners** `core/aiface/moods.py` `OWNERS`, `owner_command`; `core/aiface/history.py` `OWNERS`
   (history and the 7-day counts); `core/aiface/server.py` `_who`; `calendar_access.py`, `folder_access.py`,
   `mail_access.py` names and `DEFAULTS`. Old history files keep working (they only have claude/gpt/user).
3. **Permissions** (shared folders, calendar read/write, mail): a third switch "Illuminati" next to Claude / GPT
   (`SettingsTabs.swift` `perAI`, `Settings.swift` `calIlluminati` …). Suggested default **off**, like GPT.
   AI Illuminati only calls `set_expression` today, so these switches matter only when that is widened.
4. **Connect row** `core/aiface/integrations.py` + `SettingsTabs.swift` `appRow`: "AI Illuminati" with
   Connected / Not connected / Connect / Disconnect, reading and writing the file above. Show it only when
   AI Illuminati is installed (`/Applications/AI Illuminati.app` or its data folder exists). Unlike the other apps,
   no restart of AI Illuminati is needed.
5. **Ring color and look**: a fourth owner color. Suggested gold, like AI Illuminati's app icon mark
   (`#FFD673`, sRGB 1.0 / 0.84 / 0.45; the menu bar mark uses a darker gold on light backgrounds). Menu bar `Face.swift` (`ownerColor`, the monochrome ring pattern), `Settings.swift`
   `OWNERS` / `OWNER_LABEL` ("AI Illuminati"), `StatusMenu.swift` ("Chosen by AI Illuminati").
6. **Board firmware** `firmware/ESP32_Display/ESP32_Display.ino`: `OWNER_RGB[3]` → 4 colors, `OWNER:%d`
   accepts `slot<4`, `prefs.getInt("owner")` constrained to 0..3, a monochrome pattern in `ringOn` (for example
   dots), and the firmware simulator tests. **Compatibility:** a board with the current firmware answers
   `OWNER:3` with nothing, the exchange times out and the app closes the board connection. So either bump
   the protocol (`FACE9`, and send owner 3 only to FACE9 boards, white to older ones) or send owner 3 only after
   the board says it supports it. Never let an older board drop the connection.
7. **Docs and tests**: README, `docs/USER_GUIDE.md`, `docs/사용방법.md`, `docs/감정표현-설계.md`, tests that list
   owners (`tests/test_face_modes.py` …), `render_settings.sh` previews.

## Check after both sides are done

- Connect in AI Face → `mcp.json` appears with the entry above. Disconnect → the entry is gone.
- Send a message in AI Illuminati's plain chat (once with a Claude account, once with ChatGPT): the face changes,
  the ring is gold on the menu bar and the board, and `get_expression` lists "AI Illuminati".
- An older board firmware keeps its connection (white ring) until the firmware is updated.

## Verified on AI Illuminati's side (2026-11-05)

- Claude Code CLI with the server and `AIFACE_AGENT=illuminati`: called `set_expression` before the reply
  (≈5 s for a short answer), reply complete in the final message.
- Codex CLI (read-only sandbox, shell off, `enabled_tools=["set_expression"]`): the server reaches AI Face from
  inside the sandbox; moods `thinking`, `happy`, `sympathy` set. Codex needs the argument name (`emotion`) and
  example moods in the instruction, or it sends `mood` / invented moods.
- AI Face recorded these as Claude and GPT, as expected before AI Face's change.
