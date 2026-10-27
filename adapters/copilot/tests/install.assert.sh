#!/usr/bin/env bash
set -euo pipefail
jq -e '.version == 1 and (.hooks.sessionStart | length == 1) and (.hooks.userPromptTransformed | length == 1) and (.hooks.preToolUse[0].args[0] | endswith("/adapters/copilot/copilot-hook.sh"))' \
  "${COPILOT_HOME:-$HOME/.copilot}/hooks/atrium.json" >/dev/null
