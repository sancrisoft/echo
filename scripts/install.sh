#!/usr/bin/env bash
#
# Echo installer — installs, updates, checks or removes Echo using the GitHub
# releases of sancrisoft/echo. Plain curl, no GitHub account, no other tools.
#
#   curl -fsSL https://raw.githubusercontent.com/sancrisoft/echo/main/scripts/install.sh | bash
#
# Options go after `bash -s --`:
#
#   --version <tag>   Install that release instead of the latest (v0.0.11 or 0.0.11).
#   --check           Report the installed and latest versions; change nothing.
#   --from <zip>      Install from a release zip already on disk (no network).
#   --uninstall       Remove Echo.app, then ask before deleting your meetings.
#       --keep-data / --delete-data   Answer that question up front.
#   --help            This text.
#
# How it gets the release without credentials: GitHub redirects
# github.com/<repo>/releases/latest to the latest tag, and a public release's
# assets download straight from github.com/<repo>/releases/download/<tag>/. The
# only API call is a best-effort fetch of the checksum GitHub publishes for the
# asset; when that is unavailable (offline mirror, rate limit) the code
# signature check still runs.
#
# Environment (test seams, not for everyday use):
#   ECHO_INSTALL_DEST  Install somewhere other than /Applications/Echo.app. With
#                      a custom destination the script never quits or launches
#                      Echo, so a test install can't disturb a running copy.
#   ECHO_INSTALL_REPO  Read releases from another <owner>/<repo>.
#
# Everything lives in functions and `main` runs last, so a download cut off
# halfway through cannot execute half a script.
set -euo pipefail

REPO="${ECHO_INSTALL_REPO:-sancrisoft/echo}"
APP_PATH="${ECHO_INSTALL_DEST:-/Applications/Echo.app}"
DATA_DIR="$HOME/Library/Application Support/Echo"
MIN_MACOS="15.6"
# Free space the first launch needs: the two on-device models take about 4 GB
# on disk and the download stages through roughly 6 GB. The installer only warns.
RECOMMENDED_FREE_GB=6

# A custom destination means "leave whatever Echo is running alone".
MANAGES_RUNNING_APP=true
if [ -n "${ECHO_INSTALL_DEST:-}" ]; then
  MANAGES_RUNNING_APP=false
fi

MODE="install"
TAG=""
FROM_ZIP=""
DATA_CHOICE=""   # "" (ask), keep, delete
TMP=""
DOWNLOADED_ZIP=""   # set by download_release

# --- output -------------------------------------------------------------------

say()  { printf '==> %s\n' "$*"; }
note() { printf '    %s\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }
die()  { printf 'error: %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<EOF
Echo installer

  curl -fsSL https://raw.githubusercontent.com/$REPO/main/scripts/install.sh | bash [-s -- OPTIONS]

Options:
  --version <tag>   Install that release instead of the latest (v0.0.11 or 0.0.11).
  --check           Report the installed and latest versions; change nothing.
  --from <zip>      Install from a release zip already on disk (no network).
  --uninstall       Remove Echo.app, then ask before deleting your meetings.
      --keep-data / --delete-data   Answer that question up front.
  --help            Show this text.

Releases: https://github.com/$REPO/releases
EOF
}

# --- arguments ----------------------------------------------------------------

parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --version)
        [ $# -ge 2 ] || die "--version needs a tag, e.g. --version v0.0.11"
        TAG="$(normalize_tag "$2")"; shift 2 ;;
      --version=*)
        TAG="$(normalize_tag "${1#--version=}")"; shift ;;
      --check)      MODE="check"; shift ;;
      --from)
        [ $# -ge 2 ] || die "--from needs the path to a release zip"
        MODE="from"; FROM_ZIP="$2"; shift 2 ;;
      --from=*)     MODE="from"; FROM_ZIP="${1#--from=}"; shift ;;
      --uninstall)  MODE="uninstall"; shift ;;
      --keep-data)  DATA_CHOICE="keep"; shift ;;
      --delete-data) DATA_CHOICE="delete"; shift ;;
      -h|--help)    MODE="help"; shift ;;
      v[0-9]*|[0-9]*.[0-9]*)
        # The original one-liner took the tag as a bare argument; keep it working.
        TAG="$(normalize_tag "$1")"; shift ;;
      *) die "unknown option: $1 (try --help)" ;;
    esac
  done
}

# "0.0.11" -> "v0.0.11"; "v0.0.11" unchanged.
normalize_tag() {
  case "$1" in
    v*) printf '%s' "$1" ;;
    *)  printf 'v%s' "$1" ;;
  esac
}

# --- small helpers ------------------------------------------------------------

# Compares two dotted numeric versions ("15.6" vs "26.6.2"); prints -1, 0 or 1.
# Anything after a digit run is ignored ("12-rc1" counts as 12), and missing
# components count as 0, so 1.0 == 1.0.0.
version_compare() {
  local IFS=.
  # shellcheck disable=SC2206  # splitting on IFS is the point
  local -a a=($1) b=($2)
  local i max=${#a[@]} x y
  [ "${#b[@]}" -gt "$max" ] && max=${#b[@]}
  for ((i = 0; i < max; i++)); do
    x=${a[i]:-0}; y=${b[i]:-0}
    x=${x%%[^0-9]*}; y=${y%%[^0-9]*}
    x=${x:-0}; y=${y:-0}
    if ((10#$x > 10#$y)); then echo 1; return; fi
    if ((10#$x < 10#$y)); then echo -1; return; fi
  done
  echo 0
}

# Reads a yes/no answer from the terminal. Defaults to no — including when
# there is no terminal to ask (piped through `curl | bash` with stdin busy, a
# CI job), because the only questions this script asks guard deletions.
ask_yes_no() {
  local answer=""
  if (exec 3<>/dev/tty) 2>/dev/null; then
    printf '%s [y/N] ' "$1" >/dev/tty
    read -r answer </dev/tty || answer=""
  else
    note "(no terminal to ask on; assuming no)"
  fi
  case "$answer" in
    y|Y|yes|YES|Yes) return 0 ;;
    *) return 1 ;;
  esac
}

plist_value() {  # $1 app path, $2 key
  defaults read "$1/Contents/Info.plist" "$2" 2>/dev/null || true
}

installed_version() { plist_value "$APP_PATH" CFBundleShortVersionString; }
installed_build()   { plist_value "$APP_PATH" CFBundleVersion; }

# The code directory hash identifies the exact signed bits, so two installs of
# the same version — a release and its hotfix rebuild — compare unequal here
# even though their version strings match.
cdhash() {
  codesign -dvvv "$1" 2>&1 | awk -F= '/^CDHash=/ { print $2; exit }'
}

human_bytes() {  # $1 bytes
  awk -v b="$1" 'BEGIN {
    if (b >= 1073741824) printf "%.1f GB", b / 1073741824
    else if (b >= 1048576) printf "%.1f MB", b / 1048576
    else printf "%d KB", b / 1024
  }'
}

echo_is_running() {
  pgrep -f "Echo.app/Contents/MacOS/Echo" >/dev/null 2>&1
}

quit_echo() {
  $MANAGES_RUNNING_APP || return 0
  echo_is_running || return 0
  say "Quitting Echo"
  osascript -e 'tell application id "com.sancrisoft.Echo" to quit' >/dev/null 2>&1 || true
  local waited=0
  while echo_is_running && [ $waited -lt 20 ]; do
    sleep 0.5; waited=$((waited + 1))
  done
  if echo_is_running; then
    pkill -f "Echo.app/Contents/MacOS/Echo" >/dev/null 2>&1 || true
    sleep 1
  fi
}

launch_echo() {
  $MANAGES_RUNNING_APP || return 0
  say "Opening Echo — look for the waveform icon in your menu bar"
  open -a "$APP_PATH" 2>/dev/null || warn "couldn't open Echo automatically; open it from /Applications"
}

# --- preflight ----------------------------------------------------------------

preflight() {
  [ "$(uname -s)" = "Darwin" ] || die "Echo is a macOS app"

  if [ "$(sysctl -n hw.optional.arm64 2>/dev/null || echo 0)" != "1" ]; then
    die "Echo needs an Apple Silicon (M-series) Mac; this one is $(uname -m)"
  fi

  local macos
  macos="$(sw_vers -productVersion)"
  if [ "$(version_compare "$macos" "$MIN_MACOS")" -lt 0 ]; then
    die "Echo needs macOS $MIN_MACOS or later; this Mac runs $macos"
  fi

  local dest_dir free_kb free_gb
  dest_dir="$(dirname "$APP_PATH")"
  [ -d "$dest_dir" ] || die "$dest_dir does not exist"
  if [ ! -w "$dest_dir" ]; then
    die "cannot write to $dest_dir — install with ECHO_INSTALL_DEST=\"\$HOME/Applications/Echo.app\" or as an administrator"
  fi
  free_kb="$(df -k "$dest_dir" | awk 'NR == 2 { print $4 }')"
  free_gb=$((free_kb / 1048576))

  say "This Mac: Apple Silicon, macOS $macos, ${free_gb} GB free"
  if [ "$free_gb" -lt "$RECOMMENDED_FREE_GB" ]; then
    warn "Echo downloads about 4 GB of on-device models on first launch and needs about ${RECOMMENDED_FREE_GB} GB free while it does; ${free_gb} GB free may not be enough"
  fi
}

# --- releases -----------------------------------------------------------------

# GitHub answers /releases/latest with a redirect to /releases/tag/<tag>;
# following nothing and reading the Location is the whole lookup. No API, no
# rate limit, no JSON.
latest_tag() {
  local url
  url="$(curl -fsSI -o /dev/null -w '%{redirect_url}' "https://github.com/$REPO/releases/latest" 2>/dev/null || true)"
  case "$url" in
    */releases/tag/v[0-9]*) printf '%s' "${url##*/}" ;;
    *) return 1 ;;
  esac
}

require_latest_tag() {
  local tag
  if ! tag="$(latest_tag)"; then
    die "couldn't find the latest release of $REPO. Are you online? Releases: https://github.com/$REPO/releases"
  fi
  printf '%s' "$tag"
}

asset_name() { printf 'Echo-%s.zip' "${1#v}"; }   # $1 tag

# Best effort: the sha256 GitHub records for the asset, or nothing. Parsed
# with the JavaScript runtime every Mac ships, so the script needs no jq.
published_digest() {  # $1 tag, $2 asset name
  local json="$TMP/release.json"
  curl -fsSL --max-time 15 \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    -o "$json" \
    "https://api.github.com/repos/$REPO/releases/tags/$1" 2>/dev/null || return 0
  digest_from_release_json "$json" "$2"
}

digest_from_release_json() {  # $1 json file, $2 asset name -> "sha256:<hex>" or nothing
  osascript -l JavaScript \
    -e 'ObjC.import("Foundation");' \
    -e 'function run(argv) {' \
    -e '  const text = $.NSString.stringWithContentsOfFileEncodingError(argv[0], 4, null);' \
    -e '  if (!text || text.isNil()) return "";' \
    -e '  const release = JSON.parse(text.js);' \
    -e '  const asset = (release.assets || []).find(a => a.name === argv[1]);' \
    -e '  return asset && asset.digest ? String(asset.digest) : "";' \
    -e '}' \
    "$1" "$2" 2>/dev/null || true
}

# Hands the zip back through DOWNLOADED_ZIP rather than stdout: the progress
# lines below share stdout, and a caller capturing it with $(...) would read
# them as part of the path.
download_release() {  # $1 tag -> sets DOWNLOADED_ZIP
  local name url zip
  name="$(asset_name "$1")"
  url="https://github.com/$REPO/releases/download/$1/$name"
  zip="$TMP/$name"
  # Confirm the asset exists before the progress bar starts drawing, so a
  # missing release reads as one clean line instead of half a bar and a
  # curl error code.
  if ! curl -fsSLI --max-time 20 -o /dev/null "$url"; then
    die "release $1 has no $name. Releases: https://github.com/$REPO/releases"
  fi
  say "Downloading $url"
  if ! curl -fL --retry 3 --retry-delay 1 --progress-bar -o "$zip" "$url"; then
    die "download of $name failed"
  fi
  note "$(human_bytes "$(stat -f %z "$zip")")"

  local digest actual
  digest="$(published_digest "$1" "$name")"
  case "$digest" in
    sha256:*)
      actual="$(shasum -a 256 "$zip" | awk '{ print $1 }')"
      if [ "$actual" != "${digest#sha256:}" ]; then
        die "checksum mismatch: GitHub lists ${digest#sha256:} but the download is $actual. Not installing."
      fi
      say "Checksum matches the one GitHub published (sha256 ${actual:0:12}…)"
      ;;
    *)
      note "GitHub published no checksum for this file; relying on the code signature check"
      ;;
  esac
  DOWNLOADED_ZIP="$zip"
}

# --- install ------------------------------------------------------------------

install_zip() {  # $1 zip path
  local zip="$1" extracted="$TMP/extracted" app version build

  [ -f "$zip" ] || die "no such file: $zip"
  ditto -x -k "$zip" "$extracted" || die "couldn't unpack $zip"
  app="$extracted/Echo.app"
  [ -d "$app" ] || die "Echo.app not found inside $zip"

  # Verifies every file against the seal written at build time. Ad-hoc signed,
  # so this proves integrity (nothing altered or corrupted since CI signed it),
  # not who built it — the checksum above and the HTTPS download cover origin.
  if ! codesign --verify --deep --strict "$app" 2>/dev/null; then
    die "the downloaded Echo.app fails code-signature verification (damaged or altered). Not installing."
  fi
  say "Code signature verified"

  version="$(plist_value "$app" CFBundleShortVersionString)"
  build="$(plist_value "$app" CFBundleVersion)"

  if [ -d "$APP_PATH" ] && [ "$(cdhash "$APP_PATH")" = "$(cdhash "$app")" ]; then
    say "Echo ${version:-?} (build ${build:-?}) is already installed at $APP_PATH — nothing to do"
    return 0
  fi

  quit_echo

  # Stage next to the destination, then swap, so a failed copy never leaves
  # /Applications without an Echo.
  local staging
  staging="$(dirname "$APP_PATH")/.Echo.app.installing"
  rm -rf "$staging"
  ditto "$app" "$staging" || { rm -rf "$staging"; die "couldn't copy Echo.app into $(dirname "$APP_PATH")"; }
  rm -rf "$APP_PATH"
  mv "$staging" "$APP_PATH"

  # A curl download is never quarantined, but clear the flag in case the zip
  # came from a browser (--from).
  xattr -dr com.apple.quarantine "$APP_PATH" 2>/dev/null || true

  say "Installed Echo ${version:-?} (build ${build:-?}) to $APP_PATH"
  launch_echo
}

install_from_github() {
  local tag="$TAG" installed
  if [ -z "$tag" ]; then
    tag="$(require_latest_tag)"
    say "Latest release: $tag"
  else
    say "Requested release: $tag"
  fi

  installed="$(installed_version)"
  if [ -n "$installed" ]; then
    case "$(version_compare "$installed" "${tag#v}")" in
      1)  say "Installed Echo $installed is newer than $tag — installing the requested release anyway" ;;
      0)  note "Echo $installed is installed; fetching $tag to see whether it changed" ;;
      -1) note "Updating Echo $installed → ${tag#v}" ;;
    esac
  fi

  download_release "$tag"
  install_zip "$DOWNLOADED_ZIP"
}

# --- check --------------------------------------------------------------------

check() {
  local installed build latest
  installed="$(installed_version)"
  build="$(installed_build)"
  if [ -n "$installed" ]; then
    say "Installed: Echo $installed (build ${build:-?}) at $APP_PATH"
  else
    say "Installed: nothing at $APP_PATH"
  fi

  latest="$(require_latest_tag)"
  say "Latest:    Echo ${latest#v} — https://github.com/$REPO/releases/tag/$latest"

  if [ -z "$installed" ]; then
    note "Run the install command without --check to install it."
    return 0
  fi
  case "$(version_compare "$installed" "${latest#v}")" in
    -1) note "Update available. Run the install command again to update." ;;
    0)  note "You're up to date." ;;
    1)  note "You're ahead of the latest release." ;;
  esac
}

# --- uninstall ----------------------------------------------------------------

uninstall() {
  if [ -d "$APP_PATH" ]; then
    quit_echo
    rm -rf "$APP_PATH"
    say "Removed $APP_PATH"
  else
    say "Nothing installed at $APP_PATH"
  fi

  if [ ! -d "$DATA_DIR" ]; then
    note "No data folder at $DATA_DIR"
    return 0
  fi

  local size
  size="$(du -sh "$DATA_DIR" 2>/dev/null | awk '{ print $1 }')"
  case "$DATA_CHOICE" in
    keep)
      say "Kept your meetings, transcripts and models in $DATA_DIR (${size:-?})"
      ;;
    delete)
      rm -rf "$DATA_DIR"
      say "Deleted $DATA_DIR (${size:-?})"
      ;;
    *)
      note "Your meetings, transcripts, summaries and the downloaded models are in"
      note "$DATA_DIR (${size:-?}). Reinstalling Echo later finds them again."
      if ask_yes_no "Delete that folder too?"; then
        rm -rf "$DATA_DIR"
        say "Deleted $DATA_DIR"
      else
        say "Kept $DATA_DIR"
      fi
      ;;
  esac
}

# --- main ---------------------------------------------------------------------

main() {
  parse_args "$@"

  case "$MODE" in
    help)
      usage
      return 0 ;;
    check)
      check
      return 0 ;;
    uninstall)
      uninstall
      return 0 ;;
  esac

  TMP="$(mktemp -d "${TMPDIR:-/tmp}/echo-install.XXXXXX")"
  trap 'rm -rf "$TMP"' EXIT

  preflight
  case "$MODE" in
    from)
      say "Installing from $FROM_ZIP"
      install_zip "$FROM_ZIP" ;;
    install)
      install_from_github ;;
  esac
}

# When sourced (tests), stop here with the functions defined.
(return 0 2>/dev/null) && return 0
main "$@"
