#!/bin/zsh
# Builds "AI Illuminati.app" (menu bar usage gauge) from app/macos/*.swift into the project
# folder, then starts it. Needs the Xcode Command Line Tools (swiftc).
cd "${0:A:h}/.." || exit 1
APP="AI Illuminati.app"
LOG="app-build.log"

echo "1/3 실행 중인 앱 종료"
osascript -e 'tell application id "local.aiilluminati" to quit' >/dev/null 2>&1
sleep 1
pkill -f "AI Illuminati.app/Contents/MacOS/" 2>/dev/null

echo "2/3 컴파일"
mkdir -p "$APP/Contents/MacOS"
ARCH="$(uname -m)"
if ! xcrun swiftc -swift-version 5 -O -target "$ARCH-apple-macos13.0" \
      -framework Cocoa -framework ServiceManagement -framework Security \
      -o "$APP/Contents/MacOS/AIIlluminati.new" app/macos/*.swift >"$LOG" 2>&1; then
  echo "빌드 실패 (app-build.log):"
  cat "$LOG"
  exit 1
fi
mv -f "$APP/Contents/MacOS/AIIlluminati.new" "$APP/Contents/MacOS/AIIlluminati"

cat > "$APP/Contents/Info.plist" <<'PLIST'
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

# Reuse AI Face's local signing certificate when it exists, so a Keychain "Always Allow"
# survives rebuilds; otherwise sign ad-hoc.
if ! codesign --force --deep --sign "AI Face Local Signing" "$APP" >>"$LOG" 2>&1; then
  codesign --force --deep --sign - "$APP" >>"$LOG" 2>&1
fi

echo "3/3 앱 실행"
echo "Built $(date)" >>"$LOG"
open "$APP"
echo "완료: 메뉴바 오른쪽 위의 삼각형 안의 눈 마크를 누르면 자세히 보여요."
