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
# Each stage has a time limit, so a stuck one names itself instead of hanging the run. The stage runs in its own
# process group: on time out (or Ctrl-C) the whole group stops, compiler jobs and test servers included, and
# whatever it left running is stopped when it ends.
limit() {
  local secs=$1; shift
  perl -e '
    my $secs = shift; my $pid = fork // die "fork: $!\n";
    if (!$pid) { setpgrp(0, 0); exec @ARGV or die "exec: $!\n" }
    setpgrp($pid, $pid);
    sub stop { kill "TERM", -$pid; sleep 1; kill "KILL", -$pid; waitpid($pid, 0); exit shift }
    $SIG{ALRM} = sub { stop(142) }; $SIG{INT} = sub { stop(130) }; $SIG{TERM} = sub { stop(143) };
    alarm $secs; waitpid($pid, 0); my $status = $?; alarm 0;
    kill "KILL", -$pid;
    exit($status & 127 ? 128 + ($status & 127) : $status >> 8);
  ' "$secs" "$@" && return 0
  local rc=$?
  (( rc == 142 )) && echo "FAIL: stopped after $secs s: ${1:t}" >&2
  return $rc
}
# "[n/m] name" before each stage: the app shows it under the current step (project_run).
echo "[1/11] Check the data folder rule"
# Only the app picks the real data folder, before it makes anything that reads it.
python3 - <<'PY'
from pathlib import Path
s = Path('app/macos/main.swift').read_text()
call, start = s.find('AccountStore.useRealHome()'), s.find('AppDelegate()')
assert 0 <= call < start, 'main.swift must call AccountStore.useRealHome() before AppDelegate()'
assert s.count('useRealHome()') == 1, 'only main.swift chooses the real data folder'
import subprocess
users = subprocess.run(['grep', '-rl', '--include=*.swift', 'useRealHome()', 'app', 'tools'], capture_output=True, text=True).stdout.split()
assert sorted(users) == ['app/macos/main.swift', 'app/modules/AIAccounts/Accounts.swift', 'tools/tests/real_home.swift'], users
PY
echo "[2/11] AIAccounts module on its own"
# Built alone, checked from outside with only its public API; reaching an internal name must not compile.
MODULES="$TEST_DIR/modules"
limit 300 zsh tools/build_modules.sh "$MODULES" -module-cache-path "$TEST_DIR/cache"
mkdir -p "$TEST_DIR/accounts-src" "$TEST_DIR/accounts-home" "$TEST_DIR/boundary-src"
cp tools/tests/accounts_contract.swift "$TEST_DIR/accounts-src/main.swift"
limit 300 xcrun swiftc -swift-version 5 -module-cache-path "$TEST_DIR/cache" -I "$MODULES" -o "$TEST_DIR/accounts-contract" "$TEST_DIR/accounts-src/main.swift" "$MODULES/libAIAccounts.a"
limit 60 env AI_ILLUMINATI_TEST_HOME="$TEST_DIR/accounts-home" "$TEST_DIR/accounts-contract"
printf 'import AIAccounts\n_ = AccountStore.place\n' > "$TEST_DIR/boundary-src/main.swift"
if limit 300 xcrun swiftc -swift-version 5 -typecheck -module-cache-path "$TEST_DIR/cache" -I "$MODULES" "$TEST_DIR/boundary-src/main.swift" 2>"$TEST_DIR/boundary.log" \
   || ! grep -q "'place' is inaccessible due to 'internal' protection level" "$TEST_DIR/boundary.log"; then
  cat "$TEST_DIR/boundary.log" >&2
  echo "FAIL: code outside AIAccounts reached its internal AccountStore.place" >&2
  exit 1
fi
echo "PASS: code outside AIAccounts cannot reach its internal names"
echo "[3/11] Real data folder check"
mkdir -p "$TEST_DIR/real-home-src" && cp tools/tests/real_home.swift "$TEST_DIR/real-home-src/main.swift"
limit 300 xcrun swiftc -swift-version 5 -module-cache-path "$TEST_DIR/cache" -I "$MODULES" -o "$TEST_DIR/real-home" "$TEST_DIR/real-home-src/main.swift" "$MODULES/libAIAccounts.a"
limit 60 "$TEST_DIR/real-home"
echo "[4/11] Build WorkspaceDocument"
mkdir -p "$TEST_DIR/resources"
cp app/resources/workspace_mcp.py app/resources/project_process.py app/resources/local_models.json "$TEST_DIR/resources/"
limit 300 xcrun swiftc -swift-version 5 -module-cache-path "$TEST_DIR/cache" -o "$TEST_DIR/resources/WorkspaceDocument" tools/workspace_document.swift
echo "[5/11] Installer tests"
PYTHONDONTWRITEBYTECODE=1 limit 600 python3 tools/tests/test_install_app.py
echo "[6/11] Workspace MCP tests"
PYTHONDONTWRITEBYTECODE=1 limit 600 python3 tools/tests/test_workspace_mcp.py
echo "[7/11] Material fixtures"
PYTHONDONTWRITEBYTECODE=1 limit 300 python3 tools/tests/material_fixtures.py "$TEST_DIR/data/material-fixtures"
echo "[8/11] Compile app tests"
limit 900 xcrun swiftc -swift-version 5 -module-cache-path "$TEST_DIR/cache" -I "$MODULES" -o "$TEST_DIR/run" "$MODULES/libAIAccounts.a" \
    app/macos/ProjectWork.swift app/macos/ProjectChat.swift app/macos/ProjectCreate.swift app/macos/WindowDrag.swift app/macos/Language.swift app/macos/Usage.swift app/macos/Login.swift \
    app/macos/Settings.swift app/macos/CloudModels.swift app/macos/Discussion.swift app/macos/ChatNotes.swift app/macos/Debate.swift app/macos/Attachments.swift app/macos/NativeSessions.swift app/macos/RoomDocuments.swift app/macos/MaterialReader.swift app/macos/Collaboration.swift app/macos/Vote.swift app/macos/Solo.swift app/macos/Local.swift app/macos/LocalModels.swift app/macos/FaceLink.swift app/macos/ExternalMCP.swift app/macos/RemoteMCP.swift app/macos/Markdown.swift app/macos/DriveUI.swift app/macos/ToolHub.swift app/macos/Peer.swift app/macos/CollabLog.swift app/macos/Route.swift app/macos/Meeting.swift app/macos/GoogleAuth.swift app/macos/DriveLink.swift app/macos/Workspace.swift app/macos/WorkspaceBackup.swift app/macos/ChatStorage.swift app/macos/Updater.swift app/macos/Pictures.swift app/macos/Poker.swift app/macos/DeviceSync.swift app/macos/Enterprise.swift app/macos/ChatFind.swift app/macos/ChatSearch.swift app/macos/ChatTools.swift app/macos/Memory.swift app/macos/Todo.swift app/macos/SidebarProjects.swift app/macos/ProjectInfo.swift app/macos/GitBranches.swift app/macos/Space.swift app/macos/SpaceLibrary.swift app/macos/SpaceTemplates.swift tools/tests/space_build.swift tools/tests/google_drive.swift tools/tests/device_sync.swift tools/tests/window_drag.swift tools/tests/project_work.swift tools/tests/ask_ai.swift tools/tests/collab_log.swift tools/tests/meeting_tool.swift tools/tests/todo_work.swift tools/tests/project_info.swift tools/tests/update_channel.swift tools/tests/chat_search.swift tools/tests/search_fixtures.swift "$TEST_DIR/main.swift"
echo "[9/11] Run app tests"
# The tests also stop themselves after 120 s without progress (mode2.swift) and name the test.
limit 1500 env AI_ILLUMINATI_TEST_HOME="$TEST_DIR/data" AI_ILLUMINATI_TEST_RESOURCES="$TEST_DIR/resources" "$TEST_DIR/run"
echo "[10/11] Space web view isolation"
mkdir -p "$TEST_DIR/space-web-src" "$TEST_DIR/space-web-home"
cp tools/tests/space_web.swift "$TEST_DIR/space-web-src/main.swift"
limit 600 xcrun swiftc -swift-version 5 -module-cache-path "$TEST_DIR/cache" -framework WebKit -I "$MODULES" -o "$TEST_DIR/space-web" "$MODULES/libAIAccounts.a" \
    app/macos/Language.swift app/macos/Space.swift app/macos/SpaceLibrary.swift app/macos/SpaceTemplates.swift app/macos/SpaceWeb.swift "$TEST_DIR/space-web-src/main.swift"
limit 300 env AI_ILLUMINATI_TEST_HOME="$TEST_DIR/space-web-home" "$TEST_DIR/space-web"
echo "[11/11] Icon check"
limit 300 xcrun swiftc -swift-version 5 -module-cache-path "$TEST_DIR/cache" -o "$TEST_DIR/icon-check" \
    app/macos/Icon.swift tools/tests/icon_animation.swift
limit 60 "$TEST_DIR/icon-check"
if [[ "$(real_accounts)" != "$REAL_BEFORE" ]]; then
  echo "FAIL: the real accounts.json changed during the tests" >&2
  exit 1
fi
echo "PASS: the real accounts.json is unchanged"
