#!/bin/zsh
# One-time developer setup: git runs the module guards before each commit and push (.githooks).
# An existing core.hooksPath is someone's choice: it is reported, never overwritten.
set -eu
cd "${0:A:h}/.."
CURRENT=$(git config --get core.hooksPath || true)
if [[ -z $CURRENT ]]; then
  git config core.hooksPath .githooks
  echo "Installed: core.hooksPath = .githooks (pre-commit: fast module guards; pre-push: module test stages)"
elif [[ $CURRENT == .githooks ]]; then
  echo "Already installed: core.hooksPath = .githooks"
else
  echo "Not changed: core.hooksPath is already '$CURRENT'. To use the module hooks, call .githooks/pre-commit and" >&2
  echo ".githooks/pre-push from your hooks, or set it yourself: git config core.hooksPath .githooks" >&2
fi
