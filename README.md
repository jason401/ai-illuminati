# AI Illuminati

맥 메뉴바에 뜨는 작은 앱이에요. Claude, ChatGPT(Codex), Gemini 구독 계정마다 **남은 사용량(5시간 / 주간 %)과 리셋 시각**을 보여줘요.

- 계정을 여러 개 추가할 수 있어요 (예: Claude 개인 + 학교, ChatGPT 개인 + 학교).
- API 키는 쓰지 않아요. 각 AI 도구에 구독 계정으로 로그인한 상태만 읽어요.
- 비밀번호는 앱이 보지 않아요. 로그인은 각 도구의 공식 로그인(브라우저)으로 해요.

## 설치

1. 이 저장소를 받아요.
   ```bash
   git clone https://github.com/jason401/ai-illuminati.git
   ```
2. `Build AI Illuminati.command`를 더블클릭해요 (Xcode Command Line Tools가 필요해요. 없으면 설치 창이 떠요).
3. 메뉴바 오른쪽 위에 삼각형 안의 눈 마크가 생겨요. 누르면 계정별 사용량이 보여요.

## 계정 추가

메뉴의 **Claude 계정 추가…** / **ChatGPT(Codex) 계정 추가…** → 이름을 정하면 터미널이 열리고 브라우저 로그인이 시작돼요.
Gemini는 Gemini 줄의 **agy 설치하고 로그인…**을 눌러요.

| AI | 필요한 프로그램 | 사용량을 읽는 방법 |
|---|---|---|
| Claude | Claude Code (`~/.local/bin/claude`, 없으면 로그인 때 설치) | 계정 로그인으로 Anthropic 사용량 페이지 조회 (공식 문서에 없는 주소라 바뀔 수 있음) |
| ChatGPT | ChatGPT 앱 안의 Codex | `codex app-server`의 `account/rateLimits/read` |
| Gemini | Antigravity CLI (`agy`) | `agy -p /usage` |

계정마다 폴더를 따로 써요 (`~/.ai-illuminati/accounts/<id>`, Claude는 `CLAUDE_CONFIG_DIR`, Codex는 `CODEX_HOME`).
**같은 ChatGPT 계정을 두 번 추가하지 마세요.** 로그인이 서로 풀려요 (앱이 같은 이메일을 찾으면 알려줘요).

## 파일

- `app/macos/*.swift` — 앱 (메뉴, 계정, 사용량 읽기, 로그인 버튼, 아이콘)
- `tools/build_app.sh` — 빌드 스크립트 (`xcrun swiftc`, Xcode 프로젝트 없음)
- 앱 데이터: `~/Library/Application Support/AI Illuminati/accounts.json`
