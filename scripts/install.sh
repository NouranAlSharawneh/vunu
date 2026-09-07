#!/bin/zsh
# Install the latest Vunu release on this Mac:
#   curl -fsSL https://raw.githubusercontent.com/NouranAlSharawneh/vunu/main/scripts/install.sh | zsh
set -euo pipefail
REPO="NouranAlSharawneh/vunu"
TMP="$(mktemp -d)"
echo "→ Fetching latest release…"
URL="$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" | grep -o 'https://[^"]*Vunu[^"]*\.zip' | head -1)"
[[ -n "$URL" ]] || { echo "No release asset found."; exit 1; }
echo "→ Downloading $URL"
curl -fL --progress-bar "$URL" -o "$TMP/Vunu.zip"
echo "→ Installing to /Applications"
pkill -x Vunu 2>/dev/null || true
rm -rf /Applications/Vunu.app
ditto -x -k "$TMP/Vunu.zip" "$TMP/unzipped"
APP="$(find "$TMP/unzipped" -maxdepth 2 -name 'Vunu.app' | head -1)"
ditto "$APP" /Applications/Vunu.app
# The app is signed with a personal certificate, not notarized: clear quarantine so Gatekeeper lets it open.
xattr -dr com.apple.quarantine /Applications/Vunu.app 2>/dev/null || true
rm -rf "$TMP"
echo "✓ Installed. Opening Vunu — grant Microphone and Accessibility when asked."
open /Applications/Vunu.app
