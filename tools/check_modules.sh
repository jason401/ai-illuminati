#!/bin/zsh
# Module guards (docs/MODULES.md "Rules"); a failing check means the code changes, not the check.
#   fast              G1-G7: graph, required files, App files, extensions (warning), @testable, documents, guard hashes.
#                     No compiler, a few seconds: the pre-commit hook and run_mode2 stage 1.
#   slow MODULES TMP  S1 public API snapshots, S2 boundary files, S3 App size, on modules built by build_modules.sh
#                     (run_mode2 stage 2).
#   snapshot          builds the modules and rewrites docs/api/<Module>.txt (after giving new public names their reason).
#   guard             prints tools/module_guard.sha256 for the current guard files (only with the user's approval).
set -eu
cd "${0:A:h}/.."
export PYTHONDONTWRITEBYTECODE=1
case ${1:-fast} in
  fast) RC=0; python3 tools/check_module_dependencies.py || RC=1; python3 tools/check_modules.py fast || RC=1; exit $RC ;;
  slow) python3 tools/check_modules.py slow "${2:a}" "${3:a}" ;;
  snapshot)
    TMP=$(mktemp -d /tmp/ai-modules-snapshot.XXXXXX); trap 'rm -rf "$TMP"' EXIT
    zsh tools/build_modules.sh "$TMP/modules" -enable-testing -module-cache-path "$TMP/cache"
    python3 tools/check_modules.py snapshot "$TMP/modules" "$TMP" ;;
  guard) python3 tools/check_modules.py guard ;;
  *) echo "use: zsh tools/check_modules.sh fast | slow MODULES TMP | snapshot | guard" >&2; exit 2 ;;
esac
