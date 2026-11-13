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
# The runtime's one public test hook (a fake CLI for runtime_contract.swift) is never set by the app.
hooked = subprocess.run(['grep', '-rl', '--include=*.swift', 'toolForTests', 'app/macos'], capture_output=True, text=True).stdout.split()
assert hooked == [], hooked
# C0: every `extension Discussion` is classified in docs/MODULES.md ("Chat, step C0"): a = Chat takes it whole, b = a shell
# whose logic is another module's public function. A new block fails here until it gets its row (and the table).
import glob, re
expected = {'Attachments': 'aaa', 'ChatFind': 'a', 'ChatSearch': 'a', 'ChatTools': 'a', 'Collaboration': 'a', 'Debate': 'a',
            'DeviceSync': 'a', 'Enterprise': 'ab', 'Meeting': 'ba', 'Peer': 'b', 'ProjectChat': 'b', 'ProjectCreate': 'b',
            'RoomDocuments': 'a', 'Route': 'a', 'SidebarProjects': 'a', 'Solo': 'aa', 'SpaceView': 'b', 'TodoChatsApp': 'a', 'Vote': 'a'}
def blocks(text):
    lines, out, i = text.split('\n'), [], 0
    while i < len(lines):
        if lines[i].startswith('extension Discussion'):
            j = i
            while lines[j] != '}': j += 1
            out.append('\n'.join(lines[i:j + 1])); i = j
        i += 1
    return out
# C1: the blocks live in AIChat now (with Discussion's state); the app adds none (it sees only public names).
assert not [f for f in glob.glob('app/macos/*.swift') if blocks(Path(f).read_text())], 'the app has no extension Discussion (C1)'
found = {Path(f).stem: blocks(Path(f).read_text()) for f in sorted(glob.glob('app/modules/AIChat/*.swift'))}
found = {k: v for k, v in found.items() if v}
assert {k: len(v) for k, v in found.items()} == {k: len(v) for k, v in expected.items()}, ({k: len(v) for k, v in found.items()}, 'classify new extension Discussion blocks in docs/MODULES.md')
assert sum(len(v) for v in found.values()) == 24, 'the C0 table has 24 rows'
# The chat side calls none of these by name: the app connects them (ChatLinksApp.swift) or the module reads them.
direct = re.compile(r'PlanLink|DeviceSync\b(?!\.swift)|NativeSessions\.purgeRoom|WorkspaceBackup\.purgeRoom|RoomDocuments\.directory')
chat = Path('app/modules/AIChat/Discussion.swift').read_text()
hits = [m.group() for m in direct.finditer(chat)] + [(k, m.group()) for k, v in found.items() for b in v for m in direct.finditer(b)]
assert hits == [], hits
call, start = s.find('ChatLinksApp.connect()'), s.find('AppDelegate()')
assert 0 <= s.find('useRealHome()') < call < start and s.count('ChatLinksApp.connect()') == 1, 'main.swift connects the chat store once, before AppDelegate()'
screens = s.find('ChatScreensApp.connect()')
assert call < screens < start and s.count('ChatScreensApp.connect()') == 1, 'main.swift connects the chat window to the app screens once, before AppDelegate()'
# I: Integrations (Drive, outside MCP, AI Face) holds no tool provider: ToolHub's providers are the app's or a feature
# module's. Only the app imports it; it depends on lower modules only.
import os
integ = sorted(glob.glob('app/modules/AIIntegrations/*.swift'))
assert integ and not [f for f in integ if re.search(r'\bToolProvider\b|\bToolHub\b|\bToolContext\b', Path(f).read_text())], 'no tool provider in AIIntegrations'
assert Path('app/modules/AIIntegrations/dependencies').read_text().split() == ['AIAccounts', 'AILocalization', 'AIRuntime', 'AIWorkspace']
assert [f for f in glob.glob('app/modules/*/*.swift') if re.search(r'^import AIIntegrations', Path(f).read_text(), re.M)] == [], 'feature modules do not import AIIntegrations'
assert all(f'extension {n}: @retroactive ToolProvider' in Path('app/macos/' + f).read_text() for n, f in
           [('FaceLink', 'ToolHub.swift'), ('DriveLink', 'DriveTools.swift'), ('ExternalMCP', 'ExternalMCPTools.swift')]), 'the app makes the three providers'
# AI Face's link starts after the bridge's sockets (FaceLink no longer opens them itself).
assert s.find('ToolHub.shared.start()') < s.find('ToolHub.shared.startLegacyFaceSocket(at: FaceLink.socketPath)') < s.find('FaceLink.shared.start()')
# The 13 tool providers in their order (first(where:) picks by it): the app lists them, five are AIChat's since C1.
hub = Path('app/macos/ToolHub.swift').read_text()
order = re.search(r'private var providers: \[ToolProvider\] \{ \[(.*?)\] \}', hub).group(1).replace(' ', '').split(',')
assert order == ['FaceLink.shared', 'DriveLink.shared', 'GitLink.shared', 'PlanLink.shared', 'PeerLink.shared', 'ConveneLink.shared', 'ChatLink.shared',
                 'MemoryLink.shared', 'ProjectMakerLink.shared', 'TaskLink.shared', 'TodoAddLink.shared', 'StorageLink.shared', 'ExternalMCP.shared'], order
# App files see a module's public names only; @testable is for tests.
assert subprocess.run(['grep', '-rl', '@testable', 'app'], capture_output=True, text=True).stdout.split() == [], 'no @testable import in app files'
PY
echo "[2/11] Modules on their own"
# Each built alone (seeing only the modules it names), checked from outside with only its public API; reaching an
# internal name must not compile. -enable-testing only lets the module tests (space_build, space_web) say @testable;
# app files keep a plain import and see public names only.
MODULES="$TEST_DIR/modules"
limit 300 zsh tools/build_modules.sh "$MODULES" -enable-testing -module-cache-path "$TEST_DIR/cache"
for CONTRACT in accounts spaces runtime workspace integrations; do
  mkdir -p "$TEST_DIR/$CONTRACT-src" "$TEST_DIR/$CONTRACT-home"
  cp tools/tests/${CONTRACT}_contract.swift "$TEST_DIR/$CONTRACT-src/main.swift"
  limit 300 xcrun swiftc -swift-version 5 -module-cache-path "$TEST_DIR/cache" -I "$MODULES" -o "$TEST_DIR/$CONTRACT-contract" "$TEST_DIR/$CONTRACT-src/main.swift" "$MODULES"/lib*.a
  limit 120 env AI_ILLUMINATI_TEST_HOME="$TEST_DIR/$CONTRACT-home" "$TEST_DIR/$CONTRACT-contract"
done
# Projects runs its commands through project_process.py (the app's resources).
mkdir -p "$TEST_DIR/projects-src" "$TEST_DIR/projects-home"
cp tools/tests/projects_contract.swift "$TEST_DIR/projects-src/main.swift"
limit 300 xcrun swiftc -swift-version 5 -module-cache-path "$TEST_DIR/cache" -I "$MODULES" -o "$TEST_DIR/projects-contract" "$TEST_DIR/projects-src/main.swift" "$MODULES"/lib*.a
limit 120 env AI_ILLUMINATI_TEST_HOME="$TEST_DIR/projects-home" AI_ILLUMINATI_TEST_RESOURCES="$PWD/app/resources" "$TEST_DIR/projects-contract"
# Chat reads older chats (tools/tests/chat_fixtures) and saves them as the app did before the module.
mkdir -p "$TEST_DIR/chat-src" "$TEST_DIR/chat-home"
cp tools/tests/chat_contract.swift "$TEST_DIR/chat-src/main.swift"
limit 300 xcrun swiftc -swift-version 5 -module-cache-path "$TEST_DIR/cache" -I "$MODULES" -o "$TEST_DIR/chat-contract" "$TEST_DIR/chat-src/main.swift" "$MODULES"/lib*.a
limit 120 env AI_ILLUMINATI_TEST_HOME="$TEST_DIR/chat-home" CHAT_FIXTURES="$PWD/tools/tests/chat_fixtures" "$TEST_DIR/chat-contract"
boundary() {   # module, code that reaches one of its internal names, that name
  mkdir -p "$TEST_DIR/boundary-$1"
  printf 'import %s\n%s\n' "$1" "$2" > "$TEST_DIR/boundary-$1/main.swift"
  if limit 300 xcrun swiftc -swift-version 5 -typecheck -module-cache-path "$TEST_DIR/cache" -I "$MODULES" "$TEST_DIR/boundary-$1/main.swift" 2>"$TEST_DIR/boundary-$1.log" \
     || ! grep -q "'$3' is inaccessible due to 'internal' protection level" "$TEST_DIR/boundary-$1.log"; then
    cat "$TEST_DIR/boundary-$1.log" >&2
    echo "FAIL: code outside $1 reached its internal $3" >&2
    exit 1
  fi
}
boundary AIAccounts '_ = AccountStore.place' place
boundary AISpaces '_ = SpaceStore.setting' setting
boundary AISpaces '_ = SpaceAssets.served' served
boundary AIRuntime '_ = Answerer.chatDir' chatDir
boundary AIRuntime '_ = Answerer.launchForTests' launchForTests
boundary AIRuntime '_ = NativeSessions.split' split
boundary AIRuntime '_ = CloudModels.apply' apply
boundary AIWorkspace '_ = WorkspaceBackup.chats' chats
boundary AIWorkspace '_ = WorkspaceBackup.keepPerChat' keepPerChat
boundary AIProjects '_ = TodoScheduler.retryDelay' retryDelay
boundary AIProjects '_ = ProjectWork.leasePrefix' leasePrefix
boundary AIProjects '_ = TodoStore.encoder' encoder
boundary AIIntegrations '_ = FaceLink.fallbackMoods' fallbackMoods
boundary AIIntegrations '_ = GoogleAuth.tokenURL' tokenURL
boundary AIIntegrations '_ = DriveLink.shared.isAllowed' isAllowed
boundary AIIntegrations '_ = ExternalMCP.callTimeout' callTimeout
boundary AIChat '_ = ChatTime.calendar' calendar
boundary AIChat '_ = Discussion.maxRunning' maxRunning
boundary AIChat '_ = Discussion(model: Optional<any ChatSettings>.none!).draft' draft
# AutoGuard is internal and whole (the app's one way in is FullAutoGuard.environment): its shims and denied list stay inside.
printf 'import AIWorkspace\n_ = AutoGuard.claudeDenied\n' > "$TEST_DIR/boundary-AutoGuard.swift"
if limit 300 xcrun swiftc -swift-version 5 -typecheck -module-cache-path "$TEST_DIR/cache" -I "$MODULES" "$TEST_DIR/boundary-AutoGuard.swift" 2>"$TEST_DIR/boundary-AutoGuard.log" \
   || ! grep -q "cannot find 'AutoGuard' in scope" "$TEST_DIR/boundary-AutoGuard.log"; then
  cat "$TEST_DIR/boundary-AutoGuard.log" >&2; echo "FAIL: code outside AIWorkspace reached AutoGuard" >&2; exit 1
fi
# The chat's routing and ask_ai rules are internal types: the app reaches them only through the chat (C1).
printf 'import AIChat\n_ = Peer.maxAsks\n_ = Route.self\n' > "$TEST_DIR/boundary-Peer.swift"
if limit 300 xcrun swiftc -swift-version 5 -typecheck -module-cache-path "$TEST_DIR/cache" -I "$MODULES" "$TEST_DIR/boundary-Peer.swift" 2>"$TEST_DIR/boundary-Peer.log" \
   || ! grep -q "cannot find 'Peer' in scope" "$TEST_DIR/boundary-Peer.log" || ! grep -q "cannot find 'Route' in scope" "$TEST_DIR/boundary-Peer.log"; then
  cat "$TEST_DIR/boundary-Peer.log" >&2; echo "FAIL: code outside AIChat reached Peer or Route" >&2; exit 1
fi
echo "PASS: code outside the modules cannot reach their internal names"
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
limit 900 xcrun swiftc -swift-version 5 -module-cache-path "$TEST_DIR/cache" -I "$MODULES" -o "$TEST_DIR/run" "$MODULES"/lib*.a \
    app/macos/Login.swift \
    app/macos/Settings.swift app/macos/LocalModels.swift app/macos/ExternalMCPTools.swift app/macos/DriveUI.swift app/macos/ToolHub.swift app/macos/DriveTools.swift app/macos/RunConditionsApp.swift app/macos/Updater.swift app/macos/Poker.swift app/macos/ChatLinksApp.swift app/macos/GitBranches.swift tools/tests/space_build.swift tools/tests/google_drive.swift tools/tests/device_sync.swift tools/tests/window_drag.swift tools/tests/project_work.swift tools/tests/ask_ai.swift tools/tests/collab_log.swift tools/tests/meeting_tool.swift tools/tests/todo_work.swift tools/tests/project_info.swift tools/tests/update_channel.swift tools/tests/chat_search.swift tools/tests/search_fixtures.swift tools/tests/run_conditions.swift tools/tests/runtime_app.swift tools/tests/chat_links.swift tools/tests/chat_cli.swift "$TEST_DIR/main.swift"
echo "[9/11] Run app tests"
# The tests also stop themselves after 120 s without progress (mode2.swift) and name the test.
limit 1500 env AI_ILLUMINATI_TEST_HOME="$TEST_DIR/data" AI_ILLUMINATI_TEST_RESOURCES="$TEST_DIR/resources" "$TEST_DIR/run"
echo "[10/11] Space web view isolation"
mkdir -p "$TEST_DIR/space-web-src" "$TEST_DIR/space-web-home"
cp tools/tests/space_web.swift "$TEST_DIR/space-web-src/main.swift"
limit 600 xcrun swiftc -swift-version 5 -module-cache-path "$TEST_DIR/cache" -I "$MODULES" -o "$TEST_DIR/space-web" "$MODULES"/lib*.a \
    "$TEST_DIR/space-web-src/main.swift"
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
