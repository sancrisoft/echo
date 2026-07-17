#!/usr/bin/env bash
#
# Installs (or updates) Echo from the latest GitHub release.
#
#   gh api -H "Accept: application/vnd.github.raw" repos/sancrisoft/echo/contents/scripts/install.sh | bash
#
# Install a specific version:
#
#   ... | bash -s v0.1.0
#
# Requires the GitHub CLI (gh) authenticated with access to sancrisoft/echo.
set -euo pipefail

REPO="sancrisoft/echo"
APP_PATH="/Applications/Echo.app"
TAG="${1:-}"

if ! command -v gh >/dev/null 2>&1; then
  echo "error: the GitHub CLI is required. Install it with: brew install gh" >&2
  exit 1
fi
if ! gh auth status >/dev/null 2>&1; then
  echo "error: gh is not authenticated. Run: gh auth login" >&2
  exit 1
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

if [ -n "$TAG" ]; then
  echo "Downloading Echo $TAG ..."
  gh release download "$TAG" --repo "$REPO" --pattern "*.zip" --dir "$TMP"
else
  echo "Downloading the latest Echo release ..."
  gh release download --repo "$REPO" --pattern "*.zip" --dir "$TMP"
fi

ZIP="$(find "$TMP" -name "*.zip" -print -quit)"
if [ -z "$ZIP" ]; then
  echo "error: no zip asset found in the release" >&2
  exit 1
fi

ditto -x -k "$ZIP" "$TMP/extracted"
APP_SRC="$TMP/extracted/Echo.app"
if [ ! -d "$APP_SRC" ]; then
  echo "error: Echo.app not found inside the release archive" >&2
  exit 1
fi

# Quit a running copy before replacing it.
osascript -e 'tell application "Echo" to quit' >/dev/null 2>&1 || true
pkill -x Echo >/dev/null 2>&1 || true
sleep 1

rm -rf "$APP_PATH"
ditto "$APP_SRC" "$APP_PATH"

# gh downloads are not quarantined, but clear the flag just in case.
xattr -dr com.apple.quarantine "$APP_PATH" 2>/dev/null || true

VERSION="$(defaults read "$APP_PATH/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null || echo "unknown")"
echo "Echo $VERSION installed at $APP_PATH"
