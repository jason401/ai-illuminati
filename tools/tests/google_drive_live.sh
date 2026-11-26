#!/bin/zsh
# Hand check of Google Drive against Google itself, with the app's real code (AIIntegrations): signs in through the Mac's
# sign-in sheet, connects to the official Drive MCP server, lists its tools, reads three recent files (count only) and
# refreshes the login. Needs a person to sign in. Uses a throwaway test home: never the real Keychain or app data.
set -eu
cd "${0:A:h}/../.."
TMP=$(mktemp -d /tmp/gdrive-live.XXXXXX); trap 'rm -rf "$TMP"' EXIT
zsh tools/build_modules.sh "$TMP/modules" -enable-testing -module-cache-path "$TMP/cache" >/dev/null
xcrun swiftc -swift-version 5 -module-cache-path "$TMP/cache" -I "$TMP/modules" -o "$TMP/live" tools/tests/google_drive_live.swift "$TMP"/modules/lib*.a 2>/dev/null
mkdir -p "$TMP/home"
AI_ILLUMINATI_TEST_HOME="$TMP/home" "$TMP/live"
