#!/bin/zsh
# Build/sign a candidate without touching the running installation.
# --stage: build only. No option: build, then open candidate for one-time migration.
# --install-staged: compatibility bridge for the pre-0.2 updater (idle check done by it).
cd "${0:A:h}/.." || exit 1
APP="AI Illuminati.app"
STAGED="AI Illuminati.update.app"
LOG="app-build.log"
MODE="${1:-}"
SIGNING_NAME="AI Illuminati Local Signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

# Build never modifies or terminates the running installation.
if [[ "$MODE" == "--install-staged" ]]; then
  # Keep the old updater working on Macs that have not migrated yet. Its first swap
  # stays at the old path; the new app then migrates itself using its own idle check.
  CANDIDATE="$PWD/$STAGED"
  CURRENT="$PWD/$APP"
  SUPPORT="$HOME/Library/Application Support/AI Illuminati"
  mkdir -p "$SUPPORT/updates"
  nohup /usr/bin/python3 "$CANDIDATE/Contents/Resources/install_app.py" \
    --legacy --staged "$CANDIDATE" --current "$CURRENT" --target "$CURRENT" \
    --support "$SUPPORT" --token "$(uuidgen)" \
    </dev/null >>"$SUPPORT/updates/install.log" 2>&1 &!
  exit 0
fi
if [[ "$MODE" != "" && "$MODE" != "--stage" ]]; then
  echo "Usage: zsh tools/build_app.sh [--stage]"
  exit 1
fi

SIGNING_ID=$(security find-identity -v -p codesigning "$KEYCHAIN" | awk -v name="$SIGNING_NAME" 'index($0, "\"" name "\"") {print $2; exit}')
if [[ -z "$SIGNING_ID" ]]; then
  echo "고정 서명이 필요합니다 / Local signing identity required."
  echo "먼저 실행하세요 / Run once: zsh tools/setup_signing.sh"
  echo "기존 앱은 그대로 둡니다. 임시 서명으로 대체하지 않습니다."
  exit 1
fi

OUT="$STAGED"
rm -rf "$OUT"
echo "1/3 새 버전을 준비 (실행 중인 앱은 그대로)"

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
cp app/resources/workspace_mcp.py tools/install_app.py "$OUT/Contents/Resources/"
if ! xcrun swiftc -swift-version 5 -O -o "$OUT/Contents/Resources/WorkspaceDocument" tools/workspace_document.swift >>"$LOG" 2>&1; then
  cat "$LOG"
  exit 1
fi
if ! xcrun swiftc -swift-version 5 -O -o "$OUT/Contents/Resources/InstallBridge" tools/install_bridge.swift >>"$LOG" 2>&1; then
  cat "$LOG"
  exit 1
fi
# App icon: the menu bar mark drawn large by app/macos/Icon.swift.
ICON_TMP="$(mktemp -d)"
if ! xcrun swiftc -swift-version 5 -O -o "$ICON_TMP/MakeIcon" app/macos/Icon.swift tools/make_icon.swift >>"$LOG" 2>&1 \
   || ! "$ICON_TMP/MakeIcon" "$ICON_TMP/AppIcon.iconset" >>"$LOG" 2>&1 \
   || ! iconutil -c icns "$ICON_TMP/AppIcon.iconset" -o "$OUT/Contents/Resources/AppIcon.icns" >>"$LOG" 2>&1; then
  rm -rf "$ICON_TMP"
  cat "$LOG"
  exit 1
fi
rm -rf "$ICON_TMP"
mv -f "$OUT/Contents/MacOS/AIIlluminati.new" "$OUT/Contents/MacOS/AIIlluminati"

cat > "$OUT/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>AIIlluminati</string>
<key>CFBundleIdentifier</key><string>local.aiilluminati</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundleName</key><string>AI Illuminati</string>
<key>CFBundleDisplayName</key><string>AI Illuminati</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>$(git rev-list --count HEAD)</string>
<key>AISourceRevision</key><string>$(git rev-parse HEAD)</string>
<key>AIUpdateChannel</key><string>stable</string>
<key>CFBundleShortVersionString</key><string>0.2.0</string>
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

echo "Built $(date)" >>"$LOG"
echo "준비 완료: $OUT"
if [[ -z "$MODE" ]]; then
  echo "기존 앱이 실행 중이면 먼저 종료해 주세요. 새 앱은 별도 설치 위치로 이전합니다."
  # Explicit developer action; the prepared app migrates itself on first launch.
  APP_PATH="$(pwd)/$OUT"
  (cd / && env -u PWD -u OLDPWD open -n "$APP_PATH") || exit 1
fi
