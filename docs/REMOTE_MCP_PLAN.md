# Remote MCP servers — plan

Goal: adding a remote (URL) MCP server should feel like Claude's custom connectors or VS Code: paste a URL,
sign in in the browser if the server asks, done. Built on `ExternalMCP.swift` (stdio today); `ToolHub`,
tool names (`<server>__<tool>`), timeouts (`slow`, 120 s), on/off (`mcpOff`) and the Enterprise block stay.

## What the user does

1. Settings → MCP → **서버 추가…** → one field: "URL 또는 명령어". Anything starting with `http(s)://` is remote.
   The name is filled from the host (`mcp.notion.com` → `notion`) and can be changed.
2. **추가** probes the server at once (like Claude's "Sign in now"):
   - no auth needed → connected, tool list shown;
   - 401 → the browser opens for OAuth, then connected;
   - the server wants an API key (401 without OAuth metadata) → the sheet opens "Request headers" with
     `Authorization: Bearer ` ready to fill.
3. **고급** (folded): request headers, OAuth client ID / secret. Same places as Claude and VS Code.
4. The same field also takes what server READMEs show, so copying their install snippet just works:
   - JSON: `{"mcpServers": {...}}`, VS Code `{"servers": {...}}`, `{"url": ...}`, `"type": "http"`,
     `"serverUrl"` (Windsurf), `"headers"`;
   - command lines: `claude mcp add --transport http <name> <url> [--header "K: V"]`,
     `codex mcp add <name> --url <url>`.

## Server row

`notion · 연결됨 · 도구 12개` with the existing switch and **다시 연결**. States added for remote:
**로그인 필요** (orange, button **로그인**), **로그아웃**. Headers and tokens can be edited and reconnected
(Claude makes you delete and re-add; we do not).

## Tool permissions (Claude's three levels)

Per tool: **항상 허용 / 승인 필요 / 차단**. Default from MCP annotations: `readOnlyHint: true` → 항상 허용,
anything else → 승인 필요. Approval uses the app's existing approval card; "항상 허용" from the card is saved.
A changed tool list (hash of names + schemas) puts new or changed tools back to their default and shows a
badge. Remote descriptions and results are wrapped as data, never instructions.

## Under the hood

- `MCPServerEntry`: `url`, header *names*; header values and OAuth tokens live in a separate Keychain service
  (not `GoogleKeychainStore`, whose 4000-byte limit is too small for some JWTs). `mcp-servers.json` keeps
  no secrets.
- `MCPSession` gets a transport: stdio (today) or Streamable HTTP over URLSession (JSON and SSE replies).
  Version: `server/discover` first; 400 + `UnsupportedProtocolVersionError` → pick from `data.supported`;
  400 with anything else → `initialize` + `Mcp-Session-Id` (≤ 2025-11-25); 401 → auth, not a version hint;
  404 with a session → new session once. Old HTTP+SSE (2024-11-05) is not supported at first.
- OAuth 2.1 + PKCE S256: RFC 9728 → RFC 8414/OIDC discovery, `resource` (RFC 8707) on both requests.
  Client: DCR with `application_type: "native"` and a loopback redirect (reuse `GoogleLoopback`) →
  if the server has no DCR, ask for a client ID/secret. CIMD later, once there is an https page for it.
  Refresh tokens; a refresh failure → **로그인 필요**.
- URLs: https only, except `http://localhost` / `127.0.0.1`. The app connects from this Mac, so VPN and
  campus servers work (Claude/ChatGPT connectors cannot reach them).

## Phases

- **P1 — Notion works end to end**: HTTP transport, headers, OAuth (DCR + manual client), one-field add
  sheet, paste parsing (JSON + `claude`/`codex mcp add`), 로그인 states, three-level tool permissions.
  Tests: fake HTTP MCP server in `tools/tests` (JSON/SSE replies, 400 + unsupported version, 400 empty,
  401 + OAuth metadata, 401 without, 404 session expiry, DCR, refresh).
- **P2 — import**: off-by-default import from Claude Code (`~/.claude.json`), Cursor (`~/.cursor/mcp.json`),
  VS Code (user `mcp.json`), Codex (`~/.codex/config.toml`), Windsurf; remote entries from Claude Desktop.
  A short "추천 서버" list (one-click URL fill, URLs checked before shipping).
- **P3**: `ai-illuminati://mcp/install?name=…&config=<base64>` deep link (needs a URL type in the
  Info.plist written by `build_app.sh`, so only with the user's OK), MCP Registry search, old HTTP+SSE,
  CIMD.

## P1 as built

Code: `app/macos/RemoteMCP.swift` (secrets, paste parsing, tool rules, Streamable HTTP, OAuth), wired into
`ExternalMCP.swift`; editor and tool sheet in `Settings.swift`; fixture `tools/tests/fake_remote_mcp.py`,
test `testRemoteMCP()` in `tools/tests/mode2.swift`.

- Modern requests carry `_meta` (`io.modelcontextprotocol/protocolVersion`, `clientInfo`, `clientCapabilities`)
  and the `MCP-Protocol-Version`, `Mcp-Method`, `Mcp-Name` headers; `x-mcp-header` parameters are mirrored as
  `Mcp-Param-*` (base64 sentinel when needed), and a tool whose marks break the rules is left out, as the spec
  requires of HTTP clients. `InputRequiredResult` (MRTR) is answered with an error to the model for now.
- Secrets: `MCPKeychain` (service "AI Illuminati MCP", values split over items to stay under `security -i`'s
  line limit). Tests and previews get `MCPFileSecrets` in their throwaway home.
- OAuth: loopback on 127.0.0.1:33421 when free (so a DCR client keeps its redirect), else any port. A missing
  `code_challenge_methods_supported` is tolerated (PKCE is still sent); a list without S256 is refused.
  Tokens are bound to the server URL they were made for. Sign-out drops tokens locally (no revocation yet).
- Tool rules apply to every added server, but only remote tools default to Ask (local stdio servers keep
  running every tool, as before). Approval uses the chat's approval card for up to 60 s, with Always Allow.
- Not yet: `subscriptions/listen` (tool list changes are seen on reconnect), legacy GET streams, token revocation.
