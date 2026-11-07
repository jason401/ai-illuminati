#!/bin/zsh
set -eu
cd "${0:A:h}/../.."
PREVIEW_DIR=$(mktemp -d /tmp/ai-chat-render.XXXXXX)
trap 'rm -rf "$PREVIEW_DIR"' EXIT
OUTPUT_DIR="${1:-/tmp/ai-chat-previews}"
SOURCES=()
for SOURCE in app/macos/*.swift; do
  [[ "$SOURCE" == app/macos/main.swift || "$SOURCE" == app/macos/PokerWindow.swift ]] && continue
  SOURCES+=("$SOURCE")
done
xcrun swiftc -swift-version 5 -target "$(uname -m)-apple-macos13.0" -module-cache-path "$PREVIEW_DIR/cache" -o "$PREVIEW_DIR/render" \
  "${SOURCES[@]}" tools/tests/render_chat.swift
AI_ILLUMINATI_TEST_HOME="$PREVIEW_DIR/data" "$PREVIEW_DIR/render" "$OUTPUT_DIR" "${@:2}"
