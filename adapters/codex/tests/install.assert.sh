#!/usr/bin/env bash
set -euo pipefail

CONFIG_TOML="${HOME}/.codex/config.toml"
HOOKS_JSON="${HOME}/.codex/hooks.json"
TEST_DIR="$(cd "$(dirname "$0")" && pwd)"

feature_count="$(awk '$0 == "[features]" { count++ } END { print count + 0 }' "$CONFIG_TOML")"
[ "$feature_count" -eq 1 ] || {
  echo "install.assert: expected one [features] table, found $feature_count" >&2
  exit 1
}

hook_count="$(grep -cE '^[[:space:]]*hooks[[:space:]]*=[[:space:]]*true[[:space:]]*$' "$CONFIG_TOML" || true)"
[ "$hook_count" -eq 1 ] || {
  echo "install.assert: expected one enabled hooks flag, found $hook_count" >&2
  exit 1
}

jq -e '.hooks.SessionStart and .hooks.SessionEnd' "$HOOKS_JSON" >/dev/null
bash "$TEST_DIR/hooks-config/assert.sh"
