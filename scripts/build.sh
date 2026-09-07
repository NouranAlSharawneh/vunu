#!/bin/zsh
# Build Vunu: xcodegen → xcodebuild → verify signature → copy to /Applications
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
CONFIG="${1:-Debug}"
DERIVED="$ROOT/build/DerivedData"
export XCODEGEN_QUIET=1
xcodegen generate --spec project.yml --quiet
LOG="$ROOT/build/xcodebuild.log"
if ! xcodebuild -project Vunu.xcodeproj -scheme Vunu -configuration "$CONFIG" \
  -derivedDataPath "$DERIVED" -destination 'platform=macOS,arch=arm64' ARCHS=arm64 ONLY_ACTIVE_ARCH=YES build > "$LOG" 2>&1; then
  grep -E "error:" "$LOG" | sort -u | head -20
  echo "BUILD FAILED (see $LOG)"; exit 1
fi
echo "BUILD SUCCEEDED"
APP="$DERIVED/Build/Products/$CONFIG/Vunu.app"
codesign --verify --deep --strict "$APP" && echo "signed by: $(codesign -dvv "$APP" 2>&1 | grep -E '^Authority=' | head -1 | cut -d= -f2)"
if [[ "${NO_INSTALL:-0}" != "1" ]]; then
  rm -rf /Applications/Vunu.app
  ditto "$APP" /Applications/Vunu.app
  echo "installed → /Applications/Vunu.app"
fi
