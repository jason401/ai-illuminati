# AI Illuminati — 인수인계 (Claude Code → Codex, 2026-10-14)

이 문서만 읽으면 바로 이어서 작업할 수 있게 정리했어요. 규칙은 `AGENTS.md`(= `CLAUDE.md`와 같은 내용)에, 사용자용 설명은 `README.md`에 있어요.

## 후광 참고 이미지 반영 (2026-10-24, Codex)
- 사용자 달러 지폐 삼각형 이미지 참고: 짧은8개 외곽 빛살/별 glint 대신 삼각형 뒤에서 퍼지는28개 방사형 광선+부드러운 haze. 바깥으로 갈수록 얇고 옅어지며, 삼각형 내부는 제외해 눈을 가리지 않음.
- 대기 후광은 약하게 유지, 응답 중 고정된 광선 밝기가 일렁임, 완료 시 밝아졌다 사라짐. 눈/시선/5계정 막대·설정·프레임 크기는 유지. 별도 컴퓨터 UI/마우스 조작 없이 렌더링 확인.

## 살아 있는 눈·후광 (2026-10-24, Codex)
- Icon.swift MenuMarkFrame: 눈 깜빡임, 상하좌우 시선, 대기 중 간헐적 반짝임, 응답 중 회전/호흡 빛살, 정상 완료1.4초 후광. 실제 Discussion.running 관찰(중지/오류 시 완료 반짝임 제외), 추가 AI 호출 없음.
- main.swift: 아이콘만10fps 타이머, 동일 대기 프레임 재그리기 생략, 열린 사용량 메뉴에서는 애니메이션 일시 보류. 조회·메뉴 재구성·막대 높이는 애니메이션으로 변경하지 않음.
- 설정 ‘눈과 후광 애니메이션 / Animate eye & halo’ 기본ON, 저장. 막대만 모드/설정OFF/macOS 동작 줄이기에서는 타이머 중단·기존 정지 아이콘. macOS 접근성 설정 변경도 반영.
- 애니메이션 마크22×18pt(기존 정지18×18), 빛살 여유 확보. 프레임별 크기 고정, 5계정 막대·컬러/흑백 유지.
- tools/tests/icon_animation.swift 추가 및 run_mode2.sh에 통합: blink/4방향/후광·완료·대기 hold/색·고정 폭 검증. 별도 contact sheet 실제 렌더링 확인. 실제 AI 요청·컴퓨터 UI/마우스 조작은 하지 않음.

## 가로 막대 한 줄 압축 (2026-10-24, Codex)
- 비교 막대/비교 막대+원형 보기를 짧은36pt 막대 → 잔여% → 원형(선택) → 남은시간 한 줄로 변경. 기존146pt 막대의 별도 행 제거. 계정 이름 열112→88pt, 세로 여백5pt 통일.
- 기존 카드 보기 및 원형 압축 보기 선택은 유지. 조회/채팅 로직 변경 없음. 마우스 조작 없이 빌드·회귀 시험 확인.

## 메뉴바 계정별 막대 (2026-10-24, Codex)
- 막대 모드는 provider별 최대값3개 대신 등록 계정마다1개를 계정 설정 순서대로 표시(현재5개). 조회 전/실패 계정도 빈 윤곽으로 자리 유지. 같은 provider 계정들은 같은 색상.
- 툴팁에 모든 계정 이름·잔여량을 줄별 표시. 기존 마크+퍼센트 모드의 provider별 요약은 유지. 조회/계정/채팅 기능은 변경 없음.
- 마우스 조작 없이 빌드·기존 회귀 시험으로 검증.

## 메뉴바 컬러·간격 (2026-10-24, Codex)
- 설정 → 일반 → 메뉴바 색상: 흑백/컬러 선택, menuBarColored 저장(기본 흑백 유지). 마크는 컬러 시 청록, 막대/퍼센트는 Claude 주황·ChatGPT 초록·Gemini 파랑. 흑백은 macOS template 자동 명암 유지.
- 막대 gap 3→1pt, 마크와 막대 간격5→2pt. 세 막대 폭18→14pt, 마크 포함41→34pt. 조회/채팅 동작 변경 없음.
- 아이콘 직접 렌더링으로 컬러·흑백 및 폭 확인, 전체 빌드 통과. 사용자 요청을 존중해 이번에는 컴퓨터 UI/마우스 조작 없이 검증.

## 사용량 메뉴 표시 방식 (2026-10-24, Codex)

- UI만 변경: MenuCards.swift의 기존 카드를 보존하고 비교 막대 / 비교 막대+충전 원형 / 원형+시간 압축 보기 추가. 기본은 기존 카드.
- 메뉴 ‘표시 방식’ 및 설정 → 일반 → ‘사용량 메뉴’에서 전환. usageMenuStyle UserDefaults 저장, 재실행 후 유지. 설정에서 ‘메뉴 미리 보기’로 바로 확인.
- 비교 보기는 AI별 그룹, 계정별 5시간/주간 두 열. 압축 보기는 계정당 한 줄(잔여%·원형·남은시간). 원형은 충전까지 지난 비율, 숫자는 남은 시간. 계정 상세 메뉴에 추가 한도/요금제/오류/정확한 충전 시각, 오류는 이름 옆 경고 표시.
- 사용량 조회, 로그인, 채팅/협업/이미지/세션, 자동 업데이트 로직 변경 없음.
- 실제 메뉴가 열린 중 갱신 결과로 removeAllItems/재삽입 시 AppKit NSRangeException 재현. 열린 동안 화면 재구성을 보류하고 메뉴 닫힘 다음 이벤트에서 반영하도록 보완(조회는 유지).
- 검증: 전체 Swift 회귀20개 통과, 고정서명 빌드/설치 완료. 실제 UI에서 네 보기 전환·기존 카드 복귀·100% 한 줄 표시·추가 Cowork 한도/정확한 시각 상세·재실행 후 선택 유지 확인. 시험 후 기존 카드로 복원.

## 세션 기본 켜짐 (2026-10-23, Claude)

- 사용자 결정: 세션 유지 기본 ON, 스위치는 남김(방별 끄기). `ChatConfiguration.sessionsOn` = `keepSessions != false`(nil=켜짐). 끈 방만 false 저장. `requestDebate`는 세션 대상 계정(`NativeSessions.eligible`: 앱 전용 Claude/Codex)만 세션 경로, 나머지(Gemini)는 기존 경로(시험 주입 포함). 시험 20개 통과.

## 고정·전부 지우기·빈 대화 정리 (2026-10-23, Claude)

- `Conversation.pinned`(선택 필드), `listedConversations`(고정 먼저), `togglePin`. `deleteAll()`(모두/고정 남기기, 확인 창) → `removeChats`(하나씩 `ChatStore.delete`, 실패 수 보고, 빈 새 대화 1개 유지). 목록 ⋯/오른쪽 클릭에 고정, "새 대화" 옆 ⊙ 메뉴에 전부 지우기.
- 빈 대화 누적 수정: Codex가 설정만 바꾼 빈 방도 저장하게 해서 "새 대화"가 쌓이고 메뉴가 없어 못 지웠음. `Conversation.hasContent`(질문·자료·폴더). 설정만 있는 방은 떠날 때 파일 삭제(`dropBlanks`), 시작 시 가장 최근 것을 새 대화로 재사용(설정 유지)하고 나머지 삭제. 자료/폴더만 있는 빈 방은 유지·메뉴 표시. Discussion이 lazy라 정리는 채팅 창을 처음 열 때. 시험 20개 통과.

## AI 그림 (2026-10-23, Claude)

- 시험 결과: Codex `exec`(read-only)에서 그림 생성 됨(29초) → `<CODEX_HOME>/generated_images/<thread>/exec-*.png`. Claude는 그림 파일 불가 → SVG. agy `generate_image`는 비동기 helper로 print 모드가 먼저 끝나고, 재시도 시 Google 500 오류 → 쓰지 않고 SVG. agy는 작업 폴더의 이미지 파일을 읽어 정확히 설명함.
- `Pictures.swift`: 규칙(`Pictures.rule(for:)`: Codex=그림 도구, Claude/Gemini=```svg), 수집(`harvest`: SVG→PNG 렌더 후 [그림 N] 표시로 교체, Codex는 호출 시작 이후 generated_images 새 파일), 저장(`ImageStore`로 chats/<방>.assets, 이름 picture-N.png).
- `Discussion`: `collectPictures`/`sharePictures`(pictureLock), `nextPicture`, send()에서 이전 사용자 사진+AI 그림 전부 activeImages/imageContext로. Entry.images, ChatTurn.finalImages(선택 필드, 옛 JSON 호환). 첫 의견 그림은 모두 끝난 뒤 공유(서로 안 보고 답하므로). 최종 답: 팀 그림을 [그림 N]으로 고르게, 화면은 이름 매칭으로 같이 표시(`TurnView.finalPictures`).
- Gemini 이미지 제외 제거: 호출마다 임시 폴더에 image-N.png 복사, cwd/`--add-dir`, 경로를 프롬프트에 명시.
- 시험용 `pictureAnswer` 훅(그림 있는 요청을 가짜 응답으로). 시험 추가, 19개 통과. 실제 3AI 시험 41초: 셋 다 그림, 대표가 그림을 보고 비교·추천. 협업(모드3) 결과물 그림은 아직 안 함.

## 공개 저장소·자동 업데이트·채팅 삭제 정리 (2026-10-23, Claude)

- 저장소 **공개**(사용자 승인). 공개 전 전체 기록 검사: 이메일·토큰·키 없음, 메모에 학교명(Stanford)·요금제 정도만.
- `Updater.swift`: 시작 60초 뒤·3시간마다. 로컬 수정/로컬 전용 커밋이면 건너뜀, 채팅 중이면 10분 뒤. fetch → `merge --ff-only` → `run_mode2.sh`(30분 제한) → `build_app.sh --stage`(실행 중 앱 옆 `AI Illuminati.update.app`) → 실패 시 `reset --hard` 이전 HEAD. 성공 시 채팅이 끝날 때까지(최대 6시간) 기다렸다 `--install-staged`를 분리 실행(앱 종료→교체→실행, 실패 시 이전 앱 복구). 상태는 `update.json`, 설정 → 일반 → 업데이트(켜기/지금 확인/상태). `--stage`·`--install-staged` 실제 동작 확인(실행 중 앱 유지, 새 pid, 같은 서명 신원).
- 채팅 삭제: `NativeSessions.purgeRoom`(방 ledger의 정확한 세션 ID 파일만: Claude `projects/*/<id>.jsonl`·`<id>/`, Codex `sessions|archived_sessions/**/*<id>*`, 앱 전용 계정만; 빈 방 project 폴더; 방 rooms 폴더와 예전 archived 사본) + `WorkspaceBackup.purgeRoom`(`workspace-backups/<방>` + 연결 git의 `refs/ai-illuminati/<run>`). 로그인·다른 세션·원본은 유지. 시험 추가.

## 채팅 규칙·저장 위치 (2026-10-23, Claude)

- 기본 채팅 규칙에서 길이 줄("3~5문장", "검토 3줄", "자세히는 요청 시만") 제거, 말투·언어만 남김. 길이는 `SpeechLength` 메뉴가 담당. 저장된 값이 예전 기본(`AppModel.oldDefaultRules`, 한/영)이면 새 기본으로 읽음; 사용자가 쓴 규칙은 유지. 시험 추가.
- 설정 → 일반 → "저장 위치": 앱 데이터(`~/Library/Application Support/AI Illuminati`)·계정 폴더(`~/.ai-illuminati`) Finder 열기(`DataFolders`), 계정 ⋯ 메뉴에 "Finder에서 폴더 열기". 로그인 정보 주의 문구.

## 모든 계정 같은 방식 (2026-10-23, Claude)

- 사용자 결정: ChatGPT 개인·학교 모두 같은 방식. 처음 실행 시 `~/.codex`·기본 Claude 로그인을 빌려 등록하던 코드 제거(Gemini만 자동 등록). 기존 `codex-main`(ChatGPT (개인))은 id·이름 유지, `dir`=`~/.ai-illuminati/accounts/codex-main`(+ file 인증 저장)으로 옮기고 사용자가 브라우저로 따로 로그인. 결과: 새 폴더 개인 plus 사용량 읽힘, ChatGPT 앱 `~/.codex` 로그인도 계속 유효(따로 로그인은 충돌 없음, 복사만 위험). 이제 세션 대상 계정 4개(Claude 2, ChatGPT 2). 계정 목록 백업 `accounts.json.backup-before-codex-move`.

## Gemini 기본 꺼짐 (2026-10-23, Claude)

- 사용자 결정: 모든 모드에서 Gemini는 새 대화 기본 참여 안 함. `ChatConfiguration.participants` 기본 [.claude, .codex], 옛 모드용 `useGemini` false. 모드3(협업)은 원래 모든 계정 미선택. 설정을 저장한 기존 방은 그대로. 시험은 Gemini 참여를 명시하도록 고치고 기본값 시험 추가, 16개 통과.

## 발언 길이 설정 (2026-10-23, Claude)

- 모드1·2(토론/비판 토론)에 방별 `speechLength`(400/800/1500, 기본 800). `SpeechLength` in `Discussion.swift`, 발언 프롬프트 `Debate.swift`의 길이 규칙만 바꿈(사회자 지시 250자·최종 답 8문장은 그대로). 상단 "AI마다 N회" 옆 메뉴. 시험 `speech length default 800…` 추가, 전체 16개 통과.

## 단계⑤ — 작업 배분·언어·검색·화면 (2026-10-16)

- 계획은 고유 작업 ID/계정 ID/선행 작업 ID/필수 결과 경로. 필요한 작업만 배분, 한 계정 여러 작업 가능, 선택하지 않은 계정 호출 금지(새 방 기본 모두 미선택). 잘못된 ID/순환 계획은 호출 재시도 없이 표시. 같은 계정은 동시 turn 금지, 쓰기는 직렬.
- 모든 협업 호출 웹 검색 ON. 사용자 질문 언어로 계획·제목·결과·검토, 검색 먼저+[source: URL], 남의 주장 미확인 판정 전 직접 검색. 전체검토만 파일당 작업, 쪽별 AI 미리 읽기 없음.
- 필수 결과 경로가 연결 범위에 실제 존재하는지 검증. 결과 답변만으로 성공 처리하지 않음. 계획·교차 검토는 보기만; 최종 통합은 작성 권한을 받아 실제 요청 파일에 검토 수정을 반영. 작업 ID/선행 ID/필수 파일/결과 SHA256을 영구 저장하고 검토는 해당 SHA256 버전에 붙임. 고정된 개별 결과 파일·발언 기록 보존.
- 작업 목록/발언은 완료·진행 요약+펼치기. 실제 변경 목록/Open/Finder/Undo. 세션 스위치·경로 연결·3단계 권한 UI 실물 확인. 새 협업 방의 5계정 기본 모두미선택 확인.
- 경로 목록은 절대경로로 통일: /tmp↔/private/tmp 정규화로 상대경로 접두사가 중복되는 실제 시험 버그 수정. DOCX/PPTX 요청 이미지 추출·캐시, 슬라이드 실제 순서/노트 유지, 원래 Office 배치 렌더는 아님.
- Stop은 CLI의 자식 shell/MCP/분석 프로세스까지 종료(지연 writer 회귀). agy는 --disable-slash-commands와 --mode를 같이 쓰면 mode가 무효라는 실제 경고 확인해 workspace 호출에서 충돌 플래그 제거. 개인 권한은 바꾸지 않음. agy native 파일 읽기247kPa 성공, 보기 쓰기/명령 시도 거절·원본 해시 유지. 실행 승인 필요 시 실패를 그대로 표시.
- 실제 두 AI 한국어 협업에서 15 PDF×100쪽 연결 → 계획 즉시 → notes+PDF3쪽만 확인 → 검색 → report.md 생성 → 교차검토 → 통합 성공(6개 작업카드, 쪽별 호출0). 첫 실험에서 최종 통합이 readonly라 요청 파일 수정 못 했던 점을 발견해 보완. 최종 실제 재시험에서 report.md의 검토 지적2곳을 직접 수정·검증 완료. 검색 이벤트와 [source: URL], 원본 PDF15개 해시 불변, 요청 변환 캐시2개/미리 읽기0 확인. 시험 방6174ADF8-7E88-4ECC-99DA-BC5B277C1324, disposable report.md 작성·최종수정 확인 후 실제 앱 Undo 버튼으로 복원 완료(모든19개 파일 해시 원래 사본과 일치, Restored 표시). 개인 연구 자료 변경0. 호출 로그/앱 .work 결과 기록은 보존.
- 최종 전체 Swift 회귀15개, Python 문서7개+세션6개, 앱 빌드·실행·고정 서명 검사 통과. 작성/실행 실제 백업 복원 해시 일치. 소스 변경 완료, 아래 과거 단계의 미구현/학교만 제한은 현재 상태가 아님.

## 단계④ — 작성+실행 (2026-10-16)

- 권한 메뉴에 작성+실행 추가. Claude는 restricted를 유지하면서 Bash만 명시적 허용, sandbox enabled/allowUnsandboxedCommands=false 및 연결 allowWrite. Codex는 매 fresh/resume에 workspace-write/연결 writable_roots/shell_tool=true, network=false, tmp 쓰기 제외. 검토·계획은 여전히 read-only/shell off. 우회 플래그 없음.
- 실제 학교 Claude와 학교 Codex에서 Python으로 연결 폴더 analysis.txt 생성 성공, 부모 outside-marker 쓰기는 EPERM 차단, 실제 파일 없음. **학교 Codex의 on-request는 유지되지만 모든 실행이 막히지는 않음**: sandbox 안 명령 성공. fresh+readback resume turn_context 모두 연결 root/workspace-write/on-request 확인. 승인 필요한 명령은 headless에서 실패하며 자동 승인·재시도 없음.
- agy 실제 보기 시험에서 MCP 승인이 개인 설정에 없어 headless 거절 확인. 전역 허용을 추가하지 않음. 따라서 agy workspace MCP는 등록하지 않고 native workspace 도구+앱 읽기요청 JSON만 사용. 실행은 기존 agy sandbox/계정 권한에 따르며 거절될 수 있음을 화면 안내. 이 backend 한계는 숨기지 않음.
- 전체 회귀12개(실행 resume 설정/쓰기 root/tmp 제외/검토 readonly 포함), 고정 서명 빌드 통과. 실제 시험은 disposable 사본만 사용.

## 단계③ — 작성·백업·되돌리기 (2026-10-16)

- 방 권한에 작성 추가. 계획/검토는 보기만, 작업자는 연결 폴더에서 수정·생성·삭제. Claude Edit/Write+앱 MCP, Codex workspace-write/연결 writable_roots와 shell_tool=false, agy accept-edits(개인 명령 자동 허용이 있으면 실행 거부; 개인 설정 변경 없음).
- 작업 시작 전 APFS COW 전체 백업(다른 파일시스템은 일반 복사), 스트리밍 SHA256 검증 완료 후에만 쓰기. git 루트는 HEAD/stash create+앱 전용 ref도 보관. 백업 실패 시 호출0. 쓰기는 작업별 직렬, 읽기 병렬 유지.
- 실제 added/modified/deleted 목록과 파일/Finder 버튼, 되돌리기. 복원은 임시 사본 후 rename, 전후 해시 검증, 작업 이후 다른 수정이 있으면 덮어쓰기 거부. 중지/실패에도 백업 보존·변경 목록 수집. 방 삭제로 외부 원본/백업 삭제 안 함.
- 실제 학교 Claude 시험: disposable 1500쪽 폴더에서 edit.txt 수정/new.txt 생성/delete.txt 삭제, 셸 도구 없음 확인. 실제 변경3개 일치. 학교 Codex도 apply_patch로 동일한3개 변경 성공, 셸 도구 없음 확인. Claude 실제 백업을 앱 restore로 복원해 전파일 해시 일치. 회귀11개/Python5개/고정서명 빌드 통과, 가짜 작업자3명 쓰기 최대동시1 확인. 원본 연구 자료는 사용하지 않음.

## 단계② — 경로 연결·보기 (2026-10-16)

- 자료 선택은 WorkspaceBinding의 경로/디렉터리 여부만 저장. 내용 복사·PDF 전쪽 렌더·조각별 Read source AI 호출 제거. 파일 목록만으로 즉시 계획 시작. 기존 사본/과거 기록은 보존.
- WorkspaceInvocation: Claude restricted+Read/Grep/Glob + 앱 전용 MCP; safe-mode는 명시적 MCP도 꺼서 workspace 호출에서 제거하고 restricted/strict MCP/설정 소스 없음으로 대체. Codex read-only+shell_tool=false, resume에도 -c 적용. agy는 방 cwd의 .agents/mcp_config.json과 plan 모드, 개인 설정 변경 없음.
- 문서 도구는 요청한 파일/페이지 범위만 변환하고 private 캐시. Python stdlib MCP + 앱 번들 WorkspaceDocument(PDFKit/ImageIO) helper. 파일 범위·symlink 탈출 차단. 권한 없는 쓰기 도구 자체를 노출하지 않음.
- **학교 Codex 관리 정책은 외부 MCP까지 disabled로 강제함**(mcp list disabled_reason requirements). 정책 변경/우회 없이 문서 요청 JSON → 앱이 허가된 연결 파일을 읽어 전달 → native resume으로 답변. 명령 도구는 여전히 없음. 권한 실패/Stop/timeout 자동 재시도 금지 유지.
- 실제 검증: 시험용 15 PDF×100쪽 연결에서 미리 변환/AI호출0, 요청한 3–4쪽만 변환·캐시, 원본 해시 동일. Claude와 학교 Codex가 notes 247kPa/PDF 3쪽 표식을 읽고 수정·생성·명령은 거절. Codex 모든 fresh/resume turn_context에서 read-only/on-request/방 cwd 유지 확인.
- Python 파일경계·lazy 목록·cache 변경감지·보기 도구4개 시험, 기존 전체 회귀, 앱 빌드/서명 통과. 학교 Codex의 MCP 차단은 앱 상태 안내 대상이며 학교 실행 정책도 이후 단계에서 실제 확인할 것.

## 최신 지시·체크포인트 — Codex (2026-10-16)

- 사용자 최신 지시가 아래 과거 지시보다 우선: 실제 호출 시험은 남은 사용량이 많은 계정부터, 개인도 허용(학교만 제한 해제). 예산/호출 제한/확인창 UI 만들지 않음. 불필요한 쪽별 AI 호출 제거.
- 미커밋 협업/Office/모드 변경을 먼저 체크포인트로 저장. 전체 회귀10개와 앱 고정 서명 빌드/실행 재확인 완료. 이후 변경은 단계별 별도 커밋·push.
- 다음: ② 경로 연결·보기(미리 복사/읽기/쪽별 호출 제거, 요청 시 문서 변환 캐시) ③ 작성+자동백업/변경목록/되돌리기/쓰기직렬화 ④ 작성+실행과 학교 Codex 관리정책 실제 검증 ⑤ 작업단위 계획/선택 계정만/한국어·검색 지시문. 실제 연구 폴더로 시험하지 않음.

## 최신 변경 — Codex (2026-10-16, 범용 협업·Office 자료 지원 완료)

- **사용자 지시: 실제 AI 호출 시험은 학교 Claude + 학교 ChatGPT만. 개인 계정·Gemini는 토큰 부족으로 시험 호출 금지.** 여러 계정 병렬 구조는 가짜 응답으로 시험할 수 있음. 이 제한은 테스트에 관한 것이며 제품의 계정 선택 기능은 모두 유지.
- 모드 번호 새 체계(modeVersion=2): 1 토론(기존 대표 진행), 2 비판 토론(근거 있는 반론·대안/각 AI 후속 반론 기회), 3 범용 협업. 구형 설정은 다음 질문부터 1로 해석, 옛 턴은 Legacy 표시. old mode1/2 엔진과 회귀는 modernModes=false로 계속 검사.
- `Collaboration.swift`: 계정 ID 기준 참여·왕관 대표 선택. 계획 JSON(accountID/task/dependsOn), 선행 조건 완료 후 병렬 wave 실행, 출처별 자료 읽기/근거 cache, 작업별 원문 선택, 개별 결과·교차 검토·최종 Markdown 저장, 작업 카드/파일 열기. 논문에 고정하지 않음. 코드/분석 실행과 DOCX/PPTX 원본 서식 편집은 아직 없음.
- `MaterialReader.swift`: DOCX/PPTX OOXML XMLParser(unzip -p; arbitrary archive extraction 없음), 실제 슬라이드 순서/노트/삽입 이미지/차트 캐시; PDF 페이지 텍스트+1600px 렌더; 사진1800px. Office 전체 배치 렌더 아님(화면상 안내). 원본 사본 별도. 큰 텍스트12000자 단위. 기존 등록10MB/20개/12만자 제한 제거; 단일1GB·압축단일항목128MB 보호 한도. background import·오류 보고.
- 일반 토론은 관련 부분만 선택(원문 전부 검토 주장 금지). 협업은 부분별 읽은 수/cache 재사용 수를 표시. `.documents/evidence-notes.json` private cache, `.work/<runID>` 결과. 방 삭제 시 앱 작업 결과도 삭제, native provider history는 기존처럼 보존.
- 전체 회귀(기존 모드·이미지·중지 + 새 DOCX 11MB/표·이미지, PPTX 순서/노트, 가짜 개인/학교 동시 실행·결과 파일 저장 + 선행 조건 순서/선행 결과 전달/전체 자료 부분 수/cache 재사용 + 새 1/2 모드 발언 상한·대표 대체·반론 기회) 전부 통과. 앱 전체 빌드·실행·고정 서명 검사 통과. 실제 UI 새 3모드/5계정 개별 선택 확인.
- **실제 호출 시험 완료: 학교 Claude 4회 + 학교 Codex 2회, 총6회만. 개인·Gemini 호출0회.** 세미나 체크리스트 과제로 계획→2계정 작성→교차검토2→최종통합/파일저장 성공. native 소유 목록의 모든 accountID가 학교 두 계정뿐임을 확인. 실제 병렬 계정확장(개인/학교 같은 provider)은 토큰0의 fake 시험으로 검증.
- 실제 Office 라이브러리로 만든 합성 DOCX/PPTX/PNG를 UI 폴더 선택으로 등록: DOCX 본문·표 값/삽입그림, PPTX 노트의 7MHz/슬라이드 순서·삽입그림, PNG 변환 및 원본 사본 hash 일치 확인. 이 자료 등록 검증은 추가 AI 호출0회. 테스트 방 E1F5707D-237F-4DC1-B3BE-394870C35FF3 보존; 학교 계정만 체크된 상태. 사용자의 실제 연구 자료는 시험에 보내지 않음.
- 후속 보완: 협업은 계정·역할별 appendContext로 서로 다른 작업 요청도 같은 세션에서 이어감. 이미지 전달 기록은 누적해 이미 받은 자료를 재첨부하지 않음. 일반 토론의 canonical prefix 검증은 유지. 이 마지막 연속성 경로는 추가 실제 호출 없이 가짜 세션 회귀로 검증 중.
- 빌드가 AppleScript quit 요청에 오래 멈춤: build_app.sh의 quit Apple Event를 최대2초 대기 후 기존 종료 절차로 진행하도록 제한. 고정 서명은 그대로 유지.

## 최신 변경 — Codex (2026-10-16, 세션·자료 UI 완료)

- 사용자가 검증 스크립트만으로는 사용할 수 없음을 지적. 실제 채팅 상단에 opt-in 세션 스위치, 자료 파일/폴더 선택, 자료 이름·개수, 연결 해제, 원본으로 세션 재시작 메뉴 구현 중. `NativeSessions.swift`, `RoomDocuments.swift` 추가.
- 모드3에서만 앱 전용 Claude/Codex 계정 세션 사용. 발언과 대표 판단/최종 정리 분리. 기본 계정·Gemini는 전체 전달. 사용 가능한 기존 세션 계정 우선, 그 계정 한도가 0이면 다른 계정 선택 후 전체 자료로 bootstrap. 로그인 복사/설정 변경 없음.
- 방별 ownership ledger + 세션별 cwd. 공통 문맥이 확장되면 delta와 새 이미지만 전달. 대표 JSON은 일반 발언 세션에 넣지 않음. 모드3 원문 순서를 sessionTranscript로 보존해 후속 질문에서도 prefix 유지. 자료가 달라지거나 history가 prefix가 아니면 새 세션. 명시적 missing-session에만 stateless 1회 대체; 한도·인증·권한·Stop·timeout 자동 재시도 없음.
- PDFKit 쪽 번호 텍스트/UTF-8 지원 파일 사본. 20개·파일10 MB·총12만 자 제한, hidden/package/symlink 제외. 그림·스캔은 별도 이미지. 폴더 실시간 접근·동기화·수정권한 기능 아님. native 압축 이벤트 감지 시 다음 호출 원본 bootstrap; 모든 압축 감지를 보장하지 않음.
- **삭제 제한 명시**: 방 삭제 시 앱 자료·이미지 사본과 JSON 삭제, native provider transcript는 아직 삭제하지 않음. ownership/cwd는 rooms/archived로 보존. 공유 index나 계정 폴더 삭제 금지. UI 정보와 README에 고지.
- 검증 완료: 전체 Swift 회귀(기존 모드·언어·이미지·Stop + 세션 delta·최초 이미지만·역할 분리·합성 압축 bootstrap·자료/빈방 설정 저장) 통과. Python probe 오프라인 6개 통과. 최종 전체 앱 빌드/실행 및 고정 서명 검사 통과. sandbox 안 pasteboard/Keychain 검사는 실패하므로 해당 시험은 호스트 권한으로 실행해야 함.
- 실제 UI: 세션 ON → 폴더 선택으로 합성 원고(약2만 자) 연결 → 이미지 + 첨부 → 두 질문. Claude·ChatGPT 학교 계정 모두 첫 원고 표식/그림 위쪽 숫자, 새 첨부 없는 후속 질문의 다른 표식/아래쪽 숫자 정확히 응답. 두 질문 총8회 CLI 호출. 발언2 + 대표1, 총3개 세션 유지. 정확한 앱 소유 native transcript를 읽어 후속 사용자 입력에 원고 전체/이미지 미재전송 확인(Claude 발언 약1.8천 자·이미지0, Codex 발언 약1.9천 자·이미지0; 첫 호출은 약2.4만 자·이미지1). 테스트 방 5FB165F6-9F7A-4D58-B47B-8CAAC1E68EA4 보존. 고사용량 자동 압축까지 실제 발생시키는 시험은 아직 안 함.
- 실제 사용법은 README ‘자료와 세션 사용하기’. 현재 UI 언어 English이므로 Keep sessions (experimental) → Add materials → Choose files/Choose folder, 그림은 Attach images. 공동 작업 목록·작업 실행/결과물 작성은 아직 구현하지 않음.

## 최신 변경 — Codex (2026-10-16, 세션 검증 첫 단계)

- 사용자 승인으로 세션 도입의 안전한 첫 단계 구현. `tools/tests/session_probe.py`: 기본 실행은 합성 원고(2만 자 이상)·PNG 생성만, `--live`일 때만 기존 앱 전용 Claude/Codex 계정으로 최대 각 4회 호출. 개인 기본 폴더·Gemini 제외, API 키·인증 파일 복사·설정 변경 없음. `--parallel-only`는 같은 계정에 별도 세션 2개 생성(각 제공사 2회 호출).
- 실제 확인: 두 CLI 모두 첫 호출에만 보낸 원고·이미지를 같은 세션으로 재개해 이전에 묻지 않은 표식·그림 숫자를 정확히 답함. 재개 후 실제 검색 이벤트 확인, 쓰기 시험 파일 생성 안 됨. 같은 계정의 별도 세션 동시 생성도 통과. 해당 세션의 원본 기록에 이미지 데이터 존재 확인.
- **Codex 권한 중요**: `-c sandbox_mode="read-only"`로 재개한 모든 turn_context에서 read-only·실행 폴더 유지 확인. 학교 관리 정책이 `approval_policy="never"`를 `on-request`로 바꿈. 이를 read-only 해제로 오해하거나 정책을 우회하지 말 것.
- 오프라인 검사 `PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tools/tests -p test_session_probe.py` (6개). 상세 실행법·검증 결과·미검증 항목: `tools/tests/SESSION_PROBE.md`.
- 기존 회귀 시험에서 모드1↔2 전환 시험의 가짜 응답 함수가 `prompts` 배열을 병렬 수정해 실제 SIGSEGV 발생. 시험 코드에만 NSLock 추가. pasteboard 접근이 가능한 환경에서 `zsh tools/tests/run_mode2.sh` 전체 통과. 앱 소스 변경 없음으로 앱 재빌드/재실행은 하지 않음.
- **앱의 기존 모드3/호출 방식은 변경하지 않음.** `ready_for_app=false`: 실제 자동 압축·압축 후 이미지·네이티브 삭제·개인 목록 노출·중지/재시작 복구는 아직 미검증. 과도한 사용량을 피하려고 자동 압축까지 밀어붙이는 대형 시험은 하지 않음. 실험 세션은 앱 전용 계정에 남겨둠; 원본 출력/소유권 정보는 private tmp에 있고 git에 넣지 않음. 앱 전용 폴더도 기본 Codex 앱에 안 보인다고 보장하지 말 것.
- 다음 구현: 앱 소유 기록의 삭제/복구 검증 후 방별 opt-in 세션 연결 + 제한된 기존 호출 대체 경로. 한도/인증/권한 실패·Stop 시 자동 재호출 금지. 자료 목록/압축 복원/공동 작업은 별도 검증·커밋 단위.


## 최신 변경 — Claude (2026-10-16, 웹 검색)

- 사용자 지적: 논문 링크 질문에서 Claude·ChatGPT가 "검색을 못 한다"고 하고, ChatGPT는 검색도 안 하면서 "미확인"만 반복. 원인: 앱이 모든 도구를 꺼서 실행(`--tools ""`, codex 검색 없음, agy는 유튜브 주소만 허용).
- `Answerer.ask(..., web:)`: 모드3 발언(첫 답·이후 발언)만 `web: true`. 진행 판단·최종 정리는 검색 안 함.
  - Claude: `--tools WebSearch,WebFetch --allowedTools WebSearch,WebFetch` (print 모드는 허락을 못 물어서 allowedTools 필수).
  - Codex: `codex --search exec …` (`--search`는 exec 앞에 와야 함. exec 뒤에 두면 오류). 셸 명령(curl 등)은 read-only 샌드박스에서 막힘.
  - agy: `search_web`은 원래 허용됨. 페이지 읽기(`read_url`)는 print 모드에서 허락을 못 물어 자동 거절 → `~/.gemini/antigravity-cli/settings.json`의 `permissions.allow`에 `read_url(*)` 추가(`GeminiLinks.allowWeb`, 기존 백업 그대로). 사용자의 agy 단독 사용에도 페이지 읽기 허락 창이 안 뜸.
- 지시문: 중요한 사실·숫자·이름·링크는 먼저 검색, `[source: URL]`. 남의 주장을 미확인/틀림이라 하려면 먼저 직접 검색. 출처 있는 주장을 자기 출처 없이 반박 금지. 대표는 "검색 안 하고 미확인이라고 한 것"을 미확인으로 치지 않음. 최종 답에 찾은 링크 포함. 발언 시간 제한 240→300초.
- 발언 지시문에 남아 있던 "Do not use tools"가 검색 허용과 충돌 → Claude·ChatGPT가 "도구 금지라 검색 못 함"이라고 답함. "웹 검색·페이지 읽기만 사용, 파일 수정·명령 실행 금지"로 바꿈(시험으로 고정).
- 사용량 소진(429, RESOURCE_EXHAUSTED, quota, usage/rate limit) 실패가 나면 그 AI는 이번 토론에서 빼고(`isOutOfUsage`), 남은 AI가 이어감. 남은 AI가 없으면 종료.
- 실제 모드3 확인(같은 질문): 80초·5발언. ChatGPT가 DOI 논문과 인용 출처, Claude가 SearchWorks 서지(view/896785)와 WorldCat 링크를 찾아 최종 답에 링크 포함. 이 시험 중 Gemini 주간 한도 소진(약 127시간 후 리셋).
- 수동 확인(같은 질문, 단독 실행): Claude가 SearchWorks 기록 https://searchworks.stanford.edu/view/896785 (Stephen Allen Farnow, *Acoustic applications of the zone plate*, 1975/1976) 확인. Gemini가 이전에 말한 "Donald Allen Farnow"는 틀린 이름이었음.

## 최신 변경 — Claude (2026-10-16, 모드3 목표 = 좋은 답)

- 사용자 지적: AI들이 서로 반박만 하고 대화가 길어져도 답이 나아지지 않음. 원인은 우리 지시문(입장 방어·반론 요구·"동의 금지", 대표에게 "의견 차이 찾기·반론권", 60% 최소 발언 강제, 이른 종료 시 "가장 약한 주장 반박" 대체 지시).
- 바꾼 것(`Debate.swift`):
  - 발언: "한 팀, 목표는 사용자 질문의 가장 좋은 답". 매 발언은 새 근거/데이터/계산/예시/구체적 수정안 중 하나 필수. 반대하면 더 나은 안이나 근거를 함께. 맞으면 인정하고 덧붙임. 숫자·사실에 [source]/[from memory]/[estimate], 출처·정확한 숫자 지어내기 금지.
  - 대표: 정리판(`board`: Agreed/Check/Open) 갱신 → 답에 빠진 것을 찾아 "할 일"(find/calculate/propose/check)로 맡김, "반박하라" 금지. 정리판은 다음 발언자 원문에 `[Moderator board]`로 들어감. board가 문자열이 아니면 무시(판단 전체를 버리지 않음).
  - 종료: 최소 발언 수(`minimumDebateTurns`) 삭제. 대표가 "충분하다"면 바로 종료. 횟수 다 쓴 AI를 지목하면 남은 AI가 "빠진 것 하나 더하기".
  - 최종: 3문장 요약 → 질문에 대한 최종 답(먼저 답, 그다음 근거/추정 구분, 답을 바꿀 남은 쟁점), 8문장 정도. 시간 제한 180초.
- 웹 검색(근거 찾기)은 아직 안 켬. 써보고 근거가 약하면 검토.

## 최신 변경 — Claude (2026-10-15, 모드3만 표시)

- 사용자 결정: 당분간 모드3만 사용. `Discussion.availableModes = [3]`만 메뉴에 표시(Picker는 그대로, 목록만 이 배열에서 만듦). 방 설정이 숨긴 모드면 `configuration`이 첫 모드(3)로 바꿔 돌려줌. 모드1·2 코드·저장 형식·옛 메시지 표시는 그대로. 다시 켜려면 배열에 1, 2를 추가.
- 모드가 하나뿐이면 정보 메뉴의 "대화 중 방식 변경" 안내를 숨김.
- 시험은 시작할 때 `availableModes = [1, 2, 3]`으로 바꿔 모드1·2도 계속 검사.
- 향후 방향(사용자와 합의, 아직 구현 안 함): 방에 폴더 연결 → ① 보기만 ② 작업자 1명 + 다른 AI 검토 + 반영 버튼 ③ 사용량 한도 시 인수인계 후 다른 계정이 이어받기 ④ 병렬 작업은 필요할 때만. 원본은 반영 전 건드리지 않고 작업 복사본·백업은 `~/Library/Application Support/AI Illuminati/work/<방ID>/`.

## 최신 변경 — Claude (2026-10-15, 프롬프트 순서·이름 색)

- **모드3 프롬프트 순서**: 모든 모드3 호출(발언·진행 판단·최종 정리)이 `Discussion.debateContext`(`[MODE3 DEBATE]` + 규칙 + 전체 원문)로 시작하고, 바뀌는 지시(역할·논점·남은 횟수)는 맨 뒤. 원문은 뒤에만 덧붙으므로 같은 AI의 연속 호출이 긴 공통 앞부분을 가져 AI 서비스의 캐시를 쓸 수 있음. 실제 사용량 절감 폭은 측정 안 함. 모드2는 원래 원문이 맨 뒤라 그대로.
- **AI별 세션 유지(GPT 제안)는 보류**: 세션을 이어도 도구가 전체 기록을 매번 다시 보내 사용량이 줄지 않고, 계정 자동 선택·이미지·중지·기록 파일 문제로 복잡도만 큼. 방이 길어지면 "오래된 질문은 누가 무엇을 주장·철회했는지 구조화해 압축, 최근은 원문" 방식을 검토.
- **이름 색**: `Account.Provider.color`(Claude 주황, ChatGPT 초록, Gemini 파랑; 다크/라이트 각각). 발언자 이름과 "정리:" 이름에 적용. 옛 대화도 이름 앞부분으로 색을 찾음(`Provider.of(speaker:)`).

## 최신 변경 — Claude (2026-10-15, 한 줄 보기)

- **채팅 한 줄 보기(모드1·2·3)**: AI 답 프롬프트 끝에 `Discussion.headlineRule`(첫 줄 `TL;DR: ` 60자 이내)을 붙임. `ChatTurn.Entry.reply(...)`가 그 줄을 `headline`으로 떼고 나머지를 `text`로 저장. AI끼리 주고받는 원문에는 `text`(전체 답)만 들어감. 화면은 `EntryRow`: 이름 + 한 줄(`shortLine`, headline 없으면 첫 문장 90자) + 오른쪽 화살표, 누르면 대표 논점과 전체 답이 펼쳐짐. 펼침 상태는 `Discussion.openEntries`(저장 안 함). 이 Mac의 Command Line Tools에는 SwiftUI `@State` 매크로 플러그인이 없어 `@State`를 쓰면 빌드 실패 → 상태는 ObservableObject에 둘 것.
- **모드3 대표 판단 실패 완화**: 사용자 화면에서 7/12에 "Moderator decision failed"로 끝남. 논점이 500자를 넘으면 거절하던 규칙이 원인으로 추정(원문이 저장되지 않아 확정 못함). 이제 JSON을 앞뒤 문장/코드블록 속에서도 찾아내고, 긴 논점·이유는 600자로 잘라 받음. 대표에게 논점을 250자 이내로 요청, 판단 시간 제한 120→180초.
- **실제 화면 확인 못 함**: 이 세션에서 화면 캡처 도구가 없어 빌드·시험만 확인.

## 최신 변경 — Claude (2026-10-15, 모드3)

- **모드3 첫 단계 = 동시 첫 의견**: 모드1처럼 모든 AI가 동시에 각자 의견을 냄(서로의 답을 보지 않음). 답은 도착 순서대로 화면에 붙고, 대화 원문에는 메시지에서 부른 AI 먼저(`namedFirst`) 들어감. 그다음부터 대표가 한 명씩 지목, 지목된 AI는 전체 원문을 읽고 답함. 모든 AI가 첫 의견을 냈으므로 이후 발언은 항상 "누구의 무슨 말에 답하는지"로 시작.
- **발언 수 = AI마다**: `ChatConfiguration.turnsPerAI`(기본 4, 2~10). 전체 상한 = 인원 × turnsPerAI(`ChatTurn.maxTurns`에 저장, `ChatTurn.turnsPerAI`도 저장). 첫 의견·실패도 1회. 대표에게 AI별 사용 횟수와 남은 AI를 알려주고, 횟수를 다 쓴 AI를 지목하면 남은 AI 중 가장 적게 말한 AI로 바꿈. 최소 발언 수 공식(`minimumDebateTurns`)은 전체 상한 기준 그대로. 예전 `maxTurns`(전체 9회) 설정은 더 이상 쓰지 않지만 옛 대화 표시는 그대로.
- **중지**: `DebateCancellation`이 여러 프로세스를 함께 들고 있다가 Stop 때 모두 종료(`detach(process)`로 바뀜).
- 시험 `tools/tests/run_mode2.sh` 모드3 부분을 새 흐름으로 갱신, 전부 통과.

## 최신 변경 — Claude (2026-10-15)

- **키체인 창 반복 해결**: 팀 ID 없는 앱은 "항상 허용"이 빌드마다 바뀌는 해시에 묶여 매 빌드마다 다시 물음. Claude Code는 로그인을 `/usr/bin/security`로 저장하므로, 앱도 `security find-generic-password -s <서비스> -w`로 읽게 바꿈(`Usage.swift` `accessToken`). 두 계정 모두 창 없이 읽힘 확인.
- **Documents 권한 창 원인과 조치**: 빌드 스크립트가 문서 폴더 안 프로젝트에서 앱을 열어 `PWD/OLDPWD`가 앱 환경에 들어갔고, 자식 AI 도구(Claude 플러그인이 띄우는 `sh` 등)가 그 폴더를 확인하며 Documents 접근이 발생한 것으로 판단. 앱 시작 시 `unsetenv("PWD"/"OLDPWD")`, 빌드 스크립트는 `cd /` + `env -u PWD -u OLDPWD open`. 실행 중 앱 환경에 PWD 없음 확인. **창이 완전히 사라졌는지는 사용자 확인 필요.**
- **Gemini 유튜브 링크**: 한 번 실행 모드(`agy -p`)는 링크 열기 허락을 물을 수 없어 자동 거절됐음. 앱이 `~/.gemini/antigravity-cli/settings.json`의 `permissions.allow`에 `read_url(youtube.com|www.youtube.com|m.youtube.com|youtu.be)`만 **추가**(백업 `settings.json.backup-before-ai-illuminati`, `GeminiLinks` in `Discussion.swift`). Gemini 메시지 앞에 도구 안내를 붙임. 중요: agy는 **영상을 보지 않고 페이지(제목·채널·설명란)만 읽음**. 자막/영상 내용은 못 가져옴. 다른 사이트와 명령 실행은 여전히 막혀 있음. `--mode plan`은 `--disable-slash-commands`와 함께면 효과가 없다는 경고가 나와서 뺌.
- **대화 중 모드 변경**: 모드 선택이 진행 중에만 잠김. 각 질문이 자기 모드를 저장하고, 바뀐 지점에 구분선 표시. 모드1로 돌아오면 "요약 + 요약 이후 다른 모드 대화 원문"을 넘겨 다음 요약에 합쳐짐. 모드2/3은 원래 전체 원문을 받음. 시험 `tools/tests/run_mode2.sh`에 1→2→1 전환 시험 추가, 전부 통과.

## 최신 인수인계 — Codex → Claude (2026-10-14)

**이 절이 현재 상태입니다. 아래 연혁의 이전 설명과 충돌하면 이 절과 실제 코드를 우선하세요.**
코드 변경 마지막 커밋: `88d5737` (상단 두 줄 UI). 이미지 추가: `2a2d835`.
사용자 요청으로 인수인계만 준비한 상태이며, 추가 기능 요청은 아직 없습니다.

### 시작 순서
1. 같은 프로젝트 폴더라면 `git status --short`와 `git log -5 --oneline`부터 확인. 미커밋 변경을 덮어쓰지 말 것. 다른 체크아웃이라면 로컬 변경 확인 후 `git pull --ff-only`.
2. 이 최신 절 → AGENTS.md/CLAUDE.md → 관련 소스 순서로 읽기.
3. 수정 요청을 받으면 구현 → 필요한 시험 → 실제 앱 빌드/화면 확인 → main 커밋·push. 인수인계만 받았다고 임의로 추가 수정하지 말 것.

### 현재 기능과 사용자 결정
- 여러 줄 네이티브 입력: Enter/Shift+Enter 줄바꿈, Cmd+Enter 전송. 한글 조합 보존. 입력량에 따라 높이 자동 조절.
- 입력창 안 오른쪽 원형 전송 버튼, 모드3 진행 중 같은 위치에 Stop. 별도 중복 버튼 없음.
- 대화 목록은 … 또는 우클릭으로 삭제. 확인 후 실제 방 JSON과 이미지 사본 폴더 삭제. 제공사/agy 자체 기록까지 삭제하는 것은 아님.
- 모드1: 병렬 답변 → 상호 검토 → 최종 정리 → 다음 질문용 요약. 중간 발언은 사용자가 펼칠 때만 표시.
- 모드2: 전체 원문 맥락으로 순차 발언, AI마다 한 번씩 짧게 답변. 대표가 다음 질문의 순서 지정. 별도 최종 정리/요약 없음.
- 모드3: 모두 동시에 첫 의견(서로 못 봄) → 대표가 다음 발언자/논점/종료 결정. 반복 발언 가능. AI마다 기본 4회(2~10, 첫 의견 포함), 진행 판단·최종 정리는 횟수 제외. 중지 시 실행 중인 CLI 모두 종료하고 추가 정리 호출 없음.
- 모드2/3 상단은 두 줄: 모드·최대횟수·정보 메뉴 / 참여 AI 칩. 칩 메뉴로 대표 지정, 왕관 표시, 손잡이 드래그로 순서 변경. 긴 안내는 정보 메뉴.
- 기본 UI English. 설정 Cmd+,에서 한국어로 즉시 변경/저장. AI 응답 언어는 사용자 질문을 따름.
- 이미지: + 선택/붙여넣기/드래그, 미리보기·제거·재열기. 이미지 단독 전송 가능. 원본과 별도 PNG 사본 저장. 방의 이전 이미지도 후속 질문에 재전달.
- 이미지 제한: 파일25MiB, 메시지4장, 방12장. 최대1600px 정규화(큰 결과는1024px). 이미지 대화에는 Claude와 ChatGPT만 참여. 현재 agy 입력 경로에서 이미지 지원을 검증하지 못해 Gemini 제외를 화면에 안내.

### 파일 안내
- ChatWindow.swift: 상단/사이드바/입력창/드래그/첨부 UI.
- Discussion.swift: 모드1·2, CLI 실행, 저장 모델. Debate.swift: 모드3·취소.
- Attachments.swift: 이미지 변환·보관·붙여넣기·대화 맥락 연결.
- Language.swift: UI 언어. Settings.swift: 계정/설정. main.swift: 메뉴·앱 수명.
- 사용자 데이터: ~/Library/Application Support/AI Illuminati/chats/<방ID>.json 및 <방ID>.assets/. 원본 사진은 수정하지 않음.

### 확인한 범위
- 기존 모드/순서/전체 맥락/저장 호환/언어/모드3 상한·반복·중지/이미지 보관·삭제·붙여넣기 회귀 시험 통과.
- 실제 CLI와 UI: 모드2 세 AI 순차 발언 및 후속 맥락, 모드3 반복 지목·종료·Stop, 언어 전환, 입력창 높이, 이미지 인식과 후속 재인식 확인.
- 마지막 UI 변경은 전체 빌드 통과 및 실제 모드3 두 줄 배치·대표 변경·최대횟수 메뉴 확인. UI 배치만 바꾼 뒤 전체 AI 호출 시험을 다시 반복하지는 않음.
- 시험방은 남겨둠. 기존 사용자 대화/원본 사진을 임의 삭제하지 말 것.

### 권한 문제 — 해결한 것과 미해결을 구분
- 빌드는 고정 **AI Illuminati Local Signing** 인증서를 사용. 임시 서명 fallback 제거. 서로 다른 빌드 해시에서도 동일 앱 신원 검증 통과. 인증서를 삭제/재생성하지 말 것.
- 이전 Always Allow 승인에서 고정 서명으로 전환할 때 계정별 한 번 재승인 가능. 실제 사용자 승인 후 다음 빌드에서 팝업이 사라졌는지는 사용자 확인 전이므로 보장하지 말 것.
- Documents 요청의 실제 접근 주체는 TCC 로그에서 Claude Code, 책임 프로세스는 앱. 정확한 접근 파일은 **아직 모름**. AI Face가 원인이라는 증거 없음.
- Claude 호출에 safe-mode/strict 빈 MCP/no-chrome 적용했지만 Documents 요청 재발 확인. 해결됐다고 주장하지 말 것. fs_usage는 관리자 권한이 필요해 추적하지 못함. 사용자 비밀번호를 받거나 TCC 초기화/권한 확대하지 말 것.
- agy 자체 대화 기록은 계속 쌓일 수 있음. 임의로 지우지 말 것.

### 빌드 주의
- `zsh tools/build_app.sh < /dev/null`은 실행 중 앱 종료 → 컴파일 → 고정 서명 → 실행까지 수행.
- 컴파일 캐시 권한 문제 시 CLANG_MODULE_CACHE_PATH와 SWIFT_MODULECACHE_PATH를 /tmp의 쓰기 가능한 경로로 지정.
- **빌드 완료 전에 UI 도구로 앱을 열지 말 것**: 이전 바이너리가 다시 실행되면 빌드 후에도 옛 화면이 남을 수 있음. 완료를 기다린 뒤 UI 연결.
- 서명 신원 접근은 실행 환경의 키체인 접근 권한 영향을 받음. 인증서가 안 보인다고 새 인증서로 교체하거나 임시 서명하지 말 것.

---

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
  xcrun swiftc -o /tmp/disc app/macos/{Language,Usage,Accounts,Login,Settings,Discussion,Debate,Attachments}.swift /path/to/test/main.swift
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

### 모드2 순서 드래그
- 화살표 대신 AI 이름 옆 손잡이를 끌어 재정렬. 체크박스는 참여 선택으로 유지하고, 대표의 다음 순서 지정과 방별 저장은 유지.
- 빌드 통과. 실제 UI에서 손잡이를 잡아 Gemini를 맨 뒤에서 맨 앞으로 드래그해 Gemini → ChatGPT → Claude 순서로 바뀌는 것 확인.

## English 기본 UI 및 한국어 전환 (2026-10-14)
- Language.swift: AppLanguage(en/ko), L(한국어, 영어), 저장된 순서 안내의 표시 언어 변환. 언어 미설정 시 English.
- Settings → Language에서 English/한국어 버튼으로 즉시 전환. UserDefaults appLanguage 저장. ⌘, 설정 열기 추가.
- 열린 설정·채팅창, 창 제목, 편집·메뉴바 메뉴, 삭제 확인, 사용량 안내·날짜, 로그인 터미널 안내를 양쪽 언어로 제공. 언어 전환 시 사용량 캐시를 비우고 다시 조회.
- 기존 사용자 대화·계정 이름·사용자 지정 규칙은 보존. 기본 채팅 규칙만 언어 전환에 맞춰 표시. 예전 기본 규칙은 English 기본값으로 인식해 초기 표시.
- 모드1/모드2 프롬프트에서 한국어 강제 지시 제거. 이번 사용자 질문의 언어를 따르고, 명시적인 답변 언어 요청이 있으면 우선.
- 빌드와 기존 모드2 회귀 시험 및 기본 영어/한국어 선택/설정 재생성 후 유지/사용자 규칙 보존 시험 통과(tools/tests/mode2.swift, run_mode2.sh).
- 실제 UI에서 영어 기본 화면, 한국어로 즉시 전환, 채팅창·설정창·제목·메뉴 반영, 재실행 후 한국어 유지, English 재전환 확인.
- 최종 실제 응답 시험: 같은 모드2 시험방에서 Claude가 영어 질문에는 영어, 바로 다음 한국어 질문에는 한국어로 답하는 것 확인. UI 언어는 English로 복원.

## 모드3 — 대표 진행 토론
- Debate.swift 추가: 첫 바퀴 후 대표가 JSON(action=speak/finish, speaker, focus/reason)으로 다음 발언 또는 종료 판단. 같은 AI 반복 발언 허용. 참여자 검증과 잘못된 응답 시 종료 처리.
- 전체 대화 원문, 앞선 발언·대표 논점을 매번 전달. 1~2문장/200자 이내 요청. 대표는 충분한 답변, 중요 반론 해소, 반복 여부를 기준으로 판단하며 전원 동의를 강제하지 않음.
- ChatConfiguration.maxTurns 선택 필드(기존 파일 호환), 기본9, 3~30회. 실패한 발언도 상한에 포함. 진행 판단 및 마지막 정리 호출은 별도. 종료 시 대표가 결론·남은 쟁점을 최대3문장으로 정리. 중지 시 정리도 추가 호출하지 않음.
- ChatTurn에 maxTurns/endReason/debateFocus, Entry.focus 선택 필드. 화면에 발언 횟수·다음 발언자·논점·종료 이유·Stop 표시. 모드1/2 유지, 영어/한국어 UI 지원.
- DebateCancellation은 활성 CLI에 종료 신호를 보내고 미종료 시 1초 후 강제종료. Answerer 대기도 취소/기한을 주기적으로 확인(출력 종료 후 프로세스 무한 대기 방지 포함).
- 회귀 시험(tools/tests/run_mode2.sh) 확장: 반복 발언·전체 맥락·대표 종료·상한·잘못된 진행 판단·추가 호출 없는 중지·실제 sleep 프로세스 취소·기존 모드 및 언어 호환. 전부 통과, 전체 빌드 통과.
- 실제 UI/CLI 시험: 3종 첫 바퀴 후 대표 Claude가 자신을 다시 지목해 네 번째 발언 → 대표 종료 판단 → 최종3문장 정리 확인(상한5회). 다음 질문은 Gemini 대기 중 Stop으로 중단, 2개 기존 발언 보존 및 추가 발언/정리 없이 idle 복귀 확인. 시험방 ‘모드3 시험…’ 보존.

## 입력창 정리 및 Documents 접근 조사
- 입력창을 자동 높이(36~116pt)로 변경하고, 입력창 오른쪽 안에 원형 전송 버튼 배치. 모드3 실행 중 같은 위치가 Stop으로 바뀌며 비활성 Discussing 버튼을 중복 표시하지 않음. 스크롤바는 필요할 때만 표시.
- 실제 UI에서 4줄 붙여넣기 → 높이 확장, 전체 삭제 → 작은 높이 복귀 확인.
- Documents 접근: 이전 TCC 로그에서 Claude Code가 접근 주체, 앱은 책임 프로세스. 재빌드로 ad-hoc CDHash가 바뀌어 기존 권한 일치 실패 후 재요청하는 것 확인. 고정 서명 인증서는 현재 없음. 이번 작업에서 인증서·신뢰·TCC 권한은 변경하지 않음.
- 계정별 설정과 skills/plugins의 링크 조사에서 Documents 경로 연결은 발견하지 못함. 개인 기본 ~/.claude.json의 AI Face 경로는 Application Support. AI Face를 Documents 접근 원인으로 단정할 근거 없음.
- 학교 Claude 계정으로 일반/격리 CLI 비교: 둘 다 구독 로그인으로 OK 응답. 일반 실행은 동기화된 사용자 스킬·플러그인과 claude.ai MCP 설정 로딩. safe-mode 실행은 해당 사용자 확장 비활성화 확인. 관리 정책·내장 플러그인은 유지됨.
- 앱의 Claude 채팅 호출에 --safe-mode --strict-mcp-config --mcp-config '{"mcpServers":{}}' --no-chrome 적용. 개인 설정은 수정하지 않고 앱 호출만 제한. --bare는 OAuth를 끄므로 사용하지 않음.
- 정확히 어떤 Documents 파일을 접근했는지는 아직 미확인. 사용자 권한이 이미 허용된 상태이고 서명도 임시이므로 반복 팝업 해결 완료라고 주장하지 말 것.
- 최종 UI 시험: 입력창 안쪽 Send 클릭 → 같은 자리 Stop 표시 → Stop 클릭 → Send 복귀 확인. 모드3 시험방에 중지된 시험 질문 보존.
- 중요: 격리 적용 후에도 23:00:39 TCC에 Claude(pid88704)의 Documents 요청 재발 확인. 개인 확장만의 문제라고 단정 불가. safe-mode는 부수 확장 로딩 제한이며 Documents 팝업 해결책으로 검증되지 않음.
- 정확한 파일 접근 추적(fs_usage)은 관리자 권한이 필요했고 sudo -n에서 비밀번호 필요로 진행 불가. 비밀번호를 요청하거나 권한 초기화·확대하지 않음.

## 고정 코드 서명 수정
- 실제 설치 완료: 사용자 로그인 키체인에 AI Illuminati Local Signing 인증서/비추출 개인 키. 코드 서명 용도에만 사용자 영역 신뢰, 새 키 접근 사전 허용은 /usr/bin/codesign만. 사용자/Claude 비밀번호를 읽거나 기록하지 않음.
- tools/setup_signing.sh: 한 번 설정, 기존 정상 신원은 재사용. 임시 키·패키지는 권한 제한된 임시 폴더에서만 만들고 정리. 인증서만 있고 정상 신원이 없으면 자동 교체하지 않고 중단.
- tools/build_app.sh: 빌드 전에 고정 신원 확인(없으면 실행 중 앱을 종료하지 않음), 인증서 SHA1+bundle identifier로 designated requirement 고정. 서명/검증 실패 시 중단, ad-hoc fallback 제거. open 실패도 성공으로 보고하지 않음.
- 실제 빌드·고정 서명·앱 실행 성공. 다른 빌드 해시의 사본에서도 동일 DR 및 기존 DR 만족 검증 통과(tools/tests/check_signing.py). setup 재실행 시 신원 변경 없음 확인.
- 기존 ad-hoc ACL에서 전환하므로 계정별 Always Allow 1회 재승인 가능. 실제 사용자 키체인 승인 후 다음 빌드에서 팝업 미발생까지 직접 검증한 것은 아님. Documents 접근 경로 자체는 별도 조사 사항이며 이 서명이 불필요한 파일 접근을 차단하지는 않음.

## 이미지 첨부
- Attachments.swift: ChatImage(id, conversationID, name), 이미지 디코딩·방향 보정·최대1600px PNG 사본(4.5MB 초과 시1024px 재변환). 원본 파일은 수정하지 않음. chats/<roomUUID>.assets/<imageUUID>.png 저장, 방 삭제 시 assets 폴더도 실제 삭제.
- UI: + 선택, 입력창/첨부영역 드래그, 이미지/파일 URL 클립보드 붙여넣기, 전송 전 썸네일 제거, 저장된 메시지의 썸네일 열기. 이미지 단독 전송 지원. 최대25MB/파일,4장/메시지,12장/방. 방 전환 시 미전송 사본 정리.
- Claude: 이미지가 있을 때 stream-json 사용자 이미지 블록(base64 PNG), private 0600 임시 stdin 파일, 결과 event만 추출. ChatGPT: codex exec --image 실제 파일 첨부. 모든 모드의 초기답/검토/정리/진행판단/후속질문에 방의 이전 이미지까지 재전달하며 질문별 이미지ID와 순서 매핑 포함.
- Gemini: 실제 시험에서 Anthropic식 이미지 입력 실패. 공식 agy headless 문서는 event=user/content 텍스트만 지원한다고 명시. 이번 이미지 대화에서는 Gemini를 제외하며 명시 안내. 사진 없이 텍스트만 있는 방은 기존대로 Gemini 참여. 사진 경로만 전달하고 이미지 지원이라고 주장하지 않음.
- 실제 CLI 시험: 직접 만든 도형 PNG에 Claude와 Codex가 ‘왼쪽 자홍색 원3개, 오른쪽 청록색 정사각형1개’ 정확히 답변.
- 회귀 시험에 저장/복원/원본과 분리된 사본/이미지 단독 전송/대화 삭제 시 이미지 삭제/잘못된 파일/전용 클립보드 PNG 추가. 기존 모드·언어·중지 시험 포함 전부 통과(클립보드 시험은 sandbox 밖 macOS pasteboard 서비스 필요).
- 실제 UI 시험: + 파일 선택 → 도형 PNG 미리보기 → 모드2 전송 → Claude/ChatGPT 모두 정확히 인식. 새 첨부 없는 후속 질문에서도 원본 이미지의 색과 상대 높이를 다시 확인하는 답변 확인. 시험방 ‘이미지 기능 시험…’ 보존.
- 정상 앱 종료 시 미전송 첨부 사본 정리, 진행 중 모드3 취소. 기존 사용자 사진·대화는 삭제하지 않음.

## 모드2/3 상단 두 줄 정리
- 첫 줄은 모드 선택 + 모드3 최대 발언 수 메뉴 + 정보 메뉴, 둘째 줄은 참여자 칩으로 통일.
- 별도 대표 선택 행 제거. 각 참여자 이름 옆 메뉴에서 대표 지정, 현재 대표는 왕관 표시. 참여 체크와 드래그 손잡이는 유지.
- 긴 규칙 설명과 모드 변경 안내는 정보 메뉴로 이동. 발언 수 범위와 저장 방식은 기존대로 유지.
- 전체 빌드 통과. 실제 모드3 화면에서 두 줄 배치와 메뉴를 통한 대표 변경 확인.
