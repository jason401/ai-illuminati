# Read-only Google Drive backend

No Google login is ever started automatically.

## UI (added 2026-11-06)

- Chat window sidebar, under Shared folders: a **Google Drive** section (`DriveUI.swift`). `+` connects (an
  short disclosure, then the Google sign-in window) or, once
  connected, opens the folder picker. States: connecting (cancel), reconnect needed (orange), off, no folders.
- **Shared Drive folders** (UserDefaults `driveFolders`, `pausedDriveFolders`): rows like Shared folders, with an
  eye to pause one, double-click opens it in the browser, right-click to remove, reconnect or disconnect. No
  Pencil menu: inherited/read-only/write permission. The picker browses My Drive and Shared with me, or takes a pasted folder link.
- **The app is the gate** (`DriveLink.isAllowed`): Google's `drive.readonly` login covers the whole Drive, so every
  tool call is checked by walking the file's parents up to a shared folder (fresh permission metadata). Search
  results outside are dropped; `drive_list` without a folder lists the shared folders; reads outside are refused.
  No shared folder (or all paused) means no Drive tools at all. Local pointer files and shortcut targets
  must pass the same shared-folder check.
- Settings → Chat → MCP servers: a `google-drive` row with its state and the on/off switch (connecting and
  folders stay in the sidebar).

## Authentication entry points

- `GoogleAuth.shared.beginBuiltInAuthorization(present:completion:)` starts the configured public iOS-client
  PKCE flow through `ASWebAuthenticationSession`. No client secret is sent, including during refresh.
- `GoogleAuth.shared.beginAuthorization(clientJSON:completion:)` accepts a downloaded **Desktop OAuth client**
  JSON as `Data` and returns the consent URL. The fallback UI opens that URL in the default browser. This is
  OAuth, not an API key. The completion runs on a background thread; dispatch UI work to the main queue.
- `cancelAuthorization()` cancels a pending sign-in, including an exchange whose response arrives later.
- `connected` reads whether offline credentials exist. `accessToken(forceRefresh:)` is for the backend only.
- `disconnect()` clears the local credentials and attempts remote revocation. Run network operations off the
  main thread. If remote revocation fails, local access is still removed; report the failure to the user.
- `DriveLink.shared.enabled` is the future on/off control (stored under `mcpOff`, like AI Face). Off or disconnected
  means tools are not offered and calls are refused. An in-flight result is withheld if the switch or Google
  login changes before it returns.

The app owner configured the public iOS client, Drive/Sheets APIs and production read-only consent.
The optional own-client fallback uses a Desktop client, PKCE S256 and a random-port localhost callback. The caller must disclose that
`drive.readonly` covers the account's accessible Drive, not just linked folders, and that retrieved contents go
to whichever AI account is answering. Personal use and public OAuth distribution have different verification
requirements. Testing-mode refresh tokens for these scopes expire after seven days; production tokens can
also expire or be revoked. Never promise permanent sign-in or suggest bypassing organization policies.

Do not pass the client JSON, tokens, or token exchange responses to a model. The app-specific Keychain item
(service `AI Illuminati Google`) contains the client identity and refresh token; access tokens are in memory.
Do not copy the downloaded client JSON to the repository, manifests, logs or account folders.

## Tools and limits

Plain chat's Claude and Codex paths use the existing stdio filesystem bridge, now connected to `ToolHub`.
Gemma/Gemini have no new Drive invocation path. Other conversation modes receive no tool capability.

- `drive_search(query,type?,limit?)`: words in name/indexed text, MIME filters, up to 50 results.
- `drive_list(folder?,limit?,page?)`: My Drive by default; folder ID, Google URL or unambiguous exact name;
  up to 200 entries and a next-page token. Metadata includes parent IDs and owner display names when Google
  supplies them; parent folder names are not fetched separately for every result.
- `drive_read(file,sheet?,start?,end?)`: Google file ID/URL or a local `.gdoc`/`.gsheet`/`.gslides` under this
  answer's linked roots. Only recognized `doc_id`/`url` pointer fields are used; never return the pointer's other
  metadata. An unknown pointer format requires the user to supply the document URL. The actual Drive Desktop
  pointer format has not yet been tested on the user's files.
- Docs: Markdown export, plain-text fallback for unsupported-format errors. Slides: text only; no images,
  layout interpretation or speaker notes. Google's export endpoint has a 10 MB limit.
- Sheets: tab names and formatted values through the Sheets API using the same `drive.readonly` scope. The first
  tab is selected by default; `sheet` selects another. Exporting CSV alone would miss the other tabs.
- Regular PDF, DOCX, PPTX and plain text/CSV/TSV/Markdown: download at most 50 MiB, extract text, remove temporary
  files. PDF scans have no OCR. Office extraction does not interpret embedded images or render original layout.
  Uploaded binary XLSX, legacy Office and other unsupported formats are explicitly rejected. The current
  `MaterialReader` does not actually support XLSX; the original plan's assumption otherwise was incorrect.
- Read offsets count Swift `Character` values, starting at zero, with exclusive `end`. At most 60,000 characters
  are returned per call, together with total length, returned range, name, ID, type and modification time.
- Network requests are bounded, redirects are refused, 401 refreshes once, and 429 retries once only when its
  requested delay fits the short retry budget. A tool call has a 50-second HTTP budget. Mutations are separately opt-in and are never automatically retried.

`ToolHub` issues per-answer, two-hour local capabilities bound to room and linked roots. The socket is mode 0600.
These capability strings are not Google tokens. New manifests use `tools`/`toolSession`; the old `face` key and
face-only socket remain supported for compatibility. The AI Face connection and settings behavior are unchanged.
The tool capability restricts access through this gateway; it is not an OS isolation boundary against other
programs already running with the user's full account permissions.

`drive.log` is private and limited to 500 entries: time, tool name, sanitized ID, result byte count and success.
No document body, query text, email, authorization code or credentials are logged.

## Verification

`zsh tools/tests/run_mode2.sh` includes the Google tests in `tools/tests/google_drive.swift`, served by
`tools/tests/fake_google.py` on localhost. Tests use an in-memory token store, fictional credentials and files,
not a real Google account or login Keychain. They cover PKCE/state, Unicode ranges, token refresh/revocation,
failed replacement login, cancellation, read-only tool routing, Docs export fallback, named Sheets tabs with
apostrophes/slashes, PDF/DOCX, size/error/redirect limits, local pointer scope, a real MCP stdio/socket roundtrip,
other-mode exclusion, switch-off and late-result refusal, and credential-free manifests/results/logs. The fake
server shuts down if its test parent exits.

Also run `zsh tools/build_app.sh --stage` and signing checks before committing. Real Google authorization,
Keychain persistence/ACL behavior, seven-day use, school-admin restrictions, and actual Claude/Codex requests
against the user's Drive still require an explicitly initiated real-account test after the connection UI is added.

## Known issues (to fix later)

- Fixed 2026-11-06: one failed `accept` no longer stops the tool socket (`ToolHub.listen()` continues).
- `drive_read` returns up to 60,000 characters per call (as `read_document` does). Claude Code may cut or refuse
  long MCP results (its MCP output token limit); long Korean text is the likely case. Check with a real long
  Korean Google Doc and lower the default or page it if needed.

## Public-client login and folder gate (2026-11-06)

ASWebAuthenticationSession + PKCE supports a public iOS-type client without a client secret.
The built-in public client ID is configured: Google sign-in is the default; Desktop JSON remains a fallback.
Saved Desktop credentials remain compatible. Public-client reconnect uses the saved client ID.
Local pointer files and shortcut targets must also be inside selected Drive folders. Folder changes
invalidate in-flight results; permission ancestry is fetched fresh. Search follows Drive pages.
Real Google consent, callback, refresh and relaunch still require manual testing with Younghun.

## Optional writing (2026-11-06)

Existing connections remain read only. A folder's pencil menu enables writing after explicit Google consent
for `https://www.googleapis.com/auth/drive`. This is a broad Google grant; the app separately enforces
`driveWriteRules` (nearest ancestor override, default false, paused folders excluded). Add a subfolder
as a selected folder to override it to read only or writable. Permission changes invalidate pending calls.
Google Cloud must include the Drive write scope in consent data access and have Google Docs API enabled.

Tools: `drive_create` creates a folder, UTF-8 plain text file or native Google Doc (240 KB text maximum).
`drive_upload` sends a local file from the chat's linked folders (symlinks resolved, folders refused, 100 MB maximum) with a resumable upload; the session URL must stay on the upload host. `convert: true` imports .pptx/.ppt, .docx/.doc and .xlsx/.xls/.csv as native Slides, Docs or Sheets, keeping images and layout.
`drive_edit_doc` replaces all exact, case-sensitive matches in a native Google Doc using a mandatory
`requiredRevisionId` from `drive_read`. Stale revisions fail. Sheets edits, binary-file overwrites, renaming, moving, folder/permanent deletion and automatic Undo
are not implemented. Slides edits and file trash are described below.
The local app's folder backup does not cover cloud writes; recover Doc edits through Google version history.
Mutation calls are not automatically retried: a timeout can follow a successful server-side change.
Always check Drive before repeating. Mutations already sent cannot be cancelled by switching sharing off.
Official references: https://developers.google.com/workspace/drive/api/guides/create-file and
https://developers.google.com/workspace/docs/api/reference/rest/v1/documents/batchUpdate .

Folder names refresh on app activation and every minute while the sidebar is visible. Metadata failures
keep the old name; IDs, pause/write permissions and in-flight reads are preserved on name-only changes.

## Docs/Slides editing and file removal

Enable Google Slides API in addition to Google Docs API and the existing Drive API. The same full Drive
write scope is accepted; no new OAuth client or separate Slides scope is required.

- `drive_create(kind: slides)` creates an empty native presentation directly in a permitted Drive folder.
  It rejects non-empty text; add pages through the edit tool rather than silently dropping content.
- `drive_slides_get` reads revision, slide IDs and native page elements, including text/geometry/image references.
  `start` is a zero-based slide index; `limit` defaults to 5 (maximum 10), result cap 500 KB. Follow pages to
  cover the whole deck. This is structured inspection, not visual rendering or image/OCR interpretation.
- `drive_edit_slides`: `replace_text` (all exact case-sensitive matches, optional single slide), `add_slide`
  (blank page plus title/body text boxes), `delete_slide` (specified page; last page protected). Requests
  require the previously read revision; Google applies the batch atomically or refuses stale revisions.
  Native text/style/image/table/layout editing beyond these actions is not exposed.
- `drive_edit_doc` still supports exact text replacement; empty replacement removes matching text.
- `drive_trash` accepts only native Docs/Slides, requires a writable folder and exact current filename.
  It PATCHes `trashed: true`; it never invokes permanent DELETE. Folders and shortcuts are rejected.
  Restore manually from Google Drive trash before Google purges it (normally 30 days). No local Undo.

Official API references: https://developers.google.com/workspace/slides/api/reference/rest/v1/presentations/batchUpdate
and https://developers.google.com/workspace/drive/api/guides/delete . Actual Google writes remain to be
validated together with the user; automated tests use fake endpoints and memory credentials only.
