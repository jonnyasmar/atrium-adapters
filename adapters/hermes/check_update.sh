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

# Prefer the product semver (0.20.0) over calver stamps (2026.8.3) or
# embedded toolchain versions (Python 3.11.15). Hermes --version looks like:
#   Hermes Agent v0.19.1 (2026.7.30)
# and GitHub tags are calver (v2026.8.3) while release *names* carry the
# product semver: "Hermes Agent v0.20.0 (2026.8.3)".
extract_product_version() {
  printf '%s\n' "$1" \
    | grep -Eo 'v?[0-9]+\.[0-9]+\.[0-9]+([+-][0-9A-Za-z.-]+)?' \
    | sed 's/^[vV]//' \
    | awk -F. '
        {
          major = $1 + 0
          # Product versions stay below 100; calver years (2026.x.x) and
          # accidental year-stamped matches are skipped.
          if (major >= 100) next
          print $0
          exit
        }
      '
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
installed_version="$(extract_product_version "$installed_output")" || true
[[ -n "$installed_version" ]] || json_error "failed to parse installed Hermes version"

release_json="$(curl -fsS --connect-timeout 2 --max-time 5 -H 'Accept: application/vnd.github+json' 'https://api.github.com/repos/NousResearch/hermes-agent/releases/latest' 2>/dev/null)" || json_error "failed to fetch latest Hermes version"
# Prefer release name (has product semver) over tag_name (often calver).
release_label="$(printf '%s' "$release_json" | jq -er '(.name // empty) as $n | if ($n | length) > 0 then $n else .tag_name end | select(type == "string" and length > 0)' 2>/dev/null)" || json_error "failed to parse latest Hermes version"
latest_version="$(extract_product_version "$release_label")" || true
# Fall back to tag when name has no product semver (older releases).
if [[ -z "$latest_version" ]]; then
  tag="$(printf '%s' "$release_json" | jq -er '.tag_name | select(type == "string" and length > 0)' 2>/dev/null)" || true
  latest_version="$(extract_product_version "$tag")" || true
fi
[[ -n "$latest_version" ]] || json_error "failed to parse latest Hermes version"
[[ "$latest_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+([+-][0-9A-Za-z.-]+)?$ ]] || json_error "failed to parse latest Hermes version"

update_available=false
if version_is_newer "$installed_version" "$latest_version"; then
  update_available=true
fi

# Git installs may be behind origin/main without a new GitHub release.
# `hermes version` prints "Update available: …" in that case (exit 0 either way).
if [[ "$update_available" == false ]]; then
  version_status="$(hermes version 2>&1 || true)"
  if printf '%s\n' "$version_status" | grep -qi 'update available'; then
    update_available=true
    if [[ "$latest_version" == "$installed_version" ]]; then
      latest_version="${installed_version}+git"
    fi
  fi
fi

jq -nc --arg installed "$installed_version" --arg latest "$latest_version" --argjson available "$update_available" \
  '{installedVersion: $installed, latestVersion: $latest, updateAvailable: $available}'
