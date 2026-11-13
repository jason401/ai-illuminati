#!/bin/zsh
set -eu
cd "${0:A:h}/../.."
PREVIEW_DIR=$(mktemp -d /tmp/ai-chat-render.XXXXXX)
trap 'rm -rf "$PREVIEW_DIR"' EXIT
OUTPUT_DIR="${1:-/tmp/ai-chat-previews}"
SOURCES=()
for SOURCE in app/macos/*.swift; do
  [[ "$SOURCE" == app/macos/main.swift ]] && continue
  SOURCES+=("$SOURCE")
done
zsh tools/build_modules.sh "$PREVIEW_DIR/modules" -enable-testing -target "$(uname -m)-apple-macos13.0" -module-cache-path "$PREVIEW_DIR/cache"
xcrun swiftc -swift-version 5 -target "$(uname -m)-apple-macos13.0" -module-cache-path "$PREVIEW_DIR/cache" -I "$PREVIEW_DIR/modules" -o "$PREVIEW_DIR/render" \
  "$PREVIEW_DIR/modules"/lib*.a "${SOURCES[@]}" tools/tests/render_chat.swift tools/tests/search_fixtures.swift
AI_ILLUMINATI_TEST_HOME="$PREVIEW_DIR/data" "$PREVIEW_DIR/render" "$OUTPUT_DIR" "${@:2}"
