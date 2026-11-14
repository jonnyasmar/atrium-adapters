#!/usr/bin/env bash
set -euo pipefail

# check_update.sh — Compare the installed Muse Code build against its channel.
# Output: {"installedVersion","latestVersion","updateAvailable"} or {"error",...}
#
# Muse's own launcher resolves updates from a channel document, so we ask the
# same endpoint it does rather than scraping a release page:
#
#   https://api.meta.ai/muse-code/channels/muse-stable
#     -> {"channel":"muse-stable","version":"1.0.2-R2040.1",...}
#
# The installed version is read from the marker the launcher writes next to
# itself (`.muse-version`), which is exact and needs no process spawn. We fall
# back to `muse --version` ("Muse Code 1.0.2 (1.0.2-R2040.1)") only when the
# marker is absent, and compare the FULL build string (`1.0.2-R2040.1`) — the
# marketing "1.0.2" alone is not unique across builds, so comparing it would
# under-report real updates.

CHANNEL_URL="${MUSE_CHANNEL_URL:-https://api.meta.ai/muse-code/channels/muse-stable}"

emit_error() {
  printf '{"updateAvailable":false,"error":%s}\n' \
    "$(printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g; s/^/"/; s/$/"/')"
  exit 0
}

# --- installed -------------------------------------------------------------
INSTALLED=""
markers=("$HOME/.local/bin/.muse-version" "${MUSE_INSTALL_DIR:-}/.muse-version")
case "$(uname -s)" in
  # install.ps1's launcher home: $MUSE_INSTALL_DIR, else %LOCALAPPDATA%\Programs\muse.
  # A ~/.local/bin marker here would be a POSIX launcher Windows never runs, and
  # `command -v muse` below cannot see the muse.cmd shim.
  MINGW*|MSYS*|CYGWIN*)
    markers=("${MUSE_INSTALL_DIR:-}/.muse-version" "${LOCALAPPDATA:-}/Programs/muse/.muse-version")
    ;;
esac
for marker in "${markers[@]}"; do
  if [ -n "$marker" ] && [ -f "$marker" ]; then
    INSTALLED="$(tr -d '[:space:]' <"$marker")"
    [ -n "$INSTALLED" ] && break
  fi
done

if [ -z "$INSTALLED" ]; then
  if ! command -v muse &>/dev/null; then
    emit_error "muse is not installed"
  fi
  # "Muse Code 1.0.2 (1.0.2-R2040.1)" -> the parenthesized build string.
  INSTALLED="$(muse --version 2>/dev/null | head -1 | sed -n 's/.*(\(.*\)).*/\1/p')"
fi

[ -n "$INSTALLED" ] || emit_error "could not determine the installed muse version"

# --- latest ----------------------------------------------------------------
if ! command -v curl &>/dev/null; then
  emit_error "curl is required to check for muse updates"
fi

CHANNEL_JSON="$(curl -fsSL --max-time 10 --proto '=https' "$CHANNEL_URL" 2>/dev/null)" ||
  emit_error "could not reach the muse release channel"

if command -v jq &>/dev/null; then
  LATEST="$(printf '%s' "$CHANNEL_JSON" | jq -r '.version // empty' 2>/dev/null)"
else
  LATEST="$(printf '%s' "$CHANNEL_JSON" |
    sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)"
fi

[ -n "$LATEST" ] || emit_error "the muse release channel returned no version"

# String inequality, not a semver ordering: the build suffix (R2040.1) is not
# semver, and muse's channel is the authority on what "current" means. A
# mismatch in either direction means the local build is not the channel build.
if [ "$INSTALLED" = "$LATEST" ]; then
  AVAILABLE="false"
else
  AVAILABLE="true"
fi

printf '{"installedVersion":"%s","latestVersion":"%s","updateAvailable":%s}\n' \
  "$INSTALLED" "$LATEST" "$AVAILABLE"
