# Read-only Google Drive backend

Backend implementation only. There is deliberately **no connection button, settings row, file picker or
browser launch** yet. No Google login is started automatically. Nothing is installed or published to `stable`
by adding this backend. The installed app cannot connect a Google account through its UI until that work is
explicitly requested.

## Entry points for the future UI

- `GoogleAuth.shared.beginAuthorization(clientJSON:completion:)` accepts a downloaded **Desktop OAuth client**
  JSON as `Data` and returns the consent URL. The future caller opens that URL in the default browser. This is
  OAuth, not an API key. The completion runs on a background thread; dispatch UI work to the main queue.
- `cancelAuthorization()` cancels a pending sign-in, including an exchange whose response arrives later.
- `connected` reads whether offline credentials exist. `accessToken(forceRefresh:)` is for the backend only.
- `disconnect()` clears the local credentials and attempts remote revocation. Run network operations off the
  main thread. If remote revocation fails, local access is still removed; report the failure to the user.
- `DriveLink.shared.enabled` is the future on/off control (stored under `mcpOff`, like AI Face). Off or disconnected
  means tools are not offered and calls are refused. An in-flight result is withheld if the switch or Google
  login changes before it returns.

The setup still requires a Google Cloud project, Drive API and Sheets API enabled, and a Desktop OAuth client.
Use the system browser, PKCE S256 and a random-port localhost callback. The caller must disclose that
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
  requested delay fits the short retry budget. A tool call has a 50-second HTTP budget. No API writes/deletes.

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
