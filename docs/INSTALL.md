# 설치와 macOS 보안 경고

## 배포 형식

현재 릴리스 후보는 **소스 설치 패키지**입니다. ZIP 안에는 공개 앱 소스·빌드/시험 도구·문서·MIT 고지·설치 실행 파일이 있고, 개발자의 앱 데이터·CLI 로그인·서명 개인 키는 없습니다. 사전 빌드 앱이나 DMG가 있다는 뜻은 아닙니다.

Releases가 게시되기 전에는 다운로드 자산이 없습니다. 게시 후에는 공식 [Releases](https://github.com/jason401/ai-illuminati/releases)의 Assets에서 다음을 받습니다.

- `AI-Illuminati-0.2.0-source.zip`
- `SHA256SUMS`

GitHub가 자동으로 만드는 `Source code (zip)`에는 설치 실행 파일이 있을 수 있지만 Git 메타데이터는 없습니다. **ZIP 안에서 곧바로 기존 build_app.sh만 실행하는 방법은 사용하지 마세요.** 빌드가 Git revision을 필요로 하므로, 전용 설치 실행 파일은 공식 태그를 Git으로 새로 받습니다.

## 필요한 것

- macOS 13 이상, Xcode Command Line Tools(Apple Swift 컴파일러·git·시스템 SDK), Python 3.
- 최초 설치와 업데이트 시 GitHub 연결, AI 사용 시 해당 제공사 연결.
- 사용하려는 AI의 CLI와 사용 가능한 로그인. 외부 도구는 배포 패키지에 포함되지 않습니다.
- 앱을 설치할 위치에 대한 쓰기 권한. 기본 `/Applications`가 제한되면 오류를 확인하세요. 명시적인 사용자별 설치는 아래를 실행한 뒤 설치합니다.

```bash
defaults write local.aiilluminati installInUserApplications -bool true
```

이 선택은 설치 위치를 `~/Applications`로 바꿉니다. 불필요한 전체 디스크 접근이나 관리자 서비스를 요구하지 않습니다.

## 체크섬

ZIP과 SHA256SUMS를 같은 폴더에 둔 뒤 그 폴더에서 실행합니다.

```bash
shasum -a 256 -c SHA256SUMS
```

`OK`인지 확인합니다. 실패하면 실행하지 말고 공식 릴리스에서 다시 받으세요. 체크섬은 다운로드 손상을 확인하는 수단이며, 같은 출처의 파일과 체크섬이 함께 바뀌는 공격까지 막는 서명은 아닙니다.

## 실행 순서

1. 기존 앱의 채팅·작업·게임을 마치고 종료합니다.
2. ZIP을 풀고 `Install AI Illuminati.command`를 확인해 실행합니다. 실행 권한을 잃었다면, 신뢰하는 파일인지 확인한 뒤 터미널에서 `zsh "Install AI Illuminati.command"`로 실행할 수 있습니다.
3. 설치 실행 파일은 `v0.2.0` 태그를 별도의 캐시 폴더에 clone합니다. 기존 개발 프로젝트를 덮어쓰지 않습니다.
4. 기존 `AI Illuminati Local Signing` 신원이 있으면 재사용하고, 없으면 공식 저장소의 setup_signing.sh가 이 Mac에 코드 서명용 신원을 생성합니다. macOS 인증 창은 사용자가 직접 승인합니다.
5. 이 Mac의 CPU 아키텍처에 맞게 컴파일합니다. 처음 실행된 후보가 정상 설치 위치로 이전됩니다. 계정 추가는 설치 후 별도로 진행합니다.

캐시의 정확한 경로는 터미널에 표시됩니다. 설치가 끝나기 전에 후보 앱이나 캐시를 지우지 마세요. 새 실행 파일은 Apple Silicon/Intel 공용 universal 바이너리가 아니라 **해당 Mac에서 빌드한 바이너리**입니다. 모든 macOS·CPU 조합에서 실제 실행 시험한 것은 아닙니다.

## macOS가 차단할 때

유료 Apple Developer 계정과 Apple Developer ID 공증을 사용하지 않으므로, 로컬 서명만으로 Apple이 개발자를 검증하거나 안전성을 보증하지 않습니다.

1. 공식 저장소·태그와 다운로드 체크섬을 확인합니다.
2. 파일을 한 번 열어 macOS의 메시지를 확인합니다.
3. 출처를 신뢰할 때만 **시스템 설정 → 개인정보 보호 및 보안 → Open Anyway / 확인 없이 열기**에서 해당 항목의 예외를 승인합니다. macOS가 본인 인증을 요구하면 직접 완료합니다.
4. 악성코드 경고, 예상치 못한 손상 메시지, 체크섬 불일치라면 예외를 강행하지 말고 멈추세요. 관리되는 Mac에서는 조직 정책 때문에 예외 승인이 불가능할 수 있습니다.

Gatekeeper/SIP 끄기, ‘모든 앱 허용’, `xattr`로 격리 속성을 일괄 제거하는 절차는 제공하지 않습니다.

근거: [Apple — Safely open apps on your Mac](https://support.apple.com/en-us/102445).

## 업데이트

자동 확인과 설치는 다릅니다. 새 버전이 표시되면 사용자가 **Update Now**를 눌러야 설치합니다. 현재 업데이트도 각 Mac의 git·Python·Command Line Tools·기존 로컬 서명을 사용합니다. 개발자용 인증서나 키를 다운받지 않습니다.

배포 앱만 내려받는 방식 또는 Developer ID/Sparkle 기반 업데이트로 전환하려면 추가 구현과 검증이 필요합니다. 이번 문서·패키징 변경은 앱 기능을 바꾸지 않습니다.

## 예전 버전에서 업데이트가 거절될 때

공개 이력 정리 이전에 설치한 버전은 업데이트 소스의 Git 계보가 달라졌다고 표시할 수 있습니다. 이 경우 진행 중인 작업을 마치고 종료한 뒤 새 릴리스의 설치 실행 파일을 사용하세요. 설치 실행 파일은 전용 업데이트 소스만 잠금을 잡고 새 stable checkout으로 교체하며, 기존 소스는 로컬 migration-backups에 보관합니다. 계정·대화·서명 키는 변경하지 않습니다. 소스에 로컬 수정이 있으면 덮어쓰지 않고 중단합니다.
