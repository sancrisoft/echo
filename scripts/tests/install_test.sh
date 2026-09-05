#!/usr/bin/env bash
#
# Tests for scripts/install.sh — plain bash, no framework.
#
#   bash scripts/tests/install_test.sh
#
# The script is sourced (its `main` sits behind a guard for exactly this) and
# every function under test runs in a subshell with the script's own shell
# options, so a `die` ends that one test instead of the runner. HOME, TMPDIR
# and ECHO_INSTALL_DEST point into a scratch folder: nothing here can see, let
# alone touch, a real Echo or its data.
#
# Prints the failures and a one-line summary; exits non-zero on any failure.

SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/echo-install-test.XXXXXX")"
trap 'rm -rf "$SCRATCH"' EXIT

export HOME="$SCRATCH/home"
export TMPDIR="$SCRATCH/tmp"
export ECHO_INSTALL_DEST="$SCRATCH/Applications/Echo.app"
unset ECHO_INSTALL_REPO
mkdir -p "$HOME" "$TMPDIR" "$SCRATCH/Applications"

# shellcheck source-path=SCRIPTDIR
# shellcheck source=../install.sh
. "$(dirname "$0")/../install.sh"
# The script turns on -euo pipefail for itself; the runner has to keep going
# after a failed assertion. `run` and `parsed` turn them back on per test.
set +e +u
set +o pipefail

# --- harness ------------------------------------------------------------------

PASSED=0
FAILED=0

pass() { PASSED=$((PASSED + 1)); }

fail() {  # $1 what went wrong, then detail lines
  FAILED=$((FAILED + 1))
  printf 'FAIL: %s\n' "$1" >&2
  shift
  [ $# -eq 0 ] || printf '      %s\n' "$@" >&2
}

assert_eq() {  # $1 what, $2 expected, $3 actual
  if [ "$2" = "$3" ]; then pass; else fail "$1" "expected: $2" "  actual: $3"; fi
}

assert_contains() {  # $1 what, $2 text, $3 needle
  case "$2" in
    *"$3"*) pass ;;
    *) fail "$1" "expected to find: $3" "in: $2" ;;
  esac
}

assert_not_contains() {  # $1 what, $2 text, $3 needle
  case "$2" in
    *"$3"*) fail "$1" "did not expect to find: $3" "in: $2" ;;
    *) pass ;;
  esac
}

assert_exists()  { if [ -e "$2" ]; then pass; else fail "$1" "missing: $2"; fi; }
assert_missing() { if [ ! -e "$2" ]; then pass; else fail "$1" "exists: $2"; fi; }

# Checks the exit status of the last `run`.
assert_status() {  # $1 what, $2 expected status
  if [ "$STATUS" -eq "$2" ]; then
    pass
  else
    fail "$1" "expected exit $2, got $STATUS" "stdout: $OUT" "stderr: $ERR"
  fi
}

# Runs a function of the script in a subshell that has the script's own shell
# options back on; leaves stdout in OUT, stderr in ERR and the exit status in
# STATUS. A `die` inside exits only that subshell.
run() {
  ( set -euo pipefail; "$@" ) >"$SCRATCH/stdout" 2>"$SCRATCH/stderr"
  STATUS=$?
  OUT="$(cat "$SCRATCH/stdout")"
  ERR="$(cat "$SCRATCH/stderr")"
}

# Parses arguments in a subshell and prints the resulting state on one line,
# so a test compares the whole outcome at once.
parsed() {
  ( set -euo pipefail
    parse_args "$@"
    printf 'mode=%s tag=%s from=%s data=%s dry=%s' "$MODE" "$TAG" "$FROM_ZIP" "$DATA_CHOICE" "$DRY_RUN" )
}

# A stand-in for an installed Echo.app: just the Info.plist the script reads.
fake_installed_echo() {  # $1 version, $2 build
  mkdir -p "$ECHO_INSTALL_DEST/Contents/MacOS"
  cat >"$ECHO_INSTALL_DEST/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>com.sancrisoft.Echo</string>
  <key>CFBundleShortVersionString</key><string>$1</string>
  <key>CFBundleVersion</key><string>$2</string>
</dict>
</plist>
PLIST
}

# The shape of GET /repos/{owner}/{repo}/releases/tags/{tag}, trimmed to the
# fields around the ones the script reads. GitHub reports `digest` as
# "sha256:<hex>" and as null for assets it has no checksum for.
write_release_json() {  # $1 path
  cat >"$1" <<'JSON'
{
  "url": "https://api.github.com/repos/sancrisoft/echo/releases/1",
  "tag_name": "v0.0.12",
  "name": "Echo 0.0.12",
  "draft": false,
  "prerelease": false,
  "assets": [
    {
      "name": "Echo-0.0.12.zip",
      "content_type": "application/zip",
      "size": 13989240,
      "digest": "sha256:5206886dc626b50bbebfe65a9d8df978f588ac085c57e0faa9961787435382a8",
      "browser_download_url": "https://github.com/sancrisoft/echo/releases/download/v0.0.12/Echo-0.0.12.zip"
    },
    {
      "name": "Echo-0.0.12.dSYM.zip",
      "content_type": "application/zip",
      "size": 1024,
      "digest": null,
      "browser_download_url": "https://github.com/sancrisoft/echo/releases/download/v0.0.12/Echo-0.0.12.dSYM.zip"
    }
  ]
}
JSON
}

# --- version_compare ----------------------------------------------------------

assert_eq "version_compare: older"                      -1 "$(version_compare 15.6 26.6.2)"
assert_eq "version_compare: newer"                       1 "$(version_compare 26.6.2 15.6)"
assert_eq "version_compare: equal"                       0 "$(version_compare 0.0.12 0.0.12)"
assert_eq "version_compare: missing components are 0"    0 "$(version_compare 1.0 1.0.0)"
assert_eq "version_compare: numeric, not lexical"        1 "$(version_compare 0.0.10 0.0.9)"
assert_eq "version_compare: text after the digits ignored" 0 "$(version_compare 12-rc1 12)"
assert_eq "version_compare: leading zeros are decimal"   0 "$(version_compare 08 8)"
assert_eq "version_compare: the macOS floor"             0 "$(version_compare 15.6 15.6)"
assert_eq "version_compare: just below the floor"       -1 "$(version_compare 15.5 15.6)"

# --- normalize_tag and asset_name ---------------------------------------------

assert_eq "normalize_tag: adds the v"  v0.0.11 "$(normalize_tag 0.0.11)"
assert_eq "normalize_tag: keeps the v" v0.0.11 "$(normalize_tag v0.0.11)"
assert_eq "asset_name: named after the bare version" Echo-0.0.12.zip "$(asset_name v0.0.12)"

# --- digest_from_release_json -------------------------------------------------

write_release_json "$SCRATCH/release.json"
printf 'not json' >"$SCRATCH/broken.json"

assert_eq "digest: the asset's sha256" \
  "sha256:5206886dc626b50bbebfe65a9d8df978f588ac085c57e0faa9961787435382a8" \
  "$(digest_from_release_json "$SCRATCH/release.json" Echo-0.0.12.zip)"
assert_eq "digest: an asset GitHub has no checksum for" "" \
  "$(digest_from_release_json "$SCRATCH/release.json" Echo-0.0.12.dSYM.zip)"
assert_eq "digest: an asset that is not in the release" "" \
  "$(digest_from_release_json "$SCRATCH/release.json" Echo-9.9.9.zip)"
assert_eq "digest: a file that does not exist" "" \
  "$(digest_from_release_json "$SCRATCH/missing.json" Echo-0.0.12.zip)"
assert_eq "digest: a response that is not JSON" "" \
  "$(digest_from_release_json "$SCRATCH/broken.json" Echo-0.0.12.zip)"

# --- parse_args ---------------------------------------------------------------

assert_eq "parse_args: no arguments"      "mode=install tag= from= data= dry=false" "$(parsed)"
assert_eq "parse_args: --version <tag>"   "mode=install tag=v0.0.11 from= data= dry=false" "$(parsed --version v0.0.11)"
assert_eq "parse_args: --version <bare>"  "mode=install tag=v0.0.11 from= data= dry=false" "$(parsed --version 0.0.11)"
assert_eq "parse_args: --version=<tag>"   "mode=install tag=v0.0.11 from= data= dry=false" "$(parsed --version=0.0.11)"
assert_eq "parse_args: a bare tag (the original one-liner)" \
  "mode=install tag=v0.0.11 from= data= dry=false" "$(parsed v0.0.11)"
assert_eq "parse_args: a bare version"    "mode=install tag=v0.0.11 from= data= dry=false" "$(parsed 0.0.11)"
assert_eq "parse_args: --check"           "mode=check tag= from= data= dry=false" "$(parsed --check)"
assert_eq "parse_args: --from <zip>"      "mode=from tag= from=/tmp/Echo-0.0.11.zip data= dry=false" "$(parsed --from /tmp/Echo-0.0.11.zip)"
assert_eq "parse_args: --from=<zip>"      "mode=from tag= from=/tmp/Echo-0.0.11.zip data= dry=false" "$(parsed --from=/tmp/Echo-0.0.11.zip)"
assert_eq "parse_args: --uninstall"       "mode=uninstall tag= from= data= dry=false" "$(parsed --uninstall)"
assert_eq "parse_args: --uninstall --keep-data"   "mode=uninstall tag= from= data=keep dry=false" "$(parsed --uninstall --keep-data)"
assert_eq "parse_args: --uninstall --delete-data" "mode=uninstall tag= from= data=delete dry=false" "$(parsed --uninstall --delete-data)"
assert_eq "parse_args: --dry-run"         "mode=install tag= from= data= dry=true" "$(parsed --dry-run)"
assert_eq "parse_args: --dry-run --version" "mode=install tag=v0.0.12 from= data= dry=true" "$(parsed --dry-run --version v0.0.12)"
assert_eq "parse_args: --uninstall --dry-run" "mode=uninstall tag= from= data= dry=true" "$(parsed --uninstall --dry-run)"
assert_eq "parse_args: --help"            "mode=help tag= from= data= dry=false" "$(parsed --help)"
assert_eq "parse_args: -h"                "mode=help tag= from= data= dry=false" "$(parsed -h)"

run parse_args --bogus
assert_status "parse_args: an unknown option exits 1" 1
assert_eq "parse_args: an unknown option is named" "error: unknown option: --bogus (try --help)" "$ERR"

run parse_args --version
assert_status "parse_args: --version without a tag exits 1" 1
assert_eq "parse_args: --version without a tag says so" "error: --version needs a tag, e.g. --version v0.0.11" "$ERR"

run parse_args --from
assert_status "parse_args: --from without a path exits 1" 1
assert_eq "parse_args: --from without a path says so" "error: --from needs the path to a release zip" "$ERR"

# --- --help -------------------------------------------------------------------

run main --help
assert_status "--help: exits 0" 0
assert_contains "--help: the one-liner" "$OUT" \
  "curl -fsSL https://raw.githubusercontent.com/sancrisoft/echo/main/scripts/install.sh | bash"
assert_contains "--help: documents --dry-run" "$OUT" "--dry-run"

# --- dry run: install ---------------------------------------------------------

run main --dry-run --version v0.0.12
assert_status "dry-run install: exits 0" 0
assert_eq "dry-run install: nothing on stderr" "" "$ERR"
assert_contains "dry-run install: announces itself" "$OUT" "==> Dry run"
assert_contains "dry-run install: the requested release" "$OUT" "==> Requested release: v0.0.12"
assert_contains "dry-run install: the download URL" "$OUT" \
  "Would download https://github.com/sancrisoft/echo/releases/download/v0.0.12/Echo-0.0.12.zip"
assert_contains "dry-run install: the empty destination" "$OUT" \
  "Would install to $ECHO_INSTALL_DEST (nothing is there now)"
assert_contains "dry-run install: a custom destination never manages the running app" "$OUT" \
  "Would leave any running Echo alone (custom destination via ECHO_INSTALL_DEST)"
assert_not_contains "dry-run install: would not quit Echo" "$OUT" "Would quit"
assert_not_contains "dry-run install: would not open Echo" "$OUT" "Would open"
assert_missing "dry-run install: installed nothing" "$ECHO_INSTALL_DEST"
assert_eq "dry-run install: left no temp folder behind" "" "$(find "$TMPDIR" -mindepth 1)"

fake_installed_echo 0.0.11 80

run main --dry-run --version v0.0.12
assert_status "dry-run update: exits 0" 0
assert_contains "dry-run update: installed version against the target" "$OUT" \
  "Would update Echo 0.0.11 (build 80) at $ECHO_INSTALL_DEST to 0.0.12"

run main --dry-run --version v0.0.11
assert_status "dry-run same version: exits 0" 0
assert_contains "dry-run same version: only a different build is replaced" "$OUT" \
  "Would replace Echo 0.0.11 (build 80) at $ECHO_INSTALL_DEST only if v0.0.11 is a different build"

run main --dry-run 0.0.10
assert_status "dry-run downgrade: exits 0" 0
assert_contains "dry-run downgrade: says the target is older" "$OUT" \
  "Would replace Echo 0.0.11 (build 80) at $ECHO_INSTALL_DEST with the older v0.0.10"

: >"$SCRATCH/Echo-0.0.11.zip"
run main --dry-run --from "$SCRATCH/Echo-0.0.11.zip"
assert_status "dry-run --from: exits 0" 0
assert_contains "dry-run --from: names the zip" "$OUT" "==> Would install from $SCRATCH/Echo-0.0.11.zip (no network)"
assert_not_contains "dry-run --from: no download" "$OUT" "Would download"
assert_contains "dry-run --from: what it would replace" "$OUT" \
  "Would replace Echo 0.0.11 (build 80) at $ECHO_INSTALL_DEST, unless the zip holds that exact build"

run main --dry-run --from "$SCRATCH/missing.zip"
assert_status "dry-run --from a missing zip: exits 1" 1
assert_eq "dry-run --from a missing zip: says which" "error: no such file: $SCRATCH/missing.zip" "$ERR"

assert_eq "dry-run install: the installed app is untouched" "0.0.11" "$(installed_version)"
assert_eq "dry-run install: still no temp folder" "" "$(find "$TMPDIR" -mindepth 1)"

# --- dry run: uninstall -------------------------------------------------------

run main --dry-run --uninstall
assert_status "dry-run uninstall: exits 0" 0
assert_eq "dry-run uninstall: nothing on stderr" "" "$ERR"
assert_contains "dry-run uninstall: what would be removed" "$OUT" \
  "==> Would remove $ECHO_INSTALL_DEST (Echo 0.0.11, build 80)"
assert_contains "dry-run uninstall: no data folder yet" "$OUT" "No data folder at $DATA_DIR"
assert_not_contains "dry-run uninstall: would not quit Echo" "$OUT" "Would quit"
assert_exists "dry-run uninstall: the app is still there" "$ECHO_INSTALL_DEST/Contents/Info.plist"

mkdir -p "$DATA_DIR/Meetings"
printf '{}' >"$DATA_DIR/settings.json"

run main --dry-run --uninstall
assert_status "dry-run uninstall with data: exits 0" 0
assert_contains "dry-run uninstall with data: would ask" "$OUT" "Would ask before deleting $DATA_DIR"
assert_contains "dry-run uninstall with data: the default answer" "$OUT" "the answer defaults to keeping it"
assert_not_contains "dry-run uninstall with data: does not actually ask" "$OUT" "assuming no"

run main --dry-run --uninstall --keep-data
assert_status "dry-run uninstall --keep-data: exits 0" 0
assert_contains "dry-run uninstall --keep-data: would keep" "$OUT" \
  "==> Would keep your meetings, transcripts and models in $DATA_DIR"

run main --dry-run --uninstall --delete-data
assert_status "dry-run uninstall --delete-data: exits 0" 0
assert_contains "dry-run uninstall --delete-data: would delete" "$OUT" "==> Would delete $DATA_DIR"
assert_exists "dry-run uninstall --delete-data: the data folder survives" "$DATA_DIR/settings.json"
assert_exists "dry-run uninstall --delete-data: the app survives" "$ECHO_INSTALL_DEST/Contents/Info.plist"

rm -rf "$ECHO_INSTALL_DEST"
run main --dry-run --uninstall --keep-data
assert_status "dry-run uninstall, nothing installed: exits 0" 0
assert_contains "dry-run uninstall, nothing installed: says so" "$OUT" "==> Nothing installed at $ECHO_INSTALL_DEST"
assert_exists "dry-run uninstall, nothing installed: the data folder survives" "$DATA_DIR/settings.json"

# --- summary ------------------------------------------------------------------

printf '%d passed, %d failed\n' "$PASSED" "$FAILED"
[ "$FAILED" -eq 0 ] || exit 1
