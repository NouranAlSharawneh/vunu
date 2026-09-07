#!/bin/zsh
# Build Vunu: xcodegen → xcodebuild → verify signature → copy to /Applications
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
CONFIG="${1:-Debug}"
DERIVED="$ROOT/build/DerivedData"
export XCODEGEN_QUIET=1
xcodegen generate --spec project.yml --quiet
xcodebuild -project Vunu.xcodeproj -scheme Vunu -configuration "$CONFIG" \
  -derivedDataPath "$DERIVED" -destination 'platform=macOS,arch=arm64' \
  -quiet build 2>&1 | grep -E "error:|warning: (unre|dep)|BUILD" || true
APP="$DERIVED/Build/Products/$CONFIG/Vunu.app"
[[ -d "$APP" ]] || { echo "build failed: $APP missing"; exit 1; }
codesign --verify --deep --strict "$APP" && echo "signed: $(codesign -dv "$APP" 2>&1 | grep -E '^Authority=' | head -1)"
if [[ "${NO_INSTALL:-0}" != "1" ]]; then
  rm -rf /Applications/Vunu.app
  ditto "$APP" /Applications/Vunu.app
  echo "installed → /Applications/Vunu.app"
fi
