#!/bin/zsh
set -eu
cd "${0:A:h}/../.."
TEST_DIR=$(mktemp -d /tmp/ai-mode2-check.XXXXXX)
trap 'rm -rf "$TEST_DIR"' EXIT
python3 - "$TEST_DIR" <<'PY'
from pathlib import Path
import sys
root = Path(sys.argv[1])
s = Path('app/macos/Accounts.swift').read_text().replace(
    'static let home = FileManager.default.homeDirectoryForCurrentUser.path',
    'static let home = "' + str(root) + '/data"')
(root / 'Accounts.swift').write_text(s)
(root / 'main.swift').write_text(Path('tools/tests/mode2.swift').read_text())
PY
PYTHONDONTWRITEBYTECODE=1 python3 tools/tests/material_fixtures.py "$TEST_DIR/data/material-fixtures"
xcrun swiftc -swift-version 5 -module-cache-path "$TEST_DIR/cache" -o "$TEST_DIR/run" \
    app/macos/Language.swift app/macos/Usage.swift "$TEST_DIR/Accounts.swift" app/macos/Login.swift \
    app/macos/Settings.swift app/macos/Discussion.swift app/macos/Debate.swift app/macos/Attachments.swift app/macos/NativeSessions.swift app/macos/RoomDocuments.swift app/macos/MaterialReader.swift app/macos/Collaboration.swift "$TEST_DIR/main.swift"
"$TEST_DIR/run"
