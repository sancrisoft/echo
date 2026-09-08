#!/usr/bin/env bash
#
# The boundary rules SwiftPM cannot express, checked on every `make lint` and
# in CI. Each rule names the file that breaks it. See
# docs/architecture/v2-architecture.md §2.1.
#
set -euo pipefail
cd "$(dirname "$0")/.."

failures=0
fail() { echo "boundary: $1"; failures=$((failures + 1)); }

# Engine packages: no user interface. UI packages: SwiftUI is fine.
ENGINE_PACKAGES=(EchoCore Audio Transcription Summarization ModelDelivery Meetings Recording CallDetection Updates)
UI_PACKAGES=(DesignSystem Workspace Island)

# The few engine files that legitimately need AppKit for process identity
# (NSWorkspace / NSRunningApplication), never for drawing.
APPKIT_ALLOWLIST=(
  "Packages/Audio/Sources/Audio/AppBundleIdentity.swift"
  "Packages/Audio/Sources/Audio/SystemAudioCapture.swift"
  "Packages/CallDetection/Sources/CallDetection/BrowserCatalog.swift"
  "Packages/CallDetection/Sources/CallDetection/MicActivityMonitor.swift"
)

# Which packages each package may depend on (the downward-only graph). A
# function rather than an associative array: macOS ships bash 3.2.
allowed_deps() {
  case "$1" in
    EchoCore)       echo "" ;;
    Audio)          echo "EchoCore" ;;
    ModelDelivery)  echo "EchoCore" ;;
    Transcription)  echo "EchoCore ModelDelivery" ;;
    Summarization)  echo "EchoCore ModelDelivery" ;;
    Meetings)       echo "EchoCore" ;;
    Recording)      echo "EchoCore Audio Transcription Summarization ModelDelivery Meetings" ;;
    CallDetection)  echo "EchoCore Audio" ;;
    Updates)        echo "EchoCore" ;;
    DesignSystem)   echo "" ;;
    Workspace)      echo "EchoCore Meetings Recording ModelDelivery Updates CallDetection DesignSystem" ;;
    Island)         echo "EchoCore CallDetection Recording DesignSystem" ;;
    *)              echo "__unknown__" ;;
  esac
}

in_list() { local needle="$1"; shift; for item in "$@"; do [[ "$item" == "$needle" ]] && return 0; done; return 1; }

# 1. Every package on disk is a known package with a Package.swift.
for dir in Packages/*/; do
  name="$(basename "$dir")"
  [[ -f "$dir/Package.swift" ]] || fail "$dir has no Package.swift"
  if ! in_list "$name" "${ENGINE_PACKAGES[@]}" "${UI_PACKAGES[@]}"; then
    fail "Packages/$name is not in the architecture's package list (docs/architecture/v2-architecture.md §2)"
  fi
done

# 2. Dependency direction: every `.package(path: "../X")` must be allowed.
for dir in Packages/*/; do
  name="$(basename "$dir")"
  allowed_list="$(allowed_deps "$name")"
  [[ "$allowed_list" == "__unknown__" ]] && continue
  while IFS= read -r dep; do
    [[ -z "$dep" ]] && continue
    # shellcheck disable=SC2206
    allowed=($allowed_list)
    if ! in_list "$dep" ${allowed[@]+"${allowed[@]}"}; then
      fail "$name depends on $dep, which the dependency graph does not allow"
    fi
  done < <(grep -oE 'path: *"\.\./[A-Za-z]+"' "$dir/Package.swift" | sed -E 's/.*"\.\.\/([A-Za-z]+)"/\1/')
done

# 3. Engine packages never import SwiftUI; AppKit only on the allowlist.
for name in "${ENGINE_PACKAGES[@]}"; do
  src="Packages/$name/Sources"
  [[ -d "$src" ]] || continue
  while IFS= read -r file; do
    if grep -qE '^\s*import SwiftUI' "$file"; then
      fail "$file imports SwiftUI inside an engine package"
    fi
    if grep -qE '^\s*import (AppKit|Cocoa)' "$file" && ! in_list "$file" "${APPKIT_ALLOWLIST[@]}"; then
      fail "$file imports AppKit inside an engine package (not on the allowlist)"
    fi
  done < <(find "$src" -name '*.swift')
done

# 4. Nothing imports the app; UI packages never import each other.
for dir in Packages/*/Sources; do
  while IFS= read -r file; do
    grep -qE '^\s*import Echo$' "$file" && fail "$file imports the app target"
    for ui in "${UI_PACKAGES[@]}"; do
      case "$dir" in Packages/$ui/*) continue ;; esac
      pkg="$(echo "$dir" | cut -d/ -f2)"
      if in_list "$pkg" "${UI_PACKAGES[@]}" && [[ "$ui" != "DesignSystem" ]] \
         && grep -qE "^\s*import $ui\$" "$file"; then
        fail "$file: UI package $pkg imports sibling UI package $ui"
      fi
    done
  done < <(find "$dir" -name '*.swift')
done

# 5. Forbidden patterns in production sources.
while IFS= read -r file; do
  if grep -nE 'ProcessInfo\.processInfo\.environment' "$file" >/dev/null; then
    case "$file" in
      Packages/EchoCore/Sources/EchoCore/LaunchEnvironment.swift|\
      Packages/EchoCore/Sources/EchoCore/TestHost.swift|\
      Packages/EchoCore/Sources/EchoCoreTestSupport/Acceptance.swift) ;;
      *) fail "$file reads the environment directly; add a flag to LaunchEnvironment instead" ;;
    esac
  fi
  # Comment lines may name these (to say why they are forbidden); code may not.
  code="$(grep -vE '^\s*(//|\*)' "$file" || true)"
  grep -qE '\bUserDefaults\b' <<<"$code" && fail "$file uses UserDefaults; preferences live in settings.json (AppSettings)"
  grep -qE '(^|[^A-Za-z_.])print\(' <<<"$code" && fail "$file uses print(); use os.Logger or ErrorTrace.record"
  grep -nE '\b(hf_[A-Za-z0-9]{20,}|ghp_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,})\b' "$file" >/dev/null && fail "$file contains what looks like a credential"
done < <(find App Packages/*/Sources -name '*.swift' 2>/dev/null)

if (( failures > 0 )); then
  echo "boundary: $failures problem(s)"
  exit 1
fi
echo "boundary: ok"
