#!/bin/zsh
set -eu
cd "${0:A:h}/../.."
ARGS=("$@")
# --affected <changed paths>: only the contract tests, app tests, stage 10 and stage 11 that the paths pick
# (all of them when it says ALL). Guards, builds, the checks outside runTest and the other stages always run.
# Stage 11 (screens) runs when a path is an app file (it compiles them all), AIProjects (the TODO card shows its
# TodoItem) or the screens test itself; affected_tests.py (G7) does not know stage 11, so the choice is made here.
SELECT=0 CONTRACTS=() TESTS=() SPACE_WEB=0 SCREENS=0
if [[ ${1-} == --affected ]]; then
  shift; (( $# )) || { echo "use: zsh tools/tests/run_mode2.sh --affected <paths from the project root>" >&2; exit 2 }
  PICKED=$(zsh tools/affected_tests.sh "$@")
  # Paths as affected_tests.py reads them: real path, relative to the project root (absolute and ./ forms too).
  for P in "$@"; do [[ ${P:A} == "${PWD:A}"/(app/macos/*|app/modules/AIProjects/*|tools/tests/screens_idle.swift) ]] && SCREENS=1; done
  shift $#
  if [[ $PICKED == ALL* ]]; then
    echo "Affected: every test (${PICKED#ALL })"
  else
    SELECT=1
    for KIND NAME in ${=PICKED}; do
      case $KIND in contract) CONTRACTS+=($NAME) ;; test) TESTS+=($NAME) ;; stage) SPACE_WEB=1 ;; *) echo "FAIL: $KIND $NAME" >&2; exit 1 ;; esac
    done
    echo "Affected: contracts ${CONTRACTS[*]:-none}; app tests ${TESTS[*]:-none}; space web $(( SPACE_WEB ? 1 : 0 )); screens $SCREENS"
  fi
fi
# Every swiftc splits its work over all CPUs: without -j it ran few jobs at once (docs/modules-followup.md "O4", "O5-A").
J=(-j$(sysctl -n hw.ncpu))
TEST_DIR=$(mktemp -d /tmp/ai-mode2-check.XXXXXX)
LATE_PID=
# Stages 10-12 run beside 8-9 (late_start below); a failed or stopped run stops them first. Ctrl-C and TERM exit
# through the EXIT trap (zsh skips it when a signal kills it).
late_stop() { [[ -n $LATE_PID ]] || return 0; kill -TERM -$LATE_PID 2>/dev/null || true; wait $LATE_PID 2>/dev/null || true; LATE_PID= }
# A failed, timed out or stopped run keeps its evidence outside $TEST_DIR (never in the real data folders): the stage,
# exit code, the last app test started, stage 9's output and late.log. The newest 10 stay; a passing run keeps nothing.
# The app's Stop (SIGKILL) skips every trap, so it leaves none.
FAIL_ROOT="$HOME/Library/Logs/AI Illuminati/test-failures" FAIL_KEEP=10
save_failure() {
  local rc=$1 dir old
  (( rc )) || return 0
  dir="$FAIL_ROOT/$(date +%Y%m%d-%H%M%S)-$$"
  mkdir -p "$dir" || return 0
  for f in app-tests.log late.log; do [[ -f "$TEST_DIR/$f" ]] && cp "$TEST_DIR/$f" "$dir/"; done
  { echo "exit: $rc"
    echo "stage: ${STAGE:-none}"
    [[ -f "$dir/late.log" ]] && echo "late stage: $(grep '^\[1[0-2]/12\]' "$dir/late.log" | tail -1)"
    [[ -f "$dir/app-tests.log" ]] && echo "last app test started: ${$(grep '^▶ ' "$dir/app-tests.log" | tail -1):-none}"
    echo "args: ${ARGS[*]:-}"
    echo "head: $(git rev-parse --short HEAD 2>/dev/null)$( [[ -n $(git status --porcelain 2>/dev/null) ]] && echo ' (changed files)')"
  } > "$dir/summary.txt"
  old=("$FAIL_ROOT"/<->-<->-<->(/On))   # newest first: the names start with the time
  (( ${#old} > FAIL_KEEP )) && rm -rf -- "${old[@]:$FAIL_KEEP}"
  echo "failure log: $dir" >&2
}
# The real account list must come out of the tests exactly as it went in, so every exit checks it: a pass, a failed
# or timed out stage, Ctrl-C/TERM and --modules. A changed file adds its FAIL; a passing run then fails (exit 1), a
# failing one keeps its own exit code. The app's Stop (SIGKILL) skips the trap, so a stopped run is not checked.
REAL_ACCOUNTS="$HOME/Library/Application Support/AI Illuminati/accounts.json"
real_accounts() { [[ -f "$REAL_ACCOUNTS" ]] && shasum -a 256 "$REAL_ACCOUNTS" || echo missing }
REAL_BEFORE=$(real_accounts)
accounts_check() {
  [[ "$(real_accounts)" != "$REAL_BEFORE" ]] || { (( $1 )) && echo "the real accounts.json is unchanged" >&2 || echo "PASS: the real accounts.json is unchanged"; return 0 }
  echo "FAIL: the real accounts.json changed during the tests" >&2
  (( $1 )) && STAGE="${STAGE:-none}; the real accounts.json changed" || STAGE="the real accounts.json check"
  return 1
}
trap 'RC=$?; late_stop; accounts_check $RC || (( RC )) || RC=1; save_failure $RC; rm -rf "$TEST_DIR"; exit $RC' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
# Compiler module cache (the SDK's clang modules: Foundation, AppKit, SwiftUI, …) kept between runs; homes, data and
# built programs stay in $TEST_DIR. One real path (:A) for every compiler: a moved, copied or differently spelled
# cache (/tmp vs /private/tmp) breaks. Clang locks each module, so several runs at once may share it; clearing it
# does not take clang's locks, so every run holds a shared lock on test-cache.lock for its whole run and clearing
# needs the exclusive one (not waited for: with another run going, the cache stays until a later run).
# AI_ILLUMINATI_TEST_CACHE=fresh: an empty cache inside $TEST_DIR, as before (when the cache is suspected).
if [[ ${AI_ILLUMINATI_TEST_CACHE-} == fresh ]]; then
  CACHE="${TEST_DIR:A}/cache"; echo "test cache: fresh"
else
  CACHE="$HOME/Library/Caches/AI Illuminati/test-cache"
  mkdir -p "$CACHE"; CACHE=${CACHE:A} CACHE_LOCK="${CACHE:h}/test-cache.lock"
  : >> "$CACHE_LOCK"; zmodload zsh/system
  cache_full() { (( $(du -sk "$CACHE" | cut -f1) > 2 * 1024 * 1024 )) }
  if cache_full; then
    if zsystem flock -t 0 -f CACHE_FD "$CACHE_LOCK" 2>/dev/null; then
      # Measured again under the lock: another run may have just cleared it. Moved into $TEST_DIR (same disk) and
      # deleted with it: an AI's rm would put 2 GB in the Trash.
      if cache_full; then mv "$CACHE" "$TEST_DIR/old-cache"; mkdir -p "$CACHE"; echo "test cache over 2 GB: cleared"; fi
      zsystem flock -u $CACHE_FD
    else
      echo "test cache over 2 GB: another test run is using it, kept this time"
    fi
  fi
  zsystem flock -r -f CACHE_FD "$CACHE_LOCK"   # shared, held until this script ends
fi
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
  # A failed stage ends the run here: zsh 5.9 skips the EXIT trap (late_stop, rm $TEST_DIR) when set -e stops the
  # script at a function's failure, but runs it on exit.
  exit $rc
}
# "[n/m] name" before each stage: the app shows it under the current step (project_run). When a stage ends,
# "  [n] name: x.x s" (its parts indented under it), and the whole run's time at the end: where the time goes.
zmodload zsh/datetime
RUN_T0=$EPOCHREALTIME STAGE= STAGE_T0=
secs() { printf '%.1f' $(( EPOCHREALTIME - $1 )) }
stage_end() { [[ -n $STAGE ]] && echo "  [${${STAGE#\[}%%/*}] ${STAGE#*\] }: $(secs $STAGE_T0) s"; STAGE= }
stage() { stage_end; STAGE=$1 STAGE_T0=$EPOCHREALTIME; echo "$1" }
part() { echo "    $1: $(secs $2) s${3:+ $3}" }
stage "[1/12] Module guards and the data folder rule"
# >>> module checks (hashed in tools/module_guard.sha256: changing them needs the user's approval)
limit 60 zsh tools/check_modules.sh fast
PYTHONDONTWRITEBYTECODE=1 limit 60 python3 tools/tests/test_module_dependencies.py
# <<< module checks
# The hooks run the same checks before each commit and push; they are installed once by tools/setup_dev.sh.
[[ "$(git config --get core.hooksPath 2>/dev/null)" == .githooks ]] || echo "WARN: git hooks are not installed: zsh tools/setup_dev.sh" >&2
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
# C0: every `extension Discussion` is classified in docs/modules-history.md ("Chat, step C0"): a = Chat takes it whole, b = a shell
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
order = re.search(r'static var appProviders: \[ToolProvider\] \{ \[(.*?)\] \}', hub).group(1).replace(' ', '').split(',')
assert order == ['FaceLink.shared', 'DriveLink.shared', 'GitLink.shared', 'PlanLink.shared', 'PeerLink.shared', 'ConveneLink.shared', 'ChatLink.shared',
                 'MemoryLink.shared', 'ProjectMakerLink.shared', 'TaskLink.shared', 'TodoAddLink.shared', 'StorageLink.shared', 'ExternalMCP.shared'], order
# App files see a module's public names only; @testable is for tests.
assert subprocess.run(['grep', '-rl', '@testable', 'app'], capture_output=True, text=True).stdout.split() == [], 'no @testable import in app files'
PY
stage "[2/12] Modules on their own"
# >>> module checks (hashed in tools/module_guard.sha256: changing them needs the user's approval)
# Each built alone (seeing only the modules it names), checked from outside with only its public API; reaching an
# internal name must not compile. -enable-testing only lets the module tests (space_build, space_web) say @testable;
# app files keep a plain import and see public names only.
MODULES="$TEST_DIR/modules"
PART_T0=$EPOCHREALTIME
limit 300 zsh tools/build_modules.sh "$MODULES" $J -enable-testing -module-cache-path "$CACHE"
part "build_modules.sh" $PART_T0
# Every module folder's contract test (tools/tests/<name>_contract.swift, AIFoo -> foo): found here, not listed by hand.
for DIR in app/modules/*(/N); do
  NAME=${(L)${DIR:t}#AI}; SRC=tools/tests/${NAME}_contract.swift
  # --affected: only the picked modules' contracts (the build above, the file checks and S1-S3 below stay).
  if (( SELECT && ! ${CONTRACTS[(Ie)${DIR:t}]} )) && [[ -f $SRC ]]; then echo "skip: ${DIR:t} contract (not affected)"; continue; fi
  [[ -f $SRC ]] || { echo "FAIL: ${DIR:t} has no contract test $SRC" >&2; exit 1 }
  RUN_ENV=(AI_ILLUMINATI_TEST_HOME="$TEST_DIR/$NAME-home")
  # Projects runs its commands through project_process.py (the app's resources); Chat reads older chats
  # (tools/tests/chat_fixtures) and saves them as the app did before the module.
  grep -q '^// contract needs: app resources' $SRC && RUN_ENV+=(AI_ILLUMINATI_TEST_RESOURCES="$PWD/app/resources")
  grep -q '^// contract needs: chat fixtures' $SRC && RUN_ENV+=(CHAT_FIXTURES="$PWD/tools/tests/chat_fixtures")
  mkdir -p "$TEST_DIR/$NAME-src" "$TEST_DIR/$NAME-home"
  cp $SRC "$TEST_DIR/$NAME-src/main.swift"
  PART_T0=$EPOCHREALTIME
  limit 300 xcrun swiftc -swift-version 5 $J -module-cache-path "$CACHE" -I "$MODULES" -o "$TEST_DIR/$NAME-contract" "$TEST_DIR/$NAME-src/main.swift" "$MODULES"/lib*.a
  COMPILED_AT=$EPOCHREALTIME
  limit 120 env $RUN_ENV "$TEST_DIR/$NAME-contract"
  part "${DIR:t} contract" $PART_T0 "(compile $(printf '%.1f' $(( COMPILED_AT - PART_T0 ))) s)"
done
# S1 public API snapshots (docs/api), S2 each module's boundary file, S3 App size.
PART_T0=$EPOCHREALTIME
limit 900 zsh tools/check_modules.sh slow "$MODULES" "$TEST_DIR" "$CACHE"
part "S1-S3 (check_modules.sh slow)" $PART_T0
# <<< module checks
[[ ${1-} == --modules ]] && { stage_end; echo "PASS: module stages (1-2) only"; exit 0 }
stage "[3/12] Real data folder check"
mkdir -p "$TEST_DIR/real-home-src" && cp tools/tests/real_home.swift "$TEST_DIR/real-home-src/main.swift"
limit 300 xcrun swiftc -swift-version 5 $J -module-cache-path "$CACHE" -I "$MODULES" -o "$TEST_DIR/real-home" "$TEST_DIR/real-home-src/main.swift" "$MODULES/libAIAccounts.a"
limit 60 "$TEST_DIR/real-home"
stage "[4/12] Build WorkspaceDocument"
mkdir -p "$TEST_DIR/resources"
cp app/resources/workspace_mcp.py app/resources/project_process.py app/resources/local_models.json "$TEST_DIR/resources/"
limit 300 xcrun swiftc -swift-version 5 $J -module-cache-path "$CACHE" -o "$TEST_DIR/resources/WorkspaceDocument" tools/workspace_document.swift
stage "[5/12] Installer tests"
PYTHONDONTWRITEBYTECODE=1 limit 600 python3 tools/tests/test_install_app.py
stage "[6/12] Workspace MCP tests"
PYTHONDONTWRITEBYTECODE=1 limit 600 python3 tools/tests/test_workspace_mcp.py
stage "[7/12] Material fixtures"
PYTHONDONTWRITEBYTECODE=1 limit 300 python3 tools/tests/material_fixtures.py "$TEST_DIR/data/material-fixtures"
# Stages 10-12 need only the modules (stage 2), so they run beside 8-9 (about 24 s less; docs/modules-followup.md
# "O4"). One background job in its own process group writes to late.log, shown after stage 9: its stage lines
# reach the app's progress (RunProgress) in order. Keep it all above stage 8's line: affected_tests.py reads stage
# 8's files from the stage 8 marker to the stage 9 marker (both quoted). The perl leader stops the group (each
# stage's limit stops its own) when run_mode2 asks (late_stop) or is gone: the app stops a run with SIGKILL.
late_stages() {
  stage "[10/12] Space web view isolation"
  if (( SELECT && ! SPACE_WEB )); then
    echo "skip: space web view (not affected)"
  else
    mkdir -p "$TEST_DIR/space-web-src" "$TEST_DIR/space-web-home"
    cp tools/tests/space_web.swift "$TEST_DIR/space-web-src/main.swift"
    limit 600 xcrun swiftc -swift-version 5 $J -module-cache-path "$CACHE" -I "$MODULES" -o "$TEST_DIR/space-web" "$MODULES"/lib*.a \
        "$TEST_DIR/space-web-src/main.swift"
    limit 300 env AI_ILLUMINATI_TEST_HOME="$TEST_DIR/space-web-home" "$TEST_DIR/space-web"
  fi
  stage "[11/12] Screens stay still"
  if (( SELECT && ! SCREENS )); then
    echo "skip: screens (not affected)"
  else
    mkdir -p "$TEST_DIR/screens-src" "$TEST_DIR/screens-home"
    cp tools/tests/screens_idle.swift "$TEST_DIR/screens-src/screens_idle.swift"
    SCREEN_SOURCES=(${(f)"$(ls app/macos/*.swift | grep -v '^app/macos/main.swift$')"})
    limit 900 xcrun swiftc -swift-version 5 $J -module-cache-path "$CACHE" -I "$MODULES" -o "$TEST_DIR/screens" "$MODULES"/lib*.a \
        "${SCREEN_SOURCES[@]}" "$TEST_DIR/screens-src/screens_idle.swift"
    limit 60 env AI_ILLUMINATI_TEST_HOME="$TEST_DIR/screens-home" "$TEST_DIR/screens"
  fi
  stage "[12/12] Icon check"
  limit 300 xcrun swiftc -swift-version 5 $J -module-cache-path "$CACHE" -o "$TEST_DIR/icon-check" \
      app/macos/Icon.swift tools/tests/icon_animation.swift
  limit 60 "$TEST_DIR/icon-check"
  stage_end
}
late_start() {
  perl -e '
    use POSIX ":sys_wait_h";
    my $main = shift; setpgrp(0, 0);   # run_mode2 names itself: read later, getppid could already be launchd
    my $pid = fork // die "fork: $!\n";
    if (!$pid) { exec @ARGV or die "exec: $!\n" }
    sub stop { $SIG{TERM} = "IGNORE"; kill "TERM", -$$; sleep 2; kill "KILL", -$$ }
    $SIG{TERM} = \&stop; $SIG{INT} = "IGNORE";
    while (1) {
      if (waitpid($pid, WNOHANG) == $pid) { exit($? & 127 ? 128 + ($? & 127) : $? >> 8) }
      stop() if getppid() != $main;
      select(undef, undef, undef, 0.2);
    }
  ' $$ zsh -fc "set -eu; zmodload zsh/datetime; $(typeset -p TEST_DIR CACHE MODULES SELECT SPACE_WEB SCREENS J)
    $(typeset -f limit secs stage_end stage part late_stages); STAGE= STAGE_T0=; late_stages" \
    > "$TEST_DIR/late.log" 2>&1 < /dev/null &
  LATE_PID=$!
}
late_start
stage "[8/12] Compile app tests"
limit 900 xcrun swiftc -swift-version 5 $J -module-cache-path "$CACHE" -I "$MODULES" -o "$TEST_DIR/run" "$MODULES"/lib*.a \
    app/macos/Login.swift \
    app/macos/Settings.swift app/macos/LocalModels.swift app/macos/ExternalMCPTools.swift app/macos/DriveUI.swift app/macos/ToolHub.swift app/macos/DriveTools.swift app/macos/RunConditionsApp.swift app/macos/Updater.swift app/macos/ChatLinksApp.swift app/macos/GitBranches.swift tools/tests/space_build.swift tools/tests/google_drive.swift tools/tests/device_sync.swift tools/tests/window_drag.swift tools/tests/project_work.swift tools/tests/ask_ai.swift tools/tests/collab_log.swift tools/tests/meeting_tool.swift tools/tests/todo_work.swift tools/tests/project_info.swift tools/tests/update_channel.swift tools/tests/chat_search.swift tools/tests/search_fixtures.swift tools/tests/run_conditions.swift tools/tests/runtime_app.swift tools/tests/chat_links.swift tools/tests/chat_cli.swift tools/tests/tool_hub.swift "$TEST_DIR/main.swift"
stage "[9/12] Run app tests"
# The tests also stop themselves after 120 s without progress (mode2.swift) and name the test.
APP_ENV=(AI_ILLUMINATI_TEST_HOME="$TEST_DIR/data" AI_ILLUMINATI_TEST_RESOURCES="$TEST_DIR/resources")
# --affected: the picked runTest names, comma-separated; "-" when none (the checks outside runTest still run).
if (( SELECT )); then ONLY=${(j:,:)TESTS}; APP_ENV+=(AI_ILLUMINATI_TEST_ONLY="${ONLY:--}"); fi
# Its output also goes to app-tests.log for the failure log: limit runs in the pipe's subshell, so its exit code is
# taken from pipestatus (the subshell runs no EXIT trap).
limit 1500 env $APP_ENV "$TEST_DIR/run" 2>&1 | tee "$TEST_DIR/app-tests.log"
APP_RC=${pipestatus[1]}
(( APP_RC == 0 )) || exit $APP_RC
stage_end
LATE_T0=$EPOCHREALTIME LATE_RC=0
wait $LATE_PID || LATE_RC=$?
LATE_PID=
cat "$TEST_DIR/late.log"
echo "  [10-12] waited after stage 9: $(secs $LATE_T0) s"
if (( LATE_RC )); then
  STAGE="$(grep '^\[1[0-2]/12\]' "$TEST_DIR/late.log" | tail -1) (stages 10-12 beside 8-9, exit $LATE_RC)"
  echo "FAIL: $STAGE" >&2
  exit 1
fi
stage_end
# What the compiler module cache holds at the end (over 2 GB, the next run clears it).
echo "  test cache: $(du -sh "$CACHE" | cut -f1)"
echo "  total: $(secs $RUN_T0) s"
if (( SELECT )); then echo "PASS: affected tests only; the full test is zsh tools/tests/run_mode2.sh"; fi
