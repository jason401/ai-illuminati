#!/bin/zsh
# O3 reproducible isolated repetitions and a deliberately broken bridge in a disposable copy.
set -eu
cd "${0:A:h}/../.."
VALIDATION_DIR=$(mktemp -d /tmp/ai-o3-validation.XXXXXX)
trap 'rm -rf "$VALIDATION_DIR"' EXIT
if [[ ${1-} == full ]]; then
  unset AI_ILLUMINATI_TEST_ONLY
  for ROUND in 1 2; do
    echo "[O3] full suite $ROUND/2"
    if ! zsh tools/tests/run_mode2.sh > "$VALIDATION_DIR/full.log" 2>&1; then
      tail -n 100 "$VALIDATION_DIR/full.log"; exit 1
    fi
    /usr/bin/grep -E '^  test[A-Za-z]+:|^  \[|^  total:|^PASS: (public API|module guards|G1|real accounts)' "$VALIDATION_DIR/full.log"
  done
  zsh tools/check_modules.sh
  echo "[O3] PASS: two full suites, including module checks"
  exit 0
fi
PYTHONDONTWRITEBYTECODE=1 python3 tools/tests/test_workspace_mcp.py
NAMES=(testProjectWork testProjectHandoff)
[[ ${1-} != work ]] || NAMES=(testProjectWork)
for NAME in $NAMES; do
  for ROUND in 1 2 3 4 5; do
    echo "[O3] $NAME alone $ROUND/5"
    if ! AI_ILLUMINATI_TEST_ONLY=$NAME zsh tools/tests/run_mode2.sh --affected app/resources/workspace_mcp.py > "$VALIDATION_DIR/run.log" 2>&1; then
      cat "$VALIDATION_DIR/run.log"; exit 1
    fi
    [[ $(/usr/bin/grep -c "^▶ " "$VALIDATION_DIR/run.log") == 1 ]] || { cat "$VALIDATION_DIR/run.log"; echo "FAIL: expected one named app test"; exit 1 }
    /usr/bin/grep -E "^  $NAME:|^  total:|PASS: real" "$VALIDATION_DIR/run.log" || { cat "$VALIDATION_DIR/run.log"; exit 1 }
  done
done
if [[ ${1-} == work ]]; then
  zsh tools/check_modules.sh
  echo "[O3] PASS: reviewed Stop wait, testProjectWork 5/5"
  exit 0
fi
echo "[O3] mutation: project_run incorrectly uses the ordinary socket limit"
python3 - "$VALIDATION_DIR/mutant" <<'PY'
import pathlib, shutil, sys
root = pathlib.Path.cwd()
dest = pathlib.Path(sys.argv[1])
shutil.copytree(root, dest, ignore=shutil.ignore_patterns('.git', 'dist', '.build', 'build', '*.app', '__pycache__', '.DS_Store'))
bridge = dest / 'app/resources/workspace_mcp.py'
text = bridge.read_text()
old = "('project_run', 'ask_ai', 'ask_peer', 'meeting_result', 'create_project')"
new = "('ask_ai', 'ask_peer', 'meeting_result', 'create_project')"
assert text.count(old) == 1
bridge.write_text(text.replace(old, new))
PY
(
  cd "$VALIDATION_DIR/mutant"
  AI_ILLUMINATI_TEST_ONLY=testProjectWork zsh tools/tests/run_mode2.sh --affected app/resources/workspace_mcp.py
) > "$VALIDATION_DIR/mutation.log" 2>&1 && { cat "$VALIDATION_DIR/mutation.log"; echo "FAIL: mutant survived"; exit 1 }
if ! /usr/bin/grep -E 'Fatal error: long project tool survives Python bridge timeout and approval' "$VALIDATION_DIR/mutation.log"; then
  cat "$VALIDATION_DIR/mutation.log"; echo "FAIL: mutant failed for an unrelated reason"; exit 1
fi
echo "[O3] PASS: optimized app test rejected the broken timeout; disposable copy removed on exit"
