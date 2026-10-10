#!/usr/bin/env bash
set -euo pipefail

# <data>/adapters/<name> is a symlink into .managed/<name>/generations/<id>
# and `..` through it resolves physically, so find shared/ from the logical path.
SCRIPT_DIR="$(CDPATH='' cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
case "$SCRIPT_DIR" in
  */.managed/*/generations/*) SHARED_DIR="${SCRIPT_DIR%/.managed/*}/shared" ;;
  *) SHARED_DIR="${SCRIPT_DIR%/*}/shared" ;;
esac
source "$SHARED_DIR/package-manager.sh"

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
OMP_BIN="$(command -v omp 2>/dev/null || true)"
[[ -n "$OMP_BIN" ]] || json_error "omp not found"

mise_tool=""
if mise_tool="$(atrium_mise_tool_for_binary "$OMP_BIN" omp)" \
  && mise_bin="$(atrium_mise_command "$OMP_BIN")" \
  && mise_current="$(atrium_mise_current_binary "$OMP_BIN" "$mise_bin" omp)"; then
  mise_owner="$OMP_BIN"
  OMP_BIN="$mise_current"
else
  mise_tool=""
fi

installed_output="$(DISABLE_SELF_UPDATE=1 "$OMP_BIN" --version 2>&1)" || json_error "failed to determine installed Oh My Pi version"
installed_version="$(extract_version "$installed_output")" || true
[[ -n "$installed_version" ]] || json_error "failed to parse installed Oh My Pi version"

if [[ -n "$mise_tool" ]]; then
  # mise holds back releases younger than the user's minimum_release_age.
  published_version="$(atrium_mise_latest_version "$mise_owner" "$mise_bin" "$mise_tool")" || json_error "failed to fetch latest mise Oh My Pi version"
  latest_version="$(extract_version "$published_version")" || true
else
  command -v curl >/dev/null 2>&1 || json_error "curl not found"
  registry_json="$(curl -fsS --connect-timeout 2 --max-time 5 'https://registry.npmjs.org/-/package/@oh-my-pi%2Fpi-coding-agent/dist-tags' 2>/dev/null)" || json_error "failed to fetch latest Oh My Pi version"
  latest_version="$(printf '%s' "$registry_json" | jq -er '.latest | select(type == "string" and length > 0)' 2>/dev/null)" || json_error "failed to parse latest Oh My Pi version"
fi
[[ "$latest_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+([+-][0-9A-Za-z.-]+)?$ ]] || json_error "failed to parse latest Oh My Pi version"

update_available=false
if version_is_newer "$installed_version" "$latest_version"; then
  update_available=true
fi

jq -nc --arg installed "$installed_version" --arg latest "$latest_version" --argjson available "$update_available" \
  '{installedVersion: $installed, latestVersion: $latest, updateAvailable: $available}'
