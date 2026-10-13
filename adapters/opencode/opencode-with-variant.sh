#!/usr/bin/env bash
# opencode-with-variant.sh — exec `opencode` with a launch-time reasoning
# variant (atrium's "effort").
#
# The TUI has no --variant flag (only `opencode run` does). A variant reaches
# it only through config: `agent.<name>.variant`, which the server applies
# while `agent.<name>.model` matches the prompt's model (verified on opencode
# 1.19.0 against `opencode serve`: no-variant prompt + matching agent model ->
# the configured variant; mismatched or absent agent model -> "default").
#
# That JSON can't ride the launch line — atrium types the argv into the pane
# shell with an unquoted `cmd.join(" ")` — so build_launch_command passes the
# variant as ATRIUM_OPENCODE_VARIANT and this wrapper merges it into whatever
# OPENCODE_CONFIG_CONTENT the pane already carries (atrium's custom providers
# set one; replacing it would drop the provider).

set -euo pipefail

VARIANT="${ATRIUM_OPENCODE_VARIANT:-}"
unset ATRIUM_OPENCODE_VARIANT

MODEL=""
AGENT="build"
prev=""
for arg in "$@"; do
  case "$prev" in
    -m | --model) MODEL="$arg" ;;
    --agent) AGENT="$arg" ;;
  esac
  case "$arg" in
    --model=*) MODEL="${arg#--model=}" ;;
    --agent=*) AGENT="${arg#--agent=}" ;;
  esac
  prev="$arg"
done

if [ -n "$VARIANT" ] && [ -n "$MODEL" ] && [ -n "$AGENT" ] && command -v jq >/dev/null 2>&1; then
  BASE="${OPENCODE_CONFIG_CONTENT:-}"
  [ -n "$BASE" ] || BASE='{}'
  # A pane config that isn't a JSON object is the user's to fix — leave it
  # untouched rather than overwrite it.
  if MERGED="$(printf '%s' "$BASE" | jq -ce --arg a "$AGENT" --arg m "$MODEL" --arg v "$VARIANT" \
    'select(type == "object") | .agent[$a] = ((.agent[$a] // {}) + {model: $m, variant: $v})' 2>/dev/null)"; then
    export OPENCODE_CONFIG_CONTENT="$MERGED"
  fi
fi

exec opencode "$@"
