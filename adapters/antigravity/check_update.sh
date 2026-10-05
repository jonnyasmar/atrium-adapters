#!/usr/bin/env bash
set -euo pipefail

# check_update.sh — Compare the installed Antigravity CLI against the same
# auto-updater manifest the official installer reads:
#
#   https://<updater-host>/manifests/<platform>.json
#     -> {"version":"1.1.26","url":...,"sha512":...}
#
# Platform strings mirror install.sh exactly (darwin_arm64, linux_amd64,
# linux_arm64_musl, ...); a mismatch 404s and we degrade to installed-only.
#
# Note: agy self-updates in the background during normal runs, so an available
# update here often resolves itself. We still report it — a pinned or offline
# install will not.

UPDATER_HOST="${ATRIUM_AGY_UPDATER_HOST:-https://antigravity-cli-auto-updater-974169037036.us-central1.run.app}"

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

extract_version() {
  printf '%s\n' "$1" | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+([+-][0-9A-Za-z.-]+)?' | sed -n '1p'
}

version_is_newer() {
  local installed_core="${1%%[-+]*}"
  local latest_core="${2%%[-+]*}"
  awk -v installed="$installed_core" -v latest="$latest_core" 'BEGIN {
    split(installed, i, "."); split(latest, l, ".")
    for (n = 1; n <= 3; n++) {
      if ((l[n] + 0) > (i[n] + 0)) exit 0
      if ((l[n] + 0) < (i[n] + 0)) exit 1
    }
    exit 1
  }'
}

command -v jq >/dev/null 2>&1 || json_error "jq not found"

AGY_BIN="$(command -v agy 2>/dev/null || true)"
if [[ -z "$AGY_BIN" ]]; then
  for candidate in "$HOME/.local/bin/agy" /opt/homebrew/bin/agy /usr/local/bin/agy; do
    if [[ -x "$candidate" ]]; then
      AGY_BIN="$candidate"
      break
    fi
  done
fi
[[ -n "$AGY_BIN" ]] || json_error "agy not found"

installed_output="$("$AGY_BIN" --version 2>&1)" || json_error "failed to determine installed Antigravity CLI version"
installed_version="$(extract_version "$installed_output")" || true
[[ -n "$installed_version" ]] || json_error "failed to parse installed Antigravity CLI version"

emit_installed_only() {
  jq -nc --arg installed "$installed_version" \
    '{installedVersion: $installed, latestVersion: $installed, updateAvailable: false}'
  exit 0
}

# Homebrew-managed installs are updated by brew, not the Google updater.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ADAPTERS_DIR="$(dirname "$SCRIPT_DIR")"
# shellcheck source=../shared/package-manager.sh
source "$ADAPTERS_DIR/shared/package-manager.sh"
if atrium_binary_is_homebrew_managed "$AGY_BIN"; then
  # The cask can only move to the version it publishes (its version carries a
  # ",<build>" suffix). A third-party tap has no published version to compare.
  brew_package="$(atrium_official_homebrew_package "$AGY_BIN")" || emit_installed_only
  command -v curl >/dev/null 2>&1 || json_error "curl not found"
  published_version="$(atrium_homebrew_published_version "$brew_package")" ||
    json_error "failed to fetch latest Homebrew Antigravity CLI version"
  latest_version="$(extract_version "$published_version")" || true
else
  command -v curl >/dev/null 2>&1 || json_error "curl not found"

  case "$(uname -s)" in
    Darwin) os="darwin" ;;
    Linux) os="linux" ;;
    *) emit_installed_only ;;
  esac
  case "$(uname -m)" in
    x86_64 | amd64) arch="amd64" ;;
    arm64 | aarch64) arch="arm64" ;;
    *) emit_installed_only ;;
  esac

  platform="${os}_${arch}"
  if [[ "$os" == "linux" ]]; then
    if [[ -f /lib/libc.musl-x86_64.so.1 || -f /lib/libc.musl-aarch64.so.1 ]] || ldd /bin/ls 2>&1 | grep -q musl; then
      platform="linux_${arch}_musl"
    fi
  fi

  manifest_json="$(curl -fsS --connect-timeout 2 --max-time 5 "$UPDATER_HOST/manifests/$platform.json" 2>/dev/null)" ||
    json_error "failed to fetch latest Antigravity CLI version"
  latest_version="$(printf '%s' "$manifest_json" | jq -er '.version | select(type == "string" and length > 0)' 2>/dev/null)" ||
    json_error "failed to parse latest Antigravity CLI version"
fi
[[ "$latest_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+([+-][0-9A-Za-z.-]+)?$ ]] ||
  json_error "failed to parse latest Antigravity CLI version"

update_available=false
if version_is_newer "$installed_version" "$latest_version"; then
  update_available=true
fi

jq -nc --arg installed "$installed_version" --arg latest "$latest_version" --argjson available "$update_available" \
  '{installedVersion: $installed, latestVersion: $latest, updateAvailable: $available}'
