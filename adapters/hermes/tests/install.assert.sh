#!/usr/bin/env bash
set -euo pipefail

# install.assert.sh — assert the Hermes adapter install wrote what we expect.
# Runs after `hooks.sh install` (harness Phase 2).

HERMES_HOME="${HERMES_HOME:-$HOME/.hermes}"
CONFIG="${HERMES_HOME}/config.yaml"
ALLOW="${HERMES_HOME}/shell-hooks-allowlist.json"

[ -f "$CONFIG" ] || { echo "config.yaml missing after install" >&2; exit 1; }

# Hook commands written into config.yaml.
grep -q "hermes-hook.sh" "$CONFIG" || {
  echo "no atrium hook commands in config.yaml" >&2; exit 1; }

# Session-registration + activity events present.
for ev in on_session_start pre_llm_call pre_tool_call post_tool_call post_llm_call; do
  grep -q "$ev" "$CONFIG" || { echo "missing hook event: $ev" >&2; exit 1; }
done

# Consent allowlist pre-seeded so launch never blocks on the TTY prompt.
[ -f "$ALLOW" ] || { echo "allowlist not created" >&2; exit 1; }
grep -q "hermes-hook.sh" "$ALLOW" || { echo "allowlist not pre-seeded" >&2; exit 1; }

exit 0
