#!/bin/zsh
set -eu
cd "${0:A:h}/../.."
TEST_DIR=$(mktemp -d /tmp/ai-mode2-check.XXXXXX)
trap 'rm -rf "$TEST_DIR"' EXIT
# The real account list must come out of the tests exactly as it went in.
REAL_ACCOUNTS="$HOME/Library/Application Support/AI Illuminati/accounts.json"
real_accounts() { [[ -f "$REAL_ACCOUNTS" ]] && shasum -a 256 "$REAL_ACCOUNTS" || echo missing }
REAL_BEFORE=$(real_accounts)
mkdir -p "$TEST_DIR/data"
cp tools/tests/mode2.swift "$TEST_DIR/main.swift"
# "[n/m] name" before each stage: the app shows it under the current step (project_run).
echo "[1/10] Check the data folder rule"
# Only the app picks the real data folder, before it makes anything that reads it.
python3 - <<'PY'
from pathlib import Path
s = Path('app/macos/main.swift').read_text()
call, start = s.find('AccountStore.useRealHome()'), s.find('AppDelegate()')
assert 0 <= call < start, 'main.swift must call AccountStore.useRealHome() before AppDelegate()'
assert s.count('useRealHome()') == 1, 'only main.swift chooses the real data folder'
import subprocess
users = subprocess.run(['grep', '-rl', '--include=*.swift', 'useRealHome()', 'app', 'tools'], capture_output=True, text=True).stdout.split()
assert sorted(users) == ['app/macos/Accounts.swift', 'app/macos/main.swift', 'tools/tests/real_home.swift'], users
PY
echo "[2/10] Real data folder check"
mkdir -p "$TEST_DIR/real-home-src" && cp tools/tests/real_home.swift "$TEST_DIR/real-home-src/main.swift"
xcrun swiftc -swift-version 5 -module-cache-path "$TEST_DIR/cache" -o "$TEST_DIR/real-home" app/macos/Accounts.swift "$TEST_DIR/real-home-src/main.swift"
"$TEST_DIR/real-home"
echo "[3/10] Build WorkspaceDocument"
mkdir -p "$TEST_DIR/resources"
cp app/resources/workspace_mcp.py app/resources/project_process.py app/resources/local_models.json "$TEST_DIR/resources/"
xcrun swiftc -swift-version 5 -module-cache-path "$TEST_DIR/cache" -o "$TEST_DIR/resources/WorkspaceDocument" tools/workspace_document.swift
echo "[4/10] Installer tests"
PYTHONDONTWRITEBYTECODE=1 python3 tools/tests/test_install_app.py
echo "[5/10] Workspace MCP tests"
PYTHONDONTWRITEBYTECODE=1 python3 tools/tests/test_workspace_mcp.py
echo "[6/10] Material fixtures"
PYTHONDONTWRITEBYTECODE=1 python3 tools/tests/material_fixtures.py "$TEST_DIR/data/material-fixtures"
echo "[7/10] Compile app tests"
xcrun swiftc -swift-version 5 -module-cache-path "$TEST_DIR/cache" -o "$TEST_DIR/run" \
    app/macos/ProjectWork.swift app/macos/ProjectChat.swift app/macos/ProjectCreate.swift app/macos/WindowDrag.swift app/macos/Language.swift app/macos/Usage.swift app/macos/Accounts.swift app/macos/Login.swift \
    app/macos/Settings.swift app/macos/CloudModels.swift app/macos/Discussion.swift app/macos/ChatNotes.swift app/macos/Debate.swift app/macos/Attachments.swift app/macos/NativeSessions.swift app/macos/RoomDocuments.swift app/macos/MaterialReader.swift app/macos/Collaboration.swift app/macos/Vote.swift app/macos/Solo.swift app/macos/Local.swift app/macos/LocalModels.swift app/macos/FaceLink.swift app/macos/ExternalMCP.swift app/macos/RemoteMCP.swift app/macos/Markdown.swift app/macos/DriveUI.swift app/macos/ToolHub.swift app/macos/Peer.swift app/macos/Route.swift app/macos/Meeting.swift app/macos/GoogleAuth.swift app/macos/DriveLink.swift app/macos/Workspace.swift app/macos/WorkspaceBackup.swift app/macos/ChatStorage.swift app/macos/Updater.swift app/macos/Pictures.swift app/macos/Poker.swift app/macos/DeviceSync.swift app/macos/Enterprise.swift app/macos/ChatFind.swift app/macos/ChatSearch.swift app/macos/ChatTools.swift app/macos/Memory.swift app/macos/Todo.swift app/macos/SidebarProjects.swift app/macos/ProjectInfo.swift app/macos/Space.swift app/macos/SpaceLibrary.swift app/macos/SpaceTemplates.swift tools/tests/space_build.swift tools/tests/google_drive.swift tools/tests/device_sync.swift tools/tests/window_drag.swift tools/tests/project_work.swift tools/tests/todo_work.swift tools/tests/project_info.swift tools/tests/update_channel.swift tools/tests/chat_search.swift tools/tests/search_fixtures.swift "$TEST_DIR/main.swift"
echo "[8/10] Run app tests"
AI_ILLUMINATI_TEST_HOME="$TEST_DIR/data" AI_ILLUMINATI_TEST_RESOURCES="$TEST_DIR/resources" "$TEST_DIR/run"
echo "[9/10] Space web view isolation"
mkdir -p "$TEST_DIR/space-web-src" "$TEST_DIR/space-web-home"
cp tools/tests/space_web.swift "$TEST_DIR/space-web-src/main.swift"
xcrun swiftc -swift-version 5 -module-cache-path "$TEST_DIR/cache" -framework WebKit -o "$TEST_DIR/space-web" \
    app/macos/Accounts.swift app/macos/Language.swift app/macos/Space.swift app/macos/SpaceLibrary.swift app/macos/SpaceTemplates.swift app/macos/SpaceWeb.swift "$TEST_DIR/space-web-src/main.swift"
AI_ILLUMINATI_TEST_HOME="$TEST_DIR/space-web-home" "$TEST_DIR/space-web"
echo "[10/10] Icon check"
xcrun swiftc -swift-version 5 -module-cache-path "$TEST_DIR/cache" -o "$TEST_DIR/icon-check" \
    app/macos/Icon.swift tools/tests/icon_animation.swift
"$TEST_DIR/icon-check"
if [[ "$(real_accounts)" != "$REAL_BEFORE" ]]; then
  echo "FAIL: the real accounts.json changed during the tests" >&2
  exit 1
fi
echo "PASS: the real accounts.json is unchanged"
