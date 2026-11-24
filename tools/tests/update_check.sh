#!/bin/zsh
# The check before an update (Updater.swift), instead of the full run_mode2.sh. A version on main has passed the full
# test before its push; here only what an update cannot take back is checked again:
# - the module guards and the data folder rule (only the app opens the real data folder),
# - the installer (it swaps the app and puts the old one back when the new one does not start),
# - the saved data: accounts, chat records and chats saved by older builds are read and saved again as before.
# What comes after it covers the rest: build_app.sh --stage stops on a compile error, and install_app.py puts the
# old app back when the new one does not report its start. The timing tests of run_mode2 stage 9 stay out: they
# failed updates by chance under load (2026-11-24) and test features, not the update.
set -eu
cd "${0:A:h}/../.."
zmodload zsh/datetime zsh/system
TEST_DIR=$(mktemp -d /tmp/ai-update-check.XXXXXX)
REAL_ACCOUNTS="$HOME/Library/Application Support/AI Illuminati/accounts.json"
real_accounts() { [[ -f "$REAL_ACCOUNTS" ]] && shasum -a 256 "$REAL_ACCOUNTS" || echo missing }
REAL_BEFORE=$(real_accounts)
finish() {
  local rc=$1
  if [[ "$(real_accounts)" != "$REAL_BEFORE" ]]; then echo "FAIL: the real accounts.json changed during the check" >&2; (( rc )) || rc=1; fi
  rm -rf "$TEST_DIR"
  exit $rc
}
trap 'finish $?' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
T0=$EPOCHREALTIME
secs() { printf '%.1f' $(( EPOCHREALTIME - $1 )) }
# Each step with a time limit, so a stuck one names itself.
limit() { perl -e 'my $s = shift; alarm $s; exec @ARGV or die "exec: $!\n"' "$@" || { local rc=$?; (( rc != 142 )) || echo "FAIL: stopped: ${2:t}" >&2; exit $rc } }
J=(-j$(sysctl -n hw.ncpu))

echo "[1/3] Module guards and the data folder rule"
limit 60 zsh tools/check_modules.sh fast
PYTHONDONTWRITEBYTECODE=1 limit 60 python3 tools/tests/data_folder_rule.py
echo "[2/3] Installer tests"
PYTHONDONTWRITEBYTECODE=1 limit 600 python3 tools/tests/test_install_app.py
echo "[3/3] Saved data (accounts, chat records, chats)"
# The compiler cache run_mode2 keeps, under the same shared lock (a run_mode2 clearing it waits for this one).
CACHE="$HOME/Library/Caches/AI Illuminati/test-cache"
mkdir -p "$CACHE"; CACHE=${CACHE:A}; : >> "${CACHE:h}/test-cache.lock"
zsystem flock -r -f CACHE_FD "${CACHE:h}/test-cache.lock"
# Warnings off: the update bar shows the last line of output.
limit 600 zsh tools/build_modules.sh "$TEST_DIR/modules" $J -suppress-warnings -module-cache-path "$CACHE"
for NAME in accounts chatrecords chat; do
  mkdir -p "$TEST_DIR/$NAME-src" "$TEST_DIR/$NAME-home"
  cp tools/tests/${NAME}_contract.swift "$TEST_DIR/$NAME-src/main.swift"
  limit 300 xcrun swiftc -swift-version 5 $J -suppress-warnings -module-cache-path "$CACHE" -I "$TEST_DIR/modules" -o "$TEST_DIR/$NAME-contract" \
      "$TEST_DIR/$NAME-src/main.swift" "$TEST_DIR/modules"/lib*.a
  limit 120 env AI_ILLUMINATI_TEST_HOME="$TEST_DIR/$NAME-home" CHAT_FIXTURES="$PWD/tools/tests/chat_fixtures" "$TEST_DIR/$NAME-contract"
done
echo "PASS: update check ($(secs $T0) s; the full test is zsh tools/tests/run_mode2.sh)"
