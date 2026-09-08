#!/usr/bin/env bash
#
# Render the app's main window to PNGs for design review, against a data root
# of your choice (default: a copy of your real library without audio, so the
# real one is never touched).
#
#   scripts/snapshot.sh                      # every scene, default data root
#   scripts/snapshot.sh summary transcript   # only these scenes
#   ECHO_DATA_ROOT=/path scripts/snapshot.sh # a specific data root
#   ECHO_APPEARANCE=light scripts/snapshot.sh
#
# Output: build/snapshots/<scene>.png. Requires a Debug build (`make build`).
#
set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/Build/Products/Debug/Echo.app/Contents/MacOS/Echo"
[[ -x "$APP" ]] || { echo "build first: make build"; exit 1; }

OUT="build/snapshots"
mkdir -p "$OUT"

if [[ -z "${ECHO_DATA_ROOT:-}" ]]; then
  ECHO_DATA_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/echo-snapshot.XXXX")"
  REAL="$HOME/Library/Application Support/Echo/Meetings"
  if [[ -d "$REAL" ]]; then
    rsync -a --exclude='*.m4a' --exclude='.retention-staging' "$REAL/" "$ECHO_DATA_ROOT/Meetings/"
  fi
  echo "data root: $ECHO_DATA_ROOT (copy of the real library, no audio)"
fi
export ECHO_DATA_ROOT

scenes=("$@")
[[ ${#scenes[@]} -gt 0 ]] || scenes=(library summary transcript trash settings)

pkill -x Echo 2>/dev/null || true
for scene in "${scenes[@]}"; do
  png="$OUT/$scene.png"
  rm -f "$png"
  ECHO_OPEN_WINDOW=1 ECHO_SNAPSHOT_PATH="$png" ECHO_SNAPSHOT_SCENE="$scene" "$APP" >/dev/null 2>&1 &
  pid=$!
  for _ in $(seq 1 30); do
    [[ -f "$png" ]] && break
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.5
  done
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  if [[ -f "$png" ]]; then echo "wrote $png"; else echo "no snapshot for $scene"; fi
done
