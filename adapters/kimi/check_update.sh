#!/usr/bin/env bash
set -euo pipefail

json_error() {
  jq -nc --arg error "$1" '{updateAvailable: false, error: $error}'
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

command -v jq >/dev/null 2>&1 || exit 0
command -v curl >/dev/null 2>&1 || json_error "curl not found"
KIMI_BIN="$(command -v kimi 2>/dev/null || true)"
if [[ -z "$KIMI_BIN" && -x "$HOME/.kimi-code/bin/kimi" ]]; then
  KIMI_BIN="$HOME/.kimi-code/bin/kimi"
fi
[[ -n "$KIMI_BIN" ]] || json_error "kimi not found"

installed_output="$("$KIMI_BIN" --version 2>&1)" || json_error "failed to determine installed Kimi version"
installed_version="$(extract_version "$installed_output")" || true
[[ -n "$installed_version" ]] || json_error "failed to parse installed Kimi version"

registry_json="$(curl -fsS --connect-timeout 2 --max-time 5 'https://registry.npmjs.org/-/package/@moonshot-ai%2Fkimi-code/dist-tags' 2>/dev/null)" \
  || json_error "failed to fetch latest Kimi version"
latest_version="$(printf '%s' "$registry_json" | jq -er '.latest | select(type == "string" and length > 0)' 2>/dev/null)" \
  || json_error "failed to parse latest Kimi version"

update_available=false
if version_is_newer "$installed_version" "$latest_version"; then
  update_available=true
fi

jq -nc \
  --arg installed "$installed_version" \
  --arg latest "$latest_version" \
  --argjson available "$update_available" \
  '{installedVersion: $installed, latestVersion: $latest, updateAvailable: $available}'
