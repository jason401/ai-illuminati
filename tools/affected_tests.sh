#!/bin/zsh
# Which tests changed paths need (tools/test_map.txt; docs/MODULES.md "Which tests a change needs").
#   zsh tools/affected_tests.sh <paths from the project root, as `git diff --name-only` prints them>
# Prints `ALL <reason>` (run the full test), or lines `contract <Module>`, `test <runTest name>`, `stage space_web`.
# Paths not in the map, guard devices, shared code and a map that does not match docs/MODULES.md give ALL.
set -eu
export PYTHONDONTWRITEBYTECODE=1
exec python3 "${0:A:h}/affected_tests.py" pick "$@"
