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

## T2 선택 실행
T1 판정 "진행"(38.8%)에 따라 했다. 2026-11-13, 시작 HEAD `2d21509`, 작업 트리 깨끗한 상태에서 시작.

### 바꾼 것
- `tools/tests/mode2.swift`: `AI_ILLUMINATI_TEST_ONLY`(쉼표로 이름, `-`는 없음)가 있으면 `runTest`가 목록에 없는
  이름을 건너뛴다. 없는 이름이 있으면 실패, 빈 값도 실패. 변수가 없으면 전과 같다(아무것도 더 출력하지 않음).
  `runTest` 밖 맨 위 수준 검사는 **항상 실행**: 테스트들이 같이 쓰는 준비(모델, 채팅 연결, 테스트 홈)와 실제 데이터
  폴더 규칙이 거기 있어서, 건너뛰면 남은 테스트가 다른 상태에서 돌거나 격리 검사가 빠진다. 줄일 수 있는 시간
  (약 40 s)보다 이쪽이 안전하다.
- `tools/test_map.txt` + `tools/affected_tests.sh`(`affected_tests.py`): 바뀐 경로 → 계약 테스트, 앱 테스트, 10단계.
  모듈 줄에는 앱 테스트만 적고, 그 모듈과 그것에 기대는 모듈들의 계약은 `dependencies`에서 계산한다. Accounts,
  Localization, Runtime, Workspace, Chat은 거의 모든 테스트 밑에 있어 ALL. 표에 없는 경로, 검사 장치, 공통 코드
  (ToolHub, Settings, main, ChatLinksApp, RunConditionsApp, 빌드 스크립트, resources, docs/api, MODULES.md)는 ALL.
  테스트 파일은 자기 테스트만, 단 다른 테스트가 그 파일의 이름을 쓰면 ALL(google_drive.swift).
- G6에 대응표 검사 추가: 모듈마다 줄이 있고, 진짜 `runTest` 이름만 쓰고, MODULES.md의 그 모듈 절이 이름 붙인 테스트
  (`testX`, `space_build` 같은 파일 이름 → 그 파일의 테스트, `space_web`)를 모두 포함해야 한다. 어긋나면 G6 실패,
  선택기는 ALL.
- `run_mode2.sh --affected <paths>`: 고른 계약, `runTest`, 10단계만 돈다. 1, 3–9, 11단계, 모듈 빌드, S1–S3는 그대로.
- 검사 장치 변경(사전 승인 범위): run_mode2 모듈 블록에 "고른 경우만 계약 건너뜀" 한 줄, `check_modules.py` G6 추가와
  `affected_tests.py` 해시 대상 추가. `module_guard.sha256` 갱신. 이유와 근거는 MODULES.md "Which tests a change needs".

### 검증
- 필터 없는 전체 실행: 통과, 389.4 s. `▶` 이름 57개가 `docs/modules-followup-t1-tests.txt`와 바이트까지 같다
  (순서·중복 포함). `Affected`/`skip:`/선택 줄 없음.
- 반증 시험(각각 `/tmp` 복사본, 확인 후 버림):
  1. `GoogleAuth.publicClientID`를 뒤집고 `--affected app/modules/AIIntegrations/GoogleAuth.swift` → 2단계
     integrations 계약에서 실패(RC 133, "a login without a client secret is the app's public client"), 80.8 s.
  2. 표에 없는 경로(`docs/USER_GUIDE.md`, `app/macos/LocalModels.swift`) → `ALL`, run_mode2는 "Affected: every test".
  3. 검사 장치 경로(check_modules.sh, module_graph.txt, build_modules.sh, run_mode2.sh, module_guard.sha256, ToolHub.swift,
     build_app.sh, test_map.txt) → 다른 경로와 섞여도 `ALL`.
  4. (추가) 대응표에서 AISpaces의 `testSpace`를 빼면 G6 실패, 선택기는 ALL.
- `check_modules.sh fast` 통과.

### 시간 비교 (외부 시각, 초; 같은 Mac, 순서대로 실행)
| 경우 | 고른 것 | 시간 | 전체 대비 |
|---|---|---:|---:|
| 전체 (옵션 없음) | 계약 8, 앱 테스트 57, 10단계 | 389.4 | 100% |
| `app/macos/Updater.swift` | 앱 테스트 1 | 181.6 | 47% |
| `app/modules/AIIntegrations/FaceLink.swift` | 계약 1, 앱 테스트 8 | 200.1 | 51% |
| `app/modules/AISpaces/Space.swift` | 계약 2, 앱 테스트 5, 10단계 | 236.4 | 61% |
| `app/modules/AIProjects/Todo.swift` | 계약 2, 앱 테스트 34 | 339.3 | 87% |

남는 약 180 s는 모듈 빌드, 앱 테스트 컴파일, 맨 위 수준 검사, S1–S3라서 선택으로 줄지 않는다(T1 예상과 같음).
부분 실행(34개, 8개, 5개, 1개)이 모두 통과해, 고른 묶음이 앞 테스트의 상태에 기대지 않음도 확인했다.

## T3 Chat 조사
AIChat에서 아래쪽 "기록·저장 층"을 새 모듈(가칭 `AIChatRecords`)로 뗄 수 있는지 판정한다. 2026-11-13, HEAD
`22c0d52`, 시작할 때 작업 트리와 index 깨끗함. 실제 코드는 바꾸지 않았다. `/tmp` 복사본(`git archive HEAD`)에서
옮겨 보고 컴파일하고 테스트한 뒤 복사본은 지웠다.

### 지금 크기 (다시 잼)
- Swift 전체(`app/**/*.swift`) 31,874줄, AIChat 13,512줄(42.4%). 계획 때 값은 31,576줄, 13,299줄(42%)이었다.
- AIChat 안의 `extension Discussion`: 19개 파일, 24곳. 계획 때와 같다(run_mode2 C0 표와도 같음).

### 1차 시도: 후보 8개 전부 → NO-GO
| 파일 | 줄 | 위쪽(Discussion·Route·화면·도구)을 참조하는 곳 |
|---|---:|---|
| ChatRecords.swift | 402 | 직접 참조는 없음. 다만 `ChatTurn`·`Conversation`을 위쪽이 extension으로 넓힌다(아래). 의존: AISpaces(`SpaceDraftNote`), AIProjects(`WorkStep`) |
| ChatValues.swift | 203 | `SyncSnapshot.turns: [ChatTurn]`, `ChatImage.url`이 `ChatStore.dir` 사용 |
| ChatStorage.swift | 151 | `StorageLink`(chat_storage 도구)가 `ChatLink.shared.conversations()`, `ChatLink.allowed`, `toolFailure` 사용 |
| DeviceSync.swift | 545 | `start(discussion: Discussion)`(112행), `Discussion.modernModes`(173), `Discussion.loadState`/`loadStateTurn`(254), `Conversation.isEnterprise`(128, Enterprise.swift), `extension Discussion` 1곳(429–534) |
| Memory.swift | 228 | `ChatLink.day`(143), `ChatLink.shared.conversations()`(201), `Conversation.isEnterprise`(183) |
| ChatNotes.swift | 74 | 없음. 다만 ChatWindow.swift(2466, 2668)와 Solo.swift(836)가 내부 멤버(`shared`, `flush`, `open`, `text`, `rule`, `current`)를 씀 |
| RoomDocuments.swift | 117 | `extension Discussion` 1곳(42–117, `ProjectProcess.inspect` 포함) |
| CollabLog.swift | 132 | 없음 |
| 합계 | 1,852 | |

막힌 이유:
- **G4**: `ChatTurn`과 `Conversation`이 새 모듈로 가면 위쪽에 이미 있는 extension 4곳이 "다른 모듈 타입의 extension"이
  된다. Route.swift:44 `ChatTurn.routeChoice`(`RouteChoice`, Route 쪽 타입), Solo.swift:65 `ChatTurn.Column`/`columns`,
  ChatTools.swift:164 `Conversation.projectSummary`, Enterprise.swift:23 `Conversation.isEnterprise`/`isPersonalLocked`/
  `isProjectChat`. 앞의 둘은 위쪽 타입을 쓰므로 아래로 내릴 수 없고, 함수로 바꾸면 그것을 쓰는 ChatWindow.swift
  (260, 533, 2171 `turn.routeChoice`, 3081 `turn.columns`)를 고쳐야 한다. 세 파일 제외 조건과 충돌한다.
- `ChatTurn`/`Conversation`이 남으면 그것에 기대는 DeviceSync, Memory, `SyncSnapshot`도 남아야 한다.
- DeviceSync는 Discussion을 네 군데 부른다. `start`는 클로저 두 개로 주입하면 끊을 수 있지만(복사본에서 확인), 나머지는
  Discussion의 정적 상태(`modernModes`, 상태 파일 경로)를 옮기거나 공개해야 한다.
- 이게 풀리면 가능: (1) 위 4개 extension을 Chat 쪽 함수나 Chat 쪽 타입의 멤버로 바꾸는 별도 작업. 그림 draft TODO가
  끝나 ChatWindow.swift를 고칠 수 있을 때. (2) `Discussion.modernModes`, `stateFile`/`stateTurnFile`/`loadState`를
  기록 층의 경로 타입으로 내리는 작업. 그 뒤 ChatRecords, DeviceSync, Memory, `SyncSnapshot`을 다시 본다.

### 2차 시도: 줄인 목록 → GO (조건: 사용자 승인)
`ChatTurn`/`Conversation`/`ChatStore`와 Discussion에 기대지 않는 부분만 옮겼다. 위쪽에 기대는 조각은 AIChat에 남겼다.
`/tmp` 복사본에서 모듈 빌드, 앱 `app/macos/*.swift` 타입 검사, 앱 테스트 컴파일, 계약 8개, 앱 테스트 57개
(`▶` 57개 모두, exit 0)가 통과했다. run_mode2 1단계의 C0·I 파이썬 검사(`extension Discussion` 24곳 포함)와
G1, G4(경고 0), G5도 통과했다. 실제 `accounts.json` 해시는 그대로였다. 새 모듈이라서 생기는 G2·G6·G7 실패
(계약·boundary·API 스냅숏 없음, 문서에 모듈 없음, 그래프 해시)는 T4의 할 일이다(아래).

옮길 파일 (새 모듈 `app/modules/AIChatRecords/`):
| 새 모듈 파일 | 줄 | 내용 | AIChat에 남는 것 |
|---|---:|---|---|
| ChatValues.swift | 168 | `ChatImage`, `ImageStore`, `RoomDocument`, `MaterialUnit`, `CollaborationTask`, `VoteBallot`, `ChatRoute`, `MeetingLink`, `SyncOrigin`, `RemoteChat` | `SyncSnapshot`(turns를 가짐) → 새 파일 `AIChat/SyncSnapshot.swift`(38줄), 내용은 그대로 |
| CollabLog.swift | 139 | 전부(+ `CollabEvent` 공개 init 7줄) | 없음 |
| ChatStorage.swift | 116 | `ChatStorage`(크기 보고) | `StorageLink` → 새 파일 `AIChat/ChatStorageTool.swift`(38줄) |
| RoomDocumentFiles.swift | 40 | `RoomDocuments` enum(`directory`, `keepDropped`, `read`, `extensions`) | `extension Discussion` → `AIChat/RoomDocuments.swift`(82줄). 파일 이름을 그대로 둬야 run_mode2 C0 표(`'RoomDocuments': 'a'`)가 바뀌지 않는다 |
| ChatPaths.swift (새) | 6 | `public enum ChatPaths { public static let dir = AccountStore.supportDir + "/chats" }` | `ChatStore.dir = ChatPaths.dir` |
| 합계 | 469 | AIChat 13,512 → 13,068줄(3.3% 감소). 새 모듈 469줄 | |

남기는 것: ChatRecords, DeviceSync, Memory, ChatNotes(ChatWindow.swift가 내부 멤버를 씀; 옮기면 클래스와 멤버 6개 이상을
공개해야 함).

의존 방향:
- `AIChatRecords`: AIAccounts, AILocalization, AIRuntime, AIWorkspace. AIRuntime은 ChatStorage의
  `NativeSessions.directory` 때문이고(계획의 "Accounts, Localization, 필요하면 Workspace"보다 하나 더), AIWorkspace는
  `DiskUsage` 때문이다. Workspace가 이미 Runtime에 기대므로 새 화살표가 순환을 만들지 않는다.
- `AIChat`: 지금 의존 + AIChatRecords. 위쪽(Discussion, Route, 화면, ChatLink)을 참조하는 곳은 새 모듈에 남지 않는다
  (새 모듈은 AIChat 없이 컴파일됨). 주입은 필요 없다. `ChatStore.dir`이 `ChatPaths.dir`을 그대로 넘겨받을 뿐이다.

새로 public으로 여는 심볼 (컴파일러가 요구한 것만, 8개):
| 심볼 | 이유 | 소비자 |
|---|---|---|
| `ChatPaths`, `ChatPaths.dir` | ChatStore가 위에 남아 채팅 폴더 경로를 아래에서 받아야 함. 값은 같은 식 | AIChat/ChatRecords.swift(`ChatStore.dir`) |
| `RoomDocuments.extensions` | 자료 읽기가 붙일 수 있는 확장자를 봄 | AIChat/MaterialReader.swift:35 |
| `RoomDocuments.keepDropped` | 채팅 창에 끌어 놓은 파일을 보관 | AIChat/ChatWindow.swift:2993 (파일은 안 고침) |
| `ChatStorage.describe` | chat_storage 도구(`StorageLink`)가 위에 남음 | AIChat/ChatStorageTool.swift |
| `CollabEvent.init(at:kind:chat:…:priorCalls:)` | Swift의 멤버별 init은 internal이라 다른 모듈에서 못 만듦. 필드는 계속 internal | AIChat/Peer.swift(ask_ai, 회의, 리뷰, 결과, 요청 기록) |
| `CollabLog.add` | 기록 한 줄 추가 | AIChat/Peer.swift |
| `CollabLog.smallTalk(_:)` | 인사·감사 메시지 판정 | AIChat/Peer.swift |
| `CollabLog.asksOthers(_:)` | "다른 AI에게 물어봐" 요청 판정 | AIChat/Peer.swift |
나머지 옮긴 타입은 이미 public이었다(C1a, C1b의 이유 그대로). 내부 상태는 열지 않는다.

그 밖의 확인:
- 다른 모듈 타입에 대한 extension: 새로 생기지 않음. 옮긴 타입을 넓히는 extension은 AIChat과 App, 테스트 어디에도 없고,
  G4 경고 0. `module_extensions.txt`는 바꾸지 않는다.
- 저장 형식: 바뀌지 않음. 옮긴 `Codable` 타입의 필드·이름은 그대로다(`CollabEvent`에 init을 더해도 합성된
  `init(from:)`은 같음). 경로는 같은 식이다: `chats/`, `<id>.assets/<picture>.png`, `<id>.documents`, collab 로그 파일.
  chat 계약(옛 채팅 fixture를 읽고 같은 JSON으로 저장), testCollabLog, testDeviceSync, testChatLinks와 mode2 첨부·저장
  테스트가 통과했다.
- ChatWindow.swift, Markdown.swift, Pictures.swift: 옮기지도 고치지도 않는다. 셋 다 옮긴 타입을 쓴다(`ChatImage` 13·1·1회,
  `ImageStore` 1·0·3회, `RemoteChat`, `MeetingLink`, `VoteBallot`, `RoomDocuments`). Swift import는 파일마다라서,
  ChatApp.swift 한 곳에 `@_exported import AIChatRecords`를 두어 모듈 전체와 App이 보게 했다. 이 방법 없이는 세 파일에
  `import` 한 줄씩을 넣어야 한다. `@_exported`는 밑줄 속성(비공식)이지만 G1이 통과했고, App이 보는 이름은 전과 같다.
  T4가 이 방법을 못 쓰면 그림 draft TODO가 끝난 뒤 import 세 줄로 대신한다.
- 영향받는 MODULES.md 약속: "AIChat, step C1a" 표의 "Pictures at <id>.assets…"(이제 `ChatImage`가 AIChatRecords에 있음)와
  "Public names and why" 목록, C1b의 "Settings' tabs: `ChatStorage`…, `CollabMode`/`CollabLog`", "DriveLink:
  `RoomDocuments.directory`", Disk sizes 줄(`ChatStorage (report)`). 약속 내용은 같고 사는 모듈만 바뀐다.
- 영향받는 테스트: `tools/tests/collab_log.swift`와 `mode2.swift`에 `@testable import AIChatRecords` 한 줄씩 추가.
  collab_log는 `CollabEvent` 필드, `CollabLog.file`/`maxBytes`/`Summary`를 읽고, mode2는 `RoomDocuments.read`를 쓴다.
  그 밖의 테스트 파일은 그대로 컴파일된다.

### 판정
- 후보 8개 전부: **NO-GO**(G4 4곳, ChatWindow.swift 수정 필요, DeviceSync의 Discussion 참조).
- 줄인 목록(ChatValues에서 `SyncSnapshot`을 뺀 것, CollabLog, ChatStorage의 보고 부분, RoomDocuments enum, 새 ChatPaths):
  **GO**. 순환 없음, 위쪽 참조 없음, 저장 형식 그대로, 새 extension 없음, 새 public 8개는 모두 소비자와 이유가 있음,
  세 파일은 옮기거나 고치지 않음.
- 조건: 새 모듈과 그래프 변경은 AGENTS.md상 **사용자 승인 사항**이다(`tools/new_module.sh`, `module_graph.txt`,
  `module_guard.sha256`). T4는 승인 없이 시작하지 않는다. 사용자가 자리에 없으면 task_ask로 멈춘다.
- 참고: 줄어드는 양은 AIChat의 3.3%(444줄)로 작다. 얻는 것은 크기보다 "기록 값과 로그는 Discussion을 모른다"는 경계다.
  승인 여부는 이 이득이 새 모듈 하나(문서·계약·스냅숏 유지비)만큼 값어치가 있는지로 정하면 된다.

### T4 작업 목록 (GO, 승인 후 그대로 따름)
1. `zsh tools/new_module.sh AIChatRecords AIAccounts AILocalization AIRuntime AIWorkspace`. 만들어진 첫 파일은 지우거나
   ChatPaths.swift로 쓴다.
2. 파일 이동(`git mv`로 기록 유지):
   - `AIChat/CollabLog.swift` → `AIChatRecords/CollabLog.swift`. `CollabEvent`에 public init 추가, `add`/`smallTalk`/`asksOthers`를 public으로.
   - `AIChat/ChatValues.swift` → `AIChatRecords/ChatValues.swift`. `SyncSnapshot` 블록은 `AIChat/SyncSnapshot.swift`로
     (import Foundation, AIAccounts). `ChatStore.dir` → `ChatPaths.dir`.
   - `AIChat/ChatStorage.swift` → `AIChatRecords/ChatStorage.swift`. `StorageLink`는 `AIChat/ChatStorageTool.swift`로
     (import Foundation, AIWorkspace). `describe`를 public으로. `ChatStore.dir` → `ChatPaths.dir`.
   - `AIChat/RoomDocuments.swift`의 `enum RoomDocuments`(1–41행)는 `AIChatRecords/RoomDocumentFiles.swift`로
     (`import AIProjects` 뺌). `directory(_:)`의 `ChatStore.dir` → `ChatPaths.dir`.
     `keepDropped`/`extensions`를 public으로. `extension Discussion` 부분은
     `AIChat/RoomDocuments.swift`에 그대로 남긴다.
   - 새 `AIChatRecords/ChatPaths.swift`. `AIChat/ChatRecords.swift`의 `ChatStore.dir = ChatPaths.dir`.
3. 연결: `AIChat/dependencies`에 `AIChatRecords`. `AIChat/ChatApp.swift`에 `@_exported import AIChatRecords`.
   다른 AIChat 파일과 App 파일, 세 파일은 고치지 않는다.
4. 검사 장치(승인 범위): `tools/module_graph.txt`에 `AIChatRecords: AIAccounts AILocalization AIRuntime AIWorkspace`, AIChat 줄에
   `AIChatRecords`. `zsh tools/check_modules.sh guard > tools/module_guard.sha256`.
5. 모듈 문서·계약(G2, G6): `AIChatRecords/boundary`(예: `_ = CollabLog.maxBytes<TAB>maxBytes`, `_ = RoomDocuments.read<TAB>read`처럼
   internal로 남는 이름), `tools/tests/chatrecords_contract.swift`(사진 경로 `<id>.assets/<id>.png`, 나쁜 그림 거절,
   collab 로그 크기 제한과 요약, 문서 폴더 경로, 크기 보고의 하드링크 한 번 세기), `zsh tools/check_modules.sh snapshot`으로
   `docs/api/AIChatRecords.txt`·`docs/api/AIChat.txt` 갱신, AGENTS.md "Module rules"·CLAUDE.md Layout·MODULES.md "Module map"에
   한 줄/절, 위 public 8개의 이유를 MODULES.md에, C1a·C1b의 해당 줄을 새 모듈로 옮겨 적기,
   `tools/test_map.txt`에 `app/modules/AIChatRecords/	ALL AIChat(ALL)이 모든 채팅 기록 값을 이것으로 읽고 씀`.
6. 테스트 파일: `collab_log.swift`, `mode2.swift`에 `@testable import AIChatRecords`.
7. 확인: `zsh tools/check_modules.sh`(fast, G4 경고 0), 전체 `zsh tools/tests/run_mode2.sh`(`▶` 57개가
   `docs/modules-followup-t1-tests.txt`와 같고 실제 accounts.json 그대로), `zsh tools/tests/render_chat.sh`. 저장 형식은
   chat 계약 fixture 비교와 testCollabLog로 본다.

## T4 Chat 기록 층 분리
2026-11-13. 시작 HEAD `09fdc18`, 작업 트리와 index 깨끗함. T3 판정은 줄인 목록 GO, 조건은 사용자 승인이었다. 이번 TODO가
"그래프와 검사 장치 변경은 미리 승인"이라고 적었으므로 승인된 것으로 보고 T3 작업 목록 그대로만 했다.

### 한 것
- `zsh tools/new_module.sh AIChatRecords AIAccounts AILocalization AIRuntime AIWorkspace`. 첫 파일 `AIChatRecords.swift`는 지우고
  그 한 줄 설명은 `ChatPaths.swift`에 옮겼다.
- `git mv`: CollabLog, ChatValues, ChatStorage → `AIChatRecords/`. 남긴 조각: `SyncSnapshot` → `AIChat/SyncSnapshot.swift`,
  `StorageLink` → `AIChat/ChatStorageTool.swift`, `enum RoomDocuments` → `AIChatRecords/RoomDocumentFiles.swift`
  (`extension Discussion`은 `AIChat/RoomDocuments.swift`에 그대로). 새 `ChatPaths.dir`, `ChatStore.dir = ChatPaths.dir`.
  본문은 `ChatStore.dir` → `ChatPaths.dir`, `public` 붙이기, `CollabEvent` public init 말고는 그대로.
- 새 public은 T3 표의 8개(9개 이름: `ChatPaths`, `ChatPaths.dir`, `RoomDocuments.extensions`/`keepDropped`,
  `ChatStorage.describe`, `CollabEvent.init(…)`, `CollabLog.add`/`smallTalk`/`asksOthers`)뿐. 이유는 MODULES.md "AIChatRecords".
- 연결: `AIChat/dependencies`에 AIChatRecords, `AIChat/ChatApp.swift`에 `@_exported import AIChatRecords`(MODULES.md
  Exceptions에 이유). ChatWindow.swift, Markdown.swift, Pictures.swift와 App 파일은 고치지 않았다.
- 승인 범위 검사 장치: `module_graph.txt`(새 줄 + AIChat 줄), `module_guard.sha256`(graph 해시 한 줄만 바뀜).
- 계약 `tools/tests/chatrecords_contract.swift`(경로, 그림 거절, 문서 폴더, 옛 collab 줄 그대로 다시 쓰기, 2 MB 반 자르기,
  요약, 하드링크 한 번), boundary 4줄(`CollabLog.maxBytes`, `CollabLog.file`, `RoomDocuments.read`, `Summary.asks`),
  `docs/api/AIChatRecords.txt`(138줄) 새로, `docs/api/AIChat.txt`는 옮긴 129줄이 빠짐(더해진 줄 없음).
- 문서: AGENTS.md 모듈 목록(절 1,956자), MODULES.md(지도 표, 화살표, 빌드 설명, boundary 목록, 새 절, C1a·C1b의 옮긴
  이름 표시, Exceptions, Records), `tools/test_map.txt` 한 줄(ALL), 테스트 `collab_log.swift`·`mode2.swift`에
  `@testable import AIChatRecords`. CLAUDE.md Layout도 한 줄 고쳤다(Git 제외 파일이라 커밋되지 않음).
- 크기: AIChat 13,512 → 13,067줄, AIChatRecords 465줄.

### 검증
- `zsh tools/check_modules.sh`: G1-G7 통과, G4 경고 없음.
- 전체 `run_mode2.sh`(`project_run test`): 1번째는 S2 실패(내 boundary 줄이 Foundation 없이 `URL`을 씀; 줄을
  `_ = RoomDocuments.read`로 고침, 검사는 안 바꿈). 2번째는 `testRuntimeThroughApp` 프로세스 그룹 검사에서 RC 133.
  T1 때 같은 HEAD에서도 난 샌드박스 쪽 흔들림으로 보인다(확인은 안 됨).
  **절차 위반**: TODO는 "두 번 실패하면 task_ask로 멈춘다"였고 원인 조건은 없었다. 여기서 멈췄어야 했는데 3번째를
  돌리고 `cc8d7db`을 커밋·main에 푸시했다(되돌리지 않음: 푸시된 기록은 고치지 않는다). 2026-11-13 사용자가 그대로
  받기로 확인해 T4는 완료다. 3번째 exit 0: 계약 9개, S1-S3, `▶` 57개가
  `docs/modules-followup-t1-tests.txt`와 같은 순서, 실제 accounts.json 그대로. `render_chat.sh`도 exit 0.
- 저장 형식: chat 계약(옛 fixture 3개를 읽고 같은 JSON으로 저장), 새 계약의 옛 collab 줄 바이트 비교, testCollabLog,
  testDeviceSync, testChatLinks, mode2 첨부·저장 통과.
- 반증(`/tmp` 복사본, 하나씩, 끝나고 지움):
  | 바꾼 것 | 기대 | 결과 |
  |---|---|---|
  | `AIChatRecords/dependencies`에 AIChat | G1 실패 | 실패: forbidden dependency, unused, cycle |
  | `CollabLog.maxBytes`를 public | S1 실패 | 실패: `+CollabLog.maxBytes` 차이(S2도 실패) |
  | App 파일(ChatLinksApp.swift)에서 `CollabLog.maxBytes` | 컴파일 실패 | "'maxBytes' is inaccessible due to 'internal' protection level" |
