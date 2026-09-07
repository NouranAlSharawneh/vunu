#!/bin/zsh
# Build a Release, zip it, and publish a GitHub release:  scripts/release.sh 0.1.0 "release notes"
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${1:?version required, e.g. 0.1.0}"
NOTES="${2:-Vunu $VERSION}"
cd "$ROOT"
sed -i '' "s/CFBundleShortVersionString: \".*\"/CFBundleShortVersionString: \"$VERSION\"/" project.yml
NO_INSTALL=1 "$ROOT/scripts/build.sh" Release
APP="$ROOT/build/DerivedData/Build/Products/Release/Vunu.app"
OUT="$ROOT/build/Vunu-$VERSION.zip"
rm -f "$OUT"
ditto -c -k --keepParent "$APP" "$OUT"
echo "→ $OUT ($(du -h "$OUT" | cut -f1))"
gh release create "v$VERSION" "$OUT" --title "Vunu $VERSION" --notes "$NOTES" --latest
echo "✓ Released v$VERSION"
