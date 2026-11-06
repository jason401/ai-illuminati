# Built-in Google sign-in (one registration for everyone)

Written 2026-11-06. Read `CLAUDE.md` / `AGENTS.md`, the top of `HANDOFF.md`, `docs/GOOGLE_DRIVE_BACKEND.md` first and
follow their rules (Korean, simple replies to Younghun; tests before commit; push `main`; **`stable` only after
his explicit "배포해"**; public repo: no emails, tokens, client secrets or personal data).

## Why

Today every person who installs AI Illuminati must create their own Google Cloud project and OAuth client before
connecting Google Drive (sidebar → Google Drive → +). Younghun will share the app with a few people (under 100).
Goal: **Younghun registers once; the app ships his client ID; everyone else only presses "Sign in with Google →
Allow"**, like the Claude and ChatGPT apps. No Google verification or security assessment (fewer than 100 users;
users see Google's "unverified app" warning and pass it with Advanced → Go to).

## Decisions (already made)

1. **Use an OAuth client of type "iOS"**, not "Desktop app". The repo is public and every installed app builds
   from it, so whatever is built in is public. A Desktop client comes with a client secret (`GOCSPX-…`), which
   GitHub secret scanning flags and which should not be published. An iOS-type client has **no secret**, only a
   client ID, which is fine to publish (Google's own Sign-In SDK for macOS uses iOS-type client IDs).
2. **Sign-in window: `ASWebAuthenticationSession`** (AuthenticationServices, macOS 10.15+) with PKCE (S256), a
   random `state`, and the redirect `com.googleusercontent.apps.<ID-PREFIX>:/oauth2redirect` (the client ID
   reversed). `callbackURLScheme` is `com.googleusercontent.apps.<ID-PREFIX>`. No Info.plist URL scheme is needed
   for `ASWebAuthenticationSession`. `prefersEphemeralWebBrowserSession = false` so an existing Google login in
   Safari can be reused.
3. **Token exchange and refresh without `client_secret`** for this client. Same scope as today:
   `https://www.googleapis.com/auth/drive.readonly`. Sheets API reads use the same scope (already in DriveLink).
4. **Keep "own client file" as an advanced fallback** (the current Desktop-client + loopback flow), reached from the
   sidebar's right-click menu: "내 등록 파일로 연결…". Existing logins saved with a secret keep working.
5. The client ID is a constant in source: `GoogleAuth.builtInClientID` (Younghun sends the value; it ends with
   `.apps.googleusercontent.com`). If it is empty, the app falls back to today's flow.
6. If the iOS-type client does **not** work from the Mac app (Google refuses the redirect or the token exchange),
   **stop and report to Younghun**. Do not commit a client secret, do not obfuscate one into the repo, and do not
   switch to another flow on your own.

## Younghun's one-time steps (Korean, give him these)

1. https://console.cloud.google.com → 위쪽 프로젝트 선택 → **새 프로젝트**, 이름 `AI Illuminati` → 만들기.
2. 왼쪽 메뉴 **API 및 서비스 → 라이브러리** → `Google Drive API` 검색 → **사용**. 같은 방법으로 `Google Sheets API`도 **사용**.
3. **Google 인증 플랫폼**(또는 "OAuth 동의 화면") → 시작하기:
   - 앱 이름 `AI Illuminati`, 사용자 지원 이메일은 본인 메일 (로그인 화면에 보여요).
   - 대상: **외부**. 연락처 이메일: 본인 메일. 동의 → 만들기.
   - **데이터 액세스 → 범위 추가** → `.../auth/drive.readonly` 체크 → 업데이트 → 저장.
   - **대상 → 앱 게시** → 확인 (상태가 "프로덕션 단계"가 돼야 해요. 안 하면 7일마다 다시 로그인해야 해요).
4. **클라이언트 → 클라이언트 만들기**:
   - 애플리케이션 유형 **iOS**, 이름 `AI Illuminati Mac`, 번들 ID `local.aiilluminati` → 만들기.
   - 나오는 **클라이언트 ID**(`….apps.googleusercontent.com`)를 복사해서 GPT에게 줘요. 공개돼도 되는 값이에요.
     (iOS 유형에는 클라이언트 보안 비밀번호가 없어요. 혹시 보이면 그건 주지 말아요.)

## Code changes

### `GoogleAuth.swift`

- `static let builtInClientID = "<from Younghun>"`; derived `builtInScheme` (`com.googleusercontent.apps.` + the
  part before `.apps.googleusercontent.com`) and `builtInRedirect` (`<scheme>:/oauth2redirect`).
- `Credentials.clientSecret` becomes `String?` (decoding old Keychain items with a secret still works). Send
  `client_secret` in token/refresh requests only when it is non-nil. `beginReauthorization` uses the saved client:
  the built-in one (no secret) goes through the new flow, an own Desktop client through the loopback flow.
- New `beginBuiltInAuthorization(present:completion:)`:
  - Builds the consent URL like today (`response_type=code`, scope, `access_type=offline`, `prompt=consent`,
    `state`, PKCE S256) with `redirect_uri = builtInRedirect`.
  - Starts the browser step through a small protocol so tests need no UI:
    `protocol GoogleAuthPresenter { func start(_ url: URL, scheme: String, completion: @escaping (Result<URL, Error>) -> Void); func cancel() }`.
    The app's implementation wraps `ASWebAuthenticationSession` (needs an `ASWebAuthenticationPresentationContextProviding`
    returning the chat window, or `NSApp.keyWindow`). User cancel (`ASWebAuthenticationSessionError.canceledLogin`)
    becomes the existing "cancelled" failure, which the UI does not show as an error.
  - On the callback URL: check `state`, read `code` or `error` (`access_denied`, `admin_policy_enforced` → same
    messages as today), exchange with `client_id`, `code`, `code_verifier`, `redirect_uri`,
    `grant_type=authorization_code` (no secret), require a `refresh_token`, save, bump `version`.
  - Same rules as today: never overwrite a working login until the new exchange succeeds; cancellation during the
    exchange must not save a login later; 5-minute timeout.
- Keep the loopback flow and `beginAuthorization(clientJSON:)` unchanged for the fallback.

### `DriveUI.swift` (`DriveCenter`)

- `connect()`: when `GoogleAuth.builtInClientID` is set, show a short alert instead of the Google Cloud steps:
  title "Google 드라이브 연결 (읽기 전용)"; text: 구글 로그인 창이 열려요. "확인되지 않은 앱" 경고가 나오면
  **고급 → AI Illuminati(으)로 이동**을 눌러요(구글 심사를 받지 않은 개인 앱이라 떠요). 로그인 정보는 이 Mac의
  키체인에만 있고 AI에게 가지 않아요. 연결한 뒤 AI가 읽을 드라이브 폴더를 골라요. 읽은 내용은 그때 답하는 AI로
  보내져요. Buttons: "구글로 로그인", "취소". (English text alongside with `L(...)` as elsewhere.)
- Reconnect (orange "다시 연결 필요") goes straight to the sign-in window, no alert.
- Right-click menu of the Drive section (`accountMenu` and the hint rows): add "내 등록 파일로 연결…" which runs
  today's Google Cloud explanation + file picker flow.
- While signing in, the sidebar keeps "브라우저에서 허용을 눌러 주세요 · 취소"; change the text to
  "구글 로그인 창에서 허용을 눌러 주세요 · 취소" for the built-in flow.

### Docs

- `docs/USAGE.md` Google Drive paragraph: sign in with Google; the warning and how to pass it; the own-client
  fallback in one sentence; under 100 users per registration.
- `docs/GOOGLE_DRIVE_BACKEND.md`: the built-in client, why iOS type, no secret anywhere.
- `HANDOFF.md` (local only) top snapshot.

## Tests (`tools/tests/google_drive.swift`, fake server `tools/tests/fake_google.py`)

1. Built-in flow with a fake presenter: the consent URL has the built-in client ID, the reversed-scheme redirect,
   S256 challenge, offline access, the read-only scope, and **no `client_secret` anywhere**.
2. The presenter returns `<scheme>:/oauth2redirect?code=…&state=…`; the token request has the verifier, the same
   redirect and no `client_secret`; the refresh token is stored; a refresh also sends no secret.
3. Wrong `state`, `error=access_denied`, `admin_policy_enforced`, user cancel and cancel during exchange: no login
   saved, an existing login kept.
4. An old saved login with a secret (Desktop client) still refreshes and sends its secret; reconnect picks the
   right flow for each kind.
5. `grep` guard: the repo contains no `GOCSPX-` string.
6. All existing tests still pass (`zsh tools/tests/run_mode2.sh`), then `zsh tools/build_app.sh --stage < /dev/null`
   and `python3 tools/tests/check_signing.py`.

## Real check with Younghun (after the code is in)

1. Install from `main` build only if he asks; otherwise after his "배포해" through stable.
2. Sidebar → Google Drive → + → 구글로 로그인 → warning → Advanced → Allow → the folder picker opens.
3. Add the "Lamb Wave Paper" folder; in plain chat ask Claude and then ChatGPT to summarize the manuscript
   (a Google Doc) and the slides. Both must read the real text.
4. Quit and reopen the app: still connected. Disconnect, then connect again: works without choosing any file.

If step 2 fails because Google rejects the iOS-type client on macOS, report the exact Google error to Younghun
and stop (see Decision 6).
