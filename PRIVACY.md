# Privacy Policy — AI Illuminati

Last updated: 2026-11-28

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
  (`~/Library/Application Support/AI Illuminati`), apart from the sync options below and above.
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

## Skills and memory

- **Where they are kept** (all in `~/Library/Application Support/AI Illuminati`):
  - Memory (your profile and saved facts, with their history for Undo): `memory.json`. Project memory:
    `projects/<project>/memory.json`.
  - Skills (procedures the AIs follow): global ones in `skills/<name>/SKILL.md` with `skills.json` and
    `skills-history.jsonl`; project skills in `projects/<project>/skills/`.
  - Candidates (skills and facts an AI proposed, with the evidence it gave): `knowledge-candidates.jsonl` (global) and
    `projects/<project>/knowledge-candidates.jsonl`. Review meetings are recorded in `knowledge-reviews.json`.
  - With sync on, this Mac's record of what it took from the other Macs: `knowledge-sync.json`.
- **What is sent to an AI**, always to the AI service you chose for that answer, under your own account:
  - Memory: the profile and saved facts go with every plain-chat and project request while memory is on.
  - The `[Skills]` list: the names and short descriptions of the skills that are on (global and the current project's),
    in every request. Skills that are off are not sent.
  - A skill's full text, only when an AI reads it with `skill_read`.
  - Review meetings: when the app is idle, a hidden meeting of up to three of your AIs (Ollama on this Mac only when you
    turned it on) gets the pending candidates with their evidence, the most similar saved skills and facts, and the
    rules for deciding. Candidates from Enterprise chats and projects with an Enterprise audience are left out. Changes
    to your own facts and to skills you saved (🔒) wait for your approval in the Inbox.
- **Sync skills & memory** (Settings → Skills & Memory) is **off by default**. Only if you turn it on: global skills
  (with their on/off state), the memory profile and saved facts, and the global candidates are written to
  `knowledge/<this Mac>/` in the sync folder (iCloud Drive/AI Illuminati Sync by default) as plain readable files:
  `changes.jsonl` (one line per change, including deletions, so a deleted item is not brought back), `skills/<id>/SKILL.md`,
  `state.json`, `device.json` (this Mac's name and sync times) and `candidates.jsonl`; `knowledge/host.json` names the Mac
  that holds the review meetings. Your other Macs read these files and apply the changes. Project skills and project
  memory are never synced. Skills made in Enterprise chats are synced too; memory is never saved from Enterprise chats.
- iCloud Drive is end-to-end encrypted only when Advanced Data Protection is on for your Apple Account. With Standard
  Data Protection (the default) the files are encrypted in transit and on Apple's servers, but Apple holds the keys
  ([Apple: iCloud data security overview](https://support.apple.com/en-us/102651)). Turning sync off stops writing;
  the files already in the sync folder stay until you delete them.

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
- 기억(프로필·저장된 내용)·스킬·후보함은 내 Mac(`~/Library/Application Support/AI Illuminati`)에 저장돼요. 기억과 켜진 스킬의 이름·설명([Skills] 목록)은 답하는 AI에게 매번 보내지고, 스킬 본문은 AI가 skill_read로 읽을 때만 보내져요. 한가할 때 열리는 검토 회의에는 후보와 근거, 비슷한 스킬·기억이 회의에 참여하는 AI에게 보내져요(Enterprise 방 후보는 빼요).
- "스킬 & 기억 연동"을 켜면(기본 꺼짐) 전역 스킬·기억·후보가 동기화 폴더의 `knowledge/<이 Mac>/`에 읽을 수 있는 파일로 올라가 다른 Mac과 같이 써요. 프로젝트 스킬·프로젝트 기억은 올리지 않아요. Advanced Data Protection이 꺼져 있으면 iCloud Drive는 end-to-end 암호화가 아니에요(Apple이 키를 가짐).
- "다른 기기의 대화"를 켜면(기본 꺼짐), 고른 대화의 사본이 동기화 폴더(기본 iCloud Drive)에 읽을 수 있는 파일로 저장돼요. 엔터프라이즈 대화는 따로 켜야 올라가요.
- 연결 끊기: 사이드바 공동 폴더의 Google Drive를 오른쪽 클릭 → 연결 끊기(Google에서도 취소돼요), 또는 https://myaccount.google.com/permissions
