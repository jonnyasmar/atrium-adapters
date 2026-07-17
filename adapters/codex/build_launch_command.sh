#!/usr/bin/env bash
set -euo pipefail

# build_launch_command.sh — Build the command to launch Codex.
# Takes $1 = JSON flags from launcher options
# Output: {"command": ["codex", ...flags]}

FLAGS="${1:-"{}"}"
CMD='["codex"'

if command -v jq &>/dev/null; then
  SKIP="$(echo "$FLAGS" | jq -r '.dangerouslySkipPermissions // false' 2>/dev/null)" || SKIP="false"
  if [ "$SKIP" = "true" ]; then
    CMD="${CMD}, \"--dangerously-bypass-approvals-and-sandbox\""
  fi

  MODEL="$(echo "$FLAGS" | jq -r '.model // ""' 2>/dev/null)" || MODEL=""
  if [ -n "$MODEL" ]; then
    CMD="${CMD}, \"-m\", \"${MODEL}\""
  fi

  # Codex has no native --effort flag; reasoning effort is a config override.
  # The argv element must be model_reasoning_effort="<v>" (inner quotes are
  # part of the TOML value codex's -c/--config parser expects, e.g. -c model="o3").
  EFFORT="$(echo "$FLAGS" | jq -r '.effort // ""' 2>/dev/null)" || EFFORT=""
  if [ -n "$EFFORT" ]; then
    CMD="${CMD}, \"-c\", \"model_reasoning_effort=\\\"${EFFORT}\\\"\""
  fi

  # Fast mode: lower-latency service tier (orthogonal to reasoning effort).
  # Docs: service_tier="fast" + features.fast_mode=true. ChatGPT credit plans
  # only — API-key sessions use token pricing and ignore the credit multiplier.
  FAST="$(echo "$FLAGS" | jq -r '.fast // false' 2>/dev/null)" || FAST="false"
  if [ "$FAST" = "true" ]; then
    CMD="${CMD}, \"--enable\", \"fast_mode\", \"-c\", \"service_tier=\\\"fast\\\"\""
  fi

  EXTRA="$(echo "$FLAGS" | jq -r '.extraArgs // ""' 2>/dev/null)" || EXTRA=""
  if [ -n "$EXTRA" ]; then
    for arg in $EXTRA; do
      CMD="${CMD}, \"${arg}\""
    done
  fi
else
  if echo "$FLAGS" | grep -qE '"dangerouslySkipPermissions"\s*:\s*true'; then
    CMD="${CMD}, \"--dangerously-bypass-approvals-and-sandbox\""
  fi
fi

CMD="${CMD}]"
echo "{\"command\": ${CMD}}"
exit 0
