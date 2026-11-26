# Privacy Policy — AI Illuminati

Last updated: 2026-11-25

AI Illuminati is a free, open-source macOS app (source: https://github.com/jason401/ai-illuminati).
It runs only on your Mac. The developer runs no server and collects no data from you.

## Google Drive (optional)

- Google Drive is connected only if you add it (Shared folders → + → Google Drive…) and sign in with Google.
- The app talks to Drive only through Google's official Drive MCP server (`drivemcp.googleapis.com`), as an
  "AI-powered agent" client. It asks Google for `https://www.googleapis.com/auth/drive` (needed for the MCP server's
  write tools) plus `openid` and `email` (to show which account is connected).
- What the AIs can do is what Google's Drive MCP server offers: search, read and download files, and — only if you turn
  on writing (the pencil) — create files and folders, copy files and upload new versions. It offers no deleting, trashing,
  moving, renaming or sharing, so the app cannot do those. Google itself may ask before some calls (for example files
  owned by others).
- Your Google sign-in is stored only in the macOS Keychain on your Mac. It is never sent to the developer or to any AI.
- When you ask an AI a question in the app, the Drive content it reads for that answer is sent to the AI service you
  chose for that answer (for example Anthropic Claude or OpenAI ChatGPT), under your own account with that service.
  Their privacy policies apply to that data.
- Data from Google APIs is not sold, not used for advertising, and not used to train AI models by the developer.
  AI Illuminati's use of information received from Google APIs adheres to the
  [Google API Services User Data Policy](https://developers.google.com/terms/api-services-user-data-policy),
  including the Limited Use requirements.

## Other data

- Chats, settings and usage numbers are saved only on your Mac
  (`~/Library/Application Support/AI Illuminati`).
- The Usage window (Settings → Accounts → Show Usage…) reads the token counts in the Claude Code, Codex and Gemini (agy)
  session logs on this Mac (read only, compressed `.zst` ones too) and keeps only sums there (`token-usage.json`): by hour,
  model, session id and working folder path, also after a CLI deletes an old log. For the app's own calls that leave no
  log, the usage the CLI reports is kept the same way (`token-usage-app.jsonl`, with what the call was for). The
  conversation text is not kept or sent anywhere. Exports (CSV/JSON) hold only these names and numbers.
- Only if you turn on **All Macs** there: those sums with each account's name, model, session id and working folder path
  are written to `token-usage/<this Mac>.json` in the same sync folder, so your other Macs can add them up. "Remove mine"
  deletes it.
- Only if you turn on **Chats from other Macs** (Settings → Chat): copies of the chats you choose are saved as plain
  readable files in the sync folder you pick (iCloud Drive by default), so your other Macs can show them. Enterprise
  chats are left out unless you include them. Settings → Chat → "Remove this Mac's copies" deletes them.
- The app talks to the AI services you log in to (through their own command-line tools) and to Google only when
  Drive is connected. Nothing is sent to the developer.

## Removing your data

- In the app: right-click Google Drive under Shared folders in the chat sidebar and choose Disconnect. This deletes the
  sign-in from the Keychain and revokes it at Google.
- You can also remove the app's access at https://myaccount.google.com/permissions .
- Deleting the folder above removes all local app data.

## Contact

Questions: open an issue at https://github.com/jason401/ai-illuminati/issues .

---

## 개인정보 처리 안내 (요약)

- AI Illuminati는 내 Mac에서만 돌아가는 무료 앱이에요. 개발자는 서버가 없고, 어떤 정보도 모으지 않아요.
- 구글 드라이브는 직접 추가해야 연결되고, Google 공식 Drive MCP 서버만 써요. AI는 찾기·읽기·내려받기를 하고, 쓰기(연필)를 켜면 파일·폴더 만들기, 복사, 새 버전 올리기를 해요. 공식 MCP에 없는 삭제·휴지통·이동·이름 바꾸기·공유는 하지 않아요.
- 구글 로그인 정보는 내 Mac의 키체인에만 저장돼요.
- AI에게 질문할 때, 그 답에 필요한 파일 내용은 내가 고른 AI 서비스(Claude, ChatGPT 등)로 보내져요.
- "다른 기기의 대화"를 켜면(기본 꺼짐), 고른 대화의 사본이 동기화 폴더(기본 iCloud Drive)에 읽을 수 있는 파일로 저장돼요. 엔터프라이즈 대화는 따로 켜야 올라가요.
- 연결 끊기: 사이드바 공동 폴더의 Google Drive를 오른쪽 클릭 → 연결 끊기(Google에서도 취소돼요), 또는 https://myaccount.google.com/permissions
