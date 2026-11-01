# AI Illuminati

**Claude · ChatGPT/Codex · Gemini 구독 계정을 한곳에서 보고, 여러 AI와 대화하는 macOS 메뉴바 앱.**

무료 오픈소스 · **MIT License** · macOS 13 이상 · English / 한국어

> 앱 사용료는 없습니다. AI 기능에는 각 제공사의 CLI와 사용 가능한 계정이 필요하며, 구독 요금·사용 한도·이용 조건은 각 제공사를 따릅니다. 이 앱은 Anthropic, OpenAI 또는 Google의 공식 제품이 아닙니다.

## 주요 기능

- **계정별 사용량:** 5시간·주간 잔여량과 충전 시각, 여러 계정, 짧은 막대·원형·카드 보기.
- **살아 있는 메뉴바:** 계정별 막대, 컬러/흑백, 시선 이동·눈 깜빡임·금빛 후광. 동작 줄이기 지원.
- **AI 대화:** 토론, 비판 토론, 협업, 독립 투표. 질문과 답변, 자료·이미지, 계정별 세션을 관리합니다.
- **파일 협업:** 폴더 연결, 읽기/작성/작성+실행 권한, 작업 배분·검토, 변경 전 백업과 되돌리기.
- **이미지:** 사진 첨부 및 AI가 만든 그림 표시·공유. 제공사별 이미지 기능은 다릅니다.
- **포커:** 사람과 AI 또는 AI끼리 가상 칩으로 텍사스 홀덤을 합니다. 실제 금전 거래는 없습니다.
- **업데이트:** 새 버전은 자동으로 확인할 수 있고, 설치는 사용자가 버튼을 눌러 진행합니다.

## 화면

아래는 **실제 앱 UI를 가상 계정으로 렌더링한 예시**입니다. 실제 사용자 화면·계정·대화는 포함하지 않습니다.

<p>
  <img src="docs/images/settings-general.png" width="334" alt="AI Illuminati 일반 설정: 메뉴바 표시, 흑백과 애니메이션, 업데이트 설정">
  <img src="docs/images/settings-accounts.png" width="334" alt="AI Illuminati 계정 설정: 가상의 Personal 및 Work 계정">
</p>

## 다운로드 및 설치

[GitHub Releases](https://github.com/jason401/ai-illuminati/releases)에서 **`AI-Illuminati-0.2.0-source.zip`**과 **`SHA256SUMS`**를 받으세요. 릴리스가 아직 게시되지 않았다면 아래 소스 설치를 이용할 수 있습니다.

**현재 배포 형식은 소스 설치 패키지입니다.** 내려받자마자 실행되는 사전 빌드 `.app`/DMG는 제공하지 않습니다. 현재 설치·업데이트 구조는 각 Mac의 로컬 서명 신원을 계속 사용하므로, 개발자의 서명 키나 로그인 정보를 묶은 앱을 배포하지 않습니다.

1. macOS 13 이상에서 Xcode Command Line Tools와 Python 3를 준비합니다. `xcode-select --install`로 Apple의 설치 안내를 열 수 있습니다.
2. 다운로드한 ZIP의 SHA-256을 확인하고 압축을 풉니다. [검증·설치 안내](docs/INSTALL.md)를 참고하세요.
3. **`Install AI Illuminati.command`**를 실행합니다. 이 파일은 공식 GitHub 저장소의 **`v0.2.0` 태그**를 새 폴더에 내려받아, 이 Mac에서 서명을 준비하고 빌드합니다. 최초 컴파일에는 시간이 걸립니다.
4. 기존 AI Illuminati가 실행 중이면 작업을 마치고 종료한 뒤 진행하세요. 새 앱은 `/Applications/AI Illuminati.app`로 이전됩니다.
5. 설정 → 계정에서 사용할 AI 도구의 공식 브라우저 로그인 절차를 진행합니다. 앱에 비밀번호나 API 키를 입력하지 않습니다.

Apple Developer 유료 계정은 필요하지 않습니다. 대신 **Apple Developer ID 서명·공증(notarization)이 없는 앱**이므로 macOS가 실행을 차단할 수 있습니다. 출처와 체크섬을 확인한 경우에만 시스템 설정 → 개인정보 보호 및 보안 → **확인 없이 열기 / Open Anyway**를 사용하세요. 이것이 안전성을 보증하는 것은 아닙니다. Gatekeeper/SIP를 끄거나 격리 속성을 일괄 삭제하는 방법은 안내하지 않습니다. [Apple 공식 실행 안내](https://support.apple.com/en-us/102445)

### Git에서 직접 설치

```bash
git clone --branch stable --single-branch https://github.com/jason401/ai-illuminati.git
cd ai-illuminati
zsh tools/setup_signing.sh
zsh tools/build_app.sh
```

서명 준비는 이 Mac에 코드 서명용 로컬 인증서·개인 키를 생성하며, macOS가 승인을 요청할 수 있습니다. 승인과 암호 입력은 사용자가 macOS에서 직접 합니다. 키를 다른 사람과 공유하거나 GitHub에 올리지 마세요. 빌드만 하려면 `zsh tools/build_app.sh --stage`를 사용합니다.

Claude Code, Codex, Antigravity CLI(agy)는 **별도 설치·라이선스**의 도구이며 이 패키지에 포함되지 않습니다. Codex는 PATH의 일반 실행 파일 또는 앱이 지원하는 위치에서 찾습니다. [사용법과 필요한 도구](docs/USAGE.md)를 확인하세요.

## 개인정보와 권한

- 앱은 사용량 조회를 위해 로컬 인증 정보를 읽으며, AI 요청은 해당 제공사의 CLI/서비스로 전달합니다. **완전한 오프라인 앱이 아닙니다.** 연결한 자료가 AI에게 전달될 수 있습니다.
- 계정·대화·사진 사본·백업·업데이트 소스는 `~/Library/Application Support/AI Illuminati`, 앱 전용 계정은 `~/.ai-illuminati` 아래에 저장합니다. 일부 인증은 macOS 키체인에 저장됩니다. 제공사 CLI는 별도 세션 기록을 남길 수 있습니다.
- 기본적으로 API 키를 요구하지 않습니다. 각 제공사의 로그인과 사용 조건·조직 정책을 따르세요.
- 파일 협업의 **작성/작성+실행**은 실제 파일을 바꿀 수 있습니다. 권한과 변경 내역을 확인하고, 중요한 파일은 별도로 백업하세요.
- 스크린샷·로그·오류 보고에 이메일, 인증 정보, 실제 대화나 개인 경로를 넣지 마세요.

보안 보고와 민감한 파일을 제외하는 방법은 [SECURITY.md](SECURITY.md)를 참고하세요.

## 업데이트와 개발

설치 앱은 공개 `stable` 브랜치를 확인합니다. 자동 확인이 켜져 있으면 시작 후 약 60초와 3시간마다 확인하고, **지금 업데이트 / Update Now**를 눌러야 시험·로컬 빌드·앱 교체를 진행합니다. Command Line Tools, Python, 로컬 서명 신원이 계속 필요합니다. 개발 프로젝트 폴더는 앱이 자동으로 수정하지 않습니다.

자세한 사용법: [docs/USAGE.md](docs/USAGE.md)

```bash
zsh tools/tests/run_mode2.sh
python3 tools/tests/check_signing.py "/Applications/AI Illuminati.app"
```

일부 시험은 macOS의 클립보드 접근이 필요합니다. 기본 회귀 시험은 실제 AI를 호출하지 않습니다.

## AI-assisted development

이 프로젝트는 유지관리자가 방향과 요구사항을 정하고, **Claude Code와 OpenAI Codex 등 AI 개발 도구의 도움으로 구현·검토·시험한 프로젝트**입니다. AI가 작성한 내용도 오류가 있을 수 있으며, 계정·자료·파일 권한과 실제 변경을 사용자가 확인해야 합니다.

## 라이선스

**Copyright (c) 2026 jason401. [MIT License](LICENSE).** 무료 사용·수정·재배포 및 상업적 사용을 허용하며, 저작권·라이선스 고지를 유지해야 합니다. 보증은 제공하지 않습니다.

외부 AI 서비스, 별도 설치하는 CLI, Apple 시스템 구성 요소 및 상표에는 각각의 조건이 적용됩니다. [외부 구성 요소 안내](THIRD_PARTY_NOTICES.md)를 참고하세요.
