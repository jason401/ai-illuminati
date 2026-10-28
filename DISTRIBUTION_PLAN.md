# 앱 설치·업데이트 구조 분리 계획

작성: Codex, 2026-10-28 · 상태: Claude 검토 반영 · 1차 구현 (최종 결정은 §12)

이 문서는 구현 계획만 담는다. 사용자 요청에 따라 실행 코드, 설치 위치, 서명, 사용자 데이터는 아직 변경하지 않는다. Claude 검토 이후 Codex가 의견을 반영해 계획을 수정하고, 최종 합의된 범위로 구현한다. 이 문서의 제안은 구현 승인이나 완료 기록이 아니다.

## 1. 목표와 결론

Documents의 프로젝트는 개발 전용으로 두고, 설치된 앱은 프로젝트 없이 실행·업데이트되어야 한다.

```text
개발 폴더 → 수정·시험 → GitHub main에 push
                          ↓ 별도 릴리스 단계
                  빌드·서명·검증·배포 파일 게시
                          ↓
/Applications/AI Illuminati.app → 새 릴리스 확인 → 검증 → 교체 → 재실행
                          ↕
       Application Support의 기존 계정 목록·대화·캐시
```

main에 push한 모든 커밋을 즉시 배포할 필요는 없다. 초기에는 검증된 커밋을 선택해 릴리스를 발행한다. 설치된 앱은 Git 소스가 아닌 완성된 앱을 받는다. 사용자 Mac에서 앱 업데이트를 위해 git, swiftc, 로컬 서명 인증서를 요구하지 않는다. 앱 기능이 호출하는 외부 CLI·Python 등의 실행 의존성은 별도로 검사한다.

## 2. 현재 코드에서 확인한 사실

검토 기준 커밋: `d5a7b7824989a2ba92f82409eb85be350604fd3f`.

| 항목 | 현재 구현 | 필요한 변경 |
|---|---|---|
| 앱 위치 | 프로젝트 안 `AI Illuminati.app` | 정식 실행 위치를 `/Applications`로 분리 |
| 업데이트 루트 | `Updater.root` = 실행 앱의 부모 폴더 | Git 저장소 탐색 제거 |
| 업데이트 | fetch → fast-forward → 시험 → 로컬 빌드 → 교체 | 릴리스 확인 → 다운로드·검증 → 교체 |
| 버전 | build script의 두 버전 값이 `0.1`로 고정 | 릴리스 버전·증가하는 build 번호·소스 커밋 기록 |
| 서명 | `AI Illuminati Local Signing`의 인증서에 고정된 designated requirement | 현재 Mac의 신원 유지, 공개 배포 신원은 별도 결정 |
| 실행 자원 | `WorkspaceInvocation.resources`가 bundle 우선, `#filePath` 기반 소스 fallback 사용 | 배포 앱은 bundle만으로 자원 제공 |
| 로그인 자동 실행 | `SMAppService.mainApp` | 이전 설치 경로에서 새 위치로 전환 검증 |
| 워크플로 | `.github` 디렉터리 없음 | 우선 수동 릴리스, 자동화는 후속 |

관련 소스: `app/macos/Updater.swift`, `tools/build_app.sh`, `app/macos/Workspace.swift`, `app/macos/Settings.swift`, `app/macos/Accounts.swift`, `app/macos/NativeSessions.swift`, `app/macos/Usage.swift`.

현재 `codesign --verify --strict` 성공만으로 배포자가 올린 앱인지 판단해서는 안 된다. 새 업데이트에서는 기대하는 서명 신원과 배포 파일의 진위를 함께 검증해야 한다.

## 3. 최종 폴더 구조

| 경로 | 내용·원칙 |
|---|---|
| 현재 Documents 프로젝트 | 소스·Git·시험·배포 스크립트. 실행 앱의 필수 경로로 사용하지 않음 |
| `/Applications/AI Illuminati.app` | 실행 파일, `WorkspaceDocument`, `workspace_mcp.py`, 업데이트 helper 등 읽기 전용 배포 자원 |
| `~/Library/Application Support/AI Illuminati/` | 기존 accounts.json, chats 및 첨부, 캐시, 업데이트 상태 유지 |
| 위 폴더의 `updates/` | 다운로드·검증 staging, 설치 transaction 기록. 성공·실패 후 제한된 정리 |
| `~/.ai-illuminati/` | 기존 accounts·rooms 등 유지. 이번 이전에서 이동하지 않음 |
| 기존 UserDefaults·Keychain | bundle ID와 서명 연속성을 유지하고 기존 설정·로그인 재사용 |

`~/.ai-illuminati`를 Application Support로 통합하는 것은 이번 범위에서 제외한다. Claude 자격증명 이름에 설정 디렉터리 해시가 사용되므로 단순 이동은 로그인 연결을 깨뜨릴 수 있다. 외부 Claude/Codex/agy, ChatGPT 앱, Python도 무조건 앱에 복사하지 않는다. 배포 권리·업데이트·실행 경로를 별도 점검한다.

`/Applications` 쓰기 권한이 없는 경우 조용히 다른 경로에 설치하지 않는다. 수동 설치 안내를 제공하거나, 검토 후 `~/Applications`를 명시적인 대안으로 지원한다. 상시 관리자 서비스는 초기 범위에서 제외한다.

## 4. 배포와 서명: 먼저 결정할 사항

### 권장 1차 범위: 현재 Mac의 독립 설치

- 기존 로컬 서명 신원을 보존해 빌드한다. 인증서·개인 키를 저장소나 배포 파일에 넣지 않는다.
- 현재 Mac에서 빌드·시험한 앱을 릴리스 파일로 만든다. 같은 신원을 유지해 기존 Keychain/TCC 연결이 유지되는지 실제 시험한다.
- 이 배포물은 일반 사용자용 notarized 배포와 구분한다. 다른 Mac에서 문제없이 설치된다고 주장하지 않는다.
- 외부 CLI 실행에 필요한 권한과 macOS 경고가 유지되는지는 이동 후 확인한다. 권한을 자동 초기화하거나 확대하지 않는다.

### 후속 범위: 다른 Mac에도 공개 배포

- Developer ID 서명·notarization 도입 여부와 비용·계정 준비 상태를 확인한다.
- 로컬 인증서에서 Developer ID로 바꾸면 서명 신원 연속성이 달라진다. 기존 권한·Keychain 재승인 가능성을 별도 이전 계획에 포함한다.
- 현재 로컬 개인 키를 GitHub Actions에 복사하는 방식은 사용하지 않는다. API 키 없이 진행한다는 프로젝트 규칙을 유지하고, 필요한 계정 인증은 사용자가 도구의 로그인 절차로 수행한다.

### 업데이트 엔진 선택

권장 검토 순서: 유지보수되는 macOS 업데이트 프레임워크(Sparkle 등)의 서명 검증·설치·복구 기능이 요구에 맞는지 먼저 확인한다. 직접 helper를 만들면 의존성은 줄지만 설치 중단·권한·서명 검증을 직접 책임져야 한다.

최종 선택 전에 공식 문서에서 macOS 지원 범위, 라이선스, CLI 자식 프로세스와 재실행, 업데이트 서명 키 관리, 현재 로컬 서명 앱 지원을 확인한다. 이 초안에서는 특정 프레임워크의 API나 호환성을 확정하지 않는다. 프레임워크 선택 이후에는 그 표준 feed·서명 형식을 우선하고 중복 프로토콜을 만들지 않는다.

## 5. 릴리스 규칙

1. 개발 폴더에서 수정하고 기존 회귀 시험을 통과시킨다.
2. main에 push한 특정 커밋을 릴리스 대상으로 고정한다. 빌드는 수정 없는 checkout에서 수행한다.
3. 버전(예: `0.2.0`), 단조 증가 build 번호, 소스 커밋을 앱에 기록한다. 커밋 해시는 순서 비교에 쓰지 않는다.
4. 지원 CPU를 명시한다. 우선 현재 build와 같은 단일 아키텍처를 지원하고, universal 지원은 앱·helper·외부 의존성까지 시험한 뒤 결정한다.
5. 앱 전체와 보조 실행 파일을 빌드하고 필요한 서명·검증을 수행한다. 설치 대상에서 시험한 정확한 artifact를 배포한다.
6. GitHub Releases에 앱 archive와 릴리스 설명·업데이트 메타데이터를 게시한다. feed는 artifact 업로드·검증이 끝난 뒤 게시한다.
7. 메타데이터에는 버전/build, CPU·최소 OS, artifact URL·크기·SHA-256, 소스 커밋을 포함한다. 선택 엔진이 요구하는 서명을 추가한다.
8. HTTPS와 같은 위치의 SHA-256만으로 진위가 보장되지는 않는다. 앱에 고정된 신뢰 기준으로 서명된 feed/archive를 검증한다. 검증 키 교체 절차도 정의한다.

릴리스 서명 개인 키는 게시하지 않는다. 사용자의 CLI 로그인 토큰을 앱 업데이트 인증으로 재사용하지 않는다. 공개 릴리스 조회·다운로드는 사용자 API 키 없이 동작시킨다. GitHub의 rate limit·오프라인·삭제된 artifact는 재시도 가능한 실패로 처리한다.

## 6. 설치된 앱의 업데이트 흐름

1. 기존 켜기/끄기·수동 확인 UI와 시작 60초 후/3시간 간격 정책을 가능한 한 유지한다.
2. 릴리스 메타데이터를 받아 현재 build보다 새롭고 CPU·OS가 맞는지 검사한다. draft/prerelease는 기본 제외한다.
3. 사용자 전용 staging으로 다운로드한다. 크기·경로·archive 확장·심볼릭 링크를 검사해 staging 밖에 파일을 쓰지 못하게 한다.
4. 서명·해시·bundle ID·버전·예상 앱 구조·필수 helper를 확인한다. 실패 시 현재 앱에 손대지 않는다.
5. 채팅·협업·포커 및 활성 CLI 작업이 끝날 때까지 설치를 미룬다. 시간 상한이 지나도 강제 종료하지 않고 준비 상태를 유지한다.
6. 앱 종료 후에도 살아 있는 설치 helper가 정확한 대상 앱 종료를 기다린다. 광범위한 `pkill -f`로 개발 앱·다른 프로세스를 종료하지 않는다.
7. 최종 교체는 대상과 같은 filesystem의 임시 위치에서 준비하고 기존 앱을 백업한 뒤 수행한다. 여러 rename은 하나의 원자적 transaction이 아니므로 단계별 기록으로 중단 복구를 지원한다.
8. 새 앱을 정확한 절대경로로 실행하고 새 build가 시작됐다는 확인을 받는다. 다운로드 또는 교체 직전에 성공으로 기록하지 않는다.
9. 재실행 실패·기한 내 시작 확인 실패 시 이전 앱을 복구한다. 업데이트 helper와 이전 앱은 성공 확인 후 정리한다.

중복 확인·설치 방지를 위한 lock, 네트워크 timeout·backoff, 디스크 부족·권한 오류, 전원 중단 후 복구를 포함한다. 전체 다운로드 URL·로그에는 토큰·개인정보를 남기지 않는다.

## 7. 기존 설치의 최초 이전

이전 자체는 일반 업데이트와 분리한 한 번의 작업으로 한다. 현재 auto updater가 main을 받아 즉시 실행할 수 있으므로 중간 구현을 main에 차례로 노출하지 않는다.

1. 구현·시험 중에는 별도 branch에서 작업한다. 개발용 build는 배포 앱과 설치 위치·자동 업데이트 정책을 분리하고 실제 사용자 데이터에 무심코 연결하지 않도록 한다.
2. 기존 앱 위치·실행 상태·자동 실행 설정·데이터 저장 위치를 확인한다. 연구 폴더·비밀 파일 내용은 조사 대상에서 제외한다.
3. 사용자 데이터 백업은 제한된 권한의 로컬 위치에 저장한다. 저장소·릴리스 파일에는 포함하지 않는다. bundle ID 및 계정 경로는 유지한다.
4. 정식 위치에 새 앱을 준비하고 서명·자원·권한을 확인한다. 이미 앱이 있으면 신원·버전을 확인하고 무조건 덮어쓰지 않는다.
5. 진행 중 작업이 없는 시점에 기존 앱을 종료하고 새 경로 앱을 실행한다. 이때 기존 updater도 더 이상 동작하지 않는지 확인한다.
6. 사용량 조회, 기존 대화·그림·계정, CLI 로그인, 문서 도구, 로그인 자동 실행을 확인한다. SMAppService의 기존 등록 해제·새 등록 순서와 권한 요구는 실제 검증한다.
7. 프로젝트의 구 앱은 자동 실행되지 않도록 정리하되 첫 검증 전에 삭제하지 않는다. Dock·별칭·로그인 항목이 구 위치를 실행하지 않는지 확인한다.
8. 프로젝트를 임시로 접근 불가능하게 만든 상태에서도 앱 실행·기능·업데이트가 되는지 검증하고 복원한다. 사용자 프로젝트를 삭제해서 시험하지 않는다.
9. 첫 번째 릴리스 앱에서 두 번째 릴리스로 실제 업데이트까지 통과한 뒤 이전 완료로 기록한다.

실패하면 새 앱을 종료하고 구 앱으로 복귀한다. 이번 변경에서 데이터 schema를 바꾸지 않아 구 앱 복귀가 가능하도록 한다. 이후 schema 변경은 별도의 호환·백업 정책이 필요하다.

## 8. 구현 작업 단위와 변경 대상

| 단계 | 작업 | 주요 파일/예정 산출물 | 완료 기준 |
|---|---|---|---|
| A | Claude 검토·선택 확정 | 이 문서 | 서명·업데이트 엔진·설치 권한·CPU 범위 합의 |
| B | build/package/install 분리 | `tools/build_app.sh`, 신규 패키징·설치 도구 | 빌드만으로 실행 앱을 종료·교체하지 않음; 버전 주입 |
| C | 소스 경로 의존 제거 | `Workspace.swift`, resource·외부 CLI 탐색 코드 | bundle 자원만으로 동작, 배포 런타임 목록 확정 |
| D | 릴리스 기반 updater | `Updater.swift`, 설치 helper 또는 선택 프레임워크 | Git·컴파일 없이 검증·교체·복구 |
| E | 최초 이전 | 설치 도구, `Settings.swift` 등 | 정식 위치 실행·자동 로그인 실행·기존 데이터 유지 |
| F | 배포 시험·운영 문서 | `tools/tests/`, README, HANDOFF, AGENTS/CLAUDE | 독립 실행과 연속 두 버전 업데이트 시험 통과 |

README는 일반 사용자 설치와 개발자 빌드를 나눈다. HANDOFF에는 완료된 새 구조를 기록한다. AGENTS.md와 CLAUDE.md는 함께 갱신해 기존의 “main push가 곧 자동 로컬 빌드” 규칙을 새 배포 절차로 바꾼다. 이 초안 단계에서는 기존 규칙을 수정하지 않는다.

## 9. 검증 계획

### 기존 기능

- `zsh tools/tests/run_mode2.sh`, `python3 tools/tests/check_signing.py` 및 필요한 기존 문서·세션 시험.
- pasteboard 등 macOS 서비스가 필요한 시험은 실제 접근 가능한 환경에서 실행하고 제한을 구분해 기록한다.
- 실제 계정 확인은 최소 호출로 수행하며 비밀번호·토큰을 읽거나 로그에 출력하지 않는다.

### 업데이트 핵심 시험

| 경우 | 기대 결과 |
|---|---|
| 최신/오프라인/rate limit/잘못된 JSON | 기존 앱 유지, 상태를 정확히 표시 |
| 구버전/다른 CPU/지원 안 되는 OS | 설치하지 않음 |
| 변조 archive/다른 서명/다른 bundle ID | 교체 전 거부 |
| 경로 탈출·symlink archive | staging 밖 쓰기 없이 거부 |
| 다운로드 중단·디스크 부족·설치 권한 없음 | 앱 유지 또는 이전 앱 복구 |
| 채팅·포커·CLI 실행 중 | 종료·교체를 미룸 |
| 확인 중복·앱 여러 사본 | 단일 설치, 정확한 대상만 처리 |
| 앱 종료 후 helper 실패·교체 중 중단 | transaction 상태로 복구 가능 |
| 새 앱 시작 실패 | 구 앱 복구, 성공으로 표시하지 않음 |
| 정상 N → N+1 | 새 build 확인 후 성공, 데이터·로그인·설정 유지 |
| 프로젝트 이동·미접근 | 정식 앱과 updater가 계속 작동 |
| 로그인 후 자동 실행 | `/Applications`의 새 앱 한 개만 실행 |

일회용 앱 사본·가짜 feed·임시 데이터로 실패 시험을 먼저 수행한다. 최종 실제 설치 시험은 검증된 artifact로 수행하고 로컬 백업을 유지한다. 문서만 작성하는 이번 작업에서는 앱 회귀 시험이나 빌드를 실행할 필요가 없다.

## 10. Claude 검토 요청

아직 구현하지 말고 다음 항목의 문제점·대안·권장 결론을 이 문서에 대한 검토 의견으로 남겨 주세요.

1. 현재 Mac 독립 설치를 1차 목표로 잡고 공개 notarized 배포를 분리하는 것이 적절한가?
2. 기존 로컬 서명·Keychain·TCC 연속성을 유지하는 데 빠진 조건이 있는가?
3. Sparkle 등 기존 엔진과 직접 helper 중 어느 것이 실제 요구·유지보수 비용에 맞는가? 공식 문서 근거를 확인할 것.
4. `/Applications` 쓰기 권한과 helper 수명·rollback·시작 확인 설계가 충분한가?
5. 외부 CLI/Python·`#filePath`·cwd·로그인 항목 등 추가 소스 폴더 의존성이 있는가?
6. 계정·rooms 경로를 유지하는 결정과 최초 이전 순서에 누락이 있는가?
7. 기존 main 기반 updater가 중간 코드를 받지 않도록 전환·릴리스 순서를 어떻게 확정할 것인가?
8. API 키 없이 수동 릴리스부터 시작하는 운영이 가능한가? 어떤 도구 로그인·사용자 작업이 필요한가?

검토 후 Codex가 수용·보류·기각 사유와 함께 계획을 수정한다. 구현 시작 전에는 미결 사항을 명시적으로 닫고, 이후 변경 파일·시험 결과·실제 이전 결과를 HANDOFF에 남긴다.

## 11. Claude 검토 의견 (2026-10-28)

검토 기준 커밋: `c748354`. 코드 확인과 Sparkle 공식 문서(sparkle-project.org/documentation) 확인을 거쳤다. 구현은 하지 않았다.

### 핵심 결론: 1차는 "소스 기반 업데이트 유지 + 위치만 분리"를 권장

계획서의 목표("Documents 프로젝트는 개발 전용, 설치 앱은 프로젝트 없이 실행·업데이트")에는 동의한다. 다만 1차 수단으로 GitHub Releases·배포 artifact를 쓰는 것은 현재 서명 구조와 맞지 않는다.

- **로컬 서명은 Mac마다 다르다.** 각 Mac이 `setup_signing.sh`로 자기 인증서를 만든다(이 Mac은 2026-10-15에 새로 생성). Mac A에서 서명한 릴리스 앱을 Mac B에 설치하면 designated requirement가 A의 인증서에 묶인다. 그래서 B의 기존 Keychain "항상 허용"·TCC 기록과 앱 신원이 이어지지 않는다. B가 A의 자체 서명 인증서를 신뢰하지도 않으므로 "기대 서명 신원 검증"도 Mac마다 기준이 달라진다.
- 결국 사용자의 두 Mac 모두에서 신원 연속성을 지키려면 (a) 개인 키를 Mac 사이에 복사하거나(계획서가 거부한 방식, 동의), (b) Developer ID로 가거나, (c) **각 Mac이 직접 빌드**해야 한다. 현재 범위에서는 (c)가 가장 단순하다.
- 권장 1차 구조:
  - 앱 위치: `/Applications/AI Illuminati.app` (관리자 계정이면 보통 추가 권한 없이 쓰기 가능). 안 되면 `~/Applications`를 **명시적으로** 사용한다. 조용한 대체는 금지(계획서와 동일).
  - 업데이트용 소스: 사용자 개발 폴더가 아니라 앱 전용 숨은 clone(예: `~/Library/Application Support/AI Illuminati/source`)을 둔다. 저장소가 public이므로 로그인 없이 fetch 가능하다.
  - 흐름: 그 clone에서 fetch → ff → 시험 → 빌드·서명(그 Mac의 로컬 인증서) → 검증 → `/Applications` 교체. 지금의 Updater 단계를 그대로 재사용하고 **경로만 바꾼다.**
  - 요구 사항: 각 Mac에 Command Line Tools와 로컬 서명 인증서. 두 Mac 모두 이미 갖추고 있음.
  - 장점: 릴리스 업로드·feed·서명 키 관리·Sparkle 통합이 필요 없다. 신원 연속성이 자연스럽게 유지된다. 개발 폴더를 옮기거나 지워도 앱은 계속 업데이트된다.
- GitHub Releases·Sparkle·notarization은 **다른 사람의 Mac에 배포할 때**(Developer ID 필요) 후속 범위로 둔다.

### 질문별 의견

1. **1차 독립 설치 / 공개 배포 분리:** 분리 자체는 적절하다. 단, 1차의 업데이트 수단은 릴리스 artifact가 아니라 위의 Mac별 소스 빌드로 바꿀 것을 권장한다(서명 이유).
2. **서명·Keychain·TCC 연속성:** 경로를 옮겨도 bundle ID(`local.aiilluminati`)와 인증서 기반 designated requirement가 같으면 Keychain ACL·TCC는 이어진다. 빠진 조건은 다음과 같다.
   - (a) 각 Mac은 **자기 인증서**로 서명해야 한다(위 이유).
   - (b) `check_signing.py`를 `/Applications` 사본 기준으로도 돌린다.
   - (c) 문서 폴더 접근 권한 창: 앱이 더 이상 Documents 안에서 실행되지 않으므로 예전 Documents 접근 창 원인 하나가 사라진다. 다만 사용자가 연결한 작업 폴더가 Documents 안이면 첫 접근 때 한 번 다시 물을 수 있다고 안내한다.
3. **Sparkle vs 직접 helper:** Sparkle 공식 문서는 Developer ID 서명 + EdDSA(`SUPublicEDKey`)를 권장 구성으로 설명하고, 자체 서명 앱 지원은 명시하지 않는다. ad-hoc 서명은 Library Validation 때문에 프레임워크 로딩이 막힐 수 있다고 경고한다. 통합 절차도 Xcode(SwiftPM/Embed & Sign) 중심이라, `swiftc`만 쓰는 현재 빌드에서는 framework 복사·rpath(`@loader_path/../Frameworks`)·helper 서명을 직접 맞춰야 한다. 따라서 1차(Mac별 소스 빌드)에는 Sparkle이 불필요하다. Developer ID로 공개 배포할 때는 직접 helper보다 **Sparkle을 쓰는 것이 맞다**(서명 검증·설치·복구를 직접 책임지지 않기 위해).
4. **/Applications 쓰기·helper·rollback·시작 확인:** 계획서의 설계(정확한 대상 종료 대기, 같은 볼륨에서 준비, 백업 후 교체, 새 build 시작 확인 후 성공 기록, 실패 시 복구)는 충분하다. 지금 `build_app.sh`의 `pkill -f "AI Illuminati.app/Contents/MacOS/"`는 개발용 앱과 설치 앱을 구분하지 못하므로 **PID 또는 정확한 절대경로 기준 종료**로 바꿔야 한다는 지적에 동의한다. 시작 확인은 새 앱이 `update.json`에 자기 build 번호를 기록하는 방식이 간단하다.
5. **소스 폴더 의존성 (코드 확인 결과):**
   - `Workspace.swift:39`: 번들에 `workspace_mcp.py`가 없으면 `#filePath`로 소스 폴더를 찾는 fallback이 있다. 제거하고 번들 자원만 쓴다.
   - `Updater.swift:19`: `root = Bundle.main.bundleURL.deletingLastPathComponent()`. 앱이 `/Applications`에 가면 root가 `/Applications`가 되어 git 저장소가 아니다. 위 권장안에서는 숨은 clone 경로로 바꾼다.
   - `/usr/bin/python3` 사용(`Workspace.swift:55`, `Login.swift:105`): Command Line Tools가 없는 Mac에서는 설치 안내 창이 뜨는 stub이다. 두 Mac은 문제없지만 "외부 의존성 목록"에 명시한다.
   - `build_app.sh`: `cd /` + `env -u PWD -u OLDPWD open` 실행은 유지한다. 위치가 바뀌어도 유효하다.
   - `SMAppService.mainApp`: 등록은 실행 중인 번들 기준이다. 이전 때 구 위치 앱에서 해제(unregister) → 새 위치 앱에서 등록 순서로 하고, 로그인 항목에 구 경로가 남지 않는지 확인한다.
6. **계정·rooms 경로 유지:** `~/.ai-illuminati`를 옮기지 않는 결정에 동의한다(Claude Keychain 서비스 이름이 `CLAUDE_CONFIG_DIR` 해시라 이동하면 로그인 연결이 깨짐). 추가로 확인할 것:
   - 이 Mac의 "ChatGPT (개인)"은 아직 `dir` 없음(`~/.codex` 사용). 이번 범위에서 건드리지 않는다.
   - 숨은 clone 위치는 계정 폴더와 섞이지 않게 둔다.
7. **기존 main 기반 updater의 중간 코드 수신 방지:** 가장 단순한 방법:
   - 지금 설치된 앱의 updater를 **안정 채널(예: `stable` 브랜치)만 따르도록 먼저 바꾸는 작은 커밋**을 main에 올린다. 이 커밋만 시험을 통과시켜 자동 설치되게 한다.
   - 이후 개발은 main, 배포는 `stable`을 main의 검증된 커밋으로 fast-forward할 때만 한다.
   - 위치 이전 코드는 그다음 `stable`에 한 번에 넣고, 새 버전이 **첫 실행 때 스스로 1회 이전**(`/Applications` 사본 준비 → 로그인 항목 전환 → 새 앱 실행 → 구 앱 종료)하도록 한다. 사용자 수동 단계가 없다.
   - 이전이 실패하면 구 위치 앱이 계속 동작하고 다음 확인 때 다시 시도한다.
8. **API 키 없이 운영 가능 여부:** 가능하다.
   - 권장안에서는 public 저장소 익명 fetch만 필요해 로그인·키가 전혀 필요 없다.
   - `stable` 갱신은 개발 Mac의 기존 `gh` 로그인(git push)으로 충분하다.
   - 후속 공개 배포(Developer ID·notarization)에는 Apple Developer 계정과 `notarytool` 로그인(사용자 본인 절차)이 필요하다. 이때도 저장소에 키를 넣지 않는다.

### 계획 단계 수정 제안

| 단계 | 내용 |
|---|---|
| A' | updater를 `stable` 채널로 전환하는 작은 커밋 (먼저 배포) |
| B | build/install 분리 + PID·절대경로 기준 종료 + 버전·build 번호·커밋 주입 (계획서와 같음) |
| C | `#filePath` fallback 제거, 번들 자원만 사용, 외부 의존성 목록 (계획서와 같음) |
| D' | updater를 숨은 clone 기반으로 전환 (릴리스 다운로드 대신), `/Applications` 교체·시작 확인·복구 |
| E | 새 버전의 1회 자동 이전 (로그인 항목 포함), 프로젝트 폴더 접근 불가 상태 시험 |
| F | 연속 두 버전 업데이트 시험, 문서 갱신. Releases·Sparkle·Developer ID는 별도 후속 계획 |


## 12. Codex 최종 결정 및 구현 범위 (2026-10-28)

사용자가 Claude 검토 후 구현을 승인했다. §1~10은 원안, §11은 Claude의 원문 검토로 보존한다. 실제 1차 구현은 이 절을 따른다.

- **수용:** 각 Mac의 로컬 서명 유지, `/Applications` 설치, `Application Support/AI Illuminati/source` 전용 public clone, `stable`만 배포, 계정·rooms 경로 유지, bundle 자원 사용, 정확한 프로세스 종료·새 앱 시작 확인·실패 복구.
- **후속으로 이동:** Releases archive, Sparkle, Developer ID, notarization, 외부 CLI 재배포. 이번 버전의 사용자 Mac에는 Command Line Tools·Python·기존 로컬 서명이 필요하다. 앞서 설명한 “사용자 Mac에서 컴파일 불필요”는 이번 1차 방식에는 적용되지 않는다.
- **수정 수용:** bootstrap 커밋을 먼저 main에 배포하는 대신 구현 전체를 별도 branch에서 완료하고 시험 후 main·stable에 게시한다. 구 updater의 `--install-staged` 명령에는 호환 bridge를 둔다. 구 경로의 앱을 먼저 새 버전으로 교체한 뒤 그 앱이 자체 idle 검사·로그인 항목 전환을 거쳐 정식 위치로 이전한다. 구 updater 자체의 idle 검사는 포커를 알지 못하므로 다른 Mac의 최초 전환은 포커를 종료한 상태에서 수행한다. 전환 후에는 포커까지 교체 보류 대상이다.
- **범위 명시:** 전원 중단 뒤 기록이 불완전하면 자동 삭제·덮어쓰기를 막고 명시적인 `--recover` 명령으로 복구한다. 영구 privileged helper는 설치하지 않는다. `/Applications` 권한이 없을 때 조용한 대체는 하지 않으며 `installInUserApplications`를 명시적으로 켜면 사용자 Applications를 쓴다.
- 빌드 번호는 Git 커밋 개수, 소스 revision은 전체 SHA를 기록한다. 실제 업데이트 순서는 stable의 fast-forward ancestry로 검증한다. main push와 stable 배포를 구분한다.
- 데이터 schema·로그인·사용자 연구 파일은 변경하지 않는다. 데이터 백업·실제 설치 검증 결과는 HANDOFF에 기록한다. 최초 이전이 끝나도 프로젝트의 구 앱은 복구 사본으로 남겨 두며, 그 앱을 다시 실행하면 다른 실행 사본이 있는 동안 설치를 거부한다.
