# Privacy Policy — AI Illuminati

Last updated: 2026-11-06

AI Illuminati is a free, open-source macOS app (source: https://github.com/jason401/ai-illuminati).
It runs only on your Mac. The developer runs no server and collects no data from you.

## Google Drive (optional)

- If you choose to connect Google Drive, the app asks Google for **read-only** access
  (`https://www.googleapis.com/auth/drive.readonly`) by default.
- If you explicitly enable writing, the app requests `https://www.googleapis.com/auth/drive`, which grants
  account-wide editing/deletion authority at Google. The app restricts its AI tools to file/folder creation and
  Google Doc text edits, Slides text/page edits and moving Docs/Slides files to trash in folders you allow;
  subfolders can override inherited writing to read only. Folder deletion, permanent deletion, file moving
  and sharing are not provided. Trashed files remain subject to Google’s retention policy.
- The app only reads files inside the Drive folders you add in the app. You can remove a folder or disconnect at any time.
- Your Google sign-in token is stored only in the macOS Keychain on your Mac. It is never sent to the developer or to any AI.
- When you ask an AI a question in the app, the text of the Drive files it reads for that answer is sent to the AI
  service you chose for that answer (for example Anthropic Claude or OpenAI ChatGPT), under your own account with
  that service. Their privacy policies apply to that data.
- Data from Google APIs is not sold, not used for advertising, and not used to train AI models by the developer.
  AI Illuminati's use of information received from Google APIs adheres to the
  [Google API Services User Data Policy](https://developers.google.com/terms/api-services-user-data-policy),
  including the Limited Use requirements.

## Other data

- Chats, settings and usage numbers are saved only on your Mac
  (`~/Library/Application Support/AI Illuminati`).
- Only if you turn on **Chats from other Macs** (Settings → Chat): copies of the chats you choose are saved as plain
  readable files in the sync folder you pick (iCloud Drive by default), so your other Macs can show them. Enterprise
  chats are left out unless you include them. Settings → Chat → "Remove this Mac's copies" deletes them.
- The app talks to the AI services you log in to (through their own command-line tools) and to Google only when
  Drive is connected. Nothing is sent to the developer.

## Removing your data

- In the app: right-click the Google Drive section in the chat sidebar and disconnect. This deletes the token from the Keychain.
- You can also remove the app's access at https://myaccount.google.com/permissions .
- Deleting the folder above removes all local app data.

## Contact

Questions: open an issue at https://github.com/jason401/ai-illuminati/issues .

---

## 개인정보 처리 안내 (요약)

- AI Illuminati는 내 Mac에서만 돌아가는 무료 앱이에요. 개발자는 서버가 없고, 어떤 정보도 모으지 않아요.
- 구글 드라이브는 기본 **읽기 전용**이고, 선택한 폴더만 AI에게 제공해요. 쓰기를 별도로 허용하면 Google 계정 전체 수정·삭제 권한에 동의하지만, 앱의 AI 도구는 허용한 폴더의 생성·Docs/Slides 편집·파일 휴지통 이동을 제공해요. 폴더 삭제와 영구 삭제는 제공하지 않아요.
- 구글 로그인 정보는 내 Mac의 키체인에만 저장돼요.
- AI에게 질문할 때, 그 답에 필요한 파일 내용은 내가 고른 AI 서비스(Claude, ChatGPT 등)로 보내져요.
- "다른 기기의 대화"를 켜면(기본 꺼짐), 고른 대화의 사본이 동기화 폴더(기본 iCloud Drive)에 읽을 수 있는 파일로 저장돼요. 엔터프라이즈 대화는 따로 켜야 올라가요.
- 연결 끊기: 사이드바의 Google Drive를 오른쪽 클릭 → 연결 끊기, 또는 https://myaccount.google.com/permissions
