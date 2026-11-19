# 앱 vs 터미널 CLI 답 품질 — 기준값 (0단계, 2026-11-18)

목표: 고치기 전 상태를 재서, 고친 뒤 비교할 기준을 남긴다. **코드는 고치지 않았다** (측정과 기록만).
측정한 AI: Claude (학교) 앱 실행 1회(이 TODO 자체), Codex 짧은 호출 4번, 실제 세션 기록(읽기만).

> **완료 기준 미충족 (일부만 됨).** 같은 입력을 두 환경에 넣고 결과를 비교한 짝 실측은 4개 작업 모두 없다.
> 표는 실제 기록·코드·이 실행 관찰로 채웠고, 답 품질과 결정 회상, TODO 스위치 끔/켬 비교는 비어 있다.
> Claude CLI 실측(①, ③)도 미검증이다. 로그인된 격리 환경이 생기면 §5대로 다시 잰다.

## 0. 결론 먼저

- **2단계 모드별 effort 지정은 4단계 완료 뒤 재검토한다.** 현재 근거와 사용량 증가 우려에 따른 연기이며, 자세한 조건은 §3의 결정 절에 적었다.
- **확인한 기록에서는 앱의 effort가 더 낮다는 증거를 찾지 못했다.** Claude는 앱·터미널 기록 모두 `medium`. Codex
  `codex-main`은 두 환경 모두 `low`(기록). `codex-1792083419`는 설정이 없어 모델 기본값(`medium`으로 **추정**)이다.
  같은 모델·작업으로 품질을 비교하지 않았으므로 "effort가 원인이 아니다"까지는 확정하지 못한다.
- **가장 큰 차이는 세션이 이어지지 않는 것.** 앱 Claude 세션은 중간값 2턴(354개, 압축 0번)에서 끝나고 새로 시작한다.
  터미널은 중간값 34턴(9개 중 5개에서 압축 8번)으로 길게 이어진다. 앱은 새 세션마다 대화 **글**만 다시 받고,
  앞 턴에서 읽은 파일·도구 결과·생각은 잃는다. "예전 결정을 놓치고 덜 꼼꼼하다"와 맞는 증상이다.
  (주의: 앱 세션에는 ask_ai·리뷰·회의처럼 원래 한 번으로 끝나는 호출도 섞여 있고, 터미널 표본은 9개뿐이다.
  그래도 성공한 세션 148개가 다음 턴에 교체된 것은 이 편향과 무관한 직접 증거다.)
- **교체된 기록의 대부분(137/148)은 줄바꿈만 다르다** (관찰한 패턴). 빈 줄 수를 맞추면 앞부분이 같아진다.
  코드상 이런 차이는 `NativeSessions.swift:182`의 "앞부분이 같은가" 검사에 걸린다(§1 (c)의 `ProjectChat.swift:337`).
  다만 `valid=false`는 호출 실패(`:215`)로도 저장되므로, 각 건이 실제로 `:182`에서 버려졌는지는 기록만으로 확정하지
  못했다. 압축 감지(`:214`)는 세션 기록에 압축이 0번이라 배제된다.
- 앱은 사용자 전역 규칙 파일(`~/.claude/CLAUDE.md`)을 Claude에게 주지 않는다. 프로젝트 CLAUDE.md·AGENTS.md는
  CLI가 읽는 게 아니라 앱이 프롬프트 글로 넣어 준다.

## 1. 결과표 (4개 작업 × 2환경)

"실측" = 이번에 직접 돌리거나 기록에서 센 값. "코드" = 코드를 읽어 정해지는 값. "미측정" = 이유를 적음.

| 작업 | 항목 | 터미널 CLI | 앱 |
|---|---|---|---|
| (a) 짧은 코드 검토 | 압축 / 새 세션 | 0 / 1 (한 번 호출) | 0 / 1 (한 번 호출) |
| | effort | Claude medium, Codex low (실측) | Claude medium, Codex low 또는 medium (실측, §3) |
| | CLAUDE.md·AGENTS.md | CLI가 직접 읽음 (Codex 실측 §2-③, Claude는 문서 기준·미검증) | CLI는 안 읽음(Codex 실측, Claude 미검증), 앱이 프로젝트 규칙을 글로 넣음 (코드·이 실행) |
| | 예전 결정 | 해당 없음 | 해당 없음 |
| | 답 품질 점수 | **미측정** (아래 "못 한 것") | **미측정** |
| (b) 압축 뒤 이어 가기 | 압축 | 터미널 Claude 세션 9개 중 5개에서 8번, Codex 15개 중 4개에서 6번 (실측) | 0번 — 앱 Claude 376개·Codex 85개 세션 모두 (실측) |
| | 새 세션 | 압축해도 같은 세션 (`--resume`) | 압축 전에 이미 끊김: 기록 404개 중 166개 버려짐, 그중 148개는 성공한 세션이 다음 턴에 교체됨 (실측) |
| | 예전 결정 | **미측정** (예상: 압축 요약에 남은 만큼) | **미측정** (코드: 대화 글만 감. 길면 요약+최근 턴, `Solo.swift:587-597`) |
| (c) 의견 → 작업 모드 | 새 세션 | 같은 세션 | 바뀌는 턴 자체는 이어짐(의견 턴 기록이 새 기록의 앞부분과 같음). **그다음 턴은 항상 새 세션**: 작업 턴은 `ProjectChat.swift:337`에서 `"\n[User]\n"`(빈 줄 없음)으로 붙이고, 다음 턴은 `Discussion.swift:1402`/`Solo.swift:584`에서 `"\n\n"`으로 붙여 앞부분이 안 맞음. 대화 첫 턴이 작업 턴이어도 같음 (코드 + 기록 137건) |
| | effort | 같음 | 같음 (앱이 `--effort`를 넘기지 않음, 코드) |
| | 예전 결정 | **미측정** (코드상 세션에 있음) | **미측정** (코드상 대화 글로만 전달) |
| (d) TODO 나누기 스위치 | 켬 | 해당 없음 (터미널엔 스위치 없음) | 이 실행: 켜짐 (`[Splitting]` 안내가 프롬프트에 있음). 새 세션 1, 압축 0, effort medium. 60분 미만이라 나누지 않음 |
| | 끔 | 해당 없음 | **미측정** (나누기 조건을 채우는 같은 TODO를 끔/켬으로 돌려야 함). 코드상 차이는 `[Splitting]` 안내 글 유무뿐 (`Todo.swift:1115`) — 세션·effort에는 영향 없음 |

### 이 실행(앱 안 Claude, TODO, 완전 자동) 자체 관찰
- 명령줄(`ps`): `claude -p --tools default ... --session-id <방 id> --setting-sources "" --disable-slash-commands
  --permission-mode bypassPermissions ...` — `--effort`, `--append-system-prompt` 없음.
- 환경: `CLAUDE_CONFIG_DIR=~/.ai-illuminati/accounts/claude-1792083351`, `CLAUDE_EFFORT=medium`.
- 세션: 새로 시작(방 `ownership.json`에 이 계정 기록 1개, context 0자). 이 답 안에서 압축 0번.
- 규칙 파일: 프로젝트 CLAUDE.md·AGENTS.md는 앱 프롬프트의 `[Project rules: ...]` 글로만 받음. 전역 `~/.claude/CLAUDE.md`는 없음.

## 2. CLI 실측 3가지

**① `claude --resume` + `--append-system-prompt`, 압축 전후 규칙 유지? — 미검증 (문서 기준)**
- 공식 문서: "Claude Code records the system prompt on a session's first request and reuses that record until the
  session is compacted. The new text takes effect after that compaction, or in a new session."
  [source: https://code.claude.com/docs/en/agent-sdk/modifying-system-prompts]
- 뜻: 압축 전에는 첫 호출의 규칙이 그대로 유지된다(resume 때 다른 글을 넘겨도 안 보임). **압축 뒤에는 그 호출에
  넘긴 플래그로 다시 만든다** → resume할 때마다 같은 `--append-system-prompt`를 넘기면 유지, 빼면 사라진다.
  기록 끄기는 `--system-prompt-snapshot off` (`claude --help`, 2.1.300).
- 직접 실행 확인: **못 함.** 이 셸에서 `~/.claude`는 "Not logged in"이고, 앱 계정 폴더로 돌리면 실제 계정 데이터에
  세션 파일을 쓰게 되어 하지 않았다. 확인 방법은 §5.

**② Codex에서 시스템 지시를 넣는 설정 키**
- `developer_instructions` (string, "Additional developer instructions injected into the session"),
  내장 지시를 통째로 바꾸려면 `model_instructions_file` (path).
  [source: https://learn.chatgpt.com/docs/config-file/config-reference]
- `codex exec --help`(0.169.0-alpha.11.1): `-c key=value`로 `config.toml` 값을 덮어씀. 바이너리 안에도 `developer_instructions` 있음.
- 실행 확인 (codex-main 홈 `~/.codex`, effort low, 명령 실행 0번). **주의: 규칙 위반.** `~/.codex`는 앱 계정
  `codex-main`과 같은 폴더라 "실제 계정 데이터는 읽기만"을 어겼다. CLI가 세션 기록을 남겼다(스레드
  `01a1f246-e634…`, `01a1f247-065c…`, `01a1f247-1c23…` 및 한도 오류로 끝난 2개, 모두 5개 파일, `~/.codex/sessions/2026/11/18/`).
  지우지 않았다(지우는 것도 쓰기라 사용자 판단). 다음 측정은 `AI_ILLUMINATI_TEST_HOME` 아래 따로 로그인한 홈에서 한다. `-c 'developer_instructions="End every answer with the single word PINEAPPLE on its own line."'`
  → "Hello there / PINEAPPLE". 같은 세션을 `exec resume <id>`로 **`-c` 없이** 이어도 "Goodbye friend / PINEAPPLE" — 처음 넣은 지시가 세션 기록에 남아 유지된다.

**③ 앱 방식으로 실행할 때 프로젝트 CLAUDE.md·AGENTS.md가 읽히나 — Claude 미검증(문서·코드 추론), Codex 실측**
- Claude: **안 읽힐 것으로 본다(미검증).** 문서: "It is not loaded if you pass an empty `settingSources` array."
  [source: https://code.claude.com/docs/en/agent-sdk/modifying-system-prompts] 앱은 `--setting-sources ""`
  (`Workspace.swift:217, :228`)이고 실행 폴더도 프로젝트 밖 세션 폴더(`Answerer.swift:239`)다. 사용자 전역
  `~/.claude/CLAUDE.md`(1234 B)도 안 읽힌다(`--setting-sources ""` + 계정별 `CLAUDE_CONFIG_DIR`에 CLAUDE.md 없음).
  대신 앱이 프로젝트 CLAUDE.md·AGENTS.md를 프롬프트 글로 넣는다(이 실행에서 확인).
- Codex (실행 확인, 명령·파일 읽기 0번): 실행 폴더가 프로젝트면 세션 기록에 `AGENTS.md instructions for /Users/…/AI Illuminati`가
  들어간다. 앱처럼 프로젝트 밖 세션 폴더에서 돌리면 **프로젝트 AGENTS.md는 안 들어가고** `CODEX_HOME`의 전역 AGENTS.md만 들어간다.
  앱 계정 `codex-main`(=`~/.codex`)은 전역 AGENTS.md(2299 B)가 있고, `codex-1792083419`는 없다. 프로젝트 규칙은 Claude처럼 앱이 글로 넣는다.

## 3. effort 값 (읽기만)

| 위치 | 값 |
|---|---|
| `~/.claude/settings.json` | `effortLevel` 없음 (키는 `permissions`뿐) |
| 앱 Claude 계정 폴더 (`claude-1792083157`, `claude-1792083351`) | `settings.json` 없음. 앱도 `--effort`를 안 넘김, 게다가 `--setting-sources ""`라 설정 파일 effort는 어차피 무시됨 |
| 실제 기록 (`"effort"` 필드) | 터미널 Claude 세션: `medium` / 앱 Claude 세션: `medium` / 이 실행: `CLAUDE_EFFORT=medium` |
| `~/.claude.json` 서버 플래그 | `tengu_steady_plum`: `xhigh`,`max` → `high` (높은 effort를 낮추는 플래그로 보임, 두 환경 공통) |
| `~/.codex/config.toml` (터미널 + 앱 계정 `codex-main`) | `model = "gpt-6.1-sol"`, `model_reasoning_effort = "low"` → 기록도 `low` 246회 |
| 앱 계정 `codex-1792083419/config.toml` | effort·model 없음 → 모델 기본값 (`models_cache.json`: gpt-6.2-sol·gpt-6.1-sol 기본 `medium`) |

**판단**: 확인한 기록에서는 앱의 effort가 더 낮다는 증거가 없다(Claude 둘 다 `medium`, `codex-main` 둘 다 `low`,
`codex-1792083419`는 기본값 `medium` 추정). 품질 비교가 없어 effort가 원인이 아니라고 확정하지는 못한다. 다만 두 환경 모두 `medium`/`low`라, effort를 올리면 둘 다 나아질 수는 있다(별개 문제).

### 2단계 결정: effort 지정은 4단계 뒤로 연기 (2026-11-18)

- 0단계 결과를 먼저 보라는 TODO 조건에 따라, 모드별 effort 지정은 이번에 구현하지 않고 **4단계 완료 뒤 재검토**한다.
  위 측정 기록에서 앱의 effort가 터미널보다 낮다는 증거를 찾지 못했고, 같은 모델·입력의 짝 품질 비교도 아직 없다.
  이는 effort가 원인이 아니라고 확정한 결과는 아니다.
- TODO·작업 모드의 effort를 일괄 높이면 사용량이 늘 수 있다. 현재 근거로는 그 비용을 감수할 품질 개선을 확인할 수 없어,
  먼저 세션 연속성 등 앞 단계의 변경 결과를 확인한다. CLI 실행 인자와 기본값은 이번에 바꾸지 않는다.
- 재검토할 때는 §5의 격리된 로그인 홈을 사용해 §1의 작업 하나 이상을 같은 모델·입력으로 다시 실행하고,
  기본 effort와 모드별 지정의 답 품질·사용량·시간을 함께 기록한다. Claude 옵션은 그때 설치된 `claude --help`와
  공식 문서로 확인하고, Codex는 `model_reasoning_effort`를 검증한다. 구현 시 TODO·작업 high, 의견 medium,
  잡담 low의 실행 인자 테스트와 전체 `project_run test`를 완료한다.
- 이번 분기는 연기 결정만 기록하므로 모드별 인자 테스트와 0단계 작업 재실행은 수행하지 않는다. 이는 구현 완료를 뜻하지 않는다.

## 4. 실제 기록에서 센 숫자 (읽기만, 2026-11-18)

| 홈 | 세션 수 | 사용자 턴 중간값 / 최대 | 압축 |
|---|---|---|---|
| 터미널 `~/.claude` | 9 | 34 / 225 | 8 |
| 앱 `claude-1792083351` | 354 | 2 / 23 | 0 |
| 앱 `claude-1792083157` | 22 | 2 / 3 | 0 |
| 터미널 `~/.codex` (방 밖) | 15 | 17 / 74 | 6 |
| 앱 `~/.codex` (방 안) | 12 | 1 / 1 | 0 |
| 앱 `codex-1792083419` | 73 | 1 / 7 | 0 |

방 기록(`~/.ai-illuminati/rooms/*/ownership.json`, 200개 방, 404개): 버려짐 166 = 성공 후 교체 148
(그중 **줄바꿈만 다름 137** — 사유를 확인한 게 아니라 패턴 집계, 실제 내용 다름 2, 다음 기록이 비어 있음 9) + 첫 호출부터 실패 16 + 기타 2.
줄바꿈 예: 첫 턴 `[Complete transcript]\n\n[User]…` → 다음 턴 `[Complete transcript]\n[User]…`;
중간 턴 `…주세요.\n[User]` → 다음 턴 `…주세요.\n\n[User]`.

## 5. 못 한 것과 다시 재는 방법

- 답 품질 점수(같은 질문을 두 환경에 주고 사람이 채점)는 하지 않았다: 터미널 Claude가 이 셸에서 로그인돼 있지 않고,
  앱 계정 폴더로 돌리면 실제 계정 데이터에 쓰게 된다. Codex `codex-main`은 측정 중 사용 한도에 한 번 걸려(21:24, 21:26 해제) 짧은 호출 4번만 했다.
- 고친 뒤 비교할 지표. 세는 방법(읽기만): Claude는 `<홈>/projects/*/*.jsonl`에서 `"compact_boundary"` 줄과
  사용자 턴(`"type":"user"`이면서 `tool_result` 아님), Codex는 `<홈>/sessions/**/*.jsonl`의 `turn_context`(턴·effort)와
  `"type":"compacted"`. 방 기록은 `ownership.json`에서 `valid=false`이고 같은 계정·역할의 다음 기록이 있는 것을 세고,
  `\n+`를 `\n` 하나로 바꿨을 때 앞부분이 같아지면 "줄바꿈만 다름"으로 본다.
  1. 앱 Claude 세션 사용자 턴 중간값 (지금 2) — 커져야 함
  2. 방 기록 중 "줄바꿈만 다름"으로 버려진 수 (지금 137/404) — 0이어야 함
  3. 압축 감지로 버린 수 (지금 0) — 세션이 길어지면 생길 수 있으니 같이 본다
- ①·③ 직접 확인 (`AI_ILLUMINATI_TEST_HOME` 아래 따로 로그인한 `CLAUDE_CONFIG_DIR`로, 실제 계정 폴더 말고):
  ```sh
  id=$(uuidgen)
  claude -p "Say hi" --session-id $id --append-system-prompt "End every answer with BANANA."
  claude -p "Say bye" --resume $id                       # 압축 전, 플래그 없이 → BANANA 유지 예상
  claude -p "/compact" --resume $id
  claude -p "Say ok" --resume $id                        # 압축 후, 플래그 없이 → 사라짐 예상
  claude -p "Say ok" --resume $id --append-system-prompt "End every answer with BANANA."   # 유지 예상
  ```

## 6. 3단계 뒤 (b) 다시 재기 (2026-11-18)

3단계에서 바꾼 것: 지시문의 고정 부분(나는 누구인지, 프로젝트, 폴더 권한, 안전 규칙, 프로젝트 규칙)은
`NativeSessions.turnMarker` 앞에 두고, 세션 호출마다 시스템 프롬프트로 넘긴다(Claude `--append-system-prompt`,
Codex `-c developer_instructions=`). 대화 글에는 이번 턴 부분(파일 목록, 모드, 그림·메모 규칙, 체크포인트)만 간다.
CLI 압축만으로는 세션을 버리지 않는다. 고정 부분이 바뀌면(폴더 권한, 프로젝트 규칙 변경) 새 세션으로 시작한다.

| 지표 (§5 방법, 읽기만) | 0단계 기준 | 지금 (코드 변경 직후) | 테스트로 확인한 새 동작 |
|---|---|---|---|
| 방 기록 / 버려짐 / 성공 후 교체 | 404 / 166 / 148 | 406 / 166 / 148 | — |
| 앱 Claude 세션 압축 (`claude-1792083351`, `claude-1792083157`) | 0, 0 | 0 (356개), 0 (25개) | 압축된 세션도 다음 호출에서 같은 id로 이어짐 (`runtime_contract` "after compaction the same session id is resumed", mode2 "session kept after compaction") |
| 압축 감지로 버린 수 | 0 | 0 | 이제 생기지 않음 (압축 뒤에도 `valid=true`) |
| 이어 쓰기 호출 글에 고정 지시문 | 매번 들어감 | — | 안 들어감, 시스템 프롬프트로만 감 (`runtime_contract` "the session text has the turn part, not the fixed one") |

- **실데이터 숫자가 그대로인 이유:** 설치된 앱(stable)은 아직 예전 코드로 돈다. 이 측정 자체도 예전 코드 실행이다.
  stable에 올린 뒤 며칠 써 보고 §5의 세 지표(사용자 턴 중간값, 줄바꿈만 다른 교체, 압축 감지)를 다시 센다.
- **아직 남은 큰 원인:** 교체된 기록 148개 대부분은 줄바꿈 차이(§1 (c), `ProjectChat.swift`의 `"\n[User]\n"`)라
  이번 단계로는 줄지 않는다. 고정 지시문이 빠져 세션이 덜 빨리 차는 효과는 그 문제가 고쳐져야 실제 숫자로 보인다.
- §2 ①(압축 전후 규칙 유지)은 여전히 실행 확인을 못 했다(격리된 로그인 홈 없음). 문서대로 "매 호출 같은 플래그를
  넘기면 압축 뒤에도 유지"를 전제로 했고, 그래서 플래그를 이어 쓰기 때도 매번 넘긴다. Codex `exec resume`에
  `developer_instructions`를 다시 넘길 때 중복으로 쌓이는지도 아직 확인하지 않았다.
