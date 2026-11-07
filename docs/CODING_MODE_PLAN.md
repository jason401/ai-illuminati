# Plain chat에서 프로젝트 개발 — 구현 계획

작성: 2026-11-06. **아래 설계의 첫 구현을 실행 코드에 반영함.**

구현: plain chat + 메뉴의 프로젝트 연결, repo별 동시 writer 잠금, Claude/Codex 인계,
앱 Git 도구, 승인 카드, 등록 명령 실행, 프로세스 그룹 종료와 journal, commit/push 이후 Undo 제한.
자동 시험은 임시 Git 원격·가짜 AI 응답과 실제 MCP 통로를 사용한다. 실제 계정의 CLI 작업과
앱 업데이트 후 Google Keychain 확인은 사용자와 함께 별도로 확인한다.

사용: plain chat의 `+` 메뉴 → 프로젝트 작업 허용 → Git 최상위 폴더 선택.
`.ai-illuminati.json`의 `commands`에 실행 파일의 절대 경로와 `args` 배열을 등록한다.
등록 명령은 AI sandbox 밖의 사용자 권한으로 실행되며, 실행마다 승인한다.
앱 내부 잠금은 이 앱의 writer끼리 조정하며 외부 에디터/다른 coding agent까지 잠그지는 않는다.
재시작 후 자동 인계는 제공하지 않으며 journal과 미완성 파일은 보존한다.

긴 도구 대기는 Python socket과 vendor MCP timeout을 모두 늘린다.
[Codex 설정](https://developers.openai.com/codex/config-reference/)의 `tool_timeout_sec`와
[Claude 설정](https://code.claude.com/docs/en/env-vars)의 서버 `timeout`을 프로젝트 호출에만 적용한다.

## 1. 확정한 사용자 흐름

별도의 대화 모드·탭·새 채팅 종류를 만들지 않는다. 기존 plain chat(mode 0)에 프로젝트 폴더를 연결해 작업한다.
보기/작성/작성+실행이라는 기존 WorkspaceLevel을 유지하고 `.code` case는 추가하지 않는다.
기존 초안의 “코딩 모드”는 여기서는 **plain chat의 프로젝트 작업 권한**을 뜻한다.

1. plain chat에서 프로젝트 폴더 연결.
2. 연결 폴더 메뉴에서 **프로젝트 작업 허용**을 켬. 대상 repo·허용 동작을 앱이 표시.
3. 사용자가 “이 부분 수정해”라고 요청하면 AI가 조사 → 수정 → 시험/빌드 → commit/push.
4. main 또는 현재 feature branch의 일반 push는 이 프로젝트 권한에 포함.
5. stable 배포는 사용자가 이 채팅에서 요청했을 때 승인 카드를 보여 주고, 승인한 commit만 배포.
6. 사용량 소진 시 다른 지원 AI가 **같은 채팅·같은 작업 폴더·같은 미완성 변경**을 이어받음.

첫 구현은 Claude/Codex의 plain chat에 한정한다. Gemini/Gemma는 현재 도구 통로 지원이 달라 프로젝트
쓰기 실행자로 승격시키지 않는다. 모델이 작업 가능한지 앱이 판단하며, 지원하지 않는 AI로 넘겨놓고
수정했다고 표시하지 않는다. 기존 일반 채팅·Drive·AI Face 경로는 유지한다.

## 2. 현재 코드에서 확인한 조건

- `Solo.swift.soloBinding`: plain chat은 `.view` + `WorkspaceRoot.writable` 조합으로 자기 폴더와 연결 폴더를
  제공한다. `WorkspaceLevel.execute`만 켜면 plain chat이 자동으로 실행 권한을 갖는 구조가 아니다.
- `Workspace.swift`: 현재 `.execute` 비교가 Bash/shell 허용 여부를 결정. account별 인자 생성과 실제
  `WorkspaceInvocation.level`/backup 검증까지 프로젝트 실행 권한을 전달해야 한다.
- `ToolHub.swift`: capability에는 room/roots만 있고, 유효기간은 2시간. room별 도구 목록 필터와 명시적
  폐기 기능이 없다. 단순히 전역 providers에 GitLink를 추가하면 안 된다.
- `workspace_mcp.py`: 일반 도구 socket timeout 15초, Drive 65초. 승인 15분·빌드 수십 분을 같은 동기
  호출에 붙이면 AI는 timeout인데 앱은 계속 실행하는 문제가 생길 수 있다.
- `Solo.swift`: 기존 한도 인계는 제외 계정 목록·미완성 답변 중심. 파일 변경·HEAD·실행 중 프로세스·시험
  결과를 보존하는 프로젝트 checkpoint가 필요하다. plain chat 요청은 현재 900초 경로도 사용한다.
- `Discussion.swift`/`Debate.swift`: CLI 및 하위 프로세스 종료 로직은 재사용하되, 종료 완료를 확인하기 전
  다음 AI에 쓰기 권한을 주지 않는 계약을 추가한다.
- `WorkspaceBackup.swift`: 로컬 변경/Undo는 재사용한다. push와 원격 배포까지 되돌린다고 표시하지 않는다.

## 3. 저장할 프로젝트 연결 정보

`WorkspaceBinding`에 선택 필드 `project: ProjectBinding?`을 추가한다. 기존 저장 자료는 nil로 읽힌다.
`WorkspaceLevel`은 그대로 유지한다. 프로젝트 권한은 모든 연결 폴더의 권한을 일괄 올리는 기능이 아니다.

ProjectBinding:
- 사용자가 고른 프로젝트 디렉터리의 canonical path
- Git top-level 및 canonical common Git directory
- 선택한 remote 이름(초기 origin)과 URL fingerprint
- 프로젝트 작업 허용 여부, 설정 schema version

앱이 git으로 실제 repo를 확인하고 사용자가 선택한 repo만 연결한다. AI의 도구 인자에는 repo 절대 경로를
받지 않는다. 자기 채팅 폴더와 읽기 전용 자료 폴더는 계속 함께 사용할 수 있으나, 프로젝트 작업 대상은
한 채팅에 하나로 제한한다. 다른 자료 폴더가 자동으로 실행/Git 대상이 되지 않는다.

`soloBinding()`이 이 정보를 실행 binding으로 복사한다. 실행 가능 여부는 공통 계산 속성으로 판단하여
기존 `.execute`와 유효한 프로젝트 실행 권한을 모두 처리한다. 승인 취소·repo 변경·backup 실패 시에는
프로젝트 쓰기/Git capability를 주지 않고 원인을 채팅에 표시한다.

## 4. 한 repo의 쓰기 소유권과 AI 인계

**영구 담당 AI가 아니라 동시 쓰기 방지다.** 소유자는 모델명이 아닌 `(roomID, turnID, generation)`이다.

작업 상태:

`준비 → repo 확보 → 상태 조사/backup → AI 실행 → 도구/승인 대기 → 검증 → commit/push → 완료`

사용량 소진:

`한도 감지 → 이전 AI/자식 프로세스 종료 확인 → 이전 capability 폐기 → checkpoint → 다음 계정 선택
→ generation 증가 → 새 capability → 같은 working tree에서 계속`

- 이 인계 동안 repo 소유권은 같은 turn이 계속 가진다. 다른 채팅이 끼어들지 않는다.
- 끝나지 않은 코드, untracked 파일, commit하지 않은 변경도 유지한다. 인계를 위해 commit하지 않는다.
- 다음 AI는 HEAD/status/diff 및 저장된 작업 목표·진행 상황부터 확인한다. 무조건 pull하거나 같은 명령을
  다시 실행하지 않는다. 이미 push/배포/빌드가 완료됐다면 기록으로 확인한다.
- 이전 AI가 마지막으로 요약할 여유가 없어도 앱이 수집한 상태로 인계할 수 있어야 한다.
- turn 전체 취소와 AI attempt 취소를 분리한다. 인계는 이전 attempt만 종료하고, 사용자 Stop은 turn 전체를 종료한다.
- 이전 프로세스가 완전히 끝났다고 확인할 수 없으면 다음 AI를 쓰기 상태로 시작하지 않는다.
- Stop은 모든 관련 CLI/broker 자식 작업 종료와 승인 취소까지 처리하고 소유권을 정리한다.
- 지원 계정이 없으면 변경을 보존하고 “이어서 작업할 계정 필요”로 종료. Git 자동 복구/강제 reset 없음.

락은 앱의 동일 repo 쓰기 경로 전체에 적용한다. 프로젝트 권한을 켠 채팅만 잠그면 다른 일반 채팅의
기존 연결 폴더 쓰기·shared writable root가 우회할 수 있다. 어떤 실행이든 repo를 쓰는 root가 있으면
같은 registry를 거친다. 복수 root 확보는 정렬된 순서로 한 번에 처리해 교착을 피한다.

repo 키는 symlink를 정규화한 common Git directory로 잡는다. 초기에는 worktree도 보수적으로 같은 repo로
직렬화한다. 별도 앱 프로세스 간 advisory lock도 사용한다. 다른 앱의 Claude Code/편집기까지 강제로
막지는 못하므로, 외부 변경은 각 Git/파일 작업 전 재검사하고 충돌하면 멈춘다.
앱 재시작 시 이전 job/PID 기록을 점검한다. 남은 프로세스의 종료 여부가 불명확하면 자동 재개하지 않는다.

## 5. 인계 checkpoint

앱 데이터 폴더의 chat/turn별 파일로 저장한다. repo 안에 상태 파일을 만들거나 Git에 자동 추가하지 않는다.

- 사용자 목표와 현재 선택 프로젝트/branch
- 시작 HEAD, 현재 HEAD, status, staged/unstaged diff 요약, untracked 목록
- 시작 전부터 있던 사용자 변경과 이번 작업의 변경 구분
- backup 위치, 완료/실패/미확인 시험과 정확한 명령·종료 코드
- 생성한 commit, push가 확인된 SHA, 원격 결과 미확인 여부
- 진행 중 job, 취소한 승인, 남은 작업과 다음 단계
- 이전 AI의 요약은 있으면 추가하되 사실 기록보다 우선하지 않음

공통 deadline은 AI가 바뀌어도 초기화하지 않는다. 초기 기준은 실행 45분, 승인 대기 한 건 최대 15분,
전체 wall time 최대 60분으로 두고 UI에 상태를 구분한다. 한도 인계가 무한히 반복되지 않게 한다.

## 6. 앱이 실행하는 Git 도구

`GitLink.swift`를 추가하고 고정 argument 배열로 `Process`를 실행한다. 일반 명령 문자열을 받는 Git 도구는
만들지 않는다. `GIT_TERMINAL_PROMPT=0`, 명령별 timeout, 제한된 출력, 취소 가능한 process group을 적용한다.

| 도구 | 구체적인 동작 |
|---|---|
| git_status / git_diff / git_log | 연결 repo만 조사. diff의 외부 실행/textconv는 사용하지 않음 |
| git_pull | clean 상태에서만 ff-only. dirty/분기/충돌이면 거절. 자동 stash/reset 없음 |
| git_commit | AI가 명시한 상대 경로만 stage/commit. `git add .`나 전체 index 일괄 commit 금지 |
| git_push | 현재 main/feature branch의 일반 push만. branch/remote/HEAD를 다시 검사 |
| git_publish_stable | 아래 승인 계약을 거친 정확한 SHA를 stable로 일반 push |
| git_branch / git_switch | 유효한 이름, clean tree, 보호 branch 제한 확인 |
| project_run | 사용자 설정의 명명된 명령 실행. 아래 별도 승인 계약 적용 |

- `git_push`로 stable 등 배포용 branch를 직접 지정하는 우회는 거절한다.
- 강제 push, branch 삭제, history rewrite, reset --hard, remote/config 변경 도구는 제공하지 않는다.
- Git hooks와 암묵적인 외부 프로그램 실행을 가능한 한 끈다. credential helper는 사용자의 기존 로그인
  경로를 재사용하되 출력에 자격 정보를 넣지 않는다. repo가 지원되지 않는 특수 Git 구성을 요구하면
  조용히 보호를 푸는 대신 해당 구성을 명시적으로 처리하거나 미지원으로 보고한다.
- 작업 시작 전부터 staged/수정된 파일을 자동 포함하지 않는다. 기존 변경과 같은 파일을 고쳐 분리하기
  어려우면 포함할 diff를 보여주고 사용자 판단을 받는다. 다른 staged 파일은 보존한다.
- 인계 중 dirty 상태에서는 pull을 반복하지 않는다. 최초 clean 시작일 때만 동기화하고, 이후에는
  remote 변경을 확인하되 현재 변경을 덮어쓰지 않는다.
- push timeout 등 원격 적용 여부가 불명확하면 remote SHA를 확인한다. 확인 전 성공/실패를 단정하거나
  자동 재실행하지 않는다.

## 7. stable 승인 계약

승인 대상은 `(repo, remote URL, source SHA, destination stable, 작업 generation)`이다.
카드에는 프로젝트·branch·짧은 SHA·포함 commit 요약·관련 시험 결과를 표시한다.

- 사용자가 이 채팅에서 배포를 요청한 경우에만 카드 생성.
- 승인 후 main이 바뀌어도 새 main을 보내지 않고 승인받은 immutable SHA만 보냄.
- Stop, 연결 해제, 대상 변경, timeout, 관련 채팅창 닫기, 인계 시 미완료 요청은 취소.
- 승인 완료/거절은 한 번만 소비. 이전 AI가 가진 capability나 뒤늦은 클릭으로 실행 불가.
- 일반 fast-forward 검증을 통과하지 않으면 중단. 원격이 달라진 경우 다시 확인하고 필요하면 새 카드.
- 성공/실패/결과 미확인 상태를 실제 Git 응답으로 기록. 모델의 “배포 완료” 문장으로 판정하지 않음.

## 8. project_run과 승인

`.ai-illuminati.json` 예시(이 repo):

```json
{
  "version": 1,
  "commands": {
    "test": {"executable": "/bin/zsh", "args": ["tools/tests/run_mode2.sh"]},
    "build": {"executable": "/bin/zsh", "args": ["tools/build_app.sh", "--stage"]}
  }
}
```

실행 cwd는 연결 repo, stdin은 닫고 stdout/stderr는 제한된 로그로 저장한다. AI는 `test`, `build` 같은
등록 이름만 요청한다. 임의 shell string/환경 변수/다른 cwd를 도구 인자로 넘기지 못한다.

승인 카드에는 실제 해석한 executable/args/cwd, repo 변경 상태와 **AI sandbox 밖에서 이 프로젝트 코드를
사용자 권한으로 실행한다는 점**을 표시한다. 승인 빈도 제안: 첫 버전은 실행 요청마다 승인을 받는다(구현 전 사용자 검토 대상). 매번 달라지는
프로젝트 코드를 단순 “명령 이름 한 번 승인”으로 영구 허용하지 않는다. 추후 승인 재사용이 필요하면
명령 정의와 실행할 코드의 fingerprint/변경 추적을 별도로 설계한다.

이 도구는 고정된 이름이어도 스크립트·테스트·빌드 설정이 실행하는 코드에 영향받는다. 따라서
“AI CLI에는 직접 network/Keychain 권한이 없다”는 것과 “전체 작업이 sandbox 안에서만 돈다”는 것은
다르다. 후자는 보장하지 않는다. 사용자 승인받은 프로젝트 실행에 한해 앱이 권한을 위임하는 구조다.
패키지 설치가 필요하면 별도 명명된 명령으로 명시하고 같은 승인을 거친다.

실행 중에는 AI의 추가 쓰기 요청을 직렬화하고 외부 변경을 감지한다. 승인 후 실행 직전 명령 정의가
달라지면 실행하지 않고 재승인을 요구한다. 숨겨진 shell 입력을 추가하거나 자동으로 설치/배포하지 않는다.

## 9. 긴 도구 호출과 승인 대기

첫 버전은 기존 동기 MCP 요청/응답을 유지한다. 긴 작업 때문에 별도의 AI polling 프로토콜이나
대화를 다시 생성하는 모드를 도입하지 않는다. 대신 앱 내부에서 요청을 job으로 기록하고 관리한다.

1. Git 쓰기/project_run 요청을 앱의 job에 등록. 상태는 승인 대기 → 실행 → 완료/실패/취소/결과 미확인.
2. 앱의 background queue에서 승인과 프로세스 종료를 기다린다. main thread는 기다리지 않는다.
3. Python bridge와 ToolHub의 프로젝트 도구 timeout만 전체 wall deadline보다 여유 있게 설정한다.
   기존 일반 도구 15초·Drive 65초 정책은 유지. native CLI timeout도 같은 실행 정책에 맞춘다.
4. 승인 카드·실행 로그·Stop은 UI에서 계속 동작. AI는 원래 tool call의 최종 결과를 받고 다음 단계를
   진행한다. CLI 재시작이나 모델의 상태 polling을 요구하지 않는다.
5. CLI 종료/Stop/권한 폐기 시 기다리는 job과 승인도 함께 취소한다. socket timeout만으로 취소를
   판단하지 않으며, 늦은 승인 클릭이 실행을 재개하지 못하도록 terminal state를 검사한다.
6. 승인 후 실행된 Git/빌드는 결과를 앱 journal에 기록. 응답 전달이 실패했더라도 다음 AI가 그 기록을
   확인하고 중복 commit/push/배포를 하지 않는다.

긴 요청은 background 작업 자원을 점유하지만 동시 writer 수가 제한돼 있고, 현재 MCP/CLI 흐름을
그대로 사용할 수 있다는 장점이 있다. 실제 CLI가 이 긴 대기를 견디는지는 첫 단계 scratch 실험에서
확인한다. 불가능할 때만 비동기 job ID/자동 resume 방식으로 확장한다.

## 10. ToolHub와 프로젝트 규칙

ToolContext에 선택적인 프로젝트 scope, turn/run ID, generation, 허용 기능, cancellation 참조를 추가한다.
기존 room/roots 초기화와 FaceLink/DriveLink 도구 동작은 호환 유지한다.

- providers 전역 active 여부와 별개로 `tools(context:)`에서 이 호출자에게 허용한 도구만 제공.
- `call` 시에도 scope/현재 소유권/generation을 다시 확인. 목록 필터만으로 권한을 보장하지 않음.
- register/revoke를 명시화. Stop/인계/작업 종료/프로젝트 해제 시 이전 토큰 폐기.
- 프로젝트 Git을 켜도 FaceLink/DriveLink의 켜짐 상태에 의존하지 않게 함.
- Bridge manifest에는 capability만 넣고 Google/Git/Keychain 자격 정보는 넣지 않음.
- `AGENTS.md`/`CLAUDE.md`는 repo 최상위에서 읽어 크기 cap 30k 적용, 잘린 사실 표시. 외부 symlink는
  읽지 않음. 이 프로젝트의 작업 지침으로만 적용하고 앱의 승인/권한 정책을 우회할 수 없게 함.
- CLI cwd를 repo root로 바꿀 때 세션/임시 이미지/manifest 경로는 절대 경로로 유지한다. 기존 native
  session resume가 cwd 변경을 허용하는지 먼저 실험하고, 안 되면 세션 폴더 cwd를 유지하며 명시 경로로 실행.

## 11. Undo와 작업 기록

기존 backup/변경 목록을 재사용한다. 하나의 사용자 작업은 AI가 인계돼도 같은 작업 기록에 연결한다.

- push 전 로컬 Undo는 현재 HEAD/index/파일 상태와 충돌 여부를 검사한다. 로컬 commit이 생겼으면
  기존 파일 복원만으로 Git 상태까지 되돌렸다고 표시하지 않음. 초기에는 commit 이후 자동 Undo도
  제한하고 새 수정 commit 안내로 전환한다.
- 이 turn이 push를 하나라도 완료하면 그 turn 전체의 기존 Undo를 끈다. 다른 run의 backup도 현재
  HEAD와 맞지 않으면 거절해, 오래된 Undo 버튼으로 push된 상태를 훼손하지 않게 한다.
- 채팅에는 pull/시험/commit/push/인계/배포 결과를 앱 기록으로 짧게 표시. 코드 출력 cap 60k,
  로그·명령 출력에서 자격 정보를 노출하지 않음. raw 로그를 모델에게 무제한 전달하지 않음.

## 12. 파일별 변경 지도

| 파일 | 변경 내용 |
|---|---|
| Workspace.swift | ProjectBinding 저장/복원, plain chat 실행 가능 여부 공통 계산, sandbox/manifest scope |
| Solo.swift | 프로젝트 실행 진입, repo 소유권, checkpoint 기반 인계, 같은 turn에서 도구 결과 처리 |
| Discussion.swift | 요청 deadline/승인 대기 반영, 실행 cwd, turn별 프로젝트 결과 저장 |
| Debate.swift | CLI/broker 자식 프로세스 종료 완료 확인, Stop 전파 |
| NativeSessions.swift | 계정 인계 시 세션과 prompt 범위 정리, cwd 호환 확인 |
| ToolHub.swift | context별 목록/호출 필터, generation 검사, capability register/revoke |
| workspace_mcp.py | 프로젝트 도구 요청/응답 전달, 긴 timeout 처리 |
| GitLink.swift (신규) | scope 고정 Git 도구, argument/path 검증, 원격 결과 확인 |
| ProjectJobs.swift (신규) | job 상태·승인·취소·process group·정확한 SHA 배포 |
| ProjectWork.swift (신규) | repo registry/락, 작업 checkpoint와 실행자 교체 |
| WorkspaceBackup.swift | 작업 ID 연결, commit/push 후 Undo 제한·HEAD 충돌 검사 |
| ChatWindow.swift | plain chat 연결 메뉴의 프로젝트 권한, 승인 카드, 진행/인계/결과 표시 |
| .ai-illuminati.json (신규) | 이 repo의 test/build 명령. 임의 shell 입력 없음 |
| docs/USAGE.md | plain chat 프로젝트 작업·승인·인계 사용법 |

## 13. 구현 순서와 단계별 완료 조건

1. **실제 CLI 가능성 실험**: scratch repo + 기존 bridge로 Claude/Codex 각각 로컬 도구 호출과 session resume
   확인. 실제 환경에서 막히면 오류를 정리하고 설계 수정; sandbox를 임의로 풀지 않음.
2. **프로젝트 scope/락/읽기 Git 도구**: 기존 채팅 자료 호환, 다른 채팅 쓰기 차단, context 격리 검증.
3. **commit/push/branch**: 임시 bare origin으로 동작·dirty/staged 보존·거절 경로 검증.
4. **job/승인/project_run/stable**: 긴 동기 도구 호출이 유실되지 않고 UI/Stop이 정상 동작.
5. **한도 인계/checkpoint**: 첫 AI가 파일을 수정하고 끊겨도 다음 AI가 같은 변경을 이어 완수.
6. **UI·Undo 통합**: 별도 채팅 모드 없이 plain chat에서 전 과정 확인.
7. **실제 시험·배포**: scratch repo에서 Claude→Codex 인계와 서명 빌드 확인. 이후 실제 프로젝트에 적용.

큰 변경을 단계별 commit으로 분리하되 미완성 기능은 stable로 보내지 않는다. 최종 main push 전 전체 회귀
시험·`build_app.sh --stage`·서명 검증. stable 배포는 사용자의 별도 요청 이후에만 수행한다.

## 14. 필수 시험 목록

임시 bare repo/clone, 가짜 AI runner, 메모리 승인 UI 상태를 사용한다. 실제 GitHub나 실제 사용자 repo는
자동 시험에 사용하지 않는다.

- 기존 저장 chat/WorkspaceLevel 복원, plain chat mode 0 유지, 관련 없는 root 권한 유지.
- 프로젝트 scope 없는 요청·다른 room·폐기된 capability·이전 generation 요청 거절.
- FaceLink/DriveLink를 꺼도 프로젝트 도구는 독립 동작; 기존 Drive 권한 경로는 회귀 통과.
- clean ff pull 성공, dirty/staged/untracked/분기 거절 및 사용자 변경 보존.
- 선택 경로 commit, 기존 staged 보존, traversal/symlink/다른 repo 경로 거절.
- 일반 push 성공/비-fast-forward 거절/timeout 후 원격 결과 재확인.
- stable 도구 외 직접 배포 우회 거절. 승인 SHA와 branch 최신 SHA가 달라도 승인 SHA만 배포.
- 승인 거절/timeout/Stop/해제/늦은 클릭/인계에서 job 한 번만 종료, 예전 요청 재사용 불가.
- 명령 정의 변경 시 승인 무효, 임의 명령/cwd/환경 인자 거절, 출력 cap 및 stdin 종료.
- 15초 이상 실행·승인 대기가 브리지 timeout으로 유실되지 않고 UI/job/CLI deadline과 일치.
- 같은 repo의 두 채팅·다른 AI·기존 일반 쓰기·동일 commonDir worktree·다른 앱 인스턴스 직렬화.
- 한도 소진 시 자식 writer 종료 확인 후 다음 AI 시작. uncommitted/untracked 보존, 불필요한 pull/중복
  build/commit/push 없음. 계정 전부 소진 시 변경 보존. 사용자 Stop은 자동 인계하지 않음.
- commit/push 후 Undo 제한과 오래된 backup의 HEAD 충돌 거절.
- 앱 재시작에서 미확인 job을 임의 재실행하지 않음.
- 실제 서명 빌드와 CLI별 도구 접근은 사용자와 scratch repo에서 별도 확인.
