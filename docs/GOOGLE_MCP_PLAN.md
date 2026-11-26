# Google Drive 연결 계획 — 공식 MCP만

작성: 2026-11-25. **계획만 있고 코드는 아직 없음.** 예전 Drive 기능은 [efe2dd5]에서 지웠고, 업데이트한 앱은
`DriveCleanup`이 남은 설정·`drive.log`·키체인 로그인을 지운다.

원칙(사용자 결정): 앱은 Google 공식 MCP 서버에만 연결한다. Drive API 직접 호출, 지운 예전 Drive 코드는 쓰지 않는다.
공식 도구가 없는 일은 다른 방법으로 채우지 않고 "할 수 없는 일"로 둔다.

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
   - 새 로그인 ID(`/auth/clients/create`): Desktop app, "Use this client for an AI-powered agent" 체크. 예전 로그인 ID는 이 표시가 없어 못 씀
1. 앱 밖 시험(앱 코드 안 건드림): 로그인 → 4개 서버 도구 목록(upload_file_revision 포함 여부) → 읽기·만들기·슬라이드 수정·승인 질문 → client secret 없이 로그인되는지 → 학교 계정 → 다음 날 재로그인 없이
2. 앱 만들기: 공동 폴더 + → Google Drive 연결 → 로그인 → 앱이 공식 서버 4개에 연결해 도구를 그대로 AI 3개에게 → Google의 "허용?"은 승인 카드 → 사이드바 줄(연필=쓰기 도구 켬, 눈=잠시 끔, 연결 끊기)
3. 시험: 가짜 서버 테스트 → 실제 작업(예전 슬라이드 보고 새 발표 만들기)
4. 배포 준비: 로그인 ID는 한 곳에서만 바꾸게, 하루 한도 걸리면 안내. 사용자가 늘면 Google 심사

## 정해진 것
- 2027-02-01 규칙(AI는 공식 MCP만): 공식 MCP만 쓰므로 문제없음. 같은 약관의 학습 금지·임베딩 30일은 해당 없음.
- 친구가 로그인하면 자기 계정만: 로그인은 각자 Mac 키체인에, Google은 그 계정이 볼 수 있는 파일만 허용. 앱 로그인 ID는 앱 이름표일 뿐.
- 저장소(public)에 올라가는 건 AI-agent 로그인 ID 하나(공개돼도 되는 값). Desktop client secret(`GOCSPX-…`)은 커밋하지 않는다.
  secret 없이 안 되면 다른 방법으로 채우지 않고 사용자에게 먼저 묻는다. 커밋 전 비밀값 검사를 추가한다.
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
