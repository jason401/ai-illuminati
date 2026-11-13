# 모듈화 후속 작업 (T1–T5)

## T1 측정

전체 테스트(`zsh tools/tests/run_mode2.sh`)가 시간을 어디에 쓰는지 재서, "바뀐 곳의 테스트만 돌리기"(T2)가
의미 있게 줄일 수 있는지 판정한다. 2026-11-13, HEAD `e2dd070`, 앱·테스트 소스 변경 없음.

### 어떻게 쟀나
- 외부 전체 시간: 래퍼 스크립트가 명령 시작 직전과 끝난 직후의 시각(`Time::HiRes`)을 기록한 차이.
- 단계별 시간: 출력의 각 줄에 받은 시각을 붙이고, `[n/11]` 줄에서 다음 `[n/11]` 줄(마지막 단계는 명령 끝)까지로 근사.
- 이름 있는 테스트 시간: `runTest`(tools/tests/mode2.swift:38)가 출력하는 `  이름: x.x s` 값.
- 앱의 `project_run`은 줄마다 시각을 주지 않아서, 측정 실행 두 번은 같은 명령을 셸에서(샌드박스 밖) 돌렸다.
  샌드박스 안 첫 시도는 `testRuntimeThroughApp`의 프로세스 그룹 검사에서 멈춰(RC 133) 제외했다. 같은 HEAD로
  `project_run test`도 한 번 성공했으며(외부 시각 기준 452 s 이하, 이름 있는 테스트 합 170.1 s), 시작·끝 시각을
  정확히 잴 수 없어 판정에는 넣지 않았다.

### 시간 표 (초)

| 항목 | 실행 1 (11:51:42–12:02:06) | 실행 2 (12:02:12–12:10:50) |
|---|---:|---:|
| 외부에서 잰 전체 시간 | 623.2 | 518.4 |
| [1/11] Module guards and the data folder rule | 0.6 | 1.9 |
| [2/11] Modules on their own | 229.8 | 238.1 |
| [3/11] Real data folder check | 2.4 | 1.1 |
| [4/11] Build WorkspaceDocument | 2.7 | 1.5 |
| [5/11] Installer tests | 0.5 | 0.6 |
| [6/11] Workspace MCP tests | 0.5 | 0.5 |
| [7/11] Material fixtures | 0.1 | 0.1 |
| [8/11] Compile app tests | 48.0 | 36.9 |
| [9/11] Run app tests | 308.0 | 219.1 |
| ↳ 이름 있는 테스트 57개 합 | 263.8 | 179.0 |
| ↳ `runTest` 밖 맨 위 수준 검사 (첫 `▶`까지) | 44.2 | 39.9 |
| ↳ 마지막 테스트 뒤 | 0.0 | 0.2 |
| [10/11] Space web view isolation | 24.1 | 17.2 |
| [11/11] Icon check | 6.3 | 1.2 |
| `runTest` 밖 전체 (전체 − 이름 있는 테스트) | 359.4 | 339.4 |

- `runTest` 밖 맨 위 수준 검사는 [9/11] 안에서 첫 `runTest` 전에 도는 `do { … }` 블록들(PASS 줄 37개)이다. PASS 줄은
  파이프에서 즉시 내보내지지 않아 검사별 시간은 나눌 수 없고, 합만 적었다. 실행 파일 시작 시간도 여기에 들어 있다.
- 두 실행의 차이(특히 `testProjectWork` 60.6 s / 38.7 s, `testRunConditions` 16.2 s / 7.6 s)는 Mac의 다른 부하로 보인다.

### 이름 있는 테스트 시간 (초, 출력 순서 그대로)

| 테스트 | 실행 1 | 실행 2 |
|---|---:|---:|
| testToolHub | 0.0 | 0.0 |
| testGoogleDrive | 7.7 | 7.1 |
| testWindowDrag | 0.4 | 0.3 |
| testRunConditions | 16.2 | 7.6 |
| testRuntimeThroughApp | 5.1 | 4.4 |
| testChatLinks | 3.4 | 3.2 |
| testChatThroughCLI | 6.8 | 4.1 |
| testProjectWork | 60.6 | 38.7 |
| testAskAI | 0.9 | 0.4 |
| testCollabLog | 2.3 | 0.9 |
| testMeetingTool | 1.5 | 0.8 |
| testProjectCreate | 10.0 | 8.9 |
| testUpdateChannels | 7.9 | 7.1 |
| testDeviceSync | 0.4 | 0.2 |
| testProjectHandoff | 35.6 | 35.0 |
| testDocumentsProject | 4.2 | 3.3 |
| testDisconnectProjectFolder | 0.2 | 0.1 |
| testStartTurn | 0.5 | 0.5 |
| testTodoStore | 0.0 | 0.0 |
| testTodoScheduler | 16.5 | 12.2 |
| testTodoOrder | 6.5 | 4.7 |
| testSidebarProjects | 0.0 | 0.0 |
| testFinishedTodoCleanup | 0.0 | 0.0 |
| testMoveChatToProject | 0.0 | 0.0 |
| testProjectInfo | 0.1 | 0.1 |
| testGitBranches | 8.5 | 6.7 |
| testTodoAttachments | 0.3 | 0.0 |
| testTodoPause | 0.0 | 0.0 |
| testTodoEdit | 0.2 | 0.0 |
| testTodoMixedOrder | 0.0 | 0.0 |
| testTodoStartRace | 0.0 | 0.0 |
| testTodoAddTool | 0.0 | 0.0 |
| testTodoEditTool | 0.1 | 0.1 |
| testTodoCrew | 0.2 | 0.0 |
| testTodoTime | 0.2 | 0.0 |
| testProjectSnapshot | 8.0 | 3.2 |
| testFullAuto | 8.5 | 4.5 |
| testWorkTiming | 4.7 | 3.1 |
| testPeerReview | 21.6 | 10.6 |
| testPickedRoute | 9.1 | 4.5 |
| testAutoMeeting | 1.1 | 0.5 |
| testEnterpriseMarks | 1.1 | 0.5 |
| testMeetingFold | 1.0 | 0.0 |
| testChatFind | 0.7 | 0.0 |
| testChatSearch | 0.5 | 0.0 |
| testChatTools | 0.5 | 0.2 |
| testMemory | 0.5 | 0.1 |
| testExternalMCP | 3.2 | 2.6 |
| testRemoteMCP | 3.4 | 1.7 |
| testChatMarkdown | 0.1 | 0.0 |
| testShownTurns | 0.3 | 0.0 |
| testChatNotes | 0.0 | 0.0 |
| testSpace | 2.2 | 0.7 |
| testSpaceLibrary | 0.7 | 0.3 |
| testSpaceEnterpriseLock | 0.3 | 0.1 |
| testChatTime | 0.0 | 0.0 |
| testCloudModels | 0.0 | 0.0 |

### 비율과 판정
- 비율 = Σ(이름 있는 테스트) / Σ(외부 전체) = (263.8 + 179.0) / (623.2 + 518.4) = 442.8 / 1141.6 = **38.8%**
- 판정: 20% 이상 → **T2 진행**.
- 20%는 실행 정책으로 정한 기준이다. 38.8%는 이름 있는 테스트를 모두 건너뛸 때 줄일 수 있는 최대치에 가깝고,
  실제로 줄어드는 양이 아니다. T2가 고르는 테스트만큼만 줄고, [2/11] 모듈 단독 빌드(약 230 s, 전체의 40% 안팎),
  [8/11] 컴파일, `runTest` 밖 맨 위 수준 검사는 그대로 남는다.

### 테스트 이름 목록
`docs/modules-followup-t1-tests.txt`: `▶ 이름` 줄에서 시각과 `▶ `만 뺀 57줄, 출력 순서 그대로(정렬·중복 제거 없음).
두 실행의 목록은 같았고 중복은 없었다.
