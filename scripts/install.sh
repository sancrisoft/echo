#!/usr/bin/env bash
#
# Installs (or updates) Echo from the latest GitHub release.
#
# With the GitHub CLI (recommended):
#
#   gh api -H "Accept: application/vnd.github.raw" repos/sancrisoft/echo/contents/scripts/install.sh | bash
#
# With curl and a personal access token (no gh required):
#
#   export GITHUB_TOKEN=github_pat_...
#   curl -fsSL -H "Authorization: Bearer $GITHUB_TOKEN" -H "Accept: application/vnd.github.raw" \
#     https://api.github.com/repos/sancrisoft/echo/contents/scripts/install.sh | bash
#
# Install a specific version by appending the tag:
#
#   ... | bash -s v0.0.1
set -euo pipefail

REPO="sancrisoft/echo"
API="https://api.github.com/repos/$REPO"
APP_PATH="/Applications/Echo.app"
TAG="${1:-}"

USE_GH=false
if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
  USE_GH=true
elif [ -z "${GITHUB_TOKEN:-}" ]; then
  echo "error: no GitHub credentials found. Either:" >&2
  echo "  - install and authenticate the GitHub CLI:  brew install gh && gh auth login" >&2
  echo "  - or export GITHUB_TOKEN with a personal access token that can read $REPO" >&2
  exit 1
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

if [ -n "$TAG" ]; then
  echo "Downloading Echo $TAG ..."
else
  echo "Downloading the latest Echo release ..."
fi

if $USE_GH; then
  if [ -n "$TAG" ]; then
    gh release download "$TAG" --repo "$REPO" --pattern "*.zip" --dir "$TMP"
  else
    gh release download --repo "$REPO" --pattern "*.zip" --dir "$TMP"
  fi
else
  if [ -n "$TAG" ]; then
    RELEASE_URL="$API/releases/tags/$TAG"
  else
    RELEASE_URL="$API/releases/latest"
  fi
  RELEASE_JSON="$(curl -fsSL \
    -H "Authorization: Bearer $GITHUB_TOKEN" \
    -H "Accept: application/vnd.github+json" \
    "$RELEASE_URL")"
  # Private-repo assets can only be fetched through the API by asset id;
  # parse it with JXA so the script has no dependencies beyond curl.
  ASSET_ID="$(osascript -l JavaScript \
    -e 'function run(argv) {' \
    -e '  const release = JSON.parse(argv[0])' \
    -e '  const zip = (release.assets || []).find(a => a.name.endsWith(".zip"))' \
    -e '  return zip ? String(zip.id) : ""' \
    -e '}' \
    "$RELEASE_JSON")"
  if [ -z "$ASSET_ID" ]; then
    echo "error: no zip asset found in the release" >&2
    exit 1
  fi
  curl -fSL \
    -H "Authorization: Bearer $GITHUB_TOKEN" \
    -H "Accept: application/octet-stream" \
    -o "$TMP/Echo.zip" \
    "$API/releases/assets/$ASSET_ID"
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

# gh/curl downloads are not quarantined, but clear the flag just in case.
xattr -dr com.apple.quarantine "$APP_PATH" 2>/dev/null || true

VERSION="$(defaults read "$APP_PATH/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null || echo "unknown")"
echo "Echo $VERSION installed at $APP_PATH"
