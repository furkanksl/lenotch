#!/bin/zsh
# Signs LeNotch update files for Sparkle. See tools/updates/main.swift for the commands.
# The signing keys live in the gitignored .release/keys directory.
set -euo pipefail
umask 077
cd "$(dirname "$0")/.."

BIN=.build/tools/lenotch-updates
if [[ ! -x $BIN || tools/updates/main.swift -nt $BIN ]]; then
  mkdir -p .build/tools
  swiftc -O -o "$BIN" tools/updates/main.swift
fi
exec "$BIN" "$@"
