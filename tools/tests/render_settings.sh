#!/bin/zsh
set -eu
cd "${0:A:h}/../.."
PREVIEW_DIR=$(mktemp -d /tmp/ai-settings-render.XXXXXX)
trap 'rm -rf "$PREVIEW_DIR"' EXIT
OUTPUT_DIR="${1:-/tmp/ai-settings-previews}"
python3 - "$PREVIEW_DIR" <<'PY'
from pathlib import Path
import sys
root = Path(sys.argv[1])
s = Path('app/macos/Accounts.swift').read_text().replace(
    'static let home = FileManager.default.homeDirectoryForCurrentUser.path',
    'static let home = "' + str(root) + '/data"')
(root / 'Accounts.swift').write_text(s)
PY
SOURCES=()
for SOURCE in app/macos/*.swift; do
  [[ "$SOURCE" == app/macos/main.swift || "$SOURCE" == app/macos/Accounts.swift || "$SOURCE" == app/macos/PokerWindow.swift ]] && continue
  SOURCES+=("$SOURCE")
done
xcrun swiftc -swift-version 5 -target "$(uname -m)-apple-macos13.0" -module-cache-path "$PREVIEW_DIR/cache" -o "$PREVIEW_DIR/render" \
  "${SOURCES[@]}" "$PREVIEW_DIR/Accounts.swift" tools/tests/render_settings.swift
"$PREVIEW_DIR/render" "$OUTPUT_DIR"
