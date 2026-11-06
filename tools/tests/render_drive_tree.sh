#!/bin/zsh
set -eu
cd "${0:A:h}/../.."
PREVIEW_DIR=$(mktemp -d /tmp/ai-drive-render.XXXXXX)
trap 'rm -rf "$PREVIEW_DIR"' EXIT
OUTPUT_DIR="${1:-/tmp/ai-drive-previews}"
python3 - "$PREVIEW_DIR" <<'PY'
from pathlib import Path
import sys
root = Path(sys.argv[1])
s = Path('app/macos/Accounts.swift').read_text().replace(
    'static let home = FileManager.default.homeDirectoryForCurrentUser.path',
    'static let home = "' + str(root) + '/data"')
(root / 'Accounts.swift').write_text(s)
(root / 'DriveUI.swift').write_text(Path('app/macos/DriveUI.swift').read_text().replace('private func row(_ item: DriveTreeItem)', 'func row(_ item: DriveTreeItem)'))
PY
SOURCES=()
for SOURCE in app/macos/*.swift; do
  [[ "$SOURCE" == app/macos/main.swift || "$SOURCE" == app/macos/Accounts.swift || "$SOURCE" == app/macos/PokerWindow.swift || "$SOURCE" == app/macos/DriveUI.swift ]] && continue
  SOURCES+=("$SOURCE")
done
xcrun swiftc -swift-version 5 -target "$(uname -m)-apple-macos13.0" -module-cache-path "$PREVIEW_DIR/cache" -o "$PREVIEW_DIR/render" \
  "${SOURCES[@]}" "$PREVIEW_DIR/Accounts.swift" "$PREVIEW_DIR/DriveUI.swift" tools/tests/render_drive_tree.swift
"$PREVIEW_DIR/render" "$OUTPUT_DIR"
