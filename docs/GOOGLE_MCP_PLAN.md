# Google Drive 연결 계획 — 공식 MCP만

작성: 2026-11-25. **2단계(앱)는 Drive MCP만으로 만듦(사용자 결정: 지금 되는 것만, Developer Preview 신청 안 함).** 예전 Drive 기능은 [efe2dd5]에서 지웠고, 업데이트한 앱은
`DriveCleanup`이 남은 설정·`drive.log`·키체인 로그인을 지운다.

원칙(사용자 결정): 앱은 Google 공식 MCP 서버에만 연결한다. Drive API 직접 호출, 지운 예전 Drive 코드는 쓰지 않는다.
공식 도구가 없는 일은 다른 방법으로 채우지 않고 "할 수 없는 일"로 둔다.

## 현재 상태 (2026-11-25 저녁 기준, 다른 기기에서 이어가기)

### 된 것 (main에 있음, stable에는 아직 없음)
- **Google Cloud 설정 (사용자가 콘솔에서 함, 다시 할 필요 없음)**
  - 프로젝트: "AI Illuminati" (번호 961717606753). Audience = External, Publishing status = In production(심사 안 받음,
    "확인되지 않은 앱" 경고 + 평생 신규 100명 제한, 2026-11-25 기준 1명 사용).
  - 켠 API: Drive API, Docs API, Sheets API, Slides API, Drive MCP API, Docs MCP API, Sheets MCP API, Slides MCP API.
  - Data Access 권한: drive, documents, spreadsheets, presentations.
  - 로그인 ID: iOS 종류 "AI Illuminati Mac"(Bundle ID `local.aiilluminati`)에 "Use this client for an AI-powered agent" 체크 → 앱이 쓰는 ID.
  - 안 쓰는 것: Desktop 종류 "AI Illuminati Desktop"(secret 필요해서 버림). 콘솔에서 지울 것(사용자). 받은 JSON은 휴지통으로 옮김.
- **앱 코드**
  - `app/modules/AIIntegrations/GoogleDrive.swift` (새 파일): `GoogleDrive` — Drive MCP 서버를 외부 MCP 서버 `gdrive`로 등록.
    - 로그인: `ASWebAuthenticationSession`(Mac 로그인 창), PKCE S256, secret 없음, `resource` 없음,
      scope = `drive openid email`(Docs·Sheets·Slides 권한은 아직 안 받음), `access_type=offline`, `prompt=consent`.
      리다이렉트 `com.googleusercontent.apps.<id>:/oauth2redirect`. 토큰 교환은 `oauth2.googleapis.com/token`.
    - 로그인 정보는 기존 외부 MCP 비밀 저장소(키체인 "AI Illuminati MCP", 키 `oauth.gdrive`)에 저장, ID 토큰의 이메일을 계정 표시용으로 같이 저장.
    - `connect()`: 로그인 → `ExternalMCP.save`로 서버 추가. 새로 추가할 때는 쓰기 도구(create_file, copy_file, upload_file_revision)를 차단 = 읽기만으로 시작.
    - `disconnect()`: 서버·로그인 삭제 + Google `oauth2.googleapis.com/revoke`로 취소.
    - `setWritable` / `isWritable`: 연필 = 쓰기 도구 허용(allow) / 차단(block, AI에게 안 보임). 읽기 도구는 Google이 read-only로 표시해서 항상 실행.
  - `RemoteMCP.swift` 수정: `MCPOAuth.signIn`이 Drive MCP 주소면 `GoogleDrive.run`으로 감(설정 → MCP의 "로그인" 버튼도 같은 길).
    `Saved.account` 추가, `MCPOAuth.keep`, 갱신 때 `resource`가 비어 있으면 안 보냄, `MCPPermissions.saved`.
  - `app/macos/GoogleDriveFolder.swift` (새 파일): 사이드바 공동 폴더의 Google Drive 줄(`FolderSource`, `ChatScreensApp.connect`에서 등록).
    + 메뉴 "Google Drive…", 로그인 중 표시, 연결 직후 4초간 "연결됐어요 · 계정", 연필·눈, 두 번 클릭 = 브라우저에서 Drive,
    오른쪽 클릭 = Drive 열기·공유 켜기/끄기·쓰기·다시 로그인·연결 끊기(확인 창).
  - AI에게는 기존 외부 MCP 통로(`ExternalMCPTools.swift`, ToolHub)로 `gdrive__search_files` 같은 이름으로 3개 AI 모두에게 감.
    엔터프라이즈 채팅에는 안 감, AI별 끄기는 설정 → MCP의 "사용하는 AI".
- **테스트·문서**
  - `testGoogleDrive`(mode2): 로그인 주소·PKCE·secret/resource 없음, 계정 저장, 다른 요청의 응답 거절, 거절은 조용히 취소,
    연필 규칙, 연결 끊기(삭제 + revoke), 그리고 **app/·tools/에 Drive·Docs·Sheets·Slides REST 주소나 `GOCSPX-` 비밀 값이 없는지 검사**.
  - 전체 테스트(`zsh tools/tests/run_mode2.sh`) 통과, `build --stage` 통과 (2026-11-25).
  - docs/MODULES.md(공개 이름 이유·약속 표), docs/api/AIIntegrations.txt(스냅샷), PRIVACY.md(Drive 부분 새로 씀) 고침.
  - `tools/tests/google_drive_live.sh`: 실제 앱 코드로 Google에 붙어 보는 손 확인(사람이 로그인해야 함, 시험 홈만 씀).

### 안 된 것 / 아직 확인 못 한 것
0. **(2026-11-26 확인) 설치된 앱에서 실제로 연결됨**: 사용자가 공동 폴더 + → Google Drive…로 로그인, 채팅의 AI가
   `gdrive__list_recent_files`·`search_files`·`read_file_content`를 실제로 써서 사용자 Drive를 읽음. 연필이 꺼져 있어
   쓰기 도구 3개는 AI에게 안 보임(설계대로). 아래 1·2번은 이걸로 대부분 풀림(연결 방식 세부와 쓰기는 아직).
1. **(11-25 당시) 실제 앱 코드로 Google에 붙는 확인을 못 했다.** `google_drive_live.sh`를 돌렸지만 로그인 창에서 5분 안에 로그인이 안 돼 시간 초과.
   특히 볼 것: `RemoteMCPSession`이 Google에 modern(2026-07-28, `server/discover`)으로 붙는지, 아니면 older(initialize 2025-11-25)로
   붙는지, 그리고 tools/call이 되는지. 앱 밖 시험(파이썬)은 initialize 2025-06-18로만 확인했다.
2. **설치된 앱에서 손 확인 안 함**: 사이드바 줄 모양, 로그인 창이 채팅 창 위에 뜨는지, AI가 실제로 Drive 도구를 쓰는지.
3. **Google "허용?"(elicitation) 미지원**: `RemoteMCPSession`이 `input_required`를 받으면 "아직 지원 안 함" 오류. 내 파일 만들기는
   질문이 없었지만, 남의 파일·조직 밖 공유 파일은 Google 기본 정책상 질문이 오므로 지금은 실패한다. 승인 카드로 보여 주는 작업이 다음 큰일.
4. **Docs·Sheets·Slides MCP는 안 붙임**: 도구 호출이 "Workspace Developer Preview Program 가입 필요"로 거절됨. 사용자 결정: 신청 안 함.
   그래서 문서·슬라이드·시트 **안 고치기**는 안 된다(내용 읽기는 Drive `read_file_content`로 됨). Google이 GA하면 서버 추가 + scope 추가(다시 로그인).
5. 학교(Workspace) 계정 로그인, 다음 날 재로그인 없이 유지되는지 확인 안 함.
6. 앱 미리보기(render_chat)로 Google Drive 줄 그림 확인 안 함.
7. 쓰기 시험으로 Drive에 남은 파일 2개("AI Illuminati 시험 (문서)", "AI Illuminati 시험 (슬라이드)") — 사용자가 지울 것.

### 다른 기기에서 이어가는 순서
1. `git pull` (이 문서·코드가 있는 main).
2. `zsh tools/tests/google_drive_live.sh` → Mac 로그인 창에서 개인 Gmail 로그인(경고: Advanced → Go to AI Illuminati → Continue).
   기대 출력: `[로그인] 성공`, `[연결] 방식: …/ 도구 9개`, `[읽기] list_recent_files: 성공`, `[갱신] … 성공`.
   실패하면 그 줄을 보고 `RemoteMCP.swift`(연결 방식) 또는 `GoogleDrive.swift`(로그인)를 고친다.
3. 전체 테스트 → 사용자가 "stable 배포해" 하면 배포 → 설치 앱에서 공동 폴더 + → Google Drive… → 로그인 → 줄 확인 →
   채팅에서 "Drive 최근 파일 3개 이름 알려줘", 연필 켜고 "Drive에 빈 문서 하나 만들어줘" 시험.
4. 다음 큰일: elicitation(Google "허용?") → 채팅 승인 카드(`ProjectCenter.approve`, `ExternalMCPTools.approve`와 같은 방식),
   응답은 `inputResponses` + `requestState`로 다시 보내기(docs: developers.google.com/workspace/guides/mcp-elicitation).

### 사용자 결정 (2026-11-25)
- Google 공식 MCP만. Drive REST 직접 호출·지운 예전 Drive 코드는 다시 쓰지 않는다. 빈 곳을 다른 방법으로 채우지 않는다.
- 지금 되는 것(Drive MCP)만 한다. Developer Preview는 신청하지 않는다.
- 당분간 혼자 쓰지만 언제든 배포할 수 있게. 연결 끊은 뒤 기록 보관 문제는 나중에.
- 저장소는 공개: 비밀 값·개인정보 금지(로그인 ID는 비밀 아님).
- (구현 때 정한 것) 새 연결은 읽기만(연필 꺼짐)으로 시작, 서버 이름 `gdrive`(예전 `google-drive` 정리 코드와 안 겹치게).

## 목표
다른 사람이 앱을 받아 공동 폴더를 추가하듯 "Google Drive 연결" → Google 로그인 → AI(Claude·ChatGPT·Gemini)가
공동 폴더처럼 Drive에서 작업한다.

## 쓰는 공식 MCP 서버
| 서버 | 주소 | 도구 |
|---|---|---|
| Drive | drivemcp.googleapis.com/mcp/v1 | search_files, list_recent_files, get_file_metadata, get_file_permissions, read_file_content, download_file_content, create_file, copy_file, upload_file_revision |
| Docs | docsmcp.googleapis.com/mcp/v1 | read_doc, update_doc |
| Sheets | sheetsmcp.googleapis.com/mcp/v1 | get_values, get_spreadsheet, update_spreadsheet, update_values, update_formulas, insert_dimension |
| Slides | slidesmcp.googleapis.com/mcp/v1 | read_presentation, read_slide_page, read_slide_page_thumbnail, update_presentation |
| 통합 검색(선택) | workspacemcp.googleapis.com/mcp/v1 | search_corpus |

## 앱이 Google로 보내는 요청
- Drive 작업: 위 MCP 서버 주소로만.
- 그 밖에는 Google 로그인(로그인 창, 로그인 유지)뿐. 공식 MCP도 Google 로그인이 있어야 쓸 수 있다.
- `www.googleapis.com/drive/v3` 같은 예전 API 주소가 코드에 들어가면 실패하는 테스트를 같이 만든다.
- Cloud 프로젝트에서 Drive·Docs·Sheets·Slides API를 켜는 건 Google의 MCP 설정 안내에 있는 프로젝트 스위치일 뿐,
  앱이 그 주소를 부른다는 뜻이 아니다.

## 할 수 있는 일
- 찾기: 이름·내용·종류·날짜·폴더·소유자·공유받은 파일, 최근 파일, 파일 정보·공유 상태 보기
- 읽기: Docs·Sheets·Slides, PDF, Word·Excel·PowerPoint, ODF, PNG·JPEG 내용(댓글 포함). 원본 내려받기, Google 파일은 PDF·PPTX 등으로 내보내 받기
- 새로 만들기: 빈 Docs·Sheets·Slides, 폴더, 파일 올리기(기본은 Google 형식으로 변환), 복사(새 이름·새 폴더로)
- 일반 파일(PDF 등) 내용을 새 버전으로 바꾸기(upload_file_revision)
- Docs 수정: 글자 넣기·지우기, 표, 스타일, 글머리, 머리말·꼬리말·각주, 탭, 댓글, 제안 모드. 그림은 공개 URL만
- Sheets 수정: 값·수식, 행·열 추가·삭제·이동, 시트 추가·복제·삭제·이름, 서식, 조건부 서식, 차트, 필터·정렬, 찾아 바꾸기, 스프레드시트 제목
- Slides 수정: 슬라이드 추가·복제·삭제·순서, 다른 발표에서 가져오기, 글자·표·도형·선, 그림(공개 URL), 영상, 시트 차트, 댓글, 슬라이드 그림으로 보기

## 할 수 없는 일 (공식 도구 없음)
- 파일·폴더 삭제, 휴지통, 이동, 이름 바꾸기(Sheets 제목만 가능), 공유 바꾸기, 설명 등 정보 고치기
- Docs·Slides 문서 제목 바꾸기, 발표자 노트
- 내 Mac 그림을 문서·슬라이드에 바로 넣기(공개 URL만)
- Google이 막는 파일: 암호화(CSE), 다운로드 금지(IRM), 스팸·악성

## Google 쪽 조건
- 다른 사람 파일·조직 밖 공유 파일 등은 Google이 호출마다 "허용?"을 물음(elicitation) → 앱이 채팅 승인 카드로 보여 줘야 함(못 하면 오류)
- 로그인 ID는 "AI-powered agent" 표시 필수(만들 때만 정할 수 있음), 자동 등록(DCR) 없음 → 우리 Cloud 프로젝트에서 만들어 앱에 넣음
- 무료 Standard: 서버마다 하루 5,000회(프로젝트 전체, 모든 사용자가 함께 씀). 2027-04 이후에도 Standard는 무료
- 심사 없이 In production: 로그인 때 "확인되지 않은 앱" 경고, 평생 신규 100명, 7일 재로그인 없음(1단계에서 확인)
- 문서 페이지에 아직 "Developer Preview" 표시(2026-11-24 GA 발표와 다름) → 1단계에서 실제로 열리는지 확인

## 순서
0. 준비(사용자, Cloud 콘솔): 기존 "AI Illuminati" 프로젝트 사용(External, In production 확인됨).
   - 기능 켜기: `console.cloud.google.com/flows/enableapi?apiid=` drive, docs, sheets, slides, drivemcp, docsmcp, sheetsmcp, slidesmcp (`.googleapis.com`)
   - 권한(`/auth/scopes`): `drive`, `documents`, `spreadsheets`, `presentations`
   - 로그인 ID: 예전 iOS 종류 "AI Illuminati Mac"(Bundle ID `local.aiilluminati`)에 "Use this client for an AI-powered agent"를
     나중에 체크해도 됐다(2026-11-25 저장, 바로 적용됨). 비밀 값이 없는 종류라 공개 저장소에 넣어도 된다.
1. 앱 밖 시험(앱 코드 안 건드림) — 2026-11-25 결과:
   - Desktop 종류 로그인 ID: 로그인·MCP는 되지만 토큰 교환·갱신 모두 client secret 필수("client_secret is missing") → 배포에 못 씀.
   - iOS 종류 로그인 ID(`961717606753-4c5cmpcmegejgqdb39plii50ch7rq88m`): Mac 로그인 창(ASWebAuthenticationSession,
     리다이렉트 `com.googleusercontent.apps.<id>:/oauth2redirect`, PKCE)으로 secret 없이 로그인·갱신 성공 → 이걸 쓴다.
   - 4개 서버 initialize·tools/list 성공(Drive 9, Docs 2, Sheets 6, Slides 4), Developer Preview 가입 없이 열림, list_recent_files 읽기 성공.
   - 쓰기 시험: Drive `create_file`로 빈 문서·빈 슬라이드 만들기 성공(내 파일이라 승인 질문 없음).
     Docs·Slides MCP는 `tools/list`는 되지만 도구를 부르면 "Cloud project가 Google Workspace Developer Preview Program에
     가입해야 한다"며 거절 → Drive MCP는 GA, Docs·Sheets·Slides MCP는 아직 Developer Preview.
   - Developer Preview(https://developers.google.com/workspace/preview): 신청서에 Workspace 계정(개인 Gmail 불가, 학교 계정 가능)과
     프로젝트 번호, 승인 며칠. 약관상 GA 전에는 공개 앱에 넣을 수 없고 도메인 밖 사용자에게 열 수 없음.
   - 남은 확인: 학교 계정, 다음 날 재로그인 없이
2. 앱 만들기 (2026-11-25, Drive MCP 서버 하나만; Docs·Sheets·Slides는 Google이 GA하면 붙임): 공동 폴더 + → Google Drive… → Mac 로그인 창 →
   앱이 Drive MCP에 연결해 도구를 그대로 AI 3개에게 → 사이드바 줄(연필=쓰기 도구 허용/차단, 눈=잠시 끔, 오른쪽 클릭=다시 로그인·연결 끊기).
   Google의 "허용?"(elicitation)을 승인 카드로 보여 주는 건 아직 못 함(아래 "현재 상태").
3. 시험: 가짜 서버 테스트 → 실제 작업(예전 슬라이드 보고 새 발표 만들기)
4. 배포 준비: 로그인 ID는 한 곳에서만 바꾸게, 하루 한도 걸리면 안내. 사용자가 늘면 Google 심사

## 정해진 것
- 2027-02-01 규칙(AI는 공식 MCP만): 공식 MCP만 쓰므로 문제없음. 같은 약관의 학습 금지·임베딩 30일은 해당 없음.
- 친구가 로그인하면 자기 계정만: 로그인은 각자 Mac 키체인에, Google은 그 계정이 볼 수 있는 파일만 허용. 앱 로그인 ID는 앱 이름표일 뿐.
- 저장소(public)에 올라가는 건 iOS 종류 AI-agent 로그인 ID 하나(비밀 값 없음). 비밀 값(`GOCSPX-…`)은 커밋하지 않는다.
  커밋 전 비밀값 검사를 추가한다.
- 로그인은 Mac 로그인 창으로 하고 끝나면 창이 저절로 닫힌다(브라우저 탭·127.0.0.1 페이지 없음). 연결 뒤 앱 화면은 보기 좋게 만든다.
- 당분간 사용자 혼자 쓰지만 언제든 배포할 수 있는 구조로 만든다.

## 나중에
- 연결 끊은 뒤 Drive 내용 보관 문제(AI Tools Addendum: 연결 끊거나 권한 취소 후 보관 금지) — 정식 배포 전에 정함

## 출처
- https://developers.google.com/workspace/drive/api/reference/mcp (+ tools_list 각 도구)
- https://developers.google.com/workspace/drive/api/guides/drive-mcp-server-file-eligibility
- https://developers.google.com/workspace/guides/mcp-elicitation
- https://developers.google.com/workspace/docs/api/reference/mcp
- https://developers.google.com/workspace/sheets/api/reference/mcp
- https://developers.google.com/workspace/slides/api/reference/mcp
- https://developers.google.com/workspace/reference/mcp
- https://developers.google.com/workspace/guides/configure-mcp-servers
- https://developers.google.com/workspace/guides/create-credentials
- https://developers.google.com/workspace/guides/quota-usage-tiers
- https://support.google.com/cloud/answer/15549945
- https://workspace.google.com/terms/ai-tools
