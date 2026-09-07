#!/bin/zsh
# Run VunuCore unit tests via SwiftPM (fast) — no Xcode project needed.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT/Packages/VunuCore"
swift test "$@" 2>&1 | grep -vE "^\[[0-9]+/[0-9]+\]|Compiling|Emitting|Linking|^Build complete" || true
