#!/usr/bin/env bash
set -euo pipefail

# check_update.sh — Cursor Agent versions are date-stamped
# (e.g. 2026.07.23-e383d2b), not semver. We report the installed version and
# best-effort compare against the latest published installer revision when
# discoverable; otherwise we only surface the installed version.

json_error() {
  local message="$1"
  if command -v jq >/dev/null 2>&1; then
    jq -nc --arg error "$message" '{updateAvailable: false, error: $error}'
  else
    message="$(printf '%s' "$message" | sed 's/\\/\\\\/g; s/"/\\"/g')"
    printf '{"updateAvailable":false,"error":"%s"}\n' "$message"
  fi
  exit 0
}

# Match 2026.07.23 or 2026.07.23-e383d2b style stamps.
extract_version() {
  printf '%s\n' "$1" | grep -Eo '[0-9]{4}\.[0-9]{2}\.[0-9]{2}(-[0-9A-Za-z]+)?' | sed -n '1p'
}

# Lexicographic compare on YYYY.MM.DD stamps works for chronological order.
version_is_newer() {
  local installed="$1"
  local latest="$2"
  local i_core="${installed%%-*}"
  local l_core="${latest%%-*}"
  [[ "$l_core" > "$i_core" ]]
}

command -v jq >/dev/null 2>&1 || json_error "jq not found"

CURSOR_BIN="$(command -v cursor-agent 2>/dev/null || true)"
if [[ -z "$CURSOR_BIN" ]]; then
  for candidate in \
    "$HOME/.local/bin/cursor-agent" \
    "$HOME/.local/bin/agent" \
    /usr/local/bin/cursor-agent \
    /opt/homebrew/bin/cursor-agent; do
    if [[ -x "$candidate" ]]; then
      CURSOR_BIN="$candidate"
      break
    fi
  done
fi
[[ -n "$CURSOR_BIN" ]] || json_error "cursor-agent not found"

installed_output="$("$CURSOR_BIN" --version 2>&1)" || json_error "failed to determine installed Cursor Agent version"
installed_version="$(extract_version "$installed_output")" || true
[[ -n "$installed_version" ]] || json_error "failed to parse installed Cursor Agent version"

# Best-effort latest: Cursor publishes installers under cursor.com; there is no
# stable public version API. Probe the agent package metadata if present, else
# report installed-only (updateAvailable=false) so the UI still shows a version.
latest_version=""
if command -v curl >/dev/null 2>&1; then
  # Optional: GitHub releases mirror used by some packaging channels.
  release_json="$(curl -fsS --connect-timeout 2 --max-time 5 \
    -H 'Accept: application/vnd.github+json' \
    'https://api.github.com/repos/cursor/cursor/releases/latest' 2>/dev/null || true)"
  if [[ -n "$release_json" ]]; then
    tag="$(printf '%s' "$release_json" | jq -r '.tag_name // empty' 2>/dev/null || true)"
    latest_version="$(extract_version "$tag" || true)"
  fi
fi

update_available=false
if [[ -n "$latest_version" ]] && version_is_newer "$installed_version" "$latest_version"; then
  update_available=true
fi

if [[ -n "$latest_version" ]]; then
  jq -nc \
    --arg installed "$installed_version" \
    --arg latest "$latest_version" \
    --argjson available "$update_available" \
    '{installedVersion: $installed, latestVersion: $latest, updateAvailable: $available}'
else
  # No public latest pin — still report installed so the UI isn't empty.
  jq -nc \
    --arg installed "$installed_version" \
    '{installedVersion: $installed, latestVersion: $installed, updateAvailable: false}'
fi
