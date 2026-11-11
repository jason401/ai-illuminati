#!/bin/zsh
# Builds each app module (app/modules/<Name>/*.swift) on its own into OUT as <Name>.swiftmodule + lib<Name>.a.
# Programs that use a module `import <Name>` and compile with: -I OUT OUT/lib<Name>.a
# A module sees only itself, and its users see only its `public` declarations.
# Use: zsh tools/build_modules.sh OUT [swiftc options, e.g. -O -target ... -module-cache-path ...]
set -eu
cd "${0:A:h}/.."
OUT=$1; shift
mkdir -p "$OUT"
for DIR in app/modules/*(/N); do
  NAME=${DIR:t}
  xcrun swiftc -swift-version 5 -parse-as-library -module-name "$NAME" -emit-module -emit-module-path "$OUT/$NAME.swiftmodule" \
    -emit-library -static -o "$OUT/lib$NAME.a" "$@" "$DIR"/*.swift
done
