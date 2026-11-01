#!/bin/zsh
# Source installer shipped with the v0.2.0 release. Does not contain signing keys or account data.
set -eu
set -o pipefail
RELEASE_TAG='v0.2.0'
REPOSITORY='https://github.com/jason401/ai-illuminati.git'

finish() {
  local result=$?
  if (( result != 0 )); then
    print '\nInstallation stopped. Read the error above; no running app was intentionally replaced.'
  fi
  if [[ -t 0 ]]; then
    read -r '?Press Return to close this window. ' || true
  fi
}
trap finish EXIT

print "AI Illuminati ${RELEASE_TAG} — build on this Mac"
print 'First finish any active AI Illuminati work and quit the existing app.'
print 'This creates/reuses a local code-signing identity; approve macOS prompts yourself.'
print 'No password or API key is requested by this script.\n'

if ! /usr/bin/xcrun --find swiftc >/dev/null 2>&1; then
  print -u2 'Install Apple Command Line Tools first: xcode-select --install'
  exit 1
fi
/usr/bin/python3 --version >/dev/null
CACHE_ROOT="$HOME/Library/Caches/AI Illuminati"
mkdir -p "$CACHE_ROOT"
INSTALL_WORK=$(mktemp -d "$CACHE_ROOT/install.XXXXXX")
print "Source/build folder: $INSTALL_WORK/source"
# A fresh checkout keeps developer projects and existing account folders untouched.
/usr/bin/git clone --branch "$RELEASE_TAG" --single-branch "$REPOSITORY" "$INSTALL_WORK/source"
cd "$INSTALL_WORK/source"
/bin/zsh tools/setup_signing.sh
# A fresh source checkout also supports installations made before the public history cleanup.
/usr/bin/python3 tools/prepare_update_source.py
/bin/zsh tools/build_app.sh
print '\nCandidate opened. Let the app finish its first installation before removing the source folder.'
