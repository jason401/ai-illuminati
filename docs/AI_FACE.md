# AI Illuminati ↔ AI Face

How AI Illuminati shows up in AI Face as its own AI app, next to Claude desktop, Codex and Claude Code.
This is the agreement between the two apps. AI Illuminati's side is done (2026-11-05). The **AI Face** section
below is the work requested from AI Face.

## Goal

AI Face should see **AI Illuminati** as one AI app, not as Claude or GPT. Inside AI Illuminati, Claude,
ChatGPT or another account may answer; to AI Face it is always "AI Illuminati": its own row in Settings → AI,
its own ring color, its own name in the history and its own permission switches.

## How it connects (same as the other apps: MCP)

```
Claude desktop     ═MCP═ ai_face_mcp.py ─→ AI Face      (AIFACE_AGENT=claude)
ChatGPT desktop    ═MCP═ ai_face_mcp.py ─→ AI Face      (AIFACE_AGENT=gpt)
AI Illuminati app  ═MCP═ ai_face_mcp.py ─→ AI Face      (AIFACE_AGENT=illuminati)
   ↑ inside: Claude Code / Codex / later models, per answer, through AI Illuminati's own bridge
```

AI Illuminati behaves like the other desktop apps: **the app itself** is AI Face's MCP client.

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
3. The app starts that server **once** and keeps the MCP session open while the app runs (initialize with
   `clientInfo.name = "AI Illuminati"`, then `tools/list`), always with `AIFACE_AGENT=illuminati` whatever the file
   says. It checks the file every 30 seconds and before each call: Connect, Disconnect, or a server that quit
   is picked up without restarting AI Illuminati.
4. Which model answers stays inside AI Illuminati. In plain chat the model ends each reply with a hidden tag,
   `<face>mood</face>` (the moods come from AI Face's `set_expression` list). The app removes the tag from the
   reply and calls `set_expression` itself on its one AI Face session. No tool call by the model: it costs
   almost nothing, and models had skipped the tool call in long chats. AI Face therefore always sees one
   client, AI Illuminati, and never which model chose the face.
5. AI Face's other tools (calendar, mail, folders, timer …) are still offered to the model through AI
   Illuminati's workspace bridge, which hands every call to the app over a local socket; the app sends it on
   the same session. A model uses them only when the user asks for something they do.

### What AI Illuminati accepts (its checks)

- Only the `ai-face` entry. `command` must be an absolute path to an executable; `args[0]` must be a file
  inside `~/Library/Application Support/AI Face/` (symlinks and `..` are resolved first). Anything else is ignored.
- **Every tool AI Face lists is passed on to the models**, like the ChatGPT app does. AI Illuminati only has an
  on/off switch for the whole server (Settings → Chat → MCP servers). **AI Face's permissions for `illuminati`
  are therefore the only lock** on calendar, mail and shared folders: they must exist and default to off (see 3).
  The face itself never needs a tool call by the model (see 4); other tools are used only when the user asks.
- The data a tool returns (calendar events, mail text) goes to whichever model answers, which may be a
  school/Enterprise account. AI Face should say so next to the Illuminati switches.
- Only plain chat (mode 0), including project work linked to a plain chat (the writing AI tags its reply; a read-only reviewer does not). Debate, collaboration and vote modes do not get AI Face.
- If the file is missing, invalid or AI Face is closed, chats work as before, without a face.

## What AI Face needs to change

Today AI Face knows exactly two AIs, `claude` and `gpt`; any other name is treated as GPT (or by the MCP client
name). `AIFACE_AGENT=illuminati` therefore currently shows up as Claude (Claude Code CLI) or GPT (Codex CLI).
Places that assume two AIs (from a search for `'gpt'`):

1. **MCP shim** `core/ai_face_mcp.py` `agent()`: return `'illuminati'` when `AIFACE_AGENT` is `illuminati`
   (and, as a fallback, when the `initialize` client name is `AI Illuminati`).
   Also the awake label (`'Claude' if agent() == 'claude' else 'GPT'`) and the `get_expression` description.
2. **Owners** `core/aiface/moods.py` `OWNERS`, `owner_command`; `core/aiface/history.py` `OWNERS`
   (history and the 7-day counts); `core/aiface/server.py` `_who`; `calendar_access.py`, `folder_access.py`,
   `mail_access.py` names and `DEFAULTS`. Old history files keep working (they only have claude/gpt/user).
3. **Permissions** (shared folders, calendar read/write, mail): a third switch "Illuminati" next to Claude / GPT
   (`SettingsTabs.swift` `perAI`, `Settings.swift` `calIlluminati` …). Default **off**, like GPT. This is required,
   not optional: AI Illuminati passes every AI Face tool on, so these switches are what keeps calendar and mail
   closed. Until this exists, the shim treats `illuminati` as GPT (unknown agent, client name without "claude"),
   so GPT's switches apply.
4. **Connect row** `core/aiface/integrations.py` + `SettingsTabs.swift` `appRow`: "AI Illuminati" with
   Connected / Not connected / Connect / Disconnect, reading and writing the file above. Show it only when
   AI Illuminati is installed (`/Applications/AI Illuminati.app` or its data folder exists). Unlike the other apps,
   no restart of AI Illuminati is needed (it notices within 30 seconds).
   If AI Face shows connected clients somewhere, AI Illuminati's session stays open like Claude desktop's.
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

- With the real AI Face server: the app-side link started it once, listed its tools and stayed connected.
- Claude Code CLI and Codex CLI (Codex in its sandbox, shell off) each called `set_expression` through AI
  Illuminati's bridge before replying (`cheering`, `sympathy`); both changes reached AI Face through the app's one
  session. Before AI Face's change AI Face records them as GPT (unknown agent, client name without "claude").
- Codex needs the argument name (`emotion`) and example moods in the instruction, or it sends `mood` or
  invented moods. Calling the tool after the reply cut the reply in the chat, so it is called before.
