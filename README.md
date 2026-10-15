# AI Illuminati

맥 메뉴바에 뜨는 작은 앱이에요. Claude, ChatGPT(Codex), Gemini 구독 계정마다 **남은 사용량(5시간 / 주간 %)과 리셋 시각**을 보여줘요.

- 계정을 여러 개 추가할 수 있어요 (예: Claude 개인 + 학교, ChatGPT 개인 + 학교).
- **채팅창**: 질문하면 Claude·ChatGPT·Gemini가 각자 답하고 → 서로 검토해 고치고 → 한 명이 최종 답을 정리해요.
- API 키는 쓰지 않아요. 각 AI 도구에 구독 계정으로 로그인한 상태만 읽어요.
- 비밀번호는 앱이 보지 않아요. 로그인은 각 도구의 공식 로그인(브라우저)으로 해요.

## 설치

1. 이 저장소를 받아요.
   ```bash
   git clone https://github.com/jason401/ai-illuminati.git
   ```
2. `Build AI Illuminati.command`를 더블클릭해요 (Xcode Command Line Tools가 필요해요. 없으면 설치 창이 떠요).
3. 메뉴바 오른쪽 위에 삼각형 안의 눈 마크가 생겨요. 누르면 계정별 사용량이 보여요.

## 계정 추가 / 설정

메뉴의 **설정…**(⌘,)에서 계정 추가, 순서 바꾸기(끌어서 놓기), 이름 바꾸기, 다시 로그인, 빼기를 해요.
추가하면 터미널이 열리고 그 계정으로 브라우저 로그인을 하면 돼요 (Gemini는 agy 설치부터 해줘요).

## 채팅

메뉴의 **채팅창 열기…**(⌘N). 참여할 AI를 고르고 질문하면:
1. 각자 답하기 (동시에) → 2. 서로의 답을 읽고 검토·수정 (한 번) → 3. 남은 사용량이 가장 많은 AI가 최종 정리.
AI마다 남은 사용량이 가장 많은 계정을 써요. AI들은 답만 하고 파일 수정이나 명령 실행은 못 하게 해 둬요.
한 질문에 30초~1분, AI를 최대 8번(요약 포함) 부르니 그만큼 사용량이 쓰여요.

- **대화 저장**: 채팅 앱처럼 왼쪽에 지난 대화 목록이 있어요 (`~/Library/Application Support/AI Illuminati/chats/`). 오른쪽 클릭으로 삭제.
- **이어서 질문**: 질문마다 최종 답을 쓴 AI가 "대화 요약"(300자 이내)을 갱신하고, 다음 질문 때는 그 요약을 같이 보내요.
- **채팅 규칙**: 설정 창에서 고쳐요. 모든 메시지 맨 앞에 붙어요 (기본: 짧게 핵심만, 인사·칭찬 금지, 검토는 3줄 이내).

| AI | 필요한 프로그램 | 사용량을 읽는 방법 | 채팅에서 부르는 방법 |
|---|---|---|---|
| Claude | Claude Code (`~/.local/bin/claude`, 없으면 로그인 때 설치) | 계정 로그인으로 Anthropic 사용량 페이지 조회 (공식 문서에 없는 주소라 바뀔 수 있음) | `claude -p --tools ""` (구독 사용량에서 차감) |
| ChatGPT | ChatGPT 앱 안의 Codex | `codex app-server`의 `account/rateLimits/read` | `codex exec --sandbox read-only` |
| Gemini | Antigravity CLI (`agy`) | `agy -p /usage` | `agy -p --mode plan --sandbox` |

계정마다 폴더를 따로 써요 (`~/.ai-illuminati/accounts/<id>`, Claude는 `CLAUDE_CONFIG_DIR`, Codex는 `CODEX_HOME`).
**같은 ChatGPT 계정을 두 번 추가하지 마세요.** 로그인이 서로 풀려요 (앱이 같은 이메일을 찾으면 알려줘요).

## 파일

- `app/macos/*.swift` — 앱 (메뉴, 설정 창, 채팅 창, 토론 진행, 계정, 사용량 읽기, 로그인, 아이콘)
- `tools/build_app.sh` — 빌드 스크립트 (`xcrun swiftc`, Xcode 프로젝트 없음)
- 앱 데이터: `~/Library/Application Support/AI Illuminati/accounts.json`
