# 앱 vs 터미널 CLI 답 품질 — 기준값 (0단계, 2026-11-18)

목표: 고치기 전 상태를 재서, 고친 뒤 비교할 기준을 남긴다. **코드는 고치지 않았다** (측정과 기록만).
측정한 AI: Claude (학교) 앱 실행 1회(이 TODO 자체), Codex 터미널 실측, 실제 세션 기록(읽기만).

## 0. 결론 먼저

- **effort는 원인이 아니다.** Claude는 앱·터미널 모두 실제 값이 `medium`. Codex는 앱이 터미널과 같거나 더 높다.
- **가장 큰 차이는 세션이 이어지지 않는 것.** 앱 Claude 세션은 중간값 2턴(354개, 압축 0번)에서 끝나고 새로 시작한다.
  터미널은 중간값 34턴(9개 중 5개에서 압축 8번)으로 길게 이어진다. 앱은 새 세션마다 대화 **글**만 다시 받고,
  앞 턴에서 읽은 파일·도구 결과·생각은 잃는다. "예전 결정을 놓치고 덜 꼼꼼하다"와 맞는 증상이다.
  (주의: 앱 세션에는 ask_ai·리뷰·회의처럼 원래 한 번으로 끝나는 호출도 섞여 있고, 터미널 표본은 9개뿐이다.
  그래도 성공한 세션 148개가 다음 턴에 교체된 것은 이 편향과 무관한 직접 증거다.)
- **버려진 세션의 대부분(137/148)은 줄바꿈 차이 때문.** 내용은 같은데 대화 기록 앞부분의 빈 줄 수가 턴마다 달라서
  `NativeSessions.swift:182`의 "앞부분이 같은가" 검사가 실패한다. 압축 때문에 버린 경우(`:214`)는 기록상 0번.
- 앱은 사용자 전역 규칙 파일(`~/.claude/CLAUDE.md`)을 Claude에게 주지 않는다. 프로젝트 CLAUDE.md·AGENTS.md는
  CLI가 읽는 게 아니라 앱이 프롬프트 글로 넣어 준다.

## 1. 결과표 (4개 작업 × 2환경)

"실측" = 이번에 직접 돌리거나 기록에서 센 값. "코드" = 코드를 읽어 정해지는 값. "미측정" = 이유를 적음.

| 작업 | 항목 | 터미널 CLI | 앱 |
|---|---|---|---|
| (a) 짧은 코드 검토 | 압축 / 새 세션 | 0 / 1 (한 번 호출) | 0 / 1 (한 번 호출) |
| | effort | Claude medium, Codex low (실측) | Claude medium, Codex low 또는 medium (실측, §3) |
| | CLAUDE.md·AGENTS.md | CLI가 직접 읽음 (Codex 실측 §2-③, Claude는 문서 기준) | CLI는 안 읽음, 앱이 프로젝트 규칙을 글로 넣음 (코드·실측) |
| | 예전 결정 | 해당 없음 | 해당 없음 |
| | 답 품질 점수 | 미측정 (아래 "못 한 것") | 미측정 |
| (b) 압축 뒤 이어 가기 | 압축 | 터미널 Claude 세션 9개 중 5개에서 8번, Codex 15개 중 4개에서 6번 (실측) | 0번 — 앱 Claude 376개·Codex 85개 세션 모두 (실측) |
| | 새 세션 | 압축해도 같은 세션 (`--resume`) | 압축 전에 이미 끊김: 기록 404개 중 166개 버려짐, 그중 148개는 성공한 세션이 다음 턴에 교체됨 (실측) |
| | 예전 결정 | 압축 요약에 남은 만큼 | 대화 글에 남은 만큼. 길면 요약+최근 턴(`Solo.swift:587-597`)만 감 (코드) |
| (c) 의견 → 작업 모드 | 새 세션 | 같은 세션 | 바뀌는 턴 자체는 이어짐(의견 턴 기록이 새 기록의 앞부분과 같음). **그다음 턴은 항상 새 세션**: 작업 턴은 `ProjectChat.swift:337`에서 `"\n[User]\n"`(빈 줄 없음)으로 붙이고, 다음 턴은 `Discussion.swift:1402`/`Solo.swift:584`에서 `"\n\n"`으로 붙여 앞부분이 안 맞음. 대화 첫 턴이 작업 턴이어도 같음 (코드 + 기록 137건) |
| | effort | 같음 | 같음 (앱이 `--effort`를 넘기지 않음, 코드) |
| | 예전 결정 | 세션에 있음 | 대화 글로만 전달 |
| (d) TODO 나누기 스위치 | 켬 | 해당 없음 (터미널엔 스위치 없음) | 이 실행: 켜짐 (`[Splitting]` 안내가 프롬프트에 있음). 새 세션 1, 압축 0, effort medium. 60분 미만이라 나누지 않음 |
| | 끔 | 해당 없음 | 미측정 (설정을 바꿔 다시 돌려야 함). 코드상 차이는 `[Splitting]` 안내 글 유무뿐 (`Todo.swift:1115`) — 세션·effort에는 영향 없음 |

### 이 실행(앱 안 Claude, TODO, 완전 자동) 자체 관찰
- 명령줄(`ps`): `claude -p --tools default ... --session-id <방 id> --setting-sources "" --disable-slash-commands
  --permission-mode bypassPermissions ...` — `--effort`, `--append-system-prompt` 없음.
- 환경: `CLAUDE_CONFIG_DIR=~/.ai-illuminati/accounts/claude-1792083351`, `CLAUDE_EFFORT=medium`.
- 세션: 새로 시작(방 `ownership.json`에 이 계정 기록 1개, context 0자). 이 답 안에서 압축 0번.
- 규칙 파일: 프로젝트 CLAUDE.md·AGENTS.md는 앱 프롬프트의 `[Project rules: ...]` 글로만 받음. 전역 `~/.claude/CLAUDE.md`는 없음.

## 2. CLI 실측 3가지

**① `claude --resume` + `--append-system-prompt`, 압축 전후 규칙 유지?**
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
- 실행 확인 (codex-main 홈 `~/.codex`, effort low, 명령 실행 0번): `-c 'developer_instructions="End every answer with the single word PINEAPPLE on its own line."'`
  → "Hello there / PINEAPPLE". 같은 세션을 `exec resume <id>`로 **`-c` 없이** 이어도 "Goodbye friend / PINEAPPLE" — 처음 넣은 지시가 세션 기록에 남아 유지된다.

**③ 앱 방식으로 실행할 때 프로젝트 CLAUDE.md·AGENTS.md가 읽히나**
- Claude: **안 읽힌다.** 문서: "It is not loaded if you pass an empty `settingSources` array."
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

**판단**: Claude는 두 환경이 같은 `medium`, Codex는 앱(`codex-1792083419`)이 오히려 높다. effort 차이로는
"앱이 덜 꼼꼼하다"를 설명할 수 없다. 다만 두 환경 모두 `medium`/`low`라, effort를 올리면 둘 다 나아질 수는 있다(별개 문제).

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
(그중 **줄바꿈만 다름 137**, 실제 내용 다름 2, 다음 기록이 비어 있음 9) + 첫 호출부터 실패 16 + 기타 2.
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
- ① 직접 확인 (터미널에서 로그인된 Claude로):
  ```sh
  id=$(uuidgen)
  claude -p "Say hi" --session-id $id --append-system-prompt "End every answer with BANANA."
  claude -p "Say bye" --resume $id                       # 압축 전, 플래그 없이 → BANANA 유지 예상
  claude -p "/compact" --resume $id
  claude -p "Say ok" --resume $id                        # 압축 후, 플래그 없이 → 사라짐 예상
  claude -p "Say ok" --resume $id --append-system-prompt "End every answer with BANANA."   # 유지 예상
  ```
