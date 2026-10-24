#!/bin/zsh
# Builds "AI Illuminati.app" (menu bar usage gauge) from app/macos/*.swift into the project
# folder, then starts it. Needs the Xcode Command Line Tools (swiftc).
#   (no option)        quit the app, build it, start it
#   --stage            build and sign a new copy next to the running app ("AI Illuminati.update.app");
#                      the running app is not touched (used by automatic updates)
#   --install-staged   quit the app, swap in the staged copy, start it; the old copy comes back if
#                      the swap fails
cd "${0:A:h}/.." || exit 1
APP="AI Illuminati.app"
STAGED="AI Illuminati.update.app"
LOG="app-build.log"
MODE="${1:-}"
SIGNING_NAME="AI Illuminati Local Signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

quit_app() {
  osascript -e 'tell application id "local.aiilluminati" to quit' >/dev/null 2>&1 &
  APP_QUIT_PID=$!
  # An unresponsive Apple Event must not block the build indefinitely.
  for APP_QUIT_ATTEMPT in {1..10}; do
    kill -0 "$APP_QUIT_PID" 2>/dev/null || break
    sleep 0.2
  done
  kill "$APP_QUIT_PID" 2>/dev/null
  wait "$APP_QUIT_PID" 2>/dev/null
  sleep 1
  pkill -f "AI Illuminati.app/Contents/MacOS/" 2>/dev/null
}

open_app() {
  # Open from a neutral folder so the app does not inherit this folder (in ~/Documents) as PWD.
  APP_PATH="$(pwd)/$APP"
  (cd / && env -u PWD -u OLDPWD open "$APP_PATH") || exit 1
}

if [[ "$MODE" == "--install-staged" ]]; then
  if [[ ! -d "$STAGED" ]] || ! codesign --verify --strict "$STAGED" >>"$LOG" 2>&1; then
    echo "준비된 새 버전이 없거나 서명이 맞지 않아요 / No valid staged build."
    exit 1
  fi
  quit_app
  rm -rf "$APP.old"
  [[ -d "$APP" ]] && mv "$APP" "$APP.old"
  if ! mv "$STAGED" "$APP"; then
    [[ -d "$APP.old" ]] && mv "$APP.old" "$APP"
    open_app
    exit 1
  fi
  rm -rf "$APP.old"
  echo "Installed staged build $(date)" >>"$LOG"
  open_app
  exit 0
fi

SIGNING_ID=$(security find-identity -v -p codesigning "$KEYCHAIN" | awk -v name="$SIGNING_NAME" 'index($0, "\"" name "\"") {print $2; exit}')
if [[ -z "$SIGNING_ID" ]]; then
  echo "고정 서명이 필요합니다 / Local signing identity required."
  echo "먼저 실행하세요 / Run once: zsh tools/setup_signing.sh"
  echo "기존 앱은 그대로 둡니다. 임시 서명으로 대체하지 않습니다."
  exit 1
fi

if [[ "$MODE" == "--stage" ]]; then
  OUT="$STAGED"
  rm -rf "$OUT"
  echo "1/3 새 버전을 옆에 준비 (실행 중인 앱은 그대로)"
else
  OUT="$APP"
  echo "1/3 실행 중인 앱 종료"
  quit_app
fi

echo "2/3 컴파일"
mkdir -p "$OUT/Contents/MacOS"
ARCH="$(uname -m)"
if ! xcrun swiftc -swift-version 5 -O -target "$ARCH-apple-macos13.0" \
      -framework Cocoa -framework SwiftUI -framework ServiceManagement -framework Security \
      -o "$OUT/Contents/MacOS/AIIlluminati.new" app/macos/*.swift >"$LOG" 2>&1; then
  echo "빌드 실패 (app-build.log):"
  cat "$LOG"
  exit 1
fi
mkdir -p "$OUT/Contents/Resources"
cp app/resources/workspace_mcp.py "$OUT/Contents/Resources/workspace_mcp.py"
if ! xcrun swiftc -swift-version 5 -O -o "$OUT/Contents/Resources/WorkspaceDocument" tools/workspace_document.swift >>"$LOG" 2>&1; then
  cat "$LOG"
  exit 1
fi
mv -f "$OUT/Contents/MacOS/AIIlluminati.new" "$OUT/Contents/MacOS/AIIlluminati"

cat > "$OUT/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>AIIlluminati</string>
<key>CFBundleIdentifier</key><string>local.aiilluminati</string>
<key>CFBundleName</key><string>AI Illuminati</string>
<key>CFBundleDisplayName</key><string>AI Illuminati</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>0.1</string>
<key>CFBundleShortVersionString</key><string>0.1</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>LSUIElement</key><true/>
</dict></plist>
PLIST

# Pin the designated requirement to a persistent certificate, rather than each build's hash.
REQUIREMENT="=designated => identifier \"local.aiilluminati\" and anchor H\"$SIGNING_ID\""
if ! codesign --force --sign "$SIGNING_ID" --keychain "$KEYCHAIN" \
      --requirements "$REQUIREMENT" "$OUT" >>"$LOG" 2>&1; then
  echo "고정 서명 실패 / Signing failed. See app-build.log."
  exit 1
fi
if ! codesign --verify --strict "$OUT" >>"$LOG" 2>&1; then
  echo "서명 검증 실패 / Signature verification failed."
  exit 1
fi

if [[ "$MODE" == "--stage" ]]; then
  echo "Staged $(date)" >>"$LOG"
  echo "준비 완료: $STAGED"
  exit 0
fi

echo "3/3 앱 실행"
echo "Built $(date)" >>"$LOG"
open_app
echo "완료: 메뉴바 오른쪽 위의 삼각형 안의 눈 마크를 누르면 자세히 보여요."
