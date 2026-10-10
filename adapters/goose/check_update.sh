#!/usr/bin/env bash
set -euo pipefail

# check_update.sh — Report whether a newer Goose CLI release exists.
# Output: {installedVersion, latestVersion, updateAvailable} per
# schemas/methods/check_update.schema.json (additionalProperties: false).

# <data>/adapters/<name> is a symlink into .managed/<name>/generations/<id>
# and `..` through it resolves physically, so find shared/ from the logical path.
SCRIPT_DIR="$(CDPATH='' cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
case "$SCRIPT_DIR" in
  */.managed/*/generations/*) SHARED_DIR="${SCRIPT_DIR%/.managed/*}/shared" ;;
  *) SHARED_DIR="${SCRIPT_DIR%/*}/shared" ;;
esac
# shellcheck source=../shared/package-manager.sh
source "$SHARED_DIR/package-manager.sh"

# Fail soft: the SDK prefers exit 0 with an empty result over a non-zero exit.
json_error() {
  jq -nc --arg msg "$1" '{updateAvailable: false, error: $msg}'
  exit 0
}

command -v jq >/dev/null 2>&1 || {
  printf '{"updateAvailable":false,"error":"jq not found"}\n'
  exit 0
}

GOOSE_BIN="$(command -v goose 2>/dev/null || true)"
[ -n "$GOOSE_BIN" ] || json_error "goose not found"

# `goose --version` prints a bare semver on a single line (e.g. "1.50.0"),
# so the version is the first field — not the third.
installed_version="$("$GOOSE_BIN" --version 2>/dev/null | head -n 1 | awk '{print $1}')"
installed_version="${installed_version#v}"
[[ "$installed_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+ ]] \
  || json_error "failed to parse installed goose version"

# Homebrew owns updates for brew-installed binaries. Report no update and make
# no network call at all — tests/homebrew-managed-updates.assert.sh asserts
# both, and pointing a brew install at a GitHub release splits the install.
if atrium_binary_is_homebrew_managed "$GOOSE_BIN"; then
  jq -nc --arg installed "$installed_version" \
    '{installedVersion: $installed, latestVersion: $installed, updateAvailable: false}'
  exit 0
fi

command -v curl >/dev/null 2>&1 || json_error "curl not found"

release_json="$(curl -fsS --connect-timeout 2 --max-time 5 \
  'https://api.github.com/repos/aaif-goose/goose/releases/latest' 2>/dev/null)" \
  || json_error "failed to fetch latest goose version"

latest_version="$(printf '%s' "$release_json" \
  | jq -er '.tag_name | select(type == "string" and length > 0)' 2>/dev/null)" \
  || json_error "failed to parse latest goose version"
latest_version="${latest_version#v}"
[[ "$latest_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+ ]] \
  || json_error "failed to parse latest goose version"

update_available=false
if [ "$installed_version" != "$latest_version" ] \
  && [ "$(printf '%s\n%s\n' "$installed_version" "$latest_version" | sort -V | tail -n 1)" = "$latest_version" ]; then
  update_available=true
fi

jq -nc \
  --arg installed "$installed_version" \
  --arg latest "$latest_version" \
  --argjson available "$update_available" \
  '{installedVersion: $installed, latestVersion: $latest, updateAvailable: $available}'
