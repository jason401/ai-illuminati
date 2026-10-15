# AI Illuminati — 인수인계 (Claude Code → Codex, 2026-10-14)

이 문서만 읽으면 바로 이어서 작업할 수 있게 정리했어요. 규칙은 `AGENTS.md`(= `CLAUDE.md`와 같은 내용)에, 사용자용 설명은 `README.md`에 있어요.

## 1. 이 프로젝트가 뭔지

영훈님 맥의 메뉴바 앱. 두 가지를 해요.

1. **사용량 게이지**: Claude 계정 2개(개인, 학교=Stanford enterprise), ChatGPT 계정 2개(개인 plus, 학교 edu_plus), Gemini 1개(agy, Google AI Plus)의 남은 사용량(5시간/주간 %)과 리셋 시각. 메뉴는 계정당 한 줄(이름 + █░ 막대 + %), 마우스를 올리면 옆에 자세한 내용.
2. **채팅(단체 토론)**: 질문 → 각자 답(동시) → 서로 검토해 고침(1번) → 남은 사용량이 가장 많은 AI가 최종 정리 → 그 AI가 대화 요약(300자) 갱신. 다음 질문엔 요약만 맥락으로 보냄. 대화는 저장되고 왼쪽 목록에서 다시 열 수 있음.

큰 계획은 `~/Downloads/ai-office-spec.md`(tmux 작업자, 칸반, 인수인계, 픽셀 사무실). 이 앱은 그 앞 단계로 "쉬운 것부터" 시작한 것.

## 2. 절대 규칙 (영훈님과 합의)

- **API 키 사용 금지.** 모든 AI는 각 CLI에 구독 계정으로 로그인한 상태로만 부른다. 자식 프로세스 환경에서 `ANTHROPIC_API_KEY`, `ANTHROPIC_AUTH_TOKEN`, `ANTHROPIC_BASE_URL`, `CLAUDECODE`, `OPENAI_API_KEY`, `GEMINI_API_KEY`, `GOOGLE_API_KEY`를 지운다 (`Account.environment`).
- **비밀번호를 받거나 다루지 않는다.** 로그인은 각 도구의 공식 로그인(터미널 → 브라우저)으로만.
- 로그인 정보(키체인, auth.json)는 **읽기만** 하고 절대 고치거나 갱신하지 않는다. 갱신은 도구 자신에게 맡긴다 (예: `claude auth status`).
- 같은 ChatGPT 계정을 두 번 로그인하면 둘 다 풀린다 (리프레시 토큰 일회용). 앱이 같은 이메일을 찾으면 경고함.
- 채팅에서 AI들은 **답만** 한다 (도구 끔: Claude `--tools ""`, Codex `--sandbox read-only`, agy `--mode plan --sandbox`).
- `claude -p` 사용 가능: 2026-06-15 "별도 크레딧" 변경은 Anthropic이 보류함 → 지금도 구독 한도에서 차감 (support.claude.com/en/articles/15036540). 단 10/7 공지로 Max·Team엔 API 크레딧이 생겨서 어느 쪽이 먼저 차감되는지는 미확인.
- 대답은 한국어로, 쉽게(전문용어 피하기). 매 답변 끝에 `ai-face` MCP의 `set_expression` 호출 (Codex에 그 도구가 있으면).
- "수정하지 마" / "코드 건드리지 마" → 설명만.
- 바깥으로 나가는 일(공개 저장소 전환, 삭제 등)은 먼저 묻고 답을 기다린다. (Claude가 한 번 비공개 저장소를 묻고 답을 기다리지 않은 채 만든 적 있음 — 반복 금지.)

## 3. 지금 상태 (전부 커밋·푸시됨, `main` = `origin/main`)

| 기능 | 상태 |
|---|---|
| 메뉴바 아이콘 (삼각형 속 눈, 템플릿 이미지, 색 변화 없음 — 영훈님 요청) | 완료 |
| 계정 여러 개 (Claude/ChatGPT), Gemini 1개, 설정 창(⌘,)에서 추가·순서·이름·로그인·빼기 | 완료 |
| 사용량: Codex app-server / Claude oauth usage(`limits` 배열) / `agy -p /usage` | 완료 |
| Claude 429 대응 (5분 간격, Retry-After 또는 10분→최대 1시간 대기, 마지막 값 표시) | 완료 |
| 채팅 창(⌘N): 3단계 토론 + 요약 + 저장 + 채팅 규칙(설정에서 편집) | 완료, 실제 질문으로 시험함 |
| ⌘V/⌘C 등 단축키 (숨은 편집 메뉴) | 방금 고침, **영훈님이 아직 확인 안 함** |
| 채팅 창/설정 창의 실제 화면 모양 | Claude는 화면 캡처 권한이 없어 직접 못 봄 |

## 4. 남은 일 / 알려진 문제

1. **⌘V 붙여넣기 확인** — 영훈님이 직접 해봐야 함. 안 되면 `main.swift`의 `keyboardMenu()` 확인.
2. **Claude 학교 계정 429**: Stanford enterprise 계정은 `api/oauth/usage` 조회 제한이 빡빡함 (Retry-After 2681초를 받음). 현재는 기다리며 마지막 값 표시. 더 줄이려면 학교 계정만 15~30분 간격으로.
3. **Gemini 기록이 쌓임**: `agy -p`는 부를 때마다 `~/.gemini/antigravity-cli/conversations/*.db`를 남김(끄는 옵션 없음). 5분마다 도는 `/usage` 확인도 쌓일 수 있음. 영훈님께 "앱이 만든 기록만 지우기"를 제안했는데 아직 답 없음 — 묻기 전엔 지우지 말 것.
4. **답이 여전히 좀 김** (최종 답 300~380자). 채팅 규칙에 "최종 답 3줄 이내"처럼 숫자를 넣으면 더 짧아짐. 영훈님이 원하면 기본 규칙 조정.
5. 채팅은 AI 종류별로 1명(남은 양이 가장 많은 계정)만 참여 — 영훈님이 "우선 이대로" 결정. 체크박스에 실제 계정 이름 표시는 나중 아이디어.
6. agy 첫 설정 때 "데이터 제공 동의" 체크 여부는 영훈님이 정함 (확인 안 됨).
7. 디버그용 파일: `usage.log`(Claude 실패 이유), `last-usage-<id>.json`(마지막 정상 응답, 429 때 대체 표시에 사용) — 지우지 말 것.

## 5. 구조

- `app/macos/main.swift` — 메뉴바, 메뉴(계정 줄 + 옆 메뉴), 숨은 단축키 메뉴, 1분마다 새로고침
- `app/macos/Settings.swift` — `AppModel`(계정 목록·표시 옵션·채팅 규칙, 바뀌면 저장) + 설정 창(SwiftUI)
- `app/macos/ChatWindow.swift` — 채팅 창(왼쪽 대화 목록, 참여 체크박스, 답/토론 펼치기, 요약 보기)
- `app/macos/Discussion.swift` — `Answerer`(CLI 실행) + `Discussion`(3단계 + 요약) + `ChatStore`(`chats/*.json`)
- `app/macos/Accounts.swift` — 계정 목록(`accounts.json`), 계정 폴더 `~/.ai-illuminati/accounts/<id>`, Claude 키체인 이름 규칙
- `app/macos/Usage.swift` — 사용량 읽기 (Codex/Claude/Gemini), `describeLeft`
- `app/macos/Login.swift` — 터미널 로그인 스크립트(끝나면 창 자동 닫힘)
- `app/macos/Icon.swift` — 아이콘
- 앱 데이터: `~/Library/Application Support/AI Illuminati/` (accounts.json, chats/, usage.log, last-usage-*.json, 로그인 .command)
- 설정값: UserDefaults `local.aiilluminati` (`showPercent`, `chatRules`, `geminiInList`)

사용량을 읽는 방법(검증됨):
- **Codex**: `CODEX_HOME=<dir> codex app-server` JSON-RPC → `account/rateLimits/read`(primary=5h, secondary=주간), `account/read`(이메일, 요금제). CLI 위치: `/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex`. 새 계정 폴더엔 `cli_auth_credentials_store = "file"`.
- **Claude**: 키체인 `Claude Code-credentials`(기본) 또는 `Claude Code-credentials-<sha256(CLAUDE_CONFIG_DIR)[0:8]>` → `GET https://api.anthropic.com/api/oauth/usage` (헤더 `anthropic-beta: oauth-2025-04-20`, 문서 없는 주소). `limits` 배열 우선 사용(학교 계정은 전체 주간 한도가 없고 Cowork 주간만 있음).
- **Gemini**: `agy -p /usage` → 탭 구분 줄 `Gemini Models / Weekly Limit Remaining / 97% / ISO 리셋`. 로그인 이메일은 agy 로그의 `applyAuthResult: email=`.

## 6. 빌드 / 시험

- 빌드+재시작: `zsh tools/build_app.sh < /dev/null` (= `Build AI Illuminati.command` 더블클릭). `xcrun swiftc`로 컴파일, Xcode 프로젝트 없음, SwiftUI 매크로(`#Preview`) 못 씀.
  - 주의: 이 SDK에서 SwiftUI `@State`에 값을 넣는 코드가 컴파일 오류가 났음 → 상태는 `ObservableObject`(`AppModel`, `Discussion`)에 둠.
- 서명: AI Face가 만든 "AI Face Local Signing" 인증서 재사용(키체인 "항상 허용"이 빌드 후에도 유지되게). 없으면 임시 서명.
- 화면 없이 시험하는 법: 필요한 파일 + 시험용 `main.swift`를 같이 컴파일해 실행.
  ```bash
  xcrun swiftc -o /tmp/disc app/macos/{Usage,Accounts,Login,Settings,Discussion}.swift /path/to/test/main.swift
  ```
  (시험 `main.swift`에서 `AppModel()`, `Discussion(model:)`을 만들고 `draft` 넣고 `send()`, `running`이 끝날 때까지 `RunLoop.main.run`.) 실제 질문을 보내면 각 계정 사용량이 조금 쓰이고, 대화가 `chats/`에 저장됨.

## 7. git 연동 방법

- 저장소: **비공개** `https://github.com/jason401/ai-illuminati` (영훈님이 "우선 비공개" 결정). 기본 브랜치 `main`, 원격 이름 `origin`.
- 인증: GitHub CLI(`gh`, Homebrew)로 jason401 계정 로그인돼 있음(키체인 저장, https). git은 `gh auth git-credential`을 자격 증명 도우미로 씀 → `git push`/`git pull`에 비밀번호나 토큰을 입력할 필요 없음.
- 작업 방식(AI Face와 같음): 변경이 끝나고 빌드·시험이 되면 `main`에 바로 커밋하고 푸시.
  ```bash
  git add -A
  git commit -m "무엇을 왜 바꿨는지"
  git push
  ```
  시작할 때는 `git pull`로 최신을 받기. 브랜치나 PR은 지금까지 안 씀.
- `.gitignore`: 빌드 결과물(`AI Illuminati.app/`), `app-build.log`, `.DS_Store`.
- 개인정보(이메일, 토큰)가 코드에 들어가지 않게 커밋 전에 확인함.

## 8. Codex 후속 변경 (2026-10-14)

- 채팅 입력을 여러 줄 TextEditor로 교체. Enter/Shift+Enter 줄바꿈, ⌘Enter 또는 버튼으로 전송.
- 기존 AI 병렬 호출은 유지. 최종 답 전에는 중간 답을 펼쳐서 도착 순서대로 표시하고, 최종 답 후에는 기존 접기 UI 사용.
- 컴퓨터 제어 권한이 없어 실제 키 입력과 화면 동작은 아직 확인하지 못함. 다음 확인: 여러 줄 붙여넣기, 한국어 입력, Shift+Enter, ⌘Enter, 토론 중 도착한 답 표시.
- 빌드 성공. 컴파일 캐시는 /tmp 경로 사용. 이번 환경에서는 로컬 서명 인증서를 찾지 못해 빌드 스크립트의 임시 서명으로 완료했고, 앱 열기 명령도 성공. 실제 UI 검증은 미완료.

### 여러 줄 입력 후속 수정
- 사용자가 TextEditor 교체 후에도 줄바꿈이 안 된다고 보고함. NSTextView 기반 입력기로 교체해 Enter/Shift+Enter 줄바꿈, Cmd+Enter 전송을 명시 처리. 한글 조합 중 키 처리는 기본 입력기에 맡김.
- 입력기 단위 실행 시험 통과: 한국어 두 줄, Shift+Enter, Enter, Cmd+Enter. 전체 빌드 성공.
- 기존 앱을 명시 종료한 뒤 새 앱 실행, 프로세스 경로 확인 완료. 실제 채팅창 GUI 입력 검증은 아직 미완료.

### 중간 답변 접기 복원 및 대화 삭제
- 사용자 요청으로 중간 답변 자동 펼치기를 되돌림. 항상 DisclosureGroup 안에서 직접 펼쳐 확인.
- 목록에 휴지통 버튼 추가, 영구 삭제 확인 후 저장 JSON 삭제에 성공했을 때만 메모리 목록에서도 제거. 실패 시 오류 표시 및 대화 유지.
- 시험용 별도 폴더에서 저장 → 삭제 → 재로드 시 부재 및 다른 대화 보존 시험 통과. 기존 사용자 대화는 삭제하지 않음. 전체 빌드 통과, GUI 직접 검증은 미완료.
- 삭제 범위는 앱의 chats/<id>.json과 메모리 대화. agy 자체 기록이나 제공사 측 기록까지 삭제하는 기능은 아님.

## 모드2 추가 (2026-10-14, Codex)

- 새 방 상단에서 모드1(기존 병렬 답변→검토→최종 답→요약) / 모드2(순차 대화) 선택. 대화 시작 후 모드 고정, 기존 방은 자동 모드1.
- 모드2는 참여 AI를 좌우 화살표로 정렬하고 대표 선택. 종류별 남은 사용량이 가장 많은 계정 사용은 기존과 동일.
- 전체 사용자 질문과 AI 발언 원문을 매번 전달하고, 이번 바퀴에서 앞서 나온 발언까지 다음 AI에게 전달. 한 AI당 한 번, 한국어 1~2문장·200자 이내 요청. 원문을 임의로 요약하거나 자르지 않음.
- 별도 검토·최종 답·요약 없음. 모드2의 발언은 본문에 표시, 모드1의 중간 답변은 계속 접힌 상태.
- 한 바퀴 후 대표가 전체 대화를 읽고 다음 순서를 지정(추가 1회 호출). 참여 AI를 정확히 한 번씩 포함한 쉼표 ID 목록만 수용. 실패·잘못된 응답·대표 발언 실패 시 기존 순서 유지 및 안내.
- configuration(모드·참여자·대표·순서)와 턴별 mode/orderNote를 선택 필드로 저장해 이전 JSON 호환 유지.
- 앱 다시 열기 시 창이 없으면 채팅창 표시(main.swift reopen 처리).
- 회귀 시험: `zsh tools/tests/run_mode2.sh` (격리된 임시 계정/대화 폴더 및 가짜 AI 응답 사용, 실제 사용량 소모 없음). 순차 맥락 전달, 다음 순서 적용, 잘못된 순서 처리, 일부 AI 실패, 저장·복원, 이전 파일 호환 검증.
- 전체 빌드 및 회귀 시험 통과. 컴퓨터 제어 연결 성공 후 실제 UI에서 모드2 선택, 순서 변경, Shift+Enter 줄바꿈, Cmd+Enter 전송 확인.
- 실제 CLI 3종 첫 바퀴 성공: ChatGPT 7 → Claude 3 → Gemini 5, 대표 Claude가 다음 순서를 반환해 화면 반영 확인. 후속 질문에서도 세 AI가 첫 바퀴의 숫자 7·3·5를 원문 맥락으로 이어 말하는 것 확인.
- 실제 UI에서 기존 방이 모드1로 열리고 중간 답변이 접힌 상태인 것, 모드2 방 재진입 시 대표·순서가 유지되는 것도 확인.
- 시험용 대화방은 ‘모드2 동작 시험입니다.’로 남김. 기존 사용자 대화는 수정·삭제하지 않음.

### 대화 목록 메뉴 정리
- 상시 휴지통 버튼을 ‘…’ 메뉴로 교체. ‘…’ 또는 우클릭 → ‘대화 삭제…’ → 기존 확인 창을 거쳐 저장 파일 삭제. 삭제 처리 자체는 유지.
