#!/usr/bin/env bash
set -euo pipefail

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
command -v curl >/dev/null 2>&1 || json_error "curl not found"
command -v hermes >/dev/null 2>&1 || json_error "hermes not found"

installed_output="$(hermes --version 2>&1)" || json_error "failed to determine installed Hermes version"
installed_version="$(extract_version "$installed_output")" || true
[[ -n "$installed_version" ]] || json_error "failed to parse installed Hermes version"

release_json="$(curl -fsS --connect-timeout 2 --max-time 5 -H 'Accept: application/vnd.github+json' 'https://api.github.com/repos/NousResearch/hermes-agent/releases/latest' 2>/dev/null)" || json_error "failed to fetch latest Hermes version"
latest_version="$(printf '%s' "$release_json" | jq -er '.tag_name | select(type == "string" and length > 0) | sub("^[vV]"; "")' 2>/dev/null)" || json_error "failed to parse latest Hermes version"
[[ "$latest_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+([+-][0-9A-Za-z.-]+)?$ ]] || json_error "failed to parse latest Hermes version"

update_available=false
if version_is_newer "$installed_version" "$latest_version"; then
  update_available=true
fi

jq -nc --arg installed "$installed_version" --arg latest "$latest_version" --argjson available "$update_available" \
  '{installedVersion: $installed, latestVersion: $latest, updateAvailable: $available}'
